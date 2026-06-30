const std = @import("std");
const builtin = @import("builtin");

const args = @import("args");
const httpz = @import("httpz");
const utils = @import("utils");
const zqlite = @import("zqlite");
const zqlite_typed = @import("zqlite-typed");

const api = @import("api.zig");
const Db = @import("Db.zig");
const Metrics = @import("Metrics.zig");

pub fn main(init: std.process.Init) !void {
    var stderr_buffer: [1024]u8 = undefined;
    var stderr = std.Io.File.stderr().writer(init.io, &stderr_buffer);
    const stderr_w = &stderr.interface;

    const Options = struct {
        db: [:0]const u8 = defaults.db,
        @"user-agent": ?[]const u8 = defaults.@"user-agent",
        @"token-file": ?[]const u8 = defaults.@"token-file",

        const defaults = .{
            .db = "github-checks-stats.sqlite",
            .@"user-agent" = null,
            .@"token-file" = null,
        };

        pub const meta = .{
            .usage_summary = "[OPTION]... <scan|watch> [VERB_OPTION]... REPO...",
            .full_text = "Collect statistics about GitHub Checks",
            .option_docs = .{
                .db = "path to state database (" ++ defaults.db ++ ")",
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
            interval: u32 = defaults.interval,
            @"metrics-listen": ?[]const u8 = defaults.@"metrics-listen",

            const defaults = .{
                .interval = 300,
                .@"metrics-listen" = null,
            };

            pub const meta = .{
                .option_docs = .{
                    .interval = std.fmt.comptimePrint("seconds to sleep between iterations ({d})", .{defaults.interval}),
                    .@"metrics-listen" = "listen address and port or unix domain socket after `unix:` prefix to bind for metrics",
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

    switch (options.verb.?) {
        .scan => try scan(init.gpa, &client, db_conn, options.positionals, true), // TODO retry on rate limit
        .watch => |watch| {
            var metrics = if (watch.@"metrics-listen" != null) try Metrics.init(init.gpa, init.io, .{}) else null;
            defer if (metrics) |*m| m.deinit();

            var server = if (watch.@"metrics-listen") |metrics_listen|
                try httpz.Server(ServerContext).init(init.io, init.gpa, .{
                    .address = if (std.mem.cutPrefix(u8, metrics_listen, "unix:")) |socket_path|
                        .{ .unix = socket_path }
                    else
                        .{ .ip = try .parseLiteral(metrics_listen) },
                }, .{
                    .io = init.io,
                    .metrics = &metrics.?,
                    .db_pool = db.pool,
                })
            else
                null;
            defer if (server) |*s| {
                s.stop();
                s.deinit();
            };

            const server_thread = if (server) |*s| server_thread: {
                var router = try s.router(.{});
                router.get("/metrics", serveGetMetrics, .{});

                break :server_thread try s.listenInNewThread();
            } else null;

            const interval = std.Io.Duration.fromSeconds(@as(i64, watch.interval));
            while (true) {
                scan(init.gpa, &client, db_conn, options.positionals, false) catch |err| switch (err) {
                    error.RateLimited => std.log.warn("rate limited; sleeping {f} before retry", .{interval}),
                    else => |e| return e,
                };
                try std.Io.sleep(init.io, interval, .awake);
            }

            if (server_thread) |st| st.join();
        },
    }
}

fn scan(
    allocator: std.mem.Allocator,
    client: *api.Client,
    db_conn: zqlite.Conn,
    repos: []const []const u8,
    historical: bool,
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

        const prs_open = try api.queries.fetchPullRequestsByRepo(allocator, client, repo.value.owner.login, repo.value.name, if (historical) null else &.{.OPEN});
        defer prs_open.deinit();

        // Some PRs could have been closed since we last fetched
        // and are hence not included in the response from GitHub.
        // They are still open in our database though,
        // so fetch them again to update them in the database.
        const prs_closed = if (!historical) prs_closed: {
            var prs_db_open = try Db.queries.PullRequest.SelectByRepoAndStates(
                &.{.id},
                &.{.OPEN},
            ).queryIterator(allocator, db_conn, .{
                repo.value.owner.login,
                repo.value.name,
            });
            errdefer prs_db_open.deinit();

            var prs_closed_ids = std.ArrayList(api.types.Id).empty;
            defer {
                for (prs_closed_ids.items) |id| allocator.free(id);
                prs_closed_ids.deinit(allocator);
            }

            while (try prs_db_open.next()) |pr_db_open| {
                defer zqlite_typed.freeStructFromRow(@TypeOf(pr_db_open), allocator, pr_db_open);

                // XXX It would be nicer if we could exclude
                // the open PRs that we just fetched from the API
                // from the DB query using the `NOT IN` operator
                // instead of filtering here, but that requires
                // passing a runtime-known list of parameters (not supported by zqlite_typed)
                // or serializing the list as JSON to pass into the query (ugly).
                for (prs_open.value) |pr_open| {
                    if (std.mem.eql(u8, pr_open.id, pr_db_open.id))
                        break; // PR is still open.
                } else {
                    const id = try allocator.dupe(u8, pr_db_open.id);
                    errdefer allocator.free(id);

                    try prs_closed_ids.append(allocator, id);
                }
            }

            try prs_db_open.deinitErr();

            break :prs_closed try api.queries.fetchPullRequestsByIds(allocator, client, prs_closed_ids.items);
        } else null;
        defer if (prs_closed) |pr| pr.deinit();

        for ([_][]const api.types.PullRequest{
            prs_open.value,
            if (prs_closed) |pr| pr.value else &.{},
        }) |prs|
            for (prs) |pr|
                try Db.queries.PullRequest.upsert.exec(db_conn, .{ pr.id, repo.value.id, pr.number, @tagName(pr.state) });

        for ([_][]const api.types.PullRequest{
            prs_open.value,
            if (prs_closed) |pr| pr.value else &.{},
        }) |prs|
            for (prs) |pr| {
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
                        }
                    }
                }
            };
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

const ServerContext = struct {
    io: std.Io,
    metrics: *Metrics,
    db_pool: *zqlite.Pool,
};

fn serveGetMetrics(ctx: ServerContext, req: *httpz.Request, res: *httpz.Response) !void {
    const db_conn = try ctx.db_pool.acquire(ctx.io);
    defer ctx.db_pool.release(ctx.io, db_conn);

    try refreshMetrics(req.arena, ctx.metrics, db_conn);

    res.content_type = .TEXT;
    try ctx.metrics.write(res.writer());
}

test {
    std.testing.refAllDecls(@This());
}
