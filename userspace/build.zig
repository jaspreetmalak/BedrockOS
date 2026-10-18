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
    b.installArtifact(programs.app_init);
    b.installArtifact(programs.observer);
    b.installArtifact(programs.worker);
    b.installArtifact(programs.display_init);
    b.installArtifact(programs.display_server);
    b.installArtifact(programs.surface_client);
    b.installArtifact(programs.desktop_init);
    b.installArtifact(programs.desktop_server);
    b.installArtifact(programs.desktop_shell);
    b.installArtifact(programs.desktop_files);
    b.installArtifact(programs.window_init);
    b.installArtifact(programs.window_server);
    b.installArtifact(programs.window_shell);
    b.installArtifact(programs.window_files);
    b.installArtifact(programs.window_notes);
}
