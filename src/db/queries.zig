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

pub const CheckState = union(enum) {
    status: types.CheckStatusState,
    conclusion: types.CheckConclusionState,

    pub const Flat = utils.enums.Merged(&.{ types.CheckStatusState, types.CheckConclusionState }, true);

    pub fn unflatten(flat: Flat) @This() {
        return if (std.meta.stringToEnum(types.CheckStatusState, @tagName(flat))) |status|
            .{ .status = status }
        else if (std.meta.stringToEnum(types.CheckConclusionState, @tagName(flat))) |conclusion|
            .{ .conclusion = conclusion }
        else
            unreachable;
    }

    pub fn flatten(self: @This()) Flat {
        return switch (self) {
            inline else => |state| switch (state) {
                inline else => |tag| @field(Flat, @tagName(tag)),
            },
        };
    }

    pub fn fromZqlite(_: std.mem.Allocator, cell: []const u8) !@This() {
        return unflatten(std.meta.stringToEnum(Flat, cell) orelse return error.InvalidTag);
    }

    pub fn toZqlite(self: @This(), allocator: std.mem.Allocator) ![]const u8 {
        return try std.fmt.allocPrint(allocator, "{f}", .{self});
    }
};

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
    state: types.PullRequestState,
    head_ref_oid: []const u8,
    merge_base_oid: ?[]const u8,

    const table = "pull_request";

    pub const Column = std.meta.FieldEnum(@This());

    pub const insert = SimpleInsert(table, @This());
    pub const upsert = SimpleUpsert(table, @This(), true);

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
    repository: types.Id,
    parent: ?types.Id,

    const table = "commit";

    pub const Column = std.meta.FieldEnum(@This());

    pub const insert = SimpleInsert(table, @This());

    /// Preserves `parent` if it was already set.
    pub const upsert = Exec(
        std.fmt.comptimePrint(
            \\INSERT INTO {[commit]f} ({[id]f}, {[oid]f}, {[repository]f}, {[parent]f})
            \\VALUES (?, ?, ?, ?)
            \\ON CONFLICT ({[id]f}) DO UPDATE SET
            \\  {[oid]f} = excluded.{[oid]f},
            \\  {[repository]f} = excluded.{[repository]f},
            \\  {[parent]f} = COALESCE(excluded.{[parent]f}, {[commit]f}.{[parent]f})
        , .{
            .commit = fmtIdentifier(table),
            .id = fmtIdentifier(@tagName(Column.id)),
            .oid = fmtIdentifier(@tagName(Column.oid)),
            .repository = fmtIdentifier(@tagName(Column.repository)),
            .parent = fmtIdentifier(@tagName(Column.parent)),
        }),
        struct {
            types.Id,
            []const u8,
            types.Id,
            ?types.Id,
        },
    );

    pub fn SelectById(columns: std.enums.EnumSet(Column)) type {
        return SimpleSelectBy(table, @This(), columns, .initOne(.id));
    }

    pub fn SelectByOid(columns: std.enums.EnumSet(Column)) type {
        return SimpleSelectBy(table, @This(), columns, .initOne(.oid));
    }
};

pub const Ref = struct {
    id: types.Id,
    repository: types.Id,
    prefix: []const u8,
    name: []const u8,
    target_oid: []const u8,

    const table = "ref";

    pub const Column = std.meta.FieldEnum(@This());

    pub const insert = SimpleInsert(table, @This());
    pub const upsert = SimpleUpsert(table, @This(), true);

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
    created_at: types.DateTime,
    updated_at: types.DateTime,
    status: types.CheckStatusState,
    conclusion: ?types.CheckConclusionState,

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
    started_at: types.DateTime,
    completed_at: ?types.DateTime,
    external_id: ?[]const u8,
    status: types.CheckStatusState,
    conclusion: ?types.CheckConclusionState,

    const table = "check_run";

    pub const Column = std.meta.FieldEnum(@This());

    pub const insert = SimpleInsert(table, @This());
    pub const upsert = SimpleUpsert(table, @This(), true);

    pub fn SelectById(columns: std.enums.EnumSet(Column)) type {
        return SimpleSelectBy(table, @This(), columns, .initOne(.id));
    }
};

