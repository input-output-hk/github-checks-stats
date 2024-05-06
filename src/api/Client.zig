const builtin = @import("builtin");
const std = @import("std");

const api = @import("../api.zig");

arena: std.heap.ArenaAllocator,

client: std.http.Client,

endpoint: std.Uri,
user_agent: ?[]const u8,
authorization: ?[]const u8,

pub fn deinit(self: *@This()) void {
    self.client.deinit();
    self.arena.deinit();
}

/// `user_agent` must outlive this instance.
pub fn init(allocator: std.mem.Allocator, user_agent: ?[]const u8, token: ?[]const u8) !@This() {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const arena_allocator = arena.allocator();

    var client = std.http.Client{ .allocator = allocator };
    errdefer client.deinit();

    try client.initDefaultProxies(arena_allocator);

    const authorization = if (token) |t| try std.mem.concat(arena_allocator, u8, &.{ "token ", t }) else null;
    errdefer if (authorization) |a| arena_allocator.free(a);

    if (user_agent) |ua| std.log.debug("User-Agent: {s}", .{ua});
    if (authorization) |a| std.log.debug("Authorization: {s}…", .{a[0 .. "token ghp_".len + 2]});

    return .{
        .arena = arena,
        .client = client,
        .endpoint = try std.Uri.parse("https://api.github.com/graphql"),
        .user_agent = user_agent,
        .authorization = authorization,
    };
}

pub const QueryError =
    std.Uri.ParseError ||
    std.http.Client.Request.WaitError ||
    std.http.Client.Request.ReadError ||
    std.http.Client.Request.FinishError ||
    std.json.ParseError(std.json.Scanner) ||
    error{ StreamTooLong, QueryFailed, RateLimited };

pub fn query(self: *@This(), allocator: std.mem.Allocator, comptime Data: type, payload: []const u8) QueryError!api.Cloned(Data) {
    var response = std.ArrayList(u8).init(allocator);
    defer response.deinit();

    const max_attempts = 5;
    attempts: for (1..max_attempts + 1) |attempt| {
        response.clearRetainingCapacity();

        const result = try self.client.fetch(.{
            .headers = .{
                .authorization = if (self.authorization) |authorization| .{ .override = authorization } else .default,
                .user_agent = if (self.user_agent) |user_agent| .{ .override = user_agent } else .default,
            },
            .extra_headers = &.{
                // https://github.blog/2021-11-16-graphql-global-id-migration-update/
                .{ .name = "X-Github-Next-Global-ID", .value = "1" },
            },
            .method = .POST,
            .location = .{ .uri = self.endpoint },
            .response_storage = .{ .dynamic = &response },
            .payload = payload,
        });

        const attempts_exceeded = attempt == max_attempts;

        if (result.status != .ok) {
            const retry = result.status.class() == .server_error and !attempts_exceeded;

            const msg_fmt = "query failed with code {d} ({s}){s}\n{s}";
            const msg_fmt_args = .{
                @intFromEnum(result.status),
                result.status.phrase() orelse "unknown",
                if (retry) ", retrying…" else "",
                response.items,
            };

            if (retry) {
                std.log.warn(msg_fmt, msg_fmt_args);
                continue;
            } else {
                std.log.err(msg_fmt, msg_fmt_args);
                break;
            }
        }

        std.log.debug("GitHub response (raw): {s}", .{response.items});

        const parsed = std.json.parseFromSlice(
            struct {
                data: ?Data = null,
                errors: []const ResultError = &.{},
                extensions: struct {
                    warnings: []const std.json.Value = &.{},
                } = .{},
            },
            allocator,
            response.items,
            .{ .ignore_unknown_fields = true },
        ) catch |err| {
            std.log.err("failed to parse response from GitHub: {s}", .{@errorName(err)});
            return err;
        };
        defer parsed.deinit();

        for (parsed.value.extensions.warnings) |warning| {
            const warning_json = try std.json.stringifyAlloc(allocator, warning, .{ .whitespace = .indent_tab });
            defer allocator.free(warning_json);

            std.log.warn("GitHub responded with warning: {s}", .{warning_json});
        }

        for (parsed.value.errors) |err| {
            const err_json = try std.json.stringifyAlloc(allocator, err, .{ .whitespace = .indent_tab });
            defer allocator.free(err_json);

            std.log.err("GitHub responded with error: {s}", .{err_json});
        }
        for (parsed.value.errors) |err|
            if (if (err.type) |t| t == .RATE_LIMITED else false) return error.RateLimited;
        for (parsed.value.errors) |err| {
            if (err.locations != null or
                err.path != null) continue;

            if (std.ascii.indexOfIgnoreCase(err.message, "error") != null) continue :attempts;
        }
        if (parsed.value.errors.len != 0) break;

        if (parsed.value.data) |data| return api.clone(allocator, data);

        break;
    }

    return error.QueryFailed;
}

