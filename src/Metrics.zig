const std = @import("std");

const m = @import("metrics");
const utils = @import("utils");
const zqlite = @import("zqlite");
const zqlite_typed = @import("zqlite-typed");

const api = @import("api.zig");
const Db = @import("Db.zig");

const Metrics = @This();

commits: m.GaugeVec(u32, utils.meta.MergedStructs(&.{Labels.Repo})),
pull_requests: m.GaugeVec(u32, utils.meta.MergedStructs(&.{ Labels.Repo, struct {
    state: api.types.PullRequestState,
} })),
check_suites: m.GaugeVec(u32, utils.meta.MergedStructs(&.{ Labels.App, Labels.Repo, struct {
    state: Db.queries.CheckState.Flat,
} })),
check_runs: m.GaugeVec(u32, utils.meta.MergedStructs(&.{ Labels.App, Labels.Repo, struct {
    state: Db.queries.CheckState.Flat,
} })),
branch_time_to_fix: m.HistogramVec(u32, utils.meta.MergedStructs(&.{ Labels.App, Labels.Repo, Labels.Branch }), &time_to_fix_buckets),
pull_request_time_to_fix: m.HistogramVec(u32, utils.meta.MergedStructs(&.{ Labels.App, Labels.Repo }), &time_to_fix_buckets),

metric_computation_duration: m.GaugeVec(f16, Labels.Metric),

scan_state: m.Gauge(std.meta.Tag(ScanState)),

database: m.Gauge(usize),

client: api.Client.Metrics,

const time_to_fix_buckets = [_]u32{
    5 * std.time.s_per_min,
    15 * std.time.s_per_min,
    30 * std.time.s_per_min,
    1 * std.time.s_per_hour,
    2 * std.time.s_per_hour,
    4 * std.time.s_per_hour,
    6 * std.time.s_per_hour,
    8 * std.time.s_per_hour,
    12 * std.time.s_per_hour,
    1 * std.time.s_per_day,
    2 * std.time.s_per_day,
    3 * std.time.s_per_day,
    4 * std.time.s_per_day,
    5 * std.time.s_per_day,
    6 * std.time.s_per_day,
    std.time.s_per_week,
    2 * std.time.s_per_week,
};

const Labels = struct {
    pub const App = struct { app: api.types.Id };
    pub const Repo = struct { repo: []const u8 };
    pub const Branch = struct { branch: []const u8 };
    pub const Metric = struct { metric: ComputedMetric };
};

pub const ComputedMetric = enum {
    commits,
    pull_requests,
    check_suites,
    check_runs,
    branch_time_to_fix,
    pull_request_time_to_fix,

    comptime {
        for (std.enums.values(@This())) |metric|
            std.debug.assert(@hasField(Metrics, @tagName(metric)));
    }
};

pub const ScanState = enum {
    idle,
    scanning,
    rate_limited,
};

pub fn deinit(self: *@This()) void {
    self.commits.deinit();
    self.pull_requests.deinit();
    self.check_suites.deinit();
    self.check_runs.deinit();
    self.branch_time_to_fix.deinit();
    self.pull_request_time_to_fix.deinit();
    self.metric_computation_duration.deinit();
    self.client.deinit();
}

pub fn init(allocator: std.mem.Allocator, io: std.Io, comptime opts: m.RegistryOpts) !@This() {
    var commits = try @FieldType(@This(), "commits").init(allocator, io, "commits", .{
        .help = "Count of scanned commits",
    }, opts);
    errdefer commits.deinit();

    var pull_requests = try @FieldType(@This(), "pull_requests").init(allocator, io, "pull_requests", .{
        .help = "Count of scanned pull requests",
    }, opts);
    errdefer pull_requests.deinit();

    var check_suites = try @FieldType(@This(), "check_suites").init(allocator, io, "check_suites", .{
        .help = "Count of scanned check suites",
    }, opts);
    errdefer check_suites.deinit();

    var check_runs = try @FieldType(@This(), "check_runs").init(allocator, io, "check_runs", .{
        .help = "Count of scanned check runs",
    }, opts);
    errdefer check_runs.deinit();

    var branch_time_to_fix = try @FieldType(@This(), "branch_time_to_fix").init(allocator, io, "branch_time_to_fix_seconds", .{
        .help = "Duration from an app's first failing commit's check run to first successful commit's check run on a branch",
    }, opts);
    errdefer branch_time_to_fix.deinit();

    var pull_request_time_to_fix = try @FieldType(@This(), "pull_request_time_to_fix").init(allocator, io, "pull_request_time_to_fix_seconds", .{
        .help = "Duration from an app's first failing commit's check run to first successful commit's check run on a pull request",
    }, opts);
    errdefer pull_request_time_to_fix.deinit();

    var metric_computation_duration = try @FieldType(@This(), "metric_computation_duration").init(allocator, io, "metric_computation_duration_seconds", .{
        .help = "Duration a metric takes to compute",
    }, opts);
    errdefer metric_computation_duration.deinit();

    var client = try api.Client.Metrics.init(allocator, io, opts);
    errdefer client.deinit();

    return .{
        .commits = commits,
        .pull_requests = pull_requests,
        .check_suites = check_suites,
        .check_runs = check_runs,
        .branch_time_to_fix = branch_time_to_fix,
        .pull_request_time_to_fix = pull_request_time_to_fix,
        .metric_computation_duration = metric_computation_duration,
        .scan_state = .init("scan_state", .{
            .help = std.fmt.comptimePrint(
                "State of scanning ({f})",
                .{utils.fmt.fmtJoinSepStr(ScanState, "{0d} = {0t}", std.enums.values(ScanState), ", ")},
            ),
        }, opts),
        .database = .init("database_bytes", .{
            .help = "Size of the state database",
        }, opts),
        .client = client,
    };
}

