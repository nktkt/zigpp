//! Lightweight token-based static checks.
//!
//! These checks operate directly on the lexer's token stream — they do not
//! depend on a parser or AST, which do not yet exist in this research
//! compiler. The intent is to provide a stub implementation of E0001
//! (owned-not-deinit) that catches the common shape of the violation while
//! leaving room for a real ownership pass in `sema.zig` later.

const std = @import("std");
const lexer = @import("lexer.zig");
const diag = @import("diagnostics.zig");

pub const Finding = struct {
    code: []const u8,
    message: []const u8,
    line: u32,
    col: u32,
};

const Token = lexer.Token;
const TokenKind = lexer.TokenKind;

/// Scan `source` for owned-not-deinit (E0001) violations.
///
/// Recognized shape:
///   `own var <ident> = <expr>;`
/// inside a function body. The check is satisfied if, before the enclosing
/// block closes, EITHER:
///   - `using <ident>` rebinds the value to a `using` binding, OR
///   - `<ident>.deinit(` is called explicitly.
///
/// The `own b: Buffer` parameter form is intentionally NOT a target of this
/// check (it isn't a `var` declaration); a separate pass will handle parameter
/// ownership.
///
/// Caller owns the returned slice. `Finding.code` and `Finding.message` are
/// pointers into static string literals — no per-element heap allocation.
pub fn checkOwnership(allocator: std.mem.Allocator, source: []const u8) ![]Finding {
    const tokens = try lexer.tokenize(allocator, source);
    defer allocator.free(tokens);

    var findings: std.ArrayListUnmanaged(Finding) = .{};
    errdefer findings.deinit(allocator);

    var i: usize = 0;
    while (i < tokens.len) : (i += 1) {
        const t = tokens[i];
        if (t.kind != .kw_own) continue;

        // Only match `own var <ident>` — `own const`, `own b: T` (param form),
        // and bare `own` references are out of scope for E0001.
        const next1_idx = nextNonTrivia(tokens, i + 1) orelse continue;
        if (tokens[next1_idx].kind != .kw_var) continue;

        const next2_idx = nextNonTrivia(tokens, next1_idx + 1) orelse continue;
        if (tokens[next2_idx].kind != .ident) continue;

        const name_tok = tokens[next2_idx];
        const name = source[name_tok.start..name_tok.end];

        // Locate the enclosing block: walk backward from the `own` token
        // tracking brace depth. The most recent unmatched `lbrace` is the
        // function body's opener (or any enclosing `{` — which is fine for
        // a stub: we treat the closest scope as the lifetime boundary).
        const block = enclosingBlock(tokens, i) orelse continue;

        if (!isHandled(tokens, source, name, block.open_idx, block.close_idx)) {
            try findings.append(allocator, .{
                .code = diag.Code.owned_not_deinit,
                .message = "owned value was not deinitialized",
                .line = t.line,
                .col = t.col,
            });
        }

        // Advance past the matched ident; the body scan does not need to
        // re-examine these tokens for further `own var` shapes.
        i = next2_idx;
    }

    return findings.toOwnedSlice(allocator);
}

/// Returns the index of the next token that is not a doc comment / module doc
/// comment (the lexer surfaces these inline with code tokens; we ignore them
/// when matching the `own var <ident>` shape).
fn nextNonTrivia(tokens: []const Token, start: usize) ?usize {
    var j = start;
    while (j < tokens.len) : (j += 1) {
        const k = tokens[j].kind;
        if (k == .doc_comment or k == .module_doc_comment) continue;
        if (k == .eof) return null;
        return j;
    }
    return null;
}

const BlockSpan = struct {
    open_idx: usize,
    close_idx: usize,
};

