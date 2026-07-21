const std = @import("std");

const api = @import("../api.zig");
const types = api.types;
const Client = api.Client;
const clone = api.clone;
const cloneLeaky = api.cloneLeaky;
const Cloned = api.Cloned;

pub fn fetchRepoByFullName(
    allocator: std.mem.Allocator,
    client: *Client,
    owner: []const u8,
    name: []const u8,
) !Cloned(types.Repository) {
    const payload = try std.json.Stringify.valueAlloc(allocator, .{
        .query = "" ++
            \\query(
            \\  $owner: String!
            \\  $name: String!
            \\) {
            \\  repository(
            \\    owner: $owner
            \\    name: $name
            \\  )
        ++ " " ++ comptime api.graphqlPretty(types.Repository, "  ", 3) ++ "\n" ++
            \\}
        ,
        .variables = .{
            .owner = owner,
            .name = name,
        },
    }, .{});
    defer allocator.free(payload);

    const response = try client.query(allocator, struct {
        // Optional because there could be no such repository.
        // GitHub will respond with an error,
        // causing this call to return an error,
        // but also with this JSON field set to null
        // which still needs to parse properly.
        repository: ?types.Repository,
    }, payload);
    defer response.deinit();

    return try clone(allocator, response.value.repository.?);
}

pub fn fetchPullRequestsByIds(
    allocator: std.mem.Allocator,
    client: *Client,
    ids: []const types.Id,
) !Cloned([]const types.PullRequest) {
    const payload = try std.json.Stringify.valueAlloc(allocator, .{
        .query = "" ++
            \\query(
            \\  $ids: [ID!]!
            \\) {
            \\  nodes(ids: $ids) {
            \\    ... on PullRequest
        ++ " " ++ comptime api.graphqlPretty(types.PullRequest, "  ", 3) ++ "\n" ++
            \\  }
            \\}
        ,
        .variables = .{
            .ids = ids,
        },
    }, .{});
    defer allocator.free(payload);

    const response = try client.query(allocator, struct { nodes: []const types.PullRequest }, payload);
    defer response.deinit();

    return try clone(allocator, response.value.nodes);
}

pub fn fetchPullRequestsByRepo(
    allocator: std.mem.Allocator,
    client: *Client,
    owner: []const u8,
    name: []const u8,
    states: ?[]const types.PullRequestState,
) !Cloned([]const types.PullRequest) {
    const PageInfo = Client.PageInfo(.backward);
    var iter = client.pageIterator(
        allocator,
        \\query(
        \\  $owner: String!
        \\  $name: String!
        \\  $cursor: String
        \\  $states: [PullRequestState!]
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
        \\      states: $states
        \\    ) {
    ++ PageInfo.gql ++
        \\      nodes
    ++ " " ++ comptime api.graphqlPretty(types.PullRequest, "  ", 3) ++ "\n" ++
        \\    }
        \\  }
        \\}
    ,
        .{
            .owner = owner,
            .name = name,
            .states = states,
        },
        struct {
            repository: struct {
                pullRequests: struct {
                    pageInfo: PageInfo,
                    nodes: []const types.PullRequest,
                },
            },
        },
        PageInfo.direction,
    );
    defer iter.deinit();

    var cloned = try Cloned([]const types.PullRequest).init(allocator);
    errdefer cloned.deinit();
    const cloned_allocator = cloned.arena.allocator();

    var prs = std.ArrayList(types.PullRequest).empty;

    while (try iter.next()) |response| {
        defer iter.page = response.repository.pullRequests.pageInfo;

        try prs.ensureUnusedCapacity(cloned_allocator, response.repository.pullRequests.nodes.len);
        for (response.repository.pullRequests.nodes) |pr|
            prs.appendAssumeCapacity(try cloneLeaky(cloned_allocator, pr));
    }

    cloned.value = try prs.toOwnedSlice(cloned_allocator);
    return cloned;
}

pub fn fetchCommitsByPullRequestId(allocator: std.mem.Allocator, client: *Client, id: []const u8) !Cloned([]const types.Commit) {
    const PageInfo = Client.PageInfo(.backward);
    var iter = client.pageIterator(
        allocator,
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
    ++ PageInfo.gql ++
        \\        nodes {
        \\          commit
    ++ " " ++ comptime api.graphqlPretty(types.Commit, "  ", 5) ++ "\n" ++
        \\        }
        \\      }
        \\    }
        \\  }
        \\}
    ,
        .{ .id = id },
        struct {
            node: struct {
                commits: struct {
                    pageInfo: PageInfo,
                    nodes: []const struct {
                        commit: types.Commit,
                    },
                },
            },
        },
        PageInfo.direction,
    );
    defer iter.deinit();

    var cloned = try Cloned([]const types.Commit).init(allocator);
    errdefer cloned.deinit();
    const cloned_allocator = cloned.arena.allocator();

    var commits = std.ArrayList(types.Commit).empty;

    while (try iter.next()) |response| {
        defer iter.page = response.node.commits.pageInfo;

        try commits.ensureUnusedCapacity(cloned_allocator, response.node.commits.nodes.len);
        for (response.node.commits.nodes) |node|
            commits.appendAssumeCapacity(try cloneLeaky(cloned_allocator, node.commit));
    }

    cloned.value = try commits.toOwnedSlice(cloned_allocator);
    return cloned;
}

