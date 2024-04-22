const std = @import("std");

const api = @import("../api.zig");
const types = api.types;

const Client = api.Client;

const clone = api.clone;
const CloneError = api.CloneError;
const Cloned = api.Cloned;
const cloned = api.cloned;

pub fn fetchPullRequestsByRepo(client: *Client, allocator: std.mem.Allocator, owner: []const u8, name: []const u8) !Cloned([]const types.PullRequest) {
    var prs = std.ArrayListUnmanaged(types.PullRequest){};
    errdefer {
        for (prs.items) |pr| cloned(pr).deinit(allocator);
        prs.deinit(allocator);
    }

    const Ctx = struct {
        client: *Client,

        prs: *std.ArrayListUnmanaged(types.PullRequest),

        allocator: std.mem.Allocator,
        owner: []const u8,
        name: []const u8,

        const Error = Client.QueryError;
        const Page = Client.PageInfo(.forward);

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
                ++ std.fmt.comptimePrint("first: {d}\n", .{api.page_size}) ++
                    \\      orderBy: {
                    \\        field: CREATED_AT
                    \\        direction: ASC
                    \\      }
                    \\      after: $cursor
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
                    .cursor = if (page) |p| p.endCursor else null,
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
            defer response.deinit(page_allocator);

            try ctx.prs.ensureUnusedCapacity(ctx.allocator, response.value.repository.pullRequests.nodes.len);
            for (response.value.repository.pullRequests.nodes) |pr|
                ctx.prs.addOneAssumeCapacity().* = (try clone(ctx.allocator, pr)).value;

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
            .prs = &prs,
            .allocator = allocator,
            .owner = owner,
            .name = name,
        },
    );

    return Cloned([]const types.PullRequest){ .value = try prs.toOwnedSlice(allocator) };
}

pub fn fetchCommitsByPullRequestId(client: *Client, allocator: std.mem.Allocator, id: []const u8) !Cloned([]const types.Commit) {
    var commits = std.ArrayListUnmanaged(types.Commit){};
    errdefer {
        for (commits.items) |commit| cloned(commit).deinit(allocator);
        commits.deinit(allocator);
    }

    const Ctx = struct {
        client: *Client,

        commits: *std.ArrayListUnmanaged(types.Commit),

        allocator: std.mem.Allocator,
        id: []const u8,

        const Error = Client.QueryError;
        const Page = Client.PageInfo(.forward);

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
                ++ std.fmt.comptimePrint("first: {d}\n", .{api.page_size}) ++
                    \\        after: $cursor
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
                    .cursor = if (page) |p| p.endCursor else null,
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
            defer response.deinit(page_allocator);

            try ctx.commits.ensureUnusedCapacity(ctx.allocator, response.value.node.commits.nodes.len);
            for (response.value.node.commits.nodes) |node|
                ctx.commits.addOneAssumeCapacity().* = (try clone(ctx.allocator, node.commit)).value;

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
            .commits = &commits,
            .allocator = allocator,
            .id = id,
        },
    );

    return Cloned([]const types.Commit){ .value = try commits.toOwnedSlice(allocator) };
}

pub fn fetchCheckSuitesByCommitId(client: *Client, allocator: std.mem.Allocator, id: []const u8) !Cloned([]const types.CheckSuite) {
    var check_suites = std.ArrayListUnmanaged(types.CheckSuite){};
    errdefer {
        for (check_suites.items) |check_suite| cloned(check_suite).deinit(allocator);
        check_suites.deinit(allocator);
    }

    const Ctx = struct {
        client: *Client,

        check_suites: *std.ArrayListUnmanaged(types.CheckSuite),

        allocator: std.mem.Allocator,
        id: []const u8,

        const Error = Client.QueryError;
        const Page = Client.PageInfo(.forward);

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
                ++ std.fmt.comptimePrint("first: {d}\n", .{api.page_size}) ++
                    \\        after: $cursor
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
                    .cursor = if (page) |p| p.endCursor else null,
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
            defer response.deinit(page_allocator);

            try ctx.check_suites.ensureUnusedCapacity(ctx.allocator, response.value.node.checkSuites.nodes.len);
            for (response.value.node.checkSuites.nodes) |check_suite|
                ctx.check_suites.addOneAssumeCapacity().* = (try clone(ctx.allocator, check_suite)).value;

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
            .check_suites = &check_suites,
            .allocator = allocator,
            .id = id,
        },
    );

    return Cloned([]const types.CheckSuite){ .value = try check_suites.toOwnedSlice(allocator) };
}

pub fn fetchCheckRunsByCheckSuiteId(client: *Client, allocator: std.mem.Allocator, id: []const u8) !Cloned([]const types.CheckRun) {
    var check_runs = std.ArrayListUnmanaged(types.CheckRun){};
    errdefer {
        for (check_runs.items) |check_run| cloned(check_run).deinit(allocator);
        check_runs.deinit(allocator);
    }

    const Ctx = struct {
        client: *Client,

        check_runs: *std.ArrayListUnmanaged(types.CheckRun),

        allocator: std.mem.Allocator,
        id: []const u8,

        const Error = Client.QueryError;
        const Page = Client.PageInfo(.forward);

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
                ++ std.fmt.comptimePrint("first: {d}\n", .{api.page_size}) ++
                    \\        after: $cursor
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
                    .cursor = if (page) |p| p.endCursor else null,
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
            defer response.deinit(page_allocator);

            try ctx.check_runs.ensureUnusedCapacity(ctx.allocator, response.value.node.checkRuns.nodes.len);
            for (response.value.node.checkRuns.nodes) |check_run|
                ctx.check_runs.addOneAssumeCapacity().* = (try clone(ctx.allocator, check_run)).value;

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
            .check_runs = &check_runs,
            .allocator = allocator,
            .id = id,
        },
    );

    return Cloned([]const types.CheckRun){ .value = try check_runs.toOwnedSlice(allocator) };
}