/// Find the innermost `{ ... }` enclosing `pos`. Walks backward to locate the
/// most recent unmatched `lbrace`, then forward from there to find its match.
fn enclosingBlock(tokens: []const Token, pos: usize) ?BlockSpan {
    var depth: i32 = 0;
    var open_idx: ?usize = null;
    var k: usize = pos;
    while (true) {
        if (k == 0) break;
        k -= 1;
        switch (tokens[k].kind) {
            .rbrace => depth += 1,
            .lbrace => {
                if (depth == 0) {
                    open_idx = k;
                    break;
                }
                depth -= 1;
            },
            else => {},
        }
    }
    const open = open_idx orelse return null;

    var fdepth: i32 = 0;
    var m: usize = open;
    while (m < tokens.len) : (m += 1) {
        switch (tokens[m].kind) {
            .lbrace => fdepth += 1,
            .rbrace => {
                fdepth -= 1;
                if (fdepth == 0) return .{ .open_idx = open, .close_idx = m };
            },
            else => {},
        }
    }
    return null;
}

/// Returns true if some token in `(open, close)` either (a) `using <name>`
/// rebinds the value or (b) `<name>.deinit(` calls deinit explicitly.
fn isHandled(
    tokens: []const Token,
    source: []const u8,
    name: []const u8,
    open: usize,
    close: usize,
) bool {
    var j = open + 1;
    while (j < close) : (j += 1) {
        const t = tokens[j];

        // Pattern: `using <name>`
        if (t.kind == .kw_using) {
            const id_idx = nextNonTrivia(tokens, j + 1) orelse continue;
            if (id_idx >= close) continue;
            const id_tok = tokens[id_idx];
            if (id_tok.kind == .ident and
                std.mem.eql(u8, source[id_tok.start..id_tok.end], name))
            {
                return true;
            }
            continue;
        }

        // Pattern: `move <name>` — ownership transfer satisfies the deinit
        // obligation; the moved-from binding is dead, so the new owner (or a
        // function that consumed `move x`) is responsible from here on.
        if (t.kind == .kw_move) {
            const id_idx = nextNonTrivia(tokens, j + 1) orelse continue;
            if (id_idx >= close) continue;
            const id_tok = tokens[id_idx];
            if (id_tok.kind == .ident and
                std.mem.eql(u8, source[id_tok.start..id_tok.end], name))
            {
                return true;
            }
            continue;
        }

        // Pattern: `<name> . deinit (`
        if (t.kind == .ident and
            std.mem.eql(u8, source[t.start..t.end], name))
        {
            const dot_idx = nextNonTrivia(tokens, j + 1) orelse continue;
            if (dot_idx >= close) continue;
            if (tokens[dot_idx].kind != .dot) continue;

            const m_idx = nextNonTrivia(tokens, dot_idx + 1) orelse continue;
            if (m_idx >= close) continue;
            const m_tok = tokens[m_idx];
            if (m_tok.kind != .ident) continue;
            if (!std.mem.eql(u8, source[m_tok.start..m_tok.end], "deinit")) continue;

            const lp_idx = nextNonTrivia(tokens, m_idx + 1) orelse continue;
            if (lp_idx >= close) continue;
            if (tokens[lp_idx].kind == .lparen) return true;
        }
    }
    return false;
}