/// https://spec.graphql.org/October2021/#sec-Errors.Error-result-format
const ResultError = struct {
    message: []const u8,
    locations: ?[]const Location = null,
    path: ?[]const PathSegment = null,

    /// non-standard
    type: ?Type,

    pub const Location = struct {
        line: usize,
        column: usize,
    };

    pub const PathSegment = union(enum) {
        key: []const u8,
        index: usize,

        pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
            return switch (try source.peekNextTokenType()) {
                .number => .{ .index = try std.json.innerParse(std.meta.fieldInfo(@This(), .index).type, allocator, source, options) },
                .string => .{ .key = try std.json.innerParse(std.meta.fieldInfo(@This(), .key).type, allocator, source, options) },
                else => error.UnexpectedToken,
            };
        }

        pub fn jsonParseFromValue(_: std.mem.Allocator, source: std.json.Value, _: std.json.ParseOptions) !@This() {
            return switch (source) {
                .integer => |value| .{ .index = value },
                .string => |value| .{ .key = value },
                else => error.UnexpectedToken,
            };
        }

        pub fn jsonStringify(self: @This(), jw: anytype) !void {
            switch (self) {
                inline else => |value| try jw.write(value),
            }
        }
    };

    pub const Type = union(enum) {
        RATE_LIMITED,
        _: []const u8,

        const Tag = std.meta.Tag(@This());

        fn fromString(str: []const u8) @This() {
            inline for (std.meta.fields(@This())) |field| {
                comptime if (std.mem.eql(u8, field.name, std.meta.fieldInfo(@This(), ._).name)) continue;
                if (std.mem.eql(u8, field.name, str)) return @unionInit(@This(), field.name, {});
            } else return .{ ._ = str };
        }

        pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
            const tag = try std.json.innerParse(std.meta.fieldInfo(@This(), ._).type, allocator, source, options);
            errdefer allocator.free(tag);

            const self = fromString(tag);

            if (self != ._) allocator.free(tag);

            return self;
        }

        pub fn jsonParseFromValue(_: std.mem.Allocator, source: std.json.Value, _: std.json.ParseOptions) !@This() {
            return switch (source) {
                .string => |tag| fromString(tag),
                else => error.UnexpectedToken,
            };
        }

        pub fn jsonStringify(self: @This(), jw: anytype) !void {
            try jw.write(switch (self) {
                ._ => |value| value,
                else => |tag| @tagName(tag),
            });
        }
    };
};

pub fn paginate(
    allocator: std.mem.Allocator,
    comptime Ctx: type,
    comptime Errors: type,
    comptime direction: PaginateDirection,
    /// Must return a page that was `clone()`d with the given allocator.
    func: fn (Ctx, std.mem.Allocator, ?PageInfo(direction)) Errors!api.Cloned(PageInfo(direction)),
    ctx: Ctx,
) Errors!void {
    const Page = PageInfo(direction);
    var page: ?api.Cloned(Page) = null;
    while (if (page) |p| p.value.hasFollowingPage() else true) {
        const next_page = try func(ctx, allocator, if (page) |p| p.value else null);
        errdefer next_page.deinit();

        if (page) |*p| p.deinit();
        page = next_page;

        if (api.peek_only) {
            if (page.?.value.hasFollowingPage()) std.log.debug("more pages available but not fetching to avoid exhausting GitHub rate limit", .{});
            page.?.value.hasFollowingPagePtr().* = false;
        }
    } else page.?.deinit();
}

pub const PaginateDirection = enum { forward, backward, both };

pub fn PageInfo(comptime paginate_direction: PaginateDirection) type {
    const has_forward, const has_backward = switch (paginate_direction) {
        .forward => .{ true, false },
        .backward => .{ false, true },
        .both => .{ true, true },
    };

    return struct {
        endCursor: if (has_forward) ?[]const u8 else void,
        hasNextPage: if (has_forward) bool else void,

        startCursor: if (has_backward) ?[]const u8 else void,
        hasPreviousPage: if (has_backward) bool else void,

        pub const direction = paginate_direction;

        pub const gql =
            \\pageInfo {
        ++ (if (has_forward) "endCursor hasNextPage" else "") ++
            " " ++
            (if (has_backward) "startCursor hasPreviousPage" else "") ++
            \\}
        ;

        pub fn hasFollowingPagePtr(self: *@This()) *bool {
            return switch (direction) {
                .forward => &self.hasNextPage,
                .backward => &self.hasPreviousPage,
                .both => @compileError("bi-directional pagination does not have an unambigous following page"),
            };
        }

        pub fn hasFollowingPage(self: @This()) bool {
            var copy = self;
            return copy.hasFollowingPagePtr().*;
        }

        pub fn followingCursor(self: @This()) ?[]const u8 {
            return switch (direction) {
                .forward => self.endCursor,
                .backward => self.startCursor,
                .both => @compileError("bi-directional pagination does not have an unambigous following cursor"),
            };
        }

        // skip `void` fields because otherwise they cause an error

        pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
            return fromNonVoid(try std.json.innerParse(SelfNonVoid, allocator, source, options));
        }

        pub fn jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) !@This() {
            return fromNonVoid(try std.json.parseFromValueLeaky(SelfNonVoid, allocator, source, options));
        }

        const SelfNonVoid = blk: {
            var info = @typeInfo(@This()).Struct;
            info.fields = &.{};
            for (std.meta.fields(@This())) |field| {
                if (field.type == void) continue;
                info.fields = info.fields ++ .{field};
            }
            info.decls = &.{};
            break :blk @Type(.{ .Struct = info });
        };

        fn fromNonVoid(non_void: SelfNonVoid) @This() {
            var self: @This() = undefined;
            inline for (comptime std.meta.fieldNames(SelfNonVoid)) |field_name|
                @field(self, field_name) = @field(non_void, field_name);
            return self;
        }
    };
}
