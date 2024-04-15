const builtin = @import("builtin");
const std = @import("std");
const args = @import("args");

const api = @import("api.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){
        .backing_allocator = std.heap.page_allocator,
    };
    defer if (gpa.deinit() == .leak) std.log.err("leaked memory", .{});
    const allocator = gpa.allocator();

    const Options = struct {
        @"user-agent": ?[]const u8 = null,
        @"token-file": ?[]const u8 = null,

        pub const meta = .{
            .full_text = "Collect statistics about GitHub Checks",
            .option_docs = .{
                .@"user-agent" = "User-Agent header to send, may be needed to authenticate as a GitHub App",
                .@"token-file" = "file to read a token from to authorize with",
            },
        };
    };
    const options = args.parseForCurrentProcess(Options, allocator, .print) catch |err| if (err == error.InvalidArguments) {
        try args.printHelp(Options, "github-checks-stats REPO...", std.io.getStdErr().writer());
        std.process.exit(1);
    } else return err;
    defer options.deinit();

    var client = try api.Client.init(
        allocator,
        options.options.@"user-agent",
        if (options.options.@"token-file") |token_file| token: {
            var buf: [1024]u8 = undefined;
            const token = try std.fs.cwd().readFile(token_file, &buf);
            break :token std.mem.trim(u8, token, " \t\n\r");
        } else null,
    );
    defer client.deinit();

    for (options.positionals) |repo_full| {
        const repo_owner, const repo_name = repo: {
            errdefer std.log.err("malformed repository \"{s}\", must be of form \"foo/bar\"", .{repo_full});
            var iter = std.mem.splitScalar(u8, repo_full, '/');
            const owner = iter.next() orelse return error.MalformedRepository;
            const name = iter.next() orelse return error.MalformedRepository;
            std.debug.assert(iter.next() == null);
            break :repo .{ owner, name };
        };

        const repo_fmt = "{s}/{s}";
        const repo_fmt_args = .{ repo_owner, repo_name };

        std.log.info(repo_fmt ++ ": scanning for pull requests…", repo_fmt_args);

        const prs = try api.queries.fetchPullRequestsByRepo(&client, allocator, repo_owner, repo_name);
        defer prs.deinit(allocator);

        for (prs.value) |pr| {
            const pr_fmt = repo_fmt ++ "#{d}";
            const pr_fmt_args = repo_fmt_args ++ .{pr.number};

            std.log.info(pr_fmt ++ ": scanning for commits…", pr_fmt_args);

            const commits = try api.queries.fetchCommitsByPullRequestId(&client, allocator, pr.id);
            defer commits.deinit(allocator);

            for (commits.value) |commit| {
                const commit_fmt = pr_fmt ++ "@{s}";
                const commit_fmt_args = pr_fmt_args ++ .{commit.oid};

                std.log.info(commit_fmt ++ ": scanning for check suites…", commit_fmt_args);

                const check_suites = try api.queries.fetchCheckSuitesByCommitId(&client, allocator, commit.id);
                defer check_suites.deinit(allocator);

                for (check_suites.value) |check_suite| {
                    const check_suite_fmt = commit_fmt ++ "!{s}";
                    const check_suite_fmt_args = commit_fmt_args ++ .{check_suite.app.name};

                    if (check_suite.status != .COMPLETED) {
                        std.log.info(check_suite_fmt ++ ": skipping (not completed)", check_suite_fmt_args);
                        continue;
                    }

                    std.log.info(check_suite_fmt ++ ": scanning for check runs…", check_suite_fmt_args);

                    const check_runs = try api.queries.fetchCheckRunsByCheckSuiteId(&client, allocator, check_suite.id);
                    defer check_runs.deinit(allocator);

                    for (check_runs.value) |check_run| {
                        const check_run_fmt = check_suite_fmt ++ "?{s}";
                        const check_run_fmt_args = check_suite_fmt_args ++ .{check_run.name};

                        std.log.info(check_run_fmt ++ ": found.", check_run_fmt_args);
                    }
                }
            }
        }
    }
}
