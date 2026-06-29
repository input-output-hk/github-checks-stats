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
    app: []const u8,
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

pub const checkRunCountGroupedByRepoAndState = Query(
    \\SELECT
++ " " ++ columnList("repo", [_]Repository.Column{.owner}) ++ " || '/' || " ++ columnList("repo", [_]Repository.Column{.name}) ++
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
    \\JOIN "
++ Repository.table ++
    \\" repo ON
++ " " ++ columnList("repo", [_]Repository.Column{.id}) ++ " = " ++ columnList("cs", [_]CheckSuite.Column{.repository}) ++
    \\
    \\GROUP BY
++ " " ++ columnList("repo", [_]Repository.Column{.id}) ++ ", " ++ columnList("cr", [_]CheckRun.Column{.status, .conclusion}),
    true,
    struct {
        repo: []const u8,
        state: []const u8,
        count: i64,
    },
    @Tuple(&.{}),
);

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
    \\      'FAILURE', 'CANCELLED', 'TIMED_OUT', 'STARTUP_FAILURE',
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
    \\  r.owner || '/' || r.name                                         AS repo,
    \\  a.slug                                                           AS app,
    \\  c.name                                                           AS check_run_name,
    \\  c.first_fail_at,
    \\  c.success_at,
    \\  cast(
    \\    (julianday(c.success_at) - julianday(c.first_fail_at)) * 86400
    \\    AS INTEGER
    \\  )                                                                AS time_to_fix_seconds
    \\FROM cycles c
    \\JOIN repository r ON r.id = c.repository
    \\JOIN app a        ON a.id = c.app
    \\WHERE
    \\  c.first_fail_at IS NOT NULL
    \\  AND c.success_at IS NOT NULL
    \\ORDER BY repo, app, check_run_name, c.first_fail_at
,
    true,
    struct {
        repo: []const u8,
        check_suite_app_slug: []const u8,
        check_run_name: []const u8,
        check_run_first_fail_at: []const u8,
        check_run_success_at: []const u8,
        time_to_fix_seconds: i64,
    },
    @Tuple(&.{}),
);
