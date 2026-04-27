//! Language Server for Zig++. Drives an LSP loop over stdin/stdout, surfacing
//! diagnostics from the compiler frontend (ownership errors E0001..E0004 and
//! the effect/trait errors emitted by `compiler/diagnostics.zig`).

const std = @import("std");

const zpp_lib = @import("zpp_lib");
const parser = zpp_lib.parser;
const sema = zpp_lib.sema;
const diagnostics = zpp_lib.diagnostics;
const ast = zpp_lib.ast;

pub fn run(allocator: std.mem.Allocator) !void {
    _ = allocator;
    @panic("TODO: zpp_lsp.run not yet implemented");
}

fn handleInitialize(allocator: std.mem.Allocator) !void {
    _ = allocator;
    @panic("TODO: zpp_lsp.handleInitialize not yet implemented");
}

fn handleHover(allocator: std.mem.Allocator) !void {
    _ = allocator;
    @panic("TODO: zpp_lsp.handleHover not yet implemented");
}

fn handleDefinition(allocator: std.mem.Allocator) !void {
    _ = allocator;
    @panic("TODO: zpp_lsp.handleDefinition not yet implemented");
}

fn handleCompletion(allocator: std.mem.Allocator) !void {
    _ = allocator;
    @panic("TODO: zpp_lsp.handleCompletion not yet implemented");
}

// Surfaces ownership errors E0001..E0004 and the effect/trait errors
// produced by compiler/diagnostics.zig as LSP `textDocument/publishDiagnostics`.
fn handleDiagnostics(allocator: std.mem.Allocator) !void {
    _ = allocator;
    @panic("TODO: zpp_lsp.handleDiagnostics not yet implemented");
}

fn handleCodeAction(allocator: std.mem.Allocator) !void {
    _ = allocator;
    @panic("TODO: zpp_lsp.handleCodeAction not yet implemented");
}
