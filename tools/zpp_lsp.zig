//! Language Server for Zig++. Drives an LSP loop over stdin/stdout, surfacing
//! diagnostics from the compiler frontend (E0001 owned-not-deinit, E0002
//! use-after-move, E0003 owned-double-deinit, E0004 allocator mismatch,
//! E0010 hidden allocation in noalloc functions) via the
//! `textDocument/diagnostic` pull model.
//!
//! Scope is intentionally minimal:
//!   - `initialize` / `initialized`     : handshake
//!   - `shutdown` / `exit`              : clean teardown
//!   - `textDocument/diagnostic`        : per-file findings (pull model)
//!
//! No in-memory document state is tracked — the pull model lets clients drive
//! when to recompute diagnostics, and we always re-read the file from disk.
//! Unknown methods get -32601 (method-not-found) for requests; notifications
//! are silently ignored.
//!
//! Transport: JSON-RPC 2.0 over stdio with `Content-Length` framing
//! (see https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#headerPart).

const std = @import("std");

const zpp_lib = @import("zpp_lib");
const checks = zpp_lib.checks;
const diagnostics = zpp_lib.diagnostics;

/// LSP DiagnosticSeverity.Error. The other constants (Warning=2, Information=3,
/// Hint=4) are unused for this MVP — every check finding is an error.
const SEVERITY_ERROR: u8 = 1;

/// JSON-RPC 2.0 error codes used in our responses. Only `method_not_found` is
/// emitted by this server; the rest are documented for completeness.
const ErrorCode = struct {
    pub const parse_error: i32 = -32700;
    pub const invalid_request: i32 = -32600;
    pub const method_not_found: i32 = -32601;
    pub const invalid_params: i32 = -32602;
    pub const internal_error: i32 = -32603;
};

/// Top-level LSP loop. Reads framed JSON-RPC messages on stdin, dispatches
/// each by `method`, writes any response to stdout. Exits on stdin EOF (return
/// 0) or on `exit` notification (0 if `shutdown` was seen first, else 1).
///
/// The allocator is reset per-message via an arena to keep peak memory bounded
/// without per-call defer plumbing — every method handler can scratch freely.
pub fn run(allocator: std.mem.Allocator) !void {
    const stdin = std.fs.File.stdin();
    const stdout = std.fs.File.stdout();
    const stderr = std.fs.File.stderr();

    // Single startup line on stderr; stdout is reserved for the LSP transport.
    stderr.writeAll("[zpp lsp] starting on stdio\n") catch {};

    var shutdown_received = false;

    while (true) {
        // Per-message arena: parse + handler scratch + response body all live
        // here; freed at end of iteration. Avoids leak bookkeeping across the
        // many string allocations a single message produces.
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const body = readMessage(a, stdin) catch |err| switch (err) {
            error.EndOfStream => return, // stdin closed: clean exit.
            else => {
                stderr.writeAll("[zpp lsp] transport read error\n") catch {};
                return;
            },
        };
        if (body == null) return; // EOF before any header; treat as clean exit.

        const start_ns = std.time.nanoTimestamp();

        // Defensive parse: malformed JSON must NOT crash the server. We don't
        // even know an `id` for an error response in that case, so we just
        // log and move on.
        var parsed = std.json.parseFromSlice(std.json.Value, a, body.?, .{}) catch {
            stderr.writeAll("[zpp lsp] dropping malformed JSON message\n") catch {};
            continue;
        };
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .object) continue;
        const method_v = root.object.get("method") orelse continue;
        if (method_v != .string) continue;
        const method = method_v.string;
        const id_opt: ?std.json.Value = root.object.get("id");
        const params_opt: ?std.json.Value = root.object.get("params");

        // Notifications carry no `id`. Don't emit a response.
        const is_request = id_opt != null;

        if (std.mem.eql(u8, method, "initialize")) {
            if (is_request) try writeInitializeResponse(a, stdout, id_opt.?);
        } else if (std.mem.eql(u8, method, "initialized")) {
            // notification: no-op
        } else if (std.mem.eql(u8, method, "shutdown")) {
            shutdown_received = true;
            if (is_request) try writeNullResultResponse(a, stdout, id_opt.?);
        } else if (std.mem.eql(u8, method, "exit")) {
            // `exit` is a notification: no response, just terminate.
            std.process.exit(if (shutdown_received) 0 else 1);
        } else if (std.mem.eql(u8, method, "textDocument/diagnostic")) {
            if (is_request) try writeDiagnosticResponse(a, stdout, id_opt.?, params_opt);
        } else {
            // Anything else: respond method-not-found for requests; ignore
            // notifications. The LSP spec requires this exact code (-32601)
            // for unknown methods.
            if (is_request) {
                try writeMethodNotFound(a, stdout, id_opt.?, method);
            }
        }

        const elapsed_ms = @divTrunc(std.time.nanoTimestamp() - start_ns, std.time.ns_per_ms);
        var trace_buf: [256]u8 = undefined;
        const trace = std.fmt.bufPrint(
            &trace_buf,
            "[zpp lsp] {s} ({d} ms)\n",
            .{ method, elapsed_ms },
        ) catch null;
        if (trace) |t| stderr.writeAll(t) catch {};
    }
}

