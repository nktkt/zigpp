//! Trait declaration lowering.
//!
//! Translates each `trait Name { fn m(self, ...) Ret; ... }` block in a Zig++
//! source string into a Zig fat-pointer struct (a `*anyopaque` data pointer
//! plus a `*const VTable` table pointer), a nested `VTable` struct listing
//! each method as a function pointer, and a public dispatch wrapper per
//! method that forwards to `self.vtable.<name>(self.ptr, ...)`.
//!
//! Why `anyerror!T` for error-returning methods (rather than the method's own
//! error set)? The vtable type cannot reference a method-specific error set
//! without significant per-impl inference machinery, and we don't want to
//! force the trait author to write the error set explicitly. We pay the cost
//! of erasing the error set into `anyerror` and document it here. Methods
//! whose return type does not begin with `!` are copied through unchanged.
//!
//! Splicing strategy: the input is walked once and the output is built by
//! appending the prefix segment, the lowered replacement, then the segment
//! after the `}` — repeated for each trait. This avoids needing to do
//! reverse-order in-place mutation and keeps all source offsets valid for
//! the duration of one pass.

const std = @import("std");
const lexer = @import("lexer.zig");

/// Find every `trait <Name> { ... }` or `extern interface <Name> { ... }`
/// block in `source` and replace it with a Zig fat-pointer struct + vtable +
/// dispatch wrappers. Returns an owned, transformed copy of `source`. If there
/// are no matching blocks, the result is byte-equal to the input.
///
/// For the research compiler, `extern interface` lowers identically to `trait`;
/// future work could differentiate by enforcing extern struct layout / C ABI on
/// the VTable so plugin DLLs can be loaded across compiler versions.
pub fn lowerTraits(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    const tokens = try lexer.tokenize(allocator, source);
    defer allocator.free(tokens);

    var out = std.ArrayList(u8){};
    defer out.deinit(allocator);

    // Cursor into `source` tracking what has been emitted so far.
    var src_cursor: usize = 0;

    var ti: usize = 0;
    while (ti < tokens.len) : (ti += 1) {
        const t = tokens[ti];

        // Match either `kw_trait ident lbrace` or
        // `kw_extern kw_interface ident lbrace`. The matched start token is
        // `t` (whose `.start` becomes the splice anchor); `name_idx`/`brace_idx`
        // are token indices for the name and the opening brace.
        var name_idx: usize = 0;
        var lbrace_idx: usize = 0;
        if (t.kind == .kw_trait) {
            if (ti + 2 >= tokens.len) break;
            if (tokens[ti + 1].kind != .ident or tokens[ti + 2].kind != .lbrace) continue;
            name_idx = ti + 1;
            lbrace_idx = ti + 2;
        } else if (t.kind == .kw_extern) {
            // `extern interface <Name> {` — require all four tokens contiguously.
            // The lexer skips trivia, so adjacent tokens here are already the
            // significant ones.
            if (ti + 3 >= tokens.len) break;
            if (tokens[ti + 1].kind != .kw_interface or
                tokens[ti + 2].kind != .ident or
                tokens[ti + 3].kind != .lbrace) continue;
            name_idx = ti + 2;
            lbrace_idx = ti + 3;
        } else {
            continue;
        }

        const name_tok = tokens[name_idx];
        const lbrace_tok = tokens[lbrace_idx];
        _ = lbrace_tok;

        // Find the matching rbrace using depth tracking.
        var depth: usize = 1;
        var end_ti: usize = lbrace_idx + 1;
        while (end_ti < tokens.len and depth > 0) : (end_ti += 1) {
            switch (tokens[end_ti].kind) {
                .lbrace => depth += 1,
                .rbrace => depth -= 1,
                .eof => break,
                else => {},
            }
        }
        if (depth != 0) continue; // unbalanced — leave alone
        // After the loop, `end_ti` is one past the matching rbrace token.
        const rbrace_tok = tokens[end_ti - 1];

        const trait_start: usize = t.start;
        const trait_end_excl: usize = rbrace_tok.end; // exclusive end in source

        // Emit everything before the matched keyword (trait or extern).
        try out.appendSlice(allocator, source[src_cursor..trait_start]);

        // Compute the indentation: leading horizontal whitespace on the line
        // containing the opening keyword.
        const indent = computeIndent(source, trait_start);

        // Parse methods between lbrace and rbrace and emit replacement.
        const name_text = source[name_tok.start..name_tok.end];
        try emitReplacement(
            allocator,
            &out,
            source,
            tokens,
            lbrace_idx + 1, // first token inside the body
            end_ti - 1, // index of the closing rbrace
            name_text,
            indent,
        );

        src_cursor = trait_end_excl;
        ti = end_ti - 1; // outer loop's `+= 1` will advance past the rbrace
    }

    // Tail: everything after the last trait (or all of source if no traits).
    try out.appendSlice(allocator, source[src_cursor..]);

    return out.toOwnedSlice(allocator);
}

