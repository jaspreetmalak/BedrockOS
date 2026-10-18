const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const relocatable = b.option(bool, "relocatable", "Position-independent freestanding graphics API") orelse false;
    const arch = target.result.cpu.arch;
    const module = b.addModule("anvil", .{
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
    });
    const artifact = b.addLibrary(.{
        .name = "bedrock-anvil",
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
            .imports = &.{.{ .name = "anvil", .module = module }},
        }),
    });
    b.installArtifact(artifact);
    b.step("check", "Compile the Anvil graphics provider interface").dependOn(&artifact.step);
    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    }) });
    b.step("test", "Exercise bounded graphics batches and fence lifecycle").dependOn(&b.addRunArtifact(tests).step);
}
