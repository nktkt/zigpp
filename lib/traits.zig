//! Comptime trait-conformance checker for hand-written code that wants to
//! verify a struct satisfies a Zig++ trait. After `compiler/trait_lower.zig`,
//! a trait becomes a struct exposing a nested `VTable` whose field NAMES are
//! the required method names. This module walks those field names and
//! confirms the candidate type declares each one.

const std = @import("std");

/// Returns true if `T` declares every method named in `Trait.VTable`'s fields.
/// Only name presence is checked here — a real signature-equivalence check
/// would have to peel `*anyopaque` from each VTable field's first parameter
/// and substitute `*T`, which is out of scope for this stub.
pub fn implements(comptime T: type, comptime Trait: type) bool {
    if (!@hasDecl(Trait, "VTable")) return false;
    const VT = @field(Trait, "VTable");
    const fields = @typeInfo(VT).@"struct".fields;
    inline for (fields) |f| {
        if (!@hasDecl(T, f.name)) return false;
    }
    return true;
}

/// Like `implements`, but emits a `@compileError` when T is missing any
/// trait method. The error message names the missing method(s).
pub fn assertImplements(comptime T: type, comptime Trait: type) void {
    if (!@hasDecl(Trait, "VTable")) {
        @compileError("Trait " ++ @typeName(Trait) ++
            " has no `VTable` decl - pass a Zig++ trait struct");
    }
    const VT = @field(Trait, "VTable");
    const fields = @typeInfo(VT).@"struct".fields;
    comptime var missing: []const u8 = "";
    comptime var any_missing = false;
    inline for (fields) |f| {
        if (!@hasDecl(T, f.name)) {
            if (any_missing) {
                missing = missing ++ ", ";
            }
            missing = missing ++ f.name;
            any_missing = true;
        }
    }
    if (any_missing) {
        @compileError("type " ++ @typeName(T) ++
            " does not implement trait " ++ @typeName(Trait) ++
            " - missing method(s): " ++ missing);
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const TestTrait = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    pub const VTable = struct {
        m1: *const fn (self: *anyopaque) void,
        m2: *const fn (self: *anyopaque) void,
    };
};

const GoodImpl = struct {
    pub fn m1(_: *GoodImpl) void {}
    pub fn m2(_: *GoodImpl) void {}
};

const PartialImpl = struct {
    pub fn m1(_: *PartialImpl) void {}
};

const NotATrait = struct { x: u32 };

test "implements returns true when all VTable methods are present" {
    try testing.expect(implements(GoodImpl, TestTrait));
}

test "implements returns false when a VTable method is missing" {
    try testing.expect(!implements(PartialImpl, TestTrait));
}

test "implements returns false when Trait has no VTable decl" {
    try testing.expect(!implements(GoodImpl, NotATrait));
}

test "assertImplements compiles cleanly for a conforming type" {
    // If this call would fire a `@compileError`, the test would fail to
    // compile. There's no in-language way to assert that `@compileError`
    // *does* fire, so the negative case is intentionally not covered here.
    assertImplements(GoodImpl, TestTrait);
}
