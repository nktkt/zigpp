//! Project-level pipeline: walk a Zig++ project root, lower every .zpp
//! source to .zig under <root>/.zpp-out/, mirroring the source layout.

const std = @import("std");
const lower_to_zig = @import("lower_to_zig.zig");

/// Maximum size of a single .zpp source file we'll attempt to lower. Matches
/// the limit used by `cmdLower` in tools/zpp.zig.
const max_source_size: usize = 1 * 1024 * 1024;

/// Name of the output directory created beneath the project root. We refuse
/// to recurse into this directory while walking, which is what makes `zpp
/// build` idempotent (re-running over an existing tree does not re-lower
/// already-generated artifacts).
const out_dir_name = ".zpp-out";

pub const BuildResult = struct {
    lowered: usize,
    failed: usize,
    /// Heap-allocated; caller frees with the same allocator passed to
    /// `buildProject`.
    out_dir: []const u8,
};

/// Walk `root_dir` recursively, lower every `*.zpp` source to `*.zig`, and
/// write the result to `<root_dir>/.zpp-out/<relpath>.zig`. Continues past
/// per-file errors, accumulating a count in `BuildResult.failed`.
pub fn buildProject(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
) !BuildResult {
    // Open the root for iteration. `walk` requires `iterate = true`.
    var root = try std.fs.cwd().openDir(root_dir, .{ .iterate = true });
    defer root.close();

    // Make sure `.zpp-out/` exists up front so we can open it as the write
    // destination once and reuse the handle for every file.
    try root.makePath(out_dir_name);
    var out_root = try root.openDir(out_dir_name, .{});
    defer out_root.close();

    var lowered: usize = 0;
    var failed: usize = 0;

    var walker = try root.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".zpp")) continue;

        // Pruning approach: the std.fs.Walker has no prune hook, so we filter
        // entries by path prefix. Skip anything inside `.zpp-out/` (we don't
        // want to re-lower our own output) or any dotfile-prefixed dir like
        // `.zig-cache` / `.git`. Walker emits POSIX-style paths with '/' as
        // the separator on all platforms in practice (the macOS/Linux runtime
        // uses '/'); we match against that. A "/." substring catches nested
        // dotfile directories at any depth.
        if (std.mem.startsWith(u8, entry.path, out_dir_name ++ "/")) continue;
        if (std.mem.startsWith(u8, entry.path, ".")) continue;
        if (std.mem.indexOf(u8, entry.path, "/.") != null) continue;

        processOneFile(allocator, root, out_root, entry.path) catch |err| {
            // TODO: switch to stderr writer once API stabilizes
            std.debug.print(
                "[zpp] failed to lower {s}: {s}\n",
                .{ entry.path, @errorName(err) },
            );
            failed += 1;
            continue;
        };
        lowered += 1;
    }

    const out_dir_path = try std.fs.path.join(allocator, &.{ root_dir, out_dir_name });

    return .{
        .lowered = lowered,
        .failed = failed,
        .out_dir = out_dir_path,
    };
}

/// Read one .zpp file, lower it, write the result to the parallel location
/// under the output dir. Errors propagate; the caller decides whether to
/// continue or abort.
fn processOneFile(
    allocator: std.mem.Allocator,
    root: std.fs.Dir,
    out_root: std.fs.Dir,
    rel_path: []const u8,
) !void {
    const source = try root.readFileAlloc(allocator, rel_path, max_source_size);
    defer allocator.free(source);

    const lowered = try lower_to_zig.lowerSource(allocator, source);
    defer allocator.free(lowered);

    // Compute the output path: same relative path, but with `.zpp` swapped for
    // `.zig`. The slice ends with ".zpp" (we checked endsWith above), so the
    // arithmetic is safe.
    const stem = rel_path[0 .. rel_path.len - ".zpp".len];
    const out_rel = try std.mem.concat(allocator, u8, &.{ stem, ".zig" });
    defer allocator.free(out_rel);

    // Ensure the parent directory of the output exists. Walker paths use '/'
    // separators; std.fs.path.dirname understands that on POSIX, and on
    // Windows the Walker still writes '\' — but this project targets the
    // host's native separator either way via std.fs.path.dirname.
    if (std.fs.path.dirname(out_rel)) |parent| {
        try out_root.makePath(parent);
    }

    try out_root.writeFile(.{ .sub_path = out_rel, .data = lowered });
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// Helper: get an absolute path string for a TmpDir so we can pass it to
/// buildProject (which takes a path relative to cwd / absolute path).
fn tmpAbsPath(allocator: std.mem.Allocator, tmp: *std.testing.TmpDir) ![]u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const real = try tmp.dir.realpath(".", &buf);
    return allocator.dupe(u8, real);
}

