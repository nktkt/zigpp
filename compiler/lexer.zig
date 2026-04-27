//! Zig++ lexer. Converts UTF-8 `.zpp` source bytes into a flat token stream.
//!
//! The lexer recognizes the full Zig++-specific keyword set (`trait`, `impl`,
//! `dyn`, `using`, `own`, `move`, `effects`, `requires`, `ensures`,
//! `invariant`, `derive`, `where`) plus a representative subset of Zig
//! keywords sufficient for the parser skeleton. Unknown characters are
//! emitted as `invalid` tokens and the lexer always advances at least one
//! byte to guarantee progress.

const std = @import("std");

/// Kind tag for every lexical token produced by the lexer.
pub const TokenKind = enum {
    // keywords (Zig++)
    kw_trait,
    kw_impl,
    kw_dyn,
    kw_using,
    kw_own,
    kw_move,
    kw_effects,
    kw_requires,
    kw_ensures,
    kw_invariant,
    kw_derive,
    kw_where,
    // keywords (Zig subset)
    kw_const,
    kw_var,
    kw_fn,
    kw_pub,
    kw_return,
    kw_if,
    kw_else,
    kw_while,
    kw_for,
    kw_defer,
    kw_try,
    kw_error,
    kw_struct,
    kw_enum,
    kw_union,
    kw_comptime,
    kw_extern,
    kw_interface,
    kw_null,
    kw_true,
    kw_false,
    // literals
    ident,
    integer,
    string,
    char,
    // punctuation
    lparen,
    rparen,
    lbrace,
    rbrace,
    lbracket,
    rbracket,
    semicolon,
    comma,
    colon,
    dot,
    question,
    bang,
    eq,
    eq_eq,
    bang_eq,
    lt,
    lt_eq,
    gt,
    gt_eq,
    plus,
    minus,
    star,
    slash,
    amp,
    pipe,
    caret,
    fat_arrow,
    thin_arrow,
    dot_dot,
    dot_dot_dot,
    // misc
    doc_comment,
    module_doc_comment,
    eof,
    invalid,
};

/// A single lexed token. Lexeme text is recoverable as `source[start..end]`.
pub const Token = struct {
    kind: TokenKind,
    start: u32,
    end: u32,
    line: u32,
    col: u32,
};

const keyword_map = std.StaticStringMap(TokenKind).initComptime(.{
    // Zig++-specific
    .{ "trait", .kw_trait },
    .{ "impl", .kw_impl },
    .{ "dyn", .kw_dyn },
    .{ "using", .kw_using },
    .{ "own", .kw_own },
    .{ "move", .kw_move },
    .{ "effects", .kw_effects },
    .{ "requires", .kw_requires },
    .{ "ensures", .kw_ensures },
    .{ "invariant", .kw_invariant },
    .{ "derive", .kw_derive },
    .{ "where", .kw_where },
    // Zig subset
    .{ "const", .kw_const },
    .{ "var", .kw_var },
    .{ "fn", .kw_fn },
    .{ "pub", .kw_pub },
    .{ "return", .kw_return },
    .{ "if", .kw_if },
    .{ "else", .kw_else },
    .{ "while", .kw_while },
    .{ "for", .kw_for },
    .{ "defer", .kw_defer },
    .{ "try", .kw_try },
    .{ "error", .kw_error },
    .{ "struct", .kw_struct },
    .{ "enum", .kw_enum },
    .{ "union", .kw_union },
    .{ "comptime", .kw_comptime },
    .{ "extern", .kw_extern },
    .{ "interface", .kw_interface },
    .{ "null", .kw_null },
    .{ "true", .kw_true },
    .{ "false", .kw_false },
});

fn isIdentStart(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or c == '_';
}