/// Scan `source` for use-after-move (E0002) violations.
///
/// Recognized shape:
///   `move <ident>` at any position in the token stream. The identifier
///   following `move` is treated as the moved binding; any later occurrence
///   of that identifier within the same enclosing block (after the `move`
///   site) is reported as a use-after-move.
///
/// One finding is produced per moved-name per enclosing block, anchored at
/// the FIRST post-move use site (not the move site) so the diagnostic points
/// at the bug rather than the cause. This matches the spec's "one finding per
/// moved variable" simplification — if the same name is moved again later,
/// we don't try to disambiguate (rebinding is out of scope; see below).
///
/// Known limitations:
///   - Rebinding (`x = ...;` after the move) is NOT recognized as restoring
///     the binding. Subsequent uses of `x` are still flagged.
///   - Only the innermost lexical block is considered; uses in nested inner
///     blocks are flagged (correct), but uses in outer enclosing scopes are
///     not (out of scope for this token-only stub).
///
/// Caller owns the returned slice. `Finding.code` and `Finding.message` are
/// pointers into static string literals — no per-element heap allocation.
pub fn checkUseAfterMove(allocator: std.mem.Allocator, source: []const u8) ![]Finding {
    const tokens = try lexer.tokenize(allocator, source);
    defer allocator.free(tokens);

    var findings: std.ArrayListUnmanaged(Finding) = .{};
    errdefer findings.deinit(allocator);

    var i: usize = 0;
    while (i < tokens.len) : (i += 1) {
        if (tokens[i].kind != .kw_move) continue;

        // The token immediately after `move` (skipping doc-comment trivia)
        // names the source binding. That ident is the move SOURCE, not a
        // post-move use, so the forward scan must start strictly after it.
        const name_idx = nextNonTrivia(tokens, i + 1) orelse continue;
        if (tokens[name_idx].kind != .ident) continue;

        const name_tok = tokens[name_idx];
        const name = source[name_tok.start..name_tok.end];

        const block = enclosingBlock(tokens, i) orelse continue;

        // Scan (name_idx, close_idx) for any ident with the same text. Only
        // emit the FIRST such use — subsequent uses are redundant findings
        // for the same root cause.
        var j: usize = name_idx + 1;
        while (j < block.close_idx) : (j += 1) {
            const t = tokens[j];
            if (t.kind != .ident) continue;
            if (!std.mem.eql(u8, source[t.start..t.end], name)) continue;
            try findings.append(allocator, .{
                .code = diag.Code.owned_used_after_move,
                .message = "owned value used after move",
                .line = t.line,
                .col = t.col,
            });
            break;
        }

        // Advance past the move-source ident so we don't re-process it as a
        // standalone token if it appears in a chained pattern.
        i = name_idx;
    }

    return findings.toOwnedSlice(allocator);
}

/// Scan `source` for hidden allocations (E0010) inside functions tagged with
/// `effects(.noalloc, ...)`.
///
/// Recognized shape (token-only stub — no parser/sema involved):
///   `effects ( ... .noalloc ... ) <pub>? fn <name> ( <params> ) <ret>? { <body> }`
///
/// Inside the body of such a function, any of the following is reported as
/// `E0010`:
///   - `<allocator-param>.alloc(`, `.allocSentinel(`, `.allocAdvanced(`,
///     `.create(`, `.dupe(`, `.dupeZ(`, `.realloc(`, `.reallocAdvanced(`,
///     `.allocPrint(`, `.allocPrintZ(`. (`free` is intentionally NOT flagged.)
///   - A call expression `<callee>(... <allocator-param> ...)` that passes one
///     of the recorded Allocator-typed parameter names through to another
///     function (a likely-allocating pass-through).
///
/// The Allocator-typed parameter is detected by inspecting tokens that follow
/// the `:` of each parameter: if any of the next ~4 non-trivia tokens form a
/// sequence ending in an `ident` whose text is `"Allocator"` (catching
/// `Allocator`, `std.mem.Allocator`, `*std.mem.Allocator`, etc.), the param's
/// name is recorded. This is a deliberately loose heuristic — the test
/// fixtures and typical idioms are covered, but obscure shapes (renamed
/// imports, type aliases) will be missed.
///
/// Known false-positive class: a call like `f(allocator)` is flagged even if
/// `f` does not actually allocate (we cannot tell from a token stream alone).
/// The accompanying conformance fixtures avoid this by not naming an
/// Allocator-typed parameter at all when one isn't needed.
///
/// The heap-allocator-constructor heuristic (`std.heap.page_allocator(...)`,
/// etc.) is intentionally NOT included: those constructors take no arguments
/// in their typical use, and including them adds bookkeeping for no benefit on
/// the in-scope fixtures.
///
/// Caller owns the returned slice. `Finding.code` and `Finding.message` point
/// into static string literals — no per-element heap allocation.
pub fn checkNoAlloc(allocator: std.mem.Allocator, source: []const u8) ![]Finding {
    const tokens = try lexer.tokenize(allocator, source);
    defer allocator.free(tokens);

    var findings: std.ArrayListUnmanaged(Finding) = .{};
    errdefer findings.deinit(allocator);

    var i: usize = 0;
    while (i < tokens.len) : (i += 1) {
        if (tokens[i].kind != .kw_effects) continue;

        // `effects` must be followed by `(` ... `)`.
        const lp_idx = nextNonTrivia(tokens, i + 1) orelse continue;
        if (tokens[lp_idx].kind != .lparen) continue;
        const rp_idx = matchParen(tokens, lp_idx) orelse continue;

        // The `effects(...)` arg list must contain `.noalloc` for this clause
        // to gate the noalloc check.
        if (!effectsContainsNoalloc(tokens, source, lp_idx, rp_idx)) {
            i = rp_idx;
            continue;
        }

        // Optional `pub` then required `fn` then required `ident` (the
        // function name). Any other shape means this `effects(...)` does not
        // attach to a function declaration we can analyze.
        var head_idx = nextNonTrivia(tokens, rp_idx + 1) orelse continue;
        if (tokens[head_idx].kind == .kw_pub) {
            head_idx = nextNonTrivia(tokens, head_idx + 1) orelse continue;
        }
        if (tokens[head_idx].kind != .kw_fn) continue;
        const name_idx = nextNonTrivia(tokens, head_idx + 1) orelse continue;
        if (tokens[name_idx].kind != .ident) continue;

        // Param list: the `(` ... `)` immediately following the function name.
        const params_lp = nextNonTrivia(tokens, name_idx + 1) orelse continue;
        if (tokens[params_lp].kind != .lparen) continue;
        const params_rp = matchParen(tokens, params_lp) orelse continue;

        // Collect Allocator-typed parameter names. The `param_buf` array is
        // sized for typical fixtures (a function rarely takes more than a
        // handful of allocator params); excess names are silently dropped.
        var param_buf: [8][]const u8 = undefined;
        var param_count: usize = 0;
        collectAllocatorParams(tokens, source, params_lp, params_rp, &param_buf, &param_count);

        // Body: scan from the closing `)` of the param list forward to the
        // first `{`, then forward-depth match the matching `}`. The return
        // type tokens between `)` and `{` are skipped over.
        const body_open = findNext(tokens, params_rp + 1, .lbrace) orelse continue;
        const body_close = matchBrace(tokens, body_open) orelse continue;

        try scanBodyForAllocs(
            allocator,
            &findings,
            tokens,
            source,
            body_open,
            body_close,
            param_buf[0..param_count],
        );

        // Resume after this function's body. There may be another effects()
        // clause later in the file.
        i = body_close;
    }

    return findings.toOwnedSlice(allocator);
}

