const std = @import("std");
const builtin = @import("builtin");

const utils = @import("utils");

const api = @import("../api.zig");

arena: std.heap.ArenaAllocator,

client: std.http.Client,

endpoint: std.Uri,
user_agent: ?[]const u8,
authorization: ?[]const u8,

/// When the rate limit resets (UTC).
rate_limit_reset: ?std.Io.Timestamp = null,

pub fn deinit(self: *@This()) void {
    self.client.deinit();
    self.arena.deinit();
}

/// `user_agent` must outlive this instance.
pub fn init(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
    user_agent: ?[]const u8,
    token: ?[]const u8,
) !@This() {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const arena_allocator = arena.allocator();

    var client = std.http.Client{
        .io = io,
        .allocator = allocator,
    };
    errdefer client.deinit();

    try client.initDefaultProxies(arena_allocator, environ_map);

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
    std.http.Client.FetchError ||
    std.json.ParseError(std.json.Scanner) ||
    error{ QueryFailed, RateLimited };

/// If `error.RateLimited` is returned, `rate_limit_reset` is non-null.
pub fn query(self: *@This(), allocator: std.mem.Allocator, comptime Data: type, payload: []const u8) QueryError!api.Cloned(Data) {
    var response_body = std.Io.Writer.Allocating.init(allocator);
    defer response_body.deinit();

    response_body.clearRetainingCapacity();

    var request = try self.client.request(.POST, self.endpoint, .{
        .headers = .{
            .authorization = if (self.authorization) |authorization| .{ .override = authorization } else .default,
            .user_agent = if (self.user_agent) |user_agent| .{ .override = user_agent } else .default,
        },
        .extra_headers = &.{
            // https://docs.github.com/en/graphql/guides/migrating-graphql-global-node-ids
            // https://github.blog/2021-11-16-graphql-global-id-migration-update/
            .{ .name = "X-Github-Next-Global-ID", .value = "1" },
        },
    });
    defer request.deinit();

    request.transfer_encoding = .{ .content_length = payload.len };
    {
        var body_buffer: [utils.mem.b_per_kib]u8 = undefined;
        var body_w = try request.sendBodyUnflushed(&body_buffer);

        try body_w.writer.writeAll(payload);
        try body_w.end();
        try body_w.flush();
    }

    var response = response: {
        var redirect_buffer: [8000]u8 = undefined;
        break :response try request.receiveHead(&redirect_buffer);
    };

    {
        // https://docs.github.com/en/graphql/overview/rate-limits-and-query-limits-for-the-graphql-api#exceeding-the-rate-limit
        // We need to read headers now as they are invalidated once the response body is initialized.
        self.rate_limit_reset = null;
        var headers = response.head.iterateHeaders();
        while (headers.next()) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, "retry-after")) {
                const duration_secs = try std.fmt.parseInt(i64, header.value, 10);
                self.rate_limit_reset = std.Io.Timestamp.now(self.client.io, .real).addDuration(.fromSeconds(duration_secs));
            } else if (std.ascii.eqlIgnoreCase(header.name, "x-ratelimit-reset")) {
                const timestamp_secs = try std.fmt.parseInt(i96, header.value, 10);
                self.rate_limit_reset = std.Io.Timestamp.fromNanoseconds(timestamp_secs * std.time.ns_per_s);
            }
        }
    }

    {
        const decompress_buffer: []u8 = switch (response.head.content_encoding) {
            .identity => &.{},
            .zstd => try allocator.alloc(u8, std.compress.zstd.default_window_len),
            .deflate, .gzip => try allocator.alloc(u8, std.compress.flate.max_window_len),
            .compress => return std.http.Client.FetchError.UnsupportedCompressionMethod,
        };
        defer allocator.free(decompress_buffer);

        var transfer_buffer: [64]u8 = undefined;
        var decompress: std.http.Decompress = undefined;
        const response_body_reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);

        _ = try response_body_reader.streamRemaining(&response_body.writer);
    }

    if (response.head.status != .ok) {
        std.log.warn("query failed with code {d} ({s})\n{s}", .{
            @intFromEnum(response.head.status),
            response.head.status.phrase() orelse "unknown",
            response_body.written(),
        });
        return error.QueryFailed;
    }

    std.log.debug("GitHub response (raw): {s}", .{response_body.written()});

    const parsed = std.json.parseFromSlice(
        struct {
            data: ?Data = null,
            errors: []const ResultError = &.{},
            extensions: struct {
                warnings: []const std.json.Value = &.{},
            } = .{},
        },
        allocator,
        response_body.written(),
        .{ .ignore_unknown_fields = true },
    ) catch |err| {
        std.log.err("failed to parse response from GitHub: {s}", .{@errorName(err)});
        return err;
    };
    defer parsed.deinit();

    for (parsed.value.extensions.warnings) |warning| {
        const warning_json = try std.json.Stringify.valueAlloc(allocator, warning, .{ .whitespace = .indent_tab });
        defer allocator.free(warning_json);

        std.log.warn("GitHub responded with warning: {s}", .{warning_json});
    }

    var rate_limited = false;
    for (parsed.value.errors) |err| {
        if (if (err.type) |t| t == .RATE_LIMIT else false) {
            rate_limited = true;
        } else {
            const err_json = try std.json.Stringify.valueAlloc(allocator, err, .{ .whitespace = .indent_tab });
            defer allocator.free(err_json);

            std.log.err("GitHub responded with error: {s}", .{err_json});
        }
    }
    if (rate_limited) {
        if (self.rate_limit_reset == null)
            self.rate_limit_reset = std.Io.Timestamp.now(self.client.io, .real).addDuration(.fromSeconds(std.time.s_per_min));
        std.debug.assert(self.rate_limit_reset != null);
        return error.RateLimited;
    }
    for (parsed.value.errors) |err| {
        if (err.locations != null or
            err.path != null) continue;

        if (std.ascii.indexOfIgnoreCase(err.message, "error") != null) return error.QueryFailed;
    }
    if (parsed.value.errors.len != 0) return error.QueryFailed;

    return if (parsed.value.data) |data|
        api.clone(allocator, data)
    else
        error.QueryFailed;
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
        RATE_LIMIT,
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

