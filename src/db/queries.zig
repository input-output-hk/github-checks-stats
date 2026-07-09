const std = @import("std");

const utils = @import("utils");
const zqlite_typed = @import("zqlite-typed");
const Exec = zqlite_typed.Exec;
const Query = zqlite_typed.Query;
const SimpleSelectBy = zqlite_typed.SimpleSelectBy;
const SimpleInsert = zqlite_typed.SimpleInsert;
const SimpleUpsert = zqlite_typed.SimpleUpsert;
const SimpleDelete = zqlite_typed.SimpleDelete;
const fmtIdentifier = zqlite_typed.fmt.fmtIdentifier;
const fmtString = zqlite_typed.fmt.fmtString;
const fmtIdentifierEnumSet = zqlite_typed.fmt.fmtIdentifierEnumSet;
const fmtStringEnumSet = zqlite_typed.fmt.fmtStringEnumSet;

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

    pub fn SelectById(columns: std.enums.EnumSet(Column)) type {
        return SimpleSelectBy(table, @This(), columns, .initOne(.id));
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

    pub fn SelectById(columns: std.enums.EnumSet(Column)) type {
        return SimpleSelectBy(table, @This(), columns, .initOne(.id));
    }

    pub fn SelectByRepoAndStates(
        columns: std.enums.EnumSet(Column),
        states: std.enums.EnumSet(types.PullRequestState),
    ) type {
        return Query(
            std.fmt.comptimePrint(
                \\SELECT {[select]f}
                \\FROM {[pr]f}
                \\JOIN {[repo]f} ON {[repo]f}.{[repo_id]f} = {[pr]f}.{[pr_repository]f}
                \\WHERE
                \\  {[repo]f}.{[repo_owner]f} = ?
                \\  AND {[repo]f}.{[repo_name]f} = ?
                \\  AND {[pr]f}.{[pr_state]f} IN ({[states]f})
            , .{
                .select = fmtIdentifierEnumSet(Column, table, columns, .space),
                .pr = fmtIdentifier(table),
                .pr_repository = fmtIdentifier(@tagName(Column.repository)),
                .pr_state = fmtIdentifier(@tagName(Column.state)),
                .repo = fmtIdentifier(Repository.table),
                .repo_id = fmtIdentifier(@tagName(Repository.Column.id)),
                .repo_owner = fmtIdentifier(@tagName(Repository.Column.owner)),
                .repo_name = fmtIdentifier(@tagName(Repository.Column.name)),
                .states = fmtStringEnumSet(types.PullRequestState, states, .space),
            }),
            true,
            utils.meta.SubStruct(@This(), columns),
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

    pub fn SelectById(columns: std.enums.EnumSet(Column)) type {
        return SimpleSelectBy(table, @This(), columns, .initOne(.id));
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

    pub fn SelectById(columns: std.enums.EnumSet(Column)) type {
        return SimpleSelectBy(table, @This(), columns, .initOne(.id));
    }
};

pub const CheckSuite = struct {
    id: types.Id,
    repository: types.Id,
    commit: types.Id,
    app: types.Id,
    created_at: []const u8, // TODO make this typed?
    updated_at: []const u8, // TODO make this typed?
    status: []const u8, // TODO make this typed?
    conclusion: ?[]const u8, // TODO make this typed?

    const table = "check_suite";

    pub const Column = std.meta.FieldEnum(@This());

    pub const insert = SimpleInsert(table, @This());
    pub const upsert = SimpleUpsert(table, @This(), true);

    pub fn SelectById(columns: std.enums.EnumSet(Column)) type {
        return SimpleSelectBy(table, @This(), columns, .initOne(.id));
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

    pub fn SelectById(columns: std.enums.EnumSet(Column)) type {
        return SimpleSelectBy(table, @This(), columns, .initOne(.id));
    }
};

pub const Scan = struct {
    /// tab-separated list
    repos: []const u8,
    historical: bool,
    repos_idx: i64,
    prss_idx: i64,
    pr: ?types.Id,
    commit: ?types.Id,
    check_suite: ?types.Id,
    updated_at: []const u8, // TODO make this typed?

    const table = "scan";

    pub const Column = std.meta.FieldEnum(@This());

    /// All columns meant to be set by the application, so all except `updated_at`.
    const app_columns = std.enums.EnumSet(Column).full.differenceWith(.initOne(.updated_at));

    pub const insert = SimpleInsert(table, utils.meta.SubStruct(@This(), app_columns));
    pub const upsert = SimpleUpsert(table, utils.meta.SubStruct(@This(), app_columns), true);
    pub const delete = SimpleDelete(table, utils.meta.SubStruct(@This(), .initMany(&.{ .repos, .historical })));

    pub const delete_expired = Exec(
        std.fmt.comptimePrint(
            \\DELETE FROM {[scan]f}
            \\WHERE (julianday('now') - julianday({[updated_at]f})) * {[s_per_day]d} > ?
        , .{
            .scan = fmtIdentifier(table),
            .updated_at = fmtIdentifier(@tagName(Column.updated_at)),
            .s_per_day = std.time.s_per_day,
        }),
        struct { i64 },
    );

    pub fn SelectById(columns: std.enums.EnumSet(Column)) type {
        return SimpleSelectBy(table, @This(), columns, .initMany(&.{ .repos, .historical }));
    }

    pub fn encodeRepos(allocator: std.mem.Allocator, repos: []const []const u8) std.mem.Allocator.Error![]u8 {
        return std.mem.join(allocator, "\t", repos);
    }

    pub fn decodeRepos(repos: []const u8) std.mem.SplitIterator(u8, .scalar) {
        return std.mem.splitScalar(u8, repos, '\t');
    }
};

pub const pullRequestCountGroupedByRepoAndState = Query(
    std.fmt.comptimePrint(
        \\SELECT
        \\  repo.{[repo_owner]f} || '/' || repo.{[repo_name]f},
        \\  pr.{[pr_state]f},
        \\  count(pr.{[pr_id]f})
        \\FROM {[pr]f} pr
        \\JOIN {[repo]f} repo ON repo.{[repo_id]f} = pr.{[pr_repository]f}
        \\GROUP BY repo.{[repo_id]f}, pr.{[pr_state]f}
    , .{
        .pr = fmtIdentifier(PullRequest.table),
        .pr_id = fmtIdentifier(@tagName(PullRequest.Column.id)),
        .pr_repository = fmtIdentifier(@tagName(PullRequest.Column.repository)),
        .pr_state = fmtIdentifier(@tagName(PullRequest.Column.state)),
        .repo = fmtIdentifier(Repository.table),
        .repo_id = fmtIdentifier(@tagName(Repository.Column.id)),
        .repo_owner = fmtIdentifier(@tagName(Repository.Column.owner)),
        .repo_name = fmtIdentifier(@tagName(Repository.Column.name)),
    }),
    true,
    struct {
        repo: []const u8,
        state: @FieldType(PullRequest, "state"),
        count: i64,
    },
    @Tuple(&.{}),
);

pub const checkRunCountGroupedByAppAndRepoAndState = Query(
    std.fmt.comptimePrint(
        \\SELECT
        \\  app.{[app_slug]f},
        \\  repo.{[repo_owner]f} || '/' || repo.{[repo_name]f},
        \\  coalesce(cr.{[cr_conclusion]f}, cr.{[cr_status]f}),
        \\  count(cr.{[cr_id]f})
        \\FROM {[cr]f} cr
        \\JOIN {[cs]f} cs ON cs.{[cs_id]f} = cr.{[cr_suite]f}
        \\JOIN {[repo]f} repo ON repo.{[repo_id]f} = cs.{[cs_repo]f}
        \\JOIN {[app]f} app ON app.{[app_id]f} = {[cs_app]f}
        \\GROUP BY repo.{[repo_id]f}, app.{[app_slug]f}, cr.{[cr_status]f}, cr.{[cr_conclusion]f}
    , .{
        .app = fmtIdentifier(App.table),
        .app_id = fmtIdentifier(@tagName(App.Column.id)),
        .app_slug = fmtIdentifier(@tagName(App.Column.slug)),
        .cs = fmtIdentifier(CheckSuite.table),
        .cs_id = fmtIdentifier(@tagName(CheckSuite.Column.id)),
        .cs_app = fmtIdentifier(@tagName(CheckSuite.Column.app)),
        .cs_repo = fmtIdentifier(@tagName(CheckSuite.Column.repository)),
        .cr = fmtIdentifier(CheckRun.table),
        .cr_id = fmtIdentifier(@tagName(CheckRun.Column.id)),
        .cr_suite = fmtIdentifier(@tagName(CheckRun.Column.suite)),
        .cr_status = fmtIdentifier(@tagName(CheckRun.Column.status)),
        .cr_conclusion = fmtIdentifier(@tagName(CheckRun.Column.conclusion)),
        .repo = fmtIdentifier(Repository.table),
        .repo_id = fmtIdentifier(@tagName(Repository.Column.id)),
        .repo_owner = fmtIdentifier(@tagName(Repository.Column.owner)),
        .repo_name = fmtIdentifier(@tagName(Repository.Column.name)),
    }),
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

    pub const Tuple = utils.meta.FieldsTuple(@This());

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

pub const timeToFix = Query(
    std.fmt.comptimePrint(
        \\WITH outcomes AS (
        \\  SELECT
        \\    cs.{[cs_repository]f}   AS repository,
        \\    cs.{[cs_app]f}          AS app,
        \\    cr.{[cr_name]f}         AS name,
        \\    cr.{[cr_completed_at]f} AS completed_at,
        \\    cr.{[cr_conclusion]f}   AS conclusion
        \\  FROM {[cr]f} cr
        \\  JOIN {[cs]f} cs ON cs.{[cs_id]f} = cr.{[cr_suite]f}
        \\  WHERE
        \\    cr.{[cr_status]f} = {[cr_status_COMPLETED]f}
        \\    AND cr.{[cr_completed_at]f} IS NOT NULL
        \\    AND cr.{[cr_conclusion]f} IN (
        \\      {[cr_conclusion_FAILURE]f},
        \\      {[cr_conclusion_CANCELLED]f},
        \\      {[cr_conclusion_TIMED_OUT]f},
        \\      {[cr_conclusion_STARTUP_FAILURE]f},
        \\      {[cr_conclusion_SUCCESS]f}
        \\    )
        \\  ),
        \\tagged AS (
        \\  SELECT
        \\    *,
        \\    sum(CASE WHEN conclusion = {[cr_conclusion_SUCCESS]f} THEN 1 ELSE 0 END) OVER (
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
        \\    min(CASE WHEN conclusion != {[cr_conclusion_SUCCESS]f} THEN completed_at END) AS first_fail_at,
        \\    min(CASE WHEN conclusion  = {[cr_conclusion_SUCCESS]f} THEN completed_at END) AS success_at
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
        \\    (julianday(c.success_at) - julianday(c.first_fail_at)) * {[s_per_day]d}
        \\    AS INTEGER
        \\  )                                                                AS broken_duration_seconds
        \\FROM cycles c
        \\JOIN {[repo]f} r ON r.id = c.repository
        \\JOIN {[app]f}  a ON a.id = c.app
        \\WHERE
        \\  c.first_fail_at IS NOT NULL
        \\  AND c.success_at IS NOT NULL
        \\  AND (c.success_at, r.{[repo_id]f}, a.{[app_id]f}, c.name, c.cycle) > (
        \\    CASE WHEN ?1 IS NULL THEN '' ELSE ?1 END,
        \\    CASE WHEN ?2 IS NULL THEN '' ELSE ?2 END,
        \\    CASE WHEN ?3 IS NULL THEN '' ELSE ?3 END,
        \\    CASE WHEN ?4 IS NULL THEN '' ELSE ?4 END,
        \\    CASE WHEN ?5 IS NULL THEN -1 ELSE ?5 END
        \\  ) -- cursor
        \\ORDER BY c.success_at, r.{[repo_id]f}, a.{[app_id]f}, c.name, c.cycle -- cursor
    , .{
        .cs = fmtIdentifier(CheckSuite.table),
        .cs_id = fmtIdentifier(@tagName(CheckSuite.Column.id)),
        .cs_repository = fmtIdentifier(@tagName(CheckSuite.Column.repository)),
        .cs_app = fmtIdentifier(@tagName(CheckSuite.Column.app)),
        .cr = fmtIdentifier(CheckRun.table),
        .cr_suite = fmtIdentifier(@tagName(CheckRun.Column.suite)),
        .cr_name = fmtIdentifier(@tagName(CheckRun.Column.name)),
        .cr_status = fmtIdentifier(@tagName(CheckRun.Column.status)),
        .cr_status_COMPLETED = fmtString(@tagName(types.CheckStatusState.COMPLETED)),
        .cr_conclusion_SUCCESS = fmtString(@tagName(types.CheckConclusionState.SUCCESS)),
        .cr_conclusion_STARTUP_FAILURE = fmtString(@tagName(types.CheckConclusionState.STARTUP_FAILURE)),
        .cr_conclusion_TIMED_OUT = fmtString(@tagName(types.CheckConclusionState.TIMED_OUT)),
        .cr_conclusion_CANCELLED = fmtString(@tagName(types.CheckConclusionState.CANCELLED)),
        .cr_conclusion_FAILURE = fmtString(@tagName(types.CheckConclusionState.FAILURE)),
        .cr_completed_at = fmtIdentifier(@tagName(CheckRun.Column.completed_at)),
        .cr_conclusion = fmtIdentifier(@tagName(CheckRun.Column.conclusion)),
        .repo = fmtIdentifier(Repository.table),
        .repo_id = fmtIdentifier(@tagName(Repository.Column.id)),
        .app = fmtIdentifier(App.table),
        .app_id = fmtIdentifier(@tagName(App.Column.id)),
        .s_per_day = std.time.s_per_day,
    }),
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
