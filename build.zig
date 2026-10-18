const std = @import("std");
const builtin = @import("builtin");

comptime {
    if (!std.mem.eql(u8, builtin.zig_version_string, "0.17.0"))
        @compileError("Bedrock requires Zig 0.17.0. Run zvm use 0.17.0 or use tools/zig.ps1 (tools/zig.sh on Unix).");
}

const Profile = struct { name: []const u8, arch: std.Target.Cpu.Arch };
const WifiImageOptions = struct { directory: ?[]const u8, board: ?[]const u8 };
const DriverArtifact = struct { image: std.Build.LazyPath, package: ?std.Build.LazyPath = null };
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
    const wifi_image_options: WifiImageOptions = .{
        .directory = b.option([]const u8, "wifi-firmware-dir", "Local directory containing the pinned MT7922 patch, RAM and LICENCE.mediatek (no downloads)"),
        .board = b.option([]const u8, "wifi-board-profile", "Optional actual-board MT7922.board profile; absence keeps physical radio unavailable"),
    };
    const check = b.step("check", "Compile every component for all three freestanding targets");
    const test_step = b.step("test", "Run native OS, AxisUI layout/rendering and desktop shell tests");
    _ = b.step("app-runtime", "Build installed applications and persistent user-space init for all architectures");
    _ = b.step("test-apps", "Verify installed apps, fault recovery and balanced teardown on all three UEFI references");
    _ = b.step("display", "Build protected compositor and independent native surface clients");
    _ = b.step("test-display", "Verify surface ownership, real pixels, focused input and client crash recovery");
    _ = b.step("desktop", "Build Files, Notes, native windows, tiling and workspaces");
    _ = b.step("windows", "Build the protected native window desktop for all architectures");
    _ = b.step("service-desktop", "Build the retained single-window service desktop regression profile");
    _ = b.step("test-window-desktop", "Verify independent apps, resizing, tiling, workspaces and durable reboot");
    _ = b.step("test-system-menus", "Verify native app/system menus, smooth icons, firmware time and Control Center");
    _ = b.step("installer", "Build native firmware installer media for all three architectures");
    _ = b.step("test-installer", "Install to owned virtual disks and boot the installed OS without installer media");
    const installer_units = b.step("test-installer-units", "Verify partition planning, installer source guards and native confirmation UI");
    const installer_tests = b.addTest(.{ .root_module = installerModule(b, b.graph.host, optimize, "userspace/apps/installer/src/tests.zig") });
    const installer_run = b.addRunArtifact(installer_tests);
    installer_units.dependOn(&installer_run.step);
    test_step.dependOn(&installer_run.step);
    const test_window_units = b.step("test-window-units", "Verify native window policy, SDK and independent artifact evidence");
    const test_anvil = b.step("test-anvil", "Verify Anvil commands, CPU resources, fences and framebuffer presentation");
    const anvil_evidence_tests = b.addSystemCommand(&.{"python"});
    anvil_evidence_tests.addFileArg(b.path("tools/test-anvil-runtime.py"));
    anvil_evidence_tests.addFileInput(b.path("tools/test-system-menus.py"));
    test_anvil.dependOn(&anvil_evidence_tests.step);
    test_step.dependOn(&anvil_evidence_tests.step);
    _ = b.step("test-anvil-desktop", "Verify Anvil software presentation through the protected desktop on all architectures");
    _ = b.step("test-service-desktop", "Verify native user-space Files, shell, window controls and durable reboot");
    const test_app_units = b.step("test-app-units", "Verify application archives, startup records, heaps and launch policy");
    _ = b.step("wifi-uefi", "Package all three UEFI images with explicitly local pinned Wi-Fi firmware and optional board profile");
    _ = b.step("test-wifi-boot", "Boot actual pinned EFI assets and damaged assets on all architectures without a physical radio");
    _ = b.step("drivers", "Build separately linked driver packages with versioned C interfaces");
    _ = b.step("test-driver-modules", "Verify driver ELF/ABI/packages and execute an isolated test module on all UEFI references");
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
            .{ .dependency = "anvil", .artifact = "bedrock-anvil" },
            .{ .dependency = "anvil_core", .artifact = "bedrock-anvil-core" },
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
        inline for (.{ "bedrock-user-init", "bedrock-user-service", "bedrock-user-fault", "bedrock-user-io", "bedrock-user-exec", "bedrock-user-files", "bedrock-user-network", "bedrock-user-wifi", "bedrock-app-init", "bedrock-app-observer", "bedrock-app-worker", "bedrock-display-init", "bedrock-display-server", "bedrock-surface-client", "bedrock-desktop-init", "bedrock-desktop-server", "bedrock-desktop-shell", "bedrock-desktop-files", "bedrock-window-init", "bedrock-window-server", "bedrock-window-shell", "bedrock-window-files", "bedrock-window-notes" }) |image| {
            profile_check.dependOn(&userland.artifact(image).step);
        }
    }
    inline for (.{ .{ "boot_protocol", "boot_protocol" }, .{ "filesystem", "filesystem" }, .{ "axisui", "axisui" }, .{ "anvil", "anvil" }, .{ "anvil_core", "anvil_core" }, .{ "networkkit", "networkkit" }, .{ "network_core", "network_core" }, .{ "desktop_shell", "desktop_shell" }, .{ "files_app", "files_app" }, .{ "window_server", "window_server" } }) |component| {
        const dep = b.dependency(component[0], .{ .target = b.graph.host, .optimize = optimize });
        const tests = b.addTest(.{ .name = b.fmt("{s}-tests", .{component[0]}), .root_module = dep.module(component[1]) });
        const run = b.addRunArtifact(tests);
        test_step.dependOn(&run.step);
        if (std.mem.eql(u8, component[0], "anvil") or std.mem.eql(u8, component[0], "anvil_core")) test_anvil.dependOn(&run.step);
        if (std.mem.eql(u8, component[0], "files_app") or std.mem.eql(u8, component[0], "axisui")) test_window_units.dependOn(&run.step);
    }
    const native_protocol = b.dependency("boot_protocol", .{ .target = b.graph.host, .optimize = optimize }).module("boot_protocol");
    const native_anvil_core = b.dependency("anvil_core", .{ .target = b.graph.host, .optimize = optimize }).module("anvil_core");
    const gpu_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("drivers/gpu/framebuffer.zig"),
        .target = b.graph.host,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "boot_protocol", .module = native_protocol },
            .{ .name = "anvil_core", .module = native_anvil_core },
            .{ .name = "anvil", .module = native_anvil_core.import_table.get("anvil").? },
        },
    }) });
    const gpu_run = b.addRunArtifact(gpu_tests);
    test_anvil.dependOn(&gpu_run.step);
    test_window_units.dependOn(&gpu_run.step);
    test_step.dependOn(&gpu_run.step);
    const native_driver_abi = b.createModule(.{ .root_source_file = b.path("frameworks/private/DriverKit/src/abi.zig"), .target = b.graph.host, .optimize = optimize });
    for ([_][]const u8{ "frameworks/private/DriverKit/src/root.zig", "frameworks/private/DriverKit/src/test_module.zig" }) |source| {
        const tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path(source), .target = b.graph.host, .optimize = optimize, .imports = &.{.{ .name = "driver_abi", .module = native_driver_abi }} }) });
        const run = b.addRunArtifact(tests);
        test_step.dependOn(&run.step);
        b.top_level_steps.get("test-driver-modules").?.step.dependOn(&run.step);
    }
    const package_tests = b.addSystemCommand(&.{"python"});
    package_tests.addFileArg(b.path("tools/test-driver-packages.py"));
    package_tests.addFileInput(b.path("tools/package-drivers.py"));
    package_tests.addFileInput(b.path("tools/describe-driver-package.py"));
    package_tests.addFileInput(b.path("tools/stage-driver-build.py"));
    package_tests.addFileInput(b.path("drivers/catalogue.json"));
    test_step.dependOn(&package_tests.step);
    b.top_level_steps.get("test-driver-modules").?.step.dependOn(&package_tests.step);
    const module_adapter_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("kernel/src/core/wifi_module_adapter_tests.zig"),
        .target = b.graph.host,
        .optimize = optimize,
        .imports = &.{ .{ .name = "driver_abi", .module = native_driver_abi }, .{ .name = "network_core", .module = b.dependency("network_core", .{ .target = b.graph.host, .optimize = optimize }).module("network_core") } },
    }) });
    test_step.dependOn(&b.addRunArtifact(module_adapter_tests).step);
    const native_mt7922 = b.createModule(.{
        .root_source_file = b.path("drivers/mt7922/src/entry.zig"),
        .target = b.graph.host,
        .optimize = optimize,
        .imports = &.{ .{ .name = "driver_abi", .module = native_driver_abi }, .{ .name = "boot_protocol", .module = native_protocol } },
    });
    const native_module_memory = addMt7922Imports(b, native_mt7922, b.graph.host, optimize, native_protocol, native_driver_abi);
    for ([_]*std.Build.Module{ native_mt7922, native_module_memory }) |native_module| {
        const tests = b.addTest(.{ .root_module = native_module });
        const run = b.addRunArtifact(tests);
        test_step.dependOn(&run.step);
        b.top_level_steps.get("test-driver-modules").?.step.dependOn(&run.step);
    }
    const native_board = b.createModule(.{ .root_source_file = b.path("drivers/wifi/src/board_boot.zig"), .target = b.graph.host, .optimize = optimize });
    const assets_tests = b.addTest(.{ .name = "wifi-boot-assets-tests", .root_module = b.createModule(.{
        .root_source_file = b.path("bootloader/src/platform/uefi/wifi_assets.zig"),
        .target = b.graph.host,
        .optimize = optimize,
        .imports = &.{ .{ .name = "boot_protocol", .module = native_protocol }, .{ .name = "mt7922_board", .module = native_board } },
    }) });
    const boot_assets_step = b.step("test-wifi-boot-assets", "Verify optional EFI firmware/profile/RNG staging and resource cleanup");
    const assets_run = b.addRunArtifact(assets_tests);
    boot_assets_step.dependOn(&assets_run.step);
    test_step.dependOn(&assets_run.step);
    for ([_][]const u8{ "tools/test-wifi-board-profile.py", "tools/test-uefi-image.py" }) |script| {
        const run = std.Build.Step.Run.create(b, script);
        run.addFileArg(b.findProgramLazy(.{ .names = if (builtin.os.tag == .windows) &.{ "python", "python3" } else &.{"python3"} }));
        run.addFileArg(b.path(script));
        run.addFileInput(b.path(if (std.mem.endsWith(u8, script, "board-profile.py")) "tools/make-wifi-board-profile.py" else "tools/make-uefi-image.py"));
        if (std.mem.endsWith(u8, script, "uefi-image.py")) {
            run.addFileInput(b.path("tools/package-drivers.py"));
            run.addFileInput(b.path("drivers/catalogue.json"));
            run.addFileInput(b.path("tools/package-apps.py"));
            run.addFileInput(b.path("userspace/runtime/installed-apps.json"));
        }
        test_step.dependOn(&run.step);
        boot_assets_step.dependOn(&run.step);
    }
    const boot_setup_tests = b.addTest(.{ .name = "wifi-boot-preflight-tests", .root_module = b.createModule(.{
        .root_source_file = b.path("drivers/mt7922/src/boot.zig"),
        .target = b.graph.host,
        .optimize = optimize,
        .imports = &.{ .{ .name = "boot_protocol", .module = native_protocol }, .{ .name = "wifi_drivers", .module = b.dependency("kernel", .{ .target = b.graph.host, .optimize = optimize }).module("wifi_drivers") } },
    }) });
    const boot_setup_run = b.addRunArtifact(boot_setup_tests);
    boot_assets_step.dependOn(&boot_setup_run.step);
    test_step.dependOn(&boot_setup_run.step);
    for (profiles) |profile| {
        const target = if (profile.arch == .x86_64) b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .uefi, .abi = .msvc, .cpu_model = .baseline }) else runtimeTarget(b, profile.arch);
        const boot_module = b.dependency("boot_protocol", .{ .target = target, .optimize = optimize }).module("boot_protocol");
        const probe = b.addObject(.{ .name = b.fmt("wifi-uefi-assets-{s}", .{profile.name}), .root_module = b.createModule(.{
            .root_source_file = b.path("bootloader/src/platform/uefi/wifi_assets_compile_check.zig"),
            .target = target,
            .optimize = optimize,
            .stack_check = false,
            .stack_protector = false,
            .imports = &.{ .{ .name = "boot_protocol", .module = boot_module }, .{ .name = "mt7922_board", .module = b.createModule(.{ .root_source_file = b.path("drivers/wifi/src/board_boot.zig"), .target = target, .optimize = optimize }) } },
        }), .use_llvm = true, .use_lld = true });
        check.dependOn(&probe.step);
        boot_assets_step.dependOn(&probe.step);
        const board_probe = b.addObject(.{ .name = b.fmt("wifi-board-{s}", .{profile.name}), .root_module = b.createModule(.{
            .root_source_file = b.path("drivers/wifi/src/board_check.zig"),
            .target = runtimeTarget(b, profile.arch),
            .optimize = optimize,
            .stack_check = false,
            .stack_protector = false,
            .pic = true,
            .code_model = if (profile.arch == .riscv64) .medium else .default,
        }), .use_llvm = true, .use_lld = true });
        check.dependOn(&board_probe.step);
        boot_assets_step.dependOn(&board_probe.step);
    }
    const native_filesystem = b.dependency("filesystem", .{ .target = b.graph.host, .optimize = optimize }).module("filesystem");
    const native_security = b.dependency("kernel", .{ .target = b.graph.host, .optimize = optimize }).module("security");
    const native_app_bundles = b.createModule(.{ .root_source_file = b.path("userspace/runtime/src/bundle_archive.zig"), .target = b.graph.host, .optimize = optimize });
    const native_app_abi = b.createModule(.{ .root_source_file = b.path("userspace/runtime/src/abi.zig"), .target = b.graph.host, .optimize = optimize });
    const native_header = b.dependency("window_server", .{ .target = b.graph.host, .optimize = optimize }).module("window_header");
    for ([_][]const u8{ "kernel/src/core/wall_clock.zig", "kernel/src/core/clock_syscalls.zig", "kernel/src/core/window_message_policy.zig", "kernel/src/core/present_region.zig", "bootloader/src/platform/uefi/wall_clock.zig" }) |source| {
        const tests = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path(source),
            .target = b.graph.host,
            .optimize = optimize,
            .imports = &.{ .{ .name = "boot_protocol", .module = native_protocol }, .{ .name = "bedrock64", .module = native_app_abi } },
        }) });
        const run = b.addRunArtifact(tests);
        test_step.dependOn(&run.step);
        test_window_units.dependOn(&run.step);
    }
    for ([_][]const u8{ "userspace/runtime/src/bundle_archive.zig", "userspace/runtime/src/heap.zig", "userspace/runtime/src/startup.zig", "kernel/src/core/application_policy.zig", "bootloader/src/platform/uefi/app_assets.zig" }) |source| {
        const tests = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path(source),
            .target = b.graph.host,
            .optimize = optimize,
            .imports = &.{ .{ .name = "boot_protocol", .module = native_protocol }, .{ .name = "security", .module = native_security }, .{ .name = "bedrock64", .module = native_app_abi }, .{ .name = "app_bundles", .module = native_app_bundles } },
        }) });
        const run = b.addRunArtifact(tests);
        test_app_units.dependOn(&run.step);
        test_step.dependOn(&run.step);
    }
    const app_package_tests = b.addSystemCommand(&.{"python"});
    app_package_tests.addFileArg(b.path("tools/test-app-packages.py"));
    app_package_tests.addFileInput(b.path("tools/package-apps.py"));
    app_package_tests.addFileInput(b.path("userspace/runtime/installed-apps.json"));
    test_app_units.dependOn(&app_package_tests.step);
    test_step.dependOn(&app_package_tests.step);
    b.top_level_steps.get("test-apps").?.step.dependOn(test_app_units);
    b.top_level_steps.get("test-window-desktop").?.step.dependOn(test_app_units);
    test_window_units.dependOn(test_app_units);
    for ([_][]const u8{ "kernel/src/core/service_ipc.zig", "drivers/gpu/pixel_format.zig", "kernel/src/arch/x86_64/page_table_entry.zig", "userspace/runtime/src/display_wire.zig", "userspace/runtime/src/desktop_client.zig", "userspace/runtime/src/window_wire.zig", "userspace/runtime/src/window_client.zig", "userspace/services/display-server/src/policy.zig" }) |source| {
        const tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path(source), .target = b.graph.host, .optimize = optimize, .imports = &.{ .{ .name = "bedrock64", .module = native_app_abi }, .{ .name = "window_header", .module = native_header } } }) });
        const run = b.addRunArtifact(tests);
        test_step.dependOn(&run.step);
        b.top_level_steps.get("test-display").?.step.dependOn(&run.step);
        b.top_level_steps.get("test-service-desktop").?.step.dependOn(&run.step);
        b.top_level_steps.get("test-window-desktop").?.step.dependOn(&run.step);
        test_window_units.dependOn(&run.step);
    }
    const display_runner_tests = b.addSystemCommand(&.{"python"});
    display_runner_tests.addFileArg(b.path("tools/test-display-runtime-units.py"));
    for ([_][]const u8{ "tools/test-display-runtime.py", "tools/test-application-runtime.py", "tools/test-desktop.py", "tools/make-data-image.py" }) |source| display_runner_tests.addFileInput(b.path(source));
    test_step.dependOn(&display_runner_tests.step);
    b.top_level_steps.get("test-display").?.step.dependOn(&display_runner_tests.step);
    const desktop_runner_tests = b.addSystemCommand(&.{"python"});
    desktop_runner_tests.addFileArg(b.path("tools/test-service-desktop-units.py"));
    for ([_][]const u8{ "tools/test-service-desktop.py", "tools/test-desktop.py", "tools/test-application-runtime.py", "tools/test-display-runtime.py", "tools/make-data-image.py" }) |source| desktop_runner_tests.addFileInput(b.path(source));
    desktop_runner_tests.addFileInput(b.path("frameworks/public/AxisUI/axis-sans.json"));
    test_step.dependOn(&desktop_runner_tests.step);
    b.top_level_steps.get("test-service-desktop").?.step.dependOn(&desktop_runner_tests.step);
    const policy_axis = b.dependency("axisui", .{ .target = b.graph.host, .optimize = optimize }).module("axisui");
    const policy_shell = b.dependency("desktop_shell", .{ .target = b.graph.host, .optimize = optimize }).module("desktop_shell");
    const policy_window = b.dependency("window_server", .{ .target = b.graph.host, .optimize = optimize }).module("window_server");
    policy_shell.addImport("axisui", policy_axis);
    policy_window.addImport("axisui", policy_axis);
    const policy_runtime = b.createModule(.{ .root_source_file = b.path("userspace/runtime/src/root.zig"), .target = b.graph.host, .optimize = optimize, .imports = &.{ .{ .name = "bedrock64", .module = native_app_abi }, .{ .name = "window_header", .module = native_header }, .{ .name = "networkkit", .module = b.dependency("networkkit", .{ .target = b.graph.host, .optimize = optimize }).module("networkkit") } } });
    const desktop_policy_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("userspace/services/display-server/src/desktop_policy.zig"), .target = b.graph.host, .optimize = optimize, .imports = &.{ .{ .name = "axisui", .module = policy_axis }, .{ .name = "desktop_shell", .module = policy_shell }, .{ .name = "window_server", .module = policy_window }, .{ .name = "bedrock64", .module = native_app_abi }, .{ .name = "userspace_runtime", .module = policy_runtime } } }) });
    const desktop_policy_run = b.addRunArtifact(desktop_policy_tests);
    test_step.dependOn(&desktop_policy_run.step);
    b.top_level_steps.get("test-service-desktop").?.step.dependOn(&desktop_policy_run.step);
    const window_policy_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("userspace/services/display-server/src/window_policy.zig"), .target = b.graph.host, .optimize = optimize, .imports = &.{ .{ .name = "axisui", .module = policy_axis }, .{ .name = "desktop_shell", .module = policy_shell }, .{ .name = "window_server", .module = policy_window }, .{ .name = "bedrock64", .module = native_app_abi }, .{ .name = "userspace_runtime", .module = policy_runtime } } }) });
    const window_policy_run = b.addRunArtifact(window_policy_tests);
    test_step.dependOn(&window_policy_run.step);
    b.top_level_steps.get("test-window-desktop").?.step.dependOn(&window_policy_run.step);
    test_window_units.dependOn(&window_policy_run.step);
    const retained_frame_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("userspace/services/display-server/src/retained_frame.zig"),
        .target = b.graph.host,
        .optimize = optimize,
        .imports = &.{.{ .name = "userspace_runtime", .module = policy_runtime }},
    }) });
    const retained_frame_run = b.addRunArtifact(retained_frame_tests);
    test_window_units.dependOn(&retained_frame_run.step);
    test_step.dependOn(&retained_frame_run.step);
    const glass_frame_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("userspace/services/display-server/src/glass_frame.zig"),
        .target = b.graph.host,
        .optimize = optimize,
        .imports = &.{.{ .name = "axisui", .module = policy_axis }},
    }) });
    const glass_frame_run = b.addRunArtifact(glass_frame_tests);
    test_window_units.dependOn(&glass_frame_run.step);
    test_step.dependOn(&glass_frame_run.step);
    const frame_fill_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("userspace/services/display-server/src/frame_fill_tests.zig"),
        .target = b.graph.host,
        .optimize = optimize,
        .imports = &.{.{ .name = "axisui", .module = policy_axis }},
    }) });
    const frame_fill_run = b.addRunArtifact(frame_fill_tests);
    test_window_units.dependOn(&frame_fill_run.step);
    test_step.dependOn(&frame_fill_run.step);
    for ([_][]const u8{
        "userspace/apps/shell/src/wallpaper_tests.zig",
        "userspace/services/display-server/src/wallpaper_cache_tests.zig",
    }) |source| {
        const tests = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path(source),
            .target = b.graph.host,
            .optimize = optimize,
            .imports = &.{.{ .name = "axisui", .module = policy_axis }},
        }) });
        const run = b.addRunArtifact(tests);
        test_window_units.dependOn(&run.step);
        test_step.dependOn(&run.step);
    }
    const window_supervisor_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("userspace/apps/init/src/window_supervisor.zig"),
        .target = b.graph.host,
        .optimize = optimize,
        .imports = &.{ .{ .name = "bedrock64", .module = native_app_abi }, .{ .name = "userspace_runtime", .module = policy_runtime } },
    }) });
    const window_supervisor_run = b.addRunArtifact(window_supervisor_tests);
    test_window_units.dependOn(&window_supervisor_run.step);
    test_step.dependOn(&window_supervisor_run.step);
    const notes_navigation_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("userspace/apps/notes/src/editor_navigation.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    }) });
    const notes_navigation_run = b.addRunArtifact(notes_navigation_tests);
    test_window_units.dependOn(&notes_navigation_run.step);
    test_step.dependOn(&notes_navigation_run.step);
    const window_runner_tests = b.addSystemCommand(&.{"python"});
    window_runner_tests.addFileArg(b.path("tools/test-window-desktop-units.py"));
    for ([_][]const u8{ "tools/test-window-desktop.py", "tools/test-system-menus.py", "tools/test-service-desktop.py", "tools/test-desktop.py", "tools/test-application-runtime.py", "tools/test-display-runtime.py", "tools/make-data-image.py" }) |source| window_runner_tests.addFileInput(b.path(source));
    window_runner_tests.addFileInput(b.path("frameworks/public/AxisUI/axis-sans.json"));
    window_runner_tests.addFileInput(b.path("frameworks/public/AxisUI/src/axis_sans.bin"));
    window_runner_tests.addFileInput(b.path("frameworks/public/AxisUI/icon-coverage.json"));
    window_runner_tests.addFileInput(b.path("frameworks/public/AxisUI/src/icons.zig"));
    test_window_units.dependOn(&window_runner_tests.step);
    test_step.dependOn(&window_runner_tests.step);
    const launcher_tests = b.addSystemCommand(&.{"python"});
    launcher_tests.addFileArg(b.path("tools/test-run-uefi.py"));
    launcher_tests.addFileInput(b.path("tools/run-uefi.ps1"));
    launcher_tests.addFileInput(b.path("tools/make-data-image.py"));
    test_window_units.dependOn(&launcher_tests.step);
    test_step.dependOn(&launcher_tests.step);
    b.top_level_steps.get("test-window-desktop").?.step.dependOn(test_window_units);
    const native_wifi_drivers = b.dependency("kernel", .{ .target = b.graph.host, .optimize = optimize }).module("wifi_drivers");
    const wifi_driver_tests = b.addTest(.{ .name = "wifi-driver-tests", .root_module = native_wifi_drivers });
    const wifi_driver_run = b.addRunArtifact(wifi_driver_tests);
    test_step.dependOn(&wifi_driver_run.step);
    b.step("test-wifi-drivers", "Run native chipset, DMA-resource and WPA2 protocol tests").dependOn(&wifi_driver_run.step);
    const wifi_adapter_tests = b.addTest(.{ .name = "wifi-device-adapter-tests", .root_module = b.createModule(.{
        .root_source_file = b.path("drivers/wifi/tests/wifi_device_adapter_tests.zig"),
        .target = b.graph.host,
        .optimize = optimize,
        .imports = &.{ .{ .name = "wifi_drivers", .module = native_wifi_drivers }, .{ .name = "network_core", .module = b.dependency("network_core", .{ .target = b.graph.host, .optimize = optimize }).module("network_core") } },
    }) });
    const wifi_adapter_run = b.addRunArtifact(wifi_adapter_tests);
    test_step.dependOn(&wifi_adapter_run.step);
    const test_station = b.step("test-wifi-station", "Run station/CCMP/DMA/NIC and trusted native SDK adapter tests");
    test_station.dependOn(&wifi_driver_run.step);
    test_station.dependOn(&wifi_adapter_run.step);
    const test_regulatory = b.step("test-wifi-regulatory", "Run country/device policy and MediaTek regulatory command tests plus offline database checks");
    test_regulatory.dependOn(&wifi_driver_run.step);
    const regdb_tests = std.Build.Step.Run.create(b, "test offline wireless regulatory database importer");
    regdb_tests.addFileArg(b.findProgramLazy(.{ .names = if (builtin.os.tag == .windows) &.{ "python", "python3" } else &.{"python3"} }));
    regdb_tests.addFileArg(b.path("tools/test-wifi-regdb.py"));
    regdb_tests.addFileInput(b.path("tools/update-wifi-regdb.py"));
    regdb_tests.addFileInput(b.path("drivers/wifi/src/regulatory/database.zig"));
    regdb_tests.addFileInput(b.path("drivers/wifi/src/regulatory/LICENSE"));
    regdb_tests.addFileInput(b.path("drivers/wifi/src/regulatory/provenance.json"));
    test_regulatory.dependOn(&regdb_tests.step);
    test_step.dependOn(&regdb_tests.step);
    const firmware_references = b.addExecutable(.{ .name = "wifi-firmware-references", .root_module = b.createModule(.{
        .root_source_file = b.path("drivers/wifi/src/firmware_reference_check.zig"),
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
    const broker_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("kernel/src/core/driver_runtime.zig"),
        .target = b.graph.host,
        .optimize = optimize,
        .imports = &.{ .{ .name = "boot_protocol", .module = native_protocol }, .{ .name = "driver_abi", .module = native_driver_abi }, .{ .name = "memory_init", .module = native_memory } },
    }) });
    const broker_run = b.addRunArtifact(broker_tests);
    test_step.dependOn(&broker_run.step);
    b.top_level_steps.get("test-driver-modules").?.step.dependOn(&broker_run.step);
    const driver_assets_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("bootloader/src/platform/uefi/driver_assets.zig"),
        .target = b.graph.host,
        .optimize = optimize,
        .imports = &.{ .{ .name = "boot_protocol", .module = native_protocol }, .{ .name = "driver_kit", .module = b.createModule(.{ .root_source_file = b.path("frameworks/private/DriverKit/src/root.zig"), .target = b.graph.host, .optimize = optimize }) } },
    }) });
    const driver_assets_run = b.addRunArtifact(driver_assets_tests);
    test_step.dependOn(&driver_assets_run.step);
    b.top_level_steps.get("test-driver-modules").?.step.dependOn(&driver_assets_run.step);
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
        const run = b.addRunArtifact(tests);
        test_step.dependOn(&run.step);
        if (std.mem.eql(u8, source, "kernel/src/core/isolation_contract.zig") or std.mem.eql(u8, source, "kernel/src/security/sandbox.zig")) b.top_level_steps.get("test-display").?.step.dependOn(&run.step);
        if (std.mem.eql(u8, source, "kernel/src/core/isolation_contract.zig") or std.mem.eql(u8, source, "kernel/src/core/process.zig") or std.mem.eql(u8, source, "kernel/src/security/sandbox.zig")) b.top_level_steps.get("test-service-desktop").?.step.dependOn(&run.step);
    }
    const images = b.step("images", "Build reset and UEFI boot images for all three architectures");
    const uefi_images = b.step("uefi", "Build the primary UEFI loaders and kernels for all three architectures");
    images.dependOn(uefi_images);
    const test_boot = b.step("test-boot", "Boot reset and UEFI paths for all three architectures in QEMU");
    const test_uefi = b.step("test-uefi", "Verify underlying UEFI boot and embedded lifecycle fixtures on all three architectures");
    const test_desktop = b.step("test-desktop", "Retain the legacy hosted Files/input/storage regression on all three architectures");
    const test_network = b.step("test-network", "Verify protected NetworkKit datagrams over VirtIO networking on all three architectures");
    _ = b.step("test-wifi", "Verify protected Wi-Fi controls using an explicitly simulated radio on all architectures");
    test_boot.dependOn(test_uefi);
    const matrix = b.step("test-boot-matrix", "Verify memory discovery across multiple RAM sizes and boot paths");
    var previous_matrix: ?*std.Build.Step = null;
    const legacy_arm_qemu = b.option([]const u8, "qemu", "Absolute ARM64 QEMU path (also -Dqemu-arm64)");
    for (platforms) |platform| addPlatform(b, optimize, platform, images, uefi_images, test_boot, test_uefi, test_desktop, test_network, matrix, &previous_matrix, legacy_arm_qemu, ram_mib, kernel_min, attach_network, wifi_image_options);
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

