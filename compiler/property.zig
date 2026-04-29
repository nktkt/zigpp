//! Property-based tests for the lowering pipeline.
//!
//! Every property is reproducible: each iteration uses a deterministic seed,
//! so failures are bisectable. The generators produce small `.zpp`-shaped
//! snippets that exercise the line-level rules (using/own/move/owned/effects)
//! plus the structural passes (trait, extern interface, derive postfix).
//!
//! Properties asserted:
//!   1. Idempotence — `lowerSource(lowerSource(s)) == lowerSource(s)`. The
//!      first pass strips every Zig++ construct, so the second pass is a
//!      passthrough.
//!   2. No-crash — `lowerSource` returns without panicking on any generated
//!      input. Real allocator failures are propagated; logic panics fail
//!      the test.
//!   3. Composes-with-fmt — `formatSource` and `lowerSource` can be chained
//!      either way without crashing. They are independent normalizers and
//!      are NOT required to commute byte-exact.

const std = @import("std");
const lower_to_zig = @import("lower_to_zig.zig");
const fmt = @import("fmt.zig");

/// Generate a small but interesting `.zpp`-shaped source. Caller frees.
pub fn generateRandomSource(
    allocator: std.mem.Allocator,
    rng: *std.Random.DefaultPrng,
) ![]u8 {
    const r = rng.random();
    var buf: std.ArrayListUnmanaged(u8) = .{};
    errdefer buf.deinit(allocator);

    // Always start with an import so the body looks plausible.
    try buf.appendSlice(allocator, "const std = @import(\"std\");\n\n");

    const top_count: u8 = 1 + r.uintLessThan(u8, 5);
    var i: u8 = 0;
    while (i < top_count) : (i += 1) {
        switch (r.uintLessThan(u8, 4)) {
            0 => try writeTrait(allocator, &buf, r, false),
            1 => try writeTrait(allocator, &buf, r, true),
            2 => try writeFn(allocator, &buf, r),
            3 => try writeStructWithDerive(allocator, &buf, r),
            else => unreachable,
        }
        try buf.append(allocator, '\n');
    }

    return buf.toOwnedSlice(allocator);
}

fn writeTrait(
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    r: std.Random,
    is_extern: bool,
) !void {
    if (is_extern) {
        try buf.appendSlice(allocator, "extern interface ");
    } else {
        try buf.appendSlice(allocator, "trait ");
    }
    try writeUpperIdent(allocator, buf, r);
    try buf.appendSlice(allocator, " {\n");

    const m: u8 = 1 + r.uintLessThan(u8, 3);
    var i: u8 = 0;
    while (i < m) : (i += 1) {
        try buf.appendSlice(allocator, "    fn ");
        try writeIdent(allocator, buf, r);
        try buf.appendSlice(allocator, "(self");
        if (r.boolean()) {
            try buf.appendSlice(allocator, ", ");
            try writeIdent(allocator, buf, r);
            try buf.appendSlice(allocator, ": ");
            try writeType(allocator, buf, r);
        }
        try buf.appendSlice(allocator, ") ");
        try writeRet(allocator, buf, r);
        try buf.appendSlice(allocator, ";\n");
    }
    try buf.appendSlice(allocator, "}\n");
}

fn writeFn(
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    r: std.Random,
) !void {
    if (r.boolean()) {
        try buf.appendSlice(allocator, "effects(.noalloc, .noio)\n");
    }
    try buf.appendSlice(allocator, "pub fn ");
    try writeIdent(allocator, buf, r);
    try buf.appendSlice(allocator, "() void {\n");
    const stmts: u8 = r.uintLessThan(u8, 4);
    var i: u8 = 0;
    while (i < stmts) : (i += 1) {
        try writeStmt(allocator, buf, r);
    }
    try buf.appendSlice(allocator, "}\n");
}

fn writeStmt(
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    r: std.Random,
) !void {
    switch (r.uintLessThan(u8, 5)) {
        0 => {
            try buf.appendSlice(allocator, "    using ");
            try writeIdent(allocator, buf, r);
            try buf.appendSlice(allocator, " = init();\n");
        },
        1 => {
            try buf.appendSlice(allocator, "    own var ");
            try writeIdent(allocator, buf, r);
            try buf.appendSlice(allocator, " = init();\n");
        },
        2 => {
            try buf.appendSlice(allocator, "    var moved = move ");
            try writeIdent(allocator, buf, r);
            try buf.appendSlice(allocator, ";\n");
        },
        3 => {
            try buf.appendSlice(allocator, "    var x = 1;\n");
        },
        4 => {
            try buf.appendSlice(allocator, "    _ = x;\n");
        },
        else => unreachable,
    }
}