pub const Scan = struct {
    repos: SeparatedStrings('\t'),
    historical: bool,
    repos_idx: i64,
    prss_idx: i64,
    pr: ?types.Id,
    commit: ?types.Id,
    check_suite: ?types.Id,
    default_branch_commit: ?types.Id,
    updated_at: types.DateTime,

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
};

fn SeparatedStrings(separator: u8) type {
    return struct {
        items: []const []const u8,

        pub fn fromZqlite(allocator: std.mem.Allocator, cell: []const u8) !@This() {
            var iter = std.mem.splitScalar(u8, cell, separator);

            var items = try std.ArrayList([]const u8).initCapacity(allocator, count: {
                var count: usize = 0;
                while (iter.next()) |_|
                    count += 1;
                iter.reset();
                break :count count;
            });

            errdefer for (items.items) |item|
                allocator.free(item);

            while (iter.next()) |item|
                items.appendAssumeCapacity(try allocator.dupe(u8, item));

            return .{ .items = items };
        }

        pub fn toZqlite(self: @This(), allocator: std.mem.Allocator) ![]const u8 {
            return std.mem.join(allocator, &.{separator}, self.items);
        }
    };
}

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
        state: CheckState,
        count: i64,
    },
    @Tuple(&.{}),
);

pub const TimeToFixCursor = struct {
    fixed_at: ?types.DateTime = null,
    repo_id: ?types.Id = null,
    app_id: ?types.Id = null,
    seed_id: ?types.Id = null,
    cycle: ?i64 = null,

    pub const Tuple = utils.meta.FieldsTuple(@This());

    pub fn deinit(self: @This(), allocator: std.mem.Allocator) void {
        if (self.repo_id) |repo_id| allocator.free(repo_id);
        if (self.app_id) |app_id| allocator.free(app_id);
        if (self.seed_id) |seed_id| allocator.free(seed_id);
    }

    pub fn dupe(self: @This(), allocator: std.mem.Allocator) std.mem.Allocator.Error!@This() {
        const repo_id = if (self.repo_id) |repo_id| try allocator.dupe(u8, repo_id) else null;
        errdefer if (repo_id) |id| allocator.free(id);

        const app_id = if (self.app_id) |app_id| try allocator.dupe(u8, app_id) else null;
        errdefer if (app_id) |id| allocator.free(id);

        const seed_id = if (self.seed_id) |seed_id| try allocator.dupe(u8, seed_id) else null;
        errdefer if (seed_id) |id| allocator.free(id);

        return .{
            .fixed_at = self.fixed_at,
            .repo_id = repo_id,
            .app_id = app_id,
            .seed_id = seed_id,
            .cycle = self.cycle,
        };
    }

    pub fn tuple(self: @This()) Tuple {
        return .{
            self.fixed_at,
            self.repo_id,
            self.app_id,
            self.seed_id,
            self.cycle,
        };
    }
};

/// Limits recursion depth when scanning commit history.
const time_to_fix_history_limit = 250;

