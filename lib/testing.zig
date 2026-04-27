//! Test harness extensions for Zig++. Adds property-based testing,
//! corpus-driven fuzzing, and golden/snapshot comparison on top of Zig's
//! built-in `std.testing`. Each helper takes a comptime `name` so failures
//! can be reported with a stable identifier independent of source layout.

const std = @import("std");

pub fn property(
    comptime name: []const u8,
    comptime f: anytype,
    iterations: usize,
) !void {
    _ = name;
    _ = f;
    _ = iterations;
    @panic("TODO: property testing not yet implemented");
}

pub fn fuzz(
    comptime name: []const u8,
    comptime f: anytype,
    corpus: []const []const u8,
) !void {
    _ = name;
    _ = f;
    _ = corpus;
    @panic("TODO: fuzz harness not yet implemented");
}

pub fn snapshot(actual: []const u8, snapshot_path: []const u8) !void {
    _ = actual;
    _ = snapshot_path;
    @panic("TODO: snapshot comparison not yet implemented");
}
