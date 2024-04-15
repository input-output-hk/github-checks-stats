const builtin = @import("builtin");
const std = @import("std");
const s2s = @import("s2s");

pub const types = @import("api/types.zig");
pub const queries = @import("api/queries.zig");

pub const Client = @import("api/Client.zig");

pub const peek_only = builtin.mode == .Debug;

// maximum allowed by GitHub is 100
pub const page_size = if (peek_only) 2 else 100;

pub const CloneError = std.mem.Allocator.Error || error{ UnexpectedData, EndOfStream };

pub fn Cloned(comptime T: type) type {
    return struct {
        value: T,

        pub fn deinit(self: @This(), allocator: std.mem.Allocator) void {
            // `s2s.free()` needs a mutable pointer
            // but I don't know why and cannot fathom a reason
            // so let's just give it a pointer to a copy.
            var copy = self;
            s2s.free(allocator, T, &copy.value);
        }
    };
}

pub fn cloned(value: anytype) Cloned(@TypeOf(value)) {
    return .{ .value = value };
}

pub fn clone(allocator: std.mem.Allocator, obj: anytype) CloneError!Cloned(@TypeOf(obj)) {
    var serialized = std.ArrayListUnmanaged(u8){};
    defer serialized.deinit(allocator);

    const Obj = @TypeOf(obj);

    try s2s.serialize(serialized.writer(allocator), Obj, obj);

    var stream = std.io.fixedBufferStream(serialized.items);
    return cloned(try s2s.deserializeAlloc(stream.reader(), Obj, allocator));
}
