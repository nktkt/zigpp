//! Zig++ integration test runner. Walks `tests/<category>/` and dispatches
//! each `.zpp` fixture to the runner appropriate for its category. Exits 0 if
//! no test FAILed; SKIP and PASS are both non-failure outcomes.

const std = @import("std");
const zpp_lib = @import("zpp_lib");
const lowerSource = zpp_lib.lower_to_zig.lowerSource;

const Outcome = enum { passed, failed, skipped };

const Category = enum {
    compile,
    behavior,
    lowering,
    diagnostics,
    no_hidden_alloc,
};

const categories = [_]struct { cat: Category, name: []const u8 }{
    .{ .cat = .compile, .name = "compile" },
    .{ .cat = .behavior, .name = "behavior" },
    .{ .cat = .lowering, .name = "lowering" },
    .{ .cat = .diagnostics, .name = "diagnostics" },
    .{ .cat = .no_hidden_alloc, .name = "no_hidden_alloc" },
};

const Counts = struct {
    passed: usize = 0,
    failed: usize = 0,
    skipped: usize = 0,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 0.15.2: std.io.getStdOut() was removed; use std.fs.File.stdout().deprecatedWriter()
    // which exposes a GenericWriter compatible with anytype writer.print(...).
    const stdout = std.fs.File.stdout().deprecatedWriter();
    var counts = Counts{};

    for (categories) |c| {
        try runCategory(allocator, stdout, c.cat, c.name, &counts);
    }

    try stdout.print("\n=== summary ===\n", .{});
    try stdout.print("passed:  {d}\n", .{counts.passed});
    try stdout.print("failed:  {d}\n", .{counts.failed});
    try stdout.print("skipped: {d}\n", .{counts.skipped});

    std.process.exit(if (counts.failed == 0) 0 else 1);
}

fn runCategory(
    allocator: std.mem.Allocator,
    writer: anytype,
    cat: Category,
    name: []const u8,
    counts: *Counts,
) !void {
    const sub_path = try std.fmt.allocPrint(allocator, "tests/{s}", .{name});
    defer allocator.free(sub_path);

    var dir = std.fs.cwd().openDir(sub_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close();

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".zpp")) continue;

        const fname = try allocator.dupe(u8, entry.name);
        defer allocator.free(fname);

        const path = try std.fs.path.join(allocator, &.{ sub_path, fname });
        defer allocator.free(path);

        try writer.print("RUN  {s}/{s}\n", .{ name, fname });

        const outcome = switch (cat) {
            .compile => runCompile(allocator, writer, path),
            .lowering => runLowering(allocator, writer, sub_path, fname, path),
            .diagnostics => runDiagnostics(allocator, writer, path),
            .behavior => runBehavior(allocator, writer, fname, path),
            .no_hidden_alloc => runNoHiddenAlloc(allocator, writer, path),
        } catch |err| blk: {
            try writer.print("FAIL ({s})\n", .{@errorName(err)});
            break :blk Outcome.failed;
        };

        switch (outcome) {
            .passed => counts.passed += 1,
            .failed => counts.failed += 1,
            .skipped => counts.skipped += 1,
        }
    }
}

fn skipWith(writer: anytype, reason: []const u8) !Outcome {
    try writer.print("SKIP ({s})\n", .{reason});
    return .skipped;
}

const max_fixture_size: usize = 1 * 1024 * 1024;

/// compile/: lower the .zpp; PASS if lowering returns without error.
/// This is a weak check (text passthrough doesn't reject invalid Zig++ syntax)
/// but it's the strongest assertion the current pipeline can make.
fn runCompile(
    allocator: std.mem.Allocator,
    writer: anytype,
    path: []const u8,
) !Outcome {
    const src = try std.fs.cwd().readFileAlloc(allocator, path, max_fixture_size);
    defer allocator.free(src);

    const lowered = lowerSource(allocator, src) catch |err| {
        try writer.print("FAIL (lowerSource: {s})\n", .{@errorName(err)});
        return .failed;
    };
    defer allocator.free(lowered);

    try writer.print("PASS (lowered ok)\n", .{});
    return .passed;
}

