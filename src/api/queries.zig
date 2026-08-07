const std = @import("std");

const api = @import("../api.zig");
const types = api.types;
const Client = api.Client;
const clone = api.clone;
const cloneLeaky = api.cloneLeaky;
const Cloned = api.Cloned;

pub const Repository = struct {
    id: types.Id,
    owner: struct {
        login: []const u8,
    },
    name: []const u8,
    defaultBranchRef: ?Ref = null,
    createdAt: types.DateTime,
    updatedAt: types.DateTime,
    archivedAt: ?types.DateTime = null,
    pushedAt: ?types.DateTime = null,
};

pub fn fetchRepoByFullName(
    allocator: std.mem.Allocator,
    client: *Client,
    owner: []const u8,
    name: []const u8,
) !Cloned(Repository) {
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
        ++ " " ++ comptime api.graphqlPretty(Repository, "  ", 3) ++ "\n" ++
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
        repository: ?Repository,
    }, payload);
    defer response.deinit();

    return try clone(allocator, response.value.repository.?);
}

pub const Ref = struct {
    id: types.Id,
    prefix: []const u8,
    name: []const u8,
    target: struct {
        oid: []const u8,
    },
};

pub fn fetchRef(
    allocator: std.mem.Allocator,
    client: *Client,
    repo_owner: []const u8,
    repo_name: []const u8,
    ref: []const u8,
) !?Cloned(Ref) {
    const payload = try std.json.Stringify.valueAlloc(allocator, .{
        .query = "" ++
            \\query(
            \\  $repoOwner: String!
            \\  $repoName: String!
            \\  $qualifiedName: String!
            \\) {
            \\  repository(
            \\    owner: $repoOwner
            \\    name: $repoName
            \\  ) {
            \\    ref(qualifiedName: $qualifiedName)
        ++ " " ++ comptime api.graphqlPretty(Ref, "  ", 3) ++ "\n" ++
            \\  }
            \\}
        ,
        .variables = .{
            .repoOwner = repo_owner,
            .repoName = repo_name,
            .qualifiedName = ref,
        },
    }, .{});
    defer allocator.free(payload);

    const response = try client.query(allocator, struct {
        repository: ?struct {
            ref: ?Ref,
        },
    }, payload);
    defer response.deinit();

    return if (response.value.repository.?.ref) |r|
        try clone(allocator, r)
    else
        null;
}

pub const PullRequest = struct {
    id: types.Id,
    resourcePath: []const u8,

    number: types.Int,
    state: types.PullRequestState,
    createdAt: types.DateTime,
    updatedAt: types.DateTime,
    publishedAt: ?types.DateTime = null,
    mergedAt: ?types.DateTime = null,
    closedAt: ?types.DateTime = null,
    headRefOid: []const u8,
    commits: struct {
        /// Either length 0 or 1.
        /// Has only the first/oldest commit.
        nodes: []const struct {
            commit: struct {
                parents: struct {
                    /// Either length 0 or 1.
                    /// Has only the first parent.
                    nodes: []const struct {
                        oid: []const u8,
                    },

                    pub fn graphql(options: api.GraphqlOptions) []const u8 {
                        var opts = options;
                        opts.custom.root = false;

                        return "(first: 1) " ++ api.graphql(@This(), opts);
                    }
                },
            },
        },

        pub fn graphql(options: api.GraphqlOptions) []const u8 {
            var opts = options;
            opts.custom.root = false;

            return "(first: 1) " ++ api.graphql(@This(), opts);
        }
    },

    /// The first parent of the oldest commit in the PR.
    /// Null if the PR has no commits or the oldest commit has no parent.
    /// `baseRefOid` is not equivalent: It tracks the base branch's current tip.
    pub fn mergeBaseOid(self: @This()) ?[]const u8 {
        if (self.commits.nodes.len == 0) return null;
        const first_commit = self.commits.nodes[0].commit;
        if (first_commit.parents.nodes.len == 0) return null;
        return first_commit.parents.nodes[0].oid;
    }
};