fn isHSpace(c: u8) bool {
    return c == ' ' or c == '\t';
}

/// Return the leading horizontal whitespace on the line containing `pos`.
/// Returns a slice into `source` (zero-length if the line has no indent).
fn computeIndent(source: []const u8, pos: usize) []const u8 {
    var line_start: usize = pos;
    while (line_start > 0 and source[line_start - 1] != '\n') : (line_start -= 1) {}
    var p: usize = line_start;
    while (p < pos and isHSpace(source[p])) : (p += 1) {}
    return source[line_start..p];
}

/// Emit the lowered struct corresponding to one trait declaration. `body_first`
/// is the token index of the first token after the trait's `{`; `rbrace_idx`
/// is the index of the trait's matching `}`.
fn emitReplacement(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    source: []const u8,
    tokens: []const lexer.Token,
    body_first: usize,
    rbrace_idx: usize,
    trait_name: []const u8,
    indent: []const u8,
) !void {
    const Method = struct {
        name: []const u8,
        // Slice of the params region between the `(` and matching `)`,
        // INCLUDING leading `self` and any following `, ...`.
        params_src: []const u8,
        // Return type, raw source slice between `)` and `;`, with edge
        // whitespace trimmed.
        ret_src: []const u8,
    };

    var methods = std.ArrayList(Method){};
    defer methods.deinit(allocator);

    // Walk method declarations: kw_fn ident lparen ... rparen <ret tokens> semicolon.
    var i: usize = body_first;
    while (i < rbrace_idx) {
        const tk = tokens[i];
        if (tk.kind != .kw_fn) {
            i += 1;
            continue;
        }
        if (i + 2 >= rbrace_idx) break;
        const m_name_tok = tokens[i + 1];
        const m_lparen_tok = tokens[i + 2];
        if (m_name_tok.kind != .ident or m_lparen_tok.kind != .lparen) {
            i += 1;
            continue;
        }

        // Find matching rparen.
        var pdepth: usize = 1;
        var j: usize = i + 3;
        while (j < rbrace_idx and pdepth > 0) : (j += 1) {
            switch (tokens[j].kind) {
                .lparen => pdepth += 1,
                .rparen => pdepth -= 1,
                else => {},
            }
        }
        if (pdepth != 0) break;
        // tokens[j-1] is the matching rparen.
        const m_rparen_tok = tokens[j - 1];

        // Locate the terminating semicolon for this method declaration.
        var k: usize = j;
        while (k < rbrace_idx and tokens[k].kind != .semicolon) : (k += 1) {}
        if (k >= rbrace_idx) break;
        const m_semi_tok = tokens[k];

        // Params: source bytes between `(` (exclusive) and `)` (exclusive).
        const params_src_raw = source[m_lparen_tok.end..m_rparen_tok.start];
        // Return: source bytes between `)` (exclusive) and `;` (exclusive),
        // trimmed.
        const ret_raw = source[m_rparen_tok.end..m_semi_tok.start];
        const ret_trimmed = std.mem.trim(u8, ret_raw, " \t\r\n");

        try methods.append(allocator, .{
            .name = source[m_name_tok.start..m_name_tok.end],
            .params_src = std.mem.trim(u8, params_src_raw, " \t\r\n"),
            .ret_src = ret_trimmed,
        });

        i = k + 1;
    }

    // ---- Emit the lowered struct -----------------------------------------
    // Header.
    try out.appendSlice(allocator, "pub const ");
    try out.appendSlice(allocator, trait_name);
    try out.appendSlice(allocator, " = struct {\n");
    try writeIndentedLine(allocator, out, indent, "    ptr: *anyopaque,");
    try writeIndentedLine(allocator, out, indent, "    vtable: *const VTable,");
    try writeIndentedLine(allocator, out, indent, "");
    try writeIndentedLine(allocator, out, indent, "    pub const VTable = struct {");

    if (methods.items.len == 0) {
        // Empty VTable: emit `};` on the same indentation level.
        try writeIndentedLine(allocator, out, indent, "    };");
    } else {
        for (methods.items) |m| {
            // `        <name>: *const fn (self: *anyopaque<, others>) <ret>,`
            try out.appendSlice(allocator, indent);
            try out.appendSlice(allocator, "        ");
            try out.appendSlice(allocator, m.name);
            try out.appendSlice(allocator, ": *const fn (self: *anyopaque");
            try writeOtherParamsVtable(out, allocator, m.params_src);
            try out.appendSlice(allocator, ") ");
            try writeReturnType(out, allocator, m.ret_src);
            try out.appendSlice(allocator, ",\n");
        }
        try writeIndentedLine(allocator, out, indent, "    };");
    }

    // Wrappers.
    for (methods.items) |m| {
        try writeIndentedLine(allocator, out, indent, "");
        // `    pub fn <name>(self: <Trait><, others>) <ret> {`
        try out.appendSlice(allocator, indent);
        try out.appendSlice(allocator, "    pub fn ");
        try out.appendSlice(allocator, m.name);
        try out.appendSlice(allocator, "(self: ");
        try out.appendSlice(allocator, trait_name);
        try writeOtherParamsWrapper(out, allocator, m.params_src);
        try out.appendSlice(allocator, ") ");
        try writeReturnType(out, allocator, m.ret_src);
        try out.appendSlice(allocator, " {\n");

        // `        return self.vtable.<name>(self.ptr<, other_arg_names>);`
        try out.appendSlice(allocator, indent);
        try out.appendSlice(allocator, "        return self.vtable.");
        try out.appendSlice(allocator, m.name);
        try out.appendSlice(allocator, "(self.ptr");
        try writeOtherArgNames(out, allocator, m.params_src);
        try out.appendSlice(allocator, ");\n");

        try writeIndentedLine(allocator, out, indent, "    }");
    }

    // Auto-injected `from(impl)` factory: type-erases any `*T` whose `T`
    // declares each trait method into a fat pointer. The wrappers live on a
    // comptime-generated anonymous struct so the vtable-of-wrappers is
    // monomorphized once per `ImplT`.
    try writeIndentedLine(allocator, out, indent, "");
    try emitFromFactory(allocator, out, indent, trait_name, methods.items);

    // Trailing `};` on the same indentation as `trait`.
    try out.appendSlice(allocator, indent);
    try out.appendSlice(allocator, "};");
}

