//! Ownership primitives backing Zig++'s `own` / `move` / `using` keywords.
//! Provides affine wrappers (`Owned`), non-owning views (`Borrow`), an
//! arena RAII scope, and a debug-only deinit-leak detector. None of these
//! types allocate on their own; allocators are passed in explicitly.

const std = @import("std");

pub fn Owned(comptime T: type) type {
    return struct {
        const Self = @This();

        value: T,
        // `moved` and `deinited` only exist in safety builds so release
        // binaries pay zero overhead for the affine bookkeeping.
        moved: if (std.debug.runtime_safety) bool else void =
            if (std.debug.runtime_safety) false else {},
        deinited: if (std.debug.runtime_safety) bool else void =
            if (std.debug.runtime_safety) false else {},

        pub fn init(value: T) Self {
            return .{
                .value = value,
                .moved = if (std.debug.runtime_safety) false else {},
                .deinited = if (std.debug.runtime_safety) false else {},
            };
        }

        pub fn take(self: *Self) T {
            if (std.debug.runtime_safety) {
                if (self.moved) @panic("Owned: use-after-move");
                if (self.deinited) @panic("Owned: use-after-deinit");
                self.moved = true;
            }
            return self.value;
        }

        pub fn ref(self: *Self) *T {
            if (std.debug.runtime_safety) {
                if (self.moved) @panic("Owned: use-after-move");
                if (self.deinited) @panic("Owned: use-after-deinit");
            }
            return &self.value;
        }

        pub fn refConst(self: *const Self) *const T {
            if (std.debug.runtime_safety) {
                if (self.moved) @panic("Owned: use-after-move");
                if (self.deinited) @panic("Owned: use-after-deinit");
            }
            return &self.value;
        }

        pub fn deinit(self: *Self) void {
            if (std.debug.runtime_safety) {
                if (self.moved) @panic("Owned: deinit-after-move");
                if (self.deinited) @panic("Owned: double-deinit");
                self.deinited = true;
            }
            // `@hasDecl` only accepts container types (struct/union/enum/opaque),
            // so first check the type kind at comptime.
            const ti = @typeInfo(T);
            const has_decls = ti == .@"struct" or ti == .@"union" or
                ti == .@"enum" or ti == .@"opaque";
            if (has_decls and @hasDecl(T, "deinit")) {
                self.value.deinit();
            }
        }
    };
}

pub fn Borrow(comptime T: type) type {
    return struct {
        const Self = @This();

        ptr: *const T,

        pub fn from(ptr: *const T) Self {
            return .{ .ptr = ptr };
        }

        pub fn get(self: Self) *const T {
            return self.ptr;
        }
    };
}

pub const ArenaScope = struct {
    arena: std.heap.ArenaAllocator,

    pub fn init(parent: std.mem.Allocator) ArenaScope {
        return .{ .arena = std.heap.ArenaAllocator.init(parent) };
    }

    pub fn allocator(self: *ArenaScope) std.mem.Allocator {
        return self.arena.allocator();
    }

    pub fn deinit(self: *ArenaScope) void {
        self.arena.deinit();
    }
};

pub const DeinitGuard = struct {
    armed: bool = false,
    site: []const u8 = "",

    pub fn arm(self: *DeinitGuard) void {
        self.armed = true;
    }

    pub fn disarm(self: *DeinitGuard) void {
        self.armed = false;
    }

    pub fn check(self: *const DeinitGuard) void {
        if (!std.debug.runtime_safety) return;
        if (self.armed) @panic("DeinitGuard: dropped without deinit");
    }
};

test "Owned wraps a type with a deinit method" {
    const Resource = struct {
        const Self = @This();
        allocator: std.mem.Allocator,
        buf: []u8,

        pub fn init(a: std.mem.Allocator) !Self {
            return .{ .allocator = a, .buf = try a.alloc(u8, 16) };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.buf);
        }
    };

    var owned = Owned(Resource).init(try Resource.init(std.testing.allocator));
    defer owned.deinit();
    try std.testing.expectEqual(@as(usize, 16), owned.ref().buf.len);
}

test "Owned wraps a type without a deinit method" {
    var owned = Owned(u32).init(42);
    defer owned.deinit();
    try std.testing.expectEqual(@as(u32, 42), owned.ref().*);
    try std.testing.expectEqual(@as(u32, 42), owned.refConst().*);
}

test "Owned.take returns the inner value" {
    var owned = Owned(u32).init(7);
    const v = owned.take();
    try std.testing.expectEqual(@as(u32, 7), v);
    // After take, ref()/refConst() would panic in safety builds; only
    // exercise the happy path here.
    // TODO: panic-path test once a panic-catch helper exists
}

test "Owned.deinit on already-moved value is observable in non-safety builds" {
    if (std.debug.runtime_safety) return;
    var owned = Owned(u32).init(1);
    _ = owned.take();
    owned.deinit();
}

test "Borrow round-trips a value" {
    const x: u64 = 0xdeadbeef;
    const b = Borrow(u64).from(&x);
    try std.testing.expectEqual(@as(u64, 0xdeadbeef), b.get().*);
}

test "ArenaScope alloc and deinit releases memory" {
    var scope = ArenaScope.init(std.testing.allocator);
    defer scope.deinit();

    const a = scope.allocator();
    const slice = try a.alloc(u8, 128);
    @memset(slice, 0xaa);
    try std.testing.expectEqual(@as(u8, 0xaa), slice[0]);
    try std.testing.expectEqual(@as(u8, 0xaa), slice[127]);

    const more = try a.alloc(u32, 8);
    more[0] = 1;
    try std.testing.expectEqual(@as(u32, 1), more[0]);
}

test "DeinitGuard arm + disarm + check is a no-op" {
    var g: DeinitGuard = .{};
    g.arm();
    try std.testing.expect(g.armed);
    g.disarm();
    try std.testing.expect(!g.armed);
    g.check();
    // TODO: panic-path test once a panic-catch helper exists
}