pub fn fetchPullRequestsByIds(
    allocator: std.mem.Allocator,
    client: *Client,
    ids: []const types.Id,
) !Cloned([]const PullRequest) {
    const payload = try std.json.Stringify.valueAlloc(allocator, .{
        .query = "" ++
            \\query(
            \\  $ids: [ID!]!
            \\) {
            \\  nodes(ids: $ids) {
            \\    ... on PullRequest
        ++ " " ++ comptime api.graphqlPretty(PullRequest, "  ", 3) ++ "\n" ++
            \\  }
            \\}
        ,
        .variables = .{
            .ids = ids,
        },
    }, .{});
    defer allocator.free(payload);

    const response = try client.query(allocator, struct { nodes: []const PullRequest }, payload);
    defer response.deinit();

    return try clone(allocator, response.value.nodes);
}

pub fn fetchPullRequestsByRepo(
    allocator: std.mem.Allocator,
    client: *Client,
    owner: []const u8,
    name: []const u8,
    states: ?[]const types.PullRequestState,
) !Cloned([]const PullRequest) {
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
    ++ " " ++ comptime api.graphqlPretty(PullRequest, "  ", 3) ++ "\n" ++
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
                    nodes: []const PullRequest,
                },
            },
        },
        PageInfo.direction,
    );
    defer iter.deinit();

    var cloned = try Cloned([]const PullRequest).init(allocator);
    errdefer cloned.deinit();
    const cloned_allocator = cloned.arena.allocator();

    var prs = std.ArrayList(PullRequest).empty;

    while (try iter.next()) |response| {
        defer iter.page = response.repository.pullRequests.pageInfo;

        try prs.ensureUnusedCapacity(cloned_allocator, response.repository.pullRequests.nodes.len);
        for (response.repository.pullRequests.nodes) |pr|
            prs.appendAssumeCapacity(try cloneLeaky(cloned_allocator, pr));
    }

    cloned.value = try prs.toOwnedSlice(cloned_allocator);
    return cloned;
}

pub const Commit = struct {
    id: types.Id,
    resourcePath: []const u8,

    oid: []const u8,
    authoredDate: types.DateTime,
    committedDate: types.DateTime,
    parents: struct {
        nodes: []const struct {
            id: types.Id,
            oid: []const u8,
        },
        totalCount: usize,

        /// Fetches only the first page.
        pub fn graphql(options: api.GraphqlOptions) []const u8 {
            var opts = options;
            opts.custom.root = false;

            return std.fmt.comptimePrint("(first: {d}) {s}", .{
                api.page_size,
                api.graphql(@This(), opts),
            });
        }
    },
};

pub fn fetchCommitHistoryByRepo(
    allocator: std.mem.Allocator,
    client: *Client,
    repo_id: types.Id,
    head_oid: []const u8,
    stop_oid: ?[]const u8,
    max_commits: ?usize,
) !Cloned([]const Commit) {
    const PageInfo = Client.PageInfo(.forward);
    var iter = client.pageIterator(
        allocator,
        \\query(
        \\  $repoId: ID!
        \\  $headOid: GitObjectID!
        \\  $cursor: String
        \\) {
        \\  node(id: $repoId) {
        \\    ... on Repository {
        \\      object(oid: $headOid) {
        \\        ... on Commit {
        \\          history(
    ++ std.fmt.comptimePrint("first: {d}\n", .{api.page_size}) ++
        \\            after: $cursor
        \\          ) {
    ++ PageInfo.gql ++
        \\            nodes
    ++ " " ++ comptime api.graphqlPretty(Commit, "  ", 6) ++ "\n" ++
        \\          }
        \\        }
        \\      }
        \\    }
        \\  }
        \\}
    ,
        .{
            .repoId = repo_id,
            .headOid = head_oid,
        },
        struct {
            node: struct {
                object: struct {
                    history: struct {
                        pageInfo: PageInfo,
                        nodes: []const Commit,
                    },
                },
            },
        },
        PageInfo.direction,
    );
    defer iter.deinit();

    var cloned = try Cloned([]const Commit).init(allocator);
    errdefer cloned.deinit();
    const cloned_allocator = cloned.arena.allocator();

    var commits = std.ArrayList(Commit).empty;

    while (try iter.next()) |response| {
        const history = response.node.object.history;

        iter.page = history.pageInfo;
        iter.page.?.hasNextPage = false;

        var take: usize = 0;
        nodes: for (history.nodes) |node| {
            if (max_commits) |max|
                if (commits.items.len + take == max) break;

            if (stop_oid) |oid|
                if (std.mem.eql(u8, node.oid, oid))
                    break :nodes;

            take += 1;
        } else iter.page = history.pageInfo;

        try commits.ensureUnusedCapacity(cloned_allocator, take);
        for (history.nodes[0..take]) |node|
            commits.appendAssumeCapacity(try cloneLeaky(cloned_allocator, node));
    }

    cloned.value = try commits.toOwnedSlice(cloned_allocator);
    return cloned;
}

