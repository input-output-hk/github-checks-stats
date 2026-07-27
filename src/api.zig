const std = @import("std");
const builtin = @import("builtin");

pub const Client = @import("api/Client.zig");
pub const queries = @import("api/queries.zig");
pub const types = @import("api/types.zig");

pub const peek_only = builtin.mode == .Debug;

// maximum allowed by GitHub is 100
pub const page_size = if (peek_only) 2 else 100;

pub fn Cloned(comptime T: type) type {
    return struct {
        arena: *std.heap.ArenaAllocator,
        value: T,

        pub fn deinit(self: @This()) void {
            const allocator = self.arena.child_allocator;
            self.arena.deinit();
            allocator.destroy(self.arena);
        }

        pub fn init(allocator: std.mem.Allocator) !@This() {
            return .{
                .arena = arena: {
                    const arena_ptr = try allocator.create(std.heap.ArenaAllocator);
                    errdefer allocator.destroy(arena_ptr);

                    arena_ptr.* = std.heap.ArenaAllocator.init(allocator);

                    break :arena arena_ptr;
                },
                .value = undefined,
            };
        }
    };
}

pub fn clone(allocator: std.mem.Allocator, obj: anytype) std.mem.Allocator.Error!Cloned(@TypeOf(obj)) {
    var cloned = try Cloned(@TypeOf(obj)).init(allocator);
    errdefer cloned.deinit();

    cloned.value = try cloneLeaky(cloned.arena.allocator(), obj);

    return cloned;
}

pub fn cloneLeaky(allocator: std.mem.Allocator, obj: anytype) std.mem.Allocator.Error!@TypeOf(obj) {
    const Obj = @TypeOf(obj);
    switch (@typeInfo(Obj)) {
        .pointer => |pointer| switch (pointer.size) {
            .one, .c => {
                const ptr = try allocator.create(pointer.child);
                ptr.* = try cloneLeaky(allocator, obj.*);
                return ptr;
            },
            .slice => {
                const slice = try allocator.alloc(pointer.child, obj.len);
                for (slice, obj) |*dst, src|
                    dst.* = try cloneLeaky(allocator, src);
                return slice;
            },
            .many => @compileError("cannot clone many-item pointer"),
        },
        .array => {
            var array: Obj = undefined;
            for (&array, obj) |*dst, src|
                dst.* = try cloneLeaky(allocator, src);
            return array;
        },
        .optional => return if (obj) |child| @as(Obj, try cloneLeaky(allocator, child)) else null,
        .int, .float, .vector, .@"enum", .bool => return obj,
        .@"union" => {
            const active_tag = std.meta.activeTag(obj);
            const active_tag_name = @tagName(active_tag);
            const active = @field(obj, active_tag_name);
            return @unionInit(Obj, active_tag_name, try cloneLeaky(allocator, active));
        },
        .@"struct" => |strukt| {
            var cloned: Obj = undefined;
            inline for (strukt.fields) |field|
                @field(cloned, field.name) = try cloneLeaky(allocator, @field(obj, field.name));
            return cloned;
        },
        else => if (@bitSizeOf(Obj) == 0)
            return undefined
        else
            @compileError("cannot clone comptime-only type " ++ @typeName(Obj)),
    }
}

pub fn graphql(T: type) []const u8 {
    return graphqlPretty(T, "", 0);
}

pub fn graphqlPretty(T: type, comptime indent: []const u8, indent_level: comptime_int) []const u8 {
    const info = @typeInfo(T);
    if (info != .@"struct") @compileError("cannot derive GraphQL from type \"" ++ @typeName(T) ++ "\"");

    if (std.meta.hasFn(T, "graphql")) {
        if (@typeInfo(@typeInfo(@TypeOf(T.graphql)).@"fn".return_type.?) == .optional)
            @compileError(@typeName(T) ++ ".graphql() is only allowed to return an optional when in field position");

        const gql = comptime T.graphql(indent, indent_level);

        if (comptime std.mem.trim(u8, gql, &std.ascii.whitespace).len == 0)
            @compileError(@typeName(T) ++ ".graphql() must not return an empty string or only whitespace");

        return gql;
    }

    comptime var gql: []const u8 = "{\n";

    inline for (info.@"struct".fields) |field| {
        const field_indent_level = indent_level + 1;

        gql = gql ++ indent ** field_indent_level ++ field.name;

        if (@as(?type, switch (@typeInfo(field.type)) {
            .@"struct" => field.type,
            .optional => |optional| if (@typeInfo(optional.child) == .@"struct")
                optional.child
            else
                null,
            else => null,
        })) |field_graphql_type| {
            const field_gql: ?[]const u8 = comptime if (std.meta.hasFn(field_graphql_type, "graphql"))
                field_graphql_type.graphql(indent, field_indent_level)
            else
                graphqlPretty(field_graphql_type, indent, field_indent_level);

            if (field_gql) |f_gql| {
                if (comptime std.mem.trim(u8, f_gql, &std.ascii.whitespace).len == 0)
                    @compileError(@typeName(field_graphql_type) ++ ".graphql() must not return an empty string or only whitespace, return null instead");

                gql = gql ++ " " ++ f_gql;
            }
        }

        gql = gql ++ "\n";
    }

    return gql ++ indent ** indent_level ++ "}";
}

test graphqlPretty {
    try std.testing.expectEqualStrings(
        \\{
        \\  foo
        \\  bar {
        \\    baz
        \\    foobar {
        \\      quux
        \\      quax {
        \\      }
        \\    }
        \\  }
        \\}
    , graphqlPretty(struct {
        foo: u0,
        bar: struct {
            baz: u0,
            foobar: struct {
                quux: u0,
                quax: struct {},
            },
        },
    }, "  ", 0));

    try std.testing.expectEqualStrings(
        \\{
        \\  foo {}
        \\  bar
        \\}
    , graphqlPretty(struct {
        foo: struct {
            baz: u0,

            pub fn graphql(comptime _: []const u8, comptime _: comptime_int) []const u8 {
                return "{}";
            }
        },
        bar: struct {
            baz: u0,

            pub fn graphql(comptime _: []const u8, comptime _: comptime_int) ?[]const u8 {
                return null;
            }
        },
    }, "  ", 0));

    try std.testing.expectEqualStrings("bar", graphqlPretty(struct {
        foo: u0,

        pub fn graphql(comptime _: []const u8, comptime _: comptime_int) []const u8 {
            return "bar";
        }
    }, "  ", 0));
}
