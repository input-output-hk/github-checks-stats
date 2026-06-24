//! Subset of types needed.
//! https://docs.github.com/en/graphql/reference

const std = @import("std");
const zeit = @import("zeit");

pub const DateTime = struct {
    inner: Inner,

    const Inner = zeit.Time;

    pub fn parseIso8601(text: []const u8) !DateTime {
        return .{.inner = try Inner.fromISO8601(std.mem.trim(u8, text, " "))};
    }

    // TODO support time zones other than UTC
    pub fn format(self: @This(), writer: *std.Io.Writer) !void {
        self.inner.strftime(writer, "%FT%T%z") catch return error.WriteFailed;
    }

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
        const iso = try std.json.innerParse([]const u8, allocator, source, options);
        return parseIso8601(iso) catch return error.UnexpectedToken;
    }

    pub fn jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) !@This() {
        const iso = try std.json.innerParseFromValue([]const u8, allocator, source, options);
        return parseIso8601(iso) catch return error.UnexpectedToken;
    }

    pub fn graphql(comptime _: []const u8, _: comptime_int) ?[]const u8 {
        return null;
    }
};

pub const ID = []const u8;

pub const PullRequest = struct {
    id: ID,
    resourcePath: []const u8,

    number: usize,
    title: []const u8,
};

pub const Commit = struct {
    id: ID,
    resourcePath: []const u8,

    oid: []const u8,
    messageHeadline: []const u8,
};

pub const App = struct {
    name: []const u8,
};

pub const Ref = struct {
    prefix: []const u8,
    name: []const u8,
};

pub const User = struct {
    name: ?[]const u8 = null,
    login: []const u8,
    company: ?[]const u8 = null,
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

    pub fn format(self: @This(), writer: *std.Io.Writer) !void {
        try writer.writeAll(@tagName(self));
    }
};

pub const CheckSuite = struct {
    id: ID,
    resourcePath: []const u8,

    app: App,
    branch: ?Ref = null,
    creator: ?User = null,
    conclusion: ?CheckConclusionState = null,
    status: CheckStatusState,
    createdAt: DateTime,
    updatedAt: DateTime,
};

pub const CheckRun = struct {
    id: ID,
    resourcePath: []const u8,

    name: []const u8,
    startedAt: DateTime,
    completedAt: DateTime,
};
