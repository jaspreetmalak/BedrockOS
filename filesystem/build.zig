const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const filesystem = b.addModule("filesystem", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const library = b.addLibrary(.{
        .name = "bedrock-filesystem",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/compile_check.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "filesystem", .module = filesystem }},
        }),
    });
    b.installArtifact(library);

    const check_step = b.step("check", "Compile portable block-device, RAM and durable filesystem probes");
    check_step.dependOn(&library.step);

    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = b.graph.host,
            .optimize = optimize,
        }),
    });
    const run_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run block-device, RAM and durable filesystem boundary tests");
    test_step.dependOn(&run_tests.step);
}