pub const App = struct {
    id: types.Id,
    slug: []const u8,
    name: []const u8,
    createdAt: types.DateTime,
    updatedAt: types.DateTime,
};

pub const CheckSuite = struct {
    id: types.Id,
    resourcePath: []const u8,

    app: App,
    status: types.CheckStatusState,
    conclusion: ?types.CheckConclusionState = null,
    createdAt: types.DateTime,
    updatedAt: types.DateTime,
};

pub fn fetchCheckSuitesByCommitId(allocator: std.mem.Allocator, client: *Client, id: []const u8) !Cloned([]const CheckSuite) {
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
    ++ " " ++ comptime api.graphqlPretty(CheckSuite, "  ", 4) ++ "\n" ++
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
                    nodes: []const CheckSuite,
                },
            },
        },
        PageInfo.direction,
    );
    defer iter.deinit();

    var cloned = try Cloned([]const CheckSuite).init(allocator);
    errdefer cloned.deinit();
    const cloned_allocator = cloned.arena.allocator();

    var check_suites = std.ArrayList(CheckSuite).empty;

    while (try iter.next()) |response| {
        defer iter.page = response.node.checkSuites.pageInfo;

        try check_suites.ensureUnusedCapacity(cloned_allocator, response.node.checkSuites.nodes.len);
        for (response.node.checkSuites.nodes) |check_suite|
            check_suites.appendAssumeCapacity(try cloneLeaky(cloned_allocator, check_suite));
    }

    cloned.value = try check_suites.toOwnedSlice(cloned_allocator);
    return cloned;
}

pub const CheckRun = struct {
    id: types.Id,
    resourcePath: []const u8,

    name: []const u8,
    startedAt: types.DateTime,
    completedAt: ?types.DateTime,
    externalId: ?[]const u8,
    status: types.CheckStatusState,
    conclusion: ?types.CheckConclusionState = null,
};

pub fn fetchCheckRunsByCheckSuiteId(allocator: std.mem.Allocator, client: *Client, id: []const u8) !Cloned([]const CheckRun) {
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
    ++ " " ++ comptime api.graphqlPretty(CheckRun, "  ", 4) ++ "\n" ++
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
                    nodes: []const CheckRun,
                },
            },
        },
        PageInfo.direction,
    );
    defer iter.deinit();

    var cloned = try Cloned([]const CheckRun).init(allocator);
    errdefer cloned.deinit();
    const cloned_allocator = cloned.arena.allocator();

    var check_runs = std.ArrayList(CheckRun).empty;

    while (try iter.next()) |response| {
        defer iter.page = response.node.checkRuns.pageInfo;

        try check_runs.ensureUnusedCapacity(cloned_allocator, response.node.checkRuns.nodes.len);
        for (response.node.checkRuns.nodes) |check_run|
            check_runs.appendAssumeCapacity(try cloneLeaky(cloned_allocator, check_run));
    }

    cloned.value = try check_runs.toOwnedSlice(cloned_allocator);
    return cloned;
}
