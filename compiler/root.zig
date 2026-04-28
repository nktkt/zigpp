//! Public entry point for the `zpp_lib` static library.
//!
//! Re-exports the compiler-internal modules so external consumers (the `zpp`
//! CLI driver, integration tests, and downstream tooling) have a single,
//! stable import surface:
//!
//!     const zpp = @import("zpp_lib");
//!     const ast = zpp.ast;
//!     const Parser = zpp.parser.Parser;

pub const ast = @import("ast.zig");
pub const checks = @import("checks.zig");
pub const derive_lower = @import("derive_lower.zig");
pub const diagnostics = @import("diagnostics.zig");
pub const doc_extract = @import("doc_extract.zig");
pub const lexer = @import("lexer.zig");
pub const lower_to_zig = @import("lower_to_zig.zig");
pub const parser = @import("parser.zig");
pub const project = @import("project.zig");
pub const sema = @import("sema.zig");
pub const trait_lower = @import("trait_lower.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