fn addPlatform(b: *std.Build, optimize: std.builtin.OptimizeMode, platform: BootPlatform, images: *std.Build.Step, uefi_images: *std.Build.Step, test_boot: *std.Build.Step, test_uefi: *std.Build.Step, test_desktop: *std.Build.Step, test_network: *std.Build.Step, matrix: *std.Build.Step, previous_matrix: *?*std.Build.Step, legacy_arm_qemu: ?[]const u8, ram_mib: u32, kernel_min: u64, attach_network: bool, wifi_images: WifiImageOptions) void {
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
    if (platform.arch == .x86_64) addUefi(b, optimize, qemu, uefi_images, test_uefi, test_desktop, test_network, matrix, previous_matrix, ram_mib, kernel_min, attach_network, wifi_images);
    if (platform.arch != .x86_64) addMultiUefi(b, optimize, platform, qemu, uefi_images, test_uefi, test_desktop, test_network, matrix, previous_matrix, ram_mib, kernel_min, attach_network, wifi_images);
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
    return uefiApplicationVariant(b, optimize, kernel_image, smoke, kernel_min, false);
}
fn uefiApplicationVariant(b: *std.Build, optimize: std.builtin.OptimizeMode, kernel_image: std.Build.LazyPath, smoke: bool, kernel_min: u64, driver_acceptance: bool) *std.Build.Step.Compile {
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
    options.addOption(bool, "driver_acceptance", driver_acceptance);
    module.addOptions("boot_options", options);
    module.addAnonymousImport("kernel_image", .{ .root_source_file = kernel_image });
    module.addImport("elf_loader", b.createModule(.{ .root_source_file = b.path("bootloader/src/core/elf.zig"), .target = target, .optimize = optimize }));
    module.addImport("mt7922_board", b.createModule(.{ .root_source_file = b.path("drivers/wifi/src/board_boot.zig"), .target = target, .optimize = optimize }));
    module.addImport("driver_kit", b.createModule(.{ .root_source_file = b.path("frameworks/private/DriverKit/src/root.zig"), .target = target, .optimize = optimize }));
    module.addImport("app_bundles", b.createModule(.{ .root_source_file = b.path("userspace/runtime/src/bundle_archive.zig"), .target = target, .optimize = optimize }));
    module.addAssemblyFile(dep.path("src/platform/uefi/entry.S"));
    return b.addExecutable(.{ .name = if (driver_acceptance) "bedrock-uefi-x86_64-driver-test" else if (smoke) "bedrock-uefi-x86_64-smoke" else "bedrock-uefi-x86_64", .root_module = module, .use_llvm = true, .use_lld = true });
}