/// Emit the `pub fn from(impl_ptr: anytype) Name { ... }` factory. Generates
/// one `<m>_wrapper` per trait method that bounces a `*anyopaque` self-arg
/// back to `*ImplT` (via `@ptrCast` + `@alignCast`) and forwards the call.
/// The static `vt: VTable` initializer wires each wrapper into the vtable in
/// declaration order.
fn emitFromFactory(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    indent: []const u8,
    trait_name: []const u8,
    methods: anytype,
) !void {
    // Header.
    try out.appendSlice(allocator, indent);
    try out.appendSlice(allocator, "    pub fn from(impl_ptr: anytype) ");
    try out.appendSlice(allocator, trait_name);
    try out.appendSlice(allocator, " {\n");

    if (methods.len == 0) {
        // Empty trait: produce a minimal valid factory. No wrappers, an
        // empty vtable initializer, and `undefined` for the data ptr — the
        // factory is reachable only by code that explicitly calls it, and an
        // empty trait has no methods to dispatch through.
        try out.appendSlice(allocator, indent);
        try out.appendSlice(allocator, "        _ = impl_ptr;\n");
        try out.appendSlice(allocator, indent);
        try out.appendSlice(allocator, "        const gen = struct {\n");
        try out.appendSlice(allocator, indent);
        try out.appendSlice(allocator, "            const vt: VTable = .{};\n");
        try out.appendSlice(allocator, indent);
        try out.appendSlice(allocator, "        };\n");
        try out.appendSlice(allocator, indent);
        try out.appendSlice(allocator, "        return .{ .ptr = undefined, .vtable = &gen.vt };\n");
        try out.appendSlice(allocator, indent);
        try out.appendSlice(allocator, "    }\n");
        return;
    }

    // `ImplT` recovery. Lowercase `pointer` field on Zig 0.15.2 — the
    // round-trip `@ptrCast(@alignCast(self))` then casts back to `*ImplT`.
    try out.appendSlice(allocator, indent);
    try out.appendSlice(allocator, "        const ImplT = @typeInfo(@TypeOf(impl_ptr)).pointer.child;\n");
    try out.appendSlice(allocator, indent);
    try out.appendSlice(allocator, "        const gen = struct {\n");

    // Each method's wrapper.
    for (methods) |m| {
        try out.appendSlice(allocator, indent);
        try out.appendSlice(allocator, "            fn ");
        try out.appendSlice(allocator, m.name);
        try out.appendSlice(allocator, "_wrapper(self: *anyopaque");
        try writeOtherParamsVtable(out, allocator, m.params_src);
        try out.appendSlice(allocator, ") ");
        try writeReturnType(out, allocator, m.ret_src);
        try out.appendSlice(allocator, " {\n");
        try out.appendSlice(allocator, indent);
        try out.appendSlice(allocator, "                const t: *ImplT = @ptrCast(@alignCast(self));\n");
        try out.appendSlice(allocator, indent);
        try out.appendSlice(allocator, "                return t.");
        try out.appendSlice(allocator, m.name);
        try out.appendSlice(allocator, "(");
        try writeArgNamesNoLeadComma(out, allocator, m.params_src);
        try out.appendSlice(allocator, ");\n");
        try out.appendSlice(allocator, indent);
        try out.appendSlice(allocator, "            }\n");
    }

    // Static vt initializer.
    try out.appendSlice(allocator, indent);
    try out.appendSlice(allocator, "            const vt: VTable = .{ ");
    for (methods, 0..) |m, idx| {
        if (idx > 0) try out.appendSlice(allocator, ", ");
        try out.append(allocator, '.');
        try out.appendSlice(allocator, m.name);
        try out.appendSlice(allocator, " = ");
        try out.appendSlice(allocator, m.name);
        try out.appendSlice(allocator, "_wrapper");
    }
    try out.appendSlice(allocator, " };\n");

    try out.appendSlice(allocator, indent);
    try out.appendSlice(allocator, "        };\n");
    try out.appendSlice(allocator, indent);
    try out.appendSlice(allocator, "        return .{ .ptr = @ptrCast(impl_ptr), .vtable = &gen.vt };\n");
    try out.appendSlice(allocator, indent);
    try out.appendSlice(allocator, "    }\n");
}

