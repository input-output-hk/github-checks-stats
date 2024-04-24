const std = @import("std");

pub const DateTime = struct {
    inner: Inner,

    const Inner = @import("datetime").datetime.Datetime;

    // TODO support time zones other than UTC
    // TODO upstream
    /// Parse datetime in format YYYY-MM-DDTHH:MM:SSZ. Numbers must be zero padded.
    pub fn parseIso(ymdhmsz: []const u8) !DateTime {
        const value = std.mem.trim(u8, ymdhmsz, " ");

        if (value.len < 19 or value.len > 20) return error.InvalidFormat;

        const year = std.fmt.parseInt(u16, value[0..4], 10) catch return error.InvalidFormat;
        const month = std.fmt.parseInt(u8, value[5..7], 10) catch return error.InvalidFormat;
        const day = std.fmt.parseInt(u8, value[8..10], 10) catch return error.InvalidFormat;

        const hour = std.fmt.parseInt(u8, value[11..13], 10) catch return error.InvalidFormat;
        const minute = std.fmt.parseInt(u8, value[14..16], 10) catch return error.InvalidFormat;
        const second = std.fmt.parseInt(u8, value[17..19], 10) catch return error.InvalidFormat;

        if (value.len == 20 and std.ascii.toUpper(value[19]) != 'Z') return error.InvalidFormat;

        return .{ .inner = try Inner.create(year, month, day, hour, minute, second, 0, null) };
    }

    pub fn format(self: @This(), comptime fmt: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        const with_micro = comptime std.mem.indexOfScalar(u8, fmt, '.') != null;

        var buf: [25 + if (with_micro) 7 else 0]u8 = undefined;
        const iso = try self.inner.formatISO8601Buf(&buf, with_micro);
        std.debug.assert(iso.len == buf.len);
        try writer.writeAll(iso);
    }

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
        const iso = try std.json.innerParse([]const u8, allocator, source, options);
        return parseIso(iso) catch return error.UnexpectedToken;
    }

    pub fn jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) !@This() {
        const iso = try std.json.innerParseFromValue([]const u8, allocator, source, options);
        return parseIso(iso) catch return error.UnexpectedToken;
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
};

pub const CheckStatusState = enum {
    REQUESTED,
    QUEUED,
    IN_PROGRESS,
    COMPLETED,
    WAITING,
    PENDING,
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
