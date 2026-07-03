const std = @import("std");

const utils = @import("utils");
const zqlite_typed = @import("zqlite-typed");
const Query = zqlite_typed.Query;
const Exec = zqlite_typed.Exec;
const SimpleInsert = zqlite_typed.SimpleInsert;
const SimpleUpsert = zqlite_typed.SimpleUpsert;
const MergedTables = zqlite_typed.MergedTables;
const columnList = zqlite_typed.columnList;

// Use only GitHub's primitive types.
// GraphQL structs are specific to their query.
const types = @import("../api.zig").types;

pub const Repository = struct {
    id: types.Id,
    owner: []const u8,
    name: []const u8,

    const table = "repository";

    pub const Column = std.meta.FieldEnum(@This());

    pub const insert = SimpleInsert(table, @This());
    pub const upsert = SimpleUpsert(table, @This(), false);

    pub fn SelectById(comptime columns: []const Column) type {
        return Query(
            \\SELECT
        ++ " " ++ columnList(table, columns) ++
            \\
            \\FROM "
        ++ table ++
            \\"
            \\WHERE "
        ++ @tagName(Column.id) ++
            \\" = ?
        ,
            false,
            utils.meta.SubStruct(@This(), .initMany(columns)),
            struct { types.Id },
        );
    }
};

pub const PullRequest = struct {
    id: types.Id,
    repository: types.Id,
    number: types.Int,
    state: []const u8, // TODO make this typed?

    const table = "pull_request";

    pub const Column = std.meta.FieldEnum(@This());

    pub const insert = SimpleInsert(table, @This());
    pub const upsert = SimpleUpsert(table, @This(), false);

    pub fn SelectById(comptime columns: []const Column) type {
        return Query(
            \\SELECT
        ++ " " ++ columnList(table, columns) ++
            \\
            \\FROM "
        ++ table ++
            \\"
            \\WHERE "
        ++ @tagName(Column.id) ++
            \\" = ?
        ,
            false,
            utils.meta.SubStruct(@This(), .initMany(columns)),
            struct { types.Id },
        );
    }

    pub fn SelectByRepoAndStates(columns: []const Column, states: []const types.PullRequestState) type {
        return Query(
            \\SELECT
        ++ " " ++ columnList(table, columns) ++
            \\
            \\FROM "
        ++ table ++
            \\"
            \\JOIN "
        ++ Repository.table ++
            \\" ON
        ++ " " ++ columnList(Repository.table, [_]Repository.Column{.id}) ++ " = " ++ columnList(table, [_]Column{.repository}) ++
            \\
            \\WHERE
            \\
        ++ columnList(Repository.table, [_]Repository.Column{.owner}) ++
            \\ = ?
            \\  AND
        ++ " " ++ columnList(Repository.table, [_]Repository.Column{.name}) ++
            \\ = ?
            \\  AND
        ++ " " ++ columnList(table, [_]Column{.state}) ++
            \\ IN (
        ++ in: {
            var tags: [states.len][]const u8 = undefined;
            for (&tags, states) |*tag, state|
                tag.* = "'" ++ @tagName(state) ++ "'";
            break :in utils.mem.comptimeJoin(&tags, ", ");
        } ++
            \\)
        ,
            true,
            utils.meta.SubStruct(@This(), .initMany(columns)),
            struct {
                @FieldType(Repository, "owner"),
                @FieldType(Repository, "name"),
            },
        );
    }
};

pub const Commit = struct {
    id: types.Id,
    oid: []const u8,

    const table = "commit";

    pub const Column = std.meta.FieldEnum(@This());

    pub const insert = SimpleInsert(table, @This());
    pub const upsert = SimpleUpsert(table, @This(), false);

    pub fn SelectById(comptime columns: []const Column) type {
        return Query(
            \\SELECT
        ++ " " ++ columnList(table, columns) ++
            \\
            \\FROM "
        ++ table ++
            \\"
            \\WHERE "
        ++ @tagName(Column.id) ++
            \\" = ?
        ,
            false,
            utils.meta.SubStruct(@This(), .initMany(columns)),
            struct { types.Id },
        );
    }
};

pub const App = struct {
    id: types.Id,
    slug: []const u8,
    name: []const u8,

    const table = "app";

    pub const Column = std.meta.FieldEnum(@This());

    pub const insert = SimpleInsert(table, @This());
    pub const upsert = SimpleUpsert(table, @This(), true);

    pub fn SelectById(comptime columns: []const Column) type {
        return Query(
            \\SELECT
        ++ " " ++ columnList(table, columns) ++
            \\
            \\FROM "
        ++ table ++
            \\"
            \\WHERE "
        ++ @tagName(Column.id) ++
            \\" = ?
        ,
            false,
            utils.meta.SubStruct(@This(), .initMany(columns)),
            struct { types.Id },
        );
    }
};

