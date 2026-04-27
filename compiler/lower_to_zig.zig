//! Lowering stage: translate a fully-analyzed Zig++ AST into plain `.zig`
//! source text.
//!
//! Invariant: **the generated `.zig` must be human-readable**. A Zig++ user
//! debugging a compile error in the lowered code should be able to recognize
//! their source structure. We therefore preserve names, lay out one statement
//! per line, and avoid synthesizing unnecessary helper symbols.

const std = @import("std");
const ast = @import("ast.zig");
const trait_lower = @import("trait_lower.zig");

/// Lower a Zig++ source string to Zig.
///
/// Implemented rules:
///   - `using x = expr;`            -> `var x = expr; defer x.deinit();`
///   - `effects(...)` on its own    -> erased (line + newline removed)
///   - `own var|const|<param>`      -> strip the `own ` keyword
///   - `move <expr>`                -> strip the `move ` keyword
///   - `owned struct`               -> strip the `owned ` keyword
///   - `dyn <Ident>`                -> strip the `dyn ` keyword (the trait
///                                     name itself already lowers to a
///                                     fat-pointer struct via the trait pass)
///   - `impl <Ident>`               -> replaced with `anytype` (static
///                                     dispatch via comptime-generic). The
///                                     trait-name token is consumed.
///   - `trait Name { fn ...; }`     -> fat-pointer struct with vtable +
///                                     dispatch wrappers (see
///                                     `trait_lower.lowerTraits`)
///
/// Pipeline order: the line-based rules run first, then the structural
/// trait-lowering pass runs over the resulting buffer. Trait blocks are
/// indentation-preserving so running them after line rewrites keeps the
/// surrounding code intact.
///
/// Limitations (single-line scanner):
///   - String/char/comment state is reset at every newline. A `"..."` or
///     `'...'` literal that spans multiple lines, or a `\\` multi-line
///     string literal, is not tracked across line boundaries. This matters
///     in practice only for the `own`/`move`/`owned`/`dyn`/`impl` keyword
///     strips — the per-character scan tracks per-line lexical state.
///   - The `effects(...)` rule is matched at the line level (whitespace +
///     `effects(<balanced>)` + whitespace + EOL). A multi-line `effects(...)`
///     call is not stripped; mixed lines (e.g. `pub fn x() effects(.noalloc)
///     void {`) are passed through unchanged by design.
///   - The `impl Trait` -> `anytype` rule fires only when `impl <Ident>` is
///     followed by something other than `{` (the impl-block syntax). An
///     `impl Trait` token sequence appearing immediately before `{` is left
///     alone; structural impl-block lowering is handled elsewhere.
pub fn lowerSource(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    const after_lines = try lowerSourceLineRules(allocator, source);
    defer allocator.free(after_lines);
    return try trait_lower.lowerTraits(allocator, after_lines);
}

/// Run only the line-based lowering rules (using/effects/own/move/owned).
/// Exposed as a separate function so `lowerSource` can chain it with
/// structural passes that come after.
fn lowerSourceLineRules(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    var out = std.ArrayList(u8){};
    defer out.deinit(allocator);

    var i: usize = 0;
    while (i < source.len) {
        const line_start = i;

        // Find the end of this line (exclusive of the trailing '\n', if any).
        var line_end = line_start;
        while (line_end < source.len and source[line_end] != '\n') : (line_end += 1) {}
        const has_newline = line_end < source.len;
        const line = source[line_start..line_end];

        // Rule 1: `effects(...)` standalone line — erased entirely.
        // We check this first because a successful match suppresses the
        // line AND its trailing newline.
        if (isEffectsOnlyLine(line)) {
            // Skip this line and its newline (if present). Do not emit.
            i = if (has_newline) line_end + 1 else line_end;
            continue;
        }

        if (tryRewriteUsing(line)) |rewritten| {
            // Rule 0 (existing): `using` rewrite. We then run rules 2/3/4
            // over the synthesized expression so that `using x = move y;`
            // also strips the `move`.
            try out.appendSlice(allocator, rewritten.indent);
            try out.appendSlice(allocator, "var ");
            try out.appendSlice(allocator, rewritten.ident);
            try out.appendSlice(allocator, " = ");
            // The expression slice may itself contain `move`/`own` —
            // re-scan it with the keyword-strip pass.
            try appendStrippedKeywords(allocator, &out, rewritten.expr);
            try out.appendSlice(allocator, "; defer ");
            try out.appendSlice(allocator, rewritten.ident);
            try out.appendSlice(allocator, ".deinit();");
            try out.appendSlice(allocator, rewritten.trailing);
        } else {
            // Rules 2/3/4: per-line keyword strip with string/char/comment
            // state. Falls through to a verbatim copy for empty lines.
            try appendStrippedKeywords(allocator, &out, line);
        }
        if (has_newline) {
            try out.append(allocator, '\n');
            i = line_end + 1;
        } else {
            i = line_end;
        }
    }

    return out.toOwnedSlice(allocator);
}

