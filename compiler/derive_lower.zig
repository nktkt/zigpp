//! Postfix `derive(.{...})` lowering.
//!
//! Translates `} derive(.{ X, Y, Z });` — the postfix decoration that follows
//! a struct literal's closing brace — into `pub const x = zpp.derive.X(@This());`
//! lines injected INSIDE the struct body. The trailing `derive(...);` suffix
//! is dropped, the struct's own closing brace is re-emitted, and a blank line
//! separates the original body content from the injected decls.
//!
//! Splicing strategy (mirrors `trait_lower.zig`): tokenize once, walk left to
//! right, and accumulate output by appending the unmodified prefix segment up
//! to each match's struct body, then writing the body's content + the injected
//! `pub const` lines + the closing `};`. All offsets stay valid for one pass.
//!
//! The lowered Zig REFERENCES `zpp.derive.<Trait>(@This())` — making the
//! result executable requires a downstream `zpp` runtime module wired by the
//! consumer's build. That runtime is out of scope for this pass; the fixture
//! is byte-equality-only.
//!
//! Limitation: only the `derive(.{...})` shape is recognized. A `derive(...)`
//! call whose argument is anything other than an anonymous tuple literal is
//! left alone. A bare `derive` identifier (e.g. `const derive = 1;`) and any
//! `derive(...)` not preceded immediately by an `rbrace` also pass through.

const std = @import("std");
const lexer = @import("lexer.zig");

