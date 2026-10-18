const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const relocatable = b.option(bool, "relocatable", "Position-independent freestanding graphics backend") orelse false;
    const api = b.dependency("anvil", .{ .target = target, .optimize = optimize, .relocatable = relocatable });
    const arch = target.result.cpu.arch;
    const module = b.addModule("anvil_core", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .pic = if (target.result.os.tag == .freestanding) relocatable else null,
        .red_zone = if (arch == .x86_64) false else null,
        .stack_check = false,
        .stack_protector = false,
        .single_threaded = true,
        .code_model = switch (arch) {
            .x86_64 => .small,
            .riscv64 => .medium,
            else => .default,
        },
        .imports = &.{.{ .name = "anvil", .module = api.module("anvil") }},
    });
    const artifact = b.addLibrary(.{
        .name = "bedrock-anvil-core",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/compile_check.zig"),
            .target = target,
            .optimize = optimize,
            .pic = module.pic,
            .red_zone = module.red_zone,
            .stack_check = false,
            .stack_protector = false,
            .single_threaded = true,
            .code_model = module.code_model,
            .imports = &.{.{ .name = "anvil_core", .module = module }},
        }),
    });
    b.installArtifact(artifact);
    b.step("check", "Compile the private Anvil CPU graphics backend").dependOn(&artifact.step);
    const native_api = b.dependency("anvil", .{ .target = b.graph.host, .optimize = optimize });
    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = b.graph.host,
        .optimize = optimize,
        .imports = &.{.{ .name = "anvil", .module = native_api.module("anvil") }},
    }) });
    b.step("test", "Test Anvil CPU commands, resource lifetime and fences").dependOn(&b.addRunArtifact(tests).step);
}
