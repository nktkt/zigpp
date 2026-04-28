//! Pure logic for the `zpp migrate` subcommand. Walks Zig source line by line
//! and finds the canonical `var x = ...; defer x.deinit();` pair, proposing a
//! single-line `using x = ...;` rewrite. No I/O happens here — callers are
//! responsible for reading/writing files.

const std = @import("std");

pub const Suggestion = struct {
    /// 1-based line of the original `var ... = ...;` line.
    var_line: u32,
    /// 1-based line of the matched `defer ....deinit();` line.
    defer_line: u32,
    /// Byte offset where the rewrite span begins (start of the `var` line).
    start: u32,
    /// Byte offset (exclusive) where the rewrite span ends (just past the
    /// newline after the `defer` line).
    end: u32,
    /// The replacement text the apply pass will splice in (no trailing newline).
    replacement: []const u8,
};

/// Find every defer-deinit -> using opportunity in `source`.
/// Suggestions are returned in source order. Caller owns the slice and each
/// `replacement` string (both allocated with `allocator`).
///
/// Limitation: a naive line-based scan; `var x = ...` inside a multi-line
/// string literal could trigger a false positive. A token-aware version would
/// catch this — future work. The same caveat applies to `defer x.deinit()`
/// inside comments.
pub fn analyze(allocator: std.mem.Allocator, source: []const u8) ![]Suggestion {
    var list = std.ArrayList(Suggestion){};
    errdefer {
        for (list.items) |s| allocator.free(s.replacement);
        list.deinit(allocator);
    }

    // Build a slice of line spans: [start, end_excl_newline, end_incl_newline].
    const Line = struct { start: u32, eol: u32, next: u32, num: u32 };
    var lines = std.ArrayList(Line){};
    defer lines.deinit(allocator);

    {
        var i: u32 = 0;
        var line_num: u32 = 1;
        const len: u32 = @intCast(source.len);
        while (i < len) {
            const start = i;
            while (i < len and source[i] != '\n') : (i += 1) {}
            const eol = i;
            const next = if (i < len) i + 1 else i;
            try lines.append(allocator, .{
                .start = start,
                .eol = eol,
                .next = next,
                .num = line_num,
            });
            line_num += 1;
            if (i < len) i += 1;
        }
    }

    var idx: usize = 0;
    while (idx + 1 < lines.items.len) {
        const var_line = lines.items[idx];
        const var_text = source[var_line.start..var_line.eol];

        if (parseVarLine(var_text)) |vp| {
            const defer_line = lines.items[idx + 1];
            const defer_text = source[defer_line.start..defer_line.eol];

            if (parseDeferLine(defer_text)) |dp| {
                if (std.mem.eql(u8, vp.indent, dp.indent) and
                    std.mem.eql(u8, vp.name, dp.name))
                {
                    // Build the replacement: <indent>using <name> = <expr>;
                    const replacement = try std.fmt.allocPrint(
                        allocator,
                        "{s}using {s} = {s};",
                        .{ vp.indent, vp.name, vp.expr },
                    );

                    try list.append(allocator, .{
                        .var_line = var_line.num,
                        .defer_line = defer_line.num,
                        .start = var_line.start,
                        .end = defer_line.next,
                        .replacement = replacement,
                    });

                    idx += 2;
                    continue;
                }
            }
        }
        idx += 1;
    }

    return list.toOwnedSlice(allocator);
}

/// Apply all suggestions to `source`, returning the rewritten buffer (caller
/// owns). Suggestions must be the output of `analyze` on the same source —
/// otherwise offsets are invalid.
pub fn applyAll(
    allocator: std.mem.Allocator,
    source: []const u8,
    suggestions: []const Suggestion,
) ![]u8 {
    if (suggestions.len == 0) {
        return allocator.dupe(u8, source);
    }

    var buf = std.ArrayList(u8){};
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, source);

    // Apply in reverse order: each splice can shift later byte offsets, so by
    // walking from the end we keep every earlier suggestion's offsets valid.
    var i: usize = suggestions.len;
    while (i > 0) {
        i -= 1;
        const s = suggestions[i];
        const start: usize = s.start;
        const end: usize = s.end;
        // The end offset includes the trailing newline of the defer line; the
        // replacement carries no newline of its own, so we re-add one here.
        try buf.replaceRange(allocator, start, end - start, s.replacement);
        try buf.insert(allocator, start + s.replacement.len, '\n');
    }

    return buf.toOwnedSlice(allocator);
}