/// Find every `} derive(.{ X, Y, ... });` postfix on a struct decl in `source`
/// and rewrite it to inject `pub const x = zpp.derive.X(@This());` lines into
/// the struct body, dropping the `derive(...)` suffix.
///
/// Caller owns the returned slice. If no derive suffix is found, the result
/// is byte-equal to the input.
///
/// Note: the produced Zig references `zpp.derive.<Trait>` symbols which must
/// be supplied by a downstream runtime module — this pass does not provide
/// that runtime, only the lowered call sites.
pub fn lowerDerives(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    const tokens = try lexer.tokenize(allocator, source);
    defer allocator.free(tokens);

    var out = std.ArrayList(u8){};
    defer out.deinit(allocator);

    // Track whether at least one derive postfix was actually rewritten —
    // only then do we inject the `const zpp = @import("zpp");` runtime line.
    // A bare `derive` identifier or a derive-shaped call we leave alone must
    // NOT cause the injection.
    var rewrote_any = false;

    // Cursor into `source` tracking what has been emitted so far.
    var src_cursor: usize = 0;

    var ti: usize = 0;
    while (ti < tokens.len) : (ti += 1) {
        const t = tokens[ti];
        if (t.kind != .rbrace) continue;

        // Anchor pattern: rbrace kw_derive lparen dot lbrace
        const k1 = nextNonTrivia(tokens, ti + 1) orelse continue;
        if (tokens[k1].kind != .kw_derive) continue;
        const k2 = nextNonTrivia(tokens, k1 + 1) orelse continue;
        if (tokens[k2].kind != .lparen) continue;
        const k3 = nextNonTrivia(tokens, k2 + 1) orelse continue;
        if (tokens[k3].kind != .dot) continue;
        const k4 = nextNonTrivia(tokens, k3 + 1) orelse continue;
        if (tokens[k4].kind != .lbrace) continue;

        // Parse the trait list: idents separated by commas, with optional
        // trailing comma. Comma-after-last-ident is consumed silently so
        // `.{ A, B, }` and `.{ A, B }` produce identical output.
        var traits = std.ArrayList([]const u8){};
        defer traits.deinit(allocator);

        var cursor = nextNonTrivia(tokens, k4 + 1) orelse continue;
        var ok = true;
        while (true) {
            // Allow the closing rbrace of the tuple here (handles both an
            // empty tuple `.{ }` — though we still consume it — and the
            // post-trailing-comma position).
            if (tokens[cursor].kind == .rbrace) break;
            if (tokens[cursor].kind != .ident) {
                ok = false;
                break;
            }
            const tt = tokens[cursor];
            try traits.append(allocator, source[tt.start..tt.end]);
            const after = nextNonTrivia(tokens, cursor + 1) orelse {
                ok = false;
                break;
            };
            if (tokens[after].kind == .rbrace) {
                cursor = after;
                break;
            }
            if (tokens[after].kind != .comma) {
                ok = false;
                break;
            }
            cursor = nextNonTrivia(tokens, after + 1) orelse {
                ok = false;
                break;
            };
        }
        if (!ok) continue;
        // `cursor` is the rbrace closing the .{...}.
        const tuple_rbrace_idx = cursor;

        // Expect rparen then semicolon.
        const rparen_idx = nextNonTrivia(tokens, tuple_rbrace_idx + 1) orelse continue;
        if (tokens[rparen_idx].kind != .rparen) continue;
        const semi_idx = nextNonTrivia(tokens, rparen_idx + 1) orelse continue;
        if (tokens[semi_idx].kind != .semicolon) continue;

        // We have a valid match. Identify the struct's matching `{` so we
        // can recover the body's indentation.
        const struct_rbrace_tok = t;
        const struct_lbrace_idx = findMatchingLbrace(tokens, ti) orelse continue;
        const struct_lbrace_tok = tokens[struct_lbrace_idx];

        // Body indent: indentation of the first non-blank line after the
        // opening `{`. If we can't infer one (empty body), default to four
        // spaces — ties our output to a deterministic shape.
        const body_indent = inferBodyIndent(source, struct_lbrace_tok.end);

        // Outer indent: indent of the original `derive` line — used for the
        // re-emitted `};`.
        const outer_indent = computeIndent(source, tokens[k1].start);

        // Emit up to the start of the line that contains the struct's closing
        // `}`. Stopping at the line-start (rather than at the rbrace byte)
        // ensures any leading whitespace on that line — the indent that used
        // to belong to the `}` — is not carried into the blank line we emit.
        const rbrace_line_start = lineStartOf(source, struct_rbrace_tok.start);
        try out.appendSlice(allocator, source[src_cursor..rbrace_line_start]);

        // Blank line, then the injected decls. The body's trailing `\n` is
        // already in the prefix; the extra `\n` here makes the visual gap.
        try out.append(allocator, '\n');
        for (traits.items) |trait_name| {
            try out.appendSlice(allocator, body_indent);
            try out.appendSlice(allocator, "pub const ");
            try appendLowerFirst(allocator, &out, trait_name);
            try out.appendSlice(allocator, " = zpp.derive.");
            try out.appendSlice(allocator, trait_name);
            try out.appendSlice(allocator, "(@This());\n");
        }

        // Closing `};` at the outer indent.
        try out.appendSlice(allocator, outer_indent);
        try out.appendSlice(allocator, "};");

        // Advance past the original `};` of the struct AND the trailing
        // `derive(...);` suffix.
        src_cursor = tokens[semi_idx].end;
        ti = semi_idx; // outer `+= 1` advances past the semicolon
        rewrote_any = true;
    }

    try out.appendSlice(allocator, source[src_cursor..]);

    // If a derive was actually lowered, prepend `const zpp = @import("zpp");`
    // unless the source already imports it (substring match suffices). The
    // injection is purely a runtime-availability fix for the lowered output.
    if (rewrote_any and std.mem.indexOf(u8, source, "const zpp = @import(\"zpp\");") == null) {
        const body = try out.toOwnedSlice(allocator);
        defer allocator.free(body);
        var prefixed = std.ArrayList(u8){};
        defer prefixed.deinit(allocator);
        try prefixed.appendSlice(allocator, "const zpp = @import(\"zpp\");\n");
        try prefixed.appendSlice(allocator, body);
        return prefixed.toOwnedSlice(allocator);
    }

    return out.toOwnedSlice(allocator);
}

/// Scan forward from `start` skipping doc-comment tokens (the lexer already
/// skips whitespace). Returns the index of the next significant token, or
/// null at end-of-stream.
fn nextNonTrivia(tokens: []const lexer.Token, start: usize) ?usize {
    var i = start;
    while (i < tokens.len) : (i += 1) {
        switch (tokens[i].kind) {
            .doc_comment, .module_doc_comment => continue,
            .eof => return null,
            else => return i,
        }
    }
    return null;
}