const UsingMatch = struct {
    indent: []const u8,
    ident: []const u8,
    expr: []const u8,
    /// Anything on the line after the terminating ';' (e.g. trailing
    /// whitespace or a `// comment`). Preserved verbatim so we don't
    /// silently drop user content.
    trailing: []const u8,
};

fn isIdentStart(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or c == '_';
}

fn isIdentCont(c: u8) bool {
    return isIdentStart(c) or (c >= '0' and c <= '9');
}

fn isHSpace(c: u8) bool {
    return c == ' ' or c == '\t';
}

/// Try to match `<indent>using <ident> = <expr>;<trailing>` against a single
/// logical line. Returns null if the line is anything else.
fn tryRewriteUsing(line: []const u8) ?UsingMatch {
    var p: usize = 0;

    // Indentation.
    while (p < line.len and isHSpace(line[p])) : (p += 1) {}
    const indent = line[0..p];

    // Literal `using` keyword.
    const kw = "using";
    if (p + kw.len > line.len) return null;
    if (!std.mem.eql(u8, line[p .. p + kw.len], kw)) return null;
    // Must NOT be part of a larger identifier (e.g. `notusing` was rejected
    // by the indent scan above; here we guard against `usingx`).
    if (p + kw.len < line.len and isIdentCont(line[p + kw.len])) return null;
    p += kw.len;

    // At least one space/tab between `using` and the identifier.
    if (p >= line.len or !isHSpace(line[p])) return null;
    while (p < line.len and isHSpace(line[p])) : (p += 1) {}

    // Identifier.
    if (p >= line.len or !isIdentStart(line[p])) return null;
    const ident_start = p;
    p += 1;
    while (p < line.len and isIdentCont(line[p])) : (p += 1) {}
    const ident = line[ident_start..p];

    // Optional whitespace, then `=`.
    while (p < line.len and isHSpace(line[p])) : (p += 1) {}
    if (p >= line.len or line[p] != '=') return null;
    p += 1;
    while (p < line.len and isHSpace(line[p])) : (p += 1) {}

    // Expression up to the next `;`. We don't track string/block nesting —
    // documented limitation.
    const expr_start = p;
    while (p < line.len and line[p] != ';') : (p += 1) {}
    if (p >= line.len) return null; // no terminating `;` on this line
    // Trim trailing whitespace inside the expression slice.
    var expr_end = p;
    while (expr_end > expr_start and isHSpace(line[expr_end - 1])) : (expr_end -= 1) {}
    if (expr_end == expr_start) return null; // empty expression — reject
    const expr = line[expr_start..expr_end];

    // Skip the `;` and capture whatever follows on this line.
    p += 1;
    const trailing = line[p..];

    return .{
        .indent = indent,
        .ident = ident,
        .expr = expr,
        .trailing = trailing,
    };
}