// ---------------------------------------------------------------------------
// Transport: Content-Length framed JSON-RPC over stdio
// ---------------------------------------------------------------------------

/// Read one Content-Length-framed message from `file`. Returns the body bytes
/// (allocated in `allocator`) or `null` at EOF before any header bytes.
///
/// Header set per LSP spec:
///   Content-Length: <N>\r\n
///   <other headers ignored>
///   \r\n
///   <N bytes of body>
fn readMessage(allocator: std.mem.Allocator, file: std.fs.File) !?[]u8 {
    var content_length: ?usize = null;
    var saw_any_header_byte = false;

    // Headers are read line-by-line. We don't buffer beyond a single line at
    // a time — LSP headers are short and arrival is byte-paced by the client.
    while (true) {
        const line = readLine(allocator, file) catch |err| switch (err) {
            error.EndOfStream => {
                if (saw_any_header_byte) return error.EndOfStream;
                return null;
            },
            else => return err,
        };
        defer allocator.free(line);
        saw_any_header_byte = true;

        if (line.len == 0) break; // empty line terminates the header block

        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");

        if (std.ascii.eqlIgnoreCase(name, "Content-Length")) {
            content_length = std.fmt.parseInt(usize, value, 10) catch continue;
        }
        // Other headers (Content-Type, etc.) are intentionally ignored.
    }

    const len = content_length orelse return error.MissingContentLength;
    const body = try allocator.alloc(u8, len);
    errdefer allocator.free(body);

    var read_total: usize = 0;
    while (read_total < len) {
        const n = try file.read(body[read_total..]);
        if (n == 0) return error.EndOfStream;
        read_total += n;
    }
    return body;
}

/// Read one CRLF-terminated line from `file`, returning the bytes WITHOUT the
/// terminator. Bare LF is also accepted (some toolchains relay LF-only).
fn readLine(allocator: std.mem.Allocator, file: std.fs.File) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .{};
    errdefer buf.deinit(allocator);

    var saw_cr = false;
    while (true) {
        var byte: [1]u8 = undefined;
        const n = try file.read(&byte);
        if (n == 0) {
            if (buf.items.len == 0 and !saw_cr) return error.EndOfStream;
            // Partial line at EOF: return what we have.
            return buf.toOwnedSlice(allocator);
        }
        const c = byte[0];
        if (c == '\n') return buf.toOwnedSlice(allocator);
        if (saw_cr) {
            // CR not followed by LF: keep the CR as data.
            try buf.append(allocator, '\r');
            saw_cr = false;
        }
        if (c == '\r') {
            saw_cr = true;
            continue;
        }
        try buf.append(allocator, c);
    }
}

/// Emit `body` framed as one LSP message: `Content-Length: N\r\n\r\n<body>`.
fn writeFramed(file: std.fs.File, body: []const u8) !void {
    var hdr_buf: [64]u8 = undefined;
    const hdr = try std.fmt.bufPrint(&hdr_buf, "Content-Length: {d}\r\n\r\n", .{body.len});
    try file.writeAll(hdr);
    try file.writeAll(body);
}

