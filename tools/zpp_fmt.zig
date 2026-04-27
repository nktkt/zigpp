//! Formatter for `.zpp` source files. This tool only handles the Zig++
//! surface syntax; plain `.zig` files inside a Zig++ project should be
//! deferred to upstream `zig fmt`.

const std = @import("std");

const zpp_lib = @import("zpp_lib");
const parser = zpp_lib.parser;
const ast = zpp_lib.ast;

pub fn run(
    allocator: std.mem.Allocator,
    paths: []const []const u8,
    check_only: bool,
) !u8 {
    _ = allocator;
    _ = paths;
    _ = check_only;
    @panic("TODO: zpp_fmt.run not yet implemented");
}

fn formatFile(
    allocator: std.mem.Allocator,
    path: []const u8,
    check_only: bool,
) !bool {
    _ = allocator;
    _ = path;
    _ = check_only;
    @panic("TODO: zpp_fmt.formatFile not yet implemented");
}

fn formatSource(
    allocator: std.mem.Allocator,
    source: []const u8,
) ![]u8 {
    _ = allocator;
    _ = source;
    @panic("TODO: zpp_fmt.formatSource not yet implemented");
}
