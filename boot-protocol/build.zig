const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const protocol = b.addModule("boot_protocol", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const probe = b.addLibrary(.{
        .name = "bedrock-boot-protocol",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/compile_check.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "boot_protocol", .module = protocol }},
        }),
    });
    b.installArtifact(probe);

    const check = b.step("check", "Compile the boot protocol probe without running it");
    check.dependOn(&probe.step);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = b.graph.host,
            .optimize = optimize,
        }),
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run native boot protocol unit tests");
    test_step.dependOn(&run_tests.step);
}
