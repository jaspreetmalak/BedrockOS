//! Native, static first-profile executables. Build paths are relative to userspace/.
const std = @import("std");
pub const Programs = struct { init: *std.Build.Step.Compile, service: *std.Build.Step.Compile, fault: *std.Build.Step.Compile, io: *std.Build.Step.Compile, exec: *std.Build.Step.Compile, files: *std.Build.Step.Compile, network: *std.Build.Step.Compile, wifi: *std.Build.Step.Compile };
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
    return .{
        .init = program(b, target, abi, runtime, "bedrock-user-init", "apps/init/src/main.zig", null),
        .service = program(b, target, abi, runtime, "bedrock-user-service", "apps/lifecycle-test/src/main.zig", .service),
        .fault = program(b, target, abi, runtime, "bedrock-user-fault", "apps/lifecycle-test/src/main.zig", .fault),
        .io = program(b, target, abi, runtime, "bedrock-user-io", "apps/io-test/src/main.zig", null),
        .exec = program(b, target, abi, runtime, "bedrock-user-exec", "apps/exec-test/src/main.zig", null),
        .files = files,
        .network = network,
        .wifi = wifi,
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