/// Forward-match the `(` at `lp_idx` to its corresponding `)`. Returns the
/// index of that `)`, or null on mismatch.
fn matchParen(tokens: []const Token, lp_idx: usize) ?usize {
    var depth: i32 = 0;
    var k: usize = lp_idx;
    while (k < tokens.len) : (k += 1) {
        switch (tokens[k].kind) {
            .lparen => depth += 1,
            .rparen => {
                depth -= 1;
                if (depth == 0) return k;
            },
            else => {},
        }
    }
    return null;
}

/// Forward-match the `{` at `lb_idx` to its corresponding `}`.
fn matchBrace(tokens: []const Token, lb_idx: usize) ?usize {
    var depth: i32 = 0;
    var k: usize = lb_idx;
    while (k < tokens.len) : (k += 1) {
        switch (tokens[k].kind) {
            .lbrace => depth += 1,
            .rbrace => {
                depth -= 1;
                if (depth == 0) return k;
            },
            else => {},
        }
    }
    return null;
}

/// Find the first occurrence of `kind` at or after `from`.
fn findNext(tokens: []const Token, from: usize, kind: TokenKind) ?usize {
    var k: usize = from;
    while (k < tokens.len) : (k += 1) {
        if (tokens[k].kind == kind) return k;
        if (tokens[k].kind == .eof) return null;
    }
    return null;
}

/// True iff the arg list bounded by `(lp, rp)` contains a `.noalloc` token
/// pair (i.e., a `dot` immediately followed by an ident whose text is exactly
/// "noalloc").
fn effectsContainsNoalloc(
    tokens: []const Token,
    source: []const u8,
    lp: usize,
    rp: usize,
) bool {
    var j: usize = lp + 1;
    while (j + 1 < rp) : (j += 1) {
        if (tokens[j].kind != .dot) continue;
        const id = nextNonTrivia(tokens, j + 1) orelse continue;
        if (id >= rp) continue;
        if (tokens[id].kind != .ident) continue;
        if (std.mem.eql(u8, source[tokens[id].start..tokens[id].end], "noalloc")) return true;
    }
    return false;
}

