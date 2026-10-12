const std = @import("std");
const builtin = @import("builtin");

comptime {
    if (!std.mem.eql(u8, builtin.zig_version_string, "0.17.0"))
        @compileError("Bedrock requires Zig 0.17.0. Run zvm use 0.17.0 or use tools/zig.ps1 (tools/zig.sh on Unix).");
}

const Profile = struct { name: []const u8, arch: std.Target.Cpu.Arch };
const profiles = [_]Profile{
    .{ .name = "x86_64", .arch = .x86_64 },
    .{ .name = "aarch64", .arch = .aarch64 },
    .{ .name = "riscv64", .arch = .riscv64 },
};
const BootPlatform = struct {
    name: []const u8,
    arch: std.Target.Cpu.Arch,
    directory: []const u8,
    machine: []const u8,
    cpu: []const u8,
    firmware_elf: bool = false,
};
const platforms = [_]BootPlatform{
    .{ .name = "arm64", .arch = .aarch64, .directory = "qemu_virt", .machine = "virt-10.1,secure=off,virtualization=off", .cpu = "cortex-a57" },
    .{ .name = "x86_64", .arch = .x86_64, .directory = "qemu_pc", .machine = "pc-i440fx-10.1", .cpu = "qemu64" },
    .{ .name = "riscv64", .arch = .riscv64, .directory = "qemu_riscv_virt", .machine = "virt", .cpu = "rv64", .firmware_elf = true },
};

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const attach_network = b.option(bool, "network", "Attach a VirtIO NIC with QEMU user networking to interactive UEFI runs") orelse false;
    const ram_mib = b.option(u32, "ram-mib", "QEMU RAM in MiB for run and individual boot checks") orelse 128;
    if (ram_mib < 16 or ram_mib > 65536) @panic("ram-mib must be between 16 and 65536");
    const kernel_min = b.option(u64, "uefi-kernel-min", "Minimum physical address for deterministic UEFI kernel placement tests") orelse 0;
    const check = b.step("check", "Compile every component for all three freestanding targets");
    const test_step = b.step("test", "Run native OS, AxisUI layout/rendering and desktop shell tests");
    for (profiles) |profile| {
        const target = b.resolveTargetQuery(.{ .cpu_arch = profile.arch, .os_tag = .freestanding, .abi = .none, .cpu_model = .baseline });
        const profile_check = b.step(b.fmt("check-{s}", .{profile.name}), b.fmt("Compile all components for {s}", .{profile.name}));
        check.dependOn(profile_check);
        const components = [_]struct { dependency: []const u8, artifact: []const u8 }{
            .{ .dependency = "bootloader", .artifact = "bedrock-bootloader" },
            .{ .dependency = "kernel", .artifact = "bedrock-kernel" },
            .{ .dependency = "kernel", .artifact = "bedrock-wifi-drivers" },
            .{ .dependency = "filesystem", .artifact = "bedrock-filesystem" },
            .{ .dependency = "boot_protocol", .artifact = "bedrock-boot-protocol" },
            .{ .dependency = "axisui", .artifact = "bedrock-axisui" },
            .{ .dependency = "networkkit", .artifact = "bedrock-networkkit" },
            .{ .dependency = "network_core", .artifact = "bedrock-network-core" },
            .{ .dependency = "desktop_shell", .artifact = "bedrock-desktop-shell" },
            .{ .dependency = "files_app", .artifact = "bedrock-files-app" },
        };
        inline for (components) |component| {
            const dep = b.dependency(component.dependency, .{ .target = target, .optimize = optimize });
            const artifact = dep.artifact(component.artifact);
            profile_check.dependOn(&artifact.step);
            const install = b.addInstallArtifact(artifact, .{ .dest_dir = .{ .override = .{ .custom = b.fmt("check/{s}", .{profile.name}) } } });
            b.getInstallStep().dependOn(&install.step);
        }
        const wireless_pic = b.dependency("kernel", .{ .target = runtimeTarget(b, profile.arch), .optimize = optimize, .relocatable = true }).artifact("bedrock-wifi-drivers");
        profile_check.dependOn(&wireless_pic.step);
        const userland = b.dependency("userspace_runtime", .{ .target = target, .optimize = optimize });
        inline for (.{ "bedrock-user-init", "bedrock-user-service", "bedrock-user-fault", "bedrock-user-io", "bedrock-user-exec", "bedrock-user-files", "bedrock-user-network", "bedrock-user-wifi" }) |image| {
            profile_check.dependOn(&userland.artifact(image).step);
        }
    }
    inline for (.{ .{ "boot_protocol", "boot_protocol" }, .{ "filesystem", "filesystem" }, .{ "axisui", "axisui" }, .{ "networkkit", "networkkit" }, .{ "network_core", "network_core" }, .{ "desktop_shell", "desktop_shell" }, .{ "files_app", "files_app" }, .{ "window_server", "window_server" } }) |component| {
        const dep = b.dependency(component[0], .{ .target = b.graph.host, .optimize = optimize });
        const tests = b.addTest(.{ .name = b.fmt("{s}-tests", .{component[0]}), .root_module = dep.module(component[1]) });
        test_step.dependOn(&b.addRunArtifact(tests).step);
    }
    const native_protocol = b.dependency("boot_protocol", .{ .target = b.graph.host, .optimize = optimize }).module("boot_protocol");
    const native_filesystem = b.dependency("filesystem", .{ .target = b.graph.host, .optimize = optimize }).module("filesystem");
    const native_security = b.dependency("kernel", .{ .target = b.graph.host, .optimize = optimize }).module("security");
    const native_wifi_drivers = b.dependency("kernel", .{ .target = b.graph.host, .optimize = optimize }).module("wifi_drivers");
    const wifi_driver_tests = b.addTest(.{ .name = "wifi-driver-tests", .root_module = native_wifi_drivers });
    const wifi_driver_run = b.addRunArtifact(wifi_driver_tests);
    test_step.dependOn(&wifi_driver_run.step);
    b.step("test-wifi-drivers", "Run native chipset, DMA-resource and WPA2 protocol tests").dependOn(&wifi_driver_run.step);
    const test_regulatory = b.step("test-wifi-regulatory", "Run country/device policy and MediaTek regulatory command tests plus offline database checks");
    test_regulatory.dependOn(&wifi_driver_run.step);
    const regdb_tests = std.Build.Step.Run.create(b, "test offline wireless regulatory database importer");
    regdb_tests.addFileArg(b.findProgramLazy(.{ .names = if (builtin.os.tag == .windows) &.{ "python", "python3" } else &.{"python3"} }));
    regdb_tests.addFileArg(b.path("tools/test-wifi-regdb.py"));
    regdb_tests.addFileInput(b.path("tools/update-wifi-regdb.py"));
    regdb_tests.addFileInput(b.path("kernel/src/drivers/wifi/regulatory/database.zig"));
    regdb_tests.addFileInput(b.path("kernel/src/drivers/wifi/regulatory/LICENSE"));
    regdb_tests.addFileInput(b.path("kernel/src/drivers/wifi/regulatory/provenance.json"));
    test_regulatory.dependOn(&regdb_tests.step);
    test_step.dependOn(&regdb_tests.step);
    const firmware_references = b.addExecutable(.{ .name = "wifi-firmware-references", .root_module = b.createModule(.{
        .root_source_file = b.path("kernel/src/drivers/wifi/firmware_reference_check.zig"),
        .target = b.graph.host,
        .optimize = optimize,
        .imports = &.{.{ .name = "wifi_drivers", .module = native_wifi_drivers }},
    }) });
    const firmware_run = b.addRunArtifact(firmware_references);
    const patch_reference = b.option([]const u8, "wifi-patch-reference", "Explicit local intact MT7922 patch file for optional format/hash checks");
    const ram_reference = b.option([]const u8, "wifi-ram-reference", "Explicit local intact MT7922 RAM file for optional format/hash checks");
    if ((patch_reference == null) != (ram_reference == null)) @panic("Supply both Wi-Fi reference files, or neither");
    if (patch_reference) |path| {
        firmware_run.addArg("--reference-files");
        firmware_run.addFileArg(.{ .cwd_relative = path });
        firmware_run.addFileArg(.{ .cwd_relative = ram_reference.? });
    }
    b.step("test-wifi-firmware", "Optionally validate explicitly supplied local MT7922 firmware references; never execute firmware").dependOn(&firmware_run.step);
    const network_requests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("kernel/src/core/network_syscalls.zig"),
        .target = b.graph.host,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "security", .module = native_security },
            .{ .name = "networkkit", .module = b.dependency("networkkit", .{ .target = b.graph.host, .optimize = optimize }).module("networkkit") },
            .{ .name = "bedrock64", .module = b.createModule(.{ .root_source_file = b.path("userspace/runtime/src/abi.zig"), .target = b.graph.host, .optimize = optimize }) },
        },
    }) });
    test_step.dependOn(&b.addRunArtifact(network_requests).step);
    const wifi_requests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("kernel/src/core/wifi_syscalls.zig"),
        .target = b.graph.host,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "security", .module = native_security },
            .{ .name = "networkkit", .module = b.dependency("networkkit", .{ .target = b.graph.host, .optimize = optimize }).module("networkkit") },
            .{ .name = "bedrock64", .module = b.createModule(.{ .root_source_file = b.path("userspace/runtime/src/abi.zig"), .target = b.graph.host, .optimize = optimize }) },
        },
    }) });
    test_step.dependOn(&b.addRunArtifact(wifi_requests).step);
    const wifi_wire = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("userspace/runtime/src/wifi_wire.zig"),
        .target = b.graph.host,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "networkkit", .module = b.dependency("networkkit", .{ .target = b.graph.host, .optimize = optimize }).module("networkkit") },
            .{ .name = "bedrock64", .module = b.createModule(.{ .root_source_file = b.path("userspace/runtime/src/abi.zig"), .target = b.graph.host, .optimize = optimize }) },
        },
    }) });
    test_step.dependOn(&b.addRunArtifact(wifi_wire).step);
    const preview_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("kernel/src/drivers/desktop_preview.zig"),
        .target = b.graph.host,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "boot_protocol", .module = native_protocol },
            .{ .name = "desktop_shell", .module = b.dependency("desktop_shell", .{ .target = b.graph.host, .optimize = optimize }).module("desktop_shell") },
        },
    }) });
    test_step.dependOn(&b.addRunArtifact(preview_tests).step);
    const native_access = b.createModule(.{ .root_source_file = b.path("kernel/src/arch/physical_memory.zig"), .target = b.graph.host, .optimize = optimize, .imports = &.{.{ .name = "boot_protocol", .module = native_protocol }} });
    const native_memory = b.createModule(.{ .root_source_file = b.path("kernel/src/core/memory_init.zig"), .target = b.graph.host, .optimize = optimize, .imports = &.{ .{ .name = "boot_protocol", .module = native_protocol }, .{ .name = "physical_access", .module = native_access } } });
    const driver_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("kernel/src/drivers/virtio/root.zig"),
        .target = b.graph.host,
        .optimize = optimize,
        .imports = &.{ .{ .name = "boot_protocol", .module = native_protocol }, .{ .name = "memory_init", .module = native_memory } },
    }) });
    test_step.dependOn(&b.addRunArtifact(driver_tests).step);
    const format_tests = std.Build.Step.Run.create(b, "test persistent disk format");
    format_tests.addFileArg(b.findProgramLazy(.{ .names = if (builtin.os.tag == .windows) &.{ "python", "python3" } else &.{"python3"} }));
    format_tests.addFileArg(b.path("tools/test-data-image.py"));
    format_tests.addFileInput(b.path("tools/make-data-image.py"));
    test_step.dependOn(&format_tests.step);
    for ([_][]const u8{ "bootloader/src/core/device_tree.zig", "bootloader/src/core/elf.zig", "bootloader/src/platform/uefi/memory.zig", "bootloader/src/platform/uefi/paging.zig", "kernel/src/core/memory.zig", "kernel/src/core/physical_memory.zig", "kernel/src/core/owned_frames.zig", "kernel/src/core/kernel_heap.zig", "kernel/src/core/user_memory.zig", "kernel/src/core/isolation_contract.zig", "kernel/src/core/scheduler.zig", "kernel/src/core/process.zig", "kernel/src/core/ipc.zig", "kernel/src/core/user_elf.zig", "kernel/src/core/vfs.zig", "kernel/src/core/pipe.zig", "kernel/src/arch/physical_memory.zig", "kernel/src/arch/aarch64/timer.zig", "kernel/src/arch/riscv64/timer.zig", "kernel/src/drivers/framebuffer.zig", "kernel/src/security/sandbox.zig", "kernel/src/security/quotas.zig" }) |source| {
        const tests = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path(source),
            .target = b.graph.host,
            .optimize = optimize,
            .imports = &.{ .{ .name = "boot_protocol", .module = native_protocol }, .{ .name = "filesystem", .module = native_filesystem }, .{ .name = "security", .module = native_security } },
        }) });
        test_step.dependOn(&b.addRunArtifact(tests).step);
    }
    const images = b.step("images", "Build reset and UEFI boot images for all three architectures");
    const uefi_images = b.step("uefi", "Build the primary UEFI loaders and kernels for all three architectures");
    images.dependOn(uefi_images);
    const test_boot = b.step("test-boot", "Boot reset and UEFI paths for all three architectures in QEMU");
    const test_uefi = b.step("test-uefi", "Boot the primary UEFI paths for all three architectures in QEMU");
    const test_desktop = b.step("test-desktop", "Drive native Files input, disk operations and reboot recovery on all three architectures");
    const test_network = b.step("test-network", "Verify protected NetworkKit datagrams over VirtIO networking on all three architectures");
    _ = b.step("test-wifi", "Verify protected Wi-Fi controls using an explicitly simulated radio on all architectures");
    test_boot.dependOn(test_uefi);
    const matrix = b.step("test-boot-matrix", "Verify memory discovery across multiple RAM sizes and boot paths");
    var previous_matrix: ?*std.Build.Step = null;
    const legacy_arm_qemu = b.option([]const u8, "qemu", "Absolute ARM64 QEMU path (also -Dqemu-arm64)");
    for (platforms) |platform| addPlatform(b, optimize, platform, images, uefi_images, test_boot, test_uefi, test_desktop, test_network, matrix, &previous_matrix, legacy_arm_qemu, ram_mib, kernel_min, attach_network);
    b.getInstallStep().dependOn(uefi_images);
}

