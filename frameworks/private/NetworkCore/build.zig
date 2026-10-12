const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const relocatable = b.option(bool, "relocatable", "Position-independent freestanding stack") orelse false;
    const kit = b.dependency("networkkit", .{ .target = target, .optimize = optimize, .relocatable = relocatable });
    const arch = target.result.cpu.arch;
    const module = b.addModule("network_core", .{ .root_source_file = b.path("src/root.zig"), .target = target, .optimize = optimize, .pic = if (target.result.os.tag == .freestanding) relocatable else null, .red_zone = if (arch == .x86_64) false else null, .stack_check = false, .stack_protector = false, .single_threaded = true, .code_model = switch (arch) {
        .x86_64 => .small,
        .riscv64 => .medium,
        else => .default,
    }, .imports = &.{.{ .name = "networkkit", .module = kit.module("networkkit") }} });
    const artifact = b.addLibrary(.{ .name = "bedrock-network-core", .linkage = .static, .root_module = b.createModule(.{ .root_source_file = b.path("src/compile_check.zig"), .target = target, .optimize = optimize, .pic = module.pic, .red_zone = module.red_zone, .stack_check = false, .stack_protector = false, .single_threaded = true, .code_model = module.code_model, .imports = &.{.{ .name = "network_core", .module = module }} }) });
    b.installArtifact(artifact);
    b.step("check", "Compile the private packet stack").dependOn(&artifact.step);
    const native_kit = b.dependency("networkkit", .{ .target = b.graph.host, .optimize = optimize });
    const tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("src/root.zig"), .target = b.graph.host, .optimize = optimize, .imports = &.{.{ .name = "networkkit", .module = native_kit.module("networkkit") }} }) });
    b.step("test", "Run native packet and endpoint tests").dependOn(&b.addRunArtifact(tests).step);
}
