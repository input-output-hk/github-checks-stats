const builtin = @import("builtin");
const std = @import("std");
const args = @import("args");
const utils = @import("utils");
const zqlite = @import("zqlite");
const zqlite_typed = @import("zqlite-typed");

const api = @import("api.zig");
const Db = @import("Db.zig");
const Metrics = @import("Metrics.zig");

pub fn main(init: std.process.Init) !void {
    var stdout_buffer: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const stdout_w = &stdout.interface;

    var stderr_buffer: [1024]u8 = undefined;
    var stderr = std.Io.File.stderr().writer(init.io, &stderr_buffer);
    const stderr_w = &stderr.interface;

    const Options = struct {
        db: [:0]const u8 = "github-checks-stats.sqlite",
        @"user-agent": ?[]const u8 = null,
        @"token-file": ?[]const u8 = null,

        pub const meta = .{
            .usage_summary = "[options] <scan|watch [--interval SECS]> REPO...",
            .full_text = "Collect statistics about GitHub Checks",
            .option_docs = .{
                .db = "path to state database",
                .@"user-agent" = "User-Agent header to send, may be needed to authenticate as a GitHub App",
                .@"token-file" = "file to read a token from to authorize with",
            },
        };
    };

    const Verbs = union(enum) {
        scan: struct {
            pub const meta = .{};
        },
        watch: struct {
            interval: u32 = 300,

            pub const meta = .{
                .option_docs = .{
                    .interval = "seconds to sleep between iterations (default 300)",
                },
            };
        },
    };

    const options = options: {
        const result = args.parseWithVerbForCurrentProcess(Options, Verbs, init, .print);

        const invalid = if (result) |options|
            options.verb == null or options.positionals.len == 0
        else |err| switch (err) {
            error.InvalidArguments => true,
            else => return err,
        };

        if (invalid) {
            try args.printHelpWithVerb(Options, Verbs, "github-checks-stats", stderr_w);
            try stderr_w.flush();

            std.process.exit(1);
        }

        break :options try result;
    };
    defer options.deinit();

    var db = try Db.init(init.gpa, init.io, .{ .path = options.options.db });
    defer db.deinit();

    const db_conn = try db.pool.acquire(init.io);
    defer db.pool.release(init.io, db_conn);

    var client = try api.Client.init(
        init.arena.allocator(),
        init.io,
        init.environ_map,
        options.options.@"user-agent",
        if (options.options.@"token-file") |token_file| token: {
            var buffer: [1024]u8 = undefined;
            const token = try std.Io.Dir.cwd().readFile(init.io, token_file, &buffer);
            break :token std.mem.trim(u8, token, " \t\n\r");
        } else null,
    );
    defer client.deinit();

    var metrics = try Metrics.init(init.gpa, init.io, .{});
    defer metrics.deinit();

    try stdout_w.print(utils.mem.comptimeJoin(&.{
        "repo_owner",
        "repo_name",
        "pr_number",
        "commit_oid",
        "check_suite_app_name",
        "check_suite_status",
        "check_suite_conclusion",
        "check_run_name",
        "check_run_status",
        "check_run_conclusion",
        "check_run_started_at",
        "check_run_completed_at",
        "check_run_duration_seconds",
    }, "\t") ++ "\n", .{});

    switch (options.verb.?) {
        .scan => try scan(init.gpa, &client, db_conn, stdout_w, &metrics, options.positionals, null), // TODO retry on rate limit
        .watch => |watch| {
            const interval = std.Io.Duration.fromSeconds(@as(i64, watch.interval));
            const open_states: []const api.types.PullRequestState = &.{.OPEN};
            while (true) {
                scan(init.gpa, &client, db_conn, stdout_w, &metrics, options.positionals, open_states) catch |err| switch (err) {
                    error.RateLimited => std.log.warn("rate limited; sleeping {f} before retry", .{interval}),
                    else => |e| return e,
                };
                try std.Io.sleep(init.io, interval, .awake);
            }
        },
    }
}