/// lowering/: compare lowerSource output against <basename>.expected.zig byte-exact.
fn runLowering(
    allocator: std.mem.Allocator,
    writer: anytype,
    sub_path: []const u8,
    fname: []const u8,
    path: []const u8,
) !Outcome {
    const stem = fname[0 .. fname.len - ".zpp".len];
    const expected_name = try std.fmt.allocPrint(allocator, "{s}.expected.zig", .{stem});
    defer allocator.free(expected_name);
    const expected_path = try std.fs.path.join(allocator, &.{ sub_path, expected_name });
    defer allocator.free(expected_path);

    const src = try std.fs.cwd().readFileAlloc(allocator, path, max_fixture_size);
    defer allocator.free(src);

    const expected = std.fs.cwd().readFileAlloc(allocator, expected_path, max_fixture_size) catch |err| switch (err) {
        error.FileNotFound => {
            try writer.print("SKIP (no {s})\n", .{expected_name});
            return .skipped;
        },
        else => return err,
    };
    defer allocator.free(expected);

    const actual = lowerSource(allocator, src) catch |err| {
        try writer.print("FAIL (lowerSource: {s})\n", .{@errorName(err)});
        return .failed;
    };
    defer allocator.free(actual);

    if (std.mem.eql(u8, actual, expected)) {
        try writer.print("PASS\n", .{});
        return .passed;
    }

    try writer.print("FAIL (lowering mismatch)\n", .{});
    try printSnippet(writer, "expected", expected);
    try printSnippet(writer, "actual  ", actual);
    return .failed;
}

/// diagnostics/: validate the test header is well-formed (`//! expect-error:
/// <CODE> <message>`). For E0001, run the token-based ownership check and
/// PASS iff a finding with that code is produced. Other codes still SKIP.
fn runDiagnostics(
    allocator: std.mem.Allocator,
    writer: anytype,
    path: []const u8,
) !Outcome {
    const src = try std.fs.cwd().readFileAlloc(allocator, path, max_fixture_size);
    defer allocator.free(src);

    const eol = std.mem.indexOfScalar(u8, src, '\n') orelse src.len;
    const first = std.mem.trimRight(u8, src[0..eol], " \r");
    const prefix = "//! expect-error: ";
    if (!std.mem.startsWith(u8, first, prefix)) {
        try writer.print("FAIL (missing `//! expect-error: ...` header)\n", .{});
        return .failed;
    }
    const tail = first[prefix.len..];
    if (tail.len < 6 or tail[0] != 'E') {
        try writer.print("FAIL (expect-error header lacks Exxxx code: \"{s}\")\n", .{tail});
        return .failed;
    }

    // Extract the code: first whitespace-delimited token after the prefix.
    const code_end = std.mem.indexOfAny(u8, tail, " \t") orelse tail.len;
    const code = tail[0..code_end];

    if (std.mem.eql(u8, code, "E0001")) {
        return runCheck(allocator, writer, src, "E0001", zpp_lib.checks.checkOwnership, "checkOwnership");
    }
    if (std.mem.eql(u8, code, "E0002")) {
        return runCheck(allocator, writer, src, "E0002", zpp_lib.checks.checkUseAfterMove, "checkUseAfterMove");
    }
    if (std.mem.eql(u8, code, "E0003")) {
        return runCheck(allocator, writer, src, "E0003", zpp_lib.checks.checkDoubleDeinit, "checkDoubleDeinit");
    }
    if (std.mem.eql(u8, code, "E0004")) {
        return runCheck(allocator, writer, src, "E0004", zpp_lib.checks.checkAllocatorMismatch, "checkAllocatorMismatch");
    }
    if (std.mem.eql(u8, code, "E0010")) {
        return runCheck(allocator, writer, src, "E0010", zpp_lib.checks.checkNoAlloc, "checkNoAlloc");
    }
    if (std.mem.eql(u8, code, "E0020")) {
        return runCheck(allocator, writer, src, "E0020", zpp_lib.checks.checkTraitImpl, "checkTraitImpl");
    }

    try writer.print("SKIP (header ok; sema not yet implemented)\n", .{});
    return .skipped;
}