fn runtimeTarget(b: *std.Build, arch: std.Target.Cpu.Arch) std.Build.ResolvedTarget {
    var query: std.Target.Query = .{ .cpu_arch = arch, .os_tag = .freestanding, .abi = .none, .cpu_model = .baseline };
    switch (arch) {
        .aarch64 => {
            query.cpu_model = .{ .explicit = &std.Target.aarch64.cpu.cortex_a57 };
            // MMU-off ARM accesses must respect Device-memory alignment.
            query.cpu_features_add = std.Target.aarch64.featureSet(&.{.strict_align});
        },
        .riscv64 => {
            query.cpu_model = .{ .explicit = &std.Target.riscv.cpu.generic_rv64 };
            query.cpu_features_add = std.Target.riscv.featureSet(&.{ .m, .a, .c, .zicsr, .zifencei });
            query.cpu_features_sub = std.Target.riscv.featureSet(&.{ .f, .d });
        },
        .x86_64 => {},
        else => unreachable,
    }
    return b.resolveTargetQuery(query);
}

fn addPlatform(b: *std.Build, optimize: std.builtin.OptimizeMode, platform: BootPlatform, images: *std.Build.Step, uefi_images: *std.Build.Step, test_boot: *std.Build.Step, test_uefi: *std.Build.Step, test_desktop: *std.Build.Step, test_network: *std.Build.Step, matrix: *std.Build.Step, previous_matrix: *?*std.Build.Step, legacy_arm_qemu: ?[]const u8, ram_mib: u32, kernel_min: u64, attach_network: bool) void {
    const target = runtimeTarget(b, platform.arch);
    const kernel_dep = b.dependency("kernel", .{ .target = target, .optimize = optimize });
    const kernel = b.addExecutable(.{
        .name = b.fmt("bedrock-kernel-{s}", .{platform.name}),
        .root_module = kernel_dep.module(b.fmt("{s}_kernel", .{platform.name})),
        .use_llvm = true,
        .use_lld = true,
    });
    kernel.entry = .{ .symbol_name = "_start" };
    kernel.setLinkerScript(kernel_dep.path(b.fmt("src/platform/{s}/linker.ld", .{platform.directory})));
    const kernel_bin = kernel.addObjCopy(.{ .format = .binary, .basename = "kernel.bin" }).getOutput();
    const image_step = b.step(platform.name, b.fmt("Build {s} bootloader and kernel images", .{platform.name}));
    images.dependOn(image_step);
    image_step.dependOn(&b.addInstallFile(kernel.getEmittedBin(), b.fmt("{s}/kernel.elf", .{platform.name})).step);
    image_step.dependOn(&b.addInstallFile(kernel_bin, b.fmt("{s}/kernel.bin", .{platform.name})).step);
    const firmware = buildFirmware(b, target, optimize, platform, kernel_bin, false);
    const firmware_bin = firmware.addObjCopy(.{ .format = .binary, .basename = "bootloader.bin" }).getOutput();
    image_step.dependOn(&b.addInstallFile(firmware.getEmittedBin(), b.fmt("{s}/bootloader.elf", .{platform.name})).step);
    image_step.dependOn(&b.addInstallFile(firmware_bin, b.fmt("{s}/bootloader.bin", .{platform.name})).step);

    const qemu_override = b.option([]const u8, b.fmt("qemu-{s}", .{platform.name}), b.fmt("Absolute {s} QEMU path", .{platform.name})) orelse
        (if (platform.arch == .aarch64) legacy_arm_qemu else null);
    const program = b.fmt("qemu-system-{s}", .{if (platform.arch == .aarch64) "aarch64" else platform.name});
    const qemu: std.Build.LazyPath = if (qemu_override) |path| .{ .cwd_relative = path } else b.findProgramLazy(.{ .names = if (builtin.os.tag == .windows)
        &.{ program, b.fmt("C:\\Program Files\\qemu\\{s}.exe", .{program}) }
    else
        &.{program} });
    const run = std.Build.Step.Run.create(b, b.fmt("run {s} QEMU", .{platform.name}));
    run.addFileArg(qemu);
    run.addArgs(&.{
        "-machine", platform.machine, "-cpu",     platform.cpu,              "-accel",     "tcg",
        "-smp",     "1",              "-m",       b.fmt("{d}M", .{ram_mib}), "-display",   "none",
        "-serial",  "stdio",          "-monitor", "none",                    "-no-reboot", "-bios",
    });
    run.addFileArg(if (platform.firmware_elf) firmware.getEmittedBin() else firmware_bin);
    run.has_side_effects = true;
    b.step(b.fmt("run-{s}", .{platform.name}), b.fmt("Boot {s} (Ctrl+C to stop)", .{platform.name})).dependOn(&run.step);

    const smoke = buildFirmware(b, target, optimize, platform, kernel_bin, true);
    const smoke_image = if (platform.firmware_elf) smoke.getEmittedBin() else smoke.addObjCopy(.{ .format = .binary, .basename = "bootloader-smoke.bin" }).getOutput();
    const smoke_run = smokeRun(b, platform.name, qemu, smoke_image, ram_mib, null, null);
    const platform_test = b.step(b.fmt("test-{s}", .{platform.name}), b.fmt("Verify {s} handoff and exception handling in QEMU", .{platform.name}));
    platform_test.dependOn(&smoke_run.step);
    test_boot.dependOn(platform_test);
    for ([_]u32{ 64, 128, 512 }) |size| {
        const matrix_run = smokeRun(b, platform.name, qemu, smoke_image, size, null, null);
        if (previous_matrix.*) |previous| matrix_run.step.dependOn(previous);
        previous_matrix.* = &matrix_run.step;
        matrix.dependOn(&matrix_run.step);
    }
    if (platform.arch == .x86_64) addUefi(b, optimize, qemu, uefi_images, test_uefi, test_desktop, test_network, matrix, previous_matrix, ram_mib, kernel_min, attach_network);
    if (platform.arch != .x86_64) addMultiUefi(b, optimize, platform, qemu, uefi_images, test_uefi, test_desktop, test_network, matrix, previous_matrix, ram_mib, kernel_min, attach_network);
}