pub fn PageIterator(
    Variables: type,
    Response: type,
    direction: PaginateDirection,
) type {
    const Client = @This();

    return struct {
        client: *Client,
        arena: std.heap.ArenaAllocator,
        /// How `arena` will be reset when calling `next()`.
        arena_reset_mode: std.heap.ArenaAllocator.ResetMode,
        /// Must be set after calling `next()` to continue iteration!
        page: ?@This().PageInfo = null,
        // Might as well be comptime but let's not blow up the binary.
        /// Must use a `$cursor` variable.
        gql: []const u8,
        /// Variables in addition to `$cursor` provided to `gql`.
        variables: Variables,

        pub const PageInfo = Client.PageInfo(direction);

        pub fn deinit(self: @This()) void {
            self.arena.deinit();
        }

        /// No need to deinit the response
        /// as it is freed on the next call.
        pub fn next(self: *@This()) Client.QueryError!?Response {
            _ = self.arena.reset(self.arena_reset_mode);

            if (self.page) |page|
                if (!page.hasFollowingPage())
                    return null
                else if (api.peek_only) {
                    std.log.debug("more pages available but not fetching to avoid exhausting GitHub rate limit", .{});
                    return null;
                };

            const allocator = self.arena.allocator();

            var payload = try std.Io.Writer.Allocating.initCapacity(allocator, self.gql.len);
            defer payload.deinit();

            var stringify = std.json.Stringify{
                .writer = &payload.writer,
            };

            {
                try stringify.beginObject();

                try stringify.objectField("query");
                try stringify.write(self.gql);

                try stringify.objectField("variables");
                {
                    try stringify.beginObject();

                    try stringify.objectField("cursor");
                    try stringify.write(if (self.page) |p| p.followingCursor() else null);

                    inline for (std.meta.fields(Variables)) |field| {
                        try stringify.objectField(field.name);
                        try stringify.write(@field(self.variables, field.name));
                    }

                    try stringify.endObject();
                }

                try stringify.endObject();
            }

            // We can discard the `api.Cloned()` wrapper because we know
            // that it was allocated with our `self.arena` anyway.
            return (try self.client.query(allocator, Response, payload.written())).value;
        }
    };
}

pub fn pageIterator(
    self: *@This(),
    allocator: std.mem.Allocator,
    gql: []const u8,
    variables: anytype,
    Response: type,
    comptime direction: PaginateDirection,
) PageIterator(@TypeOf(variables), Response, direction) {
    return .{
        .client = self,
        .arena = .init(allocator),
        .arena_reset_mode = .{ .retain_with_limit = gql.len + @sizeOf(api.Cloned(Response)) },
        .gql = gql,
        .variables = variables,
    };
}

pub const PaginateDirection = enum { forward, backward, both };

pub fn PageInfo(paginate_direction: PaginateDirection) type {
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

        pub fn clone(self: @This(), allocator: std.mem.Allocator) std.mem.Allocator.Error!@This() {
            var cloned: @This() = undefined;

            if (has_forward) cloned.endCursor = try allocator.dupe(u8, self.endCursor);
            errdefer if (has_forward) allocator.free(cloned.endCursor);

            if (has_backward) cloned.startCursor = try allocator.dupe(u8, self.startCursor);
            errdefer if (has_backward) allocator.free(cloned.startCursor);

            return cloned;
        }

        pub fn deinit(self: @This(), allocator: std.mem.Allocator) void {
            if (has_forward) allocator.free(self.endCursor);
            if (has_backward) allocator.free(self.startCursor);
        }

        // skip `void` fields because otherwise they cause an error

        pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
            return fromNonVoid(try std.json.innerParse(SelfNonVoid, allocator, source, options));
        }

        pub fn jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) !@This() {
            return fromNonVoid(try std.json.parseFromValueLeaky(SelfNonVoid, allocator, source, options));
        }

        const SelfNonVoid = blk: {
            const info = @typeInfo(@This()).@"struct";

            var field_names: [info.fields.len][]const u8 = undefined;
            var field_types: [info.fields.len]type = undefined;
            var field_attrs: [info.fields.len]std.builtin.Type.StructField.Attributes = undefined;

            var fields_count = 0;
            for (info.fields) |field| {
                if (field.type == void) continue;
                field_names[fields_count] = field.name;
                field_types[fields_count] = field.type;
                field_attrs[fields_count] = .{
                    .@"comptime" = field.is_comptime,
                    .@"align" = field.alignment,
                    .default_value_ptr = field.default_value_ptr,
                };
                fields_count += 1;
            }

            break :blk @Struct(.auto, info.backing_integer, field_names[0..fields_count], field_types[0..fields_count], field_attrs[0..fields_count]);
        };

        fn fromNonVoid(non_void: SelfNonVoid) @This() {
            var self: @This() = undefined;
            inline for (comptime std.meta.fieldNames(SelfNonVoid)) |field_name|
                @field(self, field_name) = @field(non_void, field_name);
            return self;
        }
    };
}