pub const CheckSuite = struct {
    id: types.Id,
    repository: types.Id,
    commit: types.Id,
    app: types.Id,
    created_at: []const u8, // TODO make this typed?
    status: []const u8, // TODO make this typed?
    conclusion: ?[]const u8, // TODO make this typed?

    const table = "check_suite";

    pub const Column = std.meta.FieldEnum(@This());

    pub const insert = SimpleInsert(table, @This());
    pub const upsert = SimpleUpsert(table, @This(), true);

    pub fn SelectById(comptime columns: []const Column) type {
        return Query(
            \\SELECT
        ++ " " ++ columnList(table, columns) ++
            \\
            \\FROM "
        ++ table ++
            \\"
            \\WHERE "
        ++ @tagName(Column.id) ++
            \\" = ?
        ,
            false,
            utils.meta.SubStruct(@This(), .initMany(columns)),
            struct { types.Id },
        );
    }
};

pub const CheckRun = struct {
    id: types.Id,
    suite: types.Id,
    name: []const u8,
    started_at: []const u8, // TODO make this typed?
    completed_at: ?[]const u8, // TODO make this typed?
    external_id: ?[]const u8,
    status: []const u8, // TODO make this typed?
    conclusion: ?[]const u8, // TODO make this typed?

    const table = "check_run";

    pub const Column = std.meta.FieldEnum(@This());

    pub const insert = SimpleInsert(table, @This());
    pub const upsert = SimpleUpsert(table, @This(), true);

    pub fn SelectById(comptime columns: []const Column) type {
        return Query(
            \\SELECT
        ++ " " ++ columnList(table, columns) ++
            \\
            \\FROM "
        ++ table ++
            \\"
            \\WHERE "
        ++ @tagName(Column.id) ++
            \\" = ?
        ,
            false,
            utils.meta.SubStruct(@This(), .initMany(columns)),
            struct { types.Id },
        );
    }
};

pub const pullRequestCountGroupedByRepoAndState = Query(
    \\SELECT
++ " " ++ columnList("repo", [_]Repository.Column{.owner}) ++ " || '/' || " ++ columnList("repo", [_]Repository.Column{.name}) ++
    ", " ++ columnList("pr", [_]PullRequest.Column{.state}) ++
    ", count(" ++ columnList("pr", [_]PullRequest.Column{.id}) ++ ")" ++
    \\
    \\FROM "
++ PullRequest.table ++
    \\" pr
    \\JOIN "
++ Repository.table ++
    \\" repo ON
++ " " ++ columnList("repo", [_]Repository.Column{.id}) ++ " = " ++ columnList("pr", [_]PullRequest.Column{.repository}) ++
    \\
    \\GROUP BY
++ " " ++ columnList("repo", [_]Repository.Column{.id}) ++ ", " ++ columnList("pr", [_]PullRequest.Column{.state}),
    true,
    struct {
        repo: []const u8,
        state: @FieldType(PullRequest, "state"),
        count: i64,
    },
    @Tuple(&.{}),
);

pub const checkRunCountGroupedByAppAndRepoAndState = Query(
    \\SELECT
++ " " ++ columnList("app", [_]App.Column{.slug}) ++
    ", " ++ columnList("repo", [_]Repository.Column{.owner}) ++ " || '/' || " ++ columnList("repo", [_]Repository.Column{.name}) ++
    ", coalesce(" ++ columnList("cr", [_]CheckRun.Column{ .conclusion, .status }) ++ ")" ++
    ", count(" ++ columnList("cr", [_]CheckRun.Column{.id}) ++ ")" ++
    \\
    \\FROM "
++ CheckRun.table ++
    \\" cr
    \\JOIN "
++ CheckSuite.table ++
    \\" cs ON
++ " " ++ columnList("cs", [_]CheckSuite.Column{.id}) ++ " = " ++ columnList("cr", [_]CheckRun.Column{.suite}) ++
    \\
    \\JOIN "
++ Repository.table ++
    \\" repo ON
++ " " ++ columnList("repo", [_]Repository.Column{.id}) ++ " = " ++ columnList("cs", [_]CheckSuite.Column{.repository}) ++
    \\
    \\JOIN "
++ App.table ++
    \\" app ON
++ " " ++ columnList("app", [_]App.Column{.id}) ++ " = " ++ columnList("cs", [_]CheckSuite.Column{.app}) ++
    \\
    \\GROUP BY
++ " " ++ columnList("repo", [_]Repository.Column{.id}) ++ ", " ++ columnList("app", [_]App.Column{.slug}) ++ ", " ++ columnList("cr", [_]CheckRun.Column{ .status, .conclusion }),
    true,
    struct {
        app_slug: @FieldType(App, "slug"),
        repo: []const u8,
        state: []const u8,
        count: i64,
    },
    @Tuple(&.{}),
);