pub const timeToFix = Query(
    std.fmt.comptimePrint(
        \\WITH RECURSIVE
        \\  seeds AS (
        \\    SELECT
        \\      r.{[ref_id]f}         AS seed_id,
        \\      r.{[ref_repository]f} AS repository,
        \\      r.{[ref_target_oid]f} AS head_oid,
        \\      NULL                  AS base_oid,
        \\      r.{[ref_name]f}       AS branch
        \\    FROM {[ref]f} r
        \\    UNION ALL
        \\    SELECT
        \\      pr.{[pr_id]f},
        \\      pr.{[pr_repository]f},
        \\      pr.{[pr_head_ref_oid]f},
        \\      pr.{[pr_merge_base_oid]f},
        \\      NULL
        \\    FROM {[pr]f} pr
        \\  ),
        \\  history AS MATERIALIZED (
        \\    SELECT
        \\      s.seed_id,
        \\      s.repository,
        \\      s.branch,
        \\      s.base_oid,
        \\      c.{[commit_id]f}     AS commit_id,
        \\      c.{[commit_parent]f} AS parent,
        \\      0                    AS position
        \\    FROM seeds s
        \\    JOIN {[commit]f} c ON
        \\      c.{[commit_repository]f} = s.repository
        \\      AND c.{[commit_oid]f} = s.head_oid
        \\      -- Guard: a PR with head == base has no commits.
        \\      AND (s.base_oid IS NULL OR c.{[commit_oid]f} != s.base_oid)
        \\    UNION ALL
        \\    SELECT h.seed_id, h.repository, h.branch, h.base_oid, c.{[commit_id]f}, c.{[commit_parent]f}, h.position + 1
        \\    FROM history h
        \\    JOIN {[commit]f} c ON c.{[commit_id]f} = h.parent
        \\    WHERE (h.base_oid IS NULL OR c.{[commit_oid]f} != h.base_oid)
        \\      -- Guard against unlimited walk due to broken parent commit chain.
        \\      AND h.position < {[history_limit]d}
        \\  ),
    , .{
        .commit = fmtIdentifier(Commit.table),
        .commit_id = fmtIdentifier(@tagName(Commit.Column.id)),
        .commit_oid = fmtIdentifier(@tagName(Commit.Column.oid)),
        .commit_repository = fmtIdentifier(@tagName(Commit.Column.repository)),
        .commit_parent = fmtIdentifier(@tagName(Commit.Column.parent)),
        .ref = fmtIdentifier(Ref.table),
        .ref_id = fmtIdentifier(@tagName(Ref.Column.id)),
        .ref_repository = fmtIdentifier(@tagName(Ref.Column.repository)),
        .ref_name = fmtIdentifier(@tagName(Ref.Column.name)),
        .ref_target_oid = fmtIdentifier(@tagName(Ref.Column.target_oid)),
        .pr = fmtIdentifier(PullRequest.table),
        .pr_id = fmtIdentifier(@tagName(PullRequest.Column.id)),
        .pr_repository = fmtIdentifier(@tagName(PullRequest.Column.repository)),
        .pr_head_ref_oid = fmtIdentifier(@tagName(PullRequest.Column.head_ref_oid)),
        .pr_merge_base_oid = fmtIdentifier(@tagName(PullRequest.Column.merge_base_oid)),
        .history_limit = time_to_fix_history_limit,
        // split here to avoid exceeding fmt arg count limit
    }) ++ std.fmt.comptimePrint(
        \\
        \\  ranked_runs AS (
        \\    SELECT
        \\      cs.{[cs_repository]f}   AS repository,
        \\      cs.{[cs_app]f}          AS app,
        \\      cs.{[cs_commit]f}       AS commit_id,
        \\      h.seed_id               AS seed_id,
        \\      h.branch                AS branch,
        \\      h.position              AS position,
        \\      cr.{[cr_conclusion]f}   AS conclusion,
        \\      cr.{[cr_completed_at]f} AS completed_at,
        \\      row_number() OVER (
        \\        PARTITION BY cs.{[cs_repository]f}, cs.{[cs_app]f}, cs.{[cs_commit]f}, cr.{[cr_name]f}
        \\        ORDER BY cr.{[cr_completed_at]f} DESC
        \\      ) AS rn
        \\    FROM history h
        \\    CROSS JOIN {[cs]f} cs ON cs.{[cs_commit]f} = h.commit_id
        \\    CROSS JOIN {[cr]f} cr ON cr.{[cr_suite]f} = cs.{[cs_id]f}
        \\    WHERE
        \\      cr.{[cr_status]f} = {[cr_status_COMPLETED]f}
        \\      AND cr.{[cr_completed_at]f} IS NOT NULL
        \\      AND cr.{[cr_conclusion]f} IN (
        \\        {[cr_conclusion_FAILURE]f},
        \\        {[cr_conclusion_CANCELLED]f},
        \\        {[cr_conclusion_TIMED_OUT]f},
        \\        {[cr_conclusion_STARTUP_FAILURE]f},
        \\        {[cr_conclusion_SUCCESS]f}
        \\      )
        \\  ),
        \\  commit_outcomes AS (
        \\    SELECT
        \\      repository,
        \\      app,
        \\      seed_id,
        \\      branch,
        \\      commit_id,
        \\      -- all rows for one commit share the same lineage position;
        \\      -- min() is just "the value".
        \\      min(position)     AS position,
        \\      max(completed_at) AS at,
        \\      CASE
        \\        WHEN sum(CASE WHEN conclusion != {[cr_conclusion_SUCCESS]f} THEN 1 ELSE 0 END) > 0 THEN 'BROKEN'
        \\        ELSE 'FIXED'
        \\      END AS state
        \\    FROM ranked_runs
        \\    WHERE rn = 1
        \\    GROUP BY repository, app, seed_id, commit_id
        \\  ),
        \\  tagged AS (
        \\    SELECT
        \\      *,
        \\      sum(CASE WHEN state = 'FIXED' THEN 1 ELSE 0 END) OVER (
        \\        PARTITION BY repository, app, seed_id
        \\        ORDER BY position DESC
        \\        ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
        \\      ) AS cycle
        \\    FROM commit_outcomes
        \\  ),
        \\  cycles AS (
        \\    SELECT
        \\      repository,
        \\      app,
        \\      seed_id,
        \\      min(branch) AS branch,
        \\      cycle,
        \\      min(CASE WHEN state != 'FIXED' THEN at END) AS broken_at,
        \\      min(CASE WHEN state  = 'FIXED' THEN at END) AS success_at
        \\    FROM tagged
        \\    GROUP BY repository, app, seed_id, cycle
        \\  )
    , .{
        .cs = fmtIdentifier(CheckSuite.table),
        .cs_id = fmtIdentifier(@tagName(CheckSuite.Column.id)),
        .cs_repository = fmtIdentifier(@tagName(CheckSuite.Column.repository)),
        .cs_app = fmtIdentifier(@tagName(CheckSuite.Column.app)),
        .cs_commit = fmtIdentifier(@tagName(CheckSuite.Column.commit)),
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
        // split here to avoid exceeding fmt arg count limit
    }) ++ std.fmt.comptimePrint(
        \\
        \\SELECT
        \\  r.id                     AS repo_id,
        \\  r.owner || '/' || r.name AS repo_full,
        \\  a.id                     AS app_id,
        \\  a.slug                   AS app_slug,
        \\  c.seed_id                AS seed_id,
        \\  c.branch                 AS branch,
        \\  c.cycle,
        \\  c.broken_at,
        \\  c.success_at,
        \\  cast(
        \\    (julianday(c.success_at) - julianday(c.broken_at)) * {[s_per_day]d}
        \\    AS INTEGER
        \\  ) AS broken_duration_seconds
        \\FROM cycles c
        \\JOIN {[repo]f} r ON r.id = c.repository
        \\JOIN {[app]f}  a ON a.id = c.app
        \\WHERE
        \\  c.broken_at IS NOT NULL
        \\  AND c.success_at IS NOT NULL
        \\  -- Drop cycles where the "fix" completed before the "break": lineage
        \\  -- adjacency puts them in the same cycle but the check-run timestamps
        \\  -- would produce a negative duration.
        \\  AND c.success_at >= c.broken_at
        \\  AND (c.success_at, r.{[repo_id]f}, a.{[app_id]f}, c.seed_id, c.cycle) > (
        \\    CASE WHEN ?1 IS NULL THEN '' ELSE ?1 END,
        \\    CASE WHEN ?2 IS NULL THEN '' ELSE ?2 END,
        \\    CASE WHEN ?3 IS NULL THEN '' ELSE ?3 END,
        \\    CASE WHEN ?4 IS NULL THEN '' ELSE ?4 END,
        \\    CASE WHEN ?5 IS NULL THEN -1 ELSE ?5 END
        \\  ) -- cursor
        \\ORDER BY c.success_at, r.{[repo_id]f}, a.{[app_id]f}, c.seed_id, c.cycle -- cursor
    , .{
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
        seed_id: types.Id,
        branch: ?[]const u8,
        cycle: i64,
        broken_at: types.DateTime,
        fixed_at: types.DateTime,
        broken_duration_seconds: i64,
    },
    TimeToFixCursor.Tuple,
);
