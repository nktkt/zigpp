//! Documentation generator for Zig++ projects. Walks a project root, extracts
//! every `trait`, `extern interface`, `effects(...)`-annotated function, and
//! `derive(.{...})` postfix declaration, and emits a single Markdown reference
//! at `<out_dir>/REFERENCE.md`.

const std = @import("std");

const zpp_lib = @import("zpp_lib");
const doc_extract = zpp_lib.doc_extract;

const max_source_size: usize = 1 * 1024 * 1024;
const out_dir_name = ".zpp-out";

/// Per-file aggregation: we keep a separate copy of each declaration tagged
/// with the relative path so the Markdown writer can emit `file:line` anchors
/// in deterministic, sorted order.
const TraitEntry = struct {
    file: []u8,
    decl: doc_extract.TraitDecl,
    methods_owned: []doc_extract.TraitMethod,
};

const EffectsEntry = struct {
    file: []u8,
    ann: doc_extract.EffectsAnnotation,
};

const DeriveEntry = struct {
    file: []u8,
    decl: doc_extract.DeriveDecl,
    traits_owned: [][]const u8,
};

pub fn run(
    allocator: std.mem.Allocator,
    root: []const u8,
    out_dir: []const u8,
) !void {
    // Validate root.
    const stat = std.fs.cwd().statFile(root) catch |err| switch (err) {
        error.FileNotFound => {
            std.debug.print("zpp doc: no such directory: {s}\n", .{root});
            std.process.exit(2);
        },
        else => return err,
    };
    if (stat.kind != .directory) {
        std.debug.print("zpp doc: expected a directory, got file: {s}\n", .{root});
        std.process.exit(2);
    }

    // Make sure the output directory exists.
    try std.fs.cwd().makePath(out_dir);

    var root_dir = try std.fs.cwd().openDir(root, .{ .iterate = true });
    defer root_dir.close();

    // We accumulate per-file copies so the source buffers can be freed as we
    // go. Each entry owns its own duplicated strings and inner arrays.
    var traits = std.ArrayList(TraitEntry){};
    defer {
        for (traits.items) |*e| {
            allocator.free(e.file);
            for (e.methods_owned) |m| {
                allocator.free(@constCast(m.name));
                allocator.free(@constCast(m.params));
                allocator.free(@constCast(m.return_type));
            }
            allocator.free(e.methods_owned);
            allocator.free(@constCast(e.decl.name));
        }
        traits.deinit(allocator);
    }
    var effects_list = std.ArrayList(EffectsEntry){};
    defer {
        for (effects_list.items) |*e| {
            allocator.free(e.file);
            allocator.free(@constCast(e.ann.effects));
            if (e.ann.fn_name) |fn_name| allocator.free(@constCast(fn_name));
        }
        effects_list.deinit(allocator);
    }
    var derives = std.ArrayList(DeriveEntry){};
    defer {
        for (derives.items) |*e| {
            allocator.free(e.file);
            for (e.traits_owned) |t| allocator.free(@constCast(t));
            allocator.free(e.traits_owned);
            if (e.decl.struct_name) |sn| allocator.free(@constCast(sn));
        }
        derives.deinit(allocator);
    }

    var file_count: usize = 0;
    var walker = try root_dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".zpp")) continue;
        if (std.mem.startsWith(u8, entry.path, out_dir_name ++ "/")) continue;
        if (std.mem.startsWith(u8, entry.path, ".zpp-doc/")) continue;
        if (std.mem.startsWith(u8, entry.path, ".")) continue;
        if (std.mem.indexOf(u8, entry.path, "/.") != null) continue;

        const source = root_dir.readFileAlloc(allocator, entry.path, max_source_size) catch |err| {
            std.debug.print("zpp doc: skipping {s}: {s}\n", .{ entry.path, @errorName(err) });
            continue;
        };
        defer allocator.free(source);
        file_count += 1;

        const e = try doc_extract.extract(allocator, source);
        defer doc_extract.freeExtracted(allocator, e);

        // Duplicate every string slice — they currently point into the
        // about-to-be-freed source buffer.
        for (e.traits) |trait| {
            const methods_copy = try allocator.alloc(doc_extract.TraitMethod, trait.methods.len);
            for (trait.methods, 0..) |m, idx| {
                methods_copy[idx] = .{
                    .name = try allocator.dupe(u8, m.name),
                    .params = try allocator.dupe(u8, m.params),
                    .return_type = try allocator.dupe(u8, m.return_type),
                };
            }
            try traits.append(allocator, .{
                .file = try allocator.dupe(u8, entry.path),
                .decl = .{
                    .name = try allocator.dupe(u8, trait.name),
                    .is_extern = trait.is_extern,
                    .methods = &.{},
                    .line = trait.line,
                },
                .methods_owned = methods_copy,
            });
        }
        for (e.effects) |ann| {
            const fn_dup: ?[]const u8 = if (ann.fn_name) |fn_name| try allocator.dupe(u8, fn_name) else null;
            try effects_list.append(allocator, .{
                .file = try allocator.dupe(u8, entry.path),
                .ann = .{
                    .effects = try allocator.dupe(u8, ann.effects),
                    .fn_name = fn_dup,
                    .line = ann.line,
                },
            });
        }
        for (e.derives) |d| {
            const traits_copy = try allocator.alloc([]const u8, d.traits.len);
            for (d.traits, 0..) |tn, idx| traits_copy[idx] = try allocator.dupe(u8, tn);
            const sn_dup: ?[]const u8 = if (d.struct_name) |sn| try allocator.dupe(u8, sn) else null;
            try derives.append(allocator, .{
                .file = try allocator.dupe(u8, entry.path),
                .decl = .{
                    .struct_name = sn_dup,
                    .traits = &.{},
                    .line = d.line,
                },
                .traits_owned = traits_copy,
            });
        }
    }

    // Sort traits and extern interfaces alphabetically by name.
    std.sort.pdq(TraitEntry, traits.items, {}, traitLessThan);

    // Build markdown.
    var md = std.ArrayList(u8){};
    defer md.deinit(allocator);

    try md.appendSlice(allocator, "# Zig++ Project Reference\n\n");
    try std.fmt.format(md.writer(allocator), "Generated by `zpp doc` from {d} file(s) under `{s}`.\n\n", .{ file_count, root });

    // Partition traits into bare-trait vs extern interface.
    var bare_count: usize = 0;
    var extern_count: usize = 0;
    for (traits.items) |t| {
        if (t.decl.is_extern) extern_count += 1 else bare_count += 1;
    }

    if (bare_count > 0) {
        try md.appendSlice(allocator, "## Traits\n\n");
        for (traits.items) |t| {
            if (t.decl.is_extern) continue;
            try writeTraitSection(allocator, &md, t);
        }
    }
    if (extern_count > 0) {
        try md.appendSlice(allocator, "## Extern Interfaces\n\n");
        for (traits.items) |t| {
            if (!t.decl.is_extern) continue;
            try writeTraitSection(allocator, &md, t);
        }
    }

    if (effects_list.items.len > 0) {
        try md.appendSlice(allocator, "## Effect-Annotated Functions\n\n");
        try md.appendSlice(allocator, "| Function | File | Effects |\n| --- | --- | --- |\n");
        for (effects_list.items) |e| {
            const fn_label: []const u8 = if (e.ann.fn_name) |fn_name| fn_name else "?";
            try std.fmt.format(md.writer(allocator), "| `{s}` | `{s}:{d}` | `{s}` |\n", .{ fn_label, e.file, e.ann.line, e.ann.effects });
        }
        try md.append(allocator, '\n');
    }

    if (derives.items.len > 0) {
        try md.appendSlice(allocator, "## Derived Structs\n\n");
        try md.appendSlice(allocator, "| Struct | File | Traits |\n| --- | --- | --- |\n");
        for (derives.items) |d| {
            const sn_label: []const u8 = if (d.decl.struct_name) |sn| sn else "?";
            try std.fmt.format(md.writer(allocator), "| `{s}` | `{s}:{d}` | ", .{ sn_label, d.file, d.decl.line });
            for (d.traits_owned, 0..) |tn, idx| {
                if (idx > 0) try md.appendSlice(allocator, ", ");
                try md.append(allocator, '`');
                try md.appendSlice(allocator, tn);
                try md.append(allocator, '`');
            }
            try md.appendSlice(allocator, " |\n");
        }
        try md.append(allocator, '\n');
    }

    if (traits.items.len == 0 and effects_list.items.len == 0 and derives.items.len == 0) {
        try md.appendSlice(allocator, "_No declarations found._\n");
    }

    // Write file.
    const out_path = try std.fs.path.join(allocator, &.{ out_dir, "REFERENCE.md" });
    defer allocator.free(out_path);
    try std.fs.cwd().writeFile(.{ .sub_path = out_path, .data = md.items });

    std.debug.print("[zpp] wrote {d} bytes to {s}\n", .{ md.items.len, out_path });
}

fn traitLessThan(_: void, a: TraitEntry, b: TraitEntry) bool {
    return std.mem.lessThan(u8, a.decl.name, b.decl.name);
}

fn writeTraitSection(
    allocator: std.mem.Allocator,
    md: *std.ArrayList(u8),
    t: TraitEntry,
) !void {
    try std.fmt.format(md.writer(allocator), "### `{s}` ([`{s}:{d}`]({s}))\n", .{ t.decl.name, t.file, t.decl.line, t.file });
    if (t.methods_owned.len == 0) {
        try md.appendSlice(allocator, "- _(no methods)_\n");
    } else {
        for (t.methods_owned) |m| {
            try std.fmt.format(md.writer(allocator), "- `{s}({s}) {s}`\n", .{ m.name, m.params, m.return_type });
        }
    }
    try md.append(allocator, '\n');
}