fn writeStructWithDerive(
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    r: std.Random,
) !void {
    try buf.appendSlice(allocator, "const ");
    try writeUpperIdent(allocator, buf, r);
    try buf.appendSlice(allocator, " = struct {\n    id: u64,\n    name: []const u8,\n} derive(.{ ");
    const traits = [_][]const u8{ "Hash", "Json", "Debug" };
    const k: u8 = 1 + r.uintLessThan(u8, 3);
    var i: u8 = 0;
    while (i < k) : (i += 1) {
        if (i != 0) try buf.appendSlice(allocator, ", ");
        try buf.appendSlice(allocator, traits[r.uintLessThan(u8, traits.len)]);
    }
    if (r.boolean()) try buf.append(allocator, ',');
    try buf.appendSlice(allocator, " });\n");
}

fn writeIdent(
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    r: std.Random,
) !void {
    const len: u8 = 1 + r.uintLessThan(u8, 6);
    var i: u8 = 0;
    while (i < len) : (i += 1) {
        try buf.append(allocator, 'a' + r.uintLessThan(u8, 26));
    }
}

fn writeUpperIdent(
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    r: std.Random,
) !void {
    try buf.append(allocator, 'A' + r.uintLessThan(u8, 26));
    try writeIdent(allocator, buf, r);
}

fn writeType(
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    r: std.Random,
) !void {
    const types = [_][]const u8{ "u8", "u32", "u64", "[]const u8", "i32" };
    try buf.appendSlice(allocator, types[r.uintLessThan(u8, types.len)]);
}

fn writeRet(
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    r: std.Random,
) !void {
    switch (r.uintLessThan(u8, 4)) {
        0 => try buf.appendSlice(allocator, "void"),
        1 => try buf.appendSlice(allocator, "!void"),
        2 => try buf.appendSlice(allocator, "!usize"),
        3 => try buf.appendSlice(allocator, "[]const u8"),
        else => unreachable,
    }
}

/// Property 1: lowerSource is idempotent.
pub fn propertyIdempotent(
    allocator: std.mem.Allocator,
    iterations: usize,
    seed: u64,
) !void {
    var rng = std.Random.DefaultPrng.init(seed);
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        const src = try generateRandomSource(allocator, &rng);
        defer allocator.free(src);

        const once = try lower_to_zig.lowerSource(allocator, src);
        defer allocator.free(once);

        const twice = try lower_to_zig.lowerSource(allocator, once);
        defer allocator.free(twice);

        std.testing.expectEqualStrings(once, twice) catch |err| {
            std.debug.print(
                "\npropertyIdempotent failed at iter {d} (seed=0x{x})\n--- input ---\n{s}\n--- once ---\n{s}\n--- twice ---\n{s}\n",
                .{ i, seed, src, once, twice },
            );
            return err;
        };
    }
}

/// Property 2: lowerSource never crashes on any generated input.
pub fn propertyNoCrash(
    allocator: std.mem.Allocator,
    iterations: usize,
    seed: u64,
) !void {
    var rng = std.Random.DefaultPrng.init(seed);
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        const src = try generateRandomSource(allocator, &rng);
        defer allocator.free(src);

        const out = try lower_to_zig.lowerSource(allocator, src);
        allocator.free(out);
    }
}

/// Property 3: lowerSource and formatSource compose without crashing in
/// either order. They are independent normalizers and are NOT required to
/// commute byte-exact — we just assert both chains return cleanly.
pub fn propertyComposesWithFmt(
    allocator: std.mem.Allocator,
    iterations: usize,
    seed: u64,
) !void {
    var rng = std.Random.DefaultPrng.init(seed);
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        const src = try generateRandomSource(allocator, &rng);
        defer allocator.free(src);

        // lower -> fmt -> lower
        const a1 = try lower_to_zig.lowerSource(allocator, src);
        defer allocator.free(a1);
        const a2 = try fmt.formatSource(allocator, a1);
        defer allocator.free(a2);
        const a3 = try lower_to_zig.lowerSource(allocator, a2);
        allocator.free(a3);

        // fmt -> lower -> fmt
        const b1 = try fmt.formatSource(allocator, src);
        defer allocator.free(b1);
        const b2 = try lower_to_zig.lowerSource(allocator, b1);
        defer allocator.free(b2);
        const b3 = try fmt.formatSource(allocator, b2);
        allocator.free(b3);
    }
}

test "property: lowerSource is idempotent (100 iters, seed 0xdeadbeef)" {
    try propertyIdempotent(std.testing.allocator, 100, 0xdeadbeef);
}

test "property: lowerSource never crashes (100 iters, seed 0x12345678)" {
    try propertyNoCrash(std.testing.allocator, 100, 0x12345678);
}

test "property: lowerSource composes with fmt (50 iters, seed 0xcafebabe)" {
    try propertyComposesWithFmt(std.testing.allocator, 50, 0xcafebabe);
}