fn smokeRun(b: *std.Build, name: []const u8, qemu: std.Build.LazyPath, image: std.Build.LazyPath, ram_mib: u32, code: ?std.Build.LazyPath, vars: ?std.Build.LazyPath) *std.Build.Step.Run {
    const run = if (builtin.os.tag == .windows)
        b.addSystemCommand(&.{ "powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File" })
    else
        b.addSystemCommand(&.{"sh"});
    run.addFileArg(b.path(if (builtin.os.tag == .windows) "tools/test-boot.ps1" else "tools/test-boot.sh"));
    run.addArg(name);
    run.addFileArg(qemu);
    run.addFileArg(image);
    run.addArg("40");
    run.addArg(b.fmt("{d}", .{ram_mib}));
    if (code) |path| run.addFileArg(path);
    if (vars) |path| run.addFileArg(path);
    run.has_side_effects = true;
    return run;
}

fn uefiApplication(b: *std.Build, optimize: std.builtin.OptimizeMode, kernel_image: std.Build.LazyPath, smoke: bool, kernel_min: u64) *std.Build.Step.Compile {
    const target = b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .uefi, .abi = .msvc, .cpu_model = .baseline });
    const dep = b.dependency("bootloader", .{ .target = target, .optimize = optimize });
    const protocol = b.dependency("boot_protocol", .{ .target = target, .optimize = optimize });
    const module = b.createModule(.{
        .root_source_file = dep.path("src/platform/uefi/main.zig"),
        .target = target,
        .optimize = optimize,
        .stack_protector = false,
        .stack_check = false,
        .red_zone = false,
        .single_threaded = true,
        .imports = &.{.{ .name = "boot_protocol", .module = protocol.module("boot_protocol") }},
    });
    const options = b.addOptions();
    options.addOption(bool, "smoke_test", smoke);
    options.addOption(u64, "kernel_min", kernel_min);
    module.addOptions("boot_options", options);
    module.addAnonymousImport("kernel_image", .{ .root_source_file = kernel_image });
    module.addImport("elf_loader", b.createModule(.{ .root_source_file = b.path("bootloader/src/core/elf.zig"), .target = target, .optimize = optimize }));
    module.addAssemblyFile(dep.path("src/platform/uefi/entry.S"));
    return b.addExecutable(.{ .name = if (smoke) "bedrock-uefi-x86_64-smoke" else "bedrock-uefi-x86_64", .root_module = module, .use_llvm = true, .use_lld = true });
}

