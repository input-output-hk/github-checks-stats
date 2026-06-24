const builtin = @import("builtin");
const std = @import("std");
const args = @import("args");

const api = @import("api.zig");

pub fn main(init: std.process.Init) !void {
    var stdout_buffer: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const stdout_w = &stdout.interface;

    var stderr_buffer: [1024]u8 = undefined;
    var stderr = std.Io.File.stderr().writer(init.io, &stderr_buffer);
    const stderr_w = &stderr.interface;

    const Options = struct {
        @"user-agent": ?[]const u8 = null,
        @"token-file": ?[]const u8 = null,

        pub const meta = .{
            .usage_summary = "[options] <scan|watch [--interval SECS]> REPO...",
            .full_text = "Collect statistics about GitHub Checks",
            .option_docs = .{
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

    try stdout_w.print("repo_owner\trepo_name\tpr_number\tcommit_oid\tcheck_suite_app_name\tcheck_suite_conclusion\tcheck_suite_status\tcheck_run_name\tcheck_run_started_at\tcheck_run_completed_at\tcheck_run_duration_seconds\n", .{});

    switch (options.verb.?) {
        .scan => try runPass(init.gpa, &client, stdout_w, options.positionals, null),
        .watch => |watch| {
            const interval = std.Io.Duration.fromSeconds(@as(i64, watch.interval));
            const open_states: []const api.types.PullRequestState = &.{.OPEN};
            while (true) {
                runPass(init.gpa, &client, stdout_w, options.positionals, open_states) catch |err| switch (err) {
                    error.RateLimited => std.log.warn("rate limited; sleeping {f} before retry", .{interval}),
                    else => return err,
                };
                try std.Io.sleep(init.io, interval, .awake);
            }
        },
    }
}

fn runPass(
    gpa: std.mem.Allocator,
    client: *api.Client,
    stdout_w: *std.Io.Writer,
    repos: []const []const u8,
    states_filter: ?[]const api.types.PullRequestState,
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

        std.log.info("/{s}/{s}: scanning for pull requests…", .{ repo_owner, repo_name });

        const prs = try api.queries.fetchPullRequestsByRepo(client, gpa, repo_owner, repo_name, states_filter);
        defer prs.deinit();

        for (prs.value) |pr| {
            std.log.info("{s}: scanning for commits…", .{pr.resourcePath});

            const commits = try api.queries.fetchCommitsByPullRequestId(client, gpa, pr.id);
            defer commits.deinit();

            for (commits.value) |commit| {
                std.log.info("{s}: scanning for check suites…", .{commit.resourcePath});

                const check_suites = try api.queries.fetchCheckSuitesByCommitId(client, gpa, commit.id);
                defer check_suites.deinit();

                for (check_suites.value) |check_suite| {
                    if (check_suite.status != .COMPLETED) {
                        std.log.info("{s}: skipping (not completed)", .{check_suite.resourcePath});
                        continue;
                    }

                    std.log.info("{s}: scanning for check runs…", .{check_suite.resourcePath});

                    const check_runs = try api.queries.fetchCheckRunsByCheckSuiteId(client, gpa, check_suite.id);
                    defer check_runs.deinit();

                    for (check_runs.value) |check_run| {
                        std.debug.assert(check_run.startedAt.inner.offset == check_run.completedAt.inner.offset);
                        const check_run_seconds = @divFloor(
                            check_run.completedAt.inner.instant().timestamp - check_run.startedAt.inner.instant().timestamp,
                            std.time.ns_per_s,
                        );

                        std.log.info("{s}: {d}s", .{ check_run.resourcePath, check_run_seconds });

                        try stdout_w.print("{s}\t{s}\t{d}\t{s}\t{s}\t{?f}\t{f}\t{s}\t{f}\t{f}\t{d}\n", .{
                            repo_owner,
                            repo_name,
                            pr.number,
                            commit.oid,
                            check_suite.app.name,
                            check_suite.conclusion,
                            check_suite.status,
                            check_run.name,
                            check_run.startedAt,
                            check_run.completedAt,
                            check_run_seconds,
                        });
                        try stdout_w.flush();
                    }
                }
            }
        }
    }
}

test {
    std.testing.refAllDecls(@This());
}