fn addUefi(b: *std.Build, optimize: std.builtin.OptimizeMode, qemu: std.Build.LazyPath, images: *std.Build.Step, test_boot: *std.Build.Step, test_desktop: *std.Build.Step, test_network: *std.Build.Step, matrix: *std.Build.Step, previous_matrix: *?*std.Build.Step, ram_mib: u32, kernel_min: u64, attach_network: bool, wifi_images: WifiImageOptions) void {
    const pie = uefiKernel(b, optimize, .x86_64, 0, false, false);
    images.dependOn(&b.addInstallFile(pie.getEmittedBin(), "legacy-uefi/x86_64/kernel.elf").step);
    const application = uefiApplication(b, optimize, pie.getEmittedBin(), false, kernel_min);
    const driver = driverModule(b, optimize, .x86_64, false);
    addWifiImage(b, .x86_64, application.getEmittedBin(), wifi_images, driver.package.?);
    const install = b.addInstallFile(application.getEmittedBin(), "legacy-uefi/x86_64/EFI/BOOT/BOOTX64.EFI");
    images.dependOn(&install.step);
    b.step("legacy-uefi-x86_64", "Build the Bedrock x86-64 UEFI removable-media application").dependOn(&install.step);
    const normal_tree = b.addWriteFiles();
    _ = normal_tree.addCopyFile(application.getEmittedBin(), "EFI/BOOT/BOOTX64.EFI");
    const smoke = uefiApplication(b, optimize, pie.getEmittedBin(), true, kernel_min);
    const smoke_tree = b.addWriteFiles();
    const smoke_file = smoke_tree.addCopyFile(smoke.getEmittedBin(), "EFI/BOOT/BOOTX64.EFI");
    const code: std.Build.LazyPath = .{ .cwd_relative = b.option([]const u8, "ovmf-code", "OVMF/EDK2 x86-64 firmware code image") orelse if (builtin.os.tag == .windows) "C:\\Program Files\\qemu\\share\\edk2-x86_64-code.fd" else "/usr/share/OVMF/OVMF_CODE.fd" };
    const vars: std.Build.LazyPath = .{ .cwd_relative = b.option([]const u8, "ovmf-vars", "Matching OVMF/EDK2 variable-store template") orelse if (builtin.os.tag == .windows) "C:\\Program Files\\qemu\\share\\edk2-i386-vars.fd" else "/usr/share/OVMF/OVMF_VARS.fd" };
    applicationRuntime(b, optimize, .x86_64, qemu, code, vars, ram_mib, kernel_min, false);
    applicationRuntime(b, optimize, .x86_64, qemu, code, vars, ram_mib, kernel_min, true);
    installedDesktop(b, optimize, .x86_64, qemu, code, vars, ram_mib, kernel_min, images, attach_network, false);
    installedDesktop(b, optimize, .x86_64, qemu, code, vars, ram_mib, kernel_min, images, attach_network, true);
    driverModuleRun(b, optimize, .x86_64, qemu, pie.getEmittedBin(), code, vars);
    driverPolicyRun(b, .x86_64, qemu, smoke.getEmittedBin(), code, vars, driver.image);
    wifiAssetsRun(b, .x86_64, qemu, smoke.getEmittedBin(), code, vars, wifi_images);
    desktopRun(b, optimize, "x86_64", qemu, normal_tree.getDirectory(), code, vars, test_desktop);
    networkRun(b, optimize, .x86_64, qemu, code, vars, test_network);
    wifiRun(b, optimize, .x86_64, qemu, code, vars, &b.top_level_steps.get("test-wifi").?.step);
    const disk_image = uefiDiskImage(b, application.getEmittedBin(), "bedrock-x86_64-uefi.img");
    const disk_install = b.addInstallFile(disk_image, "legacy-uefi/x86_64/bedrock-uefi.img");
    const image_step = b.step("legacy-uefi-image-x86_64", "Build a standalone GPT/FAT32 UEFI disk image (requires Python 3)");
    image_step.dependOn(&install.step);
    image_step.dependOn(&disk_install.step);
    const smoke_disk = uefiDiskImage(b, smoke.getEmittedBin(), "bedrock-x86_64-uefi-smoke.img");
    const python = b.findProgramLazy(.{ .names = if (builtin.os.tag == .windows) &.{ "python", "python3" } else &.{"python3"} });
    const image_tests = std.Build.Step.Run.create(b, "test UEFI image format");
    image_tests.addFileArg(python);
    image_tests.addFileArg(b.path("tools/test-uefi-image.py"));
    image_tests.addFileInput(b.path("tools/make-uefi-image.py"));
    image_tests.addFileInput(b.path("tools/package-drivers.py"));
    image_tests.addFileInput(b.path("drivers/catalogue.json"));
    image_tests.addFileInput(b.path("tools/package-apps.py"));
    image_tests.addFileInput(b.path("userspace/runtime/installed-apps.json"));
    const image_check = std.Build.Step.Run.create(b, "check UEFI disk image");
    image_check.addFileArg(python);
    image_check.addFileArg(b.path("tools/test-uefi-image.py"));
    image_check.addFileInput(b.path("tools/make-uefi-image.py"));
    image_check.addFileInput(b.path("tools/package-drivers.py"));
    image_check.addFileInput(b.path("drivers/catalogue.json"));
    image_check.addFileInput(b.path("tools/package-apps.py"));
    image_check.addFileInput(b.path("userspace/runtime/installed-apps.json"));
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
    b.step("run-legacy-uefi-x86_64", "Boot the normal UEFI image with a visible framebuffer (Ctrl+C to stop)").dependOn(&run.step);
}

