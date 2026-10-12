const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const relocatable = b.option(bool, "relocatable", "Build position-independent desktop shell code") orelse false;
    const axisui = b.dependency("axisui", .{ .target = target, .optimize = optimize, .relocatable = relocatable });
    const arch = target.result.cpu.arch;
    const code_model: std.builtin.CodeModel = switch (arch) {
        .x86_64 => .small,
        .riscv64 => .medium,
        else => .default,
    };
    const module = b.addModule("desktop_shell", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .stack_protector = false,
        .stack_check = false,
        .single_threaded = true,
        .red_zone = if (arch == .x86_64) false else null,
        .pic = if (target.result.os.tag == .freestanding) relocatable else null,
        .code_model = code_model,
        .imports = &.{.{ .name = "axisui", .module = axisui.module("axisui") }},
    });
    const library = b.addLibrary(.{
        .name = "bedrock-desktop-shell",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/compile_check.zig"),
            .target = target,
            .optimize = optimize,
            .stack_protector = false,
            .stack_check = false,
            .single_threaded = true,
            .red_zone = if (arch == .x86_64) false else null,
            .pic = if (target.result.os.tag == .freestanding) relocatable else null,
            .code_model = code_model,
            .imports = &.{.{ .name = "desktop_shell", .module = module }},
        }),
    });
    b.installArtifact(library);
    b.step("check", "Compile the native desktop composition").dependOn(&library.step);

    const native_axisui = b.dependency("axisui", .{ .target = b.graph.host, .optimize = optimize, .relocatable = false }).module("axisui");
    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = b.graph.host,
        .optimize = optimize,
        .imports = &.{.{ .name = "axisui", .module = native_axisui }},
    }) });
    b.step("test", "Render the desktop into bounded native test buffers").dependOn(&b.addRunArtifact(tests).step);
}
