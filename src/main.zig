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

        const defaults = .{
            .db = "github-checks-stats.sqlite",
        };

        pub const meta = .{
            .usage_summary = "[OPTION]... <serve|scan|watch> [VERB_OPTION]... [REPO]...",
            .full_text =
            \\Collect statistics about GitHub Checks
            \\
            \\serve: Serve metrics, do not scan.
            \\scan:  Scan once and then exit.
            \\watch: Scan in a loop.
            ,
            .option_docs = .{
                .db = "path to state database (default: " ++ defaults.db ++ ")",

                .@"user-agent" = Common.meta.option_docs.@"user-agent",
                .@"token-file" = Common.meta.option_docs.@"token-file",
                .historical = Common.meta.option_docs.historical,
                .@"metrics-listen" = Common.meta.option_docs.@"metrics-listen",
            },
        };

        const Common = struct {
            @"user-agent": ?[]const u8 = @This().defaults.@"user-agent",
            @"token-file": ?[]const u8 = @This().defaults.@"token-file",
            historical: ?bool = @This().defaults.historical,
            @"metrics-listen": ?[]const u8 = @This().defaults.@"metrics-listen",

            pub const defaults = .{
                .@"user-agent" = null,
                .@"token-file" = null,
                .historical = null,
                .@"metrics-listen" = null,
            };

            pub const meta = .{
                .option_docs = .{
                    .@"user-agent" = "User-Agent header to send, may be needed to authenticate as a GitHub App",
                    .@"token-file" = "file to read a token from to authorize with",
                    .historical = "scan only closed instead of open PRs (default: true in scan mode, false otherwise)",
                    .@"metrics-listen" = "listen address and port or unix domain socket after `unix:` prefix to bind for metrics",
                },
            };
        };
    };

    const Verbs = union(enum) {
        serve: struct {
            @"metrics-listen": @FieldType(Options.Common, "metrics-listen") = Options.Common.defaults.@"metrics-listen",

            pub const meta = .{
                .option_docs = .{
                    .@"metrics-listen" = Options.Common.meta.option_docs.@"metrics-listen" ++ " (required)",
                },
            };
        },
        scan: struct {
            @"user-agent": @FieldType(Options.Common, "user-agent") = Options.Common.defaults.@"user-agent",
            @"token-file": @FieldType(Options.Common, "token-file") = Options.Common.defaults.@"token-file",
            historical: @FieldType(Options.Common, "historical") = Options.Common.defaults.historical,
            @"metrics-listen": @FieldType(Options.Common, "metrics-listen") = Options.Common.defaults.@"metrics-listen",

            pub const meta = .{
                .option_docs = Options.Common.meta.option_docs,
            };
        },
        watch: struct {
            @"user-agent": @FieldType(Options.Common, "user-agent") = Options.Common.defaults.@"user-agent",
            @"token-file": @FieldType(Options.Common, "token-file") = Options.Common.defaults.@"token-file",
            historical: @FieldType(Options.Common, "historical") = Options.Common.defaults.historical,
            @"metrics-listen": @FieldType(Options.Common, "metrics-listen") = Options.Common.defaults.@"metrics-listen",

            interval: u32 = defaults.interval,

            const defaults = .{
                .interval = std.time.s_per_hour,
            };

            pub const meta = .{
                .option_docs = .{
                    .@"user-agent" = Options.Common.meta.option_docs.@"user-agent",
                    .@"token-file" = Options.Common.meta.option_docs.@"token-file",
                    .historical = Options.Common.meta.option_docs.historical,
                    .@"metrics-listen" = Options.Common.meta.option_docs.@"metrics-listen",

                    .interval = std.fmt.comptimePrint("seconds to sleep between iterations (default: {d})", .{defaults.interval}),
                },
            };
        },
    };

    const options = options: {
        const result = args.parseWithVerbForCurrentProcess(Options, Verbs, init, .print);

        const invalid = if (result) |options| invalid: {
            if (options.verb == null) break :invalid true;

            switch (options.verb.?) {
                .serve => |serve| {
                    if (options.positionals.len != 0) {
                        std.log.err("serve mode expects no positional arguments but received {d}", .{options.positionals.len});
                        break :invalid true;
                    }

                    if (serve.@"metrics-listen" == null) {
                        std.log.err("--metrics-listen is required in serve mode", .{});
                        break :invalid true;
                    }
                },
                .scan, .watch => {
                    if (options.positionals.len == 0) break :invalid true;
                },
            }

            break :invalid false;
        } else |err| switch (err) {
            error.InvalidArguments => true,
            else => |e| return e,
        };

        if (invalid) {
            try args.printHelpWithVerb(Options, Verbs, "github-checks-stats", stderr_w);
            try stderr_w.flush();

            std.process.exit(1);
        }

        break :options try result;
    };
    defer options.deinit();

    try start(init.gpa, init.io, init.environ_map, switch (options.verb.?) {
        .serve => |serve| .{ .serve = .{
            .db = options.options.db,
            .metrics_listen = serve.@"metrics-listen".?,
        } },
        .scan => |scan| .{ .scan = .{
            .db = options.options.db,
            .user_agent = scan.@"user-agent",
            .token_file = scan.@"token-file",
            .historical = scan.historical orelse true,
            .metrics_listen = scan.@"metrics-listen",
            .repos = options.positionals,
        } },
        .watch => |watch| .{ .watch = .{
            .db = options.options.db,
            .user_agent = watch.@"user-agent",
            .token_file = watch.@"token-file",
            .historical = watch.historical orelse false,
            .metrics_listen = watch.@"metrics-listen",
            .repos = options.positionals,
            .interval_s = watch.interval,
        } },
    });
}

