//! Semantic analysis for Zig++.
//!
//! Runs after parsing and before lowering. Produces zero new AST nodes; only
//! diagnostics and side tables consumed by the lowering stage.
//!
//! The four ownership errors enforced by `checkOwnership`:
//!
//!   E0001  owned value was not deinitialized
//!   E0002  owned value used after move
//!   E0003  owned value deinitialized twice
//!   E0004  allocator mismatch
//!
//! Effect checking enforces E0010 (hidden allocation in a `noalloc` function).
//! Trait checking enforces E0020 (trait not implemented for type).

const std = @import("std");
const ast = @import("ast.zig");
const diagnostics = @import("diagnostics.zig");

pub const Analyzer = struct {
    allocator: std.mem.Allocator,
    sink: *diagnostics.DiagnosticSink,

    const Self = @This();

    pub fn init(
        allocator: std.mem.Allocator,
        sink: *diagnostics.DiagnosticSink,
    ) Analyzer {
        return .{ .allocator = allocator, .sink = sink };
    }

    pub fn analyze(self: *Analyzer, root: *ast.Node) !void {
        _ = self;
        _ = root;
        @panic("TODO: Analyzer.analyze not yet implemented");
    }

    fn checkTraitImpls(self: *Analyzer, root: *ast.Node) !void {
        _ = self;
        _ = root;
        @panic("TODO: checkTraitImpls (E0020 trait_not_implemented)");
    }

    fn checkOwnership(self: *Analyzer, root: *ast.Node) !void {
        _ = self;
        _ = root;
        @panic("TODO: checkOwnership (E0001/E0002/E0003/E0004)");
    }

    fn checkEffects(self: *Analyzer, root: *ast.Node) !void {
        _ = self;
        _ = root;
        @panic("TODO: checkEffects (E0010 hidden_alloc_in_noalloc)");
    }

    fn checkContracts(self: *Analyzer, root: *ast.Node) !void {
        _ = self;
        _ = root;
        @panic("TODO: checkContracts (requires/ensures/invariant)");
    }
};