fn isIdentCont(c: u8) bool {
    return isIdentStart(c) or (c >= '0' and c <= '9');
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

/// Streaming lexer over a borrowed UTF-8 source slice.
pub const Lexer = struct {
    source: []const u8,
    pos: u32,
    line: u32,
    col: u32,

    /// Construct a fresh lexer positioned at the start of `source`.
    pub fn init(source: []const u8) Lexer {
        return .{
            .source = source,
            .pos = 0,
            .line = 1,
            .col = 1,
        };
    }

    fn peek(self: *const Lexer, offset: u32) ?u8 {
        const idx = self.pos + offset;
        if (idx >= self.source.len) return null;
        return self.source[idx];
    }

    fn advance(self: *Lexer) u8 {
        const c = self.source[self.pos];
        self.pos += 1;
        if (c == '\n') {
            self.line += 1;
            self.col = 1;
        } else {
            self.col += 1;
        }
        return c;
    }

    fn skipWhitespace(self: *Lexer) void {
        while (self.pos < self.source.len) {
            const c = self.source[self.pos];
            switch (c) {
                ' ', '\t', '\r', '\n' => _ = self.advance(),
                else => return,
            }
        }
    }

    /// Skip whitespace and plain `//` line comments. Returns when positioned
    /// on a non-trivia byte or EOF, or when a doc-comment marker (`///` /
    /// `//!`) is encountered (those are caller-handled tokens).
    fn skipTrivia(self: *Lexer) void {
        while (true) {
            self.skipWhitespace();
            if (self.pos >= self.source.len) return;
            if (self.source[self.pos] != '/') return;
            if (self.peek(1) != @as(?u8, '/')) return;
            // It's a `//` something. If it's a doc-comment, stop.
            const third = self.peek(2);
            if (third == @as(?u8, '/') or third == @as(?u8, '!')) return;
            // Plain line comment: consume until end of line.
            while (self.pos < self.source.len and self.source[self.pos] != '\n') {
                _ = self.advance();
            }
        }
    }

    fn makeToken(
        self: *const Lexer,
        kind: TokenKind,
        start: u32,
        line: u32,
        col: u32,
    ) Token {
        return .{
            .kind = kind,
            .start = start,
            .end = self.pos,
            .line = line,
            .col = col,
        };
    }

    fn lexIdentOrKeyword(self: *Lexer, start: u32, line: u32, col: u32) Token {
        while (self.pos < self.source.len and isIdentCont(self.source[self.pos])) {
            _ = self.advance();
        }
        const text = self.source[start..self.pos];
        const kind: TokenKind = keyword_map.get(text) orelse .ident;
        return self.makeToken(kind, start, line, col);
    }

    fn lexInteger(self: *Lexer, start: u32, line: u32, col: u32) Token {
        while (self.pos < self.source.len) {
            const c = self.source[self.pos];
            if (isDigit(c) or c == '_') {
                _ = self.advance();
            } else break;
        }
        return self.makeToken(.integer, start, line, col);
    }

    fn lexString(self: *Lexer, start: u32, line: u32, col: u32) Token {
        // Opening `"` already consumed by caller.
        while (self.pos < self.source.len) {
            const c = self.source[self.pos];
            if (c == '\\') {
                _ = self.advance();
                if (self.pos >= self.source.len) break;
                const esc = self.source[self.pos];
                // Recognize \" \n \\ \t (raw lexeme, no interpretation).
                switch (esc) {
                    '"', 'n', '\\', 't' => _ = self.advance(),
                    else => _ = self.advance(),
                }
                continue;
            }
            if (c == '"') {
                _ = self.advance();
                return self.makeToken(.string, start, line, col);
            }
            if (c == '\n') {
                // Unterminated string on this line.
                return self.makeToken(.invalid, start, line, col);
            }
            _ = self.advance();
        }
        return self.makeToken(.invalid, start, line, col);
    }

    fn lexChar(self: *Lexer, start: u32, line: u32, col: u32) Token {
        // Opening `'` already consumed by caller.
        while (self.pos < self.source.len) {
            const c = self.source[self.pos];
            if (c == '\\') {
                _ = self.advance();
                if (self.pos >= self.source.len) break;
                const esc = self.source[self.pos];
                switch (esc) {
                    '\'', '\\' => _ = self.advance(),
                    else => _ = self.advance(),
                }
                continue;
            }
            if (c == '\'') {
                _ = self.advance();
                return self.makeToken(.char, start, line, col);
            }
            if (c == '\n') {
                return self.makeToken(.invalid, start, line, col);
            }
            _ = self.advance();
        }
        return self.makeToken(.invalid, start, line, col);
    }

    fn lexLineCommentDoc(self: *Lexer, start: u32, line: u32, col: u32, kind: TokenKind) Token {
        // Caller has consumed the `//` prefix; consume the third marker byte
        // and then the rest of the line.
        _ = self.advance();
        while (self.pos < self.source.len and self.source[self.pos] != '\n') {
            _ = self.advance();
        }
        return self.makeToken(kind, start, line, col);
    }

    /// Produce the next token. Always returns a token (`eof` once exhausted,
    /// `invalid` for unrecognized bytes); never blocks and always advances.
    pub fn next(self: *Lexer) Token {
        self.skipTrivia();
        const start = self.pos;
        const line = self.line;
        const col = self.col;

        if (self.pos >= self.source.len) {
            return .{
                .kind = .eof,
                .start = start,
                .end = start,
                .line = line,
                .col = col,
            };
        }

        const c = self.source[self.pos];

        // Identifiers / keywords.
        if (isIdentStart(c)) {
            _ = self.advance();
            return self.lexIdentOrKeyword(start, line, col);
        }

        // Integer literals.
        if (isDigit(c)) {
            _ = self.advance();
            return self.lexInteger(start, line, col);
        }

        // String literal.
        if (c == '"') {
            _ = self.advance();
            return self.lexString(start, line, col);
        }

        // Char literal.
        if (c == '\'') {
            _ = self.advance();
            return self.lexChar(start, line, col);
        }

        // Operators and punctuation. Two-char forms must be checked first.
        switch (c) {
            '(' => {
                _ = self.advance();
                return self.makeToken(.lparen, start, line, col);
            },
            ')' => {
                _ = self.advance();
                return self.makeToken(.rparen, start, line, col);
            },
            '{' => {
                _ = self.advance();
                return self.makeToken(.lbrace, start, line, col);
            },
            '}' => {
                _ = self.advance();
                return self.makeToken(.rbrace, start, line, col);
            },
            '[' => {
                _ = self.advance();
                return self.makeToken(.lbracket, start, line, col);
            },
            ']' => {
                _ = self.advance();
                return self.makeToken(.rbracket, start, line, col);
            },
            ';' => {
                _ = self.advance();
                return self.makeToken(.semicolon, start, line, col);
            },
            ',' => {
                _ = self.advance();
                return self.makeToken(.comma, start, line, col);
            },
            ':' => {
                _ = self.advance();
                return self.makeToken(.colon, start, line, col);
            },
            '?' => {
                _ = self.advance();
                return self.makeToken(.question, start, line, col);
            },
            '+' => {
                _ = self.advance();
                return self.makeToken(.plus, start, line, col);
            },
            '*' => {
                _ = self.advance();
                return self.makeToken(.star, start, line, col);
            },
            '&' => {
                _ = self.advance();
                return self.makeToken(.amp, start, line, col);
            },
            '|' => {
                _ = self.advance();
                return self.makeToken(.pipe, start, line, col);
            },
            '^' => {
                _ = self.advance();
                return self.makeToken(.caret, start, line, col);
            },
            '!' => {
                _ = self.advance();
                if (self.pos < self.source.len and self.source[self.pos] == '=') {
                    _ = self.advance();
                    return self.makeToken(.bang_eq, start, line, col);
                }
                return self.makeToken(.bang, start, line, col);
            },
            '=' => {
                _ = self.advance();
                if (self.pos < self.source.len) {
                    const n = self.source[self.pos];
                    if (n == '=') {
                        _ = self.advance();
                        return self.makeToken(.eq_eq, start, line, col);
                    }
                    if (n == '>') {
                        _ = self.advance();
                        return self.makeToken(.fat_arrow, start, line, col);
                    }
                }
                return self.makeToken(.eq, start, line, col);
            },
            '<' => {
                _ = self.advance();
                if (self.pos < self.source.len and self.source[self.pos] == '=') {
                    _ = self.advance();
                    return self.makeToken(.lt_eq, start, line, col);
                }
                return self.makeToken(.lt, start, line, col);
            },
            '>' => {
                _ = self.advance();
                if (self.pos < self.source.len and self.source[self.pos] == '=') {
                    _ = self.advance();
                    return self.makeToken(.gt_eq, start, line, col);
                }
                return self.makeToken(.gt, start, line, col);
            },
            '-' => {
                _ = self.advance();
                if (self.pos < self.source.len and self.source[self.pos] == '>') {
                    _ = self.advance();
                    return self.makeToken(.thin_arrow, start, line, col);
                }
                return self.makeToken(.minus, start, line, col);
            },
            '.' => {
                _ = self.advance();
                if (self.pos < self.source.len and self.source[self.pos] == '.') {
                    _ = self.advance();
                    if (self.pos < self.source.len and self.source[self.pos] == '.') {
                        _ = self.advance();
                        return self.makeToken(.dot_dot_dot, start, line, col);
                    }
                    return self.makeToken(.dot_dot, start, line, col);
                }
                return self.makeToken(.dot, start, line, col);
            },
            '/' => {
                // Doc-comment markers are surfaced; plain `//` was already
                // skipped by `skipTrivia`. So if we're sitting on `/`, it's
                // either a doc-comment or a division operator.
                if (self.peek(1) == @as(?u8, '/')) {
                    const third = self.peek(2);
                    if (third == @as(?u8, '/')) {
                        _ = self.advance(); // first '/'
                        _ = self.advance(); // second '/'
                        return self.lexLineCommentDoc(start, line, col, .doc_comment);
                    }
                    if (third == @as(?u8, '!')) {
                        _ = self.advance();
                        _ = self.advance();
                        return self.lexLineCommentDoc(start, line, col, .module_doc_comment);
                    }
                }
                _ = self.advance();
                return self.makeToken(.slash, start, line, col);
            },
            else => {
                // Unknown byte: emit invalid and advance one byte to ensure
                // progress.
                _ = self.advance();
                return self.makeToken(.invalid, start, line, col);
            },
        }
    }
};

/// Tokenize an entire source buffer, returning an owned slice of tokens
/// terminated by a single `eof` token. Caller owns the returned memory.
pub fn tokenize(allocator: std.mem.Allocator, source: []const u8) ![]Token {
    var list: std.ArrayListUnmanaged(Token) = .{};
    errdefer list.deinit(allocator);

    var lex = Lexer.init(source);
    while (true) {
        const tok = lex.next();
        try list.append(allocator, tok);
        if (tok.kind == .eof) break;
    }
    return list.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "empty source yields only eof" {
    var lex = Lexer.init("");
    const t = lex.next();
    try testing.expectEqual(TokenKind.eof, t.kind);
    try testing.expectEqual(@as(u32, 0), t.start);
    try testing.expectEqual(@as(u32, 0), t.end);
}

test "simple identifier" {
    const src = "foo";
    const toks = try tokenize(testing.allocator, src);
    defer testing.allocator.free(toks);
    try testing.expectEqual(@as(usize, 2), toks.len);
    try testing.expectEqual(TokenKind.ident, toks[0].kind);
    try testing.expectEqualStrings("foo", src[toks[0].start..toks[0].end]);
    try testing.expectEqual(TokenKind.eof, toks[1].kind);
}

test "Zig++-specific keywords are distinct token kinds" {
    const Pair = struct { text: []const u8, kind: TokenKind };
    const pairs = [_]Pair{
        .{ .text = "trait", .kind = .kw_trait },
        .{ .text = "impl", .kind = .kw_impl },
        .{ .text = "dyn", .kind = .kw_dyn },
        .{ .text = "using", .kind = .kw_using },
        .{ .text = "own", .kind = .kw_own },
        .{ .text = "move", .kind = .kw_move },
        .{ .text = "effects", .kind = .kw_effects },
        .{ .text = "requires", .kind = .kw_requires },
        .{ .text = "ensures", .kind = .kw_ensures },
        .{ .text = "invariant", .kind = .kw_invariant },
        .{ .text = "derive", .kind = .kw_derive },
        .{ .text = "where", .kind = .kw_where },
    };
    for (pairs) |p| {
        var lex = Lexer.init(p.text);
        const t = lex.next();
        try testing.expectEqual(p.kind, t.kind);
        const eof = lex.next();
        try testing.expectEqual(TokenKind.eof, eof.kind);
    }
}

test "two-char operators win over one-char" {
    var lex = Lexer.init("==");
    const t = lex.next();
    try testing.expectEqual(TokenKind.eq_eq, t.kind);
    try testing.expectEqual(@as(u32, 0), t.start);
    try testing.expectEqual(@as(u32, 2), t.end);
    try testing.expectEqual(TokenKind.eof, lex.next().kind);

    // Spot-check a few more multi-char forms.
    var lex2 = Lexer.init("!= <= >= => -> .. ...");
    try testing.expectEqual(TokenKind.bang_eq, lex2.next().kind);
    try testing.expectEqual(TokenKind.lt_eq, lex2.next().kind);
    try testing.expectEqual(TokenKind.gt_eq, lex2.next().kind);
    try testing.expectEqual(TokenKind.fat_arrow, lex2.next().kind);
    try testing.expectEqual(TokenKind.thin_arrow, lex2.next().kind);
    try testing.expectEqual(TokenKind.dot_dot, lex2.next().kind);
    try testing.expectEqual(TokenKind.dot_dot_dot, lex2.next().kind);
    try testing.expectEqual(TokenKind.eof, lex2.next().kind);
}

test "string literal preserves raw lexeme including escapes" {
    const src = "\"hello\\n\"";
    var lex = Lexer.init(src);
    const t = lex.next();
    try testing.expectEqual(TokenKind.string, t.kind);
    try testing.expectEqualStrings("\"hello\\n\"", src[t.start..t.end]);
    try testing.expectEqual(TokenKind.eof, lex.next().kind);
}

test "// line comment is skipped" {
    const src = "foo // a comment\nbar";
    const toks = try tokenize(testing.allocator, src);
    defer testing.allocator.free(toks);
    try testing.expectEqual(@as(usize, 3), toks.len);
    try testing.expectEqual(TokenKind.ident, toks[0].kind);
    try testing.expectEqualStrings("foo", src[toks[0].start..toks[0].end]);
    try testing.expectEqual(TokenKind.ident, toks[1].kind);
    try testing.expectEqualStrings("bar", src[toks[1].start..toks[1].end]);
    try testing.expectEqual(TokenKind.eof, toks[2].kind);
}

test "/// produces doc_comment token" {
    const src = "/// docs here\nfoo";
    const toks = try tokenize(testing.allocator, src);
    defer testing.allocator.free(toks);
    try testing.expectEqual(@as(usize, 3), toks.len);
    try testing.expectEqual(TokenKind.doc_comment, toks[0].kind);
    try testing.expectEqualStrings("/// docs here", src[toks[0].start..toks[0].end]);
    try testing.expectEqual(TokenKind.ident, toks[1].kind);
}

test "//! produces module_doc_comment token" {
    const src = "//! module docs\n";
    const toks = try tokenize(testing.allocator, src);
    defer testing.allocator.free(toks);
    try testing.expectEqual(@as(usize, 2), toks.len);
    try testing.expectEqual(TokenKind.module_doc_comment, toks[0].kind);
    try testing.expectEqualStrings("//! module docs", src[toks[0].start..toks[0].end]);
    try testing.expectEqual(TokenKind.eof, toks[1].kind);
}

test "line and column track across newline" {
    const src = "foo\nbar";
    var lex = Lexer.init(src);
    const t1 = lex.next();
    try testing.expectEqual(TokenKind.ident, t1.kind);
    try testing.expectEqual(@as(u32, 1), t1.line);
    try testing.expectEqual(@as(u32, 1), t1.col);

    const t2 = lex.next();
    try testing.expectEqual(TokenKind.ident, t2.kind);
    try testing.expectEqual(@as(u32, 2), t2.line);
    try testing.expectEqual(@as(u32, 1), t2.col);
}

test "small Zig++ snippet round-trips through tokenize" {
    const src = "fn foo() trait { return 1; }";
    const toks = try tokenize(testing.allocator, src);
    defer testing.allocator.free(toks);

    const expected = [_]TokenKind{
        .kw_fn,
        .ident,
        .lparen,
        .rparen,
        .kw_trait,
        .lbrace,
        .kw_return,
        .integer,
        .semicolon,
        .rbrace,
        .eof,
    };
    try testing.expectEqual(expected.len, toks.len);
    for (expected, toks) |exp, got| {
        try testing.expectEqual(exp, got.kind);
    }
    try testing.expectEqualStrings("foo", src[toks[1].start..toks[1].end]);
    try testing.expectEqualStrings("1", src[toks[7].start..toks[7].end]);
}