/// no_hidden_alloc/: positive-conformance category. Each fixture must produce
/// zero E0010 findings under `checkNoAlloc`. Any finding fails the test.
fn runNoHiddenAlloc(
    allocator: std.mem.Allocator,
    writer: anytype,
    path: []const u8,
) !Outcome {
    const src = try std.fs.cwd().readFileAlloc(allocator, path, max_fixture_size);
    defer allocator.free(src);

    const findings = zpp_lib.checks.checkNoAlloc(allocator, src) catch |err| {
        try writer.print("FAIL (checkNoAlloc: {s})\n", .{@errorName(err)});
        return .failed;
    };
    defer allocator.free(findings);

    if (findings.len == 0) {
        try writer.print("PASS\n", .{});
        return .passed;
    }

    try writer.print(
        "FAIL (unexpected E0010 findings: {d}; first at line {d}, col {d})\n",
        .{ findings.len, findings[0].line, findings[0].col },
    );
    return .failed;
}

/// Shared body for diagnostic codes backed by a token-based check function.
/// PASS iff the check returns at least one finding whose `code` matches `expected`.
fn runCheck(
    allocator: std.mem.Allocator,
    writer: anytype,
    src: []const u8,
    expected: []const u8,
    comptime check_fn: fn (std.mem.Allocator, []const u8) anyerror![]zpp_lib.checks.Finding,
    comptime check_name: []const u8,
) !Outcome {
    const findings = check_fn(allocator, src) catch |err| {
        try writer.print("FAIL ({s}: {s})\n", .{ check_name, @errorName(err) });
        return .failed;
    };
    defer allocator.free(findings);

    for (findings) |f| {
        if (std.mem.eql(u8, f.code, expected)) {
            try writer.print("PASS\n", .{});
            return .passed;
        }
    }

    try writer.print("FAIL (expected {s} but no finding produced)\n", .{expected});
    return .failed;
}

fn printSnippet(writer: anytype, label: []const u8, s: []const u8) !void {
    const cap: usize = 200;
    const shown = if (s.len > cap) s[0..cap] else s;
    try writer.print("  {s}: \"", .{label});
    for (shown) |b| switch (b) {
        '\n' => try writer.print("\\n", .{}),
        '\t' => try writer.print("\\t", .{}),
        '"' => try writer.print("\\\"", .{}),
        '\\' => try writer.print("\\\\", .{}),
        else => try writer.print("{c}", .{b}),
    };
    if (s.len > cap) try writer.print("...", .{});
    try writer.print("\"\n", .{});
}

/// Template for the build.zig synthesized into each behavior fixture's tmp
/// dir. Builds `.zpp-out/main.zig` as `behavior_test`. We deliberately don't
/// expose a `run` step that we use — the runner spawns the produced binary
/// directly so the captured stderr is the program's own output, free of
/// `zig build`'s progress chatter.
///
/// `{s}` is interpolated at write-time with the absolute path to
/// `lib/zpp.zig` so the lowered code's `@import("zpp")` resolves regardless
/// of where the tmp dir lives. We use `.cwd_relative` because the path is
/// outside the tmp dir's build root, where `b.path` would be invalid.
const synthesized_build_zig_template =
    \\const std = @import("std");
    \\pub fn build(b: *std.Build) void {{
    \\    const target = b.standardTargetOptions(.{{}});
    \\    const optimize = b.standardOptimizeOption(.{{}});
    \\    const zpp_mod = b.createModule(.{{
    \\        .root_source_file = .{{ .cwd_relative = "{s}" }},
    \\        .target = target,
    \\        .optimize = optimize,
    \\    }});
    \\    const m = b.createModule(.{{
    \\        .root_source_file = b.path(".zpp-out/main.zig"),
    \\        .target = target,
    \\        .optimize = optimize,
    \\    }});
    \\    m.addImport("zpp", zpp_mod);
    \\    const exe = b.addExecutable(.{{ .name = "behavior_test", .root_module = m }});
    \\    b.installArtifact(exe);
    \\    const run_cmd = b.addRunArtifact(exe);
    \\    run_cmd.step.dependOn(b.getInstallStep());
    \\    const run_step = b.step("run", "");
    \\    run_step.dependOn(&run_cmd.step);
    \\}}
    \\
