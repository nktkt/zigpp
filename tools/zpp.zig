//! Main CLI driver for the `zpp` binary; parses argv and dispatches to
//! subcommand handlers that drive the Zig++ pipeline (parse, sema, lower,
//! and the auxiliary `fmt`, `doc`, `lsp`, `migrate` tools).

const std = @import("std");

const zpp_lib = @import("zpp_lib");
const parser = zpp_lib.parser;
const sema = zpp_lib.sema;
const lower_to_zig = zpp_lib.lower_to_zig;
const diagnostics = zpp_lib.diagnostics;
const ast = zpp_lib.ast;
const project = zpp_lib.project;
const checks = zpp_lib.checks;

const zpp_fmt = @import("zpp_fmt.zig");
const zpp_lsp = @import("zpp_lsp.zig");
const zpp_doc = @import("zpp_doc.zig");
const zpp_migrate = @import("zpp_migrate.zig");

const version_text = "zpp 0.0.1 (Zig++ Design Draft v0.1)\n";

const help_text =
    \\zpp - the Zig++ frontend compiler driver
    \\
    \\Usage:
    \\  zpp <subcommand> [args...]
    \\
    \\Subcommands:
    \\  build [path]        Compile a .zpp project (lowers .zpp -> .zig, then runs `zig build`)
    \\  run <file.zpp>      Build, then execute the resulting binary
    \\  check [path]        Run all sema checks (E0001/E0002/E0003/E0004/E0010/E0020) on a project, no codegen
    \\  lower <file.zpp>    Print the generated .zig to stdout (debug aid)
    \\  fmt [--check] [path]   Whitespace-only format .zpp files; --check reports without writing
    \\  doc [path]          Generate a Markdown project reference under <path>/.zpp-doc/
    \\  migrate [--apply] [path]   Suggest (or apply) Zig -> Zig++ rewrites under <path>
    \\  lsp                 Start a Language Server speaking LSP over stdio
    \\  version             Print the zpp version string
    \\  help, --help, -h    Print this help text
    \\
;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        try printHelp();
        std.process.exit(2);
    }

    const sub = args[1];
    const rest = args[2..];

    if (std.mem.eql(u8, sub, "version")) {
        try printVersion();
        return;
    }
    if (std.mem.eql(u8, sub, "help") or
        std.mem.eql(u8, sub, "--help") or
        std.mem.eql(u8, sub, "-h"))
    {
        try printHelp();
        return;
    }
    if (std.mem.eql(u8, sub, "build")) return cmdBuild(allocator, rest);
    if (std.mem.eql(u8, sub, "run")) return cmdRun(allocator, rest);
    if (std.mem.eql(u8, sub, "check")) return cmdCheck(allocator, rest);
    if (std.mem.eql(u8, sub, "lower")) return cmdLower(allocator, rest);
    if (std.mem.eql(u8, sub, "fmt")) return cmdFmt(allocator, rest);
    if (std.mem.eql(u8, sub, "doc")) return cmdDoc(allocator, rest);
    if (std.mem.eql(u8, sub, "migrate")) return cmdMigrate(allocator, rest);
    if (std.mem.eql(u8, sub, "lsp")) return cmdLsp(allocator, rest);

    try printHelp();
    std.process.exit(2);
}

// TODO: switch to stdout writer once API stabilizes
fn printVersion() !void {
    std.debug.print("{s}", .{version_text});
}

// TODO: switch to stdout writer once API stabilizes
fn printHelp() !void {
    std.debug.print("{s}", .{help_text});
}

fn cmdBuild(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const dir_path: []const u8 = if (args.len == 0) "." else args[0];

    // Resolve the argument: must exist and must be a directory.
    const stat = std.fs.cwd().statFile(dir_path) catch |err| switch (err) {
        error.FileNotFound => {
            // TODO: switch to stderr writer once API stabilizes
            std.debug.print("zpp build: no such directory: {s}\n", .{dir_path});
            std.process.exit(2);
        },
        else => return err,
    };
    if (stat.kind != .directory) {
        // TODO: switch to stderr writer once API stabilizes
        std.debug.print("zpp build: expected a directory, got file: {s}\n", .{dir_path});
        std.process.exit(2);
    }

    const result = try project.buildProject(allocator, dir_path);
    defer allocator.free(result.out_dir);

    // TODO: switch to stderr writer once API stabilizes
    std.debug.print(
        "[zpp] lowered {d} files to {s}/\n",
        .{ result.lowered, result.out_dir },
    );

    if (result.failed > 0) std.process.exit(1);
}

fn cmdRun(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const dir_path: []const u8 = if (args.len == 0) "." else args[0];

    // Resolve the argument: must exist and must be a directory.
    const stat = std.fs.cwd().statFile(dir_path) catch |err| switch (err) {
        error.FileNotFound => {
            // TODO: switch to stderr writer once API stabilizes
            std.debug.print("zpp run: no such directory: {s}\n", .{dir_path});
            std.process.exit(2);
        },
        else => return err,
    };
    if (stat.kind != .directory) {
        // TODO: switch to stderr writer once API stabilizes
        std.debug.print("zpp run: expected a directory, got file: {s}\n", .{dir_path});
        std.process.exit(2);
    }

    const result = try project.buildProject(allocator, dir_path);
    defer allocator.free(result.out_dir);

    // TODO: switch to stderr writer once API stabilizes
    std.debug.print(
        "[zpp] lowered {d} files to {s}/\n",
        .{ result.lowered, result.out_dir },
    );

    if (result.failed > 0) std.process.exit(1);

    // TODO: switch to stderr writer once API stabilizes
    std.debug.print("[zpp] running `zig build run` in {s}\n", .{dir_path});

    var child = std.process.Child.init(&.{ "zig", "build", "run" }, allocator);
    child.cwd = dir_path;
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    const term = try child.spawnAndWait();
    switch (term) {
        .Exited => |code| std.process.exit(code),
        else => std.process.exit(1),
    }
}

