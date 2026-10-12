const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const relocatable = b.option(bool, "relocatable", "Build position-independent freestanding UI code") orelse false;
    const arch = target.result.cpu.arch;
    const axisui = b.addModule("axisui", .{
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
        .name = "bedrock-axisui",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/compile_check.zig"),
            .target = target,
            .optimize = optimize,
            .pic = if (target.result.os.tag == .freestanding) relocatable else null,
            .red_zone = if (arch == .x86_64) false else null,
            .stack_check = false,
            .stack_protector = false,
            .single_threaded = true,
            .code_model = axisui.code_model,
            .imports = &.{.{ .name = "axisui", .module = axisui }},
        }),
    });
    b.installArtifact(artifact);
    b.step("check", "Compile the AxisUI rendering interface without running it").dependOn(&artifact.step);
    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    }) });
    b.step("test", "Run native AxisUI layout, clipping and surface tests").dependOn(&b.addRunArtifact(tests).step);
}
