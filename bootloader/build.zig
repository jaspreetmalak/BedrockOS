const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{ .default_target = .{ .cpu_arch = .x86_64, .os_tag = .freestanding, .abi = .none } });
    const optimize = b.standardOptimizeOption(.{});
    const smoke_test = b.option(bool, "smoke-test", "Enable emulator-only termination") orelse false;
    const protocol = b.dependency("boot_protocol", .{ .target = target, .optimize = optimize });
    const module = b.addModule("bootloader", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "boot_protocol", .module = protocol.module("boot_protocol") }},
    });
    const arch = target.result.cpu.arch;
    const platform = switch (arch) {
        .aarch64 => .{ "arm64", "aarch64", "qemu_virt" },
        .x86_64 => .{ "x86_64", "x86_64", "qemu_pc" },
        .riscv64 => .{ "riscv64", "riscv64", "qemu_riscv_virt" },
        else => null,
    };
    if (platform) |port| {
        const boot_options = b.addOptions();
        boot_options.addOption(bool, "smoke_test", smoke_test);
        const firmware = b.addModule(b.fmt("{s}_firmware", .{port[0]}), .{
            .root_source_file = b.path(b.fmt("src/platform/{s}/main.zig", .{port[2]})),
            .target = target,
            .optimize = optimize,
            .stack_protector = false,
            .stack_check = false,
            .single_threaded = true,
            .red_zone = if (arch == .x86_64) false else null,
            .pic = false,
            .code_model = switch (arch) {
                .x86_64 => .large,
                .riscv64 => .medium,
                else => .default,
            },
            .imports = &.{.{ .name = "boot_protocol", .module = protocol.module("boot_protocol") }},
        });
        firmware.addOptions("boot_options", boot_options);
        if (arch == .aarch64 or arch == .riscv64) firmware.addImport("device_tree", b.createModule(.{
            .root_source_file = b.path("src/core/device_tree.zig"),
            .target = target,
            .optimize = optimize,
        }));
        firmware.addAssemblyFile(b.path(b.fmt("src/arch/{s}/entry.S", .{port[1]})));
        // The workspace supplies an opaque image, never kernel implementation.
    }
    const artifact = b.addLibrary(.{
        .name = "bedrock-bootloader",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/compile_check.zig"),
            .target = target,
            .optimize = optimize,
            .stack_protector = false,
            .red_zone = if (target.result.cpu.arch == .x86_64) false else null,
            .imports = &.{.{ .name = "bootloader", .module = module }},
        }),
    });
    b.installArtifact(artifact);
    b.step("check", "Compile the bootloader interface; no boot image is generated").dependOn(&artifact.step);
}