pub const Config = union(enum) {
    serve: Serve,
    scan: @This().Scan,
    watch: Watch,

    pub const Serve = struct {
        db: [:0]const u8 = "github-checks-stats.sqlite",
        metrics_listen: []const u8,
    };

    pub const Scan = utils.meta.MergedStructs(&.{
        utils.meta.SubStruct(Serve, std.enums.EnumSet(std.meta.FieldEnum(Serve)).initFull().differenceWith(.initMany(&.{
            .metrics_listen,
        }))),
        struct {
            user_agent: ?[]const u8 = null,
            token_file: ?[]const u8 = null,
            historical: bool,
            metrics_listen: ?[]const u8 = null,
            repos: []const []const u8,
        },
    });

    pub const Watch = utils.meta.MergedStructs(&.{ @This().Scan, struct {
        interval_s: u32 = std.time.s_per_hour,
    } });
};

pub fn start(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
    config: Config,
) !void {
    switch (config) {
        inline else => |mode| std.log.info("database: {s}", .{mode.db}),
    }
    switch (config) {
        .serve => {},
        inline .scan, .watch => |mode| if (mode.user_agent) |user_agent| std.log.info("User-Agent: {s}", .{user_agent}),
    }
    switch (config) {
        .serve => {},
        inline .scan, .watch => |mode| if (mode.token_file) |token_file|
            std.log.info("token file: {s}", .{token_file})
        else
            std.log.warn("no token file, likely to hit rate limit quickly", .{}),
    }
    switch (config) {
        .serve => {},
        inline .scan, .watch => |mode| std.log.info("historical: {any}", .{mode.historical}),
    }
    if (switch (config) {
        .serve => |mode| mode.metrics_listen,
        inline .scan, .watch => |mode| if (mode.metrics_listen) |addr| addr else null,
    }) |addr|
        std.log.info("serving metrics on {s}/metrics", .{addr});

    var db = try Db.init(allocator, io, .{ .path = switch (config) {
        inline else => |mode| mode.db,
    } });
    defer db.deinit();

    const db_conn = try db.pool.acquire(io);
    defer db.pool.release(io, db_conn);

    var metrics = if (switch (config) {
        inline else => |mode| mode.metrics_listen,
    } != null) try Metrics.init(allocator, io, .{
        .prefix = "github_",
    }) else null;
    defer if (metrics) |*m| m.deinit();

    var metrics_scrape = if (switch (config) {
        inline else => |mode| mode.metrics_listen,
    } != null) Metrics.Scrape{
        .allocator = allocator,
    } else null;
    defer if (metrics_scrape) |*ms| ms.deinit();

    var server = if (switch (config) {
        inline else => |mode| mode.metrics_listen,
    }) |metrics_listen|
        try httpz.Server(ServerContext).init(io, allocator, .{
            .address = if (std.mem.cutPrefix(u8, metrics_listen, "unix:")) |socket_path|
                .{ .unix = socket_path }
            else
                .{ .ip = try .parseLiteral(metrics_listen) },
        }, .{
            .io = io,
            .metrics = &metrics.?,
            .metrics_scrape = &metrics_scrape.?,
            .db_pool = db.pool,
        })
    else
        null;
    defer if (server) |*s| s.deinit();

    const server_thread = if (server) |*s| server_thread: {
        var router = try s.router(.{});
        router.get("/metrics", serveGetMetrics, .{});

        break :server_thread try s.listenInNewThread();
    } else null;
    defer if (config != .serve) if (server_thread) |st| {
        server.?.stop();
        st.join();
    };

    if (config == .serve) {
        server_thread.?.join();
        return;
    }

    var client = try api.Client.init(
        allocator,
        io,
        environ_map,
        switch (config) {
            .serve => unreachable,
            inline else => |mode| mode.user_agent,
        },
        if (switch (config) {
            .serve => unreachable,
            inline else => |mode| mode.token_file,
        }) |token_file| token: {
            var buffer: [1024]u8 = undefined;
            const token = try std.Io.Dir.cwd().readFile(io, token_file, &buffer);
            break :token std.mem.trim(u8, token, " \t\n\r");
        } else null,
    );
    defer client.deinit();

    switch (config) {
        .serve => unreachable,
        .scan => {
            var scan: Scan = .{
                .client = &client,
                .db_conn = db_conn,
                .repos = switch (config) {
                    .serve => unreachable,
                    inline .scan, .watch => |mode| mode.repos,
                },
                .historical = switch (config) {
                    .serve => unreachable,
                    inline else => |mode| mode.historical,
                },
            };
            while (true) {
                scan.scan(allocator) catch |err| switch (err) {
                    error.RateLimited => {
                        const duration = std.Io.Timestamp.now(io, .real).durationTo(client.rate_limit_reset.?);
                        std.log.warn("rate limited; continuing in {f}", .{duration});
                        try std.Io.sleep(io, duration, .real);
                        continue;
                    },
                    else => |e| return e,
                };
                break;
            }
        },
        .watch => |watch| {
            var scan: Scan = .{
                .client = &client,
                .db_conn = db_conn,
                .repos = switch (config) {
                    .serve => unreachable,
                    inline .scan, .watch => |mode| mode.repos,
                },
                .historical = switch (config) {
                    .serve => unreachable,
                    inline else => |mode| mode.historical,
                },
            };
            const interval = std.Io.Duration.fromSeconds(watch.interval_s);
            while (true) {
                scan.scan(allocator) catch |err| switch (err) {
                    error.RateLimited => {
                        const duration = std.Io.Timestamp.now(io, .real).durationTo(client.rate_limit_reset.?);
                        std.log.warn("rate limited; continuing in {f}", .{duration});
                        try std.Io.sleep(io, duration, .real);
                        continue;
                    },
                    else => |e| return e,
                };
                std.log.info("next scan in {f}", .{interval});
                try std.Io.sleep(io, interval, .awake);
            }
        },
    }
}