fn addUefi(b: *std.Build, optimize: std.builtin.OptimizeMode, qemu: std.Build.LazyPath, images: *std.Build.Step, test_boot: *std.Build.Step, test_desktop: *std.Build.Step, test_network: *std.Build.Step, matrix: *std.Build.Step, previous_matrix: *?*std.Build.Step, ram_mib: u32, kernel_min: u64, attach_network: bool) void {
    const pie = uefiKernel(b, optimize, .x86_64, 0, false, false);
    images.dependOn(&b.addInstallFile(pie.getEmittedBin(), "uefi/x86_64/kernel.elf").step);
    const application = uefiApplication(b, optimize, pie.getEmittedBin(), false, kernel_min);
    const install = b.addInstallFile(application.getEmittedBin(), "uefi/x86_64/EFI/BOOT/BOOTX64.EFI");
    images.dependOn(&install.step);
    b.step("uefi-x86_64", "Build the Bedrock x86-64 UEFI removable-media application").dependOn(&install.step);
    const normal_tree = b.addWriteFiles();
    _ = normal_tree.addCopyFile(application.getEmittedBin(), "EFI/BOOT/BOOTX64.EFI");
    const smoke = uefiApplication(b, optimize, pie.getEmittedBin(), true, kernel_min);
    const smoke_tree = b.addWriteFiles();
    const smoke_file = smoke_tree.addCopyFile(smoke.getEmittedBin(), "EFI/BOOT/BOOTX64.EFI");
    const code: std.Build.LazyPath = .{ .cwd_relative = b.option([]const u8, "ovmf-code", "OVMF/EDK2 x86-64 firmware code image") orelse if (builtin.os.tag == .windows) "C:\\Program Files\\qemu\\share\\edk2-x86_64-code.fd" else "/usr/share/OVMF/OVMF_CODE.fd" };
    const vars: std.Build.LazyPath = .{ .cwd_relative = b.option([]const u8, "ovmf-vars", "Matching OVMF/EDK2 variable-store template") orelse if (builtin.os.tag == .windows) "C:\\Program Files\\qemu\\share\\edk2-i386-vars.fd" else "/usr/share/OVMF/OVMF_VARS.fd" };
    desktopRun(b, optimize, "x86_64", qemu, normal_tree.getDirectory(), code, vars, test_desktop);
    networkRun(b, optimize, .x86_64, qemu, code, vars, test_network);
    wifiRun(b, optimize, .x86_64, qemu, code, vars, &b.top_level_steps.get("test-wifi").?.step);
    const disk_image = uefiDiskImage(b, application.getEmittedBin(), "bedrock-x86_64-uefi.img");
    const disk_install = b.addInstallFile(disk_image, "uefi/x86_64/bedrock-uefi.img");
    const image_step = b.step("uefi-image-x86_64", "Build a standalone GPT/FAT32 UEFI disk image (requires Python 3)");
    image_step.dependOn(&install.step);
    image_step.dependOn(&disk_install.step);
    const smoke_disk = uefiDiskImage(b, smoke.getEmittedBin(), "bedrock-x86_64-uefi-smoke.img");
    const python = b.findProgramLazy(.{ .names = if (builtin.os.tag == .windows) &.{ "python", "python3" } else &.{"python3"} });
    const image_tests = std.Build.Step.Run.create(b, "test UEFI image format");
    image_tests.addFileArg(python);
    image_tests.addFileArg(b.path("tools/test-uefi-image.py"));
    image_tests.addFileInput(b.path("tools/make-uefi-image.py"));
    const image_check = std.Build.Step.Run.create(b, "check UEFI disk image");
    image_check.addFileArg(python);
    image_check.addFileArg(b.path("tools/test-uefi-image.py"));
    image_check.addFileInput(b.path("tools/make-uefi-image.py"));
    image_check.addFileArg(smoke.getEmittedBin());
    image_check.addFileArg(smoke_disk);
    const disk_test = smokeRun(b, "x86_64-uefi-image", qemu, smoke_disk, @max(ram_mib, 128), code, vars);
    disk_test.step.dependOn(&image_tests.step);
    disk_test.step.dependOn(&image_check.step);
    b.step("test-uefi-image-x86_64", "Check and boot the standalone GPT/FAT32 UEFI disk image").dependOn(&disk_test.step);
    const test_run = smokeRun(b, "x86_64-uefi", qemu, smoke_file, @max(ram_mib, 128), code, vars);
    b.step("test-uefi-x86_64", "Verify UEFI ExitBootServices and the separate x86-64 kernel").dependOn(&test_run.step);
    test_boot.dependOn(&test_run.step);
    for ([_]u32{ 128, 256, 512 }) |size| {
        const matrix_run = smokeRun(b, "x86_64-uefi", qemu, smoke_file, size, code, vars);
        if (previous_matrix.*) |previous| matrix_run.step.dependOn(previous);
        previous_matrix.* = &matrix_run.step;
        matrix.dependOn(&matrix_run.step);
    }
    const run = if (builtin.os.tag == .windows) b.addSystemCommand(&.{ "powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File" }) else b.addSystemCommand(&.{"sh"});
    run.addFileArg(b.path(if (builtin.os.tag == .windows) "tools/run-uefi.ps1" else "tools/run-uefi.sh"));
    run.addFileArg(qemu);
    run.addFileArg(normal_tree.getDirectory());
    run.addFileArg(code);
    run.addFileArg(vars);
    run.addArg(b.fmt("{d}", .{@max(ram_mib, 128)}));
    if (attach_network) {
        run.addArg("x86_64");
        if (builtin.os.tag == .windows) run.addArg("-Network") else run.addArgs(&.{ "", "network" });
    }
    run.has_side_effects = true;
    b.step("run-uefi-x86_64", "Boot the normal UEFI image with a visible framebuffer (Ctrl+C to stop)").dependOn(&run.step);
}