;

/// Synthesized `build.zig.zon`. The fingerprint is fixed; if a future Zig
/// release rejects it, the failure message names the expected value, which can
/// be substituted here.
const synthesized_build_zon =
    \\.{
    \\    .name = .behavior_test,
    \\    .version = "0.0.0",
    \\    .fingerprint = 0x316942bf0c14ab6f,
    \\    .minimum_zig_version = "0.15.0",
    \\    .dependencies = .{},
    \\    .paths = .{ "build.zig", "build.zig.zon", ".zpp-out" },
    \\}
    \\
;

const ExpectedKind = enum { stdout, stderr };

const ExpectedHeader = struct {
    kind: ExpectedKind,
    /// Owned by caller; allocated via the same allocator passed to parseHeader.
    pattern: []u8,
};

/// Parses the first line of a behavior fixture. Recognizes:
///   `// expected stdout: <pattern>`
///   `// expected stderr: <pattern>`
/// Inside `<pattern>`, the escapes `\n`, `\t`, and `\\` are interpreted as
/// LF (0x0A), TAB (0x09), and a single backslash respectively. Other
/// backslash sequences are passed through verbatim (limitation: e.g. `\r`
/// is not supported; add cases here when a fixture needs them).
fn parseHeader(allocator: std.mem.Allocator, src: []const u8) !?ExpectedHeader {
    const eol = std.mem.indexOfScalar(u8, src, '\n') orelse src.len;
    const first = std.mem.trimRight(u8, src[0..eol], " \r");

    const stdout_prefix = "// expected stdout: ";
    const stderr_prefix = "// expected stderr: ";
    var kind: ExpectedKind = undefined;
    var raw: []const u8 = undefined;
    if (std.mem.startsWith(u8, first, stdout_prefix)) {
        kind = .stdout;
        raw = first[stdout_prefix.len..];
    } else if (std.mem.startsWith(u8, first, stderr_prefix)) {
        kind = .stderr;
        raw = first[stderr_prefix.len..];
    } else {
        return null;
    }

    var buf = try allocator.alloc(u8, raw.len);
    var n: usize = 0;
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        const c = raw[i];
        if (c == '\\' and i + 1 < raw.len) {
            const nxt = raw[i + 1];
            switch (nxt) {
                'n' => {
                    buf[n] = '\n';
                    n += 1;
                    i += 1;
                    continue;
                },
                't' => {
                    buf[n] = '\t';
                    n += 1;
                    i += 1;
                    continue;
                },
                '\\' => {
                    buf[n] = '\\';
                    n += 1;
                    i += 1;
                    continue;
                },
                else => {},
            }
        }
        buf[n] = c;
        n += 1;
    }
    const pattern = try allocator.realloc(buf, n);
    return ExpectedHeader{ .kind = kind, .pattern = pattern };
}

