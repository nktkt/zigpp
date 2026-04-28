//! Pure extraction of Zig++ surface declarations of interest for `zpp doc`.
//!
//! Walks the lexer token stream looking for four shapes:
//!   1. `trait <Name> { fn ... ; ... }`
//!   2. `extern interface <Name> { fn ... ; ... }`
//!   3. `effects(...)` annotations followed (optionally) by `[pub] fn <name>`
//!   4. `} derive(.{ ... });` postfix on a struct decl
//!
//! No I/O. No Markdown formatting. Just raw text slices into the source plus
//! short-lived heap-backed lists for the variable-length fields. The caller
//! frees everything via `freeExtracted`.

const std = @import("std");
const lexer = @import("lexer.zig");

pub const TraitMethod = struct {
    name: []const u8,
    params: []const u8,
    return_type: []const u8,
};

pub const TraitDecl = struct {
    name: []const u8,
    is_extern: bool,
    methods: []TraitMethod,
    line: u32,
};

pub const EffectsAnnotation = struct {
    effects: []const u8,
    fn_name: ?[]const u8,
    line: u32,
};

pub const DeriveDecl = struct {
    struct_name: ?[]const u8,
    traits: [][]const u8,
    line: u32,
};

pub const Extracted = struct {
    traits: []TraitDecl,
    effects: []EffectsAnnotation,
    derives: []DeriveDecl,
};

/// Tokenize `source` and pull out every trait/extern-interface/effects/derive
/// declaration. The string slices in the result point into `source` (raw text)
/// or into freshly-allocated buffers we own. Caller must invoke
/// `freeExtracted` with the same allocator to release the inner arrays.
pub fn extract(allocator: std.mem.Allocator, source: []const u8) !Extracted {
    const tokens = try lexer.tokenize(allocator, source);
    defer allocator.free(tokens);

    var traits = std.ArrayList(TraitDecl){};
    errdefer traits.deinit(allocator);
    var effects_list = std.ArrayList(EffectsAnnotation){};
    errdefer effects_list.deinit(allocator);
    var derives = std.ArrayList(DeriveDecl){};
    errdefer derives.deinit(allocator);

    var ti: usize = 0;
    while (ti < tokens.len) : (ti += 1) {
        const t = tokens[ti];
        switch (t.kind) {
            .kw_trait => {
                if (try parseTrait(allocator, source, tokens, ti, false)) |res| {
                    try traits.append(allocator, res.decl);
                    ti = res.advance_to;
                }
            },
            .kw_extern => {
                if (ti + 1 < tokens.len and tokens[ti + 1].kind == .kw_interface) {
                    if (try parseTrait(allocator, source, tokens, ti, true)) |res| {
                        try traits.append(allocator, res.decl);
                        ti = res.advance_to;
                    }
                }
            },
            .kw_effects => {
                if (try parseEffects(source, tokens, ti)) |res| {
                    try effects_list.append(allocator, res.ann);
                    ti = res.advance_to;
                }
            },
            .rbrace => {
                if (try parseDerive(allocator, source, tokens, ti)) |res| {
                    try derives.append(allocator, res.decl);
                    ti = res.advance_to;
                }
            },
            else => {},
        }
    }

    return .{
        .traits = try traits.toOwnedSlice(allocator),
        .effects = try effects_list.toOwnedSlice(allocator),
        .derives = try derives.toOwnedSlice(allocator),
    };
}

/// Release every heap allocation produced by `extract`. The raw-text string
/// slices live inside the original source buffer and are not freed here.
pub fn freeExtracted(allocator: std.mem.Allocator, e: Extracted) void {
    for (e.traits) |trait| allocator.free(trait.methods);
    allocator.free(e.traits);
    allocator.free(e.effects);
    for (e.derives) |d| allocator.free(d.traits);
    allocator.free(e.derives);
}

const TraitParseResult = struct {
    decl: TraitDecl,
    advance_to: usize, // index of the closing rbrace; outer loop's `+= 1` skips past it
};

