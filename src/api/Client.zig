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
    error{ StreamTooLong, QueryFailed };

pub fn query(self: *@This(), allocator: std.mem.Allocator, comptime Data: type, payload: []const u8) QueryError!api.Cloned(Data) {
    var response = std.ArrayList(u8).init(allocator);
    defer response.deinit();

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
    if (result.status != .ok) {
        std.log.err("query failed with code {s}: {s}", .{ @tagName(result.status), response.items });
        return error.QueryFailed;
    }

    std.log.debug("GitHub response (raw): {s}", .{response.items});

    const parsed = std.json.parseFromSlice(
        struct {
            data: ?Data = null,
            errors: []const std.json.Value = &.{},
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
    if (parsed.value.errors.len != 0) return error.QueryFailed;

    return if (parsed.value.data) |data|
        try api.clone(allocator, data)
    else
        error.QueryFailed;
}

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
