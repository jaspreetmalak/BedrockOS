const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{ .default_target = .{ .cpu_arch = .x86_64, .os_tag = .freestanding, .abi = .none } });
    const optimize = b.standardOptimizeOption(.{});
    const check = b.step("check", "Compile the kernel and chipset protocol interfaces");
    const relocatable = b.option(bool, "relocatable", "Build position-independent kernel entry for firmware loading") orelse false;
    const uefi_entry = b.option(bool, "uefi_entry", "Use standard firmware CPU entry instead of the reset profile") orelse false;
    const network_echo_port = b.option(u16, "network_echo_port", "Run the protected network acceptance client against this UDP port") orelse 0;
    const wifi_acceptance = b.option(bool, "wifi_acceptance", "TEST ONLY: simulated radio and protected Wi-Fi acceptance client") orelse false;
    const wifi_absence_probe = b.option(bool, "wifi_absence_probe", "TEST ONLY: observe production Wi-Fi unavailability without control permission") orelse false;
    const window_runtime = b.option(bool, "window_runtime", "Run independently owned native windows, tiling and workspaces") orelse false;
    const requested_app_runtime = b.option(bool, "app_runtime", "Run persistent init and installed native applications") orelse false;
    const app_runtime = window_runtime or requested_app_runtime;
    const app_acceptance = b.option(bool, "app_acceptance", "TEST ONLY: finish installed-app lifecycle after independently checked supervision") orelse false;
    const requested_display_runtime = b.option(bool, "display_runtime", "Run protected display service and native surface clients") orelse false;
    const requested_desktop_runtime = b.option(bool, "desktop_runtime", "Run the installed shell and Files through the user-space compositor") orelse false;
    const display_runtime = window_runtime or requested_display_runtime;
    const desktop_runtime = window_runtime or requested_desktop_runtime;
    if (desktop_runtime and !display_runtime) @panic("The runtime desktop requires display services");
    if (display_runtime and !app_runtime) @panic("Display services require the installed runtime");
    if (app_acceptance and !app_runtime) @panic("Application acceptance requires the installed runtime");
    if (wifi_acceptance and wifi_absence_probe) @panic("Wi-Fi acceptance and absence profiles are exclusive");
    const runtime_options = b.addOptions();
    runtime_options.addOption(bool, "relocatable", relocatable);
    runtime_options.addOption(bool, "uefi_entry", uefi_entry);
    runtime_options.addOption(u16, "network_echo_port", network_echo_port);
    runtime_options.addOption(bool, "wifi_acceptance", wifi_acceptance);
    runtime_options.addOption(bool, "wifi_absence_probe", wifi_absence_probe);
    runtime_options.addOption(bool, "app_runtime", app_runtime);
    runtime_options.addOption(bool, "app_acceptance", app_acceptance);
    runtime_options.addOption(bool, "display_runtime", display_runtime);
    runtime_options.addOption(bool, "desktop_runtime", desktop_runtime);
    runtime_options.addOption(bool, "window_runtime", window_runtime);
    const options_module = runtime_options.createModule();
    const protocol = b.dependency("boot_protocol", .{ .target = target, .optimize = optimize });
    const filesystem = b.dependency("filesystem", .{ .target = target, .optimize = optimize });
    const arch = target.result.cpu.arch;
    const security = b.addModule("security", .{
        .root_source_file = b.path("src/security/root.zig"),
        .target = target,
        .optimize = optimize,
        .stack_protector = false,
        .stack_check = false,
        .single_threaded = true,
        .red_zone = if (arch == .x86_64) false else null,
        .pic = if (target.result.os.tag == .freestanding) relocatable else null,
        .code_model = if (arch == .riscv64) .medium else if (arch == .x86_64) .small else .default,
    });
    const module = b.addModule("kernel", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "boot_protocol", .module = protocol.module("boot_protocol") },
            .{ .name = "filesystem", .module = filesystem.module("filesystem") },
            .{ .name = "security", .module = security },
        },
    });
    const platform = switch (arch) {
        .aarch64 => .{ "arm64", "aarch64", "qemu_virt" },
        .x86_64 => .{ "x86_64", "x86_64", "qemu_pc" },
        .riscv64 => .{ "riscv64", "riscv64", "qemu_riscv_virt" },
        else => null,
    };
    if (platform) |port| {
        const runtime = b.addModule(b.fmt("{s}_kernel", .{port[0]}), .{
            .root_source_file = b.path(b.fmt("src/platform/{s}/main.zig", .{port[2]})),
            .target = target,
            .optimize = optimize,
            .stack_protector = false,
            .stack_check = false,
            .single_threaded = true,
            .red_zone = if (arch == .x86_64) false else null,
            .pic = if (target.result.os.tag == .freestanding) relocatable else null,
            .code_model = switch (arch) {
                .x86_64 => .small,
                .riscv64 => .medium,
                else => .default,
            },
            .imports = &.{
                .{ .name = "boot_protocol", .module = protocol.module("boot_protocol") },
            },
        });
        const physical_access = b.createModule(.{
            .root_source_file = b.path("src/arch/physical_memory.zig"),
            .target = target,
            .optimize = optimize,
            .stack_protector = false,
            .stack_check = false,
            .single_threaded = true,
            .red_zone = if (arch == .x86_64) false else null,
            .pic = if (target.result.os.tag == .freestanding) relocatable else null,
            .code_model = runtime.code_model,
            .imports = &.{.{ .name = "boot_protocol", .module = protocol.module("boot_protocol") }},
        });
        const memory_init = b.createModule(.{
            .root_source_file = b.path("src/core/memory_init.zig"),
            .target = target,
            .optimize = optimize,
            .stack_protector = false,
            .stack_check = false,
            .single_threaded = true,
            .red_zone = if (arch == .x86_64) false else null,
            .pic = if (target.result.os.tag == .freestanding) relocatable else null,
            .code_model = runtime.code_model,
            .imports = &.{
                .{ .name = "boot_protocol", .module = protocol.module("boot_protocol") },
                .{ .name = "physical_access", .module = physical_access },
            },
        });
        runtime.addImport("memory_init", memory_init);
        const wireless = wifiDrivers(b, "wifi_drivers", target, optimize, relocatable, protocol.module("boot_protocol"), memory_init, b.dependency("networkkit", .{ .target = target, .optimize = optimize, .relocatable = relocatable }).module("networkkit"));
        const wireless_probe = b.addLibrary(.{
            .name = "bedrock-wifi-drivers",
            .root_module = b.createModule(.{
                .root_source_file = b.path("../drivers/wifi/src/compile_check.zig"),
                .target = target,
                .optimize = optimize,
                .stack_protector = false,
                .stack_check = false,
                .single_threaded = true,
                .red_zone = if (arch == .x86_64) false else null,
                .pic = if (target.result.os.tag == .freestanding) relocatable else null,
                .code_model = runtime.code_model,
                .imports = &.{ .{ .name = "wifi_drivers", .module = wireless }, .{ .name = "boot_protocol", .module = protocol.module("boot_protocol") } },
            }),
        });
        b.installArtifact(wireless_probe);
        check.dependOn(&wireless_probe.step);
        if (uefi_entry) {
            const userland = b.dependency("userspace_runtime", .{ .target = target, .optimize = optimize });
            const desktop_shell = b.dependency("desktop_shell", .{ .target = target, .optimize = optimize, .relocatable = relocatable });
            runtime.addImport("desktop_preview", b.createModule(.{
                .root_source_file = b.path("src/drivers/desktop_preview.zig"),
                .target = target,
                .optimize = optimize,
                .stack_protector = false,
                .stack_check = false,
                .single_threaded = true,
                .red_zone = if (arch == .x86_64) false else null,
                .pic = relocatable,
                .code_model = runtime.code_model,
                .imports = &.{
                    .{ .name = "boot_protocol", .module = protocol.module("boot_protocol") },
                    .{ .name = "desktop_shell", .module = desktop_shell.module("desktop_shell") },
                },
            }));
            const contract = b.createModule(.{
                .root_source_file = b.path("src/core/isolation_contract.zig"),
                .target = target,
                .optimize = optimize,
            });
            const isolation_arch = b.createModule(.{
                .root_source_file = b.path(b.fmt("src/arch/{s}/isolation.zig", .{port[1]})),
                .target = target,
                .optimize = optimize,
                .stack_protector = false,
                .stack_check = false,
                .single_threaded = true,
                .red_zone = if (arch == .x86_64) false else null,
                .pic = relocatable,
                .code_model = runtime.code_model,
                .imports = &.{
                    .{ .name = "boot_protocol", .module = protocol.module("boot_protocol") },
                    .{ .name = "memory_init", .module = memory_init },
                    .{ .name = "isolation_contract", .module = contract },
                },
            });
            isolation_arch.addAssemblyFile(b.path(b.fmt("src/arch/{s}/isolation.S", .{port[1]})));
            runtime.addImport("isolation_arch", isolation_arch);
            const isolation = b.createModule(.{
                .root_source_file = b.path("src/core/isolation.zig"),
                .target = target,
                .optimize = optimize,
                .stack_protector = false,
                .stack_check = false,
                .single_threaded = true,
                .red_zone = if (arch == .x86_64) false else null,
                .pic = relocatable,
                .code_model = runtime.code_model,
                .imports = &.{
                    .{ .name = "bedrock64", .module = userland.module("bedrock64") },
                    .{ .name = "boot_protocol", .module = protocol.module("boot_protocol") },
                    .{ .name = "memory_init", .module = memory_init },
                    .{ .name = "isolation_contract", .module = contract },
                    .{ .name = "isolation_arch", .module = isolation_arch },
                    .{ .name = "security", .module = security },
                    .{ .name = "filesystem", .module = filesystem.module("filesystem") },
                    .{ .name = "desktop_shell", .module = desktop_shell.module("desktop_shell") },
                    .{ .name = "window_server", .module = b.dependency("window_server", .{ .target = target, .optimize = optimize, .relocatable = relocatable }).module("window_server") },
                },
            });
            const virtio = b.createModule(.{
                .root_source_file = b.path("src/drivers/virtio/root.zig"),
                .target = target,
                .optimize = optimize,
                .stack_protector = false,
                .stack_check = false,
                .single_threaded = true,
                .red_zone = if (arch == .x86_64) false else null,
                .pic = relocatable,
                .code_model = runtime.code_model,
                .imports = &.{ .{ .name = "boot_protocol", .module = protocol.module("boot_protocol") }, .{ .name = "memory_init", .module = memory_init } },
            });
            isolation.addImport("virtio", virtio);
            const anvil_core = b.dependency("anvil_core", .{ .target = target, .optimize = optimize, .relocatable = relocatable }).module("anvil_core");
            isolation.addImport("gpu_backend", b.createModule(.{
                .root_source_file = b.path("../drivers/gpu/framebuffer.zig"),
                .target = target,
                .optimize = optimize,
                .stack_protector = false,
                .stack_check = false,
                .single_threaded = true,
                .red_zone = if (arch == .x86_64) false else null,
                .pic = relocatable,
                .code_model = runtime.code_model,
                .imports = &.{
                    .{ .name = "boot_protocol", .module = protocol.module("boot_protocol") },
                    .{ .name = "anvil_core", .module = anvil_core },
                    .{ .name = "anvil", .module = anvil_core.import_table.get("anvil").? },
                },
            }));
            const network_core = b.dependency("network_core", .{ .target = target, .optimize = optimize, .relocatable = relocatable }).module("network_core");
            isolation.addImport("network_core", network_core);
            isolation.addImport("networkkit", network_core.import_table.get("networkkit").?);
            // The radio protocol types and the controller share the same kit.
            wireless.addImport("networkkit", network_core.import_table.get("networkkit").?);
            isolation.addImport("driver_abi", b.createModule(.{ .root_source_file = b.path("../frameworks/private/DriverKit/src/abi.zig"), .target = target, .optimize = optimize, .pic = relocatable, .stack_check = false, .stack_protector = false, .red_zone = if (arch == .x86_64) false else null, .code_model = runtime.code_model }));
            const runtime_pci = b.createModule(.{ .root_source_file = b.path("src/drivers/pci/root.zig"), .target = target, .optimize = optimize, .pic = relocatable, .stack_check = false, .stack_protector = false, .red_zone = if (arch == .x86_64) false else null });
            isolation.addImport("pci", runtime_pci);
            isolation.addImport("pci_native", b.createModule(.{ .root_source_file = b.path("src/drivers/pci/native.zig"), .target = target, .optimize = optimize, .pic = relocatable, .stack_check = false, .stack_protector = false, .red_zone = if (arch == .x86_64) false else null, .imports = &.{ .{ .name = "pci", .module = runtime_pci }, .{ .name = "boot_protocol", .module = protocol.module("boot_protocol") } } }));
            isolation.addImport("kernel_options", options_module);
            isolation.addImport("app_bundles", b.createModule(.{ .root_source_file = b.path("../userspace/runtime/src/bundle_archive.zig"), .target = target, .optimize = optimize, .pic = relocatable, .red_zone = if (arch == .x86_64) false else null, .stack_check = false, .stack_protector = false, .code_model = runtime.code_model }));
            inline for (.{ .{ "user_init_image", "bedrock-user-init" }, .{ "user_service_image", "bedrock-user-service" }, .{ "user_fault_image", "bedrock-user-fault" }, .{ "user_io_image", "bedrock-user-io" }, .{ "user_exec_image", "bedrock-user-exec" }, .{ "user_files_image", "bedrock-user-files" }, .{ "user_network_image", "bedrock-user-network" }, .{ "user_wifi_image", "bedrock-user-wifi" } }) |image| {
                isolation.addAnonymousImport(image[0], .{ .root_source_file = userland.artifact(image[1]).getEmittedBin() });
            }
            runtime.addImport("isolation", isolation);
        }
        runtime.addImport("kernel_options", options_module);
        if (uefi_entry) runtime.addCMacro("BEDROCK_UEFI", "1");
        runtime.addImport("framebuffer", b.createModule(.{
            .root_source_file = b.path("src/drivers/framebuffer.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "boot_protocol", .module = protocol.module("boot_protocol") }},
        }));
        if (arch == .aarch64) runtime.addImport("qemu_virt_uart", b.createModule(.{
            .root_source_file = b.path("src/platform/qemu_virt/uart.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "framebuffer", .module = runtime.import_table.get("framebuffer").? }},
        }));
        runtime.addAssemblyFile(b.path(b.fmt("src/arch/{s}/entry.S", .{port[1]})));
    }
    const artifact = b.addLibrary(.{
        .name = "bedrock-kernel",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/compile_check.zig"),
            .target = target,
            .optimize = optimize,
            .stack_protector = false,
            .red_zone = if (target.result.cpu.arch == .x86_64) false else null,
            .imports = &.{.{ .name = "kernel", .module = module }},
        }),
    });
    b.installArtifact(artifact);
    check.dependOn(&artifact.step);
    const test_step = b.step("test", "Run native kernel memory, console and security tests");
    const native_protocol = b.dependency("boot_protocol", .{ .target = b.graph.host, .optimize = optimize }).module("boot_protocol");
    const native_filesystem = b.dependency("filesystem", .{ .target = b.graph.host, .optimize = optimize }).module("filesystem");
    const native_security = b.createModule(.{ .root_source_file = b.path("src/security/root.zig"), .target = b.graph.host, .optimize = optimize });
    const native_access = b.createModule(.{ .root_source_file = b.path("src/arch/physical_memory.zig"), .target = b.graph.host, .optimize = optimize, .imports = &.{.{ .name = "boot_protocol", .module = native_protocol }} });
    const native_memory = b.createModule(.{ .root_source_file = b.path("src/core/memory_init.zig"), .target = b.graph.host, .optimize = optimize, .imports = &.{ .{ .name = "boot_protocol", .module = native_protocol }, .{ .name = "physical_access", .module = native_access } } });
    const native_wireless = wifiDrivers(b, null, b.graph.host, optimize, false, native_protocol, native_memory, b.dependency("networkkit", .{ .target = b.graph.host, .optimize = optimize }).module("networkkit"));
    const wireless_tests = b.addTest(.{ .name = "wifi-driver-tests", .root_module = native_wireless });
    test_step.dependOn(&b.addRunArtifact(wireless_tests).step);
    const network_requests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/core/network_syscalls.zig"),
        .target = b.graph.host,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "security", .module = native_security },
            .{ .name = "networkkit", .module = b.dependency("networkkit", .{ .target = b.graph.host, .optimize = optimize }).module("networkkit") },
            .{ .name = "bedrock64", .module = b.dependency("userspace_runtime", .{ .target = b.graph.host, .optimize = optimize }).module("bedrock64") },
        },
    }) });
    test_step.dependOn(&b.addRunArtifact(network_requests).step);
    const preview_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/drivers/desktop_preview.zig"),
        .target = b.graph.host,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "boot_protocol", .module = native_protocol },
            .{ .name = "desktop_shell", .module = b.dependency("desktop_shell", .{ .target = b.graph.host, .optimize = optimize }).module("desktop_shell") },
        },
    }) });
    test_step.dependOn(&b.addRunArtifact(preview_tests).step);
    for ([_][]const u8{ "src/core/memory.zig", "src/core/physical_memory.zig", "src/core/owned_frames.zig", "src/core/kernel_heap.zig", "src/core/user_memory.zig", "src/core/isolation_contract.zig", "src/core/scheduler.zig", "src/core/process.zig", "src/core/ipc.zig", "src/core/service_ipc.zig", "../drivers/gpu/pixel_format.zig", "src/arch/x86_64/page_table_entry.zig", "src/core/user_elf.zig", "src/core/vfs.zig", "src/core/pipe.zig", "src/arch/physical_memory.zig", "src/arch/aarch64/timer.zig", "src/arch/riscv64/timer.zig", "src/drivers/framebuffer.zig", "src/security/sandbox.zig", "src/security/quotas.zig" }) |source| {
        const tests = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path(source),
            .target = b.graph.host,
            .optimize = optimize,
            .imports = &.{ .{ .name = "boot_protocol", .module = native_protocol }, .{ .name = "filesystem", .module = native_filesystem }, .{ .name = "security", .module = native_security } },
        }) });
        test_step.dependOn(&b.addRunArtifact(tests).step);
    }
}

