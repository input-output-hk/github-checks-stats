const std = @import("std");
const builtin = @import("builtin");

const args = @import("args");
const httpz = @import("httpz");
const utils = @import("utils");
const m_ = @import("metrics");
const zeit = @import("zeit");
const zqlite = @import("zqlite");
const zqlite_typed = @import("zqlite-typed");
const zretry = @import("zretry");

const api = @import("api.zig");
const Db = @import("Db.zig");
const Metrics = @import("Metrics.zig");

const metric_opts = m_.RegistryOpts{
    .prefix = "github_",
};

pub fn main(init: std.process.Init) !void {
    const Options = struct {
        db: @FieldType(Config.Serve, "db") = std.meta.fieldInfo(Config.Serve, .db).defaultValue().?,

        pub const meta = .{
            .usage_summary = "[OPTION]... <serve|scan|watch> [VERB_OPTION]... [REPO[#BRANCH]]...",
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
                .@"history-limit" = std.fmt.comptimePrint("max depth of commits to walk (default: {d})", .{std.meta.fieldInfo(Config.Scan, .history_limit).defaultValue().?}),
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
            @"history-limit": @FieldType(Config.Scan, "history_limit") = std.meta.fieldInfo(Config.Scan, .history_limit).defaultValue().?,
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
            @"history-limit": @FieldType(Config.Watch, "history_limit") = std.meta.fieldInfo(Config.Watch, .history_limit).defaultValue().?,
            @"metrics-listen": @FieldType(Config.Watch, "metrics_listen") = std.meta.fieldInfo(Config.Watch, .metrics_listen).defaultValue().?,

            interval: @FieldType(Config.Watch, "interval_s") = std.meta.fieldInfo(Config.Watch, .interval_s).defaultValue().?,

            pub const meta = .{
                .option_docs = .{
                    .@"scan-expiry" = Options.meta_common.option_docs.@"scan-expiry",
                    .@"user-agent" = Options.meta_common.option_docs.@"user-agent",
                    .@"token-file" = Options.meta_common.option_docs.@"token-file",
                    .historical = Options.meta_common.option_docs.historical,
                    .@"history-limit" = Options.meta_common.option_docs.@"history-limit",
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
            .history_limit = scan.@"history-limit",
            .metrics_listen = scan.@"metrics-listen",
            .targets = options.positionals,
        } },
        .watch => |watch| .{ .watch = .{
            .db = options.options.db,
            .scan_expiry_s = watch.@"scan-expiry",
            .user_agent = watch.@"user-agent",
            .token_file = watch.@"token-file",
            .historical = watch.historical orelse false,
            .history_limit = watch.@"history-limit",
            .metrics_listen = watch.@"metrics-listen",
            .targets = options.positionals,
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
            history_limit: u32 = 250,
            metrics_listen: ?[]const u8 = null,
            targets: []const []const u8,
        },
    });

    pub const Watch = utils.meta.MergedStructs(&.{ @This().Scan, struct {
        interval_s: u32 = std.time.s_per_hour / 2,
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
    } != null)
        try Metrics.init(allocator, io, metric_opts)
    else
        null;
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
        router.get("/metrics/history/:gte_unix_s/:interval_s/:lt_unix_s", serveGetMetricsHistory, .{});

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
        if (metrics) |*m| &m.client else null,
    );
    defer client.deinit();

    var scan: Scan = .{
        .allocator = allocator,
        .targets = switch (config) {
            .serve => unreachable,
            inline .scan, .watch => |mode| mode.targets,
        },
        .historical = switch (config) {
            .serve => unreachable,
            inline .scan, .watch => |mode| mode.historical,
        },
        .history_limit = switch (config) {
            .serve => unreachable,
            inline .scan, .watch => |mode| mode.history_limit,
        },
    };
    defer scan.deinit();

    try scan.loadFromDb(db_conn);

    const retry_opts = zretry.RetryOptions{
        .io = io,
        .retry_if = struct {
            fn retryIf(err: anyerror) bool {
                return switch (err) {
                    error.RateLimited => false,
                    else => |e| if (utils.meta.errorSetContains(api.Client.QueryError, e)) retry: {
                        std.log.warn("error during API request, retrying after a delay: {s}", .{@errorName(e)});
                        break :retry true;
                    } else false,
                };
            }
        }.retryIf,
    };

    switch (config) {
        .serve => unreachable,
        .scan => while (true) {
            if (metrics) |*m|
                m.scan_state.set(@intFromEnum(Metrics.ScanState.scanning));

            scan.scan(&client, db_conn, retry_opts) catch |err| switch (err) {
                error.RateLimited => {
                    if (metrics) |*m|
                        m.scan_state.set(@intFromEnum(Metrics.ScanState.rate_limited));

                    const duration = client.rate_limit.?.delay().?.fromNow(io);
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
                if (metrics) |*m|
                    m.scan_state.set(@intFromEnum(Metrics.ScanState.scanning));

                scan.scan(&client, db_conn, retry_opts) catch |err| switch (err) {
                    error.RateLimited => {
                        if (metrics) |*m|
                            m.scan_state.set(@intFromEnum(Metrics.ScanState.rate_limited));

                        const duration = client.rate_limit.?.delay().?.fromNow(io);
                        std.log.warn("rate limited; continuing in {f}", .{duration});
                        try std.Io.sleep(io, duration, .real);
                        continue;
                    },
                    else => |e| return e,
                };

                if (metrics) |*m|
                    m.scan_state.set(@intFromEnum(Metrics.ScanState.idle));

                std.log.info("next scan in {f}", .{interval});
                try std.Io.sleep(io, interval, .awake);
            }
        },
    }
}

/// Stateful scan that can continue where it left off.
const Scan = struct {
    allocator: std.mem.Allocator,

    targets: []const []const u8,
    historical: bool,
    history_limit: u32,

    progress: Progress = .{},

    const Progress = struct {
        targets_idx: usize = 0,
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
            .targets_idx,
            .prss_idx,
            .pr,
            .commit,
            .check_suite,
            .updated_at,
        })).query(self.allocator, db_conn, .{
            .targets = .{ .items = self.targets },
            .historical = self.historical,
        })) |db_scan| {
            self.progress.targets_idx = @intCast(db_scan.targets_idx);
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
                self.progress.targets_idx + 1,
                self.targets.len,
                self.progress.prss_idx + 1,
                self.progress.pr.id,
                self.progress.commit.id,
                self.progress.check_suite.id,
            });
        }
    }

    fn persist(self: @This(), db_conn: zqlite.Conn) !void {
        if (self.progress.targets_idx == 0 and
            self.progress.prss_idx == 0 and
            self.progress.pr.id == null and
            self.progress.commit.id == null and
            self.progress.check_suite.id == null)
            try Db.queries.Scan.delete.exec(self.allocator, db_conn, .{
                .targets = .{ .items = self.targets },
                .historical = self.historical,
            })
        else
            try Db.queries.Scan.upsert.exec(self.allocator, db_conn, .{
                .targets = .{ .items = self.targets },
                .historical = self.historical,
                .targets_idx = @intCast(self.progress.targets_idx),
                .prss_idx = @intCast(self.progress.prss_idx),
                .pr = self.progress.pr.id,
                .commit = self.progress.commit.id,
                .check_suite = self.progress.check_suite.id,
            });
    }

    pub fn scan(self: *@This(), client: *api.Client, db_conn: zqlite.Conn, retry_opts: zretry.RetryOptions) !void {
        for (self.targets[self.progress.targets_idx..], self.progress.targets_idx..) |target, targets_idx| {
            const repo_owner, const repo_name, const branch = target: {
                errdefer std.log.err("malformed target \"{s}\", must be of form \"owner/name\" or \"owner/name#branch\"", .{target});

                var iter = std.mem.splitScalar(u8, target, '/');
                const owner = iter.next() orelse return error.MalformedTarget;
                const name_branch = iter.next() orelse return error.MalformedTarget;
                std.debug.assert(iter.next() == null);

                iter = std.mem.splitScalar(u8, name_branch, '#');
                const name = iter.next() orelse return error.MalformedTarget;
                const branch = iter.next();
                if (branch != null)
                    std.debug.assert(iter.next() == null);

                break :target .{ owner, name, branch };
            };

            std.log.info("/{s}/{s}{s}{s}: fetching repository…", .{
                repo_owner,
                repo_name,
                if (branch) |_| "#" else "",
                branch orelse "",
            });

            const repo = try zretry.zretry(api.queries.fetchRepoByFullName, .{
                self.allocator,
                client,
                repo_owner,
                repo_name,
            }, retry_opts);
            defer repo.deinit();

            try Db.queries.Repository.upsert.exec(self.allocator, db_conn, .{
                .id = repo.value.id,
                .owner = repo.value.owner.login,
                .name = repo.value.name,
                .created_at = repo.value.createdAt,
                .updated_at = repo.value.updatedAt,
                .archived_at = repo.value.archivedAt,
                .pushed_at = repo.value.pushedAt,
            });

            if (branch) |b| {
                if (try zretry.zretry(api.queries.fetchRef, .{
                    self.allocator,
                    client,
                    repo.value.owner.login,
                    repo.value.name,
                    b,
                }, retry_opts)) |ref| {
                    defer ref.deinit();
                    try self.scanRef(client, db_conn, retry_opts, repo.value, ref.value);
                } else {
                    std.log.err("/{s}/{s}#{s} does not exist", .{ repo_owner, repo_name, b });
                    return error.TargetNotFound;
                }
            } else try self.scanRepository(client, db_conn, retry_opts, repo.value);

            self.progress.targets_idx += 1;
            std.log.info("{d}/{d} targets scanned", .{ targets_idx + 1, self.targets.len });
        } else self.progress.targets_idx = 0;

        // All indices and anchors were just set to their zero value,
        // so persisting now will delete the scan from the DB.
        try self.persist(db_conn);
    }

    fn scanRepository(
        self: *@This(),
        client: *api.Client,
        db_conn: zqlite.Conn,
        retry_opts: zretry.RetryOptions,
        repo: api.queries.Repository,
    ) !void {
        std.log.info("/{s}/{s}: scanning pull requests…", .{ repo.owner.login, repo.name });

        const prs_open = try zretry.zretry(api.queries.fetchPullRequestsByRepo, .{
            self.allocator,
            client,
            repo.owner.login,
            repo.name,
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
                repo.owner.login,
                repo.name,
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

        const prss = [_][]const api.queries.PullRequest{
            prs_open.value,
            if (prs_closed) |pr| pr.value else &.{},
        };

        for (prss[self.progress.prss_idx..]) |prs| {
            const prs_start_idx = if (self.progress.pr.find(api.queries.PullRequest, prs)) |idx| idx + 1 else 0;
            for (prs[prs_start_idx..]) |pr|
                try Db.queries.PullRequest.upsert.exec(self.allocator, db_conn, .{
                    .id = pr.id,
                    .repository = repo.id,
                    .number = pr.number,
                    .state = pr.state,
                    .head_ref_oid = pr.headRefOid,
                    .merge_base_oid = pr.mergeBaseOid(),
                    .created_at = pr.createdAt,
                    .updated_at = pr.updatedAt,
                    .published_at = pr.publishedAt,
                    .merged_at = pr.mergedAt,
                    .closed_at = pr.closedAt,
                });
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

            const prs_start_idx = self.progress.pr.findNextLogVanished(api.queries.PullRequest, prs);
            for (prs[prs_start_idx..], prs_start_idx..) |pr, prs_idx| {
                try self.scanPullRequest(client, db_conn, retry_opts, repo, pr);

                try self.progress.pr.set(self.allocator, pr.id);
                std.log.info("/{s}/{s}: {d}/{d} PRs scanned", .{ repo.owner.login, repo.name, prev_prs_count + prs_idx + 1, prs_count });
            } else self.progress.pr.clear(self.allocator);

            self.progress.prss_idx += 1;
        } else self.progress.prss_idx = 0;

        if (repo.defaultBranchRef) |ref|
            try self.scanRef(client, db_conn, retry_opts, repo, ref);
    }

    fn scanPullRequest(
        self: *@This(),
        client: *api.Client,
        db_conn: zqlite.Conn,
        retry_opts: zretry.RetryOptions,
        repo: api.queries.Repository,
        pr: api.queries.PullRequest,
    ) !void {
        const merge_base_oid = pr.mergeBaseOid() orelse {
            std.log.info("{s}: no commits, skipping", .{pr.resourcePath});
            return;
        };

        std.log.info("{s}: scanning commits…", .{pr.resourcePath});

        const commits = try zretry.zretry(api.queries.fetchCommitHistoryByRepo, .{
            self.allocator,
            client,
            repo.id,
            pr.headRefOid,
            merge_base_oid,
            @as(usize, @intCast(self.history_limit)),
        }, retry_opts);
        defer commits.deinit();

        const commits_start_idx = self.progress.commit.findNextLogVanished(api.queries.Commit, commits.value);

        try upsertCommits(self.allocator, db_conn, repo.id, commits.value[commits_start_idx..]);

        for (commits.value[commits_start_idx..], commits_start_idx..) |commit, commits_idx| {
            const commit_changed = try self.scanCommit(client, db_conn, retry_opts, repo.id, commit);

            if (!commit_changed and !self.historical) {
                std.log.info("{s}: check suites of commit {d}/{d} have not changed, skipping older commits", .{ pr.resourcePath, commits_idx + 1, commits.value.len });
                break;
            }

            try self.progress.commit.set(self.allocator, commit.id);
            std.log.info("{s}: {d}/{d} commits scanned", .{ pr.resourcePath, commits_idx + 1, commits.value.len });
        }
        self.progress.commit.clear(self.allocator);
    }

    fn scanRef(
        self: *@This(),
        client: *api.Client,
        db_conn: zqlite.Conn,
        retry_opts: zretry.RetryOptions,
        repo: api.queries.Repository,
        ref: api.queries.Ref,
    ) !void {
        std.log.info("/{s}/{s}#{s}{s}: scanning history commits…", .{
            repo.owner.login, repo.name, ref.prefix, ref.name,
        });

        const commits = try zretry.zretry(api.queries.fetchCommitHistoryByRepo, .{
            self.allocator,
            client,
            repo.id,
            ref.target.oid,
            null,
            @as(usize, @intCast(self.history_limit)),
        }, retry_opts);
        defer commits.deinit();

        const commits_start_idx = self.progress.commit.findNextLogVanished(api.queries.Commit, commits.value);

        const commits_len = commits_len: for (commits.value[commits_start_idx..], commits_start_idx..) |commit, idx| {
            const commit_known = if (try Db.queries.Commit.SelectByRepoAndOid(.initOne(.id)).query(self.allocator, db_conn, .{
                .repository = repo.id,
                .oid = commit.oid,
            })) |db_commit| known: {
                zqlite_typed.freeStructFromRow(@TypeOf(db_commit), self.allocator, db_commit);
                break :known true;
            } else false;

            if (commit_known) {
                std.log.info("/{s}/{s}#{s}{s}: stopping {d} from HEAD at known commit {s}", .{
                    repo.owner.login, repo.name, ref.prefix, ref.name, idx, commit.oid,
                });
                break idx;
            }
        } else {
            std.log.warn("/{s}/{s}#{s}{s}: reached history depth limit ({d}), skipping older commits", .{
                repo.owner.login, repo.name, ref.prefix, ref.name, self.history_limit,
            });
            break :commits_len commits.value.len;
        };

        // Slicing past `commits_len` so that PR scans don't prevent commit parents from being inserted here.
        try upsertCommits(self.allocator, db_conn, repo.id, commits.value[commits_start_idx..]);

        // The ref's target OID is not a foreign key so we could insert the ref
        // before the commit it references. Let's pretend it's a foreign key
        // anyway and insert only once the referenced commit is already in the DB.
        // Feels cleaner and is prepared in case it does become a foreign key in the future.
        try Db.queries.Ref.upsert.exec(self.allocator, db_conn, .{
            .id = ref.id,
            .repository = repo.id,
            .prefix = ref.prefix,
            .name = ref.name,
            .target_oid = ref.target.oid,
        });

        for (commits.value[commits_start_idx..commits_len], commits_start_idx..) |commit, commits_idx| {
            const commit_changed = try self.scanCommit(client, db_conn, retry_opts, repo.id, commit);

            if (!commit_changed and !self.historical) {
                std.log.info("/{s}/{s}#{s}{s}: check suites of commit {d}/{d} have not changed, skipping older commits", .{
                    repo.owner.login, repo.name, ref.prefix, ref.name, commits_idx + 1, commits_len,
                });
                break;
            }

            try self.progress.commit.set(self.allocator, commit.id);
            std.log.info("/{s}/{s}#{s}{s}: {d}/{d} history commits scanned", .{
                repo.owner.login, repo.name, ref.prefix, ref.name, commits_idx + 1, commits_len,
            });
        }
        self.progress.commit.clear(self.allocator);
    }

    fn upsertCommits(
        allocator: std.mem.Allocator,
        db_conn: zqlite.Conn,
        repo_id: api.types.Id,
        commits: []const api.queries.Commit,
    ) !void {
        for (commits) |commit|
            try Db.queries.Commit.upsert.exec(allocator, db_conn, .{
                .id = commit.id,
                .repository = repo_id,
                .oid = commit.oid,
                .authored_at = commit.authoredDate,
                .committed_at = commit.committedDate,
            });

        // Insert parents after the commits so the foreign keys work.
        for (commits) |commit|
            for (commit.parents.nodes, 0..) |parent, idx| {
                // Skip if we don't have the parent.
                if (try Db.queries.Commit.SelectById(.initOne(.id)).query(allocator, db_conn, .{ .id = parent.id })) |row|
                    zqlite_typed.freeStructFromRow(@TypeOf(row), allocator, row)
                else
                    continue;

                try Db.queries.Commit.Parent.upsert.exec(allocator, db_conn, .{
                    .commit = commit.id,
                    .index = idx,
                    .parent = parent.id,
                });
            };
    }

    /// Returns whether any check suites were updated since the last scan.
    fn scanCommit(
        self: *@This(),
        client: *api.Client,
        db_conn: zqlite.Conn,
        retry_opts: zretry.RetryOptions,
        repo_id: api.types.Id,
        commit: api.queries.Commit,
    ) !bool {
        std.log.info("{s}: scanning check suites…", .{commit.resourcePath});

        const check_suites = try zretry.zretry(api.queries.fetchCheckSuitesByCommitId, .{
            self.allocator,
            client,
            commit.id,
        }, retry_opts);
        defer check_suites.deinit();

        var check_suites_updated = false;

        const check_suites_start_idx = self.progress.check_suite.findNextLogVanished(api.queries.CheckSuite, check_suites.value);
        for (check_suites.value[check_suites_start_idx..], check_suites_start_idx..) |check_suite, check_suites_idx| {
            const check_suite_updated = if (try Db.queries.CheckSuite.SelectById(.initOne(.updated_at)).query(self.allocator, db_conn, .{
                .id = check_suite.id,
            })) |db_check_suite| check_suite_updated: {
                defer zqlite_typed.freeStructFromRow(@TypeOf(db_check_suite), self.allocator, db_check_suite);
                break :check_suite_updated check_suite.updatedAt.inner.compare(db_check_suite.updated_at.inner) != .equal;
            } else true;

            check_suites_updated |= check_suite_updated;

            if (!check_suite_updated)
                std.log.info("{s}: has not changed", .{check_suite.resourcePath});

            if (check_suite_updated or self.historical) {
                try Db.queries.App.upsert.exec(self.allocator, db_conn, .{
                    .id = check_suite.app.id,
                    .slug = check_suite.app.slug,
                    .name = check_suite.app.name,
                    .created_at = check_suite.app.createdAt,
                    .updated_at = check_suite.app.updatedAt,
                });

                try Db.queries.CheckSuite.upsert.exec(self.allocator, db_conn, .{
                    .id = check_suite.id,
                    .repository = repo_id,
                    .commit = commit.id,
                    .app = check_suite.app.id,
                    .created_at = check_suite.createdAt,
                    .updated_at = check_suite.updatedAt,
                    .status = check_suite.status,
                    .conclusion = check_suite.conclusion,
                });

                try self.scanCheckSuite(client, db_conn, retry_opts, check_suite);
            } else std.log.info("{s}: skipping", .{check_suite.resourcePath});

            try self.progress.check_suite.set(self.allocator, check_suite.id);
            std.log.info("{s}: {d}/{d} check suites scanned", .{ commit.resourcePath, check_suites_idx + 1, check_suites.value.len });

            try self.persist(db_conn);
        } else self.progress.check_suite.clear(self.allocator);

        try self.persist(db_conn);

        return check_suites_updated;
    }

    fn scanCheckSuite(
        self: *@This(),
        client: *api.Client,
        db_conn: zqlite.Conn,
        retry_opts: zretry.RetryOptions,
        check_suite: api.queries.CheckSuite,
    ) !void {
        std.log.info("{s}: scanning check runs…", .{check_suite.resourcePath});

        const check_runs = try zretry.zretry(api.queries.fetchCheckRunsByCheckSuiteId, .{
            self.allocator,
            client,
            check_suite.id,
        }, retry_opts);
        defer check_runs.deinit();

        for (check_runs.value) |check_run|
            try Db.queries.CheckRun.upsert.exec(self.allocator, db_conn, .{
                .id = check_run.id,
                .suite = check_suite.id,
                .name = check_run.name,
                .started_at = check_run.startedAt,
                .completed_at = check_run.completedAt,
                .external_id = check_run.externalId,
                .status = check_run.status,
                .conclusion = check_run.conclusion,
            });

        std.log.info("{s}: {d} check runs scanned", .{ check_suite.resourcePath, check_runs.value.len });
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

    try ctx.metrics_scrape.refreshMetrics(req.arena, ctx.io, ctx.metrics, db_conn, .{});

    res.content_type = .TEXT;
    try ctx.metrics.write(res.writer());

    try httpz.writeMetrics(res.writer());
}

fn serveGetMetricsHistory(ctx: ServerContext, req: *httpz.Request, res: *httpz.Response) !void {
    const interval = std.Io.Duration.fromSeconds(try std.fmt.parseInt(i64, req.params.get("interval_s").?, 10));
    const timestamp_gte = std.Io.Timestamp.fromNanoseconds(try std.fmt.parseInt(i96, req.params.get("gte_unix_s").?, 10) * std.time.ns_per_s);
    const timestamp_lt = std.Io.Timestamp.fromNanoseconds(try std.fmt.parseInt(i96, req.params.get("lt_unix_s").?, 10) * std.time.ns_per_s);

    if (interval.toSeconds() == 0 or
        timestamp_gte.toSeconds() > timestamp_lt.toSeconds())
    {
        res.setStatus(.bad_request);
        return;
    }

    const MetricsFormat = enum {
        /// Timestamps are integers that represent milliseconds since the epoch.
        prometheus,
        /// Timestamps are floats that represent seconds since the epoch.
        open_metrics,
    };

    const metrics_format = if (req.param("format")) |f|
        std.meta.stringToEnum(MetricsFormat, f) orelse {
            res.setStatus(.bad_request);
            return;
        }
    else
        .open_metrics;

    const MetricPreamble = struct {
        kind: Kind,
        series: []const u8,
        value: []const u8,
        emitted: bool = false,

        pub const Kind = enum {
            HELP,
            TYPE,
            UNIT,

            pub fn fromZqlite(_: std.mem.Allocator, cell: []const u8) !@This() {
                return std.meta.stringToEnum(@This(), cell) orelse return error.InvalidTag;
            }

            pub fn toZqlite(self: @This(), _: std.mem.Allocator) ![]const u8 {
                return @tagName(self);
            }
        };

        const table = "metric_preamble";

        const Column = std.meta.FieldEnum(@This());

        pub const upsert = zqlite_typed.SimpleUpsert(table, @This(), true);

        pub const select_by_series_and_emitted = zqlite_typed.SimpleSelectBy(table, @This(), .full, .initMany(&.{ .series, .emitted }), true);

        pub fn format(self: @This(), writer: *std.Io.Writer) !void {
            try writer.print("# {t} {s} {s}\n", .{
                self.kind,
                self.series,
                self.value,
            });
        }

        /// Returns null if it's a normal comment.
        pub fn fromString(
            /// Must be trimmed already, so must not contain
            /// leading or trailing whitespace including newline.
            line: []const u8,
        ) ?@This() {
            const kind_pos = std.mem.findNone(u8, line, "#" ++ std.ascii.whitespace).?;
            const kind_end = (std.mem.findAnyPos(u8, line, kind_pos, &std.ascii.whitespace) orelse return null) - 1;

            const kind = std.meta.stringToEnum(Kind, line[kind_pos .. kind_end + 1]) orelse
                return null;

            const series_pos = std.mem.findNonePos(u8, line, kind_end + 1, &std.ascii.whitespace).?;
            const series_end = std.mem.findAnyPos(u8, line, series_pos, &std.ascii.whitespace).? - 1;

            return .{
                .kind = kind,
                .series = line[series_pos .. series_end + 1],
                .value = std.mem.trimStart(u8, line[series_end + 1 ..], &std.ascii.whitespace),
            };
        }

        test fromString {
            const series = "foo";
            const help = "This is the description.";
            const @"type" = "gauge";
            const unit = "seconds";

            const preamble_help = fromString("# HELP " ++ series ++ " " ++ help);
            const preamble_type = fromString("# TYPE " ++ series ++ " " ++ @"type");
            const preamble_unit = fromString("# UNIT " ++ series ++ " " ++ unit);
            const preamble_comment = fromString("# foobar");

            try std.testing.expectEqual(.HELP, preamble_help.?.kind);
            try std.testing.expectEqualStrings(series, preamble_help.?.series);
            try std.testing.expectEqualStrings(help, preamble_help.?.value);

            try std.testing.expectEqual(.TYPE, preamble_type.?.kind);
            try std.testing.expectEqualStrings(series, preamble_type.?.series);
            try std.testing.expectEqualStrings(@"type", preamble_type.?.value);

            try std.testing.expectEqual(.UNIT, preamble_unit.?.kind);
            try std.testing.expectEqualStrings(series, preamble_unit.?.series);
            try std.testing.expectEqualStrings(unit, preamble_unit.?.value);

            try std.testing.expect(preamble_comment == null);
        }
    };

    const MetricPoint = struct {
        series: []const u8,
        labels: ?[]const u8,
        value: f64,
        timestamp_us: i64,

        const table = "metric_point";

        const Column = std.meta.FieldEnum(@This());

        pub const insert = zqlite_typed.SimpleInsert(table, @This());

        pub const select_history = zqlite_typed.Query(
            zqlite_typed.SimpleSelectBy(table, @This(), .full, .empty, true).sql ++
                std.fmt.comptimePrint(
                    \\
                    \\ORDER BY {[series]f}, {[labels]f}, {[timestamp_us]f}
                , .{
                    .series = zqlite_typed.fmt.fmtIdentifier(@tagName(Column.series)),
                    .labels = zqlite_typed.fmt.fmtIdentifier(@tagName(Column.labels)),
                    .timestamp_us = zqlite_typed.fmt.fmtIdentifier(@tagName(Column.timestamp_us)),
                }),
            true,
            @This(),
            struct {},
        );

        const MetricPoint = @This();

        pub const Fmt = struct {
            metric_point: MetricPoint,
            metrics_format: MetricsFormat,

            pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
                try writer.print("{s}{s} {d} {d}\n", .{
                    self.metric_point.series,
                    self.metric_point.labels orelse "",
                    self.metric_point.value,
                    switch (self.metrics_format) {
                        .prometheus => self.metric_point.timestamp_us * std.time.us_per_ms,
                        .open_metrics => @as(f80, @floatFromInt(self.metric_point.timestamp_us)) / std.time.us_per_s,
                    },
                });
            }
        };

        pub fn fmt(self: @This(), format: MetricsFormat) Fmt {
            return .{
                .metric_point = self,
                .metrics_format = format,
            };
        }

        pub fn fromString(
            /// Must be trimmed already, so must not contain
            /// leading or trailing whitespace including newline.
            line: []const u8,
            timestamp_us: i64,
        ) std.fmt.ParseFloatError!@This() {
            const series_len = std.mem.findAny(u8, line, std.ascii.whitespace ++ "{").?;
            const labels_end = std.mem.findScalarLast(u8, line, '}');
            const value_pos = std.mem.findLastAny(u8, line, &std.ascii.whitespace).? + 1;

            return .{
                .series = line[0..series_len],
                .labels = if (labels_end) |end| line[series_len .. end + 1] else null,
                .value = try std.fmt.parseFloat(f64, line[value_pos..]),
                .timestamp_us = timestamp_us,
            };
        }

        test fromString {
            const series = "foo";
            const labels =
                \\{bar="bar",baz="baz"}
            ;
            const value_int = 1337;
            const value_float = 1337.9;

            const metric_prometheus = try fromString(std.fmt.comptimePrint("{s}{s} {d}", .{ series, labels, value_int }), 0);
            const metric_openmetrics = try fromString(std.fmt.comptimePrint("{s}{s} {d}", .{ series, labels, value_float }), 0);

            try std.testing.expectEqualStrings(series, metric_prometheus.series);
            try std.testing.expectEqualStrings(series, metric_openmetrics.series);
            try std.testing.expectEqualStrings(labels, metric_prometheus.labels.?);
            try std.testing.expectEqualStrings(labels, metric_openmetrics.labels.?);
            try std.testing.expectEqual(value_int, metric_prometheus.value);
            try std.testing.expectEqual(value_float, metric_openmetrics.value);

            const metric_simple = try fromString(std.fmt.comptimePrint("{s} {d}", .{ series, value_int }), 0);

            try std.testing.expectEqualStrings(series, metric_simple.series);
            try std.testing.expect(metric_simple.labels == null);
            try std.testing.expectEqual(value_int, metric_simple.value);
        }
    };

    const db_conn = try ctx.db_pool.acquire(ctx.io);
    defer ctx.db_pool.release(ctx.io, db_conn);

    try db_conn.transaction();
    defer db_conn.rollback();

    try db_conn.execNoArgs(std.fmt.comptimePrint(
        \\CREATE TEMP TABLE {[mpa]f} (
        \\  {[mpa_kind]f} TEXT NOT NULL CHECK ({[mpa_kind]f} IN ({[mpa_kind_values]f})),
        \\  {[mpa_series]f} TEXT NOT NULL,
        \\  {[mpa_value]f} TEXT NOT NULL,
        \\  {[mpa_emitted]f} INT NOT NULL CHECK ({[mpa_emitted]f} IN (TRUE, FALSE)),
        \\  UNIQUE ({[mpa_series]f}, {[mpa_kind]f})
        \\) STRICT;
        \\
        \\CREATE TEMP TABLE {[mp]f} (
        \\  {[mp_series]f} TEXT NOT NULL,
        \\  {[mp_labels]f} TEXT,
        \\  {[mp_value]f} REAL NOT NULL,
        \\  {[mp_timestamp_us]f} INT NOT NULL
        \\) STRICT;
    , comptime .{
        .mpa = zqlite_typed.fmt.fmtIdentifier(MetricPreamble.table),
        .mpa_kind = zqlite_typed.fmt.fmtIdentifier(@tagName(MetricPreamble.Column.kind)),
        .mpa_kind_values = zqlite_typed.fmt.fmtStringEnumSet(MetricPreamble.Kind, .full, .space),
        .mpa_series = zqlite_typed.fmt.fmtIdentifier(@tagName(MetricPreamble.Column.series)),
        .mpa_value = zqlite_typed.fmt.fmtIdentifier(@tagName(MetricPreamble.Column.value)),
        .mpa_emitted = zqlite_typed.fmt.fmtIdentifier(@tagName(MetricPreamble.Column.emitted)),
        .mp = zqlite_typed.fmt.fmtIdentifier(MetricPoint.table),
        .mp_series = zqlite_typed.fmt.fmtIdentifier(@tagName(MetricPoint.Column.series)),
        .mp_labels = zqlite_typed.fmt.fmtIdentifier(@tagName(MetricPoint.Column.labels)),
        .mp_value = zqlite_typed.fmt.fmtIdentifier(@tagName(MetricPoint.Column.value)),
        .mp_timestamp_us = zqlite_typed.fmt.fmtIdentifier(@tagName(MetricPoint.Column.timestamp_us)),
    }));

    const fns = struct {
        fn insertFromText(allocator: std.mem.Allocator, conn: zqlite.Conn, text: []const u8, timestamp: std.Io.Timestamp) !void {
            var lines = std.mem.splitScalar(u8, text, '\n');
            while (lines.next()) |line_raw| {
                const line = std.mem.trim(u8, line_raw, &std.ascii.whitespace);

                if (line.len == 0)
                    continue;

                if (line[0] == '#') {
                    if (MetricPreamble.fromString(line)) |metric_preamble|
                        try MetricPreamble.upsert.exec(allocator, conn, metric_preamble);
                } else try MetricPoint.insert.exec(
                    allocator,
                    conn,
                    try MetricPoint.fromString(line, timestamp.toMicroseconds()),
                );
            }
        }
    };

    var metrics = try Metrics.init(req.arena, ctx.io, metric_opts);
    defer metrics.deinit();

    var metrics_scrape = Metrics.Scrape{ .allocator = req.arena };
    defer metrics_scrape.deinit();

    var metric_family = std.Io.Writer.Allocating.init(req.arena);
    defer metric_family.deinit();

    const scrapes = @divTrunc(timestamp_gte.durationTo(timestamp_lt).toNanoseconds(), interval.toNanoseconds());
    std.log.info("dumping history from {f} to {f} with an interval of {f} in {d} scrapes…", .{
        api.types.DateTime.fromTimestamp(timestamp_gte),
        api.types.DateTime.fromTimestamp(timestamp_lt),
        interval,
        scrapes,
    });

    std.debug.assert(scrapes <= std.math.maxInt(usize));
    for (0..@intCast(scrapes)) |scrape| {
        const timestamp = timestamp_gte.addDuration(.fromNanoseconds(interval.toNanoseconds() * scrape));
        std.debug.assert(timestamp.toNanoseconds() < timestamp_lt.toNanoseconds());

        inline for (std.enums.values(Metrics.ComputedMetric)) |metric| {
            try metrics_scrape.refreshComputedMetric(metric, req.arena, ctx.io, &metrics, db_conn, .{
                .gte = timestamp_gte,
                .lt = timestamp,
            });

            metric_family.clearRetainingCapacity();
            try @field(metrics, @tagName(metric)).write(&metric_family.writer);

            try fns.insertFromText(req.arena, db_conn, metric_family.written(), timestamp);
        }

        metric_family.clearRetainingCapacity();
        try metrics.metric_computation_duration.write(&metric_family.writer);

        try fns.insertFromText(req.arena, db_conn, metric_family.written(), timestamp);

        std.log.info("{d}/{d} history scrapes dumped (from {f} to {f} with an interval of {f}, currently at {f})", .{
            scrape + 1,
            scrapes,
            api.types.DateTime.fromTimestamp(timestamp_gte),
            api.types.DateTime.fromTimestamp(timestamp_lt),
            interval,
            api.types.DateTime.fromTimestamp(timestamp),
        });
    }

    res.content_type = .TEXT;

    var history = try MetricPoint.select_history.queryIterator(req.arena, db_conn, .{});
    errdefer history.deinit();

    while (try history.next(req.arena)) |metric_point| {
        var metric_preambles = try MetricPreamble.select_by_series_and_emitted.queryIterator(req.arena, db_conn, .{
            .series = metric_point.series,
            .emitted = false,
        });
        errdefer metric_preambles.deinit();

        while (try metric_preambles.next(req.arena)) |row| {
            const metric_preamble = MetricPreamble{
                .kind = row.kind,
                .series = row.series,
                .value = row.value,
                .emitted = true,
            };

            try res.writer().print("{f}", .{metric_preamble});

            try MetricPreamble.upsert.exec(req.arena, db_conn, metric_preamble);
        }

        try metric_preambles.deinitErr();

        try metric_point.fmt(metrics_format).format(res.writer());
    }

    try history.deinitErr();

    if (metrics_format == .open_metrics)
        try res.writer().writeAll("# EOF");
}

test {
    std.testing.refAllDecls(@This());
}