/// Walk backward from the index of an `rbrace` token to find the index of
/// its matching `lbrace`. Tracks nesting depth.
fn findMatchingLbrace(tokens: []const lexer.Token, rbrace_idx: usize) ?usize {
    var depth: usize = 1;
    var i: isize = @as(isize, @intCast(rbrace_idx)) - 1;
    while (i >= 0) : (i -= 1) {
        const k = tokens[@intCast(i)].kind;
        if (k == .rbrace) depth += 1
        else if (k == .lbrace) {
            depth -= 1;
            if (depth == 0) return @intCast(i);
        }
    }
    return null;
}

fn isHSpace(c: u8) bool {
    return c == ' ' or c == '\t';
}

/// Return the byte offset of the start of the line containing `pos`.
fn lineStartOf(source: []const u8, pos: usize) usize {
    var ls: usize = pos;
    while (ls > 0 and source[ls - 1] != '\n') : (ls -= 1) {}
    return ls;
}

/// Return the leading horizontal whitespace on the line containing `pos`.
fn computeIndent(source: []const u8, pos: usize) []const u8 {
    var line_start: usize = pos;
    while (line_start > 0 and source[line_start - 1] != '\n') : (line_start -= 1) {}
    var p: usize = line_start;
    while (p < pos and isHSpace(source[p])) : (p += 1) {}
    return source[line_start..p];
}

/// Infer the struct body's indent by reading the first non-blank line after
/// the opening `{`. If the body has no field lines we default to 4 spaces so
/// the output is still deterministic.
fn inferBodyIndent(source: []const u8, after_lbrace: usize) []const u8 {
    var p: usize = after_lbrace;
    while (p < source.len) {
        // Skip a single newline if present, then horizontal whitespace.
        const line_start_search = p;
        while (p < source.len and source[p] != '\n') : (p += 1) {
            if (!isHSpace(source[p])) {
                // Non-whitespace before any newline: this means the `{`
                // and the first body content sit on the same line, so we
                // cannot use the prior line's leading indent. Fall through
                // to default.
                _ = line_start_search;
                return "    ";
            }
        }
        if (p >= source.len) return "    ";
        p += 1; // consume '\n'
        const line_start = p;
        while (p < source.len and isHSpace(source[p])) : (p += 1) {}
        if (p >= source.len) return "    ";
        if (source[p] == '\n') continue; // blank line, try next
        return source[line_start..p];
    }
    return "    ";
}

