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

        std.log.info("/{s}/{s}: scanning for pull requests…", .{ repo_owner, repo_name });

        const prs = try api.queries.fetchPullRequestsByRepo(&client, allocator, repo_owner, repo_name);
        defer prs.deinit(allocator);

        for (prs.value) |pr| {
            std.log.info("{s}: scanning for commits…", .{pr.resourcePath});

            const commits = try api.queries.fetchCommitsByPullRequestId(&client, allocator, pr.id);
            defer commits.deinit(allocator);

            for (commits.value) |commit| {
                std.log.info("{s}: scanning for check suites…", .{commit.resourcePath});

                const check_suites = try api.queries.fetchCheckSuitesByCommitId(&client, allocator, commit.id);
                defer check_suites.deinit(allocator);

                for (check_suites.value) |check_suite| {
                    if (check_suite.status != .COMPLETED) {
                        std.log.info("{s}: skipping (not completed)", .{check_suite.resourcePath});
                        continue;
                    }

                    std.log.info("{s}: scanning for check runs…", .{check_suite.resourcePath});

                    const check_runs = try api.queries.fetchCheckRunsByCheckSuiteId(&client, allocator, check_suite.id);
                    defer check_runs.deinit(allocator);

                    for (check_runs.value) |check_run|
                        std.log.info("{s}: found.", .{check_run.resourcePath});
                }
            }
        }
    }
}

test {
    std.testing.refAllDecls(@This());
}
