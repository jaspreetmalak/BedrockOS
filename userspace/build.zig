const std = @import("std");
const support = @import("runtime/build_support.zig");

pub fn build(b: *std.Build) void {
    const selected = b.standardTargetOptions(.{ .default_target = .{
        .cpu_arch = .x86_64,
        .os_tag = .freestanding,
        .abi = .none,
    } });
    // Accept the conventional dependency option; bounded user code stays small.
    _ = b.standardOptimizeOption(.{});
    const target = support.userTarget(b, selected);
    const abi = b.addModule("bedrock64", .{
        .root_source_file = b.path("runtime/src/abi.zig"),
        .target = target,
        .optimize = .ReleaseSmall,
    });
    const runtime = b.addModule("userspace_runtime", .{
        .root_source_file = b.path("runtime/src/root.zig"),
        .target = target,
        .optimize = .ReleaseSmall,
        .stack_protector = false,
        .stack_check = false,
        .single_threaded = true,
        .red_zone = false,
        .pic = true,
        .code_model = if (target.result.cpu.arch == .riscv64) .medium else .small,
        .imports = &.{.{ .name = "bedrock64", .module = abi }},
    });
    runtime.addImport("networkkit", b.dependency("networkkit", .{ .target = target, .optimize = .ReleaseSmall, .relocatable = true }).module("networkkit"));
    const programs = support.addPrograms(b, target, abi, runtime);
    // Dependencies may request these artifacts without installing the package.
    b.installArtifact(programs.init);
    b.installArtifact(programs.service);
    b.installArtifact(programs.fault);
    b.installArtifact(programs.io);
    b.installArtifact(programs.exec);
    b.installArtifact(programs.files);
    b.installArtifact(programs.network);
    b.installArtifact(programs.wifi);
}
