const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const relocatable = b.option(bool, "relocatable", "Position-independent driver wire helpers") orelse false;
    const kit = b.dependency("networkkit", .{ .target = target, .optimize = optimize, .relocatable = relocatable });
    const module = b.addModule("ieee80211", .{ .root_source_file = b.path("root.zig"), .target = target, .optimize = optimize, .pic = if (target.result.os.tag == .freestanding) relocatable else null, .red_zone = if (target.result.cpu.arch == .x86_64) false else null, .stack_check = false, .stack_protector = false, .single_threaded = true, .code_model = if (target.result.cpu.arch == .riscv64) .medium else .small, .imports = &.{.{ .name = "networkkit", .module = kit.module("networkkit") }} });
    const artifact = b.addLibrary(.{ .name = "bedrock-ieee80211", .linkage = .static, .root_module = b.createModule(.{ .root_source_file = b.path("compile_check.zig"), .target = target, .optimize = optimize, .pic = module.pic, .red_zone = module.red_zone, .stack_check = false, .stack_protector = false, .single_threaded = true, .code_model = module.code_model, .imports = &.{.{ .name = "ieee80211", .module = module }} }) });
    b.installArtifact(artifact);
    b.step("check", "Compile wireless frame and WPA2 helpers").dependOn(&artifact.step);
    const native_kit = b.dependency("networkkit", .{ .target = b.graph.host, .optimize = optimize });
    const tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("root.zig"), .target = b.graph.host, .optimize = optimize, .imports = &.{.{ .name = "networkkit", .module = native_kit.module("networkkit") }} }) });
    b.step("test", "Run native wireless protocol tests").dependOn(&b.addRunArtifact(tests).step);
}
