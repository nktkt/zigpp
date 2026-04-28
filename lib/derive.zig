//! Runtime stubs for Zig++'s `derive(.{...})` lowering. The frontend rewrites
//! `} derive(.{ Hash, Json, Debug });` into `pub const x = zpp.derive.X(@This());`
//! decls; the symbols those references resolve to live here. Each generator
//! is a comptime `T -> type` function returning a namespace struct with one
//! deterministic method, so behavior tests can assert byte-exact output.
//!
//! These are stubs by design: real hashing / debug formatting / JSON encoding
//! is future work. The contract this module owns today is that the symbols
//! referenced by the lowering exist and that calling the methods does not
//! crash or allocate.

const std = @import("std");

/// Stub: returns a namespace with `hash(T) u64` that always returns
/// 0xDEADBEEFDEADBEEF. Real hashing is future work.
pub fn Hash(comptime T: type) type {
    return struct {
        pub fn hash(_: T) u64 {
            return 0xDEADBEEFDEADBEEF;
        }
    };
}

/// Stub: returns a namespace with `dump(T) void` that prints `debug ok\n`
/// to stderr. Real debug formatting is future work.
pub fn Debug(comptime T: type) type {
    return struct {
        pub fn dump(_: T) void {
            std.debug.print("debug ok\n", .{});
        }
    };
}

/// Stub: returns a namespace with `json(T, anytype) !void` that writes `{}`.
/// Real JSON encoding is future work.
pub fn Json(comptime T: type) type {
    return struct {
        pub fn json(_: T, w: anytype) !void {
            try w.writeAll("{}");
        }
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "Hash stub returns the fixed sentinel" {
    const S = struct { x: u32 };
    const H = Hash(S);
    const v = S{ .x = 1 };
    try testing.expectEqual(@as(u64, 0xDEADBEEFDEADBEEF), H.hash(v));
}

test "Hash stub is deterministic across distinct values" {
    const S = struct { x: u32 };
    const H = Hash(S);
    try testing.expectEqual(H.hash(.{ .x = 1 }), H.hash(.{ .x = 999 }));
}

test "Debug stub exposes dump method" {
    const S = struct { x: u32 };
    const D = Debug(S);
    // Don't call dump() here — it writes to stderr and would pollute the
    // test output. Just confirm the decl exists with the expected signature.
    try testing.expect(@hasDecl(D, "dump"));
    const FnT = @TypeOf(D.dump);
    const info = @typeInfo(FnT);
    try testing.expect(info == .@"fn");
}

test "Json stub writes {} into a writer" {
    const S = struct { x: u32 };
    const J = Json(S);

    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(testing.allocator);

    const W = struct {
        list: *std.ArrayListUnmanaged(u8),
        allocator: std.mem.Allocator,
        pub fn writeAll(self: @This(), bytes: []const u8) !void {
            try self.list.appendSlice(self.allocator, bytes);
        }
    };
    const w = W{ .list = &buf, .allocator = testing.allocator };

    try J.json(.{ .x = 7 }, w);
    try testing.expectEqualStrings("{}", buf.items);
}