/// Walk `(lp, rp)` as a comma-separated list of `<name>: <type>` pairs.
/// Records each `<name>` whose `<type>` reaches an ident equal to "Allocator"
/// within ~4 non-trivia tokens after the `:`. Silently drops past the buffer
/// capacity.
fn collectAllocatorParams(
    tokens: []const Token,
    source: []const u8,
    lp: usize,
    rp: usize,
    out_buf: *[8][]const u8,
    out_len: *usize,
) void {
    var j: usize = lp + 1;
    // Each pass tries to identify one parameter starting at `j`.
    while (j < rp) {
        // Skip forward to the next ident at depth 0 (the param name).
        while (j < rp) : (j += 1) {
            const k = tokens[j].kind;
            if (k == .ident) break;
            if (k == .comma) {} else {}
        }
        if (j >= rp) break;
        const name_tok = tokens[j];
        // Expect `:` next.
        const colon_idx = nextNonTrivia(tokens, j + 1) orelse return;
        if (colon_idx >= rp) return;
        if (tokens[colon_idx].kind != .colon) {
            // Malformed param shape; advance to next comma at depth 0.
            j = advanceToNextParam(tokens, colon_idx, rp);
            continue;
        }

        // Look ahead up to 4 non-trivia tokens for an ident "Allocator". We
        // tolerate intervening `*`, `?`, `dot`, and `ident` (for
        // `std.mem.Allocator` or `*Allocator`).
        var look = colon_idx + 1;
        var hops: usize = 0;
        var matched = false;
        while (look < rp and hops < 6) : (hops += 1) {
            const t = tokens[look];
            if (t.kind == .doc_comment or t.kind == .module_doc_comment) {
                look += 1;
                continue;
            }
            if (t.kind == .ident and
                std.mem.eql(u8, source[t.start..t.end], "Allocator"))
            {
                matched = true;
                break;
            }
            // Stop at structural boundary that ends the type.
            if (t.kind == .comma or t.kind == .rparen) break;
            look += 1;
        }

        if (matched and out_len.* < out_buf.len) {
            out_buf[out_len.*] = source[name_tok.start..name_tok.end];
            out_len.* += 1;
        }

        j = advanceToNextParam(tokens, look, rp);
    }
}

/// Advance from `from` to one past the next `,` at depth 0 within `(.., rp)`,
/// or to `rp` if no such comma exists.
fn advanceToNextParam(tokens: []const Token, from: usize, rp: usize) usize {
    var depth: i32 = 0;
    var k: usize = from;
    while (k < rp) : (k += 1) {
        const kind = tokens[k].kind;
        if (kind == .lparen or kind == .lbracket or kind == .lbrace) depth += 1;
        if (kind == .rparen or kind == .rbracket or kind == .rbrace) depth -= 1;
        if (kind == .comma and depth == 0) return k + 1;
    }
    return rp;
}