fn parseTrait(
    allocator: std.mem.Allocator,
    source: []const u8,
    tokens: []const lexer.Token,
    start_ti: usize,
    is_extern: bool,
) !?TraitParseResult {
    var name_idx: usize = 0;
    var lbrace_idx: usize = 0;
    if (is_extern) {
        if (start_ti + 3 >= tokens.len) return null;
        if (tokens[start_ti + 1].kind != .kw_interface or
            tokens[start_ti + 2].kind != .ident or
            tokens[start_ti + 3].kind != .lbrace) return null;
        name_idx = start_ti + 2;
        lbrace_idx = start_ti + 3;
    } else {
        if (start_ti + 2 >= tokens.len) return null;
        if (tokens[start_ti + 1].kind != .ident or
            tokens[start_ti + 2].kind != .lbrace) return null;
        name_idx = start_ti + 1;
        lbrace_idx = start_ti + 2;
    }

    // Find matching rbrace.
    var depth: usize = 1;
    var end_ti: usize = lbrace_idx + 1;
    while (end_ti < tokens.len and depth > 0) : (end_ti += 1) {
        switch (tokens[end_ti].kind) {
            .lbrace => depth += 1,
            .rbrace => depth -= 1,
            .eof => return null,
            else => {},
        }
    }
    if (depth != 0) return null;
    const rbrace_ti = end_ti - 1;

    // Walk methods inside the body.
    var methods = std.ArrayList(TraitMethod){};
    errdefer methods.deinit(allocator);

    var i: usize = lbrace_idx + 1;
    while (i < rbrace_ti) {
        if (tokens[i].kind != .kw_fn) {
            i += 1;
            continue;
        }
        if (i + 2 >= rbrace_ti) break;
        const m_name = tokens[i + 1];
        const m_lparen = tokens[i + 2];
        if (m_name.kind != .ident or m_lparen.kind != .lparen) {
            i += 1;
            continue;
        }
        var pdepth: usize = 1;
        var j: usize = i + 3;
        while (j < rbrace_ti and pdepth > 0) : (j += 1) {
            switch (tokens[j].kind) {
                .lparen => pdepth += 1,
                .rparen => pdepth -= 1,
                else => {},
            }
        }
        if (pdepth != 0) break;
        const m_rparen = tokens[j - 1];

        var k: usize = j;
        while (k < rbrace_ti and tokens[k].kind != .semicolon) : (k += 1) {}
        if (k >= rbrace_ti) break;
        const m_semi = tokens[k];

        const params_raw = source[m_lparen.end..m_rparen.start];
        const ret_raw = source[m_rparen.end..m_semi.start];
        try methods.append(allocator, .{
            .name = source[m_name.start..m_name.end],
            .params = std.mem.trim(u8, params_raw, " \t\r\n"),
            .return_type = std.mem.trim(u8, ret_raw, " \t\r\n"),
        });

        i = k + 1;
    }

    const name_tok = tokens[name_idx];
    return .{
        .decl = .{
            .name = source[name_tok.start..name_tok.end],
            .is_extern = is_extern,
            .methods = try methods.toOwnedSlice(allocator),
            .line = tokens[start_ti].line,
        },
        .advance_to = rbrace_ti,
    };
}

const EffectsParseResult = struct {
    ann: EffectsAnnotation,
    advance_to: usize,
};

fn parseEffects(
    source: []const u8,
    tokens: []const lexer.Token,
    start_ti: usize,
) !?EffectsParseResult {
    if (start_ti + 1 >= tokens.len) return null;
    if (tokens[start_ti + 1].kind != .lparen) return null;
    const lparen = tokens[start_ti + 1];

    // Find matching rparen.
    var depth: usize = 1;
    var j: usize = start_ti + 2;
    while (j < tokens.len and depth > 0) : (j += 1) {
        switch (tokens[j].kind) {
            .lparen => depth += 1,
            .rparen => depth -= 1,
            .eof => return null,
            else => {},
        }
    }
    if (depth != 0) return null;
    const rparen = tokens[j - 1];

    const body_raw = source[lparen.end..rparen.start];
    const body = std.mem.trim(u8, body_raw, " \t\r\n");

    // Lookahead up to ~10 tokens past the rparen for `[pub] fn <name>`.
    var fn_name: ?[]const u8 = null;
    var look: usize = j;
    var seen: usize = 0;
    while (look < tokens.len and seen < 10) : ({
        look += 1;
        seen += 1;
    }) {
        const k = tokens[look].kind;
        if (k == .doc_comment or k == .module_doc_comment) continue;
        if (k == .kw_pub) continue;
        if (k == .kw_fn) {
            if (look + 1 < tokens.len and tokens[look + 1].kind == .ident) {
                const id = tokens[look + 1];
                fn_name = source[id.start..id.end];
            }
            break;
        }
        // Anything else: not a fn declaration.
        break;
    }

    return .{
        .ann = .{
            .effects = body,
            .fn_name = fn_name,
            .line = tokens[start_ti].line,
        },
        .advance_to = j - 1,
    };
}

const DeriveParseResult = struct {
    decl: DeriveDecl,
    advance_to: usize,
};

