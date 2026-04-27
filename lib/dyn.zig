//! Dynamic dispatch helpers for Zig++'s `dyn Trait` types. A `Dyn(Trait)`
//! is a fat pointer pairing an erased instance pointer with a vtable
//! generated from the trait's declarations. Construction goes through
//! `makeDyn`, which the frontend emits when an `impl Trait` is coerced to
//! a `dyn Trait`.

const std = @import("std");

pub fn VTable(comptime Trait: type) type {
    _ = Trait;
    // TODO: synthesize a struct with one `*const fn` field per trait method,
    // each rewritten to take `*anyopaque` as its first parameter.
    @compileError("dyn dispatch not yet wired up: VTable");
}

pub fn Dyn(comptime Trait: type) type {
    return struct {
        ptr: *anyopaque,
        vtable: *const VTable(Trait),
    };
}

pub fn makeDyn(comptime Trait: type, instance: anytype) Dyn(Trait) {
    _ = instance;
    @compileError("dyn dispatch not yet wired up: makeDyn");
}