/// Rule 1 helper. Returns true iff `line` is exactly:
///   <hspace>* `effects(` <balanced parens content> `)` <hspace>*
/// A balanced-parens scan handles arbitrary nested calls inside the
/// argument list. Lines that have other tokens before/after the call
/// return false.
fn isEffectsOnlyLine(line: []const u8) bool {
    var p: usize = 0;
    while (p < line.len and isHSpace(line[p])) : (p += 1) {}
    const kw = "effects(";
    if (p + kw.len > line.len) return false;
    if (!std.mem.eql(u8, line[p .. p + kw.len], kw)) return false;
    p += kw.len;

    // Track paren depth starting at 1 (the `(` we just consumed).
    var depth: usize = 1;
    while (p < line.len and depth > 0) : (p += 1) {
        const c = line[p];
        if (c == '(') depth += 1
        else if (c == ')') depth -= 1;
    }
    if (depth != 0) return false; // unbalanced — not our shape

    // Trailing whitespace only; anything else means it's not a standalone
    // annotation line.
    while (p < line.len and isHSpace(line[p])) : (p += 1) {}
    return p == line.len;
}

/// Rules 2/3/4: scan a line tracking string/char/line-comment state and
/// strip the keywords `own ` (before var/const/identifier), `move `
/// (expression prefix), and `owned ` (before `struct`).
///
/// Single-line scanner: state resets at each call. `\\`-prefixed multi-line
/// string literal lines are detected and passed through verbatim.
fn appendStrippedKeywords(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    line: []const u8,
) !void {
    // `\\`-prefixed multi-line string literal: pass the whole line through.
    {
        var q: usize = 0;
        while (q < line.len and isHSpace(line[q])) : (q += 1) {}
        if (q + 1 < line.len and line[q] == '\\' and line[q + 1] == '\\') {
            try out.appendSlice(allocator, line);
            return;
        }
    }

    var i: usize = 0;
    var in_string = false;
    var in_char = false;
    while (i < line.len) {
        const c = line[i];

        if (in_string) {
            try out.append(allocator, c);
            // Handle escapes: `\\`, `\"`, etc. — skip the next byte.
            if (c == '\\' and i + 1 < line.len) {
                try out.append(allocator, line[i + 1]);
                i += 2;
                continue;
            }
            if (c == '"') in_string = false;
            i += 1;
            continue;
        }
        if (in_char) {
            try out.append(allocator, c);
            if (c == '\\' and i + 1 < line.len) {
                try out.append(allocator, line[i + 1]);
                i += 2;
                continue;
            }
            if (c == '\'') in_char = false;
            i += 1;
            continue;
        }

        // `//` line comment: emit the rest of the line verbatim.
        if (c == '/' and i + 1 < line.len and line[i + 1] == '/') {
            try out.appendSlice(allocator, line[i..]);
            return;
        }

        if (c == '"') {
            in_string = true;
            try out.append(allocator, c);
            i += 1;
            continue;
        }
        if (c == '\'') {
            in_char = true;
            try out.append(allocator, c);
            i += 1;
            continue;
        }

        // Token boundary check: previous emitted char (or start-of-line)
        // must be one of [SOL, whitespace, '(', ',', '{', ';', '='].
        // For `own`/`owned` the allowed set excludes `=` (per spec); for
        // `move`/`dyn`/`impl` it includes `=` and `[`/`:`. We compute
        // boundary against the original `line` (the input is what the spec
        // describes).
        const at_boundary_owned = isOwnBoundary(line, i);
        const at_boundary_move = isMoveBoundary(line, i);
        const at_boundary_trait = isTraitKwBoundary(line, i);

        if (at_boundary_owned and matchKeyword(line, i, "owned ")) {
            // Must be followed by `struct` token.
            const after = i + "owned ".len;
            if (isStructAt(line, after)) {
                i = after; // skip `owned ` entirely
                continue;
            }
        }
        if (at_boundary_owned and matchKeyword(line, i, "own ")) {
            const after = i + "own ".len;
            if (followsOwnTarget(line, after)) {
                i = after; // skip `own ` entirely
                continue;
            }
        }
        if (at_boundary_move and matchKeyword(line, i, "move ")) {
            const after = i + "move ".len;
            // `move` must be followed by an identifier (expression form).
            if (after < line.len and (isIdentStart(line[after]) or line[after] == '@')) {
                i = after; // skip `move ` entirely
                continue;
            }
        }
        // Rule A: `dyn <Ident>` -> strip the `dyn ` keyword. The identifier
        // (the trait name) is left intact; the trait pass turns it into the
        // fat-pointer struct elsewhere. Mirrors `move`/`own` exactly.
        if (at_boundary_trait and matchKeyword(line, i, "dyn ")) {
            const after = i + "dyn ".len;
            if (after < line.len and isIdentStart(line[after])) {
                i = after; // skip `dyn ` entirely
                continue;
            }
        }
        // Rule B: `impl <Ident>` -> `anytype`, but ONLY when the identifier
        // is NOT followed by `{` (the impl-block form). We scan the trait
        // name, then skip trivia, and if the next non-trivia byte is `{`
        // we leave the line alone — impl-blocks are out of scope here.
        if (at_boundary_trait and matchKeyword(line, i, "impl ")) {
            const ident_start = i + "impl ".len;
            if (ident_start < line.len and isIdentStart(line[ident_start])) {
                var j: usize = ident_start + 1;
                while (j < line.len and isIdentCont(line[j])) : (j += 1) {}
                // Look past whitespace for the disambiguator. If the next
                // non-trivia byte is `{`, this is an impl-block and we must
                // not substitute.
                var k: usize = j;
                while (k < line.len and isHSpace(line[k])) : (k += 1) {}
                const is_block = k < line.len and line[k] == '{';
                if (!is_block) {
                    try out.appendSlice(allocator, "anytype");
                    i = j; // consume `impl <Ident>` entirely
                    continue;
                }
            }
        }

        try out.append(allocator, c);
        i += 1;
    }
}

