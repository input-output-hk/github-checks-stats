//! Subset of types needed.
//! https://docs.github.com/en/graphql/reference

// TODO There is no proper way to create types for API objects with GraphQL.
// The type changes based on the query. Most prominently, non-primitive fields
// can introduce type loops. One way to work around this would be
// to fetch only the IDs of non-primitive types in fields, but that negates
// the advantages of GraphQL in the first place.
// This means that these types are only response types for specific queries.
// This is not easily apparent by looking at this file though.
// Improve that by moving them next to their queries instead.

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
        self.inner.gofmt(writer, "2006-01-02T15:04:05Z07:00") catch return error.WriteFailed;
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

pub const Id = []const u8;
pub const Int = i32;

pub const RepositoryOwner = struct {
    id: Id,
    login: []const u8,
};

pub const Repository = struct {
    id: Id,
    owner: RepositoryOwner,
    name: []const u8,
};

pub const PullRequestState = enum {
    OPEN,
    CLOSED,
    MERGED,

    pub fn format(self: @This(), writer: *std.Io.Writer) !void {
        try writer.writeAll(@tagName(self));
    }
};

pub const PullRequest = struct {
    id: Id,
    resourcePath: []const u8,

    number: Int,
    title: []const u8,
    state: PullRequestState,
};

pub const Commit = struct {
    id: Id,
    resourcePath: []const u8,

    oid: []const u8,
    messageHeadline: []const u8,
};

pub const App = struct {
    id: Id,
    slug: []const u8,
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
    id: Id,
    resourcePath: []const u8,

    app: App,
    branch: ?Ref = null,
    creator: ?User = null,
    status: CheckStatusState,
    conclusion: ?CheckConclusionState = null,
    createdAt: DateTime,
    updatedAt: DateTime,
};

pub const CheckRun = struct {
    id: Id,
    resourcePath: []const u8,

    name: []const u8,
    startedAt: DateTime,
    completedAt: ?DateTime,
    externalId: ?[]const u8,
    status: CheckStatusState,
    conclusion: ?CheckConclusionState = null,
};