fn parseDerive(
    allocator: std.mem.Allocator,
    source: []const u8,
    tokens: []const lexer.Token,
    rbrace_ti: usize,
) !?DeriveParseResult {
    // Pattern: rbrace kw_derive lparen dot lbrace ident, ident, ... rbrace rparen semicolon
    if (rbrace_ti + 5 >= tokens.len) return null;
    if (tokens[rbrace_ti + 1].kind != .kw_derive) return null;
    if (tokens[rbrace_ti + 2].kind != .lparen) return null;
    if (tokens[rbrace_ti + 3].kind != .dot) return null;
    if (tokens[rbrace_ti + 4].kind != .lbrace) return null;

    var traits = std.ArrayList([]const u8){};
    errdefer traits.deinit(allocator);

    var cursor: usize = rbrace_ti + 5;
    while (cursor < tokens.len) {
        const tk = tokens[cursor].kind;
        if (tk == .rbrace) break;
        if (tk != .ident) return null;
        const t = tokens[cursor];
        try traits.append(allocator, source[t.start..t.end]);
        cursor += 1;
        if (cursor >= tokens.len) return null;
        if (tokens[cursor].kind == .rbrace) break;
        if (tokens[cursor].kind != .comma) return null;
        cursor += 1;
    }
    if (cursor >= tokens.len or tokens[cursor].kind != .rbrace) return null;
    const tuple_rbrace = cursor;
    if (tuple_rbrace + 2 >= tokens.len) return null;
    if (tokens[tuple_rbrace + 1].kind != .rparen) return null;
    if (tokens[tuple_rbrace + 2].kind != .semicolon) return null;
    const semi_ti = tuple_rbrace + 2;

    // Best-effort struct-name recovery: walk back from the struct's rbrace to
    // find its matching lbrace, then look for `kw_const|kw_var ident eq kw_struct`
    // immediately preceding it.
    var struct_name: ?[]const u8 = null;
    if (findMatchingLbrace(tokens, rbrace_ti)) |lbrace_ti| {
        struct_name = recoverStructName(source, tokens, lbrace_ti);
    }

    return .{
        .decl = .{
            .struct_name = struct_name,
            .traits = try traits.toOwnedSlice(allocator),
            .line = tokens[rbrace_ti + 1].line,
        },
        .advance_to = semi_ti,
    };
}

fn findMatchingLbrace(tokens: []const lexer.Token, rbrace_ti: usize) ?usize {
    var depth: usize = 1;
    var i: isize = @as(isize, @intCast(rbrace_ti)) - 1;
    while (i >= 0) : (i -= 1) {
        const k = tokens[@intCast(i)].kind;
        if (k == .rbrace) {
            depth += 1;
        } else if (k == .lbrace) {
            depth -= 1;
            if (depth == 0) return @intCast(i);
        }
    }
    return null;
}