fn uefiKernel(b: *std.Build, optimize: std.builtin.OptimizeMode, arch: std.Target.Cpu.Arch, network_echo_port: u16, wifi_acceptance: bool, wifi_absence_probe: bool) *std.Build.Step.Compile {
    return uefiKernelVariant(b, optimize, arch, network_echo_port, wifi_acceptance, wifi_absence_probe, false, false);
}
fn uefiKernelVariant(b: *std.Build, optimize: std.builtin.OptimizeMode, arch: std.Target.Cpu.Arch, network_echo_port: u16, wifi_acceptance: bool, wifi_absence_probe: bool, app_runtime: bool, app_acceptance: bool) *std.Build.Step.Compile {
    return uefiKernelProfile(b, optimize, arch, network_echo_port, wifi_acceptance, wifi_absence_probe, app_runtime, app_acceptance, false);
}
fn uefiKernelProfile(b: *std.Build, optimize: std.builtin.OptimizeMode, arch: std.Target.Cpu.Arch, network_echo_port: u16, wifi_acceptance: bool, wifi_absence_probe: bool, app_runtime: bool, app_acceptance: bool, display_runtime: bool) *std.Build.Step.Compile {
    return uefiKernelDesktopProfile(b, optimize, arch, network_echo_port, wifi_acceptance, wifi_absence_probe, app_runtime, app_acceptance, display_runtime, false);
}
fn uefiKernelDesktopProfile(b: *std.Build, optimize: std.builtin.OptimizeMode, arch: std.Target.Cpu.Arch, network_echo_port: u16, wifi_acceptance: bool, wifi_absence_probe: bool, app_runtime: bool, app_acceptance: bool, display_runtime: bool, desktop_runtime: bool) *std.Build.Step.Compile {
    return uefiKernelWindowProfile(b, optimize, arch, network_echo_port, wifi_acceptance, wifi_absence_probe, app_runtime, app_acceptance, display_runtime, desktop_runtime, false);
}
fn uefiKernelWindowProfile(b: *std.Build, optimize: std.builtin.OptimizeMode, arch: std.Target.Cpu.Arch, network_echo_port: u16, wifi_acceptance: bool, wifi_absence_probe: bool, app_runtime: bool, app_acceptance: bool, display_runtime: bool, desktop_runtime: bool, window_runtime: bool) *std.Build.Step.Compile {
    const target = runtimeTarget(b, arch);
    const dep = b.dependency("kernel", .{ .target = target, .optimize = optimize, .relocatable = true, .uefi_entry = true, .network_echo_port = network_echo_port, .wifi_acceptance = wifi_acceptance, .wifi_absence_probe = wifi_absence_probe, .app_runtime = app_runtime, .app_acceptance = app_acceptance, .display_runtime = display_runtime, .desktop_runtime = desktop_runtime, .window_runtime = window_runtime });
    const name = if (arch == .aarch64) "arm64" else @tagName(arch);
    const userland = b.dependency("userspace_runtime", .{ .target = target, .optimize = optimize });
    inline for (.{ .{ "bedrock-user-init", "init" }, .{ "bedrock-user-service", "service" }, .{ "bedrock-user-fault", "fault" }, .{ "bedrock-user-io", "io" }, .{ "bedrock-user-exec", "exec" }, .{ "bedrock-user-files", "files" }, .{ "bedrock-user-network", "network" }, .{ "bedrock-user-wifi", "wifi" } }) |image| {
        const install = b.addInstallFile(userland.artifact(image[0]).getEmittedBin(), b.fmt("userspace/{s}/{s}.elf", .{ name, image[1] }));
        b.getInstallStep().dependOn(&install.step);
    }
    const kernel = b.addExecutable(.{ .name = b.fmt("bedrock-kernel-{s}-pie{s}", .{ name, if (window_runtime) (if (app_acceptance) "-windows-test" else "-windows") else if (desktop_runtime) (if (app_acceptance) "-desktop-test" else "-desktop") else if (display_runtime) (if (app_acceptance) "-display-test" else "-display") else if (app_acceptance) "-apps-test" else if (app_runtime) "-apps" else "" }), .root_module = dep.module(b.fmt("{s}_kernel", .{name})), .use_llvm = true, .use_lld = true });
    kernel.pie = true;
    kernel.entry = .{ .symbol_name = "_start" };
    kernel.setLinkerScript(dep.path("src/platform/uefi/linker.ld"));
    return kernel;
}

