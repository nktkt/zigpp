//! Whitespace-only formatter for `.zpp` source.
//!
//! This is intentionally NOT a real formatter. It does not touch indentation
//! depth, brace placement, or token spacing — those would require an AST,
//! which the research compiler does not yet have.
//!
//! The four normalization passes applied by `formatSource`:
//!   1. Trailing whitespace (' ', '\t', '\r') is stripped from every line.
//!   2. Leading tabs are converted to 4 spaces. ONLY in the leading
//!      indentation run; a tab that appears after the first non-whitespace
//!      byte (e.g. inside an aligned table comment) is preserved verbatim.
//!   3. The file ends with exactly one '\n'.
//!   4. Runs of 2+ consecutive blank lines collapse to a single blank line.
//!
//! If the input is already canonical, `formatSource` returns a byte-equal
//! copy. `isFormatted` is the cheap "did anything change?" predicate built
//! on top of that.

const std = @import("std");

/// Apply the four whitespace normalization passes (trim trailing whitespace,
/// leading-tab to 4 spaces, single trailing newline, collapse blank-line
/// runs to a single blank line). Returns an owned buffer; caller frees.
///
/// If the input is already canonical, the result is byte-equal.
///
/// This is intentionally a whitespace-only formatter — indentation depth,
/// brace placement, and token spacing are NOT touched. A real formatter
/// would need an AST, which the research compiler does not yet have.
pub fn formatSource(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    // Pass 1: rewrite each line into `intermediate` with trailing whitespace
    // stripped and leading tabs expanded. Lines are separated by '\n' and we
    // do NOT emit a trailing '\n' at the end of the last line here; pass 2
    // owns final-newline handling.
    var intermediate = std.ArrayList(u8){};
    defer intermediate.deinit(allocator);

    var i: usize = 0;
    var first_line = true;
    while (i <= source.len) {
        // Find end of line: either next '\n' or end of input.
        const line_start = i;
        while (i < source.len and source[i] != '\n') : (i += 1) {}
        const line_end = i;
        const line = source[line_start..line_end];

        // Strip trailing whitespace: ' ', '\t', '\r'.
        var stripped_end: usize = line.len;
        while (stripped_end > 0) {
            const c = line[stripped_end - 1];
            if (c == ' ' or c == '\t' or c == '\r') {
                stripped_end -= 1;
            } else break;
        }
        const stripped = line[0..stripped_end];

        // Expand leading tabs in the leading whitespace run only. A tab that
        // appears mid-line (after the first non-whitespace byte) is left
        // alone — these are usually intentional alignment in comments.
        var lead_end: usize = 0;
        while (lead_end < stripped.len and (stripped[lead_end] == ' ' or stripped[lead_end] == '\t')) : (lead_end += 1) {}

        if (!first_line) try intermediate.append(allocator, '\n');
        first_line = false;

        // Emit leading run with tabs expanded to 4 spaces each.
        for (stripped[0..lead_end]) |c| {
            if (c == '\t') {
                try intermediate.appendSlice(allocator, "    ");
            } else {
                try intermediate.append(allocator, c);
            }
        }
        // Emit the rest of the line verbatim (mid-line tabs preserved).
        try intermediate.appendSlice(allocator, stripped[lead_end..]);

        if (i >= source.len) break;
        i += 1; // skip the '\n'
    }

    // Pass 2: collapse blank-line runs (>=2 consecutive empty lines -> 1)
    // and ensure the file ends with exactly one '\n'.
    var out = std.ArrayList(u8){};
    defer out.deinit(allocator);

    var j: usize = 0;
    var prev_blank = false;
    var any_emitted = false;
    while (j <= intermediate.items.len) {
        const ls = j;
        while (j < intermediate.items.len and intermediate.items[j] != '\n') : (j += 1) {}
        const le = j;
        const line = intermediate.items[ls..le];
        const is_blank = line.len == 0;

        // Suppress an extra blank line if we just emitted one.
        if (is_blank and prev_blank) {
            // skip
        } else {
            if (any_emitted) try out.append(allocator, '\n');
            try out.appendSlice(allocator, line);
            any_emitted = true;
            prev_blank = is_blank;
        }

        if (j >= intermediate.items.len) break;
        j += 1; // skip '\n'
    }

    // If the very first virtual "line" was blank and nothing else, we still
    // need a single '\n'. Trim any leading blank lines that may have come
    // through, then guarantee exactly one trailing '\n'.
    // Strip leading blank lines (defensive — collapse already limits to one,
    // but the file could legitimately start with a blank line; per spec we
    // do not require that to disappear).
    // Actually: per spec, runs of 2+ blanks collapse to 1, so a single
    // leading blank line stays. We do nothing here.

    // Guarantee a single trailing newline:
    //   - if `out` is empty -> emit "\n"
    //   - else: trim trailing '\n' bytes (there is at most one because we
    //     only ever append '\n' as a separator) and append exactly one.
    var trimmed_end: usize = out.items.len;
    while (trimmed_end > 0 and out.items[trimmed_end - 1] == '\n') {
        trimmed_end -= 1;
    }
    out.shrinkRetainingCapacity(trimmed_end);
    try out.append(allocator, '\n');

    // Special case: if `out` is now exactly "\n" but `source` was empty, the
    // result is still "\n" — that matches the spec ("empty source -> '\n'").
    return out.toOwnedSlice(allocator);
}