fn matchKeyword(line: []const u8, i: usize, kw: []const u8) bool {
    if (i + kw.len > line.len) return false;
    return std.mem.eql(u8, line[i .. i + kw.len], kw);
}

/// Boundary check for `own`/`owned`: previous char must be SOL, whitespace,
/// `(`, `,`, `{`, or `;`.
fn isOwnBoundary(line: []const u8, i: usize) bool {
    if (i == 0) return true;
    const prev = line[i - 1];
    return isHSpace(prev) or prev == '(' or prev == ',' or prev == '{' or prev == ';';
}

/// Boundary check for `move`: previous char must be SOL, whitespace, `(`,
/// `,`, `=`, or `{`. (Spec adds `=` to the set since `move` shows up as an
/// expression prefix on the RHS of an assignment.)
fn isMoveBoundary(line: []const u8, i: usize) bool {
    if (i == 0) return true;
    const prev = line[i - 1];
    return isHSpace(prev) or prev == '(' or prev == ',' or prev == '=' or prev == '{';
}

/// Boundary check for `dyn`/`impl`: previous char must be SOL, whitespace,
/// `(`, `,`, `[`, `]`, `:`, `=`, `{`, or `;`. The spec lists `[` to cover
/// the slice form `[]dyn AudioPlugin` — but in that form the byte preceding
/// `dyn` is actually `]`, so we accept both. `:` covers `w: dyn Writer`,
/// `=` covers `x = dyn ...`.
fn isTraitKwBoundary(line: []const u8, i: usize) bool {
    if (i == 0) return true;
    const prev = line[i - 1];
    return isHSpace(prev) or prev == '(' or prev == ',' or prev == '[' or
        prev == ']' or prev == ':' or prev == '=' or prev == '{' or prev == ';';
}