const Scan = struct {
    client: *api.Client,
    db_conn: zqlite.Conn,
    repos: []const []const u8,
    historical: bool,

    repo_idx: usize = 0,
    prss_idx: usize = 0,
    prs_idx: usize = 0,
    commits_idx: usize = 0,
    check_suites_idx: usize = 0,

    pub fn scan(self: *@This(), allocator: std.mem.Allocator) !void {
        for (self.repos[self.repo_idx..]) |repo_full| {
            const repo_owner, const repo_name = repo: {
                errdefer std.log.err("malformed repository \"{s}\", must be of form \"foo/bar\"", .{repo_full});
                var iter = std.mem.splitScalar(u8, repo_full, '/');
                const owner = iter.next() orelse return error.MalformedRepository;
                const name = iter.next() orelse return error.MalformedRepository;
                std.debug.assert(iter.next() == null);
                break :repo .{ owner, name };
            };

            std.log.info("/{s}/{s}: fetching repository…", .{ repo_owner, repo_name });

            const repo = try api.queries.fetchRepoByFullName(allocator, self.client, repo_owner, repo_name);
            defer repo.deinit();

            try Db.queries.Repository.upsert.exec(self.db_conn, .{ repo.value.id, repo.value.owner.login, repo.value.name });

            std.log.info("/{s}/{s}: scanning for pull requests…", .{ repo_owner, repo_name });

            const prs_open = try api.queries.fetchPullRequestsByRepo(allocator, self.client, repo.value.owner.login, repo.value.name, if (self.historical) null else &.{.OPEN});
            defer prs_open.deinit();

            // Some PRs could have been closed since we last fetched
            // and are hence not included in the response from GitHub.
            // They are still open in our database though,
            // so fetch them again to update them in the database.
            const prs_closed = if (!self.historical) prs_closed: {
                var prs_db_open = try Db.queries.PullRequest.SelectByRepoAndStates(
                    &.{.id},
                    &.{.OPEN},
                ).queryIterator(self.db_conn, .{
                    repo.value.owner.login,
                    repo.value.name,
                });
                errdefer prs_db_open.deinit();

                var prs_closed_ids = std.ArrayList(api.types.Id).empty;
                defer {
                    for (prs_closed_ids.items) |id| allocator.free(id);
                    prs_closed_ids.deinit(allocator);
                }

                while (try prs_db_open.next(allocator)) |pr_db_open| {
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

                break :prs_closed try api.queries.fetchPullRequestsByIds(allocator, self.client, prs_closed_ids.items);
            } else null;
            defer if (prs_closed) |pr| pr.deinit();

            const prss = [_][]const api.types.PullRequest{
                prs_open.value,
                if (prs_closed) |pr| pr.value else &.{},
            };

            for (prss[self.prss_idx..], self.prss_idx..) |prs, prss_idx|
                for (prs[(if (prss_idx == self.prss_idx) self.prs_idx else 0)..]) |pr|
                    try Db.queries.PullRequest.upsert.exec(self.db_conn, .{ pr.id, repo.value.id, pr.number, @tagName(pr.state) });

            const prs_count = prs_count: {
                var count: usize = 0;
                for (prss) |prs|
                    count += prs.len;
                break :prs_count count;
            };
            for (prss[self.prss_idx..], self.prss_idx..) |prs, prss_idx| {
                const prev_prs_count = prev_prs_count: {
                    var count: usize = 0;
                    for (0..prss_idx) |i|
                        count += prss[i].len;
                    break :prev_prs_count count;
                };
                for (prs[self.prs_idx..]) |pr| {
                    std.log.info("{s}: scanning for commits…", .{pr.resourcePath});

                    const commits = try api.queries.fetchCommitsByPullRequestId(allocator, self.client, pr.id);
                    defer commits.deinit();

                    for (commits.value[self.commits_idx..]) |commit|
                        try Db.queries.Commit.upsert.exec(self.db_conn, .{ commit.id, commit.oid });

                    for (commits.value[self.commits_idx..]) |commit| {
                        std.log.info("{s}: scanning for check suites…", .{commit.resourcePath});

                        const check_suites = try api.queries.fetchCheckSuitesByCommitId(allocator, self.client, commit.id);
                        defer check_suites.deinit();

                        for (check_suites.value[self.check_suites_idx..]) |check_suite| {
                            try Db.queries.App.upsert.exec(self.db_conn, .{
                                check_suite.app.id,
                                check_suite.app.slug,
                                check_suite.app.name,
                            });

                            {
                                const created_at = try std.fmt.allocPrint(allocator, "{f}", .{check_suite.createdAt});
                                defer allocator.free(created_at);

                                const status = try std.fmt.allocPrint(allocator, "{f}", .{check_suite.status});
                                defer allocator.free(status);

                                try Db.queries.CheckSuite.upsert.exec(self.db_conn, .{
                                    check_suite.id,
                                    repo.value.id,
                                    commit.id,
                                    check_suite.app.id,
                                    created_at,
                                    status,
                                    if (check_suite.conclusion) |c| @tagName(c) else null,
                                });
                            }

                            std.log.info("{s}: scanning for check runs…", .{check_suite.resourcePath});

                            const check_runs = try api.queries.fetchCheckRunsByCheckSuiteId(allocator, self.client, check_suite.id);
                            defer check_runs.deinit();

                            for (check_runs.value) |check_run| {
                                const started_at = try std.fmt.allocPrint(allocator, "{f}", .{check_run.startedAt});
                                defer allocator.free(started_at);

                                const completed_at = if (check_run.completedAt) |c| try std.fmt.allocPrint(allocator, "{f}", .{c}) else null;
                                defer if (completed_at) |c| allocator.free(c);

                                try Db.queries.CheckRun.upsert.exec(self.db_conn, .{
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

                            for (check_runs.value, 0..) |check_run, check_runs_idx| {
                                const check_run_ns = if (check_run.completedAt) |completedAt| duration: {
                                    std.debug.assert(check_run.startedAt.inner.offset == completedAt.inner.offset);
                                    break :duration completedAt.inner.instant().timestamp - check_run.startedAt.inner.instant().timestamp;
                                } else null;

                                std.log.info("{s}: {?f}", .{
                                    check_run.resourcePath,
                                    if (check_run_ns) |c| std.Io.Duration.fromNanoseconds(@intCast(c)) else null,
                                });

                                std.log.info("{s}: {d}/{d} check runs scanned", .{ check_suite.resourcePath, check_runs_idx + 1, check_runs.value.len });
                            }

                            self.check_suites_idx += 1;
                            std.log.info("{s}: {d}/{d} check suites scanned", .{ commit.resourcePath, self.check_suites_idx, check_suites.value.len });
                        } else self.check_suites_idx = 0;

                        self.commits_idx += 1;
                        std.log.info("{s}: {d}/{d} commits scanned", .{ pr.resourcePath, self.commits_idx, commits.value.len });
                    } else self.commits_idx = 0;

                    self.prs_idx += 1;
                    std.log.info("/{s}/{s}: {d}/{d} PRs scanned", .{ repo_owner, repo_name, prev_prs_count + self.prs_idx, prs_count });
                } else self.prs_idx = 0;

                self.prss_idx += 1;
            } else self.prss_idx = 0;

            self.repo_idx += 1;
            std.log.info("{d}/{d} repositories scanned", .{ self.repo_idx, self.repos.len });
        } else self.repo_idx = 0;
    }
};

const ServerContext = struct {
    io: std.Io,
    metrics: *Metrics,
    metrics_scrape: *Metrics.Scrape,
    db_pool: *zqlite.Pool,
};

fn serveGetMetrics(ctx: ServerContext, req: *httpz.Request, res: *httpz.Response) !void {
    const db_conn = try ctx.db_pool.acquire(ctx.io);
    defer ctx.db_pool.release(ctx.io, db_conn);

    try ctx.metrics_scrape.refreshMetrics(req.arena, ctx.io, ctx.metrics, db_conn);

    res.content_type = .TEXT;
    try ctx.metrics.write(res.writer());
}

test {
    std.testing.refAllDecls(@This());
}
