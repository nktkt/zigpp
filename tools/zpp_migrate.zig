//! Migration helper that rewrites idiomatic Zig source into Zig++. Walks the
//! AST and proposes / applies syntactic upgrades for ownership, traits, and
//! dynamic dispatch patterns.

const std = @import("std");

const zpp_lib = @import("zpp_lib");
const parser = zpp_lib.parser;
const ast = zpp_lib.ast;

pub fn run(
    allocator: std.mem.Allocator,
    paths: []const []const u8,
    dry_run: bool,
) !u8 {
    _ = allocator;
    _ = paths;
    _ = dry_run;
    @panic("TODO: zpp_migrate.run not yet implemented");
}

// Candidate rewrite: `var x = init(); defer x.deinit();` -> `using x = init();`
fn rewriteDeferDeinit(
    allocator: std.mem.Allocator,
    source: []const u8,
) ![]u8 {
    _ = allocator;
    _ = source;
    @panic("TODO: zpp_migrate.rewriteDeferDeinit not yet implemented");
}

// Candidate rewrite: `anytype` parameters constrained by `@hasDecl` checks
// become `impl Trait` parameters once the corresponding trait exists.
fn rewriteAnytypeToImplTrait(
    allocator: std.mem.Allocator,
    source: []const u8,
) ![]u8 {
    _ = allocator;
    _ = source;
    @panic("TODO: zpp_migrate.rewriteAnytypeToImplTrait not yet implemented");
}

// Candidate rewrite: structs with hand-rolled vtables become `dyn Trait`
// values, deferring the dispatch wiring to the compiler.
fn rewriteManualVTableToDyn(
    allocator: std.mem.Allocator,
    source: []const u8,
) ![]u8 {
    _ = allocator;
    _ = source;
    @panic("TODO: zpp_migrate.rewriteManualVTableToDyn not yet implemented");
}