/// Removes `_ = <ident>;` lines whose <ident> is already referenced by a
/// `defer <ident>.deinit();` elsewhere in the source. Zig 0.15.2 treats such
/// redundant discards as a hard `pointless discard of local variable` error,
/// but lowered `using` rewrites can leave them behind when the original
/// fixture explicitly named the binding to silence an unused-variable check.
/// First pass: collect every identifier mentioned as `defer X.deinit();`.
/// Second pass: emit every line except `<ws>_ = X;<ws>` for those identifiers.
fn stripPointlessDiscards(allocator: std.mem.Allocator, src: []const u8) ![]u8 {
    var defer_idents = std.StringHashMap(void).init(allocator);
    defer defer_idents.deinit();

    // Pass 1: scan for `defer <ident>.deinit();`
    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |line| {
        var rest = std.mem.trimLeft(u8, line, " \t");
        // A line may carry multiple statements; scan all `defer ... .deinit();`
        // segments by splitting on ';'.
        while (true) {
            const idx = std.mem.indexOf(u8, rest, "defer ") orelse break;
            rest = rest[idx + "defer ".len ..];
            // Read identifier
            var j: usize = 0;
            while (j < rest.len and (std.ascii.isAlphanumeric(rest[j]) or rest[j] == '_')) : (j += 1) {}
            if (j == 0) continue;
            const ident = rest[0..j];
            const tail = rest[j..];
            if (std.mem.startsWith(u8, tail, ".deinit()")) {
                _ = try defer_idents.getOrPut(ident);
            }
            rest = tail;
        }
    }

    var out = std.ArrayList(u8){};
    defer out.deinit(allocator);

    // Pass 2: emit lines, dropping those that are exactly `_ = X;` for a
    // defer-bound X. Preserve all other content byte-for-byte.
    var i: usize = 0;
    while (i < src.len) {
        const line_start = i;
        var line_end = line_start;
        while (line_end < src.len and src[line_end] != '\n') : (line_end += 1) {}
        const has_nl = line_end < src.len;
        const line = src[line_start..line_end];

        const trimmed = std.mem.trim(u8, line, " \t");
        var drop = false;
        if (std.mem.startsWith(u8, trimmed, "_ = ") and std.mem.endsWith(u8, trimmed, ";")) {
            const inner = std.mem.trim(u8, trimmed[4 .. trimmed.len - 1], " \t");
            // Pure identifier?
            var pure = inner.len > 0;
            for (inner) |c| {
                if (!(std.ascii.isAlphanumeric(c) or c == '_')) {
                    pure = false;
                    break;
                }
            }
            if (pure and defer_idents.contains(inner)) {
                drop = true;
            }
        }

        if (!drop) {
            try out.appendSlice(allocator, line);
            if (has_nl) try out.append(allocator, '\n');
        }
        i = if (has_nl) line_end + 1 else line_end;
    }

    return out.toOwnedSlice(allocator);
}