fn cmdCheck(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const dir_path: []const u8 = if (args.len == 0) "." else args[0];

    const stat = std.fs.cwd().statFile(dir_path) catch |err| switch (err) {
        error.FileNotFound => {
            // TODO: switch to stderr writer once API stabilizes
            std.debug.print("zpp check: no such directory: {s}\n", .{dir_path});
            std.process.exit(2);
        },
        else => return err,
    };
    if (stat.kind != .directory) {
        // TODO: switch to stderr writer once API stabilizes
        std.debug.print("zpp check: expected a directory, got file: {s}\n", .{dir_path});
        std.process.exit(2);
    }

    var root = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
    defer root.close();

    var walker = try root.walk(allocator);
    defer walker.deinit();

    var checked: usize = 0;
    var total_findings: usize = 0;
    const max_size: usize = 1 * 1024 * 1024;

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".zpp")) continue;
        // Skip generated output and dotfile dirs (mirrors project.buildProject prune logic).
        if (std.mem.startsWith(u8, entry.path, ".zpp-out/")) continue;
        if (std.mem.indexOf(u8, entry.path, "/.")) |_| continue;
        if (std.mem.startsWith(u8, entry.path, ".")) continue;

        const file_path = try std.fs.path.join(allocator, &.{ dir_path, entry.path });
        defer allocator.free(file_path);

        const source = root.readFileAlloc(allocator, entry.path, max_size) catch |err| {
            std.debug.print("{s}: read failed: {s}\n", .{ file_path, @errorName(err) });
            total_findings += 1;
            continue;
        };
        defer allocator.free(source);

        checked += 1;

        const own_findings = try checks.checkOwnership(allocator, source);
        defer allocator.free(own_findings);
        const move_findings = try checks.checkUseAfterMove(allocator, source);
        defer allocator.free(move_findings);
        const double_findings = try checks.checkDoubleDeinit(allocator, source);
        defer allocator.free(double_findings);
        const mismatch_findings = try checks.checkAllocatorMismatch(allocator, source);
        defer allocator.free(mismatch_findings);
        const noalloc_findings = try checks.checkNoAlloc(allocator, source);
        defer allocator.free(noalloc_findings);
        const trait_findings = try checks.checkTraitImpl(allocator, source);
        defer allocator.free(trait_findings);

        for (own_findings) |f| try printFinding(file_path, f);
        for (move_findings) |f| try printFinding(file_path, f);
        for (double_findings) |f| try printFinding(file_path, f);
        for (mismatch_findings) |f| try printFinding(file_path, f);
        for (noalloc_findings) |f| try printFinding(file_path, f);
        for (trait_findings) |f| try printFinding(file_path, f);

        total_findings += own_findings.len + move_findings.len + double_findings.len + mismatch_findings.len + noalloc_findings.len + trait_findings.len;
    }

    // TODO: switch to stderr writer once API stabilizes
    std.debug.print(
        "[zpp] checked {d} files, {d} findings\n",
        .{ checked, total_findings },
    );

    if (total_findings > 0) std.process.exit(1);
}

// TODO: switch to stdout writer once API stabilizes
fn printFinding(file_path: []const u8, f: checks.Finding) !void {
    std.debug.print(
        "{s}:{d}:{d}: {s} {s}\n",
        .{ file_path, f.line, f.col, f.code, f.message },
    );
}

fn cmdLower(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len < 1) {
        // TODO: switch to stderr writer once API stabilizes
        std.debug.print("zpp lower: missing <file.zpp> argument\n", .{});
        std.process.exit(2);
    }

    const path = args[0];
    const max_size: usize = 1 * 1024 * 1024;
    const source = try std.fs.cwd().readFileAlloc(allocator, path, max_size);
    defer allocator.free(source);

    const lowered = try lower_to_zig.lowerSource(allocator, source);
    defer allocator.free(lowered);

    // TODO: switch to stdout writer once API stabilizes
    std.debug.print("{s}", .{lowered});
}

fn cmdFmt(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var check_only = false;
    var path: []const u8 = ".";
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--check")) {
            check_only = true;
        } else {
            path = args[i];
        }
    }
    const code = try zpp_fmt.run(allocator, &.{path}, check_only);
    std.process.exit(code);
}

fn cmdDoc(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const dir_path: []const u8 = if (args.len == 0) "." else args[0];

    const stat = std.fs.cwd().statFile(dir_path) catch |err| switch (err) {
        error.FileNotFound => {
            // TODO: switch to stderr writer once API stabilizes
            std.debug.print("zpp doc: no such directory: {s}\n", .{dir_path});
            std.process.exit(2);
        },
        else => return err,
    };
    if (stat.kind != .directory) {
        // TODO: switch to stderr writer once API stabilizes
        std.debug.print("zpp doc: expected a directory, got file: {s}\n", .{dir_path});
        std.process.exit(2);
    }

    const out_dir = try std.fs.path.join(allocator, &.{ dir_path, ".zpp-doc" });
    defer allocator.free(out_dir);

    try zpp_doc.run(allocator, dir_path, out_dir);
}

fn cmdMigrate(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var dry_run = true;
    var path: []const u8 = ".";
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--apply")) {
            dry_run = false;
        } else {
            path = args[i];
        }
    }
    const code = try zpp_migrate.run(allocator, &.{path}, dry_run);
    std.process.exit(code);
}

fn cmdLsp(allocator: std.mem.Allocator, args: []const []const u8) !void {
    _ = args;
    try zpp_lsp.run(allocator);
}