// ---------------------------------------------------------------------------
// Outbound message construction
//
// We hand-build the JSON for outgoing messages: the structure is small and
// fixed, and avoiding the std.json Stringify machinery keeps the wire output
// trivially auditable from the smoke shell test.
// ---------------------------------------------------------------------------

/// Render a request `id` (which may be number or string per JSON-RPC) back as
/// a JSON token suitable for placement in an outbound `id` field.
fn idToJson(allocator: std.mem.Allocator, id: std.json.Value) ![]u8 {
    return switch (id) {
        .integer => |n| try std.fmt.allocPrint(allocator, "{d}", .{n}),
        .string => |s| try std.fmt.allocPrint(allocator, "\"{s}\"", .{escapeJsonString(s, allocator) catch s}),
        .null => try allocator.dupe(u8, "null"),
        else => try allocator.dupe(u8, "null"),
    };
}

/// Escape a string for safe embedding inside a JSON string literal. Caller
/// owns the returned slice. Handles the minimum set required by JSON: `"`,
/// `\`, and the C0 control range.
fn escapeJsonString(s: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .{};
    errdefer out.deinit(allocator);
    for (s) |c| {
        switch (c) {
            '"' => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            0...8, 11, 12, 14...31 => {
                var hex_buf: [6]u8 = undefined;
                const h = try std.fmt.bufPrint(&hex_buf, "\\u{x:0>4}", .{c});
                try out.appendSlice(allocator, h);
            },
            else => try out.append(allocator, c),
        }
    }
    return out.toOwnedSlice(allocator);
}

fn writeInitializeResponse(allocator: std.mem.Allocator, file: std.fs.File, id: std.json.Value) !void {
    const id_json = try idToJson(allocator, id);
    defer allocator.free(id_json);

    // Capabilities: textDocumentSync = 0 (None) since we run pull-only;
    // diagnosticProvider advertises identifier + stability flags. The
    // workspaceDiagnostics flag is false — we only handle per-file pulls.
    const body = try std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"capabilities\":{{" ++
            "\"textDocumentSync\":0," ++
            "\"diagnosticProvider\":{{" ++
            "\"identifier\":\"zpp\"," ++
            "\"interFileDependencies\":false," ++
            "\"workspaceDiagnostics\":false" ++
            "}}" ++
            "}},\"serverInfo\":{{\"name\":\"zpp\",\"version\":\"0.0.1\"}}}}}}",
        .{id_json},
    );
    defer allocator.free(body);
    try writeFramed(file, body);
}

fn writeNullResultResponse(allocator: std.mem.Allocator, file: std.fs.File, id: std.json.Value) !void {
    const id_json = try idToJson(allocator, id);
    defer allocator.free(id_json);
    const body = try std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":null}}",
        .{id_json},
    );
    defer allocator.free(body);
    try writeFramed(file, body);
}

fn writeMethodNotFound(
    allocator: std.mem.Allocator,
    file: std.fs.File,
    id: std.json.Value,
    method: []const u8,
) !void {
    const id_json = try idToJson(allocator, id);
    defer allocator.free(id_json);
    const escaped = try escapeJsonString(method, allocator);
    defer allocator.free(escaped);
    const body = try std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"error\":{{\"code\":{d},\"message\":\"method not found: {s}\"}}}}",
        .{ id_json, ErrorCode.method_not_found, escaped },
    );
    defer allocator.free(body);
    try writeFramed(file, body);
}

// ---------------------------------------------------------------------------
// textDocument/diagnostic handler
// ---------------------------------------------------------------------------

