const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zpp_mod = b.createModule(.{
        .root_source_file = b.path("../../lib/zpp.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe_module = b.createModule(.{
        .root_source_file = b.path(".zpp-out/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_module.addImport("zpp", zpp_mod);

    const exe = b.addExecutable(.{
        .name = "pipeline",
        .root_module = exe_module,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the pipeline example");
    run_step.dependOn(&run_cmd.step);
}
