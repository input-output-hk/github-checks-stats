const std = @import("std");

const c = @import("c");
const utils = @import("utils");
const zqlite = @import("zqlite");
const zqlite_typed = @import("zqlite-typed");

pub const queries = @import("db/queries.zig");

pool: *zqlite.Pool,

pub fn deinit(self: @This()) void {
    self.pool.deinit();
}

pub const Options = utils.meta.SubStruct(zqlite.Pool.Config, .initMany(&.{ .path, .flags, .size }));

pub fn init(allocator: std.mem.Allocator, io: std.Io, options: Options) !@This() {
    errdefer |err| std.log.err("could not initialize database: {s}", .{@errorName(err)});

    const self = @This(){
        .pool = try zqlite.Pool.init(allocator, .{
            .path = options.path,
            .flags = options.flags,
            .size = options.size,
            .on_connection = initDbConn,
        }),
    };
    errdefer self.deinit();

    {
        const conn = try self.pool.acquire(io);
        defer self.pool.release(io, conn);

        try migrate(conn);
    }

    return self;
}

fn initDbConn(conn: zqlite.Conn, _: ?*anyopaque) !void {
    try conn.busyTimeout(std.time.ms_per_s);
    try setJournalMode(conn, .WAL);
    try enableForeignKeys(conn);
    enableLogging(conn);
}

fn migrate(conn: zqlite.Conn) !void {
    if (blk: {
        const row = (try conn.row("PRAGMA user_version", .{})).?;
        errdefer row.deinit();

        const user_version = row.int(0);

        try row.deinitErr();

        break :blk user_version == 0;
    }) {
        try conn.transaction();
        errdefer conn.rollback();

        {
            const sql = @embedFile("db/schema.sql");
            try zqlite_typed.logErr(conn, .execNoArgs, .{sql});
        }
        {
            const sql = "PRAGMA user_version = 1";
            try zqlite_typed.logErr(conn, .execNoArgs, .{sql});
        }

        try conn.commit();
    }
}

fn setJournalMode(conn: zqlite.Conn, comptime mode: enum {
    DELETE,
    TRUNCATE,
    PERSIST,
    MEMORY,
    WAL,
    OFF,
}) !void {
    const sql = "PRAGMA journal_mode = " ++ @tagName(mode);
    try zqlite_typed.logErr(conn, .execNoArgs, .{sql});
}

fn enableForeignKeys(conn: zqlite.Conn) !void {
    const sql = "PRAGMA foreign_keys = ON";
    try zqlite_typed.logErr(conn, .execNoArgs, .{sql});
}

pub fn enableLogging(conn: zqlite.Conn) void {
    if (comptime !std.log.logEnabled(.debug, zqlite_typed.options.log_scope)) return;
    _ = c.sqlite3_trace_v2(@ptrCast(conn.conn), c.SQLITE_TRACE_STMT, traceStmt, null);
}

fn traceStmt(event: c_uint, ctx: ?*anyopaque, _: ?*anyopaque, x: ?*anyopaque) callconv(.c) c_int {
    std.debug.assert(event == c.SQLITE_TRACE_STMT);
    std.debug.assert(ctx == null);

    const sql: [*:0]const u8 = @ptrCast(x.?);
    zqlite_typed.log.debug("trace: {f}", .{utils.fmt.fmtOneline(std.mem.span(sql))});

    return 0;
}