pub fn fetchCommitHistoryByRepo(
    allocator: std.mem.Allocator,
    client: *Client,
    repo_id: types.Id,
    head_oid: []const u8,
    stop_oids: []const []const u8,
    max_commits: ?usize,
) !Cloned([]const types.Commit) {
    const PageInfo = Client.PageInfo(.forward);
    var iter = client.pageIterator(
        allocator,
        \\query(
        \\  $repo_id: ID!
        \\  $head_oid: GitObjectID!
        \\  $cursor: String
        \\) {
        \\  node(id: $repo_id) {
        \\    ... on Repository {
        \\      object(oid: $head_oid) {
        \\        ... on Commit {
        \\          history(
    ++ std.fmt.comptimePrint("first: {d}\n", .{api.page_size}) ++
        \\            after: $cursor
        \\          ) {
    ++ PageInfo.gql ++
        \\            nodes
    ++ " " ++ comptime api.graphqlPretty(types.Commit, "  ", 6) ++ "\n" ++
        \\          }
        \\        }
        \\      }
        \\    }
        \\  }
        \\}
    ,
        .{
            .repo_id = repo_id,
            .head_oid = head_oid,
        },
        struct {
            node: struct {
                object: struct {
                    history: struct {
                        pageInfo: PageInfo,
                        nodes: []const types.Commit,
                    },
                },
            },
        },
        PageInfo.direction,
    );
    defer iter.deinit();

    var cloned = try Cloned([]const types.Commit).init(allocator);
    errdefer cloned.deinit();
    const cloned_allocator = cloned.arena.allocator();

    var commits = std.ArrayList(types.Commit).empty;

    while (try iter.next()) |response| {
        const history = response.node.object.history;

        iter.page = history.pageInfo;
        iter.page.?.hasNextPage = false;

        var take: usize = 0;
        nodes: for (history.nodes) |node| {
            if (max_commits) |max| {
                if (take == max) break;
            } else for (stop_oids) |stop_oid|
                if (std.mem.eql(u8, node.oid, stop_oid)) break :nodes;

            take += 1;
        } else iter.page = history.pageInfo;

        try commits.ensureUnusedCapacity(cloned_allocator, take);
        for (history.nodes[0..take]) |node|
            commits.addOneAssumeCapacity().* = try cloneLeaky(cloned_allocator, node);
    }

    cloned.value = try commits.toOwnedSlice(cloned_allocator);
    return cloned;
}

pub fn fetchCheckSuitesByCommitId(allocator: std.mem.Allocator, client: *Client, id: []const u8) !Cloned([]const types.CheckSuite) {
    const PageInfo = Client.PageInfo(.backward);
    var iter = client.pageIterator(
        allocator,
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
    ++ PageInfo.gql ++
        \\        nodes
    ++ " " ++ comptime api.graphqlPretty(types.CheckSuite, "  ", 4) ++ "\n" ++
        \\      }
        \\    }
        \\  }
        \\}
    ,
        .{ .id = id },
        struct {
            node: struct {
                checkSuites: struct {
                    pageInfo: PageInfo,
                    nodes: []const types.CheckSuite,
                },
            },
        },
        PageInfo.direction,
    );
    defer iter.deinit();

    var cloned = try Cloned([]const types.CheckSuite).init(allocator);
    errdefer cloned.deinit();
    const cloned_allocator = cloned.arena.allocator();

    var check_suites = std.ArrayList(types.CheckSuite).empty;

    while (try iter.next()) |response| {
        defer iter.page = response.node.checkSuites.pageInfo;

        try check_suites.ensureUnusedCapacity(cloned_allocator, response.node.checkSuites.nodes.len);
        for (response.node.checkSuites.nodes) |check_suite|
            check_suites.appendAssumeCapacity(try cloneLeaky(cloned_allocator, check_suite));
    }

    cloned.value = try check_suites.toOwnedSlice(cloned_allocator);
    return cloned;
}

pub fn fetchCheckRunsByCheckSuiteId(allocator: std.mem.Allocator, client: *Client, id: []const u8) !Cloned([]const types.CheckRun) {
    const PageInfo = Client.PageInfo(.backward);
    var iter = client.pageIterator(
        allocator,
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
    ++ PageInfo.gql ++
        \\        nodes
    ++ " " ++ comptime api.graphqlPretty(types.CheckRun, "  ", 4) ++ "\n" ++
        \\      }
        \\    }
        \\  }
        \\}
    ,
        .{ .id = id },
        struct {
            node: struct {
                checkRuns: struct {
                    pageInfo: PageInfo,
                    nodes: []const types.CheckRun,
                },
            },
        },
        PageInfo.direction,
    );
    defer iter.deinit();

    var cloned = try Cloned([]const types.CheckRun).init(allocator);
    errdefer cloned.deinit();
    const cloned_allocator = cloned.arena.allocator();

    var check_runs = std.ArrayList(types.CheckRun).empty;

    while (try iter.next()) |response| {
        defer iter.page = response.node.checkRuns.pageInfo;

        try check_runs.ensureUnusedCapacity(cloned_allocator, response.node.checkRuns.nodes.len);
        for (response.node.checkRuns.nodes) |check_run|
            check_runs.appendAssumeCapacity(try cloneLeaky(cloned_allocator, check_run));
    }

    cloned.value = try check_runs.toOwnedSlice(cloned_allocator);
    return cloned;
}