/// Handle a `textDocument/diagnostic` pull request. Resolves the document URI
/// to a filesystem path, reads the file, runs all five sema checks, and
/// returns the union of findings as a `RelatedFullDocumentDiagnosticReport`.
///
/// On any read or URI failure we return zero diagnostics rather than an error
/// — the LSP spec lets the server signal "unchanged"/"no diagnostics" without
/// a hard error, and crashing on a transient read failure would be hostile to
/// editor integrations.
fn writeDiagnosticResponse(
    allocator: std.mem.Allocator,
    file: std.fs.File,
    id: std.json.Value,
    params_opt: ?std.json.Value,
) !void {
    const id_json = try idToJson(allocator, id);
    defer allocator.free(id_json);

    const diags_json = blk: {
        const params = params_opt orelse break :blk try allocator.dupe(u8, "[]");
        if (params != .object) break :blk try allocator.dupe(u8, "[]");
        const td = params.object.get("textDocument") orelse break :blk try allocator.dupe(u8, "[]");
        if (td != .object) break :blk try allocator.dupe(u8, "[]");
        const uri_v = td.object.get("uri") orelse break :blk try allocator.dupe(u8, "[]");
        if (uri_v != .string) break :blk try allocator.dupe(u8, "[]");

        const path = (uriToPath(allocator, uri_v.string) catch null) orelse
            break :blk try allocator.dupe(u8, "[]");
        defer allocator.free(path);

        // 1 MiB cap matches the rest of the toolchain (cmdCheck, test_runner).
        const max_size: usize = 1 * 1024 * 1024;
        const source = std.fs.cwd().readFileAlloc(allocator, path, max_size) catch
            break :blk try allocator.dupe(u8, "[]");
        defer allocator.free(source);

        break :blk try renderDiagnostics(allocator, source);
    };
    defer allocator.free(diags_json);

    // RelatedFullDocumentDiagnosticReport: { kind: "full", items: [...] }.
    // We don't populate `relatedDocuments` because we don't track inter-file
    // dependencies (`interFileDependencies` was advertised false above).
    const body = try std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"kind\":\"full\",\"items\":{s}}}}}",
        .{ id_json, diags_json },
    );
    defer allocator.free(body);
    try writeFramed(file, body);
}

/// Run all five sema checks on `source`, render each finding as an LSP
/// `Diagnostic`, and return the JSON array (e.g. `[{...},{...}]`). Caller
/// owns the returned slice.
fn renderDiagnostics(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    const own = checks.checkOwnership(allocator, source) catch &[_]checks.Finding{};
    defer if (own.len > 0) allocator.free(own);
    const move = checks.checkUseAfterMove(allocator, source) catch &[_]checks.Finding{};
    defer if (move.len > 0) allocator.free(move);
    const double = checks.checkDoubleDeinit(allocator, source) catch &[_]checks.Finding{};
    defer if (double.len > 0) allocator.free(double);
    const mismatch = checks.checkAllocatorMismatch(allocator, source) catch &[_]checks.Finding{};
    defer if (mismatch.len > 0) allocator.free(mismatch);
    const noalloc = checks.checkNoAlloc(allocator, source) catch &[_]checks.Finding{};
    defer if (noalloc.len > 0) allocator.free(noalloc);

    var out: std.ArrayListUnmanaged(u8) = .{};
    errdefer out.deinit(allocator);
    try out.append(allocator, '[');

    var first = true;
    for ([_][]const checks.Finding{ own, move, double, mismatch, noalloc }) |group| {
        for (group) |f| {
            if (!first) try out.append(allocator, ',');
            first = false;
            try appendFinding(allocator, &out, f);
        }
    }

    try out.append(allocator, ']');
    return out.toOwnedSlice(allocator);
}

/// Append a JSON-encoded LSP `Diagnostic` for `f` to `out`.
///
/// LSP positions are zero-based; `Finding.line`/`col` are one-based, so we
/// subtract 1. The end position is computed as `start + 1`: column-extent
/// accuracy isn't a hard requirement for this MVP — we don't carry token
/// lengths through the check API. Future revs that want exact spans can
/// extend `Finding` with an `end` column.
fn appendFinding(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    f: checks.Finding,
) !void {
    const line0: i64 = if (f.line == 0) 0 else @as(i64, f.line) - 1;
    const col0: i64 = if (f.col == 0) 0 else @as(i64, f.col) - 1;
    const col_end: i64 = col0 + 1;

    const escaped_msg = try escapeJsonString(f.message, allocator);
    defer allocator.free(escaped_msg);
    const escaped_code = try escapeJsonString(f.code, allocator);
    defer allocator.free(escaped_code);

    const piece = try std.fmt.allocPrint(
        allocator,
        "{{\"range\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}}," ++
            "\"severity\":{d},\"code\":\"{s}\",\"source\":\"zpp\",\"message\":\"{s}\"}}",
        .{ line0, col0, line0, col_end, SEVERITY_ERROR, escaped_code, escaped_msg },
    );
    defer allocator.free(piece);
    try out.appendSlice(allocator, piece);
}