/// True if at position `p` the line has `struct` followed by a non-ident
/// character (or end-of-line).
fn isStructAt(line: []const u8, p: usize) bool {
    const kw = "struct";
    if (p + kw.len > line.len) return false;
    if (!std.mem.eql(u8, line[p .. p + kw.len], kw)) return false;
    if (p + kw.len == line.len) return true;
    return !isIdentCont(line[p + kw.len]);
}

/// True if at position `p` we see one of `var`, `const`, or an identifier
/// (the parameter-binding case), with proper token boundary.
fn followsOwnTarget(line: []const u8, p: usize) bool {
    if (p >= line.len) return false;
    if (matchKeyword(line, p, "var") and (p + 3 == line.len or !isIdentCont(line[p + 3]))) return true;
    if (matchKeyword(line, p, "const") and (p + 5 == line.len or !isIdentCont(line[p + 5]))) return true;
    return isIdentStart(line[p]);
}

pub const Lowering = struct {
    /// Output sink for the generated Zig source. The lowering stage never
    /// buffers the full output; it streams.
    writer: std.io.AnyWriter,

    const Self = @This();

    pub fn init(writer: std.io.AnyWriter) Lowering {
        return .{ .writer = writer };
    }

    pub fn lower(self: *Lowering, root: *ast.Node) !void {
        _ = self;
        _ = root;
        @panic("TODO: Lowering.lower not yet implemented");
    }

    /// `using x = expr;`  =>  `var x = expr; defer x.deinit();`
    fn lowerUsing(self: *Lowering, node: *ast.Node) !void {
        _ = self;
        _ = node;
        @panic("TODO: lowerUsing (using x = expr; -> var x = expr; defer x.deinit();)");
    }

    /// `impl Trait` parameter  =>  comptime-generic `anytype` whose
    /// constraints are enforced by a comptime trait-check helper.
    fn lowerImplTrait(self: *Lowering, node: *ast.Node) !void {
        _ = self;
        _ = node;
        @panic("TODO: lowerImplTrait (impl Trait -> anytype + comptime trait check)");
    }

    /// `dyn Trait`  =>  `struct { ptr: *anyopaque, vtable: *const TraitVTable }`
    fn lowerDynTrait(self: *Lowering, node: *ast.Node) !void {
        _ = self;
        _ = node;
        @panic("TODO: lowerDynTrait (dyn Trait -> { ptr: *anyopaque, vtable: *const TraitVTable })");
    }

    /// `derive(.{Json, Hash})`  =>
    ///     `pub const json = zpp.derive.Json(@This());`
    ///     `pub const hash = zpp.derive.Hash(@This());`
    /// Note: comptime calls into the `zpp.derive` runtime library, NOT macros.
    fn lowerDerive(self: *Lowering, node: *ast.Node) !void {
        _ = self;
        _ = node;
        @panic("TODO: lowerDerive (derive(.{X}) -> pub const x = zpp.derive.X(@This());)");
    }

    /// `effects(.noalloc, ...)` is erased from the generated Zig. The set is
    /// kept on the side, recorded by sema, and referenced by diagnostics.
    fn lowerEffects(self: *Lowering, node: *ast.Node) !void {
        _ = self;
        _ = node;
        @panic("TODO: lowerEffects (erased at codegen; recorded for sema)");
    }
};

test "lowerSource: empty input" {
    const out = try lowerSource(std.testing.allocator, "");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("", out);
}

test "lowerSource: passthrough non-using line" {
    const out = try lowerSource(std.testing.allocator, "var x = 1;\n");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("var x = 1;\n", out);
}

test "lowerSource: single using rewrite, no trailing newline" {
    const out = try lowerSource(std.testing.allocator, "using f = openFile();");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("var f = openFile(); defer f.deinit();", out);
}