fn uefiKernel(b: *std.Build, optimize: std.builtin.OptimizeMode, arch: std.Target.Cpu.Arch, network_echo_port: u16, wifi_acceptance: bool, wifi_absence_probe: bool) *std.Build.Step.Compile {
    const target = runtimeTarget(b, arch);
    const dep = b.dependency("kernel", .{ .target = target, .optimize = optimize, .relocatable = true, .uefi_entry = true, .network_echo_port = network_echo_port, .wifi_acceptance = wifi_acceptance, .wifi_absence_probe = wifi_absence_probe });
    const name = if (arch == .aarch64) "arm64" else @tagName(arch);
    const userland = b.dependency("userspace_runtime", .{ .target = target, .optimize = optimize });
    inline for (.{ .{ "bedrock-user-init", "init" }, .{ "bedrock-user-service", "service" }, .{ "bedrock-user-fault", "fault" }, .{ "bedrock-user-io", "io" }, .{ "bedrock-user-exec", "exec" }, .{ "bedrock-user-files", "files" }, .{ "bedrock-user-network", "network" }, .{ "bedrock-user-wifi", "wifi" } }) |image| {
        const install = b.addInstallFile(userland.artifact(image[0]).getEmittedBin(), b.fmt("userspace/{s}/{s}.elf", .{ name, image[1] }));
        b.getInstallStep().dependOn(&install.step);
    }
    const kernel = b.addExecutable(.{ .name = b.fmt("bedrock-kernel-{s}-pie", .{name}), .root_module = dep.module(b.fmt("{s}_kernel", .{name})), .use_llvm = true, .use_lld = true });
    kernel.pie = true;
    kernel.entry = .{ .symbol_name = "_start" };
    kernel.setLinkerScript(dep.path("src/platform/uefi/linker.ld"));
    return kernel;
}