/// Scan body tokens in `(open, close)` for allocation indicators relative to
/// the recorded Allocator-typed parameter names. Appends one finding per
/// suspect site.
fn scanBodyForAllocs(
    allocator: std.mem.Allocator,
    findings: *std.ArrayListUnmanaged(Finding),
    tokens: []const Token,
    source: []const u8,
    open: usize,
    close: usize,
    param_names: []const []const u8,
) !void {
    if (param_names.len == 0) return;

    var j: usize = open + 1;
    while (j < close) : (j += 1) {
        const t = tokens[j];
        if (t.kind != .ident) continue;
        const text = source[t.start..t.end];
        const is_alloc_param = identInList(text, param_names);

        // Pattern A: `<alloc>.<method>(` — direct allocator method call.
        if (is_alloc_param) {
            const dot_idx = nextNonTrivia(tokens, j + 1) orelse continue;
            if (dot_idx < close and tokens[dot_idx].kind == .dot) {
                const m_idx = nextNonTrivia(tokens, dot_idx + 1) orelse continue;
                if (m_idx >= close) continue;
                if (tokens[m_idx].kind != .ident) continue;
                const lp_idx = nextNonTrivia(tokens, m_idx + 1) orelse continue;
                if (lp_idx >= close) continue;
                if (tokens[lp_idx].kind != .lparen) continue;
                const method = source[tokens[m_idx].start..tokens[m_idx].end];
                if (isAllocMethod(method)) {
                    try findings.append(allocator, .{
                        .code = diag.Code.hidden_alloc_in_noalloc,
                        .message = "hidden allocation in noalloc function",
                        .line = t.line,
                        .col = t.col,
                    });
                    j = lp_idx;
                    continue;
                }
            }
        }

        // Pattern B: `<callee>(... <alloc-param> ...)` — pass-through. Detect
        // by an `ident` immediately followed by `(`. The callee may be a
        // chain like `std.mem.foo(...)`, but we anchor on any ident-then-lparen
        // shape that isn't itself the allocator method case handled above.
        const lp_after = nextNonTrivia(tokens, j + 1) orelse continue;
        if (lp_after >= close) continue;
        if (tokens[lp_after].kind != .lparen) continue;
        // Skip the case where `j` is itself one of the allocator params
        // followed by `(` — that's `allocator(...)` which isn't a real
        // pass-through pattern and is unlikely.
        if (is_alloc_param) continue;
        const lp_close = matchParen(tokens, lp_after) orelse continue;
        if (lp_close > close) continue;
        // Scan the call's args for any allocator-param ident.
        var k: usize = lp_after + 1;
        var flagged = false;
        while (k < lp_close) : (k += 1) {
            const at = tokens[k];
            if (at.kind != .ident) continue;
            if (identInList(source[at.start..at.end], param_names)) {
                try findings.append(allocator, .{
                    .code = diag.Code.hidden_alloc_in_noalloc,
                    .message = "hidden allocation in noalloc function",
                    .line = at.line,
                    .col = at.col,
                });
                flagged = true;
                break;
            }
        }
        if (flagged) {
            j = lp_close;
        }
    }
}

fn identInList(name: []const u8, list: []const []const u8) bool {
    for (list) |n| {
        if (std.mem.eql(u8, n, name)) return true;
    }
    return false;
}