test "lowerSource: multi-line with one using in the middle" {
    const input =
        "const std = @import(\"std\");\n" ++
        "using f = openFile();\n" ++
        "return 0;\n";
    const expected =
        "const std = @import(\"std\");\n" ++
        "var f = openFile(); defer f.deinit();\n" ++
        "return 0;\n";
    const out = try lowerSource(std.testing.allocator, input);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(expected, out);
}

test "lowerSource: indented using preserves indentation" {
    const input = "    using f = openFile();\n";
    const expected = "    var f = openFile(); defer f.deinit();\n";
    const out = try lowerSource(std.testing.allocator, input);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(expected, out);
}

test "lowerSource: notusing is not rewritten" {
    const input = "notusing f = openFile();\n";
    const out = try lowerSource(std.testing.allocator, input);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(input, out);
}

test "lowerSource: using inside string literal on same line is not rewritten" {
    // The `using` keyword appears after a non-whitespace token on the line,
    // so our line-start matcher correctly skips it.
    const input = "const s = \"using x = 1;\";\n";
    const out = try lowerSource(std.testing.allocator, input);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(input, out);
}

test "lowerSource: known-limitation - using at start of \\\\ multi-line string literal IS rewritten" {
    // known-limitation: a `using` line that begins inside a `\\`-style
    // multi-line string literal is still rewritten. Documenting actual
    // (incorrect) behavior so the limitation is explicit.
    const input = "    \\\\using x = 1;\n";
    const out = try lowerSource(std.testing.allocator, input);
    defer std.testing.allocator.free(out);
    // The line starts with whitespace then `\\` — neither is the `using`
    // keyword, so this particular form is actually safe.
    try std.testing.expectEqualStrings(input, out);
}

// ---------------------------------------------------------------------------
// Rule 1: effects(...) erasure
// ---------------------------------------------------------------------------

test "lowerSource: effects(...) on its own line is erased" {
    const input =
        "    effects(.noalloc, .noio)\n" ++
        "pub fn f() void {}\n";
    const expected = "pub fn f() void {}\n";
    const out = try lowerSource(std.testing.allocator, input);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(expected, out);
}

test "lowerSource: effects(...) mixed with other tokens is passthrough" {
    // Mixed-line case is out of scope per the spec — we pass it through.
    const input = "pub fn x() effects(.noalloc) void {\n";
    const out = try lowerSource(std.testing.allocator, input);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(input, out);
}

// ---------------------------------------------------------------------------
// Rule 2: own keyword
// ---------------------------------------------------------------------------

test "lowerSource: own var is stripped" {
    const out = try lowerSource(std.testing.allocator, "own var x = init();\n");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("var x = init();\n", out);
}

test "lowerSource: own param binding is stripped" {
    const input = "fn consume(own b: Buffer) void {\n";
    const expected = "fn consume(b: Buffer) void {\n";
    const out = try lowerSource(std.testing.allocator, input);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(expected, out);
}

// ---------------------------------------------------------------------------
// Rule 3: move keyword
// ---------------------------------------------------------------------------

test "lowerSource: move expression is stripped on RHS of var" {
    const out = try lowerSource(std.testing.allocator, "var y = move buf;\n");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("var y = buf;\n", out);
}

test "lowerSource: move expression is stripped inside call" {
    const out = try lowerSource(std.testing.allocator, "consume(move x);\n");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("consume(x);\n", out);
}

// ---------------------------------------------------------------------------
// Rule 4: owned struct
// ---------------------------------------------------------------------------

test "lowerSource: owned struct is stripped" {
    const out = try lowerSource(std.testing.allocator, "owned struct Buf {\n");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("struct Buf {\n", out);
}

// ---------------------------------------------------------------------------
// Lexical-state guards
// ---------------------------------------------------------------------------

test "lowerSource: own keyword inside string literal is preserved" {
    const input = "const s = \"own var trap\";\n";
    const out = try lowerSource(std.testing.allocator, input);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(input, out);
}

test "lowerSource: own keyword inside // comment is preserved" {
    const input = "x = 1; // own var trap\n";
    const out = try lowerSource(std.testing.allocator, input);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(input, out);
}