fn multiUefiApplication(b: *std.Build, optimize: std.builtin.OptimizeMode, arch: std.Target.Cpu.Arch, image: std.Build.LazyPath, smoke: bool, kernel_min: u64) std.Build.LazyPath {
    return multiUefiApplicationVariant(b, optimize, arch, image, smoke, kernel_min, false);
}
fn multiUefiApplicationVariant(b: *std.Build, optimize: std.builtin.OptimizeMode, arch: std.Target.Cpu.Arch, image: std.Build.LazyPath, smoke: bool, kernel_min: u64, driver_acceptance: bool) std.Build.LazyPath {
    const target = if (arch == .riscv64) runtimeTarget(b, arch) else b.resolveTargetQuery(.{ .cpu_arch = arch, .os_tag = .uefi, .abi = .none, .cpu_model = .{ .explicit = &std.Target.aarch64.cpu.cortex_a57 }, .cpu_features_add = std.Target.aarch64.featureSet(&.{.strict_align}) });
    const protocol = b.dependency("boot_protocol", .{ .target = target, .optimize = optimize }).module("boot_protocol");
    const options = b.addOptions();
    options.addOption(bool, "smoke_test", smoke);
    options.addOption(u64, "kernel_min", kernel_min);
    options.addOption(bool, "driver_acceptance", driver_acceptance);
    const common = b.createModule(.{ .root_source_file = b.path("bootloader/src/platform/uefi/multiarch.zig"), .target = target, .optimize = optimize, .imports = &.{
        .{ .name = "boot_protocol", .module = protocol },
        .{ .name = "device_tree", .module = b.createModule(.{ .root_source_file = b.path("bootloader/src/core/device_tree.zig"), .target = target, .optimize = optimize }) },
        .{ .name = "elf_loader", .module = b.createModule(.{ .root_source_file = b.path("bootloader/src/core/elf.zig"), .target = target, .optimize = optimize }) },
        .{ .name = "uefi_memory", .module = b.createModule(.{ .root_source_file = b.path("bootloader/src/platform/uefi/memory.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "boot_protocol", .module = protocol }} }) },
    } });
    const boot_options = options.createModule();
    common.addImport("boot_options", boot_options);
    common.addImport("mt7922_board", b.createModule(.{ .root_source_file = b.path("drivers/wifi/src/board_boot.zig"), .target = target, .optimize = optimize }));
    common.addImport("driver_kit", b.createModule(.{ .root_source_file = b.path("frameworks/private/DriverKit/src/root.zig"), .target = target, .optimize = optimize }));
    common.addImport("app_bundles", b.createModule(.{ .root_source_file = b.path("userspace/runtime/src/bundle_archive.zig"), .target = target, .optimize = optimize }));
    common.addAnonymousImport("kernel_image", .{ .root_source_file = image });
    const module = b.createModule(.{ .root_source_file = b.path(b.fmt("bootloader/src/platform/uefi/{s}/main.zig", .{@tagName(arch)})), .target = target, .optimize = optimize, .stack_check = false, .stack_protector = false, .single_threaded = true, .pic = true, .code_model = if (arch == .riscv64) .medium else .default, .imports = &.{ .{ .name = "uefi_common", .module = common }, .{ .name = "boot_protocol", .module = protocol } } });
    module.addImport("boot_options", boot_options);
    module.addAssemblyFile(b.path(b.fmt("bootloader/src/platform/uefi/{s}/entry.S", .{@tagName(arch)})));
    const compile = b.addExecutable(.{ .name = b.fmt("bedrock-uefi-{s}{s}", .{ @tagName(arch), if (driver_acceptance) "-driver-test" else if (smoke) "-smoke" else "" }), .root_module = module, .use_llvm = true, .use_lld = true });
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

fn addMultiUefi(b: *std.Build, optimize: std.builtin.OptimizeMode, platform: BootPlatform, qemu: std.Build.LazyPath, images: *std.Build.Step, test_boot: *std.Build.Step, test_desktop: *std.Build.Step, test_network: *std.Build.Step, matrix: *std.Build.Step, previous_matrix: *?*std.Build.Step, ram_mib: u32, kernel_min: u64, attach_network: bool, wifi_images: WifiImageOptions) void {
    const arch = platform.arch;
    const pie = uefiKernel(b, optimize, arch, 0, false, false);
    const normal = multiUefiApplication(b, optimize, arch, pie.getEmittedBin(), false, kernel_min);
    const driver = driverModule(b, optimize, arch, false);
    addWifiImage(b, arch, normal, wifi_images, driver.package.?);
    const smoke = multiUefiApplication(b, optimize, arch, pie.getEmittedBin(), true, kernel_min);
    const filename = if (arch == .aarch64) "BOOTAA64.EFI" else "BOOTRISCV64.EFI";
    const install = b.addInstallFile(normal, b.fmt("legacy-uefi/{s}/EFI/BOOT/{s}", .{ platform.name, filename }));
    images.dependOn(&install.step);
    images.dependOn(&b.addInstallFile(pie.getEmittedBin(), b.fmt("legacy-uefi/{s}/kernel.elf", .{platform.name})).step);
    b.step(b.fmt("legacy-uefi-{s}", .{platform.name}), "Build the relocatable standard firmware loader and kernel").dependOn(&install.step);
    const tree = b.addWriteFiles();
    const file = tree.addCopyFile(smoke, b.fmt("EFI/BOOT/{s}", .{filename}));
    const code: std.Build.LazyPath = .{ .cwd_relative = b.option([]const u8, b.fmt("uefi-code-{s}", .{platform.name}), "Architecture firmware code image") orelse if (builtin.os.tag == .windows) b.fmt("C:\\Program Files\\qemu\\share\\edk2-{s}-code.fd", .{if (arch == .aarch64) "aarch64" else "riscv"}) else b.fmt("/usr/share/qemu/edk2-{s}-code.fd", .{if (arch == .aarch64) "aarch64" else "riscv"}) };
    const vars: std.Build.LazyPath = .{ .cwd_relative = b.option([]const u8, b.fmt("uefi-vars-{s}", .{platform.name}), "Matching architecture firmware variable-store template") orelse if (builtin.os.tag == .windows) b.fmt("C:\\Program Files\\qemu\\share\\edk2-{s}-vars.fd", .{if (arch == .aarch64) "arm" else "riscv"}) else b.fmt("/usr/share/qemu/edk2-{s}-vars.fd", .{if (arch == .aarch64) "arm" else "riscv"}) };
    applicationRuntime(b, optimize, arch, qemu, code, vars, ram_mib, kernel_min, false);
    applicationRuntime(b, optimize, arch, qemu, code, vars, ram_mib, kernel_min, true);
    installedDesktop(b, optimize, arch, qemu, code, vars, ram_mib, kernel_min, images, attach_network, false);
    installedDesktop(b, optimize, arch, qemu, code, vars, ram_mib, kernel_min, images, attach_network, true);
    driverModuleRun(b, optimize, arch, qemu, pie.getEmittedBin(), code, vars);
    wifiAssetsRun(b, arch, qemu, smoke, code, vars, wifi_images);
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
    b.step(b.fmt("run-legacy-uefi-{s}", .{platform.name}), "Boot the normal firmware image (Ctrl+C to stop)").dependOn(&interactive.step);
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
    run.addFileInput(b.path("tools/package-apps.py"));
    run.addFileInput(b.path("userspace/runtime/installed-apps.json"));
    run.addFileArg(application);
    return run.addOutputFileArg(basename);
}

fn applicationRuntime(b: *std.Build, optimize: std.builtin.OptimizeMode, arch: std.Target.Cpu.Arch, qemu: std.Build.LazyPath, code: std.Build.LazyPath, vars: std.Build.LazyPath, ram_mib: u32, kernel_min: u64, display_runtime: bool) void {
    const name = if (arch == .aarch64) "arm64" else @tagName(arch);
    const filename = switch (arch) {
        .x86_64 => "BOOTX64.EFI",
        .aarch64 => "BOOTAA64.EFI",
        .riscv64 => "BOOTRISCV64.EFI",
        else => unreachable,
    };
    const userland = b.dependency("userspace_runtime", .{ .target = runtimeTarget(b, arch), .optimize = optimize });
    const package = b.addSystemCommand(&.{"python"});
    package.addFileArg(b.path("tools/package-apps.py"));
    const catalogue = if (display_runtime) "userspace/runtime/display-apps.json" else "userspace/runtime/installed-apps.json";
    package.addFileInput(b.path(catalogue));
    if (display_runtime) {
        package.addArg("--catalogue");
        package.addFileArg(b.path(catalogue));
    }
    package.addArgs(&.{ "--arch", @tagName(arch), "--output" });
    const archive = package.addOutputFileArg("apps.bap");
    const installed = if (display_runtime) &[_][2][]const u8{ .{ "bedrock-display-init", "org.bedrock.init" }, .{ "bedrock-display-server", "org.bedrock.display-server" }, .{ "bedrock-surface-client", "org.bedrock.surface-one" }, .{ "bedrock-surface-client", "org.bedrock.surface-two" } } else &[_][2][]const u8{ .{ "bedrock-app-init", "org.bedrock.init" }, .{ "bedrock-app-observer", "org.bedrock.observer" }, .{ "bedrock-app-worker", "org.bedrock.worker" } };
    for (installed) |app| {
        package.addArg("--app");
        package.addPrefixedFileArg(b.fmt("{s}=", .{app[1]}), userland.artifact(app[0]).getEmittedBin());
    }
    const image_group = if (display_runtime) "display" else "app-runtime";
    const output_group = if (display_runtime) "display" else "apps";
    const test_group = if (display_runtime) "test-display" else "test-apps";
    const image_step = b.step(b.fmt("{s}-{s}", .{ image_group, name }), "Build installed native applications with a persistent supervisor");
    b.top_level_steps.get(image_group).?.step.dependOn(image_step);
    const test_step = b.step(b.fmt("{s}-{s}", .{ test_group, name }), "Boot installed app supervision and verify resource recovery");
    b.top_level_steps.get(test_group).?.step.dependOn(test_step);
    const normal = uefiKernelProfile(b, optimize, arch, 0, false, false, true, false, display_runtime);
    const acceptance = uefiKernelProfile(b, optimize, arch, 0, false, false, true, true, display_runtime);
    // Both reference profiles use serial diagnostics. Only the acceptance
    // kernel asks the host to end the otherwise persistent supervisor.
    const normal_efi = if (arch == .x86_64) uefiApplication(b, optimize, normal.getEmittedBin(), true, kernel_min).getEmittedBin() else multiUefiApplication(b, optimize, arch, normal.getEmittedBin(), true, kernel_min);
    const test_efi = if (arch == .x86_64) uefiApplication(b, optimize, acceptance.getEmittedBin(), true, kernel_min).getEmittedBin() else multiUefiApplication(b, optimize, arch, acceptance.getEmittedBin(), true, kernel_min);
    const esp = b.addWriteFiles();
    _ = esp.addCopyFile(normal_efi, b.fmt("EFI/BOOT/{s}", .{filename}));
    _ = esp.addCopyFile(archive, "EFI/Bedrock/Apps/apps.bap");
    for ([_]struct { source: std.Build.LazyPath, destination: []const u8 }{
        .{ .source = normal_efi, .destination = b.fmt("{s}/{s}/EFI/BOOT/{s}", .{ output_group, name, filename }) },
        .{ .source = archive, .destination = b.fmt("{s}/{s}/EFI/Bedrock/Apps/apps.bap", .{ output_group, name }) },
        .{ .source = normal.getEmittedBin(), .destination = b.fmt("{s}/{s}/kernel.elf", .{ output_group, name }) },
    }) |file| image_step.dependOn(&b.addInstallFile(file.source, file.destination).step);
    var prior: ?*std.Build.Step = null;
    for ([_]struct { efi: std.Build.LazyPath, suffix: []const u8, with_apps: bool, persistent: bool }{
        .{ .efi = test_efi, .suffix = "acceptance", .with_apps = true, .persistent = false },
        .{ .efi = normal_efi, .suffix = "persistent", .with_apps = true, .persistent = true },
        .{ .efi = test_efi, .suffix = "missing", .with_apps = false, .persistent = false },
    }) |profile| {
        if (display_runtime and !profile.with_apps) continue;
        const image = b.addSystemCommand(&.{"python"});
        image.addFileArg(b.path("tools/make-uefi-image.py"));
        image.addFileInput(b.path("tools/package-apps.py"));
        image.addFileInput(b.path(catalogue));
        image.addFileArg(profile.efi);
        const disk = image.addOutputFileArg(b.fmt("bedrock-{s}-{s}-{s}.img", .{ name, output_group, profile.suffix }));
        image.addArgs(&.{ "--arch", name });
        if (profile.with_apps) {
            image.addArg("--apps");
            image.addFileArg(archive);
            const check_image = b.addSystemCommand(&.{"python"});
            check_image.addFileArg(b.path("tools/test-uefi-image.py"));
            check_image.addFileInput(b.path("tools/make-uefi-image.py"));
            check_image.addFileInput(b.path("tools/package-apps.py"));
            check_image.addFileInput(b.path(catalogue));
            check_image.addFileArg(profile.efi);
            check_image.addFileArg(disk);
            check_image.addArgs(&.{ "--arch", name });
            check_image.addArg("--apps");
            check_image.addFileArg(archive);
            test_step.dependOn(&check_image.step);
        }
        if (profile.persistent) image_step.dependOn(&b.addInstallFile(disk, b.fmt("{s}/{s}/bedrock-{s}.img", .{ output_group, name, output_group })).step);
        const run = b.addSystemCommand(&.{"python"});
        run.addFileArg(b.path(if (display_runtime) "tools/test-display-runtime.py" else "tools/test-application-runtime.py"));
        if (display_runtime) {
            run.addFileInput(b.path("tools/test-desktop.py"));
            run.addFileInput(b.path("tools/test-application-runtime.py"));
        }
        run.addFileInput(b.path("tools/make-data-image.py"));
        run.addArgs(&.{ "--arch", name, "--qemu" });
        run.addFileArg(qemu);
        run.addArg("--code");
        run.addFileArg(code);
        run.addArg("--vars");
        run.addFileArg(vars);
        run.addArg("--image");
        run.addFileArg(disk);
        run.addArgs(&.{ "--ram-mib", b.fmt("{d}", .{@max(ram_mib, 128)}) });
        run.addArg("--artifacts");
        run.addDirectoryArg(b.path(b.fmt("zig-out/{s}-tests/{s}", .{ if (display_runtime) "display" else "application-runtime", @tagName(optimize) })));
        if (profile.persistent) run.addArg("--persistent") else if (!profile.with_apps) run.addArg("--missing");
        run.has_side_effects = true;
        if (prior) |previous| run.step.dependOn(previous);
        prior = &run.step;
        test_step.dependOn(&run.step);
    }
    const interactive = if (builtin.os.tag == .windows) b.addSystemCommand(&.{ "powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File" }) else b.addSystemCommand(&.{"sh"});
    interactive.addFileArg(b.path(if (builtin.os.tag == .windows) "tools/run-uefi.ps1" else "tools/run-uefi.sh"));
    interactive.addFileArg(qemu);
    interactive.addDirectoryArg(esp.getDirectory());
    interactive.addFileArg(code);
    interactive.addFileArg(vars);
    interactive.addArgs(&.{ b.fmt("{d}", .{@max(ram_mib, 128)}), name });
    interactive.has_side_effects = true;
    b.step(b.fmt("run-{s}-{s}", .{ output_group, name }), "Run installed applications and persistent init (Ctrl+C to stop)").dependOn(&interactive.step);
}

fn installerModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, path: []const u8) *std.Build.Module {
    return b.createModule(.{ .root_source_file = b.path(path), .target = target, .optimize = optimize, .stack_check = false, .stack_protector = false, .single_threaded = true, .red_zone = if (target.result.cpu.arch == .x86_64) false else null, .pic = if (target.result.os.tag == .freestanding) true else null, .code_model = if (target.result.cpu.arch == .riscv64) .medium else .default, .imports = &.{
        .{ .name = "axisui", .module = b.dependency("axisui", .{ .target = target, .optimize = optimize, .relocatable = true }).module("axisui") },
        .{ .name = "desktop_shell", .module = b.dependency("desktop_shell", .{ .target = target, .optimize = optimize, .relocatable = true }).module("desktop_shell") },
        .{ .name = "filesystem", .module = b.dependency("filesystem", .{ .target = target, .optimize = optimize }).module("filesystem") },
    } });
}
fn installerImage(b: *std.Build, optimize: std.builtin.OptimizeMode, arch: std.Target.Cpu.Arch, os_disk: std.Build.LazyPath, qemu: std.Build.LazyPath, code: std.Build.LazyPath, vars: std.Build.LazyPath) void {
    const name = if (arch == .aarch64) "arm64" else @tagName(arch);
    const target = if (arch == .riscv64) runtimeTarget(b, arch) else if (arch == .aarch64) b.resolveTargetQuery(.{ .cpu_arch = arch, .os_tag = .uefi, .abi = .none, .cpu_model = .{ .explicit = &std.Target.aarch64.cpu.cortex_a57 }, .cpu_features_add = std.Target.aarch64.featureSet(&.{.strict_align}) }) else b.resolveTargetQuery(.{ .cpu_arch = arch, .os_tag = .uefi, .abi = .msvc, .cpu_model = .baseline });
    // Firmware paints directly to GOP. Keep safety checks and optimize these
    // interactive paths even when the installed kernel uses Debug.
    const firmware_optimize = if (optimize == .debug) .safe else optimize;
    const compile = b.addExecutable(.{ .name = b.fmt("bedrock-installer-{s}", .{name}), .root_module = installerModule(b, target, firmware_optimize, "userspace/apps/installer/src/uefi_main.zig"), .use_llvm = true, .use_lld = true });
    var application = compile.getEmittedBin();
    if (arch == .riscv64) {
        compile.entry = .{ .symbol_name = "EfiMain" };
        compile.pie = true;
        compile.setLinkerScript(b.path("bootloader/src/platform/uefi/riscv64/linker.ld"));
        const convert = b.addSystemCommand(&.{"python"});
        convert.addFileArg(b.path("tools/elf-to-efi.py"));
        convert.addFileInput(b.path("tools/make-uefi-image.py"));
        convert.addFileArg(application);
        application = convert.addOutputFileArg("BOOTRISCV64.EFI");
    }
    const payload = b.addSystemCommand(&.{"python"});
    payload.addFileArg(b.path("tools/make-installer-payload.py"));
    payload.addFileInput(b.path("tools/make-data-image.py"));
    payload.addFileInput(b.path("tools/make-uefi-image.py"));
    payload.addFileArg(os_disk);
    const bip = payload.addOutputFileArg("os.bip");
    payload.addArgs(&.{ "--arch", name });
    const pack = b.addSystemCommand(&.{"python"});
    pack.addFileArg(b.path("tools/make-uefi-image.py"));
    pack.addFileArg(application);
    const disk = pack.addOutputFileArg(b.fmt("bedrock-installer-{s}.img", .{name}));
    pack.addArgs(&.{ "--arch", name, "--installer-payload" });
    pack.addFileArg(bip);
    const step = b.step(b.fmt("installer-{s}", .{name}), "Build native bootable installer media");
    step.dependOn(&b.addInstallFile(disk, b.fmt("installer/{s}/bedrock-installer.img", .{name})).step);
    step.dependOn(&b.addInstallFile(bip, b.fmt("installer/{s}/os.bip", .{name})).step);
    b.top_level_steps.get("installer").?.step.dependOn(step);
    for ([_]bool{ false, true }) |installed| {
        const interactive = b.addSystemCommand(&.{"python"});
        interactive.addFileArg(b.path("tools/run-installer.py"));
        interactive.addFileInput(b.path("tools/make-uefi-image.py"));
        interactive.addArgs(&.{ "--arch", name, "--image" });
        interactive.addFileArg(disk);
        interactive.addArg("--qemu");
        interactive.addFileArg(qemu);
        interactive.addArg("--code");
        interactive.addFileArg(code);
        interactive.addArg("--vars");
        interactive.addFileArg(vars);
        interactive.addArgs(&.{ "--target", b.fmt("zig-out/installed/{s}/bedrock-installed.img", .{name}) });
        if (installed) interactive.addArg("--boot-installed");
        interactive.has_side_effects = true;
        b.step(b.fmt("run-{s}-{s}", .{ if (installed) "installed" else "installer", name }), "Run native installer or installed virtual disk (ordinary files only)").dependOn(&interactive.step);
    }
    const run = b.addSystemCommand(&.{"python"});
    run.addFileArg(b.path("tools/test-installer.py"));
    for ([_][]const u8{ "tools/test-window-desktop.py", "tools/test-service-desktop.py", "tools/test-application-runtime.py", "tools/test-display-runtime.py", "tools/test-desktop.py", "tools/make-data-image.py", "tools/make-installer-payload.py" }) |input| run.addFileInput(b.path(input));
    run.addArgs(&.{ "--arch", name, "--image" });
    run.addFileArg(disk);
    run.addArg("--os-image");
    run.addFileArg(os_disk);
    run.addArg("--qemu");
    run.addFileArg(qemu);
    run.addArg("--code");
    run.addFileArg(code);
    run.addArg("--vars");
    run.addFileArg(vars);
    run.addArgs(&.{ "--artifacts", b.fmt("zig-out/installer-tests/{s}/{s}", .{ @tagName(optimize), name }) });
    run.has_side_effects = true;
    const tests = b.step(b.fmt("test-installer-{s}", .{name}), "Verify confirmed native installation and independent installed boot");
    tests.dependOn(&run.step);
    b.top_level_steps.get("test-installer").?.step.dependOn(tests);
}
/// The normal installed desktop and its test host share executable packages.
/// Legacy kernel-hosted Files remains an independent regression profile.
fn installedDesktop(b: *std.Build, optimize: std.builtin.OptimizeMode, arch: std.Target.Cpu.Arch, qemu: std.Build.LazyPath, code: std.Build.LazyPath, vars: std.Build.LazyPath, ram_mib: u32, kernel_min: u64, images: *std.Build.Step, attach_network: bool, window_runtime: bool) void {
    const name = if (arch == .aarch64) "arm64" else @tagName(arch);
    const directory = if (window_runtime) "desktop" else "service-desktop";
    const catalogue = if (window_runtime) "userspace/runtime/window-apps.json" else "userspace/runtime/desktop-apps.json";
    const runner = if (window_runtime) "tools/test-window-desktop.py" else "tools/test-service-desktop.py";
    const filename = switch (arch) {
        .x86_64 => "BOOTX64.EFI",
        .aarch64 => "BOOTAA64.EFI",
        .riscv64 => "BOOTRISCV64.EFI",
        else => unreachable,
    };
    const userland = b.dependency("userspace_runtime", .{ .target = runtimeTarget(b, arch), .optimize = optimize });
    const package = b.addSystemCommand(&.{"python"});
    package.addFileArg(b.path("tools/package-apps.py"));
    package.addArgs(&.{"--catalogue"});
    package.addFileArg(b.path(catalogue));
    package.addArgs(&.{ "--arch", @tagName(arch), "--output" });
    const archive = package.addOutputFileArg("apps.bap");
    const app_programs: []const [2][]const u8 = if (window_runtime) &.{ .{ "bedrock-window-init", "org.bedrock.init" }, .{ "bedrock-window-server", "org.bedrock.display-server" }, .{ "bedrock-window-shell", "org.bedrock.shell" }, .{ "bedrock-window-files", "org.bedrock.files" }, .{ "bedrock-window-notes", "org.bedrock.notes" } } else &.{ .{ "bedrock-desktop-init", "org.bedrock.init" }, .{ "bedrock-desktop-server", "org.bedrock.display-server" }, .{ "bedrock-desktop-shell", "org.bedrock.shell" }, .{ "bedrock-desktop-files", "org.bedrock.files" } };
    for (app_programs) |app| {
        package.addArg("--app");
        package.addPrefixedFileArg(b.fmt("{s}=", .{app[1]}), userland.artifact(app[0]).getEmittedBin());
    }
    const build_step = b.step(b.fmt("{s}-{s}", .{ directory, name }), "Package native apps and user-space compositor");
    b.top_level_steps.get(directory).?.step.dependOn(build_step);
    if (window_runtime) {
        images.dependOn(build_step);
        b.top_level_steps.get("windows").?.step.dependOn(build_step);
        b.step(b.fmt("uefi-{s}", .{name}), "Build the primary installed runtime desktop").dependOn(build_step);
        b.step(b.fmt("uefi-image-{s}", .{name}), "Build the primary GPT/FAT32 runtime desktop image").dependOn(build_step);
    }
    const test_name = if (window_runtime) "test-window-desktop" else "test-service-desktop";
    const test_step = b.step(b.fmt("{s}-{s}", .{ test_name, name }), "Drive native apps, window controls and durable recovery");
    b.top_level_steps.get(test_name).?.step.dependOn(test_step);
    const normal = uefiKernelWindowProfile(b, optimize, arch, 0, false, false, true, false, true, true, window_runtime);
    const acceptance = uefiKernelWindowProfile(b, optimize, arch, 0, false, false, true, true, true, true, window_runtime);
    const efi = if (arch == .x86_64) uefiApplication(b, optimize, normal.getEmittedBin(), true, kernel_min).getEmittedBin() else multiUefiApplication(b, optimize, arch, normal.getEmittedBin(), true, kernel_min);
    const test_efi = if (arch == .x86_64) uefiApplication(b, optimize, acceptance.getEmittedBin(), true, kernel_min).getEmittedBin() else multiUefiApplication(b, optimize, arch, acceptance.getEmittedBin(), true, kernel_min);
    const tree = b.addWriteFiles();
    _ = tree.addCopyFile(efi, b.fmt("EFI/BOOT/{s}", .{filename}));
    _ = tree.addCopyFile(archive, "EFI/Bedrock/Apps/apps.bap");
    for ([_]struct { file: std.Build.LazyPath, suffix: []const u8 }{
        .{ .file = efi, .suffix = b.fmt("EFI/BOOT/{s}", .{filename}) },
        .{ .file = archive, .suffix = "EFI/Bedrock/Apps/apps.bap" },
        .{ .file = normal.getEmittedBin(), .suffix = "kernel.elf" },
    }) |output| {
        build_step.dependOn(&b.addInstallFile(output.file, b.fmt("{s}/{s}/{s}", .{ directory, name, output.suffix })).step);
        if (window_runtime) build_step.dependOn(&b.addInstallFile(output.file, b.fmt("uefi/{s}/{s}", .{ name, output.suffix })).step);
    }
    var prior: ?*std.Build.Step = null;
    for ([_]struct { efi: std.Build.LazyPath, suffix: []const u8, acceptance: bool }{
        .{ .efi = efi, .suffix = "persistent", .acceptance = false },
        .{ .efi = test_efi, .suffix = "acceptance", .acceptance = true },
    }) |profile| {
        const image = b.addSystemCommand(&.{"python"});
        image.addFileArg(b.path("tools/make-uefi-image.py"));
        image.addFileInput(b.path("tools/package-apps.py"));
        image.addFileInput(b.path(catalogue));
        image.addFileArg(profile.efi);
        const disk = image.addOutputFileArg(b.fmt("bedrock-{s}-{s}-{s}.img", .{ name, directory, profile.suffix }));
        image.addArgs(&.{ "--arch", name, "--apps" });
        image.addFileArg(archive);
        const check_image = b.addSystemCommand(&.{"python"});
        check_image.addFileArg(b.path("tools/test-uefi-image.py"));
        check_image.addFileInput(b.path("tools/make-uefi-image.py"));
        check_image.addFileInput(b.path("tools/package-apps.py"));
        check_image.addFileArg(profile.efi);
        check_image.addFileArg(disk);
        check_image.addArgs(&.{ "--arch", name, "--apps" });
        check_image.addFileArg(archive);
        test_step.dependOn(&check_image.step);
        if (!profile.acceptance) {
            if (window_runtime) installerImage(b, optimize, arch, disk, qemu, code, vars);
            build_step.dependOn(&b.addInstallFile(disk, b.fmt("{s}/{s}/bedrock-desktop.img", .{ directory, name })).step);
            if (window_runtime) build_step.dependOn(&b.addInstallFile(disk, b.fmt("uefi/{s}/bedrock-uefi.img", .{name})).step);
            if (window_runtime) {
                for ([_]bool{ false, true }) |anvil_check| {
                    const menus = b.addSystemCommand(&.{"python"});
                    menus.addFileArg(b.path("tools/test-system-menus.py"));
                    if (anvil_check) menus.addArg("--require-anvil");
                    for ([_][]const u8{ "tools/test-window-desktop.py", "tools/test-service-desktop.py", "tools/test-desktop.py", "tools/test-application-runtime.py", "tools/test-display-runtime.py", "tools/make-data-image.py", "frameworks/public/AxisUI/axis-sans.json", "frameworks/public/AxisUI/src/axis_sans.bin", "frameworks/public/AxisUI/icon-coverage.json", "frameworks/public/AxisUI/src/icons.zig" }) |input| menus.addFileInput(b.path(input));
                    menus.addArgs(&.{ "--arch", name, "--image" });
                    menus.addFileArg(disk);
                    menus.addArg("--qemu");
                    menus.addFileArg(qemu);
                    menus.addArg("--code");
                    menus.addFileArg(code);
                    menus.addArg("--vars");
                    menus.addFileArg(vars);
                    menus.addArgs(&.{ "--ram-mib", b.fmt("{d}", .{@max(ram_mib, 256)}), "--artifacts" });
                    menus.addDirectoryArg(b.path(b.fmt("zig-out/{s}/{s}/{s}", .{ if (anvil_check) "anvil-tests" else "system-menu-tests", @tagName(optimize), name })));
                    menus.has_side_effects = true;
                    menus.step.dependOn(&check_image.step);
                    const menu_step = b.step(b.fmt("{s}-{s}", .{ if (anvil_check) "test-anvil-desktop" else "test-system-menus", name }), "Verify native desktop rendering through actual QEMU input/pixels");
                    menu_step.dependOn(&menus.step);
                    b.top_level_steps.get(if (anvil_check) "test-anvil-desktop" else "test-system-menus").?.step.dependOn(menu_step);
                }
            }
        }
        const run = b.addSystemCommand(&.{"python"});
        run.addFileArg(b.path(runner));
        if (window_runtime) {
            run.addFileInput(b.path("tools/test-service-desktop.py"));
        }
        run.addFileInput(b.path("frameworks/public/AxisUI/axis-sans.json"));
        if (window_runtime) run.addFileInput(b.path("frameworks/public/AxisUI/src/axis_sans.bin"));
        if (window_runtime) run.addFileInput(b.path("frameworks/public/AxisUI/icon-coverage.json"));
        if (window_runtime) run.addFileInput(b.path("frameworks/public/AxisUI/src/icons.zig"));
        for ([_][]const u8{ "tools/test-desktop.py", "tools/test-application-runtime.py", "tools/make-data-image.py", "tools/test-display-runtime.py" }) |input| run.addFileInput(b.path(input));
        run.addArgs(&.{ "--arch", name, "--image" });
        run.addFileArg(disk);
        run.addArg("--qemu");
        run.addFileArg(qemu);
        run.addArg("--code");
        run.addFileArg(code);
        run.addArg("--vars");
        run.addFileArg(vars);
        run.addArgs(&.{ "--ram-mib", b.fmt("{d}", .{@max(ram_mib, 256)}), "--artifacts" });
        run.addDirectoryArg(b.path(b.fmt("zig-out/{s}-tests/{s}/{s}", .{ if (window_runtime) "window-desktop" else "service-desktop", @tagName(optimize), profile.suffix })));
        if (profile.acceptance) run.addArg("--acceptance");
        if (prior) |previous| run.step.dependOn(previous);
        prior = &run.step;
        run.has_side_effects = true;
        test_step.dependOn(&run.step);
    }
    const interactive = if (builtin.os.tag == .windows) b.addSystemCommand(&.{ "powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File" }) else b.addSystemCommand(&.{"sh"});
    interactive.addFileArg(b.path(if (builtin.os.tag == .windows) "tools/run-uefi.ps1" else "tools/run-uefi.sh"));
    interactive.addFileArg(qemu);
    interactive.addDirectoryArg(tree.getDirectory());
    interactive.addFileArg(code);
    interactive.addFileArg(vars);
    interactive.addArgs(&.{ b.fmt("{d}", .{@max(ram_mib, 256)}), name });
    if (attach_network) {
        if (builtin.os.tag == .windows) interactive.addArg("-Network") else interactive.addArgs(&.{ "", "network" });
    }
    interactive.has_side_effects = true;
    b.step(b.fmt("run-{s}-{s}", .{ directory, name }), "Run the native service desktop (Ctrl+C to stop)").dependOn(&interactive.step);
    if (window_runtime) {
        b.step(b.fmt("run-windows-{s}", .{name}), "Run native windows, tiling and workspaces (Ctrl+C to stop)").dependOn(&interactive.step);
        b.step(b.fmt("run-uefi-{s}", .{name}), "Boot the primary user-space desktop (Ctrl+C to stop)").dependOn(&interactive.step);
    }
}

fn addMt7922Imports(b: *std.Build, module: *std.Build.Module, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, protocol: *std.Build.Module, abi: *std.Build.Module) *std.Build.Module {
    const arch = target.result.cpu.arch;
    const networkkit = b.dependency("networkkit", .{ .target = target, .optimize = optimize, .relocatable = true }).module("networkkit");
    const memory = b.createModule(.{ .root_source_file = b.path("drivers/mt7922/src/memory_proxy.zig"), .target = target, .optimize = optimize, .pic = true, .stack_check = false, .stack_protector = false, .red_zone = if (arch == .x86_64) false else null, .code_model = if (arch == .riscv64) .medium else .default, .imports = &.{ .{ .name = "driver_abi", .module = abi }, .{ .name = "boot_protocol", .module = protocol } } });
    const pci = b.createModule(.{ .root_source_file = b.path("kernel/src/drivers/pci/root.zig"), .target = target, .optimize = optimize, .pic = true, .stack_check = false, .stack_protector = false, .red_zone = if (arch == .x86_64) false else null, .code_model = if (arch == .riscv64) .medium else .default });
    const pci_native = b.createModule(.{ .root_source_file = b.path("kernel/src/drivers/pci/native.zig"), .target = target, .optimize = optimize, .pic = true, .stack_check = false, .stack_protector = false, .red_zone = if (arch == .x86_64) false else null, .code_model = if (arch == .riscv64) .medium else .default, .imports = &.{ .{ .name = "pci", .module = pci }, .{ .name = "boot_protocol", .module = protocol } } });
    const wireless = b.createModule(.{
        .root_source_file = b.path("drivers/wifi/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .pic = true,
        .single_threaded = true,
        .stack_check = false,
        .stack_protector = false,
        .red_zone = if (arch == .x86_64) false else null,
        .code_model = if (arch == .riscv64) .medium else .default,
        .imports = &.{ .{ .name = "pci", .module = pci }, .{ .name = "pci_native", .module = pci_native }, .{ .name = "boot_protocol", .module = protocol }, .{ .name = "memory_init", .module = memory }, .{ .name = "networkkit", .module = networkkit } },
    });
    module.addImport("wifi_drivers", wireless);
    module.addImport("memory_init", memory);
    module.addImport("networkkit", networkkit);
    return memory;
}

fn driverModule(b: *std.Build, optimize: std.builtin.OptimizeMode, arch: std.Target.Cpu.Arch, fixture: bool) DriverArtifact {
    const target = runtimeTarget(b, arch);
    const protocol = b.dependency("boot_protocol", .{ .target = target, .optimize = optimize }).module("boot_protocol");
    const abi = b.createModule(.{ .root_source_file = b.path("frameworks/private/DriverKit/src/abi.zig"), .target = target, .optimize = optimize, .pic = true, .stack_check = false, .stack_protector = false, .red_zone = if (arch == .x86_64) false else null, .code_model = if (arch == .riscv64) .medium else .default });
    const module = b.createModule(.{
        .root_source_file = b.path(if (fixture) "frameworks/private/DriverKit/src/test_module.zig" else "drivers/mt7922/src/entry.zig"),
        .target = target,
        .optimize = optimize,
        .pic = true,
        .single_threaded = true,
        .stack_check = false,
        .stack_protector = false,
        .red_zone = if (arch == .x86_64) false else null,
        .code_model = if (arch == .riscv64) .medium else .default,
        .imports = &.{ .{ .name = "driver_abi", .module = abi }, .{ .name = "boot_protocol", .module = protocol } },
    });
    if (!fixture) _ = addMt7922Imports(b, module, target, optimize, protocol, abi);
    const artifact = b.addExecutable(.{ .name = b.fmt("{s}-{s}.bdm", .{ if (fixture) "test-driver" else "mt7922", @tagName(arch) }), .root_module = module, .use_llvm = true, .use_lld = true });
    artifact.pie = true;
    artifact.entry = .{ .symbol_name = "bedrock_driver_entry" };
    artifact.setLinkerScript(b.path("frameworks/private/DriverKit/module.ld"));
    if (!fixture) {
        const package = b.addSystemCommand(&.{"python"});
        package.addFileArg(b.path("tools/describe-driver-package.py"));
        package.addFileArg(artifact.getEmittedBin());
        const directory = package.addOutputDirectoryArg("driver-package");
        package.addArgs(&.{ "--arch", @tagName(arch) });
        package.addFileInput(b.path("tools/package-drivers.py"));
        package.addFileInput(b.path("drivers/catalogue.json"));
        const install = b.addInstallDirectory(.{ .source_dir = directory, .install_dir = .prefix, .install_subdir = "drivers" });
        b.top_level_steps.get("drivers").?.step.dependOn(&install.step);
        b.getInstallStep().dependOn(&install.step);
        b.top_level_steps.get("check").?.step.dependOn(&artifact.step);
        return .{ .image = artifact.getEmittedBin(), .package = directory };
    }
    return .{ .image = artifact.getEmittedBin() };
}

fn driverModuleRun(b: *std.Build, optimize: std.builtin.OptimizeMode, arch: std.Target.Cpu.Arch, qemu: std.Build.LazyPath, image: std.Build.LazyPath, code: std.Build.LazyPath, vars: std.Build.LazyPath) void {
    const name = if (arch == .aarch64) "arm64" else @tagName(arch);
    const filename = switch (arch) {
        .x86_64 => "BOOTX64.EFI",
        .aarch64 => "BOOTAA64.EFI",
        .riscv64 => "BOOTRISCV64.EFI",
        else => unreachable,
    };
    const application = if (arch == .x86_64) uefiApplicationVariant(b, optimize, image, true, 0, true).getEmittedBin() else multiUefiApplicationVariant(b, optimize, arch, image, true, 0, true);
    const tree = b.addWriteFiles();
    const file = tree.addCopyFile(application, b.fmt("EFI/BOOT/{s}", .{filename}));
    _ = tree.addCopyFile(driverModule(b, optimize, arch, true).image, "EFI/Bedrock/Drivers/test-driver.bdm");
    const run = b.addSystemCommand(&.{"python"});
    run.addFileArg(b.path("tools/test-driver-module-boot.py"));
    run.addFileArg(b.path(if (builtin.os.tag == .windows) "tools/test-boot.ps1" else "tools/test-boot.sh"));
    run.addArg(b.fmt("{s}-uefi", .{name}));
    run.addFileArg(qemu);
    run.addFileArg(file);
    run.addArgs(&.{ "40", "128" });
    run.addFileArg(code);
    run.addFileArg(vars);
    run.has_side_effects = true;
    b.top_level_steps.get("test-driver-modules").?.step.dependOn(&run.step);
}

fn driverPolicyRun(b: *std.Build, arch: std.Target.Cpu.Arch, qemu: std.Build.LazyPath, application: std.Build.LazyPath, code: std.Build.LazyPath, vars: std.Build.LazyPath, module: std.Build.LazyPath) void {
    // The ordinary x86 loader must skip an unmatched real package and reject
    // malformed optional code while preserving the rest of the OS boot.
    std.debug.assert(arch == .x86_64);
    for ([_][]const u8{ "unmatched", "malformed" }) |case| {
        const tree = b.addWriteFiles();
        const file = tree.addCopyFile(application, "EFI/BOOT/BOOTX64.EFI");
        if (std.mem.eql(u8, case, "unmatched")) {
            _ = tree.addCopyFile(module, "EFI/Bedrock/Drivers/mt7922.bdm");
        } else {
            _ = tree.add("EFI/Bedrock/Drivers/mt7922.bdm", "invalid optional module");
        }
        const run = b.addSystemCommand(&.{"python"});
        run.addFileArg(b.path("tools/test-driver-policy-boot.py"));
        run.addArg(case);
        run.addFileArg(b.path(if (builtin.os.tag == .windows) "tools/test-boot.ps1" else "tools/test-boot.sh"));
        run.addArg("x86_64-uefi");
        run.addFileArg(qemu);
        run.addFileArg(file);
        run.addArgs(&.{ "40", "128" });
        run.addFileArg(code);
        run.addFileArg(vars);
        run.has_side_effects = true;
        b.top_level_steps.get("test-driver-modules").?.step.dependOn(&run.step);
    }
}

fn addWifiImage(b: *std.Build, arch: std.Target.Cpu.Arch, application: std.Build.LazyPath, inputs: WifiImageOptions, driver_packages: std.Build.LazyPath) void {
    const name = if (arch == .aarch64) "arm64" else @tagName(arch);
    const filename = switch (arch) {
        .x86_64 => "BOOTX64.EFI",
        .aarch64 => "BOOTAA64.EFI",
        .riscv64 => "BOOTRISCV64.EFI",
        else => unreachable,
    };
    const directory = inputs.directory;
    const board = inputs.board;
    const pin = ".zig-cache/upstream-wifi/firmware/afabaf773c4c2e2c841429933a6a084a5af4d14d";
    const tree = b.addWriteFiles();
    _ = tree.addCopyFile(application, b.fmt("EFI/BOOT/{s}", .{filename}));
    for ([_][]const u8{ "WIFI_MT7922_patch_mcu_1_1_hdr.bin", "WIFI_RAM_CODE_MT7922_1.bin", "LICENCE.mediatek" }) |asset| {
        const source: std.Build.LazyPath = .{ .cwd_relative = if (directory) |dir| b.fmt("{s}/{s}", .{ dir, asset }) else b.fmt("{s}/{s}/{s}", .{ pin, if (std.mem.eql(u8, asset, "LICENCE.mediatek")) "LICENSES" else "mediatek", asset }) };
        _ = tree.addCopyFile(source, b.fmt("EFI/Bedrock/Firmware/{s}", .{asset}));
    }
    if (board) |path| _ = tree.addCopyFile(.{ .cwd_relative = path }, "EFI/Bedrock/Firmware/MT7922.board");
    const select = b.addSystemCommand(&.{"python"});
    select.addFileArg(b.path("tools/stage-driver-build.py"));
    select.addFileInput(b.path("tools/package-drivers.py"));
    select.addArgs(&.{ "--arch", @tagName(arch), "--all-compatible", "--modules" });
    select.addDirectoryArg(driver_packages);
    select.addArg("--catalogue");
    select.addFileArg(b.path("drivers/catalogue.json"));
    select.addArg("--output-root");
    const selection_root = select.addOutputDirectoryArg("driver-stage");
    const selection = selection_root.path(b, "selected");
    const package = std.Build.Step.Run.create(b, b.fmt("package {s} Wi-Fi firmware ESP", .{name}));
    package.addFileArg(b.findProgramLazy(.{ .names = if (builtin.os.tag == .windows) &.{ "python", "python3" } else &.{"python3"} }));
    package.addFileArg(b.path("tools/make-uefi-image.py"));
    package.addFileArg(application);
    const image = package.addOutputFileArg(b.fmt("bedrock-{s}-wifi.img", .{name}));
    package.addArgs(&.{ "--arch", name, "--firmware-dir" });
    package.addDirectoryArg(tree.getDirectory().path(b, "EFI/Bedrock/Firmware"));
    package.addArg("--driver-dir");
    package.addDirectoryArg(selection.path(b, "EFI/Bedrock/Drivers"));
    package.addFileInput(b.path("tools/package-drivers.py"));
    package.addFileInput(b.path("drivers/catalogue.json"));
    const validate = b.addSystemCommand(&.{"python"});
    validate.addFileArg(b.path("tools/test-uefi-image.py"));
    validate.addFileArg(application);
    validate.addFileArg(image);
    validate.addArgs(&.{ "--arch", name, "--firmware-dir" });
    validate.addDirectoryArg(tree.getDirectory().path(b, "EFI/Bedrock/Firmware"));
    validate.addArg("--driver-dir");
    validate.addDirectoryArg(selection.path(b, "EFI/Bedrock/Drivers"));
    validate.addFileInput(b.path("tools/make-uefi-image.py"));
    validate.addFileInput(b.path("tools/package-drivers.py"));
    validate.addFileInput(b.path("drivers/catalogue.json"));
    const install_tree = b.addInstallDirectory(.{ .source_dir = tree.getDirectory(), .install_dir = .prefix, .install_subdir = b.fmt("wifi/{s}", .{name}) });
    // Image validation must succeed before publishing the assembled tree.
    install_tree.step.dependOn(&validate.step);
    const install_image = b.addInstallFile(image, b.fmt("wifi/{s}/bedrock-wifi.img", .{name}));
    install_image.step.dependOn(&validate.step);
    const step = b.step(b.fmt("wifi-uefi-{s}", .{name}), "Build ordinary GPT/FAT32 image and firmware files; no host-device access");
    step.dependOn(&install_tree.step);
    step.dependOn(&install_image.step);
    const install_drivers = b.addInstallDirectory(.{ .source_dir = selection, .install_dir = .prefix, .install_subdir = b.fmt("wifi/{s}", .{name}) });
    install_drivers.step.dependOn(&validate.step);
    step.dependOn(&install_drivers.step);
    b.top_level_steps.get("wifi-uefi").?.step.dependOn(step);
}

fn wifiAssetsRun(b: *std.Build, arch: std.Target.Cpu.Arch, qemu: std.Build.LazyPath, application: std.Build.LazyPath, code: std.Build.LazyPath, vars: std.Build.LazyPath, inputs: WifiImageOptions) void {
    const name = if (arch == .aarch64) "arm64" else @tagName(arch);
    const filename = switch (arch) {
        .x86_64 => "BOOTX64.EFI",
        .aarch64 => "BOOTAA64.EFI",
        .riscv64 => "BOOTRISCV64.EFI",
        else => unreachable,
    };
    const pin = ".zig-cache/upstream-wifi/firmware/afabaf773c4c2e2c841429933a6a084a5af4d14d/mediatek";
    for ([_][]const u8{ "valid", "bad-patch" }) |case| {
        const tree = b.addWriteFiles();
        const file = tree.addCopyFile(application, b.fmt("EFI/BOOT/{s}", .{filename}));
        for ([_][]const u8{ "WIFI_MT7922_patch_mcu_1_1_hdr.bin", "WIFI_RAM_CODE_MT7922_1.bin" }, 0..) |asset, i| {
            const target = b.fmt("EFI/Bedrock/Firmware/{s}", .{asset});
            if (i == 0 and std.mem.eql(u8, case, "bad-patch")) {
                _ = tree.add(target, "deliberately invalid firmware length");
            } else {
                _ = tree.addCopyFile(.{ .cwd_relative = b.fmt("{s}/{s}", .{ inputs.directory orelse pin, asset }) }, target);
            }
        }
        const run = std.Build.Step.Run.create(b, b.fmt("{s} EFI Wi-Fi assets {s}", .{ name, case }));
        run.addFileArg(b.findProgramLazy(.{ .names = if (builtin.os.tag == .windows) &.{ "python", "python3" } else &.{"python3"} }));
        run.addFileArg(b.path("tools/test-wifi-assets-boot.py"));
        run.addArg(case);
        run.addFileArg(b.path(if (builtin.os.tag == .windows) "tools/test-boot.ps1" else "tools/test-boot.sh"));
        run.addArg(b.fmt("{s}-uefi", .{name}));
        run.addFileArg(qemu);
        run.addFileArg(file);
        run.addArgs(&.{ "40", "128" });
        run.addFileArg(code);
        run.addFileArg(vars);
        run.has_side_effects = true;
        b.top_level_steps.get("test-wifi-boot").?.step.dependOn(&run.step);
    }
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
