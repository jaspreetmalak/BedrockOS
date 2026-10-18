//! Native, static first-profile executables. Build paths are relative to userspace/.
const std = @import("std");
pub const Programs = struct { init: *std.Build.Step.Compile, service: *std.Build.Step.Compile, fault: *std.Build.Step.Compile, io: *std.Build.Step.Compile, exec: *std.Build.Step.Compile, files: *std.Build.Step.Compile, network: *std.Build.Step.Compile, wifi: *std.Build.Step.Compile, app_init: *std.Build.Step.Compile, observer: *std.Build.Step.Compile, worker: *std.Build.Step.Compile, display_init: *std.Build.Step.Compile, display_server: *std.Build.Step.Compile, surface_client: *std.Build.Step.Compile, desktop_init: *std.Build.Step.Compile, desktop_server: *std.Build.Step.Compile, desktop_shell: *std.Build.Step.Compile, desktop_files: *std.Build.Step.Compile, window_init: *std.Build.Step.Compile, window_server: *std.Build.Step.Compile, window_shell: *std.Build.Step.Compile, window_files: *std.Build.Step.Compile, window_notes: *std.Build.Step.Compile };
const Role = enum { service, fault };

pub fn userTarget(b: *std.Build, selected: std.Build.ResolvedTarget) std.Build.ResolvedTarget {
    var query = selected.query;
    switch (selected.result.cpu.arch) {
        .aarch64 => {
            query.cpu_features_add.addFeature(@backingInt(std.Target.aarch64.Feature.strict_align));
            query.cpu_features_sub.addFeature(@backingInt(std.Target.aarch64.Feature.neon));
            query.cpu_features_sub.addFeature(@backingInt(std.Target.aarch64.Feature.fp_armv8));
        },
        .riscv64 => {
            query.cpu_features_add.addFeatureSet(std.Target.riscv.featureSet(&.{ .m, .a, .c, .zicsr, .zifencei }));
            query.cpu_features_sub.addFeatureSet(std.Target.riscv.featureSet(&.{ .f, .d }));
        },
        .x86_64 => {},
        else => @panic("Bedrock64 user images require x86_64, ARM64 or RV64"),
    }
    return b.resolveTargetQuery(query);
}

