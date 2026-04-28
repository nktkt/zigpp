//! Migration helper that rewrites idiomatic Zig source into Zig++. Walks a
//! directory of `.zig` files, applies the line-based pattern matchers in
//! `compiler/migrate.zig`, and either prints suggestions (dry run) or
//! rewrites files in place (`--apply`).

const std = @import("std");

const zpp_lib = @import("zpp_lib");
const migrate = zpp_lib.migrate;

/// Process every `.zig` file reachable from `paths`. If `dry_run` is true,
/// print suggestions to stderr. Otherwise rewrite files in place. Returns 0
/// on success, 1 if any I/O error happened.
pub fn run(
    allocator: std.mem.Allocator,
    paths: []const []const u8,
    dry_run: bool,
) !u8 {
    var total_suggestions: usize = 0;
    var files_with_changes: usize = 0;
    var files_scanned: usize = 0;
    var saw_error: bool = false;

    const effective_paths: []const []const u8 = if (paths.len == 0) &.{"."} else paths;

    for (effective_paths) |path| {
        const stat = std.fs.cwd().statFile(path) catch |err| {
            std.debug.print("zpp migrate: cannot stat {s}: {s}\n", .{ path, @errorName(err) });
            saw_error = true;
            continue;
        };

        if (stat.kind == .file) {
            if (!std.mem.endsWith(u8, path, ".zig")) continue;
            const had_changes = processFile(
                allocator,
                std.fs.cwd(),
                path,
                path,
                dry_run,
                &total_suggestions,
                &files_scanned,
            ) catch |err| {
                std.debug.print(
                    "zpp migrate: failed on {s}: {s}\n",
                    .{ path, @errorName(err) },
                );
                saw_error = true;
                continue;
            };
            if (had_changes) files_with_changes += 1;
        } else if (stat.kind == .directory) {
            walkDir(
                allocator,
                path,
                dry_run,
                &total_suggestions,
                &files_with_changes,
                &files_scanned,
                &saw_error,
            ) catch |err| {
                std.debug.print(
                    "zpp migrate: walk {s} failed: {s}\n",
                    .{ path, @errorName(err) },
                );
                saw_error = true;
                continue;
            };
        }
    }

    const mode_label: []const u8 = if (dry_run) "dry-run" else "applied";
    std.debug.print(
        "[zpp] migrate: {d} suggestion(s) across {d}/{d} files ({s})\n",
        .{ total_suggestions, files_with_changes, files_scanned, mode_label },
    );

    return if (saw_error) 1 else 0;
}

fn walkDir(
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    dry_run: bool,
    total_suggestions: *usize,
    files_with_changes: *usize,
    files_scanned: *usize,
    saw_error: *bool,
) !void {
    var root = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
    defer root.close();

    var walker = try root.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;
        // Mirrors project.buildProject prune logic: skip generated/output dirs
        // and any dotfile-prefixed directory at any depth.
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

        const had_changes = processFileInDir(
            allocator,
            root,
            entry.path,
            display_path,
            dry_run,
            total_suggestions,
            files_scanned,
        ) catch |err| {
            std.debug.print(
                "zpp migrate: failed on {s}: {s}\n",
                .{ display_path, @errorName(err) },
            );
            saw_error.* = true;
            continue;
        };
        if (had_changes) files_with_changes.* += 1;
    }
}

fn processFile(
    allocator: std.mem.Allocator,
    dir: std.fs.Dir,
    rel_path: []const u8,
    display_path: []const u8,
    dry_run: bool,
    total_suggestions: *usize,
    files_scanned: *usize,
) !bool {
    return processFileImpl(
        allocator,
        dir,
        rel_path,
        display_path,
        dry_run,
        total_suggestions,
        files_scanned,
    );
}

fn processFileInDir(
    allocator: std.mem.Allocator,
    dir: std.fs.Dir,
    rel_path: []const u8,
    display_path: []const u8,
    dry_run: bool,
    total_suggestions: *usize,
    files_scanned: *usize,
) !bool {
    return processFileImpl(
        allocator,
        dir,
        rel_path,
        display_path,
        dry_run,
        total_suggestions,
        files_scanned,
    );
}

fn processFileImpl(
    allocator: std.mem.Allocator,
    dir: std.fs.Dir,
    rel_path: []const u8,
    display_path: []const u8,
    dry_run: bool,
    total_suggestions: *usize,
    files_scanned: *usize,
) !bool {
    const max_size: usize = 4 * 1024 * 1024;
    const source = try dir.readFileAlloc(allocator, rel_path, max_size);
    defer allocator.free(source);

    files_scanned.* += 1;

    const sugs = try migrate.analyze(allocator, source);
    defer migrate.freeSuggestions(allocator, sugs);

    if (sugs.len == 0) return false;
    total_suggestions.* += sugs.len;

    if (dry_run) {
        for (sugs) |s| {
            std.debug.print(
                "{s}:{d}: defer-deinit -> using\n",
                .{ display_path, s.var_line },
            );
            const before = source[s.start..s.end];
            // Print the original two lines as the "before" diff.
            std.debug.print("  - before:\n", .{});
            printIndented(before);
            std.debug.print("  + after:\n", .{});
            std.debug.print("      {s}\n", .{s.replacement});
        }
    } else {
        const rewritten = try migrate.applyAll(allocator, source, sugs);
        defer allocator.free(rewritten);

        try dir.writeFile(.{ .sub_path = rel_path, .data = rewritten });
        std.debug.print(
            "{s}: applied {d} rewrite(s)\n",
            .{ display_path, sugs.len },
        );
    }

    return true;
}

fn printIndented(text: []const u8) void {
    var i: usize = 0;
    while (i < text.len) {
        const start = i;
        while (i < text.len and text[i] != '\n') : (i += 1) {}
        std.debug.print("      {s}\n", .{text[start..i]});
        if (i < text.len) i += 1;
    }
}