fn wifiDrivers(b: *std.Build, name: ?[]const u8, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, relocatable: bool, protocol: *std.Build.Module, memory: *std.Build.Module, kit: *std.Build.Module) *std.Build.Module {
    const arch = target.result.cpu.arch;
    const options: std.Build.Module.CreateOptions = .{
        .target = target,
        .optimize = optimize,
        .stack_protector = false,
        .stack_check = false,
        .single_threaded = true,
        .red_zone = if (arch == .x86_64) false else null,
        .pic = if (target.result.os.tag == .freestanding) relocatable else null,
        .code_model = if (arch == .riscv64) .medium else if (arch == .x86_64) .small else .default,
    };
    var pci_options = options;
    pci_options.root_source_file = b.path("src/drivers/pci/root.zig");
    const pci = b.createModule(pci_options);
    var native_options = options;
    native_options.root_source_file = b.path("src/drivers/pci/native.zig");
    native_options.imports = &.{ .{ .name = "pci", .module = pci }, .{ .name = "boot_protocol", .module = protocol } };
    const native = b.createModule(native_options);
    var driver_options = options;
    driver_options.root_source_file = b.path("../drivers/wifi/src/root.zig");
    driver_options.imports = &.{ .{ .name = "pci", .module = pci }, .{ .name = "pci_native", .module = native }, .{ .name = "boot_protocol", .module = protocol }, .{ .name = "memory_init", .module = memory }, .{ .name = "networkkit", .module = kit } };
    return if (name) |public_name| b.addModule(public_name, driver_options) else b.createModule(driver_options);
}