pub fn addPrograms(b: *std.Build, target: std.Build.ResolvedTarget, abi: *std.Build.Module, runtime: *std.Build.Module) Programs {
    const files = program(b, target, abi, runtime, "bedrock-user-files", "apps/files/src/main.zig", null);
    files.root_module.addImport("files_app", b.dependency("files_app", .{ .target = target, .optimize = .ReleaseSmall, .relocatable = true }).module("files_app"));
    files.setLinkerScript(b.path("runtime/desktop.ld"));
    const network = program(b, target, abi, runtime, "bedrock-user-network", "apps/network-test/src/main.zig", null);
    network.root_module.addImport("networkkit", runtime.import_table.get("networkkit").?);
    const wifi = program(b, target, abi, runtime, "bedrock-user-wifi", "apps/wifi-test/src/main.zig", null);
    wifi.root_module.addImport("networkkit", runtime.import_table.get("networkkit").?);
    wifi.setLinkerScript(b.path("runtime/desktop.ld"));
    const app_init = program(b, target, abi, runtime, "bedrock-app-init", "apps/init/src/supervisor.zig", null);
    const observer = program(b, target, abi, runtime, "bedrock-app-observer", "apps/observer/src/main.zig", null);
    const worker = program(b, target, abi, runtime, "bedrock-app-worker", "apps/worker/src/main.zig", null);
    for ([_]*std.Build.Step.Compile{ app_init, observer, worker }) |application|
        application.setLinkerScript(b.path("runtime/desktop.ld"));
    const display_init = program(b, target, abi, runtime, "bedrock-display-init", "apps/init/src/display_supervisor.zig", null);
    const display_server = program(b, target, abi, runtime, "bedrock-display-server", "services/display-server/src/main.zig", null);
    const surface_client = program(b, target, abi, runtime, "bedrock-surface-client", "apps/surface-client/src/main.zig", null);
    const axisui = b.dependency("axisui", .{ .target = target, .optimize = .ReleaseSmall, .relocatable = true }).module("axisui");
    display_server.root_module.addImport("axisui", axisui);
    surface_client.root_module.addImport("axisui", axisui);
    for ([_]*std.Build.Step.Compile{ display_init, display_server, surface_client }) |application|
        application.setLinkerScript(b.path("runtime/desktop.ld"));
    const desktop_init = program(b, target, abi, runtime, "bedrock-desktop-init", "apps/init/src/desktop_supervisor.zig", null);
    const desktop_server = program(b, target, abi, runtime, "bedrock-desktop-server", "services/display-server/src/desktop_main.zig", null);
    const desktop_shell = program(b, target, abi, runtime, "bedrock-desktop-shell", "apps/shell/src/main.zig", null);
    const desktop_files = program(b, target, abi, runtime, "bedrock-desktop-files", "apps/files/src/compositor_main.zig", null);
    const shell_module = b.dependency("desktop_shell", .{ .target = target, .optimize = .ReleaseSmall, .relocatable = true }).module("desktop_shell");
    // Nested path dependencies may otherwise instantiate the same AxisUI file
    // twice. Every UI type in one executable uses this single module instance.
    shell_module.addImport("axisui", axisui);
    for ([_]*std.Build.Step.Compile{ desktop_server, desktop_shell, desktop_files }) |application|
        application.root_module.addImport("desktop_shell", shell_module);
    const files_module = files.root_module.import_table.get("files_app").?;
    files_module.addImport("axisui", axisui);
    desktop_files.root_module.addImport("files_app", files_module);
    desktop_server.root_module.addImport("axisui", axisui);
    const window_dependency = b.dependency("window_server", .{ .target = target, .optimize = .ReleaseSmall, .relocatable = true });
    const window_module = window_dependency.module("window_server");
    runtime.addImport("window_header", window_dependency.module("window_header"));
    window_module.addImport("axisui", axisui);
    desktop_server.root_module.addImport("window_server", window_module);
    for ([_]*std.Build.Step.Compile{ desktop_init, desktop_server, desktop_shell, desktop_files }) |application|
        application.setLinkerScript(b.path("runtime/desktop.ld"));
    const window_init = program(b, target, abi, runtime, "bedrock-window-init", "apps/init/src/window_supervisor.zig", null);
    const window_server = program(b, target, abi, runtime, "bedrock-window-server", "services/display-server/src/window_main.zig", null);
    const window_shell = program(b, target, abi, runtime, "bedrock-window-shell", "apps/shell/src/window_main.zig", null);
    const window_files = program(b, target, abi, runtime, "bedrock-window-files", "apps/files/src/window_main.zig", null);
    const window_notes = program(b, target, abi, runtime, "bedrock-window-notes", "apps/notes/src/main.zig", null);
    for ([_]*std.Build.Step.Compile{ window_server, window_shell, window_files, window_notes }) |application| {
        application.root_module.addImport("axisui", axisui);
        application.root_module.addImport("desktop_shell", shell_module);
    }
    window_server.root_module.addImport("window_server", window_module);
    window_files.root_module.addImport("files_app", files_module);
    for ([_]*std.Build.Step.Compile{ window_init, window_server, window_shell, window_files, window_notes }) |application|
        application.setLinkerScript(b.path("runtime/desktop.ld"));
    return .{
        .init = program(b, target, abi, runtime, "bedrock-user-init", "apps/init/src/main.zig", null),
        .service = program(b, target, abi, runtime, "bedrock-user-service", "apps/lifecycle-test/src/main.zig", .service),
        .fault = program(b, target, abi, runtime, "bedrock-user-fault", "apps/lifecycle-test/src/main.zig", .fault),
        .io = program(b, target, abi, runtime, "bedrock-user-io", "apps/io-test/src/main.zig", null),
        .exec = program(b, target, abi, runtime, "bedrock-user-exec", "apps/exec-test/src/main.zig", null),
        .files = files,
        .network = network,
        .wifi = wifi,
        .app_init = app_init,
        .observer = observer,
        .worker = worker,
        .display_init = display_init,
        .display_server = display_server,
        .surface_client = surface_client,
        .desktop_init = desktop_init,
        .desktop_server = desktop_server,
        .desktop_shell = desktop_shell,
        .desktop_files = desktop_files,
        .window_init = window_init,
        .window_server = window_server,
        .window_shell = window_shell,
        .window_files = window_files,
        .window_notes = window_notes,
    };
}

fn program(b: *std.Build, target: std.Build.ResolvedTarget, abi: *std.Build.Module, runtime: *std.Build.Module, name: []const u8, source: []const u8, role: ?Role) *std.Build.Step.Compile {
    const module = b.createModule(.{
        .root_source_file = b.path(source),
        .target = target,
        // Keep the initial one-code-page fixture bounded in every kernel mode.
        .optimize = .ReleaseSmall,
        .stack_protector = false,
        .stack_check = false,
        .single_threaded = true,
        .red_zone = false,
        .pic = true,
        .strip = true,
        .code_model = if (target.result.cpu.arch == .riscv64) .medium else .small,
        .imports = &.{
            .{ .name = "bedrock64", .module = abi },
            .{ .name = "userspace_runtime", .module = runtime },
        },
    });
    if (role) |value| {
        const options = b.addOptions();
        options.addOption(Role, "role", value);
        module.addOptions("program_options", options);
    }
    const architecture = switch (target.result.cpu.arch) {
        .x86_64 => "x86_64",
        .aarch64 => "aarch64",
        .riscv64 => "riscv64",
        else => unreachable,
    };
    module.addAssemblyFile(b.path(b.fmt("runtime/src/arch/{s}/entry.S", .{architecture})));
    if (role == .fault)
        module.addAssemblyFile(b.path(b.fmt("runtime/src/arch/{s}/boundary.S", .{architecture})));
    const result = b.addExecutable(.{ .name = name, .root_module = module });
    result.entry = .{ .symbol_name = "_start" };
    result.pie = false;
    result.link_z_common_page_size = 4096;
    result.link_z_max_page_size = 4096;
    result.setLinkerScript(b.path("runtime/linker.ld"));
    return result;
}