fn scan(
    allocator: std.mem.Allocator,
    client: *api.Client,
    db_conn: zqlite.Conn,
    stdout_w: *std.Io.Writer,
    metrics: *Metrics,
    repos: []const []const u8,
    states: ?[]const api.types.PullRequestState,
) !void {
    for (repos) |repo_full| {
        const repo_owner, const repo_name = repo: {
            errdefer std.log.err("malformed repository \"{s}\", must be of form \"foo/bar\"", .{repo_full});
            var iter = std.mem.splitScalar(u8, repo_full, '/');
            const owner = iter.next() orelse return error.MalformedRepository;
            const name = iter.next() orelse return error.MalformedRepository;
            std.debug.assert(iter.next() == null);
            break :repo .{ owner, name };
        };

        std.log.info("/{s}/{s}: fetching repository…", .{ repo_owner, repo_name });

        const repo = try api.queries.fetchRepoByFullName(allocator, client, repo_owner, repo_name);
        defer repo.deinit();

        try Db.queries.Repository.upsert.exec(db_conn, .{ repo.value.id, repo.value.owner.login, repo.value.name });

        std.log.info("/{s}/{s}: scanning for pull requests…", .{ repo_owner, repo_name });

        const prs = try api.queries.fetchPullRequestsByRepo(allocator, client, repo_owner, repo_name, states);
        defer prs.deinit();

        for (prs.value) |pr|
            try Db.queries.PullRequest.upsert.exec(db_conn, .{ pr.id, repo.value.id, pr.number, @tagName(pr.state) });

        for (prs.value) |pr| {
            std.log.info("{s}: scanning for commits…", .{pr.resourcePath});

            const commits = try api.queries.fetchCommitsByPullRequestId(allocator, client, pr.id);
            defer commits.deinit();

            for (commits.value) |commit|
                try Db.queries.Commit.upsert.exec(db_conn, .{ commit.id, commit.oid });

            for (commits.value) |commit| {
                std.log.info("{s}: scanning for check suites…", .{commit.resourcePath});

                const check_suites = try api.queries.fetchCheckSuitesByCommitId(allocator, client, commit.id);
                defer check_suites.deinit();

                for (check_suites.value) |check_suite| {
                    try Db.queries.App.upsert.exec(db_conn, .{
                        check_suite.app.id,
                        check_suite.app.slug,
                        check_suite.app.name,
                    });

                    {
                        const created_at = try std.fmt.allocPrint(allocator, "{f}", .{check_suite.createdAt});
                        defer allocator.free(created_at);

                        const status = try std.fmt.allocPrint(allocator, "{f}", .{check_suite.status});
                        defer allocator.free(status);

                        try Db.queries.CheckSuite.upsert.exec(db_conn, .{
                            check_suite.id,
                            repo.value.id,
                            commit.id,
                            check_suite.app.id,
                            created_at,
                            status,
                            if (check_suite.conclusion) |c| @tagName(c) else null,
                        });
                    }
                }

                for (check_suites.value) |check_suite| {
                    std.log.info("{s}: scanning for check runs…", .{check_suite.resourcePath});

                    const check_runs = try api.queries.fetchCheckRunsByCheckSuiteId(allocator, client, check_suite.id);
                    defer check_runs.deinit();

                    for (check_runs.value) |check_run| {
                        const started_at = try std.fmt.allocPrint(allocator, "{f}", .{check_run.startedAt});
                        defer allocator.free(started_at);

                        const completed_at = if (check_run.completedAt) |c| try std.fmt.allocPrint(allocator, "{f}", .{c}) else null;
                        defer if (completed_at) |c| allocator.free(c);

                        try Db.queries.CheckRun.upsert.exec(db_conn, .{
                            check_run.id,
                            check_suite.id,
                            check_run.name,
                            started_at,
                            completed_at,
                            check_run.externalId,
                            @tagName(check_run.status),
                            if (check_run.conclusion) |c| @tagName(c) else null,
                        });
                    }

                    for (check_runs.value) |check_run| {
                        const check_run_ns = if (check_run.completedAt) |completedAt| duration: {
                            std.debug.assert(check_run.startedAt.inner.offset == completedAt.inner.offset);
                            break :duration completedAt.inner.instant().timestamp - check_run.startedAt.inner.instant().timestamp;
                        } else null;

                        std.log.info("{s}: {?f}", .{
                            check_run.resourcePath,
                            if (check_run_ns) |c| std.Io.Duration.fromNanoseconds(@intCast(c)) else null,
                        });

                        try stdout_w.print(
                            utils.mem.comptimeJoin(&.{
                                "{s}",
                                "{s}",
                                "{d}",
                                "{s}",
                                "{s}",
                                "{f}",
                                "{?f}",
                                "{s}",
                                "{f}",
                                "{?f}",
                                "{f}",
                                "{?f}",
                                "{?d}",
                            }, "\t") ++ "\n",
                            .{
                                repo_owner,
                                repo_name,
                                pr.number,
                                commit.oid,
                                check_suite.app.name,
                                check_suite.status,
                                check_suite.conclusion,
                                check_run.name,
                                check_run.status,
                                check_run.conclusion,
                                check_run.startedAt,
                                check_run.completedAt,
                                if (check_run_ns) |c| @divFloor(c, std.time.ns_per_s) else null,
                            },
                        );
                        try stdout_w.flush();
                    }
                }
            }

            try refreshMetrics(allocator, metrics, db_conn);
            try metrics.write(stdout_w);
        }
    }
}

fn refreshMetrics(allocator: std.mem.Allocator, metrics: *Metrics, db_conn: zqlite.Conn) !void {
    {
        var rows = try Db.queries.pullRequestCountGroupedByRepoAndState.queryIterator(allocator, db_conn, .{});
        errdefer rows.deinit();

        while (try rows.next()) |row| {
            defer zqlite_typed.freeStructFromRow(@TypeOf(row), allocator, row);
            try metrics.pull_requests.set(.{
                .repo = row.repo,
                .state = std.meta.stringToEnum(api.types.PullRequestState, row.state).?,
            }, @intCast(row.count));
        }

        try rows.deinitErr();
    }

    {
        var rows = try Db.queries.checkRunCountGroupedByRepoAndState.queryIterator(allocator, db_conn, .{});
        errdefer rows.deinit();

        while (try rows.next()) |row| {
            defer zqlite_typed.freeStructFromRow(@TypeOf(row), allocator, row);
            try metrics.check_runs.set(.{
                .repo = row.repo,
                .state = std.meta.stringToEnum(Metrics.CheckState, row.state).?,
            }, @intCast(row.count));
        }

        try rows.deinitErr();
    }

    {
        var rows = try Db.queries.timeToFix.queryIterator(allocator, db_conn, .{});
        errdefer rows.deinit();

        while (try rows.next()) |row| {
            defer zqlite_typed.freeStructFromRow(@TypeOf(row), allocator, row);
            try metrics.time_to_fix.observe(.{ .repo = row.repo }, @intCast(row.time_to_fix_seconds));
        }

        try rows.deinitErr();
    }
}

test {
    std.testing.refAllDecls(@This());
}
