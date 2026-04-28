//! Whitespace-only formatter for `.zpp` source files.
//!
//! Walks a path (file or directory), reads each `.zpp` source, runs the
//! pure-logic normalization in `compiler/fmt.zig`, and either rewrites the
//! file in place or (in `--check` mode) just reports what would change.
//!
//! Plain `.zig` files inside a Zig++ project are deferred to upstream
//! `zig fmt` and are not touched here.

const std = @import("std");

const zpp_lib = @import("zpp_lib");
const fmt_mod = zpp_lib.fmt;

/// Process every `.zpp` file reachable from `paths`. If `check_only` is
/// true, do not write anything; just report files that would change.
///
/// Returns:
///   - apply mode (check_only=false): 0 on success, 1 on any I/O error.
///   - check mode (check_only=true): 0 if all files clean and no I/O
///     errors, 1 otherwise.
pub fn run(
    allocator: std.mem.Allocator,
    paths: []const []const u8,
    check_only: bool,
) !u8 {
    var files_scanned: usize = 0;
    var files_changed: usize = 0;
    var saw_error: bool = false;

    const effective_paths: []const []const u8 = if (paths.len == 0) &.{"."} else paths;

    for (effective_paths) |path| {
        const stat = std.fs.cwd().statFile(path) catch |err| {
            std.debug.print("zpp fmt: cannot stat {s}: {s}\n", .{ path, @errorName(err) });
            saw_error = true;
            continue;
        };

        if (stat.kind == .file) {
            if (!std.mem.endsWith(u8, path, ".zpp")) continue;
            const changed = processFile(
                allocator,
                std.fs.cwd(),
                path,
                path,
                check_only,
                &files_scanned,
            ) catch |err| {
                std.debug.print(
                    "zpp fmt: failed on {s}: {s}\n",
                    .{ path, @errorName(err) },
                );
                saw_error = true;
                continue;
            };
            if (changed) files_changed += 1;
        } else if (stat.kind == .directory) {
            walkDir(
                allocator,
                path,
                check_only,
                &files_scanned,
                &files_changed,
                &saw_error,
            ) catch |err| {
                std.debug.print(
                    "zpp fmt: walk {s} failed: {s}\n",
                    .{ path, @errorName(err) },
                );
                saw_error = true;
                continue;
            };
        }
    }

    const action_label: []const u8 = if (check_only) "would-format" else "formatted";
    std.debug.print(
        "[zpp] fmt: {d}/{d} files {s}\n",
        .{ files_changed, files_scanned, action_label },
    );

    if (check_only) {
        return if (files_changed > 0 or saw_error) 1 else 0;
    } else {
        return if (saw_error) 1 else 0;
    }
}

fn walkDir(
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    check_only: bool,
    files_scanned: *usize,
    files_changed: *usize,
    saw_error: *bool,
) !void {
    var root = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
    defer root.close();

    var walker = try root.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".zpp")) continue;
        // Mirrors project.buildProject prune logic: skip generated/output
        // dirs and any dotfile-prefixed directory at any depth.
        if (std.mem.startsWith(u8, entry.path, ".zpp-out/")) continue;
        if (std.mem.startsWith(u8, entry.path, ".zpp-doc/")) continue;
        if (std.mem.startsWith(u8, entry.path, "zig-out/")) continue;
        if (std.mem.startsWith(u8, entry.path, ".zig-cache/")) continue;
        if (std.mem.startsWith(u8, entry.path, ".")) continue;
        if (std.mem.indexOf(u8, entry.path, "/.") != null) continue;
        if (std.mem.indexOf(u8, entry.path, "/zig-out/") != null) continue;
        if (std.mem.indexOf(u8, entry.path, "/.zig-cache/") != null) continue;

        const display_path = try std.fs.path.join(allocator, &.{ dir_path, entry.path });
        defer allocator.free(display_path);

        const changed = processFile(
            allocator,
            root,
            entry.path,
            display_path,
            check_only,
            files_scanned,
        ) catch |err| {
            std.debug.print(
                "zpp fmt: failed on {s}: {s}\n",
                .{ display_path, @errorName(err) },
            );
            saw_error.* = true;
            continue;
        };
        if (changed) files_changed.* += 1;
    }
}

fn processFile(
    allocator: std.mem.Allocator,
    dir: std.fs.Dir,
    rel_path: []const u8,
    display_path: []const u8,
    check_only: bool,
    files_scanned: *usize,
) !bool {
    const max_size: usize = 4 * 1024 * 1024;
    const source = try dir.readFileAlloc(allocator, rel_path, max_size);
    defer allocator.free(source);

    files_scanned.* += 1;

    const formatted = try fmt_mod.formatSource(allocator, source);
    defer allocator.free(formatted);

    if (std.mem.eql(u8, formatted, source)) return false;

    if (check_only) {
        std.debug.print("{s}: would format\n", .{display_path});
    } else {
        try dir.writeFile(.{ .sub_path = rel_path, .data = formatted });
        std.debug.print("{s}: formatted\n", .{display_path});
    }
    return true;
}