/// Look immediately before the struct opener for `[const|var] <ident> = struct`
/// and return the ident text. Tolerant of intervening doc-comment tokens.
fn recoverStructName(
    source: []const u8,
    tokens: []const lexer.Token,
    lbrace_ti: usize,
) ?[]const u8 {
    // Walk backward collecting up to 4 significant tokens.
    var collected: [4]usize = undefined;
    var n: usize = 0;
    var i: isize = @as(isize, @intCast(lbrace_ti)) - 1;
    while (i >= 0 and n < collected.len) : (i -= 1) {
        const k = tokens[@intCast(i)].kind;
        if (k == .doc_comment or k == .module_doc_comment) continue;
        collected[n] = @intCast(i);
        n += 1;
    }
    // Need: kw_struct (collected[0]), eq (collected[1]), ident (collected[2]),
    // kw_const|kw_var (collected[3]).
    if (n < 4) return null;
    if (tokens[collected[0]].kind != .kw_struct) return null;
    if (tokens[collected[1]].kind != .eq) return null;
    if (tokens[collected[2]].kind != .ident) return null;
    const decl_kind = tokens[collected[3]].kind;
    if (decl_kind != .kw_const and decl_kind != .kw_var) return null;
    const id = tokens[collected[2]];
    return source[id.start..id.end];
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "extract: empty source produces empty Extracted" {
    const e = try extract(testing.allocator, "");
    defer freeExtracted(testing.allocator, e);
    try testing.expectEqual(@as(usize, 0), e.traits.len);
    try testing.expectEqual(@as(usize, 0), e.effects.len);
    try testing.expectEqual(@as(usize, 0), e.derives.len);
}

test "extract: bare trait with two methods" {
    const src =
        "trait Writer {\n" ++
        "    fn write(self, bytes: []const u8) !usize;\n" ++
        "    fn flush(self) !void;\n" ++
        "}\n";
    const e = try extract(testing.allocator, src);
    defer freeExtracted(testing.allocator, e);
    try testing.expectEqual(@as(usize, 1), e.traits.len);
    try testing.expectEqualStrings("Writer", e.traits[0].name);
    try testing.expect(!e.traits[0].is_extern);
    try testing.expectEqual(@as(usize, 2), e.traits[0].methods.len);
    try testing.expectEqualStrings("write", e.traits[0].methods[0].name);
    try testing.expectEqualStrings("flush", e.traits[0].methods[1].name);
}

test "extract: extern interface sets is_extern=true" {
    const src = "extern interface Plugin {\n    fn process(self) void;\n}\n";
    const e = try extract(testing.allocator, src);
    defer freeExtracted(testing.allocator, e);
    try testing.expectEqual(@as(usize, 1), e.traits.len);
    try testing.expectEqualStrings("Plugin", e.traits[0].name);
    try testing.expect(e.traits[0].is_extern);
    try testing.expectEqual(@as(usize, 1), e.traits[0].methods.len);
}

test "extract: effects annotation followed by pub fn captures fn_name" {
    const src =
        "effects(.noalloc, .noio)\n" ++
        "pub fn hashBytes(b: []const u8) u64 {\n" ++
        "    return 0;\n" ++
        "}\n";
    const e = try extract(testing.allocator, src);
    defer freeExtracted(testing.allocator, e);
    try testing.expectEqual(@as(usize, 1), e.effects.len);
    try testing.expectEqualStrings(".noalloc, .noio", e.effects[0].effects);
    try testing.expect(e.effects[0].fn_name != null);
    try testing.expectEqualStrings("hashBytes", e.effects[0].fn_name.?);
}

test "extract: effects with no following fn yields null fn_name" {
    const src = "effects(.io)\nconst x = 1;\n";
    const e = try extract(testing.allocator, src);
    defer freeExtracted(testing.allocator, e);
    try testing.expectEqual(@as(usize, 1), e.effects.len);
    try testing.expectEqualStrings(".io", e.effects[0].effects);
    try testing.expect(e.effects[0].fn_name == null);
}

test "extract: derive postfix recovers struct name and trait list" {
    const src =
        "const User = struct {\n" ++
        "    id: u32,\n" ++
        "} derive(.{ Hash, Json });\n";
    const e = try extract(testing.allocator, src);
    defer freeExtracted(testing.allocator, e);
    try testing.expectEqual(@as(usize, 1), e.derives.len);
    try testing.expect(e.derives[0].struct_name != null);
    try testing.expectEqualStrings("User", e.derives[0].struct_name.?);
    try testing.expectEqual(@as(usize, 2), e.derives[0].traits.len);
    try testing.expectEqualStrings("Hash", e.derives[0].traits[0]);
    try testing.expectEqualStrings("Json", e.derives[0].traits[1]);
}

test "extract: all four shapes coexist in one file" {
    const src =
        "trait Greeter {\n" ++
        "    fn greet(self) void;\n" ++
        "}\n" ++
        "\n" ++
        "extern interface Plugin {\n" ++
        "    fn run(self) void;\n" ++
        "}\n" ++
        "\n" ++
        "effects(.io)\n" ++
        "pub fn write(b: []const u8) !void {}\n" ++
        "\n" ++
        "const Item = struct {\n" ++
        "    n: u32,\n" ++
        "} derive(.{ Hash });\n";
    const e = try extract(testing.allocator, src);
    defer freeExtracted(testing.allocator, e);
    try testing.expectEqual(@as(usize, 2), e.traits.len);
    try testing.expectEqualStrings("Greeter", e.traits[0].name);
    try testing.expect(!e.traits[0].is_extern);
    try testing.expectEqualStrings("Plugin", e.traits[1].name);
    try testing.expect(e.traits[1].is_extern);
    try testing.expectEqual(@as(usize, 1), e.effects.len);
    try testing.expectEqualStrings("write", e.effects[0].fn_name.?);
    try testing.expectEqual(@as(usize, 1), e.derives.len);
    try testing.expectEqualStrings("Item", e.derives[0].struct_name.?);
}

test "extract: keywords inside string literals and // comments are ignored" {
    const src =
        "// trait Fake { fn x(self) void; }\n" ++
        "const note = \"trait Hidden { fn y(self) void; }\";\n" ++
        "// effects(.io)\n" ++
        "// derive(.{ X });\n";
    const e = try extract(testing.allocator, src);
    defer freeExtracted(testing.allocator, e);
    try testing.expectEqual(@as(usize, 0), e.traits.len);
    try testing.expectEqual(@as(usize, 0), e.effects.len);
    try testing.expectEqual(@as(usize, 0), e.derives.len);
}
