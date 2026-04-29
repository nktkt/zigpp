//! Top-level build script for the Zig++ research compiler.
//!
//! Produces:
//!   - `zpp`     : CLI driver executable (root: tools/zpp.zig)
//!   - `zpp_lib` : static library exposing the compiler internals
//!                (root: compiler/root.zig)
//!   - `test`    : aggregated unit tests across the compiler modules
//!
//! Uses the Zig 0.16-style module-first build API. Executables and libraries
//! are constructed by first creating a `Module` via `b.createModule(...)` and
//! passing it as `.root_module`. The legacy `.root_source_file` shape on
//! `addExecutable` / `addStaticLibrary` is intentionally avoided.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib_module = b.createModule(.{
        .root_source_file = b.path("compiler/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib = b.addLibrary(.{
        .name = "zpp_lib",
        .root_module = lib_module,
        .linkage = .static,
    });
    b.installArtifact(lib);

    const exe_module = b.createModule(.{
        .root_source_file = b.path("tools/zpp.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_module.addImport("zpp_lib", lib_module);

    const exe = b.addExecutable(.{
        .name = "zpp",
        .root_module = exe_module,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the zpp CLI driver");
    run_step.dependOn(&run_cmd.step);

    const tests_module = b.createModule(.{
        .root_source_file = b.path("compiler/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const unit_tests = b.addTest(.{ .root_module = tests_module });
    const run_tests = b.addRunArtifact(unit_tests);

    // Runtime support library tests (lib/owned, contracts, derive, async,
    // traits, testing). Wired through lib/zpp.zig's `refAllDecls`.
    const lib_tests_module = b.createModule(.{
        .root_source_file = b.path("lib/zpp.zig"),
        .target = target,
        .optimize = optimize,
    });
    const lib_unit_tests = b.addTest(.{ .root_module = lib_tests_module });
    const run_lib_tests = b.addRunArtifact(lib_unit_tests);

    const test_step = b.step("test", "Run all Zig++ unit tests");
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(&run_lib_tests.step);

    // Integration test runner: walks tests/{compile,behavior,...} and emits
    // RUN/SKIP lines for each .zpp fixture. Not installed — it's a test driver.
    const zpp_runner_module = b.createModule(.{
        .root_source_file = b.path("tests/test_runner.zig"),
        .target = target,
        .optimize = optimize,
    });
    // Pre-wire the compiler library import so the runner can grow into a real
    // driver (e.g. lower_to_zig.lowerSource) without a build.zig change.
    zpp_runner_module.addImport("zpp_lib", lib_module);

    const zpp_runner_exe = b.addExecutable(.{
        .name = "zpp_test_runner",
        .root_module = zpp_runner_module,
    });

    const run_zpp_runner = b.addRunArtifact(zpp_runner_exe);
    // Run from the project root so `tests/<category>` paths inside the runner resolve.
    run_zpp_runner.setCwd(b.path("."));
    // Inherit stdio so the user sees RUN/SKIP lines live; also marks the step
    // as having side-effects so it always executes.
    run_zpp_runner.stdio = .inherit;

    const test_zpp_step = b.step("test-zpp", "Run Zig++ .zpp integration tests");
    test_zpp_step.dependOn(&run_zpp_runner.step);
}