/// Returns true if `source` is already in canonical form (i.e.,
/// `formatSource(source)` would be byte-equal).
pub fn isFormatted(allocator: std.mem.Allocator, source: []const u8) !bool {
    const formatted = try formatSource(allocator, source);
    defer allocator.free(formatted);
    return std.mem.eql(u8, formatted, source);
}

// ---------- inline tests ----------

test "formatSource: empty source becomes single newline" {
    const out = try formatSource(std.testing.allocator, "");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("\n", out);
}

test "formatSource: source ending without newline gets one appended" {
    const out = try formatSource(std.testing.allocator, "hello");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("hello\n", out);
}

test "formatSource: triple trailing newline collapses to one" {
    const out = try formatSource(std.testing.allocator, "hello\n\n\n");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("hello\n", out);
}

test "formatSource: trailing whitespace is trimmed" {
    const out = try formatSource(std.testing.allocator, "  hello   \n");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("  hello\n", out);
}

test "formatSource: leading tabs become 4 spaces each" {
    const out = try formatSource(std.testing.allocator, "\t\thello\n");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("        hello\n", out);
}

test "formatSource: mid-line tab is preserved" {
    // Mid-line tabs (after the first non-whitespace byte) are intentionally
    // left alone — they often align table-style comments.
    const out = try formatSource(std.testing.allocator, "x\ty\n");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("x\ty\n", out);
}

test "formatSource: blank-line run collapses to single blank" {
    const out = try formatSource(std.testing.allocator, "\n\n\nhello\n");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("\nhello\n", out);
}

test "formatSource: already-canonical source is byte-equal" {
    const out = try formatSource(std.testing.allocator, "a\n\nb\n");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("a\n\nb\n", out);
}

test "formatSource: CRLF line ending becomes LF" {
    const out = try formatSource(std.testing.allocator, "hello\r\n");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("hello\n", out);
}

test "isFormatted: returns true for canonical, false for non-canonical" {
    try std.testing.expect(try isFormatted(std.testing.allocator, "a\n\nb\n"));
    try std.testing.expect(!try isFormatted(std.testing.allocator, "  hello   \n"));
    try std.testing.expect(!try isFormatted(std.testing.allocator, "\t\thello\n"));
    try std.testing.expect(!try isFormatted(std.testing.allocator, "hello"));
    try std.testing.expect(!try isFormatted(std.testing.allocator, "a\n\n\nb\n"));
}

test "formatSource: dirty fixture round-trip" {
    const dirty =
        "const std    = @import(\"std\");   \n" ++
        "\n" ++
        "pub fn main() !void {\n" ++
        "\tvar x = 1;\t\n" ++
        "\n" ++
        "\n" ++
        "}\n";
    const expected =
        "const std    = @import(\"std\");\n" ++
        "\n" ++
        "pub fn main() !void {\n" ++
        "    var x = 1;\n" ++
        "\n" ++
        "}\n";
    const out = try formatSource(std.testing.allocator, dirty);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(expected, out);
}