pub fn write(self: *@This(), writer: *std.Io.Writer) !void {
    inline for (std.enums.values(ComputedMetric)) |metric|
        try @field(self, @tagName(metric)).write(writer);

    try m.write(&.{
        self.metric_computation_duration,
        self.scan_state,
        self.database,
    }, writer);

    try self.client.write(writer);
}

pub const Scrape = struct {
    allocator: std.mem.Allocator,

    branch_time_to_fix_cursor: Db.queries.TimeToFixCursor = .{},
    branch_time_to_fix_mutex: std.Io.Mutex = .init,

    pull_request_time_to_fix_cursor: Db.queries.TimeToFixCursor = .{},
    pull_request_time_to_fix_mutex: std.Io.Mutex = .init,

    pub const Range = struct {
        gte: ?std.Io.Timestamp = null,
        lt: ?std.Io.Timestamp = null,
    };

    pub fn deinit(self: *@This()) void {
        self.branch_time_to_fix_cursor.deinit(self.allocator);
        self.pull_request_time_to_fix_cursor.deinit(self.allocator);
    }

    pub fn refreshMetrics(
        self: *@This(),
        allocator: std.mem.Allocator,
        io: std.Io,
        metrics: *Metrics,
        db_conn: zqlite.Conn,
        range: Range,
    ) !void {
        inline for (std.enums.values(Metrics.ComputedMetric)) |metric|
            try self.refreshComputedMetric(metric, allocator, io, metrics, db_conn, range);

        metrics.database.set(@intCast((try Db.queries.dbSize.query(allocator, db_conn, .{})).?.bytes));
    }

    pub fn refreshComputedMetric(
        self: *@This(),
        // Would not need to be comptime but should compile away the cost of the switch.
        comptime metric: Metrics.ComputedMetric,
        allocator: std.mem.Allocator,
        io: std.Io,
        metrics: *Metrics,
        db_conn: zqlite.Conn,
        range: Range,
    ) !void {
        const started_at = std.Io.Clock.Timestamp.now(io, .cpu_process);

        switch (metric) {
            .commits => {
                var rows = try Db.queries.commitCountGroupedByRepo.queryIterator(allocator, db_conn, .{
                    .committed_at_gte = if (range.gte) |gte| .fromTimestamp(gte) else null,
                    .committed_at_lt = if (range.lt) |lt| .fromTimestamp(lt) else null,
                });
                errdefer rows.deinit();

                while (try rows.next(allocator)) |row| {
                    defer zqlite_typed.freeStructFromRow(@TypeOf(row), allocator, row);
                    try metrics.commits.set(.{
                        .repo = row.repo,
                    }, @intCast(row.count));
                }

                try rows.deinitErr();
            },
            .pull_requests => {
                var rows = try Db.queries.pullRequestCountGroupedByRepoAndState.queryIterator(allocator, db_conn, .{
                    .created_at_gte = if (range.gte) |gte| .fromTimestamp(gte) else null,
                    .updated_at_lt = if (range.lt) |lt| .fromTimestamp(lt) else null,
                });
                errdefer rows.deinit();

                while (try rows.next(allocator)) |row| {
                    defer zqlite_typed.freeStructFromRow(@TypeOf(row), allocator, row);
                    try metrics.pull_requests.set(.{
                        .repo = row.repo,
                        .state = row.state,
                    }, @intCast(row.count));
                }

                try rows.deinitErr();
            },
            .check_suites => {
                var rows = try Db.queries.checkSuiteCountGroupedByAppAndRepoAndState.queryIterator(allocator, db_conn, .{
                    .created_at_gte = if (range.gte) |gte| .fromTimestamp(gte) else null,
                    .updated_at_lt = if (range.lt) |lt| .fromTimestamp(lt) else null,
                });
                errdefer rows.deinit();

                while (try rows.next(allocator)) |row| {
                    defer zqlite_typed.freeStructFromRow(@TypeOf(row), allocator, row);
                    try metrics.check_suites.set(.{
                        .app = row.app_slug,
                        .repo = row.repo,
                        .state = row.state.flatten(),
                    }, @intCast(row.count));
                }

                try rows.deinitErr();
            },
            .check_runs => {
                var rows = try Db.queries.checkRunCountGroupedByAppAndRepoAndState.queryIterator(allocator, db_conn, .{
                    .started_at_gte = if (range.gte) |gte| .fromTimestamp(gte) else null,
                    .completed_at_lt = if (range.lt) |lt| .fromTimestamp(lt) else null,
                });
                errdefer rows.deinit();

                while (try rows.next(allocator)) |row| {
                    defer zqlite_typed.freeStructFromRow(@TypeOf(row), allocator, row);
                    try metrics.check_runs.set(.{
                        .app = row.app_slug,
                        .repo = row.repo,
                        .state = row.state.flatten(),
                    }, @intCast(row.count));
                }

                try rows.deinitErr();
            },
            .branch_time_to_fix => {
                try self.branch_time_to_fix_mutex.lock(io);
                defer self.branch_time_to_fix_mutex.unlock(io);

                var rows = try Db.queries.branchTimeToFix.queryIterator(allocator, db_conn, .{
                    .cursor_fixed_at = self.branch_time_to_fix_cursor.fixed_at,
                    .cursor_repo_id = self.branch_time_to_fix_cursor.repo_id,
                    .cursor_app_id = self.branch_time_to_fix_cursor.app_id,
                    .cursor_seed_id = self.branch_time_to_fix_cursor.seed_id,
                    .cursor_cycle = self.branch_time_to_fix_cursor.cycle,
                    .at_gte = if (range.gte) |gte| .fromTimestamp(gte) else null,
                    .at_lt = if (range.lt) |lt| .fromTimestamp(lt) else null,
                });
                errdefer rows.deinit();

                while (try rows.next(allocator)) |row| {
                    defer zqlite_typed.freeStructFromRow(@TypeOf(row), allocator, row);

                    const new_cursor = try (Db.queries.TimeToFixCursor{
                        .fixed_at = row.fixed_at,
                        .repo_id = row.repo_id,
                        .app_id = row.app_id,
                        .seed_id = row.seed_id,
                        .cycle = row.cycle,
                    }).dupe(self.allocator);
                    errdefer new_cursor.deinit(self.allocator);

                    try metrics.branch_time_to_fix.observe(.{
                        .app = row.app_slug,
                        .repo = row.repo_full,
                        .branch = row.seed_tag,
                    }, @intCast(row.broken_duration_seconds));

                    {
                        self.branch_time_to_fix_cursor.deinit(self.allocator);

                        // Now that the old cursor is freed,
                        // no errors must happen until the new cursor is set,
                        // so that the new cursor will be freed.
                        errdefer comptime unreachable;

                        self.branch_time_to_fix_cursor = new_cursor;
                    }
                }

                try rows.deinitErr();
            },
            .pull_request_time_to_fix => {
                try self.pull_request_time_to_fix_mutex.lock(io);
                defer self.pull_request_time_to_fix_mutex.unlock(io);

                var rows = try Db.queries.pullRequestTimeToFix.queryIterator(allocator, db_conn, .{
                    .cursor_fixed_at = self.pull_request_time_to_fix_cursor.fixed_at,
                    .cursor_repo_id = self.pull_request_time_to_fix_cursor.repo_id,
                    .cursor_app_id = self.pull_request_time_to_fix_cursor.app_id,
                    .cursor_seed_id = self.pull_request_time_to_fix_cursor.seed_id,
                    .cursor_cycle = self.pull_request_time_to_fix_cursor.cycle,
                    .at_gte = if (range.gte) |gte| .fromTimestamp(gte) else null,
                    .at_lt = if (range.lt) |lt| .fromTimestamp(lt) else null,
                });
                errdefer rows.deinit();

                while (try rows.next(allocator)) |row| {
                    defer zqlite_typed.freeStructFromRow(@TypeOf(row), allocator, row);

                    const new_cursor = try (Db.queries.TimeToFixCursor{
                        .fixed_at = row.fixed_at,
                        .repo_id = row.repo_id,
                        .app_id = row.app_id,
                        .seed_id = row.seed_id,
                        .cycle = row.cycle,
                    }).dupe(self.allocator);
                    errdefer new_cursor.deinit(self.allocator);

                    try metrics.pull_request_time_to_fix.observe(.{
                        .app = row.app_slug,
                        .repo = row.repo_full,
                    }, @intCast(row.broken_duration_seconds));

                    {
                        self.pull_request_time_to_fix_cursor.deinit(self.allocator);

                        // Now that the old cursor is freed,
                        // no errors must happen until the new cursor is set,
                        // so that the new cursor will be freed.
                        errdefer comptime unreachable;

                        self.pull_request_time_to_fix_cursor = new_cursor;
                    }
                }

                try rows.deinitErr();
            },
        }

        try metrics.metric_computation_duration.set(
            .{ .metric = metric },
            @floatCast(@as(f64, @floatFromInt(started_at.untilNow(io).raw.nanoseconds)) / std.time.ns_per_s),
        );
    }
};
