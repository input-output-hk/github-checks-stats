//! Primitives and enums shared across GraphQL response types.
//! Object types live next to the queries that produce them (see `queries.zig`).
//! https://docs.github.com/en/graphql/reference

const std = @import("std");

const zeit = @import("zeit");

pub const DateTime = struct {
    inner: Inner,

    const Inner = zeit.Time;

    pub fn fromIso8601(text: []const u8) !DateTime {
        return .{ .inner = try Inner.fromISO8601(std.mem.trim(u8, text, " ")) };
    }

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
        const iso = try std.json.innerParse([]const u8, allocator, source, options);
        return fromIso8601(iso) catch return error.UnexpectedToken;
    }

    pub fn jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) !@This() {
        const iso = try std.json.innerParseFromValue([]const u8, allocator, source, options);
        return fromIso8601(iso) catch return error.UnexpectedToken;
    }

    pub fn graphql(comptime _: []const u8, _: comptime_int) ?[]const u8 {
        return null;
    }

    pub fn fromZqlite(_: std.mem.Allocator, cell: []const u8) !@This() {
        return .{ .inner = try Inner.fromISO8601(cell) };
    }

    pub fn toZqlite(self: @This(), allocator: std.mem.Allocator) ![]const u8 {
        return try std.fmt.allocPrint(allocator, "{f}", .{self});
    }

    // TODO support time zones other than UTC
    pub fn format(self: @This(), writer: *std.Io.Writer) !void {
        self.inner.gofmt(writer, "2006-01-02T15:04:05Z07:00") catch return error.WriteFailed;
    }
};

pub const Id = []const u8;
pub const Int = i32;

pub const PullRequestState = enum {
    OPEN,
    CLOSED,
    MERGED,

    pub fn fromZqlite(_: std.mem.Allocator, cell: []const u8) !@This() {
        return std.meta.stringToEnum(@This(), cell) orelse error.InvalidTag;
    }

    pub fn toZqlite(self: @This(), allocator: std.mem.Allocator) ![]const u8 {
        return try std.fmt.allocPrint(allocator, "{f}", .{self});
    }

    pub fn format(self: @This(), writer: *std.Io.Writer) !void {
        try writer.writeAll(@tagName(self));
    }
};

pub const CheckConclusionState = enum {
    ACTION_REQUIRED,
    TIMED_OUT,
    CANCELLED,
    FAILURE,
    SUCCESS,
    NEUTRAL,
    SKIPPED,
    STARTUP_FAILURE,
    STALE,

    pub fn fromZqlite(_: std.mem.Allocator, cell: []const u8) !@This() {
        return std.meta.stringToEnum(@This(), cell);
    }

    pub fn toZqlite(self: @This(), allocator: std.mem.Allocator) ![]const u8 {
        return try std.fmt.allocPrint(allocator, "{f}", .{self});
    }

    pub fn format(self: @This(), writer: *std.Io.Writer) !void {
        try writer.writeAll(@tagName(self));
    }
};

pub const CheckStatusState = enum {
    REQUESTED,
    QUEUED,
    IN_PROGRESS,
    COMPLETED,
    WAITING,
    PENDING,

    pub fn fromZqlite(_: std.mem.Allocator, cell: []const u8) !@This() {
        return std.meta.stringToEnum(@This(), cell);
    }

    pub fn toZqlite(self: @This(), allocator: std.mem.Allocator) ![]const u8 {
        return try std.fmt.allocPrint(allocator, "{f}", .{self});
    }

    pub fn format(self: @This(), writer: *std.Io.Writer) !void {
        try writer.writeAll(@tagName(self));
    }
};