fn isAllocMethod(name: []const u8) bool {
    const methods = [_][]const u8{
        "alloc",
        "allocSentinel",
        "allocAdvanced",
        "create",
        "dupe",
        "dupeZ",
        "realloc",
        "reallocAdvanced",
        "allocPrint",
        "allocPrintZ",
    };
    for (methods) |m| {
        if (std.mem.eql(u8, m, name)) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "exact E0001 fixture produces one finding" {
    const src =
        \\//! expect-error: E0001 owned value was not deinitialized
        \\const std = @import("std");
        \\
        \\pub fn leaky(allocator: std.mem.Allocator) !void {
        \\    own var x = try allocator.create(u32);
        \\    x.* = 42;
        \\    // falls off scope without `using` or explicit deinit -> E0001
        \\}
    ;
    const findings = try checkOwnership(testing.allocator, src);
    defer testing.allocator.free(findings);
    try testing.expectEqual(@as(usize, 1), findings.len);
    try testing.expectEqualStrings("E0001", findings[0].code);
    try testing.expectEqualStrings("owned value was not deinitialized", findings[0].message);
}

test "explicit .deinit() satisfies the check" {
    const src =
        \\pub fn ok(a: A) !void {
        \\    own var x = try a.create(u32);
        \\    x.deinit();
        \\}
    ;
    const findings = try checkOwnership(testing.allocator, src);
    defer testing.allocator.free(findings);
    try testing.expectEqual(@as(usize, 0), findings.len);
}

test "using rebinding satisfies the check" {
    const src =
        \\pub fn ok(a: A) !void {
        \\    own var x = try a.create(u32);
        \\    using x = x;
        \\}
    ;
    const findings = try checkOwnership(testing.allocator, src);
    defer testing.allocator.free(findings);
    try testing.expectEqual(@as(usize, 0), findings.len);
}

test "two unhandled own vars produce two findings" {
    const src =
        \\pub fn leaky(a: A) !void {
        \\    own var x = try a.create(u32);
        \\    own var y = try a.create(u32);
        \\    x.* = 1;
        \\    y.* = 2;
        \\}
    ;
    const findings = try checkOwnership(testing.allocator, src);
    defer testing.allocator.free(findings);
    try testing.expectEqual(@as(usize, 2), findings.len);
    try testing.expectEqualStrings("E0001", findings[0].code);
    try testing.expectEqualStrings("E0001", findings[1].code);
}

test "own b: Buffer parameter form is not flagged" {
    const src =
        \\pub fn consume(own b: Buffer) !void {
        \\    _ = b;
        \\}
    ;
    const findings = try checkOwnership(testing.allocator, src);
    defer testing.allocator.free(findings);
    try testing.expectEqual(@as(usize, 0), findings.len);
}

test "own var with intervening write then deinit is fine" {
    const src =
        \\pub fn ok(a: A) !void {
        \\    own var x = try a.create(u32);
        \\    x.* = 1;
        \\    x.deinit();
        \\}
    ;
    const findings = try checkOwnership(testing.allocator, src);
    defer testing.allocator.free(findings);
    try testing.expectEqual(@as(usize, 0), findings.len);
}

test "E0002 fixture text produces a use-after-move finding" {
    const src =
        \\//! expect-error: E0002 owned value used after move
        \\const std = @import("std");
        \\
        \\pub fn oops(allocator: std.mem.Allocator) !void {
        \\    own var x = try allocator.create(u32);
        \\    using x;
        \\    var y = move x;
        \\    _ = y;
        \\    _ = x.something();
        \\}
    ;
    const findings = try checkUseAfterMove(testing.allocator, src);
    defer testing.allocator.free(findings);
    try testing.expect(findings.len >= 1);
    var saw_e0002 = false;
    for (findings) |f| {
        if (std.mem.eql(u8, f.code, "E0002")) saw_e0002 = true;
    }
    try testing.expect(saw_e0002);
}

test "E0002: use of moved name after move is flagged" {
    const src =
        \\pub fn oops(a: A) !void {
        \\    var y = move x;
        \\    _ = x;
        \\}
    ;
    const findings = try checkUseAfterMove(testing.allocator, src);
    defer testing.allocator.free(findings);
    try testing.expectEqual(@as(usize, 1), findings.len);
    try testing.expectEqualStrings("E0002", findings[0].code);
    try testing.expectEqualStrings("owned value used after move", findings[0].message);
}

test "E0002: only the destination is used after move -> not flagged" {
    const src =
        \\pub fn ok(a: A) !void {
        \\    var y = move x;
        \\    _ = y;
        \\}
    ;
    const findings = try checkUseAfterMove(testing.allocator, src);
    defer testing.allocator.free(findings);
    try testing.expectEqual(@as(usize, 0), findings.len);
}

test "E0002: source without `move` produces no findings" {
    const src =
        \\pub fn ok(a: A) !void {
        \\    var y = x;
        \\    _ = x;
        \\    _ = y;
        \\}
    ;
    const findings = try checkUseAfterMove(testing.allocator, src);
    defer testing.allocator.free(findings);
    try testing.expectEqual(@as(usize, 0), findings.len);
}

test "E0002: move in inner block does not flag uses in outer block" {
    // The move and the use live in disjoint blocks: the inner block closes
    // before the outer use is reached, so the inner-block scan stops at the
    // inner `}` and never sees the outer `_ = x;`.
    const src =
        \\pub fn ok(a: A) !void {
        \\    {
        \\        var y = move x;
        \\        _ = y;
        \\    }
        \\    _ = x;
        \\}
    ;
    const findings = try checkUseAfterMove(testing.allocator, src);
    defer testing.allocator.free(findings);
    try testing.expectEqual(@as(usize, 0), findings.len);
}

test "E0002: `using x = move y;` then `_ = y;` is flagged" {
    const src =
        \\pub fn oops(a: A) !void {
        \\    using x = move y;
        \\    _ = y;
        \\}
    ;
    const findings = try checkUseAfterMove(testing.allocator, src);
    defer testing.allocator.free(findings);
    try testing.expectEqual(@as(usize, 1), findings.len);
    try testing.expectEqualStrings("E0002", findings[0].code);
}

test "E0010: exact fixture text produces an E0010 finding" {
    const src =
        \\//! expect-error: E0010 hidden allocation in noalloc function
        \\const std = @import("std");
        \\
        \\fn allocates(allocator: std.mem.Allocator) ![]u8 {
        \\    return try allocator.alloc(u8, 16);
        \\}
        \\
        \\effects(.noalloc)
        \\pub fn pureLooking(allocator: std.mem.Allocator) !void {
        \\    _ = try allocates(allocator);
        \\}
    ;
    const findings = try checkNoAlloc(testing.allocator, src);
    defer testing.allocator.free(findings);
    try testing.expect(findings.len >= 1);
    var saw_e0010 = false;
    for (findings) |f| {
        if (std.mem.eql(u8, f.code, "E0010")) saw_e0010 = true;
    }
    try testing.expect(saw_e0010);
}

test "E0010: hash_bytes positive fixture produces zero findings" {
    const src =
        \\//! must pass no-hidden-allocation conformance
        \\const std = @import("std");
        \\
        \\effects(.noalloc, .noio)
        \\pub fn hashBytes(bytes: []const u8) u64 {
        \\    var h: u64 = 0xcbf29ce484222325;
        \\    for (bytes) |b| {
        \\        h ^= @as(u64, b);
        \\        h *%= 0x100000001b3;
        \\    }
        \\    return h;
        \\}
    ;
    const findings = try checkNoAlloc(testing.allocator, src);
    defer testing.allocator.free(findings);
    try testing.expectEqual(@as(usize, 0), findings.len);
}

test "E0010: direct allocator.alloc call inside noalloc body is flagged" {
    const src =
        \\effects(.noalloc)
        \\pub fn leak(allocator: std.mem.Allocator) ![]u8 {
        \\    return try allocator.alloc(u8, 8);
        \\}
    ;
    const findings = try checkNoAlloc(testing.allocator, src);
    defer testing.allocator.free(findings);
    try testing.expect(findings.len >= 1);
    try testing.expectEqualStrings("E0010", findings[0].code);
}

test "E0010: pass-through call with allocator argument is flagged" {
    const src =
        \\effects(.noalloc)
        \\pub fn leak(allocator: std.mem.Allocator) !void {
        \\    _ = try other(allocator);
        \\}
    ;
    const findings = try checkNoAlloc(testing.allocator, src);
    defer testing.allocator.free(findings);
    try testing.expect(findings.len >= 1);
    try testing.expectEqualStrings("E0010", findings[0].code);
}

test "E0010: effects(.noio) without .noalloc is not analyzed" {
    const src =
        \\effects(.noio)
        \\pub fn quiet(allocator: std.mem.Allocator) ![]u8 {
        \\    return try allocator.alloc(u8, 8);
        \\}
    ;
    const findings = try checkNoAlloc(testing.allocator, src);
    defer testing.allocator.free(findings);
    try testing.expectEqual(@as(usize, 0), findings.len);
}

test "E0010: function without any effects() is not analyzed" {
    const src =
        \\pub fn plain(allocator: std.mem.Allocator) ![]u8 {
        \\    return try allocator.alloc(u8, 8);
        \\}
    ;
    const findings = try checkNoAlloc(testing.allocator, src);
    defer testing.allocator.free(findings);
    try testing.expectEqual(@as(usize, 0), findings.len);
}

test "E0010: pure body with no allocator param produces zero findings" {
    const src =
        \\effects(.noalloc)
        \\pub fn add(a: u32, b: u32) u32 {
        \\    return a + b;
        \\}
    ;
    const findings = try checkNoAlloc(testing.allocator, src);
    defer testing.allocator.free(findings);
    try testing.expectEqual(@as(usize, 0), findings.len);
}

test "E0010: effects(.noalloc, .noio) still triggers analysis" {
    const src =
        \\effects(.noalloc, .noio)
        \\pub fn leak(allocator: std.mem.Allocator) ![]u8 {
        \\    return try allocator.alloc(u8, 8);
        \\}
    ;
    const findings = try checkNoAlloc(testing.allocator, src);
    defer testing.allocator.free(findings);
    try testing.expect(findings.len >= 1);
    try testing.expectEqualStrings("E0010", findings[0].code);
}