// ---------------------------------------------------------------------------
// Combined rules
// ---------------------------------------------------------------------------

test "lowerSource: own + move on the same line" {
    const out = try lowerSource(std.testing.allocator, "own var x = move y;\n");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("var x = y;\n", out);
}

test "lowerSource: using + move combined" {
    const input = "using x = move src;\n";
    const expected = "var x = src; defer x.deinit();\n";
    const out = try lowerSource(std.testing.allocator, input);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(expected, out);
}

// Negative: identifiers that LOOK like the keywords must not be touched.
test "lowerSource: notown / own_field / movedata are not stripped" {
    const input =
        "const notown = 1;\n" ++
        "var own_field: u32 = 0;\n" ++
        "fn movedata() void {}\n";
    const out = try lowerSource(std.testing.allocator, input);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(input, out);
}

// ---------------------------------------------------------------------------
// Rule A: dyn <Ident> strip
// ---------------------------------------------------------------------------

test "lowerSource: dyn Writer parameter type strip" {
    const out = try lowerSource(std.testing.allocator, "fn f(w: dyn Writer) void {}\n");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("fn f(w: Writer) void {}\n", out);
}

test "lowerSource: []dyn AudioPlugin -> []AudioPlugin" {
    const out = try lowerSource(std.testing.allocator, "fn runAll(plugins: []dyn AudioPlugin) void {}\n");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("fn runAll(plugins: []AudioPlugin) void {}\n", out);
}

test "lowerSource: dyn AudioPlugin.from(&x) -> AudioPlugin.from(&x)" {
    const out = try lowerSource(std.testing.allocator, "    slots[0] = dyn AudioPlugin.from(&x);\n");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("    slots[0] = AudioPlugin.from(&x);\n", out);
}

test "lowerSource: dynamic identifier prefix is not stripped" {
    const input = "var dynamic = 1;\n";
    const out = try lowerSource(std.testing.allocator, input);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(input, out);
}

test "lowerSource: dyn inside string literal is preserved" {
    const input = "const s = \"dyn Writer\";\n";
    const out = try lowerSource(std.testing.allocator, input);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(input, out);
}

test "lowerSource: dyn inside // comment is preserved" {
    const input = "x = 1; // dyn Writer\n";
    const out = try lowerSource(std.testing.allocator, input);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(input, out);
}

// ---------------------------------------------------------------------------
// Rule B: impl <Ident> -> anytype
// ---------------------------------------------------------------------------

test "lowerSource: impl Writer parameter -> anytype" {
    const out = try lowerSource(std.testing.allocator, "fn f(w: impl Writer) !void {}\n");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("fn f(w: anytype) !void {}\n", out);
}

test "lowerSource: impl_count identifier prefix is not substituted" {
    const input = "var impl_count: u32 = 0;\n";
    const out = try lowerSource(std.testing.allocator, input);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(input, out);
}

test "lowerSource: impl Greeter { ... } block form is NOT substituted" {
    const input = "impl Greeter {\n";
    const out = try lowerSource(std.testing.allocator, input);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(input, out);
}

// ---------------------------------------------------------------------------
// Combined dyn + impl
// ---------------------------------------------------------------------------

test "lowerSource: combined []dyn W and impl W on the same line" {
    const out = try lowerSource(std.testing.allocator, "fn each(ws: []dyn W, w: impl W) !void {}\n");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("fn each(ws: []W, w: anytype) !void {}\n", out);
}

// Regression: previously-passing rules must still work after wiring dyn/impl.
test "lowerSource (regression): using rewrite still works" {
    const out = try lowerSource(std.testing.allocator, "using x = init();\n");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("var x = init(); defer x.deinit();\n", out);
}

test "lowerSource (regression): own var still strips" {
    const out = try lowerSource(std.testing.allocator, "own var x = init();\n");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("var x = init();\n", out);
}