/// Convert an LSP `file://` URI to a filesystem path. Returns null if `uri`
/// doesn't have the `file://` scheme.
///
/// Limitation: percent-decoding is NOT performed. Real-world paths almost
/// never need it (LSP clients typically only encode `%20` for spaces and
/// non-ASCII), and getting it right portably is more code than this MVP
/// warrants. Add when a fixture demands it.
fn uriToPath(allocator: std.mem.Allocator, uri: []const u8) !?[]u8 {
    const prefix = "file://";
    if (!std.mem.startsWith(u8, uri, prefix)) return null;
    const rest = uri[prefix.len..];
    // Some clients emit `file:///abs/path` (three slashes); the leading slash
    // is part of the absolute path, so we keep it. On Windows the path may
    // begin with `/C:/...` — out of scope here, document and move on.
    return try allocator.dupe(u8, rest);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "uriToPath strips file:// prefix" {
    const path = (try uriToPath(testing.allocator, "file:///tmp/foo.zpp")).?;
    defer testing.allocator.free(path);
    try testing.expectEqualStrings("/tmp/foo.zpp", path);
}

test "uriToPath rejects non-file scheme" {
    const result = try uriToPath(testing.allocator, "http://example.com/foo");
    try testing.expect(result == null);
}

test "escapeJsonString handles quotes and backslashes" {
    const out = try escapeJsonString("he said \"hi\"\\bye", testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("he said \\\"hi\\\"\\\\bye", out);
}

test "escapeJsonString handles control characters" {
    const out = try escapeJsonString("a\nb\tc\rd", testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("a\\nb\\tc\\rd", out);
}

test "renderDiagnostics returns [] for empty input" {
    const out = try renderDiagnostics(testing.allocator, "");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("[]", out);
}

test "renderDiagnostics surfaces E0001 finding" {
    const src =
        \\pub fn leaky(allocator: std.mem.Allocator) !void {
        \\    own var x = try allocator.create(u32);
        \\    x.* = 42;
        \\}
    ;
    const out = try renderDiagnostics(testing.allocator, src);
    defer testing.allocator.free(out);
    // The exact JSON shape is asserted loosely — we only need to know the
    // E0001 code surfaced and the message text is intact. Position values
    // are exercised by appendFinding's line/col conversion below.
    try testing.expect(std.mem.indexOf(u8, out, "\"code\":\"E0001\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"source\":\"zpp\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"severity\":1") != null);
    try testing.expect(std.mem.indexOf(u8, out, "owned value was not deinitialized") != null);
}

test "renderDiagnostics emits zero-based positions" {
    // Construct a minimal source where the `own` token sits on line 2, col 5
    // (1-based). After 0-based conversion the LSP range start should be
    // line=1, character=4.
    const src =
        \\pub fn f(a: A) !void {
        \\    own var x = try a.create(u32);
        \\}
    ;
    const out = try renderDiagnostics(testing.allocator, src);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "\"line\":1") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"character\":4") != null);
}

test "renderDiagnostics surfaces E0002 use-after-move" {
    const src =
        \\pub fn oops(a: A) !void {
        \\    var y = move x;
        \\    _ = x;
        \\}
    ;
    const out = try renderDiagnostics(testing.allocator, src);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "\"code\":\"E0002\"") != null);
}

test "renderDiagnostics surfaces E0010 hidden alloc" {
    const src =
        \\effects(.noalloc)
        \\pub fn leak(allocator: std.mem.Allocator) ![]u8 {
        \\    return try allocator.alloc(u8, 8);
        \\}
    ;
    const out = try renderDiagnostics(testing.allocator, src);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "\"code\":\"E0010\"") != null);
}