test "buildProject: single .zpp file is lowered" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "main.zpp",
        .data = "using x = init();\n",
    });

    const allocator = testing.allocator;
    const root_path = try tmpAbsPath(allocator, &tmp);
    defer allocator.free(root_path);

    const result = try buildProject(allocator, root_path);
    defer allocator.free(result.out_dir);

    try testing.expectEqual(@as(usize, 1), result.lowered);
    try testing.expectEqual(@as(usize, 0), result.failed);

    const out = try tmp.dir.readFileAlloc(allocator, ".zpp-out/main.zig", 1 << 20);
    defer allocator.free(out);
    try testing.expectEqualStrings("var x = init(); defer x.deinit();\n", out);
}

test "buildProject: nested subdir structure is mirrored under .zpp-out" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.makePath("sub/inner");
    try tmp.dir.writeFile(.{
        .sub_path = "sub/inner/deep.zpp",
        .data = "using y = make();\n",
    });

    const allocator = testing.allocator;
    const root_path = try tmpAbsPath(allocator, &tmp);
    defer allocator.free(root_path);

    const result = try buildProject(allocator, root_path);
    defer allocator.free(result.out_dir);

    try testing.expectEqual(@as(usize, 1), result.lowered);

    const out = try tmp.dir.readFileAlloc(allocator, ".zpp-out/sub/inner/deep.zig", 1 << 20);
    defer allocator.free(out);
    try testing.expectEqualStrings("var y = make(); defer y.deinit();\n", out);
}

test "buildProject: non-.zpp files are ignored" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "keep.zig",
        .data = "// not a .zpp\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "real.zpp",
        .data = "var z = 0;\n",
    });

    const allocator = testing.allocator;
    const root_path = try tmpAbsPath(allocator, &tmp);
    defer allocator.free(root_path);

    const result = try buildProject(allocator, root_path);
    defer allocator.free(result.out_dir);

    try testing.expectEqual(@as(usize, 1), result.lowered);

    // The .zig source must not have been mirrored into .zpp-out/.
    const probe = tmp.dir.openFile(".zpp-out/keep.zig", .{});
    try testing.expectError(error.FileNotFound, probe);
}

test "buildProject: count matches number of .zpp files" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "a.zpp", .data = "var a = 0;\n" });
    try tmp.dir.writeFile(.{ .sub_path = "b.zpp", .data = "var b = 0;\n" });
    try tmp.dir.makePath("nested");
    try tmp.dir.writeFile(.{ .sub_path = "nested/c.zpp", .data = "var c = 0;\n" });

    const allocator = testing.allocator;
    const root_path = try tmpAbsPath(allocator, &tmp);
    defer allocator.free(root_path);

    const result = try buildProject(allocator, root_path);
    defer allocator.free(result.out_dir);

    try testing.expectEqual(@as(usize, 3), result.lowered);
    try testing.expectEqual(@as(usize, 0), result.failed);
}

test "buildProject: .zpp-out is not re-traversed" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    // Pre-seed a stale .zpp-out/ with a file that, if walked, would be
    // counted; buildProject must skip it.
    try tmp.dir.makePath(".zpp-out");
    try tmp.dir.writeFile(.{
        .sub_path = ".zpp-out/already.zpp",
        .data = "var stale = 0;\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "live.zpp",
        .data = "var live = 0;\n",
    });

    const allocator = testing.allocator;
    const root_path = try tmpAbsPath(allocator, &tmp);
    defer allocator.free(root_path);

    const result = try buildProject(allocator, root_path);
    defer allocator.free(result.out_dir);

    // Only live.zpp should have been lowered.
    try testing.expectEqual(@as(usize, 1), result.lowered);
}
