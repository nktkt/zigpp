//! Zig++ source parser. Consumes UTF-8 `.zpp` source and emits an AST rooted
//! at a `module` node.
//!
//! Beyond the Zig keyword set, the parser additionally recognizes the
//! Zig++-specific keywords:
//!
//!   trait     impl     dyn      using
//!   own       move     effects  requires
//!   ensures   invariant         derive    where
//!
//! All other tokens fall through to the underlying Zig grammar.

const std = @import("std");
const ast = @import("ast.zig");
const diagnostics = @import("diagnostics.zig");

pub const Parser = struct {
    allocator: std.mem.Allocator,
    source: []const u8,
    pos: usize,
    sink: *diagnostics.DiagnosticSink,

    const Self = @This();

    pub fn init(
        allocator: std.mem.Allocator,
        source: []const u8,
        sink: *diagnostics.DiagnosticSink,
    ) Parser {
        return .{
            .allocator = allocator,
            .source = source,
            .pos = 0,
            .sink = sink,
        };
    }

    pub fn parseModule(self: *Parser) !*ast.Node {
        _ = self;
        @panic("TODO: parser not yet implemented");
    }

    fn parseFnDecl(self: *Parser) !*ast.Node {
        _ = self;
        @panic("TODO: parseFnDecl");
    }

    fn parseTraitDecl(self: *Parser) !*ast.Node {
        _ = self;
        @panic("TODO: parseTraitDecl");
    }

    fn parseImplBlock(self: *Parser) !*ast.Node {
        _ = self;
        @panic("TODO: parseImplBlock");
    }

    fn parseUsingStmt(self: *Parser) !*ast.Node {
        _ = self;
        @panic("TODO: parseUsingStmt");
    }

    fn parseOwnDecl(self: *Parser) !*ast.Node {
        _ = self;
        @panic("TODO: parseOwnDecl");
    }

    fn parseEffectsAttr(self: *Parser) !*ast.Node {
        _ = self;
        @panic("TODO: parseEffectsAttr");
    }

    fn parseDerive(self: *Parser) !*ast.Node {
        _ = self;
        @panic("TODO: parseDerive");
    }
};
