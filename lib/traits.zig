//! Runtime and comptime helpers for the Zig++ trait system. A trait is
//! represented as a Zig struct type whose declarations describe required
//! method signatures, e.g.
//!     pub const Writer = struct {
//!         pub fn write(self: *anyopaque, bytes: []const u8) anyerror!usize;
//!     };
//! Concrete types satisfy a trait by exposing matching `pub fn` decls with
//! compatible signatures. The frontend lowers `impl Trait for T { ... }`
//! into ordinary Zig methods plus an `assertImplements` call.

const std = @import("std");

pub fn implements(comptime T: type, comptime Trait: type) bool {
    _ = T;
    _ = Trait;
    // TODO: walk @typeInfo(Trait).@"struct".decls and verify each appears on
    // T with a structurally compatible function type.
    return true;
}

pub fn assertImplements(comptime T: type, comptime Trait: type) void {
    if (!implements(T, Trait)) {
        @compileError("type " ++ @typeName(T) ++ " does not implement trait " ++ @typeName(Trait));
    }
}