/// Append `trait_name` to `out` with the first ASCII letter lowercased.
/// Hash -> hash, Json -> json, MyDerive -> myDerive.
fn appendLowerFirst(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    trait_name: []const u8,
) !void {
    if (trait_name.len == 0) return;
    const c = trait_name[0];
    const lc: u8 = if (c >= 'A' and c <= 'Z') c + 32 else c;
    try out.append(allocator, lc);
    try out.appendSlice(allocator, trait_name[1..]);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "lowerDerives: empty source -> unchanged" {
    const out = try lowerDerives(testing.allocator, "");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("", out);
}

test "lowerDerives: no derive keyword -> byte-equal output" {
    const src =
        "const std = @import(\"std\");\n" ++
        "pub fn main() !void {}\n";
    const out = try lowerDerives(testing.allocator, src);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(src, out);
}

test "lowerDerives: single trait" {
    const src =
        "const X = struct {\n" ++
        "    a: u32,\n" ++
        "} derive(.{ Hash });\n";
    const expected =
        "const zpp = @import(\"zpp\");\n" ++
        "const X = struct {\n" ++
        "    a: u32,\n" ++
        "\n" ++
        "    pub const hash = zpp.derive.Hash(@This());\n" ++
        "};\n";
    const out = try lowerDerives(testing.allocator, src);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(expected, out);
}

test "lowerDerives: three traits in declaration order" {
    const src =
        "const User = struct {\n" ++
        "    id: u64,\n" ++
        "    name: []const u8,\n" ++
        "} derive(.{ Hash, Json, Debug });\n";
    const expected =
        "const zpp = @import(\"zpp\");\n" ++
        "const User = struct {\n" ++
        "    id: u64,\n" ++
        "    name: []const u8,\n" ++
        "\n" ++
        "    pub const hash = zpp.derive.Hash(@This());\n" ++
        "    pub const json = zpp.derive.Json(@This());\n" ++
        "    pub const debug = zpp.derive.Debug(@This());\n" ++
        "};\n";
    const out = try lowerDerives(testing.allocator, src);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(expected, out);
}

test "lowerDerives: trailing comma in trait list" {
    const src =
        "const X = struct {\n" ++
        "    a: u32,\n" ++
        "} derive(.{ Hash, Json, });\n";
    const expected =
        "const zpp = @import(\"zpp\");\n" ++
        "const X = struct {\n" ++
        "    a: u32,\n" ++
        "\n" ++
        "    pub const hash = zpp.derive.Hash(@This());\n" ++
        "    pub const json = zpp.derive.Json(@This());\n" ++
        "};\n";
    const out = try lowerDerives(testing.allocator, src);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(expected, out);
}

test "lowerDerives: multi-line trait list" {
    const src =
        "const X = struct {\n" ++
        "    a: u32,\n" ++
        "} derive(.{\n" ++
        "    Hash,\n" ++
        "    Json,\n" ++
        "});\n";
    const expected =
        "const zpp = @import(\"zpp\");\n" ++
        "const X = struct {\n" ++
        "    a: u32,\n" ++
        "\n" ++
        "    pub const hash = zpp.derive.Hash(@This());\n" ++
        "    pub const json = zpp.derive.Json(@This());\n" ++
        "};\n";
    const out = try lowerDerives(testing.allocator, src);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(expected, out);
}

test "lowerDerives: bare derive identifier passes through" {
    const src = "const derive = 1;\n";
    const out = try lowerDerives(testing.allocator, src);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(src, out);
}

test "lowerDerives: derive call not preceded by rbrace passes through" {
    // Here `derive(.{Hash})` appears as a function-call expression with no
    // preceding struct rbrace. The pass must leave it alone.
    const src = "const x = derive(.{Hash});\n";
    const out = try lowerDerives(testing.allocator, src);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(src, out);
}

test "lowerDerives: two structs each with their own derive" {
    const src =
        "const A = struct {\n" ++
        "    x: u32,\n" ++
        "} derive(.{ Hash });\n" ++
        "\n" ++
        "const B = struct {\n" ++
        "    y: u32,\n" ++
        "} derive(.{ Json });\n";
    const expected =
        "const zpp = @import(\"zpp\");\n" ++
        "const A = struct {\n" ++
        "    x: u32,\n" ++
        "\n" ++
        "    pub const hash = zpp.derive.Hash(@This());\n" ++
        "};\n" ++
        "\n" ++
        "const B = struct {\n" ++
        "    y: u32,\n" ++
        "\n" ++
        "    pub const json = zpp.derive.Json(@This());\n" ++
        "};\n";
    const out = try lowerDerives(testing.allocator, src);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(expected, out);
}

test "lowerDerives: indented struct uses body field indent" {
    // The body's first field is indented 8 spaces; the injected pub const
    // line must match that indent. The closing `};` matches the `derive`
    // keyword's line indent (4 spaces).
    const src =
        "    const X = struct {\n" ++
        "        a: u32,\n" ++
        "    } derive(.{ Hash });\n";
    const expected =
        "const zpp = @import(\"zpp\");\n" ++
        "    const X = struct {\n" ++
        "        a: u32,\n" ++
        "\n" ++
        "        pub const hash = zpp.derive.Hash(@This());\n" ++
        "    };\n";
    const out = try lowerDerives(testing.allocator, src);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(expected, out);
}

test "lowerDerives: PascalCase trait lowercases first char only" {
    const src =
        "const X = struct {\n" ++
        "    a: u32,\n" ++
        "} derive(.{ MyDerive });\n";
    const expected =
        "const zpp = @import(\"zpp\");\n" ++
        "const X = struct {\n" ++
        "    a: u32,\n" ++
        "\n" ++
        "    pub const myDerive = zpp.derive.MyDerive(@This());\n" ++
        "};\n";
    const out = try lowerDerives(testing.allocator, src);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(expected, out);
}