pub fn freeSuggestions(allocator: std.mem.Allocator, sugs: []Suggestion) void {
    for (sugs) |s| allocator.free(s.replacement);
    allocator.free(sugs);
}

// ---------------------------------------------------------------------------
// Internal: line parsing
// ---------------------------------------------------------------------------

const VarParse = struct {
    indent: []const u8,
    name: []const u8,
    expr: []const u8,
};

const DeferParse = struct {
    indent: []const u8,
    name: []const u8,
};

/// Parse a single line as `<ws>var <ident> = <expr>;` with no trailing code
/// after the semicolon (only optional trailing whitespace). Returns null on
/// no match.
fn parseVarLine(line: []const u8) ?VarParse {
    var i: usize = 0;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
    const indent = line[0..i];

    if (!startsWithKeyword(line, i, "var")) return null;
    i += 3;

    // Require at least one space after `var`.
    if (i >= line.len or !(line[i] == ' ' or line[i] == '\t')) return null;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}

    const name_start = i;
    if (!consumeIdent(line, &i)) return null;
    const name = line[name_start..i];

    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
    if (i >= line.len or line[i] != '=') return null;
    i += 1;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}

    // Find the trailing `;` followed by optional whitespace through end-of-line.
    // The expression is everything up to that `;`.
    if (line.len == 0 or i >= line.len) return null;

    // Walk back from end-of-line, skipping trailing whitespace, expecting `;`.
    var j: usize = line.len;
    while (j > i and (line[j - 1] == ' ' or line[j - 1] == '\t')) : (j -= 1) {}
    if (j <= i or line[j - 1] != ';') return null;

    // Reject any earlier `;` followed by non-whitespace (i.e. another stmt on
    // the same line). Scan from i to j-2: if we see `;`, the chars between it
    // and j-1 must all be whitespace — but we already trimmed those, so the
    // presence of any earlier `;` at all means another statement followed.
    var k: usize = i;
    while (k < j - 1) : (k += 1) {
        if (line[k] == ';') return null;
    }

    const expr = line[i .. j - 1];
    if (expr.len == 0) return null;

    return .{ .indent = indent, .name = name, .expr = expr };
}

/// Parse a single line as `<ws>defer <ident>.deinit();` with optional trailing
/// whitespace. Returns null on no match.
fn parseDeferLine(line: []const u8) ?DeferParse {
    var i: usize = 0;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
    const indent = line[0..i];

    if (!startsWithKeyword(line, i, "defer")) return null;
    i += 5;

    if (i >= line.len or !(line[i] == ' ' or line[i] == '\t')) return null;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}

    const name_start = i;
    if (!consumeIdent(line, &i)) return null;
    const name = line[name_start..i];

    if (i >= line.len or line[i] != '.') return null;
    i += 1;

    const tail = "deinit();";
    if (i + tail.len > line.len) return null;
    if (!std.mem.eql(u8, line[i .. i + tail.len], tail)) return null;
    i += tail.len;

    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
    if (i != line.len) return null;

    return .{ .indent = indent, .name = name };
}

/// Returns true if `line[at..]` starts with `kw` AND the next char (if any)
/// is not part of an identifier.
fn startsWithKeyword(line: []const u8, at: usize, kw: []const u8) bool {
    if (at + kw.len > line.len) return false;
    if (!std.mem.eql(u8, line[at .. at + kw.len], kw)) return false;
    if (at + kw.len < line.len) {
        const c = line[at + kw.len];
        if (isIdentCont(c)) return false;
    }
    return true;
}

fn consumeIdent(line: []const u8, i: *usize) bool {
    const start = i.*;
    if (start >= line.len) return false;
    if (!isIdentStart(line[start])) return false;
    var k = start + 1;
    while (k < line.len and isIdentCont(line[k])) : (k += 1) {}
    i.* = k;
    return true;
}

fn isIdentStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
}

