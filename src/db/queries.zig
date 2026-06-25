const std = @import("std");
const zeit = @import("zeit");
const utils = @import("utils");
const zqlite_typed = @import("zqlite-typed");

// Use only GitHub's primitive types.
// GraphQL structs are specific to their query.
const types = @import("../api.zig").types;

const Query = zqlite_typed.Query;
const Exec = zqlite_typed.Exec;
const SimpleInsert = zqlite_typed.SimpleInsert;
const SimpleUpsert = zqlite_typed.SimpleUpsert;
const MergedTables = zqlite_typed.MergedTables;
const columnList = zqlite_typed.columnList;

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
    conclusion: ?[]const u8, // TODO make this typed?
    status: []const u8, // TODO make this typed?

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