pub const TimeToFixCursor = struct {
    fixed_at: ?[]const u8 = null,
    repo_id: ?types.Id = null,
    app_id: ?types.Id = null,
    check_run_name: ?[]const u8 = null,
    cycle: ?i64 = null,

    pub const Tuple = @Tuple(&.{
        @FieldType(@This(), "fixed_at"),
        @FieldType(@This(), "repo_id"),
        @FieldType(@This(), "app_id"),
        @FieldType(@This(), "check_run_name"),
        @FieldType(@This(), "cycle"),
    });

    pub fn deinit(self: @This(), allocator: std.mem.Allocator) void {
        if (self.fixed_at) |fixed_at| allocator.free(fixed_at);
        if (self.repo_id) |repo_id| allocator.free(repo_id);
        if (self.app_id) |app_id| allocator.free(app_id);
        if (self.check_run_name) |check_run_name| allocator.free(check_run_name);
    }

    pub fn dupe(self: @This(), allocator: std.mem.Allocator) std.mem.Allocator.Error!@This() {
        const fixed_at = if (self.fixed_at) |fixed_at| try allocator.dupe(u8, fixed_at) else null;
        errdefer if (fixed_at) |at| allocator.free(at);

        const repo_id = if (self.repo_id) |repo_id| try allocator.dupe(u8, repo_id) else null;
        errdefer if (repo_id) |id| allocator.free(id);

        const app_id = if (self.app_id) |app_id| try allocator.dupe(u8, app_id) else null;
        errdefer if (app_id) |id| allocator.free(id);

        const check_run_name = if (self.check_run_name) |check_run_name| try allocator.dupe(u8, check_run_name) else null;
        errdefer if (check_run_name) |name| allocator.free(name);

        return .{
            .fixed_at = fixed_at,
            .repo_id = repo_id,
            .app_id = app_id,
            .check_run_name = check_run_name,
            .cycle = self.cycle,
        };
    }

    pub fn tuple(self: @This()) Tuple {
        return .{
            self.fixed_at,
            self.repo_id,
            self.app_id,
            self.check_run_name,
            self.cycle,
        };
    }
};

// TODO vibe-coded
pub const timeToFix = Query(
    \\WITH outcomes AS (
    \\  SELECT
    \\    cs.repository,
    \\    cs.app,
    \\    cr.name,
    \\    cr.completed_at,
    \\    cr.conclusion
    \\  FROM check_run cr
    \\  JOIN check_suite cs ON cs.id = cr.suite
    \\  WHERE
    \\    cr.status = 'COMPLETED'
    \\    AND cr.completed_at IS NOT NULL
    \\    AND cr.conclusion IN (
    \\      'FAILURE',
    \\      'CANCELLED',
    \\      'TIMED_OUT',
    \\      'STARTUP_FAILURE',
    \\      'SUCCESS'
    \\    )
    \\  ),
    \\tagged AS (
    \\  SELECT
    \\    *,
    \\    sum(CASE WHEN conclusion = 'SUCCESS' THEN 1 ELSE 0 END) OVER (
    \\      PARTITION BY repository, app, name
    \\      ORDER BY completed_at
    \\      ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
    \\    ) AS cycle
    \\  FROM outcomes
    \\),
    \\cycles AS (
    \\  SELECT
    \\    repository,
    \\    app,
    \\    name,
    \\    cycle,
    \\    min(CASE WHEN conclusion != 'SUCCESS' THEN completed_at END) AS first_fail_at,
    \\    min(CASE WHEN conclusion  = 'SUCCESS' THEN completed_at END) AS success_at
    \\  FROM tagged
    \\  GROUP BY repository, app, name, cycle
    \\)
    \\SELECT
    \\  r.id                                                             AS repo_id,
    \\  r.owner || '/' || r.name                                         AS repo_full,
    \\  a.id                                                             AS app_id,
    \\  a.slug                                                           AS app_slug,
    \\  c.name                                                           AS check_run_name,
    \\  c.cycle,
    \\  c.first_fail_at,
    \\  c.success_at,
    \\  cast(
    \\    (julianday(c.success_at) - julianday(c.first_fail_at)) * 86400
    \\    AS INTEGER
    \\  )                                                                AS broken_duration_seconds
    \\FROM cycles c
    \\JOIN repository r ON r.id = c.repository
    \\JOIN app a        ON a.id = c.app
    \\WHERE
    \\  c.first_fail_at IS NOT NULL
    \\  AND c.success_at IS NOT NULL
    \\  AND (c.success_at, r.id, a.id, c.name, c.cycle) > (
    \\    CASE WHEN ?1 IS NULL THEN '' ELSE ?1 END,
    \\    CASE WHEN ?2 IS NULL THEN '' ELSE ?2 END,
    \\    CASE WHEN ?3 IS NULL THEN '' ELSE ?3 END,
    \\    CASE WHEN ?4 IS NULL THEN '' ELSE ?4 END,
    \\    CASE WHEN ?5 IS NULL THEN -1 ELSE ?5 END
    \\  ) -- cursor
    \\ORDER BY c.success_at, r.id, a.id, c.name, c.cycle -- cursor
,
    true,
    struct {
        repo_id: types.Id,
        repo_full: []const u8,
        app_id: types.Id,
        app_slug: []const u8,
        check_run_name: []const u8,
        cycle: i64,
        broken_at: []const u8,
        fixed_at: []const u8,
        broken_duration_seconds: i64,
    },
    TimeToFixCursor.Tuple,
);
