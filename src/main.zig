const std = @import("std");
const builtin = @import("builtin");

const args = @import("args");
const httpz = @import("httpz");
const utils = @import("utils");
const zeit = @import("zeit");
const zqlite = @import("zqlite");
const zqlite_typed = @import("zqlite-typed");
const zretry = @import("zretry");

const api = @import("api.zig");
const Db = @import("Db.zig");
const Metrics = @import("Metrics.zig");

pub fn main(init: std.process.Init) !void {
    const Options = struct {
        db: @FieldType(Config.Serve, "db") = std.meta.fieldInfo(Config.Serve, .db).defaultValue().?,

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
                .db = "path to state database (default: " ++ std.meta.fieldInfo(@This(), .db).defaultValue().? ++ ")",
            },
        };

        const meta_common = .{
            .option_docs = .{
                .@"scan-expiry" = "duration in seconds after which to delete interrupted scans",
                .@"user-agent" = "User-Agent header to send, may be needed to authenticate as a GitHub App",
                .@"token-file" = "file to read a token from to authorize with",
                .historical = "scan only closed instead of open PRs (default: true in scan mode, false otherwise)",
                .@"metrics-listen" = "listen address and port or unix domain socket after `unix:` prefix to bind for metrics",
            },
        };
    };

    const Verbs = union(enum) {
        serve: struct {
            @"metrics-listen": ?@FieldType(Config.Serve, "metrics_listen") = std.meta.fieldInfo(Config.Serve, .metrics_listen).defaultValue(),

            pub const meta = .{
                .option_docs = .{
                    .@"metrics-listen" = Options.meta_common.option_docs.@"metrics-listen" ++ " (required)",
                },
            };
        },
        scan: struct {
            @"scan-expiry": @FieldType(Config.Scan, "scan_expiry_s") = std.meta.fieldInfo(Config.Scan, .scan_expiry_s).defaultValue().?,
            @"user-agent": @FieldType(Config.Scan, "user_agent") = std.meta.fieldInfo(Config.Scan, .user_agent).defaultValue().?,
            @"token-file": @FieldType(Config.Scan, "token_file") = std.meta.fieldInfo(Config.Scan, .token_file).defaultValue().?,
            historical: ?@FieldType(Config.Scan, "historical") = std.meta.fieldInfo(Config.Scan, .historical).defaultValue(),
            @"metrics-listen": @FieldType(Config.Scan, "metrics_listen") = std.meta.fieldInfo(Config.Scan, .metrics_listen).defaultValue().?,

            pub const meta = .{
                .option_docs = Options.meta_common.option_docs,
            };
        },
        watch: struct {
            @"scan-expiry": @FieldType(Config.Watch, "scan_expiry_s") = std.meta.fieldInfo(Config.Watch, .scan_expiry_s).defaultValue().?,
            @"user-agent": @FieldType(Config.Watch, "user_agent") = std.meta.fieldInfo(Config.Watch, .user_agent).defaultValue().?,
            @"token-file": @FieldType(Config.Watch, "token_file") = std.meta.fieldInfo(Config.Watch, .token_file).defaultValue().?,
            historical: ?@FieldType(Config.Watch, "historical") = std.meta.fieldInfo(Config.Watch, .historical).defaultValue(),
            @"metrics-listen": @FieldType(Config.Watch, "metrics_listen") = std.meta.fieldInfo(Config.Watch, .metrics_listen).defaultValue().?,

            interval: @FieldType(Config.Watch, "interval_s") = std.meta.fieldInfo(Config.Watch, .interval_s).defaultValue().?,

            pub const meta = .{
                .option_docs = .{
                    .@"scan-expiry" = Options.meta_common.option_docs.@"scan-expiry",
                    .@"user-agent" = Options.meta_common.option_docs.@"user-agent",
                    .@"token-file" = Options.meta_common.option_docs.@"token-file",
                    .historical = Options.meta_common.option_docs.historical,
                    .@"metrics-listen" = Options.meta_common.option_docs.@"metrics-listen",

                    .interval = std.fmt.comptimePrint("seconds to sleep between iterations (default: {d})", .{std.meta.fieldInfo(@This(), .interval).defaultValue().?}),
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
            var stderr_buffer: [1024]u8 = undefined;
            var stderr = std.Io.File.stderr().writer(init.io, &stderr_buffer);
            const stderr_w = &stderr.interface;

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
            .scan_expiry_s = scan.@"scan-expiry",
            .user_agent = scan.@"user-agent",
            .token_file = scan.@"token-file",
            .historical = scan.historical orelse true,
            .metrics_listen = scan.@"metrics-listen",
            .repos = options.positionals,
        } },
        .watch => |watch| .{ .watch = .{
            .db = options.options.db,
            .scan_expiry_s = watch.@"scan-expiry",
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
            scan_expiry_s: ?u32 = std.time.s_per_day,
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

    switch (config) {
        .serve => {},
        inline .scan, .watch => |mode| if (mode.scan_expiry_s) |scan_expiry_s|
            try Db.queries.Scan.delete_expired.exec(allocator, db_conn, .{scan_expiry_s}),
    }

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

    var scan: Scan = .{
        .allocator = allocator,
        .repos = switch (config) {
            .serve => unreachable,
            inline .scan, .watch => |mode| mode.repos,
        },
        .historical = switch (config) {
            .serve => unreachable,
            inline else => |mode| mode.historical,
        },
    };
    defer scan.deinit();

    try scan.loadFromDb(db_conn);

    const retry_opts = zretry.RetryOptions{
        .io = io,
        .retry_if = struct {
            fn retryIf(err: anyerror) bool {
                return utils.meta.errorSetContains(api.Client.QueryError, err);
            }
        }.retryIf,
    };

    switch (config) {
        .serve => unreachable,
        .scan => while (true) {
            scan.scan(&client, db_conn, retry_opts) catch |err| switch (err) {
                error.RateLimited => {
                    const duration = std.Io.Timestamp.now(io, .real).durationTo(client.rate_limit_reset.?);
                    std.log.warn("rate limited; continuing in {f}", .{duration});
                    try std.Io.sleep(io, duration, .real);
                    continue;
                },
                else => |e| return e,
            };
            break;
        },
        .watch => |watch| {
            const interval = std.Io.Duration.fromSeconds(watch.interval_s);
            while (true) {
                scan.scan(&client, db_conn, retry_opts) catch |err| switch (err) {
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

/// Stateful scan that can continue where it left off.
const Scan = struct {
    allocator: std.mem.Allocator,

    repos: []const []const u8,
    historical: bool,

    progress: Progress = .{},

    const Progress = struct {
        repos_idx: usize = 0,
        prss_idx: usize = 0,
        pr: Anchor = .{},
        commit: Anchor = .{},
        check_suite: Anchor = .{},

        pub fn deinit(self: *const @This(), allocator: std.mem.Allocator) void {
            inline for (.{ "pr", "commit", "check_suite" }) |anchor|
                @field(self, anchor).deinit(allocator);
        }

        /// ID of the last item at each level that was processed to completion.
        ///
        /// GitHub GraphQL doesn't guarantee stable cursors, and numeric list
        /// positions can shift between calls (items closing, force-pushes, new
        /// items appended in the middle of a list). Anchoring by ID makes resume
        /// robust: if the anchored item is still there we resume right after it;
        /// if it has vanished, we log a warning and restart the level.
        pub const Anchor = struct {
            id: ?api.types.Id = null,

            pub fn deinit(self: @This(), allocator: std.mem.Allocator) void {
                if (self.id) |id| allocator.free(id);
            }

            pub fn set(self: *@This(), allocator: std.mem.Allocator, value: api.types.Id) !void {
                const new = try allocator.dupe(u8, value);
                if (self.id) |old| allocator.free(old);
                self.id = new;
            }

            pub fn clear(self: *@This(), allocator: std.mem.Allocator) void {
                if (self.id) |old| allocator.free(old);
                self.id = null;
            }

            pub fn find(
                self: @This(),
                /// An API type. Must have an `id` field.
                comptime Node: type,
                nodes: []const Node,
            ) ?usize {
                if (self.id) |id|
                    for (nodes, 0..) |node, idx|
                        if (std.mem.eql(u8, node.id, id)) return idx;
                return null;
            }

            /// Returns the next index to process.
            /// If the anchor is not found returns zero and logs a warning.
            pub fn findNextLogVanished(self: @This(), comptime Node: type, nodes: []const Node) usize {
                if (self.find(Node, nodes)) |idx|
                    return idx + 1;

                if (self.id) |id|
                    std.log.warn(@typeName(Node) ++ " anchor {s} not found, restarting from the beginning", .{id});

                return 0;
            }
        };
    };

    pub fn deinit(self: @This()) void {
        self.progress.deinit(self.allocator);
    }

    pub fn loadFromDb(self: *@This(), db_conn: zqlite.Conn) !void {
        if (try Db.queries.Scan.SelectById(.initMany(&.{
            .repos_idx,
            .prss_idx,
            .pr,
            .commit,
            .check_suite,
            .updated_at,
        })).query(self.allocator, db_conn, .{
            .{ .items = self.repos },
            self.historical,
        })) |db_scan| {
            self.progress.repos_idx = @intCast(db_scan.repos_idx);
            self.progress.prss_idx = @intCast(db_scan.prss_idx);

            // Couldn't help myself, had to prematurely optimize this to prevent allocations.
            const optimized = true;

            defer if (optimized) {
                // Do not free `db_scan` because we move ownership of all of its allocated fields into `scan`.
            } else zqlite_typed.freeStructFromRow(@TypeOf(db_scan), self.allocator, db_scan);

            inline for (.{ "pr", "commit", "check_suite" }) |field| {
                const anchor = &@field(self.progress, field);
                // The DB schema and Zig field names are meant to stay in sync.
                const db_anchor = @field(db_scan, field);

                if (optimized)
                    anchor.id = db_anchor
                else if (db_anchor) |db_a|
                    try anchor.set(self.allocator, db_a)
                else
                    anchor.clear(self.allocator);
            }

            std.log.info("continuing interrupted scan from {f} at repo={d}/{d} prs_batch={d} pr={?s} commit={?s} check_suite={?s}", .{
                db_scan.updated_at,
                self.progress.repos_idx + 1,
                self.repos.len,
                self.progress.prss_idx + 1,
                self.progress.pr.id,
                self.progress.commit.id,
                self.progress.check_suite.id,
            });
        }
    }

    fn persist(self: @This(), db_conn: zqlite.Conn) !void {
        if (self.progress.repos_idx == 0 and
            self.progress.prss_idx == 0 and
            self.progress.pr.id == null and
            self.progress.commit.id == null and
            self.progress.check_suite.id == null)
            try Db.queries.Scan.delete.exec(self.allocator, db_conn, .{
                .{ .items = self.repos },
                self.historical,
            })
        else
            try Db.queries.Scan.upsert.exec(self.allocator, db_conn, .{
                .{ .items = self.repos },
                self.historical,
                @intCast(self.progress.repos_idx),
                @intCast(self.progress.prss_idx),
                self.progress.pr.id,
                self.progress.commit.id,
                self.progress.check_suite.id,
            });
    }

    pub fn scan(self: *@This(), client: *api.Client, db_conn: zqlite.Conn, retry_opts: zretry.RetryOptions) !void {
        for (self.repos[self.progress.repos_idx..], self.progress.repos_idx..) |repo_full, repos_idx| {
            const repo_owner, const repo_name = repo: {
                errdefer std.log.err("malformed repository \"{s}\", must be of form \"foo/bar\"", .{repo_full});
                var iter = std.mem.splitScalar(u8, repo_full, '/');
                const owner = iter.next() orelse return error.MalformedRepository;
                const name = iter.next() orelse return error.MalformedRepository;
                std.debug.assert(iter.next() == null);
                break :repo .{ owner, name };
            };

            std.log.info("/{s}/{s}: fetching repository…", .{ repo_owner, repo_name });

            const repo = try zretry.zretry(api.queries.fetchRepoByFullName, .{
                self.allocator,
                client,
                repo_owner,
                repo_name,
            }, retry_opts);
            defer repo.deinit();

            try Db.queries.Repository.upsert.exec(self.allocator, db_conn, .{ repo.value.id, repo.value.owner.login, repo.value.name });

            std.log.info("/{s}/{s}: scanning for pull requests…", .{ repo_owner, repo_name });

            const prs_open = try zretry.zretry(api.queries.fetchPullRequestsByRepo, .{
                self.allocator,
                client,
                repo.value.owner.login,
                repo.value.name,
                if (self.historical) null else @as([]const api.types.PullRequestState, &.{.OPEN}),
            }, retry_opts);
            defer prs_open.deinit();

            // Some PRs could have been closed since we last fetched
            // and are hence not included in the response from GitHub.
            // They are still open in our database though,
            // so fetch them again to update them in the database.
            const prs_closed = if (!self.historical) prs_closed: {
                var prs_db_open = try Db.queries.PullRequest.SelectByRepoAndStates(
                    .initOne(.id),
                    .initOne(.OPEN),
                ).queryIterator(self.allocator, db_conn, .{
                    repo.value.owner.login,
                    repo.value.name,
                });
                errdefer prs_db_open.deinit();

                var prs_closed_ids = std.ArrayList(api.types.Id).empty;
                defer {
                    for (prs_closed_ids.items) |id| self.allocator.free(id);
                    prs_closed_ids.deinit(self.allocator);
                }

                while (try prs_db_open.next(self.allocator)) |pr_db_open| {
                    defer zqlite_typed.freeStructFromRow(@TypeOf(pr_db_open), self.allocator, pr_db_open);

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
                        const id = try self.allocator.dupe(u8, pr_db_open.id);
                        errdefer self.allocator.free(id);

                        try prs_closed_ids.append(self.allocator, id);
                    }
                }

                try prs_db_open.deinitErr();

                break :prs_closed try zretry.zretry(api.queries.fetchPullRequestsByIds, .{
                    self.allocator,
                    client,
                    prs_closed_ids.items,
                }, retry_opts);
            } else null;
            defer if (prs_closed) |pr| pr.deinit();

            const prss = [_][]const api.types.PullRequest{
                prs_open.value,
                if (prs_closed) |pr| pr.value else &.{},
            };

            for (prss[self.progress.prss_idx..]) |prs| {
                const prs_start_idx = if (self.progress.pr.find(api.types.PullRequest, prs)) |idx| idx + 1 else 0;
                for (prs[prs_start_idx..]) |pr|
                    try Db.queries.PullRequest.upsert.exec(self.allocator, db_conn, .{ pr.id, repo.value.id, pr.number, pr.state });
            }

            const prs_count = prs_count: {
                var count: usize = 0;
                for (prss) |prs|
                    count += prs.len;
                break :prs_count count;
            };

            for (prss[self.progress.prss_idx..], self.progress.prss_idx..) |prs, prss_idx| {
                const prev_prs_count = prev_prs_count: {
                    var count: usize = 0;
                    for (0..prss_idx) |i|
                        count += prss[i].len;
                    break :prev_prs_count count;
                };

                const prs_start_idx = self.progress.pr.findNextLogVanished(api.types.PullRequest, prs);
                for (prs[prs_start_idx..], prs_start_idx..) |pr, prs_idx| {
                    std.log.info("{s}: scanning for commits…", .{pr.resourcePath});

                    const commits = try zretry.zretry(api.queries.fetchCommitsByPullRequestId, .{
                        self.allocator,
                        client,
                        pr.id,
                    }, retry_opts);
                    defer commits.deinit();

                    const commits_start_idx = self.progress.commit.findNextLogVanished(api.types.Commit, commits.value);

                    for (commits.value[commits_start_idx..]) |commit|
                        try Db.queries.Commit.upsert.exec(self.allocator, db_conn, .{ commit.id, commit.oid });

                    for (commits.value[commits_start_idx..], commits_start_idx..) |commit, commits_idx| {
                        std.log.info("{s}: scanning for check suites…", .{commit.resourcePath});

                        const check_suites = try zretry.zretry(api.queries.fetchCheckSuitesByCommitId, .{
                            self.allocator,
                            client,
                            commit.id,
                        }, retry_opts);
                        defer check_suites.deinit();

                        const check_suites_start_idx = self.progress.check_suite.findNextLogVanished(api.types.CheckSuite, check_suites.value);
                        for (check_suites.value[check_suites_start_idx..], check_suites_start_idx..) |check_suite, check_suites_idx| {
                            const scan_check_runs =
                                self.historical or
                                if (try Db.queries.CheckSuite.SelectById(.initMany(&.{.updated_at})).query(self.allocator, db_conn, .{check_suite.id})) |db_check_suite| scan_check_runs: {
                                    defer zqlite_typed.freeStructFromRow(@TypeOf(db_check_suite), self.allocator, db_check_suite);

                                    break :scan_check_runs check_suite.updatedAt.inner.compare(db_check_suite.updated_at.inner) != .equal;
                                } else true;

                            if (scan_check_runs) {
                                try Db.queries.App.upsert.exec(self.allocator, db_conn, .{
                                    check_suite.app.id,
                                    check_suite.app.slug,
                                    check_suite.app.name,
                                });

                                try Db.queries.CheckSuite.upsert.exec(self.allocator, db_conn, .{
                                    check_suite.id,
                                    repo.value.id,
                                    commit.id,
                                    check_suite.app.id,
                                    check_suite.createdAt,
                                    check_suite.updatedAt,
                                    check_suite.status,
                                    check_suite.conclusion,
                                });

                                std.log.info("{s}: scanning for check runs…", .{check_suite.resourcePath});

                                const check_runs = try zretry.zretry(api.queries.fetchCheckRunsByCheckSuiteId, .{
                                    self.allocator,
                                    client,
                                    check_suite.id,
                                }, retry_opts);
                                defer check_runs.deinit();

                                for (check_runs.value, 0..) |check_run, check_runs_idx| {
                                    try Db.queries.CheckRun.upsert.exec(self.allocator, db_conn, .{
                                        check_run.id,
                                        check_suite.id,
                                        check_run.name,
                                        check_run.startedAt,
                                        check_run.completedAt,
                                        check_run.externalId,
                                        check_run.status,
                                        check_run.conclusion,
                                    });

                                    std.log.info("{s}: {d}/{d} check runs scanned", .{ check_suite.resourcePath, check_runs_idx + 1, check_runs.value.len });
                                }
                            } else std.log.info("{s}: has not changed, skipping", .{check_suite.resourcePath});

                            try self.progress.check_suite.set(self.allocator, check_suite.id);
                            std.log.info("{s}: {d}/{d} check suites scanned", .{ commit.resourcePath, check_suites_idx + 1, check_suites.value.len });

                            try self.persist(db_conn);
                        } else self.progress.check_suite.clear(self.allocator);

                        try self.progress.commit.set(self.allocator, commit.id);
                        std.log.info("{s}: {d}/{d} commits scanned", .{ pr.resourcePath, commits_idx + 1, commits.value.len });
                    } else self.progress.commit.clear(self.allocator);

                    try self.progress.pr.set(self.allocator, pr.id);
                    std.log.info("/{s}/{s}: {d}/{d} PRs scanned", .{ repo_owner, repo_name, prev_prs_count + prs_idx + 1, prs_count });
                } else self.progress.pr.clear(self.allocator);

                self.progress.prss_idx += 1;
            } else self.progress.prss_idx = 0;

            self.progress.repos_idx += 1;
            std.log.info("{d}/{d} repositories scanned", .{ repos_idx + 1, self.repos.len });
        } else self.progress.repos_idx = 0;

        // All indices and anchors were just set to their zero value,
        // so persisting now will delete the scan from the DB.
        try self.persist(db_conn);
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