fn isIdentCont(c: u8) bool {
    return isIdentStart(c) or (c >= '0' and c <= '9');
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "analyze: empty source yields no suggestions and applyAll round-trips" {
    const allocator = testing.allocator;
    const source = "";
    const sugs = try analyze(allocator, source);
    defer freeSuggestions(allocator, sugs);
    try testing.expectEqual(@as(usize, 0), sugs.len);

    const out = try applyAll(allocator, source, sugs);
    defer allocator.free(out);
    try testing.expectEqualStrings(source, out);
}

test "analyze: source with no defer-deinit yields zero suggestions" {
    const allocator = testing.allocator;
    const source =
        \\const std = @import("std");
        \\pub fn main() void {
        \\    var x: u32 = 0;
        \\    x += 1;
        \\}
        \\
    ;
    const sugs = try analyze(allocator, source);
    defer freeSuggestions(allocator, sugs);
    try testing.expectEqual(@as(usize, 0), sugs.len);
}

test "analyze: canonical pair produces one suggestion and applyAll rewrites" {
    const allocator = testing.allocator;
    const source =
        "    var f = std.fs.cwd().createFile(\"x\", .{});\n" ++
        "    defer f.deinit();\n";
    const sugs = try analyze(allocator, source);
    defer freeSuggestions(allocator, sugs);
    try testing.expectEqual(@as(usize, 1), sugs.len);
    try testing.expectEqualStrings(
        "    using f = std.fs.cwd().createFile(\"x\", .{});",
        sugs[0].replacement,
    );
    try testing.expectEqual(@as(u32, 1), sugs[0].var_line);
    try testing.expectEqual(@as(u32, 2), sugs[0].defer_line);

    const out = try applyAll(allocator, source, sugs);
    defer allocator.free(out);
    try testing.expectEqualStrings(
        "    using f = std.fs.cwd().createFile(\"x\", .{});\n",
        out,
    );
}

test "analyze: multiple pairs in source order, applyAll splices correctly" {
    const allocator = testing.allocator;
    const source =
        "fn main() void {\n" ++
        "    var a = makeA();\n" ++
        "    defer a.deinit();\n" ++
        "    doStuff();\n" ++
        "    var b = makeB();\n" ++
        "    defer b.deinit();\n" ++
        "}\n";
    const sugs = try analyze(allocator, source);
    defer freeSuggestions(allocator, sugs);
    try testing.expectEqual(@as(usize, 2), sugs.len);
    try testing.expect(sugs[0].var_line < sugs[1].var_line);

    const out = try applyAll(allocator, source, sugs);
    defer allocator.free(out);
    const expected =
        "fn main() void {\n" ++
        "    using a = makeA();\n" ++
        "    doStuff();\n" ++
        "    using b = makeB();\n" ++
        "}\n";
    try testing.expectEqualStrings(expected, out);
}

test "analyze: indentation mismatch is not a match" {
    const allocator = testing.allocator;
    const source =
        "    var f = open();\n" ++
        "        defer f.deinit();\n";
    const sugs = try analyze(allocator, source);
    defer freeSuggestions(allocator, sugs);
    try testing.expectEqual(@as(usize, 0), sugs.len);
}

test "analyze: name mismatch is not a match" {
    const allocator = testing.allocator;
    const source =
        "    var x = open();\n" ++
        "    defer y.deinit();\n";
    const sugs = try analyze(allocator, source);
    defer freeSuggestions(allocator, sugs);
    try testing.expectEqual(@as(usize, 0), sugs.len);
}

test "analyze: blank line between var and defer is not a match" {
    const allocator = testing.allocator;
    const source =
        "    var f = open();\n" ++
        "\n" ++
        "    defer f.deinit();\n";
    const sugs = try analyze(allocator, source);
    defer freeSuggestions(allocator, sugs);
    try testing.expectEqual(@as(usize, 0), sugs.len);
}

test "analyze: try in expression is preserved" {
    const allocator = testing.allocator;
    const source =
        "    var f = try open();\n" ++
        "    defer f.deinit();\n";
    const sugs = try analyze(allocator, source);
    defer freeSuggestions(allocator, sugs);
    try testing.expectEqual(@as(usize, 1), sugs.len);
    try testing.expectEqualStrings("    using f = try open();", sugs[0].replacement);

    const out = try applyAll(allocator, source, sugs);
    defer allocator.free(out);
    try testing.expectEqualStrings("    using f = try open();\n", out);
}

test "analyze: trailing whitespace on defer line is tolerated" {
    const allocator = testing.allocator;
    const source =
        "    var f = open();\n" ++
        "    defer f.deinit();   \n";
    const sugs = try analyze(allocator, source);
    defer freeSuggestions(allocator, sugs);
    try testing.expectEqual(@as(usize, 1), sugs.len);
}

test "analyze: extra statement after var; semicolon rejects the match" {
    const allocator = testing.allocator;
    const source =
        "    var x = init(); other_thing();\n" ++
        "    defer x.deinit();\n";
    const sugs = try analyze(allocator, source);
    defer freeSuggestions(allocator, sugs);
    try testing.expectEqual(@as(usize, 0), sugs.len);
}