fn multiUefiApplication(b: *std.Build, optimize: std.builtin.OptimizeMode, arch: std.Target.Cpu.Arch, image: std.Build.LazyPath, smoke: bool, kernel_min: u64) std.Build.LazyPath {
    const target = if (arch == .riscv64) runtimeTarget(b, arch) else b.resolveTargetQuery(.{ .cpu_arch = arch, .os_tag = .uefi, .abi = .none, .cpu_model = .{ .explicit = &std.Target.aarch64.cpu.cortex_a57 }, .cpu_features_add = std.Target.aarch64.featureSet(&.{.strict_align}) });
    const protocol = b.dependency("boot_protocol", .{ .target = target, .optimize = optimize }).module("boot_protocol");
    const options = b.addOptions();
    options.addOption(bool, "smoke_test", smoke);
    options.addOption(u64, "kernel_min", kernel_min);
    const common = b.createModule(.{ .root_source_file = b.path("bootloader/src/platform/uefi/multiarch.zig"), .target = target, .optimize = optimize, .imports = &.{
        .{ .name = "boot_protocol", .module = protocol },
        .{ .name = "device_tree", .module = b.createModule(.{ .root_source_file = b.path("bootloader/src/core/device_tree.zig"), .target = target, .optimize = optimize }) },
        .{ .name = "elf_loader", .module = b.createModule(.{ .root_source_file = b.path("bootloader/src/core/elf.zig"), .target = target, .optimize = optimize }) },
        .{ .name = "uefi_memory", .module = b.createModule(.{ .root_source_file = b.path("bootloader/src/platform/uefi/memory.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "boot_protocol", .module = protocol }} }) },
    } });
    const boot_options = options.createModule();
    common.addImport("boot_options", boot_options);
    common.addAnonymousImport("kernel_image", .{ .root_source_file = image });
    const module = b.createModule(.{ .root_source_file = b.path(b.fmt("bootloader/src/platform/uefi/{s}/main.zig", .{@tagName(arch)})), .target = target, .optimize = optimize, .stack_check = false, .stack_protector = false, .single_threaded = true, .pic = true, .code_model = if (arch == .riscv64) .medium else .default, .imports = &.{ .{ .name = "uefi_common", .module = common }, .{ .name = "boot_protocol", .module = protocol } } });
    module.addImport("boot_options", boot_options);
    module.addAssemblyFile(b.path(b.fmt("bootloader/src/platform/uefi/{s}/entry.S", .{@tagName(arch)})));
    const compile = b.addExecutable(.{ .name = b.fmt("bedrock-uefi-{s}{s}", .{ @tagName(arch), if (smoke) "-smoke" else "" }), .root_module = module, .use_llvm = true, .use_lld = true });
    if (arch != .riscv64) return compile.getEmittedBin();
    compile.entry = .{ .symbol_name = "EfiMain" };
    compile.pie = true;
    compile.setLinkerScript(b.path("bootloader/src/platform/uefi/riscv64/linker.ld"));
    const run = std.Build.Step.Run.create(b, "convert RV64 ELF to UEFI PE");
    run.addFileArg(b.findProgramLazy(.{ .names = if (builtin.os.tag == .windows) &.{ "python", "python3" } else &.{"python3"} }));
    run.addFileArg(b.path("tools/elf-to-efi.py"));
    run.addFileInput(b.path("tools/make-uefi-image.py"));
    run.addFileArg(compile.getEmittedBin());
    return run.addOutputFileArg("BOOTRISCV64.EFI");
}

fn addMultiUefi(b: *std.Build, optimize: std.builtin.OptimizeMode, platform: BootPlatform, qemu: std.Build.LazyPath, images: *std.Build.Step, test_boot: *std.Build.Step, test_desktop: *std.Build.Step, test_network: *std.Build.Step, matrix: *std.Build.Step, previous_matrix: *?*std.Build.Step, ram_mib: u32, kernel_min: u64, attach_network: bool) void {
    const arch = platform.arch;
    const pie = uefiKernel(b, optimize, arch, 0, false, false);
    const normal = multiUefiApplication(b, optimize, arch, pie.getEmittedBin(), false, kernel_min);
    const smoke = multiUefiApplication(b, optimize, arch, pie.getEmittedBin(), true, kernel_min);
    const filename = if (arch == .aarch64) "BOOTAA64.EFI" else "BOOTRISCV64.EFI";
    const install = b.addInstallFile(normal, b.fmt("uefi/{s}/EFI/BOOT/{s}", .{ platform.name, filename }));
    images.dependOn(&install.step);
    images.dependOn(&b.addInstallFile(pie.getEmittedBin(), b.fmt("uefi/{s}/kernel.elf", .{platform.name})).step);
    b.step(b.fmt("uefi-{s}", .{platform.name}), "Build the relocatable standard firmware loader and kernel").dependOn(&install.step);
    const tree = b.addWriteFiles();
    const file = tree.addCopyFile(smoke, b.fmt("EFI/BOOT/{s}", .{filename}));
    const code: std.Build.LazyPath = .{ .cwd_relative = b.option([]const u8, b.fmt("uefi-code-{s}", .{platform.name}), "Architecture firmware code image") orelse if (builtin.os.tag == .windows) b.fmt("C:\\Program Files\\qemu\\share\\edk2-{s}-code.fd", .{if (arch == .aarch64) "aarch64" else "riscv"}) else b.fmt("/usr/share/qemu/edk2-{s}-code.fd", .{if (arch == .aarch64) "aarch64" else "riscv"}) };
    const vars: std.Build.LazyPath = .{ .cwd_relative = b.option([]const u8, b.fmt("uefi-vars-{s}", .{platform.name}), "Matching architecture firmware variable-store template") orelse if (builtin.os.tag == .windows) b.fmt("C:\\Program Files\\qemu\\share\\edk2-{s}-vars.fd", .{if (arch == .aarch64) "arm" else "riscv"}) else b.fmt("/usr/share/qemu/edk2-{s}-vars.fd", .{if (arch == .aarch64) "arm" else "riscv"}) };
    const run = smokeRun(b, b.fmt("{s}-uefi", .{platform.name}), qemu, file, @max(ram_mib, 128), code, vars);
    b.step(b.fmt("test-uefi-{s}", .{platform.name}), "Verify firmware exit and the relocatable kernel").dependOn(&run.step);
    test_boot.dependOn(&run.step);
    for ([_]u32{ 128, 256, 512 }) |size| {
        const matrix_run = smokeRun(b, b.fmt("{s}-uefi", .{platform.name}), qemu, file, size, code, vars);
        if (previous_matrix.*) |previous| matrix_run.step.dependOn(previous);
        previous_matrix.* = &matrix_run.step;
        matrix.dependOn(&matrix_run.step);
    }
    const normal_tree = b.addWriteFiles();
    _ = normal_tree.addCopyFile(normal, b.fmt("EFI/BOOT/{s}", .{filename}));
    desktopRun(b, optimize, platform.name, qemu, normal_tree.getDirectory(), code, vars, test_desktop);
    networkRun(b, optimize, arch, qemu, code, vars, test_network);
    wifiRun(b, optimize, arch, qemu, code, vars, &b.top_level_steps.get("test-wifi").?.step);
    const interactive = if (builtin.os.tag == .windows) b.addSystemCommand(&.{ "powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File" }) else b.addSystemCommand(&.{"sh"});
    interactive.addFileArg(b.path(if (builtin.os.tag == .windows) "tools/run-uefi.ps1" else "tools/run-uefi.sh"));
    interactive.addFileArg(qemu);
    interactive.addFileArg(normal_tree.getDirectory());
    interactive.addFileArg(code);
    interactive.addFileArg(vars);
    interactive.addArg(b.fmt("{d}", .{@max(ram_mib, 128)}));
    interactive.addArg(platform.name);
    if (attach_network) {
        if (builtin.os.tag == .windows) interactive.addArg("-Network") else interactive.addArgs(&.{ "", "network" });
    }
    interactive.has_side_effects = true;
    b.step(b.fmt("run-uefi-{s}", .{platform.name}), "Boot the normal firmware image (Ctrl+C to stop)").dependOn(&interactive.step);
    if (arch == .riscv64) {
        const test_converter = std.Build.Step.Run.create(b, "test RV64 EFI conversion");
        test_converter.addFileArg(b.findProgramLazy(.{ .names = if (builtin.os.tag == .windows) &.{ "python", "python3" } else &.{"python3"} }));
        test_converter.addFileArg(b.path("tools/test-elf-to-efi.py"));
        test_converter.addFileInput(b.path("tools/elf-to-efi.py"));
        test_boot.dependOn(&test_converter.step);
    }
}

fn networkRun(b: *std.Build, optimize: std.builtin.OptimizeMode, arch: std.Target.Cpu.Arch, qemu: std.Build.LazyPath, code: std.Build.LazyPath, vars: std.Build.LazyPath, aggregate: *std.Build.Step) void {
    const architecture = if (arch == .aarch64) "arm64" else @tagName(arch);
    const kernel = uefiKernel(b, optimize, arch, 32123, false, false);
    const image = if (arch == .x86_64)
        uefiApplication(b, optimize, kernel.getEmittedBin(), true, 0).getEmittedBin()
    else
        multiUefiApplication(b, optimize, arch, kernel.getEmittedBin(), true, 0);
    const tree = b.addWriteFiles();
    const filename = switch (arch) {
        .x86_64 => "BOOTX64.EFI",
        .aarch64 => "BOOTAA64.EFI",
        .riscv64 => "BOOTRISCV64.EFI",
        else => unreachable,
    };
    _ = tree.addCopyFile(image, b.fmt("EFI/BOOT/{s}", .{filename}));
    const run = std.Build.Step.Run.create(b, b.fmt("test protected {s} networking", .{architecture}));
    run.addFileArg(b.findProgramLazy(.{ .names = if (builtin.os.tag == .windows) &.{ "python", "python3" } else &.{"python3"} }));
    run.addFileArg(b.path("tools/test-network.py"));
    run.addFileInput(b.path("tools/make-data-image.py"));
    run.addArg(architecture);
    run.addFileArg(qemu);
    run.addDirectoryArg(tree.getDirectory());
    run.addFileArg(code);
    run.addFileArg(vars);
    run.addArg("--artifacts");
    run.addDirectoryArg(b.path(b.fmt("zig-out/network-tests/{s}", .{@tagName(optimize)})));
    run.has_side_effects = true;
    aggregate.dependOn(&run.step);
    b.step(b.fmt("test-network-{s}", .{architecture}), "Exercise checked UDP, ARP, authority and lifecycle through the real NIC").dependOn(&run.step);
}

fn wifiRun(b: *std.Build, optimize: std.builtin.OptimizeMode, arch: std.Target.Cpu.Arch, qemu: std.Build.LazyPath, code: std.Build.LazyPath, vars: std.Build.LazyPath, aggregate: *std.Build.Step) void {
    const arch_step = b.step(b.fmt("test-wifi-{s}", .{if (arch == .aarch64) "arm64" else @tagName(arch)}), "Test simulated Wi-Fi controls and real driver-unavailable policy");
    wifiProfileRun(b, optimize, arch, qemu, code, vars, aggregate, arch_step, false);
    wifiProfileRun(b, optimize, arch, qemu, code, vars, aggregate, arch_step, true);
}
fn wifiProfileRun(b: *std.Build, optimize: std.builtin.OptimizeMode, arch: std.Target.Cpu.Arch, qemu: std.Build.LazyPath, code: std.Build.LazyPath, vars: std.Build.LazyPath, aggregate: *std.Build.Step, arch_step: *std.Build.Step, absent: bool) void {
    const architecture = if (arch == .aarch64) "arm64" else @tagName(arch);
    const kernel = uefiKernel(b, optimize, arch, 0, !absent, absent);
    const image = if (arch == .x86_64)
        uefiApplication(b, optimize, kernel.getEmittedBin(), true, 0).getEmittedBin()
    else
        multiUefiApplication(b, optimize, arch, kernel.getEmittedBin(), true, 0);
    const tree = b.addWriteFiles();
    const filename = switch (arch) {
        .x86_64 => "BOOTX64.EFI",
        .aarch64 => "BOOTAA64.EFI",
        .riscv64 => "BOOTRISCV64.EFI",
        else => unreachable,
    };
    _ = tree.addCopyFile(image, b.fmt("EFI/BOOT/{s}", .{filename}));
    const run = std.Build.Step.Run.create(b, b.fmt("test protected {s} Wi-Fi {s}", .{ architecture, if (absent) "unavailable driver" else "simulated controls" }));
    run.addFileArg(b.findProgramLazy(.{ .names = if (builtin.os.tag == .windows) &.{ "python", "python3" } else &.{"python3"} }));
    run.addFileArg(b.path("tools/test-wifi.py"));
    run.addFileInput(b.path("tools/make-data-image.py"));
    run.addArg(architecture);
    run.addFileArg(qemu);
    run.addDirectoryArg(tree.getDirectory());
    run.addFileArg(code);
    run.addFileArg(vars);
    run.addArgs(&.{ "--mode", if (optimize == .debug) "debug" else "safe", "--artifacts" });
    run.addDirectoryArg(b.path(b.fmt("zig-out/wifi-tests/{s}", .{if (optimize == .debug) "debug" else "safe"})));
    run.addArgs(&.{ "--radio", if (absent) "absent" else "simulated" });
    run.has_side_effects = true;
    aggregate.dependOn(&run.step);
    arch_step.dependOn(&run.step);
}

fn desktopRun(b: *std.Build, optimize: std.builtin.OptimizeMode, architecture: []const u8, qemu: std.Build.LazyPath, esp: std.Build.LazyPath, code: std.Build.LazyPath, vars: std.Build.LazyPath, aggregate: *std.Build.Step) void {
    const run = std.Build.Step.Run.create(b, b.fmt("test native {s} desktop", .{architecture}));
    run.addFileArg(b.findProgramLazy(.{ .names = if (builtin.os.tag == .windows) &.{ "python", "python3" } else &.{"python3"} }));
    run.addFileArg(b.path("tools/test-desktop.py"));
    run.addFileInput(b.path("tools/make-data-image.py"));
    run.addArg(architecture);
    run.addFileArg(qemu);
    run.addDirectoryArg(esp);
    run.addFileArg(code);
    run.addFileArg(vars);
    run.addArg("--artifacts");
    run.addDirectoryArg(b.path(b.fmt("zig-out/desktop-tests/{s}", .{@tagName(optimize)})));
    run.has_side_effects = true;
    aggregate.dependOn(&run.step);
    b.step(b.fmt("test-desktop-{s}", .{architecture}), "Test protected Files through real input and reboot the same data disk").dependOn(&run.step);
}

fn uefiDiskImage(b: *std.Build, application: std.Build.LazyPath, basename: []const u8) std.Build.LazyPath {
    const python = b.findProgramLazy(.{ .names = if (builtin.os.tag == .windows) &.{ "python", "python3" } else &.{"python3"} });
    const run = std.Build.Step.Run.create(b, "make UEFI disk image");
    run.addFileArg(python);
    run.addFileArg(b.path("tools/make-uefi-image.py"));
    run.addFileArg(application);
    return run.addOutputFileArg(basename);
}

fn buildFirmware(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, platform: BootPlatform, image: std.Build.LazyPath, smoke: bool) *std.Build.Step.Compile {
    const dep = b.dependency("bootloader", .{ .target = target, .optimize = optimize, .@"smoke-test" = smoke });
    const module = dep.module(b.fmt("{s}_firmware", .{platform.name}));
    module.addAnonymousImport("kernel_image", .{ .root_source_file = image });
    const firmware = b.addExecutable(.{
        .name = b.fmt("bedrock-bootloader-{s}{s}", .{ platform.name, if (smoke) "-smoke" else "" }),
        .root_module = module,
        .use_llvm = true,
        .use_lld = true,
    });
    firmware.entry = .{ .symbol_name = "_start" };
    firmware.setLinkerScript(dep.path(b.fmt("src/platform/{s}/linker.ld", .{platform.directory})));
    return firmware;
}
