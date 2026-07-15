const std = @import("std");

const m = @import("metrics");
const utils = @import("utils");

const types = @import("api.zig").types;
const db_queries = @import("Db.zig").queries;

pull_requests: m.GaugeVec(u32, utils.meta.MergedStructs(&.{ Labels.Repo, struct {
    state: types.PullRequestState,
} })),
check_runs: m.GaugeVec(u32, utils.meta.MergedStructs(&.{ Labels.App, Labels.Repo, struct {
    state: db_queries.CheckState.Flat,
} })),
pull_request_time_to_fix: m.HistogramVec(u64, utils.meta.MergedStructs(&.{ Labels.App, Labels.Repo }), &.{
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
}),

const Labels = struct {
    pub const App = struct { app: types.Id };
    pub const Repo = struct { repo: []const u8 };
};

pub fn deinit(self: *@This()) void {
    self.pull_requests.deinit();
    self.check_runs.deinit();
    self.pull_request_time_to_fix.deinit();
}

pub fn init(allocator: std.mem.Allocator, io: std.Io, comptime opts: m.RegistryOpts) !@This() {
    return .{
        .pull_requests = try .init(allocator, io, "pull_requests", .{
            .help = "Count of pull requests",
        }, opts),
        .check_runs = try .init(allocator, io, "check_runs", .{
            .help = "Count of check runs",
        }, opts),
        .pull_request_time_to_fix = try .init(allocator, io, "pull_request_time_to_fix_seconds", .{
            .help = "Duration from first failing commit to first successful commit on a pull request",
        }, opts),
    };
}

pub fn write(self: *const @This(), writer: *std.Io.Writer) !void {
    try m.write(self, writer);
}

const Metrics = @This();

pub const Scrape = struct {
    const zqlite = @import("zqlite");
    const zqlite_typed = @import("zqlite-typed");

    const Db = @import("Db.zig");

    allocator: std.mem.Allocator,
    mutex: std.Io.Mutex = .init,

    time_to_fix_cursor: Db.queries.TimeToFixCursor = .{},

    pub fn deinit(self: *@This()) void {
        self.time_to_fix_cursor.deinit(self.allocator);
    }

    /// Thread safe via mutex. If this function was not protected by a mutex, the following would apply:
    /// Must never be called concurrently as that will mess up the metrics because some events could be observed twice.
    pub fn refreshMetrics(self: *@This(), arena: std.mem.Allocator, io: std.Io, metrics: *Metrics, db_conn: zqlite.Conn) !void {
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);

        {
            var rows = try Db.queries.pullRequestCountGroupedByRepoAndState.queryIterator(arena, db_conn, .{});
            errdefer rows.deinit();

            while (try rows.next(arena)) |row| {
                defer zqlite_typed.freeStructFromRow(@TypeOf(row), arena, row);
                try metrics.pull_requests.set(.{
                    .repo = row.repo,
                    .state = row.state,
                }, @intCast(row.count));
            }

            try rows.deinitErr();
        }

        {
            var rows = try Db.queries.checkRunCountGroupedByAppAndRepoAndState.queryIterator(arena, db_conn, .{});
            errdefer rows.deinit();

            while (try rows.next(arena)) |row| {
                defer zqlite_typed.freeStructFromRow(@TypeOf(row), arena, row);
                try metrics.check_runs.set(.{
                    .app = row.app_slug,
                    .repo = row.repo,
                    .state = row.state.flatten(),
                }, @intCast(row.count));
            }

            try rows.deinitErr();
        }

        {
            var rows = try Db.queries.timeToFix.queryIterator(arena, db_conn, self.time_to_fix_cursor.tuple());
            errdefer rows.deinit();

            while (try rows.next(arena)) |row| {
                defer zqlite_typed.freeStructFromRow(@TypeOf(row), arena, row);

                const new_cursor = try (Db.queries.TimeToFixCursor{
                    .fixed_at = row.fixed_at,
                    .repo_id = row.repo_id,
                    .app_id = row.app_id,
                    .check_run_name = row.check_run_name,
                    .cycle = row.cycle,
                }).dupe(self.allocator);
                errdefer new_cursor.deinit(self.allocator);

                try metrics.pull_request_time_to_fix.observe(.{
                    .app = row.app_slug,
                    .repo = row.repo_full,
                }, @intCast(row.broken_duration_seconds));

                self.time_to_fix_cursor.deinit(self.allocator);

                // Now that the old cursor is freed,
                // no errors must happen until the new cursor is set,
                // so that the new cursor will be freed.
                errdefer comptime unreachable;

                self.time_to_fix_cursor = new_cursor;
            }

            try rows.deinitErr();
        }
    }
};