/// Like `writeOtherArgNames` but without the leading `, `. Used inside
/// `t.<m>(<args>)` where there's no `self.ptr` first arg to comma-prefix.
fn writeArgNamesNoLeadComma(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    params_src: []const u8,
) !void {
    const rest = otherParamsSlice(params_src);
    if (rest.len == 0) return;

    var depth_paren: i32 = 0;
    var depth_brack: i32 = 0;
    var seg_start: usize = 0;
    var i: usize = 0;
    var first = true;
    while (i <= rest.len) : (i += 1) {
        const at_end = i == rest.len;
        const at_top_comma = !at_end and rest[i] == ',' and depth_paren == 0 and depth_brack == 0;
        if (at_end or at_top_comma) {
            const seg = std.mem.trim(u8, rest[seg_start..i], " \t\r\n");
            var dp: i32 = 0;
            var db: i32 = 0;
            var name_end: usize = seg.len;
            var sj: usize = 0;
            while (sj < seg.len) : (sj += 1) {
                const c = seg[sj];
                switch (c) {
                    '(' => dp += 1,
                    ')' => dp -= 1,
                    '[' => db += 1,
                    ']' => db -= 1,
                    ':' => {
                        if (dp == 0 and db == 0) {
                            name_end = sj;
                            break;
                        }
                    },
                    else => {},
                }
            }
            const name = std.mem.trim(u8, seg[0..name_end], " \t\r\n");
            if (name.len > 0) {
                if (!first) try out.appendSlice(allocator, ", ");
                try out.appendSlice(allocator, name);
                first = false;
            }
            seg_start = i + 1;
        }
        if (!at_end) {
            const c = rest[i];
            switch (c) {
                '(' => depth_paren += 1,
                ')' => depth_paren -= 1,
                '[' => depth_brack += 1,
                ']' => depth_brack -= 1,
                else => {},
            }
        }
    }
}

/// Append `<indent><body>\n`, with the special case that if `body` is empty
/// we still emit a bare `\n` (no indent on a blank line — matches the spec
/// example whose blank line between fields and VTable has no trailing space).
fn writeIndentedLine(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    indent: []const u8,
    body: []const u8,
) !void {
    if (body.len == 0) {
        try out.append(allocator, '\n');
        return;
    }
    try out.appendSlice(allocator, indent);
    try out.appendSlice(allocator, body);
    try out.append(allocator, '\n');
}

/// Translate the return type slice. If it begins with `!`, emit `anyerror!`
/// followed by the remainder; otherwise copy through unchanged.
fn writeReturnType(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    ret_src: []const u8,
) !void {
    if (ret_src.len > 0 and ret_src[0] == '!') {
        try out.appendSlice(allocator, "anyerror");
        try out.appendSlice(allocator, ret_src);
    } else {
        try out.appendSlice(allocator, ret_src);
    }
}

/// Slice off the first parameter (`self`) from `params_src`. Returns the
/// remainder, with the leading `,` and surrounding whitespace trimmed.
/// If there's only `self`, returns an empty slice.
fn otherParamsSlice(params_src: []const u8) []const u8 {
    // `params_src` is the trimmed contents inside `(...)`. The first param is
    // exactly the bare ident `self`. Find the comma that separates it from
    // the rest.
    if (params_src.len == 0) return params_src; // no params at all (unusual)
    // Find first comma OUTSIDE of any nested brackets/parens. For `self` the
    // first param has no nesting so a top-level scan is sufficient.
    var depth_paren: i32 = 0;
    var depth_brack: i32 = 0;
    var i: usize = 0;
    while (i < params_src.len) : (i += 1) {
        const c = params_src[i];
        switch (c) {
            '(' => depth_paren += 1,
            ')' => depth_paren -= 1,
            '[' => depth_brack += 1,
            ']' => depth_brack -= 1,
            ',' => {
                if (depth_paren == 0 and depth_brack == 0) {
                    return std.mem.trim(u8, params_src[i + 1 ..], " \t\r\n");
                }
            },
            else => {},
        }
    }
    // No comma found — only `self`.
    return "";
}

