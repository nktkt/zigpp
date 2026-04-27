//! Diagnostic and error reporting for the Zig++ compiler frontend.
//!
//! All compiler stages (parser, sema, lowering) report problems through a
//! shared `DiagnosticSink`. Diagnostics are addressable by stable error codes
//! (`E0001`, `E0002`, ...) so that documentation, tests, and tooling can
//! reference them unambiguously. The codes used internally are exposed via
//! the `Code` namespace below.

const std = @import("std");

/// Severity level of a diagnostic. `.fatal` aborts compilation immediately;
/// `.@"error"` accumulates but still prevents code generation.
pub const Severity = enum {
    note,
    warning,
    @"error",
    fatal,
};

/// A half-open `[start, end)` byte range inside a source file, plus a
/// human-friendly line/column for the start position.
pub const SourceSpan = struct {
    file: []const u8,
    start: usize,
    end: usize,
    line: u32,
    col: u32,
};

/// One emitted message. `code` is a stable identifier (see `Code`); `message`
/// is the human-readable explanation.
pub const Diagnostic = struct {
    severity: Severity,
    span: SourceSpan,
    code: []const u8,
    message: []const u8,
};

/// Collects diagnostics from every compiler stage. Owned by the driver; passed
/// by pointer into each stage.
pub const DiagnosticSink = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(Diagnostic),
    error_count: usize = 0,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .items = .{},
        };
    }

    pub fn deinit(self: *Self) void {
        self.items.deinit(self.allocator);
    }

    pub fn emit(self: *Self, diag: Diagnostic) !void {
        _ = self;
        _ = diag;
        @panic("TODO: DiagnosticSink.emit not yet implemented");
    }

    pub fn hasErrors(self: *const Self) bool {
        return self.error_count > 0;
    }
};

/// Stable error codes referenced by the design document and by sema passes.
/// Strings are UPPERCASE `E` followed by a 4-digit identifier; ranges are
/// loosely partitioned (E00xx ownership, E001x effects, E002x traits).
pub const Code = struct {
    pub const owned_not_deinit: []const u8 = "E0001";
    pub const owned_used_after_move: []const u8 = "E0002";
    pub const owned_double_deinit: []const u8 = "E0003";
    pub const allocator_mismatch: []const u8 = "E0004";
    pub const hidden_alloc_in_noalloc: []const u8 = "E0010";
    pub const trait_not_implemented: []const u8 = "E0020";
};