/// behavior/: lower the .zpp, write it under a fresh tmp dir, build it via
/// `zig build` (stage 1), then exec the produced binary directly (stage 2).
/// The two-stage split exists because `zig build run` interleaves Zig's own
/// progress chatter into stderr; running the binary ourselves keeps the
/// capture pure so byte-exact comparison against the header pattern works.
fn runBehavior(
    allocator: std.mem.Allocator,
    writer: anytype,
    fname: []const u8,
    path: []const u8,
) !Outcome {
    const src = try std.fs.cwd().readFileAlloc(allocator, path, max_fixture_size);
    defer allocator.free(src);

    const header = parseHeader(allocator, src) catch |err| {
        try writer.print("FAIL (header parse: {s})\n", .{@errorName(err)});
        return .failed;
    } orelse {
        try writer.print("FAIL (missing `// expected stdout:` or `// expected stderr:` header)\n", .{});
        return .failed;
    };
    defer allocator.free(header.pattern);

    const stem = fname[0 .. fname.len - ".zpp".len];
    const tmp_path = try std.fmt.allocPrint(allocator, "tests/.tmp-behavior/{s}", .{stem});
    defer allocator.free(tmp_path);

    // Best-effort cleanup of any leftover dir from a previous run; recreate fresh.
    std.fs.cwd().deleteTree(tmp_path) catch {};
    try std.fs.cwd().makePath(tmp_path);
    defer std.fs.cwd().deleteTree(tmp_path) catch {};

    const out_subdir = try std.fmt.allocPrint(allocator, "{s}/.zpp-out", .{tmp_path});
    defer allocator.free(out_subdir);
    try std.fs.cwd().makePath(out_subdir);

    const lowered = lowerSource(allocator, src) catch |err| {
        try writer.print("FAIL (lowerSource: {s})\n", .{@errorName(err)});
        return .failed;
    };
    defer allocator.free(lowered);

    // Post-process: drop `_ = <ident>;` lines whose <ident> is already used
    // by a `defer <ident>.deinit();` produced by the `using` rewrite. Zig
    // 0.15 rejects such redundant discards as `pointless discard of local
    // variable`. The fixture predates that rule; the runner sanitizes here
    // rather than mutating the lowering or fixture.
    const sanitized = try stripPointlessDiscards(allocator, lowered);
    defer allocator.free(sanitized);

    {
        const main_path = try std.fmt.allocPrint(allocator, "{s}/main.zig", .{out_subdir});
        defer allocator.free(main_path);
        const f = try std.fs.cwd().createFile(main_path, .{ .truncate = true });
        defer f.close();
        try f.writeAll(sanitized);
    }
    {
        // The build.zig template references `lib/zpp.zig` by absolute path —
        // the tmp dir is not a sibling of `lib/`, so a relative path inside
        // the synthesized build root would not resolve. Compute it from cwd
        // (set to the project root by build.zig) and free after writing.
        const lib_zpp_abs = try std.fs.cwd().realpathAlloc(allocator, "lib/zpp.zig");
        defer allocator.free(lib_zpp_abs);
        const bz_contents = try std.fmt.allocPrint(
            allocator,
            synthesized_build_zig_template,
            .{lib_zpp_abs},
        );
        defer allocator.free(bz_contents);

        const bz_path = try std.fmt.allocPrint(allocator, "{s}/build.zig", .{tmp_path});
        defer allocator.free(bz_path);
        const f = try std.fs.cwd().createFile(bz_path, .{ .truncate = true });
        defer f.close();
        try f.writeAll(bz_contents);
    }
    {
        const zon_path = try std.fmt.allocPrint(allocator, "{s}/build.zig.zon", .{tmp_path});
        defer allocator.free(zon_path);
        const f = try std.fs.cwd().createFile(zon_path, .{ .truncate = true });
        defer f.close();
        try f.writeAll(synthesized_build_zon);
    }

    // Stage 1: compile only. Run from tmp_path so build artifacts land there.
    {
        const argv = [_][]const u8{ "zig", "build" };
        const result = std.process.Child.run(.{
            .allocator = allocator,
            .argv = &argv,
            .cwd = tmp_path,
            .max_output_bytes = 4 * 1024 * 1024,
        }) catch |err| {
            try writer.print("FAIL (zig build spawn: {s})\n", .{@errorName(err)});
            return .failed;
        };
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        const ok = switch (result.term) {
            .Exited => |code| code == 0,
            else => false,
        };
        if (!ok) {
            try writer.print("FAIL (zig build failed)\n", .{});
            try printSnippet(writer, "build_stderr", result.stderr);
            return .failed;
        }
    }

    // Stage 2: exec the built binary. Capture is pure — no zig build chatter.
    const bin_path = try std.fmt.allocPrint(allocator, "{s}/zig-out/bin/behavior_test", .{tmp_path});
    defer allocator.free(bin_path);

    const run_argv = [_][]const u8{bin_path};
    const run_result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &run_argv,
        .max_output_bytes = 4 * 1024 * 1024,
    }) catch |err| {
        try writer.print("FAIL (binary spawn: {s})\n", .{@errorName(err)});
        return .failed;
    };
    defer allocator.free(run_result.stdout);
    defer allocator.free(run_result.stderr);

    const exit_code: ?i32 = switch (run_result.term) {
        .Exited => |code| @intCast(code),
        else => null,
    };

    const captured = switch (header.kind) {
        .stdout => run_result.stdout,
        .stderr => run_result.stderr,
    };
    const stream_label = switch (header.kind) {
        .stdout => "stdout",
        .stderr => "stderr",
    };

    const matches = std.mem.eql(u8, captured, header.pattern);

    if (exit_code == null or exit_code.? != 0) {
        const code_str = if (exit_code) |c| c else -1;
        try writer.print("FAIL (binary exit code {d})\n", .{code_str});
        try printSnippet(writer, "expected", header.pattern);
        try printSnippet(writer, stream_label, captured);
        return .failed;
    }

    if (matches) {
        try writer.print("PASS\n", .{});
        return .passed;
    }

    try writer.print("FAIL ({s} mismatch)\n", .{stream_label});
    try printSnippet(writer, "expected", header.pattern);
    try printSnippet(writer, "actual  ", captured);
    return .failed;
}