/// Write `, <other_params...>` to the vtable signature, with the first param
/// replaced by nothing (it's already `self: *anyopaque`). For each comma-
/// separated rest-param, copy its source slice verbatim.
fn writeOtherParamsVtable(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    params_src: []const u8,
) !void {
    const rest = otherParamsSlice(params_src);
    if (rest.len == 0) return;
    try out.appendSlice(allocator, ", ");
    try out.appendSlice(allocator, rest);
}

/// Write `, <other_params...>` to the wrapper signature. Identical to the
/// vtable form: each rest-param is `<name>: <type>` and we keep both pieces.
fn writeOtherParamsWrapper(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    params_src: []const u8,
) !void {
    const rest = otherParamsSlice(params_src);
    if (rest.len == 0) return;
    try out.appendSlice(allocator, ", ");
    try out.appendSlice(allocator, rest);
}

/// Write `, <name1>, <name2>, ...` for each other-param's binding name —
/// used at the wrapper's call site `self.vtable.<m>(self.ptr, name1, ...)`.
fn writeOtherArgNames(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    params_src: []const u8,
) !void {
    const rest = otherParamsSlice(params_src);
    if (rest.len == 0) return;

    // Split `rest` on top-level commas; each segment is `<name>: <type>`. We
    // grab `<name>` (everything before the first `:`), trimmed.
    var depth_paren: i32 = 0;
    var depth_brack: i32 = 0;
    var seg_start: usize = 0;
    var i: usize = 0;
    while (i <= rest.len) : (i += 1) {
        const at_end = i == rest.len;
        const at_top_comma = !at_end and rest[i] == ',' and depth_paren == 0 and depth_brack == 0;
        if (at_end or at_top_comma) {
            const seg = std.mem.trim(u8, rest[seg_start..i], " \t\r\n");
            // Find the colon outside nested brackets within `seg`.
            var dp: i32 = 0;
            var db: i32 = 0;
            var name_end: usize = seg.len;
            var sj: usize = 0;
            while (sj < seg.len) : (sj += 1) {
                const c = seg[sj];
                switch (c) {
                    '(' => dp += 1,
                    ')' => dp -= 1,
                    '[' => db += 1,
                    ']' => db -= 1,
                    ':' => {
                        if (dp == 0 and db == 0) {
                            name_end = sj;
                            break;
                        }
                    },
                    else => {},
                }
            }
            const name = std.mem.trim(u8, seg[0..name_end], " \t\r\n");
            if (name.len > 0) {
                try out.appendSlice(allocator, ", ");
                try out.appendSlice(allocator, name);
            }
            seg_start = i + 1;
        }
        if (!at_end) {
            const c = rest[i];
            switch (c) {
                '(' => depth_paren += 1,
                ')' => depth_paren -= 1,
                '[' => depth_brack += 1,
                ']' => depth_brack -= 1,
                else => {},
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "lowerTraits: empty source -> unchanged" {
    const out = try lowerTraits(testing.allocator, "");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("", out);
}

test "lowerTraits: no trait keyword -> byte-equal output" {
    const src =
        "const std = @import(\"std\");\n" ++
        "pub fn main() !void {\n" ++
        "    return;\n" ++
        "}\n";
    const out = try lowerTraits(testing.allocator, src);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(src, out);
}

test "lowerTraits: single-method trait canonical output" {
    const src = "trait W {\n    fn write(self, b: []const u8) !usize;\n}\n";
    const expected =
        "pub const W = struct {\n" ++
        "    ptr: *anyopaque,\n" ++
        "    vtable: *const VTable,\n" ++
        "\n" ++
        "    pub const VTable = struct {\n" ++
        "        write: *const fn (self: *anyopaque, b: []const u8) anyerror!usize,\n" ++
        "    };\n" ++
        "\n" ++
        "    pub fn write(self: W, b: []const u8) anyerror!usize {\n" ++
        "        return self.vtable.write(self.ptr, b);\n" ++
        "    }\n" ++
        "\n" ++
        "    pub fn from(impl_ptr: anytype) W {\n" ++
        "        const ImplT = @typeInfo(@TypeOf(impl_ptr)).pointer.child;\n" ++
        "        const gen = struct {\n" ++
        "            fn write_wrapper(self: *anyopaque, b: []const u8) anyerror!usize {\n" ++
        "                const t: *ImplT = @ptrCast(@alignCast(self));\n" ++
        "                return t.write(b);\n" ++
        "            }\n" ++
        "            const vt: VTable = .{ .write = write_wrapper };\n" ++
        "        };\n" ++
        "        return .{ .ptr = @ptrCast(impl_ptr), .vtable = &gen.vt };\n" ++
        "    }\n" ++
        "};\n";
    const out = try lowerTraits(testing.allocator, src);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(expected, out);
}

test "lowerTraits: empty trait body" {
    const src = "trait E {}\n";
    const out = try lowerTraits(testing.allocator, src);
    defer testing.allocator.free(out);
    // Empty trait still emits a minimal `from`. We don't pin the full body —
    // the goal is just that `pub fn from(` shows up so the API is uniform.
    try testing.expect(std.mem.indexOf(u8, out, "pub const E = struct {") != null);
    try testing.expect(std.mem.indexOf(u8, out, "pub fn from(impl_ptr: anytype) E") != null);
}

test "lowerTraits: two-method trait keeps declaration order" {
    const src =
        "trait Writer {\n" ++
        "    fn write(self, bytes: []const u8) !usize;\n" ++
        "    fn flush(self) !void;\n" ++
        "}\n";
    const expected =
        "pub const Writer = struct {\n" ++
        "    ptr: *anyopaque,\n" ++
        "    vtable: *const VTable,\n" ++
        "\n" ++
        "    pub const VTable = struct {\n" ++
        "        write: *const fn (self: *anyopaque, bytes: []const u8) anyerror!usize,\n" ++
        "        flush: *const fn (self: *anyopaque) anyerror!void,\n" ++
        "    };\n" ++
        "\n" ++
        "    pub fn write(self: Writer, bytes: []const u8) anyerror!usize {\n" ++
        "        return self.vtable.write(self.ptr, bytes);\n" ++
        "    }\n" ++
        "\n" ++
        "    pub fn flush(self: Writer) anyerror!void {\n" ++
        "        return self.vtable.flush(self.ptr);\n" ++
        "    }\n" ++
        "\n" ++
        "    pub fn from(impl_ptr: anytype) Writer {\n" ++
        "        const ImplT = @typeInfo(@TypeOf(impl_ptr)).pointer.child;\n" ++
        "        const gen = struct {\n" ++
        "            fn write_wrapper(self: *anyopaque, bytes: []const u8) anyerror!usize {\n" ++
        "                const t: *ImplT = @ptrCast(@alignCast(self));\n" ++
        "                return t.write(bytes);\n" ++
        "            }\n" ++
        "            fn flush_wrapper(self: *anyopaque) anyerror!void {\n" ++
        "                const t: *ImplT = @ptrCast(@alignCast(self));\n" ++
        "                return t.flush();\n" ++
        "            }\n" ++
        "            const vt: VTable = .{ .write = write_wrapper, .flush = flush_wrapper };\n" ++
        "        };\n" ++
        "        return .{ .ptr = @ptrCast(impl_ptr), .vtable = &gen.vt };\n" ++
        "    }\n" ++
        "};\n";
    const out = try lowerTraits(testing.allocator, src);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(expected, out);
}

test "lowerTraits: indented trait keeps 4-space prefix on every line" {
    const src =
        "    trait W {\n" ++
        "        fn write(self, b: []const u8) !usize;\n" ++
        "    }\n";
    const expected =
        "    pub const W = struct {\n" ++
        "        ptr: *anyopaque,\n" ++
        "        vtable: *const VTable,\n" ++
        "\n" ++
        "        pub const VTable = struct {\n" ++
        "            write: *const fn (self: *anyopaque, b: []const u8) anyerror!usize,\n" ++
        "        };\n" ++
        "\n" ++
        "        pub fn write(self: W, b: []const u8) anyerror!usize {\n" ++
        "            return self.vtable.write(self.ptr, b);\n" ++
        "        }\n" ++
        "\n" ++
        "        pub fn from(impl_ptr: anytype) W {\n" ++
        "            const ImplT = @typeInfo(@TypeOf(impl_ptr)).pointer.child;\n" ++
        "            const gen = struct {\n" ++
        "                fn write_wrapper(self: *anyopaque, b: []const u8) anyerror!usize {\n" ++
        "                    const t: *ImplT = @ptrCast(@alignCast(self));\n" ++
        "                    return t.write(b);\n" ++
        "                }\n" ++
        "                const vt: VTable = .{ .write = write_wrapper };\n" ++
        "            };\n" ++
        "            return .{ .ptr = @ptrCast(impl_ptr), .vtable = &gen.vt };\n" ++
        "        }\n" ++
        "    };\n";
    const out = try lowerTraits(testing.allocator, src);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(expected, out);
}

test "lowerTraits: self-only method has no extra args" {
    const src = "trait C {\n    fn close(self) void;\n}\n";
    const expected =
        "pub const C = struct {\n" ++
        "    ptr: *anyopaque,\n" ++
        "    vtable: *const VTable,\n" ++
        "\n" ++
        "    pub const VTable = struct {\n" ++
        "        close: *const fn (self: *anyopaque) void,\n" ++
        "    };\n" ++
        "\n" ++
        "    pub fn close(self: C) void {\n" ++
        "        return self.vtable.close(self.ptr);\n" ++
        "    }\n" ++
        "\n" ++
        "    pub fn from(impl_ptr: anytype) C {\n" ++
        "        const ImplT = @typeInfo(@TypeOf(impl_ptr)).pointer.child;\n" ++
        "        const gen = struct {\n" ++
        "            fn close_wrapper(self: *anyopaque) void {\n" ++
        "                const t: *ImplT = @ptrCast(@alignCast(self));\n" ++
        "                return t.close();\n" ++
        "            }\n" ++
        "            const vt: VTable = .{ .close = close_wrapper };\n" ++
        "        };\n" ++
        "        return .{ .ptr = @ptrCast(impl_ptr), .vtable = &gen.vt };\n" ++
        "    }\n" ++
        "};\n";
    const out = try lowerTraits(testing.allocator, src);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(expected, out);
}

test "lowerTraits: non-error return is copied unchanged" {
    const src = "trait N {\n    fn name(self) []const u8;\n}\n";
    const expected =
        "pub const N = struct {\n" ++
        "    ptr: *anyopaque,\n" ++
        "    vtable: *const VTable,\n" ++
        "\n" ++
        "    pub const VTable = struct {\n" ++
        "        name: *const fn (self: *anyopaque) []const u8,\n" ++
        "    };\n" ++
        "\n" ++
        "    pub fn name(self: N) []const u8 {\n" ++
        "        return self.vtable.name(self.ptr);\n" ++
        "    }\n" ++
        "\n" ++
        "    pub fn from(impl_ptr: anytype) N {\n" ++
        "        const ImplT = @typeInfo(@TypeOf(impl_ptr)).pointer.child;\n" ++
        "        const gen = struct {\n" ++
        "            fn name_wrapper(self: *anyopaque) []const u8 {\n" ++
        "                const t: *ImplT = @ptrCast(@alignCast(self));\n" ++
        "                return t.name();\n" ++
        "            }\n" ++
        "            const vt: VTable = .{ .name = name_wrapper };\n" ++
        "        };\n" ++
        "        return .{ .ptr = @ptrCast(impl_ptr), .vtable = &gen.vt };\n" ++
        "    }\n" ++
        "};\n";
    const out = try lowerTraits(testing.allocator, src);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(expected, out);
}

test "lowerTraits: surrounding code passes through" {
    const src =
        "const std = @import(\"std\");\n" ++
        "\n" ++
        "trait W {\n" ++
        "    fn write(self, b: []const u8) !usize;\n" ++
        "}\n" ++
        "\n" ++
        "pub fn main() !void {}\n";
    const expected =
        "const std = @import(\"std\");\n" ++
        "\n" ++
        "pub const W = struct {\n" ++
        "    ptr: *anyopaque,\n" ++
        "    vtable: *const VTable,\n" ++
        "\n" ++
        "    pub const VTable = struct {\n" ++
        "        write: *const fn (self: *anyopaque, b: []const u8) anyerror!usize,\n" ++
        "    };\n" ++
        "\n" ++
        "    pub fn write(self: W, b: []const u8) anyerror!usize {\n" ++
        "        return self.vtable.write(self.ptr, b);\n" ++
        "    }\n" ++
        "\n" ++
        "    pub fn from(impl_ptr: anytype) W {\n" ++
        "        const ImplT = @typeInfo(@TypeOf(impl_ptr)).pointer.child;\n" ++
        "        const gen = struct {\n" ++
        "            fn write_wrapper(self: *anyopaque, b: []const u8) anyerror!usize {\n" ++
        "                const t: *ImplT = @ptrCast(@alignCast(self));\n" ++
        "                return t.write(b);\n" ++
        "            }\n" ++
        "            const vt: VTable = .{ .write = write_wrapper };\n" ++
        "        };\n" ++
        "        return .{ .ptr = @ptrCast(impl_ptr), .vtable = &gen.vt };\n" ++
        "    }\n" ++
        "};\n" ++
        "\n" ++
        "pub fn main() !void {}\n";
    const out = try lowerTraits(testing.allocator, src);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(expected, out);
}

test "lowerTraits: extern interface lowers identically to trait" {
    const src =
        "extern interface AudioPlugin {\n" ++
        "    fn process(self, input: []const f32, output: []f32) void;\n" ++
        "    fn name(self) []const u8;\n" ++
        "}\n";
    const expected =
        "pub const AudioPlugin = struct {\n" ++
        "    ptr: *anyopaque,\n" ++
        "    vtable: *const VTable,\n" ++
        "\n" ++
        "    pub const VTable = struct {\n" ++
        "        process: *const fn (self: *anyopaque, input: []const f32, output: []f32) void,\n" ++
        "        name: *const fn (self: *anyopaque) []const u8,\n" ++
        "    };\n" ++
        "\n" ++
        "    pub fn process(self: AudioPlugin, input: []const f32, output: []f32) void {\n" ++
        "        return self.vtable.process(self.ptr, input, output);\n" ++
        "    }\n" ++
        "\n" ++
        "    pub fn name(self: AudioPlugin) []const u8 {\n" ++
        "        return self.vtable.name(self.ptr);\n" ++
        "    }\n" ++
        "\n" ++
        "    pub fn from(impl_ptr: anytype) AudioPlugin {\n" ++
        "        const ImplT = @typeInfo(@TypeOf(impl_ptr)).pointer.child;\n" ++
        "        const gen = struct {\n" ++
        "            fn process_wrapper(self: *anyopaque, input: []const f32, output: []f32) void {\n" ++
        "                const t: *ImplT = @ptrCast(@alignCast(self));\n" ++
        "                return t.process(input, output);\n" ++
        "            }\n" ++
        "            fn name_wrapper(self: *anyopaque) []const u8 {\n" ++
        "                const t: *ImplT = @ptrCast(@alignCast(self));\n" ++
        "                return t.name();\n" ++
        "            }\n" ++
        "            const vt: VTable = .{ .process = process_wrapper, .name = name_wrapper };\n" ++
        "        };\n" ++
        "        return .{ .ptr = @ptrCast(impl_ptr), .vtable = &gen.vt };\n" ++
        "    }\n" ++
        "};\n";
    const out = try lowerTraits(testing.allocator, src);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(expected, out);
}

test "lowerTraits: empty extern interface body" {
    const src = "extern interface E {}\n";
    const out = try lowerTraits(testing.allocator, src);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "pub const E = struct {") != null);
    try testing.expect(std.mem.indexOf(u8, out, "pub fn from(impl_ptr: anytype) E") != null);
    // Ensure the `extern` and `interface` keywords are gone from the output.
    try testing.expect(std.mem.indexOf(u8, out, "extern interface") == null);
}

test "lowerTraits: extern interface single self-only method" {
    const src = "extern interface I {\n    fn m(self) void;\n}\n";
    const expected =
        "pub const I = struct {\n" ++
        "    ptr: *anyopaque,\n" ++
        "    vtable: *const VTable,\n" ++
        "\n" ++
        "    pub const VTable = struct {\n" ++
        "        m: *const fn (self: *anyopaque) void,\n" ++
        "    };\n" ++
        "\n" ++
        "    pub fn m(self: I) void {\n" ++
        "        return self.vtable.m(self.ptr);\n" ++
        "    }\n" ++
        "\n" ++
        "    pub fn from(impl_ptr: anytype) I {\n" ++
        "        const ImplT = @typeInfo(@TypeOf(impl_ptr)).pointer.child;\n" ++
        "        const gen = struct {\n" ++
        "            fn m_wrapper(self: *anyopaque) void {\n" ++
        "                const t: *ImplT = @ptrCast(@alignCast(self));\n" ++
        "                return t.m();\n" ++
        "            }\n" ++
        "            const vt: VTable = .{ .m = m_wrapper };\n" ++
        "        };\n" ++
        "        return .{ .ptr = @ptrCast(impl_ptr), .vtable = &gen.vt };\n" ++
        "    }\n" ++
        "};\n";
    const out = try lowerTraits(testing.allocator, src);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(expected, out);
}

test "lowerTraits: trait + extern interface in declaration order; bare `interface` ident untouched" {
    // The bare `const interface = 1;` line uses `interface` as a value-level
    // identifier — the lowering must leave it alone (no `extern` precedes it).
    const src =
        "trait W {\n" ++
        "    fn write(self, b: []const u8) !usize;\n" ++
        "}\n" ++
        "\n" ++
        "const interface = 1;\n" ++
        "\n" ++
        "extern interface I {\n" ++
        "    fn m(self) void;\n" ++
        "}\n";
    const out = try lowerTraits(testing.allocator, src);
    defer testing.allocator.free(out);

    // Both blocks lowered.
    try testing.expect(std.mem.indexOf(u8, out, "pub const W = struct {") != null);
    try testing.expect(std.mem.indexOf(u8, out, "pub const I = struct {") != null);
    // Declaration order preserved: W appears before I.
    const w_idx = std.mem.indexOf(u8, out, "pub const W = struct {").?;
    const i_idx = std.mem.indexOf(u8, out, "pub const I = struct {").?;
    try testing.expect(w_idx < i_idx);
    // Bare `const interface = 1;` line preserved verbatim.
    try testing.expect(std.mem.indexOf(u8, out, "const interface = 1;") != null);
    // No leftover Zig++ surface keywords.
    try testing.expect(std.mem.indexOf(u8, out, "trait W") == null);
    try testing.expect(std.mem.indexOf(u8, out, "extern interface I") == null);
}
