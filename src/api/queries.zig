const std = @import("std");

const api = @import("../api.zig");
const types = api.types;

const Client = api.Client;

const clone = api.clone;
const cloneLeaky = api.cloneLeaky;
const Cloned = api.Cloned;

pub fn fetchPullRequestsByRepo(client: *Client, allocator: std.mem.Allocator, owner: []const u8, name: []const u8) !Cloned([]const types.PullRequest) {
    var cloned = try Cloned([]const types.PullRequest).init(allocator);
    errdefer cloned.deinit();
    const cloned_allocator = cloned.arena.allocator();

    var prs = std.ArrayListUnmanaged(types.PullRequest){};

    const Ctx = struct {
        client: *Client,

        cloned_allocator: std.mem.Allocator,
        prs: *std.ArrayListUnmanaged(types.PullRequest),

        owner: []const u8,
        name: []const u8,

        const Error = Client.QueryError;
        const Page = Client.PageInfo(.backward);

        fn queryPage(ctx: @This(), page_allocator: std.mem.Allocator, page: ?Page) Error!Cloned(Page) {
            const payload = try std.json.stringifyAlloc(page_allocator, .{
                .query = "" ++
                    \\query(
                    \\  $owner: String!
                    \\  $name: String!
                    \\  $cursor: String
                    \\) {
                    \\  repository(
                    \\    owner: $owner
                    \\    name: $name
                    \\  ) {
                    \\    pullRequests(
                ++ std.fmt.comptimePrint("last: {d}\n", .{api.page_size}) ++
                    \\      orderBy: {
                    \\        field: CREATED_AT
                    \\        direction: ASC
                    \\      }
                    \\      before: $cursor
                    \\    ) {
                ++ Page.gql ++
                    \\      nodes
                ++ " " ++ comptime api.graphqlPretty(types.PullRequest, "  ", 3) ++ "\n" ++
                    \\    }
                    \\  }
                    \\}
                ,
                .variables = .{
                    .owner = ctx.owner,
                    .name = ctx.name,
                    .cursor = if (page) |p| p.followingCursor() else null,
                },
            }, .{});
            defer page_allocator.free(payload);

            const response = try ctx.client.query(page_allocator, struct {
                repository: struct {
                    pullRequests: struct {
                        pageInfo: Page,
                        nodes: []const types.PullRequest,
                    },
                },
            }, payload);
            defer response.deinit();

            try ctx.prs.ensureUnusedCapacity(ctx.cloned_allocator, response.value.repository.pullRequests.nodes.len);
            for (response.value.repository.pullRequests.nodes) |pr|
                ctx.prs.addOneAssumeCapacity().* = try cloneLeaky(ctx.cloned_allocator, pr);

            return clone(page_allocator, response.value.repository.pullRequests.pageInfo);
        }
    };

    try Client.paginate(
        allocator,
        Ctx,
        Ctx.Error,
        Ctx.Page.direction,
        Ctx.queryPage,
        .{
            .client = client,
            .cloned_allocator = cloned_allocator,
            .prs = &prs,
            .owner = owner,
            .name = name,
        },
    );

    cloned.value = try prs.toOwnedSlice(cloned_allocator);
    return cloned;
}

pub fn fetchCommitsByPullRequestId(client: *Client, allocator: std.mem.Allocator, id: []const u8) !Cloned([]const types.Commit) {
    var cloned = try Cloned([]const types.Commit).init(allocator);
    errdefer cloned.deinit();
    const cloned_allocator = cloned.arena.allocator();

    var commits = std.ArrayListUnmanaged(types.Commit){};

    const Ctx = struct {
        client: *Client,

        cloned_allocator: std.mem.Allocator,
        commits: *std.ArrayListUnmanaged(types.Commit),

        id: []const u8,

        const Error = Client.QueryError;
        const Page = Client.PageInfo(.backward);

        fn queryPage(ctx: @This(), page_allocator: std.mem.Allocator, page: ?Page) Error!Cloned(Page) {
            const payload = try std.json.stringifyAlloc(page_allocator, .{
                .query = "" ++
                    \\query(
                    \\  $id: ID!
                    \\  $cursor: String
                    \\) {
                    \\  node(id: $id) {
                    \\    ... on PullRequest {
                    \\      commits(
                ++ std.fmt.comptimePrint("last: {d}\n", .{api.page_size}) ++
                    \\        before: $cursor
                    \\      ) {
                ++ Page.gql ++
                    \\        nodes {
                    \\          commit
                ++ " " ++ comptime api.graphqlPretty(types.Commit, "  ", 5) ++ "\n" ++
                    \\        }
                    \\      }
                    \\    }
                    \\  }
                    \\}
                ,
                .variables = .{
                    .id = ctx.id,
                    .cursor = if (page) |p| p.followingCursor() else null,
                },
            }, .{});
            defer page_allocator.free(payload);

            var response = try ctx.client.query(page_allocator, struct {
                node: struct {
                    commits: struct {
                        pageInfo: Page,
                        nodes: []const struct {
                            commit: types.Commit,
                        },
                    },
                },
            }, payload);
            defer response.deinit();

            try ctx.commits.ensureUnusedCapacity(ctx.cloned_allocator, response.value.node.commits.nodes.len);
            for (response.value.node.commits.nodes) |node|
                ctx.commits.addOneAssumeCapacity().* = try cloneLeaky(ctx.cloned_allocator, node.commit);

            return clone(page_allocator, response.value.node.commits.pageInfo);
        }
    };

    try Client.paginate(
        allocator,
        Ctx,
        Ctx.Error,
        Ctx.Page.direction,
        Ctx.queryPage,
        .{
            .client = client,
            .cloned_allocator = cloned_allocator,
            .commits = &commits,
            .id = id,
        },
    );

    cloned.value = try commits.toOwnedSlice(cloned_allocator);
    return cloned;
}

