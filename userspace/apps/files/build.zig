const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const relocatable = b.option(bool, "relocatable", "Position-independent native Files client") orelse false;
    const axis = b.dependency("axisui", .{ .target = target, .optimize = optimize, .relocatable = relocatable });
    const arch = target.result.cpu.arch;
    const module = b.addModule("files_app", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .stack_protector = false,
        .stack_check = false,
        .single_threaded = true,
        .red_zone = if (arch == .x86_64) false else null,
        .pic = if (target.result.os.tag == .freestanding) relocatable else null,
        .code_model = switch (arch) {
            .x86_64 => .small,
            .riscv64 => .medium,
            else => .default,
        },
        .imports = &.{.{ .name = "axisui", .module = axis.module("axisui") }},
    });
    const artifact = b.addLibrary(.{ .name = "bedrock-files-app", .linkage = .static, .root_module = b.createModule(.{
        .root_source_file = b.path("src/compile_check.zig"),
        .target = target,
        .optimize = optimize,
        .stack_protector = false,
        .stack_check = false,
        .single_threaded = true,
        .red_zone = if (arch == .x86_64) false else null,
        .pic = module.pic,
        .code_model = module.code_model,
        .imports = &.{.{ .name = "files_app", .module = module }},
    }) });
    b.installArtifact(artifact);
    b.step("check", "Compile Files controller and both native rendering backends").dependOn(&artifact.step);
    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = b.graph.host,
        .optimize = optimize,
        .imports = &.{.{ .name = "axisui", .module = b.dependency("axisui", .{ .target = b.graph.host, .optimize = optimize, .relocatable = false }).module("axisui") }},
    }) });
    b.step("test", "Exercise provider authority, drag/drop, editing and bounded rendering").dependOn(&b.addRunArtifact(tests).step);
}
