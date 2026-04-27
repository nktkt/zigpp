//! Documentation generator for Zig++ projects. Emits HTML/Markdown describing
//! the public API, with first-class sections for declared traits and effects
//! as promised by the language design.

const std = @import("std");

const zpp_lib = @import("zpp_lib");
const parser = zpp_lib.parser;
const sema = zpp_lib.sema;
const ast = zpp_lib.ast;

pub fn run(
    allocator: std.mem.Allocator,
    root: []const u8,
    out_dir: []const u8,
) !void {
    _ = allocator;
    _ = root;
    _ = out_dir;
    @panic("TODO: zpp_doc.run not yet implemented");
}

fn generateTraitDocs(
    allocator: std.mem.Allocator,
    out_dir: []const u8,
) !void {
    _ = allocator;
    _ = out_dir;
    @panic("TODO: zpp_doc.generateTraitDocs not yet implemented");
}

fn generateEffectDocs(
    allocator: std.mem.Allocator,
    out_dir: []const u8,
) !void {
    _ = allocator;
    _ = out_dir;
    @panic("TODO: zpp_doc.generateEffectDocs not yet implemented");
}

fn generateApiManifest(
    allocator: std.mem.Allocator,
    out_dir: []const u8,
) !void {
    _ = allocator;
    _ = out_dir;
    @panic("TODO: zpp_doc.generateApiManifest not yet implemented");
}
