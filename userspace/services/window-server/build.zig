const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const relocatable = b.option(bool, "relocatable", "Position-independent window policy") orelse false;
    const header = b.addModule("window_header", .{
        .root_source_file = b.path("src/header.zig"),
        .target = target,
        .optimize = optimize,
        .stack_protector = false,
        .stack_check = false,
        .single_threaded = true,
        .red_zone = if (target.result.cpu.arch == .x86_64) false else null,
        .pic = if (target.result.os.tag == .freestanding) relocatable else null,
        .code_model = if (target.result.cpu.arch == .riscv64) .medium else .small,
    });
    const module = b.addModule("window_server", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .stack_protector = false,
        .stack_check = false,
        .single_threaded = true,
        .red_zone = if (target.result.cpu.arch == .x86_64) false else null,
        .pic = if (target.result.os.tag == .freestanding) relocatable else null,
        .code_model = if (target.result.cpu.arch == .riscv64) .medium else .small,
        .imports = &.{.{ .name = "axisui", .module = b.dependency("axisui", .{ .target = target, .optimize = optimize, .relocatable = relocatable }).module("axisui") }},
    });
    module.addImport("window_header", header);
    const tests = b.addTest(.{ .root_module = module });
    b.step("test", "Check window controls, geometry, capture and client routing").dependOn(&b.addRunArtifact(tests).step);
}