pub fn fetchCheckSuitesByCommitId(client: *Client, allocator: std.mem.Allocator, id: []const u8) !Cloned([]const types.CheckSuite) {
    var cloned = try Cloned([]const types.CheckSuite).init(allocator);
    errdefer cloned.deinit();
    const cloned_allocator = cloned.arena.allocator();

    var check_suites = std.ArrayListUnmanaged(types.CheckSuite){};

    const Ctx = struct {
        client: *Client,

        cloned_allocator: std.mem.Allocator,
        check_suites: *std.ArrayListUnmanaged(types.CheckSuite),

        id: []const u8,

        const Error = Client.QueryError;
        const Page = Client.PageInfo(.backward);

        fn queryPage(ctx: @This(), page_allocator: std.mem.Allocator, page: ?Page) Error!Cloned(Page) {
            const payload = try std.json.stringifyAlloc(page_allocator, .{
                .query = "" ++
                    \\query(
                    \\  $id: ID!
                    \\  $cursor: String
                    \\) {
                    \\  node(id: $id) {
                    \\    ... on Commit {
                    \\      checkSuites(
                ++ std.fmt.comptimePrint("last: {d}\n", .{api.page_size}) ++
                    \\        before: $cursor
                    \\      ) {
                ++ Page.gql ++
                    \\        nodes
                ++ " " ++ comptime api.graphqlPretty(types.CheckSuite, "  ", 4) ++ "\n" ++
                    \\      }
                    \\    }
                    \\  }
                    \\}
                ,
                .variables = .{
                    .id = ctx.id,
                    .cursor = if (page) |p| p.followingCursor() else null,
                },
            }, .{});
            defer page_allocator.free(payload);

            const response = try ctx.client.query(page_allocator, struct {
                node: struct {
                    checkSuites: struct {
                        pageInfo: Page,
                        nodes: []const types.CheckSuite,
                    },
                },
            }, payload);
            defer response.deinit();

            try ctx.check_suites.ensureUnusedCapacity(ctx.cloned_allocator, response.value.node.checkSuites.nodes.len);
            for (response.value.node.checkSuites.nodes) |check_suite|
                ctx.check_suites.addOneAssumeCapacity().* = try cloneLeaky(ctx.cloned_allocator, check_suite);

            return clone(page_allocator, response.value.node.checkSuites.pageInfo);
        }
    };

    try Client.paginate(
        allocator,
        Ctx,
        Ctx.Error,
        Ctx.Page.direction,
        Ctx.queryPage,
        .{
            .client = client,
            .cloned_allocator = cloned_allocator,
            .check_suites = &check_suites,
            .id = id,
        },
    );

    cloned.value = try check_suites.toOwnedSlice(cloned_allocator);
    return cloned;
}

pub fn fetchCheckRunsByCheckSuiteId(client: *Client, allocator: std.mem.Allocator, id: []const u8) !Cloned([]const types.CheckRun) {
    var cloned = try Cloned([]const types.CheckRun).init(allocator);
    errdefer cloned.deinit();
    const cloned_allocator = cloned.arena.allocator();

    var check_runs = std.ArrayListUnmanaged(types.CheckRun){};

    const Ctx = struct {
        client: *Client,

        cloned_allocator: std.mem.Allocator,
        check_runs: *std.ArrayListUnmanaged(types.CheckRun),

        id: []const u8,

        const Error = Client.QueryError;
        const Page = Client.PageInfo(.backward);

        fn queryPage(ctx: @This(), page_allocator: std.mem.Allocator, page: ?Page) Error!Cloned(Page) {
            const payload = try std.json.stringifyAlloc(page_allocator, .{
                .query = "" ++
                    \\query(
                    \\  $id: ID!
                    \\  $cursor: String
                    \\) {
                    \\  node(id: $id) {
                    \\    ... on CheckSuite {
                    \\      checkRuns(
                ++ std.fmt.comptimePrint("last: {d}\n", .{api.page_size}) ++
                    \\        before: $cursor
                    \\      ) {
                ++ Page.gql ++
                    \\        nodes
                ++ " " ++ comptime api.graphqlPretty(types.CheckRun, "  ", 4) ++ "\n" ++
                    \\      }
                    \\    }
                    \\  }
                    \\}
                ,
                .variables = .{
                    .id = ctx.id,
                    .cursor = if (page) |p| p.followingCursor() else null,
                },
            }, .{});
            defer page_allocator.free(payload);

            const response = try ctx.client.query(page_allocator, struct {
                node: struct {
                    checkRuns: struct {
                        pageInfo: Page,
                        nodes: []const types.CheckRun,
                    },
                },
            }, payload);
            defer response.deinit();

            try ctx.check_runs.ensureUnusedCapacity(ctx.cloned_allocator, response.value.node.checkRuns.nodes.len);
            for (response.value.node.checkRuns.nodes) |check_run|
                ctx.check_runs.addOneAssumeCapacity().* = try cloneLeaky(ctx.cloned_allocator, check_run);

            return clone(page_allocator, response.value.node.checkRuns.pageInfo);
        }
    };

    try Client.paginate(
        allocator,
        Ctx,
        Ctx.Error,
        Ctx.Page.direction,
        Ctx.queryPage,
        .{
            .client = client,
            .cloned_allocator = cloned_allocator,
            .check_runs = &check_runs,
            .id = id,
        },
    );

    cloned.value = try check_runs.toOwnedSlice(cloned_allocator);
    return cloned;
}
