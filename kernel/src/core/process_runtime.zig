//! Native ELF processes and serialized blocking syscalls on one CPU/hart.
//! RAM, contexts and handles remain kernel-owned; the portable process table
//! supplies policy. No physical teardown or root switching occurs inside a trap.
const builtin = @import("builtin");
const protocol = @import("boot_protocol");
const abi = @import("bedrock64");
const memory = @import("memory_init");
const arch = @import("isolation_arch");
const contract = @import("isolation_contract");
const security = @import("security");
const policy = @import("process.zig");
const ipc = @import("ipc.zig");
const elf = @import("user_elf.zig");
const user_memory = @import("user_memory.zig");
const filesystem = @import("filesystem");
const vfs = @import("vfs.zig");
const pipe = @import("pipe.zig");
const network = @import("network_runtime.zig");
const network_requests = @import("network_syscalls.zig").Live;
const wifi = @import("wifi_runtime.zig");
const wifi_requests = @import("wifi_syscalls.zig").Live;
const kernel_options = @import("kernel_options");
const app_policy = @import("application_policy.zig");
const app_bundles = @import("app_bundles");
const display_requests = @import("display_syscalls.zig");
const WallClock = @import("wall_clock.zig").Clock;
const clock_requests = @import("clock_syscalls.zig");
var wall_clock: WallClock = .{};
const capacity = 8;
comptime {
    if (elf.code_address != abi.code or elf.data_address != abi.data or elf.page_size != abi.page_size or
        contract.user_code != abi.code or contract.user_stack_top != abi.stack_top)
        @compileError("ELF, syscall ABI and architecture mapping windows must agree");
}
const Pid = policy.Pid;
const FrameOwner = memory.ownership.Owner(5);
const Grants = display_requests.Grants;
const Files = vfs.Files(8);
const PipeDescriptors = pipe.Descriptors(8);
const Path = struct { bytes: [vfs.max_path]u8 = undefined, length: usize = 0 };
const Spawn = struct { path: Path, image_id: u64 = 0, argument: u64 = 0, grant: ?security.handles.Grant = null, pipe_grant: ?pipe.Grant = null, package_id: u64 = 0 };
const Pending = union(enum) {
    none,
    spawn: Spawn,
    exec: struct { path: Path, argument: u64 },
    wait: ?Pid,
    sleep: u64,
    send: struct { object: u64, length: usize, data: [abi.max_payload]u8 },
    receive: struct { object: u64, address: u64, capacity: usize },
    display: struct { number: u64, arg0: u64, arg1: u64, arg2: u64 },
};
const Native = struct {
    live: bool = false,
    pid: Pid = undefined,
    owner: FrameOwner = undefined,
    frames: contract.TaskMemory = undefined,
    space: contract.AddressSpace = undefined,
    context: contract.ContextHandle = undefined,
    profile: security.sandbox.Profile = undefined,
    handles: Grants = .{},
    stdout: ?security.handles.Token = null,
    files: Files = undefined,
    pipes: PipeDescriptors = .{},
    pending: Pending = .none,
    startup_read: bool = false,
    shared: [contract.shared_surface_slots]display_requests.Shared = @splat(.{}),
};
const Channel = struct { id: u64 = 0, owner: Pid = undefined, references: usize = 0 };
var processes: policy.ProcessTable(capacity) = .{};
var mailboxes: ipc.Mailboxes(4, 4) = .{};
var native: [capacity]Native = @splat(.{});
var channels: [4]Channel = @splat(.{});
const disk_runtime = @import("storage_runtime.zig");
const storage = &disk_runtime.storage;
var pipes: pipe.Pipes(4, 256) = .{};
// One retained budget shared by init's app tree, rather than copied allowances.
// Payload pages are charged; private translation-table/kernel overhead is not.
var budget = security.quotas.Budget.init(.{ .memory_pages = if (kernel_options.window_runtime) 16384 else if (kernel_options.display_runtime) 8192 else if (kernel_options.app_runtime) 256 else 27, .processes = 8, .handles = 64, .ipc_bytes = if (kernel_options.display_runtime) 8192 else 1024 });
var display: display_requests.Manager = .{};
var selected: ?Pid = null;
var active = false;
var has_run = false;
var write_console: *const fn ([]const u8) void = undefined;
var receive_blocks: u64 = 0;
var send_blocks: u64 = 0;
var wait_blocks: u64 = 0;
var sleep_blocks: u64 = 0;
var runnable_sleep_wakes: u64 = 0;
var idle_ticks: u64 = 0;
var faults: u64 = 0;
var reports: u64 = 0;
var exec_replacements: u64 = 0;
var file_operations: u64 = 0;
var pipe_operations: u64 = 0;
var installed_ready = false;
var session_teardown = false;
var observer_pid: ?Pid = null;
var observer_starts: usize = 0;
var worker_starts: usize = 0;
var worker_reaped: usize = 0;
var worker_baseline: ?u64 = null;
var worker_handles_baseline: ?u64 = null;
var worker_memory_baseline: ?u64 = null;
var observer_ticks: u64 = 0;
var display_server_starts: usize = 0;
var display_client_a_starts: usize = 0;
var display_client_b_starts: usize = 0;
var display_client_a_exits: usize = 0;
var display_ready_frames_b: u64 = 0;
var desktop_shell_starts: usize = 0;
var desktop_files_starts: usize = 0;
var desktop_files_exits: usize = 0;
var window_notes_starts: usize = 0;
var window_notes_exits: usize = 0;

pub fn isActive() bool {
    return active;
}

pub fn run(comptime console: type, info: *const protocol.BootInfo) !void {
    if (has_run) return error.ProcessRuntimeAlreadyInitialized;
    has_run = true;
    wall_clock = try WallClock.init(info.wall_clock, processes.ticks);
    write_console = &struct {
        fn write(bytes: []const u8) void {
            console.write(bytes);
        }
    }.write;
    if (info.wall_clock.flags == 0) {
        console.write("[kernel] wall clock unavailable\n");
    } else {
        console.write("[kernel] wall clock epoch/offset/flags=");
        console.writeHex(@bitCast(info.wall_clock.seconds));
        console.write(" ");
        console.writeHex(@as(u64, @bitCast(@as(i64, info.wall_clock.utc_offset_minutes))));
        console.write(" ");
        console.writeHex(info.wall_clock.flags);
        console.write("\n");
    }
    try disk_runtime.initializeWithInput(console, info, kernel_options.display_runtime);
    try network.initialize(info);
    try wifi.initialize(info, 0);
    for (wifi.inventory().candidates[0..wifi.inventory().count]) |candidate| {
        console.write("[kernel] Wi-Fi PCI adapter identified vendor/product/bus=");
        console.writeHex(candidate.device.vendor);
        console.write(" ");
        console.writeHex(candidate.device.product);
        console.write(" ");
        console.writeHex(candidate.device.bdf.bus);
        console.write("\n");
    }
    const wifi_boot = wifi.bootReport();
    if (wifi_boot.error_length != 0) {
        console.write("[kernel] driver module: ");
        console.write(wifi_boot.error_text[0..@min(wifi_boot.error_length, wifi_boot.error_text.len)]);
        console.write("\n");
    }
    if (info.drivers.count == 0 and !kernel_options.wifi_acceptance) console.write("[kernel] Wi-Fi driver module absent; radio unavailable\n");
    if (kernel_options.wifi_acceptance) console.write("[kernel] Wi-Fi simulated test radio active\n");
    if (kernel_options.wifi_absence_probe) console.write("[kernel] Wi-Fi physical driver unavailable\n");
    if (network.isAvailable()) console.write("[kernel] network device ready\n");
    const pages = memory.allocator() orelse return error.MemoryNotInitialized;
    const baseline = pages.stats();
    if (kernel_options.app_runtime) return runInstalled(console, info, baseline.free_pages, baseline.allocated_pages);
    const permission = security.sandbox.bit(.ipc_service) | (if (kernel_options.network_echo_port != 0) security.sandbox.bit(.network_client) else @as(u32, 0)) |
        (if (kernel_options.wifi_acceptance) security.sandbox.bit(.wifi_control) | security.sandbox.bit(.wifi_observe) else if (kernel_options.wifi_absence_probe) security.sandbox.bit(.wifi_observe) else @as(u32, 0));
    // Installed app identities are stable across boots; frame-owner tickets are
    // session identities and cannot name persistent private containers.
    const profile = try security.sandbox.Profile.init(1, permission, permission);
    try storage.prepareContainer(profile.app_id);
    inline for (.{
        .{ "/bundle/init.elf", "user_init_image" },
        .{ "/bundle/service.elf", "user_service_image" },
        .{ "/bundle/fault.elf", "user_fault_image" },
        .{ "/bundle/io.elf", "user_io_image" },
        .{ "/bundle/exec.elf", "user_exec_image" },
    }) |item| try storage.mountBundle(profile, item[0], @embedFile(item[1]), true);
    if (kernel_options.network_echo_port != 0) try storage.mountBundle(profile, "/bundle/network.elf", @embedFile("user_network_image"), true);
    if (kernel_options.wifi_acceptance or kernel_options.wifi_absence_probe) try storage.mountBundle(profile, "/bundle/wifi.elf", @embedFile("user_wifi_image"), true);
    try storage.mountBundle(profile, "/bundle/not-elf", "invalid executable", true);
    const init = try processes.spawn(null);
    errdefer processes.abortSpawn(init) catch {};
    try load(init, .{ .path = try catalogPath(abi.image.init), .image_id = abi.image.init, .argument = @as(u64, kernel_options.network_echo_port) | (if (kernel_options.wifi_acceptance) @as(u64, 0x10000) else if (kernel_options.wifi_absence_probe) @as(u64, 0x20000) else 0) }, profile);
    errdefer {
        // An aborted bootstrap session still reclaims every native owner after
        // control has returned to the kernel root, including blocked clients.
        processes.failInit(.{ .code = 99, .faulted = true }) catch {};
        cleanupZombies() catch {};
    }
    try execCapacityProbe(init, profile);
    console.write("[kernel] exec capacity rollback verified\n");
    active = true;
    defer {
        active = false;
        selected = null;
    }
    console.write("[kernel] native ELF init ready\n");
    var turns: usize = 0;
    while (try processes.state(init) != .zombie) {
        turns += 1;
        if (turns > 4096) return error.NativeProcessWorkloadTimeout;
        network.poll();
        wifi.poll(processes.ticks);
        try finishKernelRequests();
        if (try processes.dispatch()) |pid| {
            const task = &native[try processes.slot(pid)];
            if (!task.live or task.pending != .none) return error.ProcessDispatchedBeforeCompletion;
            arch.validateContext(task.context) catch {
                try failProcess(pid);
                try cleanupZombies();
                continue;
            };
            selected = pid;
            arch.resumeContext(task.context);
            selected = null;
            try cleanupZombies();
        } else {
            // Blocked apps are absent from the ready queue. Current adapters
            // poll a real armed hardware timer with kernel interrupts masked.
            // This advances deadlines without executing or restarting an app.
            try arch.idleUntilTick();
            idle_ticks += 1;
            try processes.advanceTicks(1);
            network.poll();
            wifi.poll(processes.ticks);
        }
    }
    try cleanupZombies();
    const init_state = try processes.exitRecord(init);
    console.write("[kernel] native status/faults/receive/send/wait/sleep/runnable/idle=");
    for ([_]u64{ init_state.status.code, faults, receive_blocks, send_blocks, wait_blocks, sleep_blocks, runnable_sleep_wakes, idle_ticks }) |value| {
        console.writeHex(value);
        console.write(" ");
    }
    console.write("\n");
    if (init_state.status.code != 0 or init_state.status.faulted or faults != 3 or
        receive_blocks == 0 or send_blocks == 0 or wait_blocks == 0 or sleep_blocks < 3 or
        runnable_sleep_wakes == 0 or idle_ticks < 2 or reports == 0 or
        exec_replacements != 1 or file_operations == 0 or pipe_operations == 0)
        return error.NativeUserspaceVerificationFailed;
    const after = pages.stats();
    if (network.liveCount() != 0) return error.NativeSocketLeak;
    if (kernel_options.network_echo_port != 0) console.write("[kernel] network endpoint cleanup verified\n");
    if (kernel_options.wifi_acceptance) {
        if (wifi.status().state != .disabled) return error.NativeWifiControlLeak;
        console.write("[kernel] Wi-Fi control cleanup verified\n");
    }
    if (kernel_options.wifi_absence_probe) {
        if (wifi.status().state != .unavailable or wifi.status().simulated) return error.NativeWifiSimulationLeak;
        console.write("[kernel] Wi-Fi control cleanup verified\n");
    }
    if (after.allocated_pages != baseline.allocated_pages or after.free_pages != baseline.free_pages or
        budget.used.memory_pages != 0 or budget.used.processes != 0 or budget.used.handles != 0 or
        budget.used.ipc_bytes != 0) return error.NativeProcessResourceLeak;
    for (channels) |channel| if (channel.id != 0) return error.NativeChannelLeak;
    if (pipes.liveCount() != 0) return error.NativePipeLeak;
    console.write("[kernel] filesystem I/O verified\n[kernel] pipe lifecycle verified\n[kernel] filesystem exec replacement verified\n");
    console.write("[kernel] native process lifecycle verified\n[kernel] blocking wait verified\n[kernel] sleep wakeup verified\n[kernel] cooperative sleep progress verified\n[kernel] capability IPC verified\n[kernel] native process cleanup verified\n");
}

fn runInstalled(comptime console: type, info: *const protocol.BootInfo, baseline_free: u64, baseline_allocated: u64) !void {
    const std = @import("std");
    if (info.apps.archive.length == 0) return error.InstalledApplicationArchiveMissing;
    const source: [*]const u8 = @ptrFromInt(info.apps.archive.base);
    const bytes = source[0..@intCast(info.apps.archive.length)];
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    if (!std.crypto.timing_safe.eql([32]u8, digest, info.apps.sha256)) return error.InstalledArchiveChanged;
    const archive = try app_bundles.inspect(bytes, switch (builtin.cpu.arch) {
        .x86_64 => .x86_64,
        .aarch64 => .aarch64,
        .riscv64 => .riscv64,
        else => unreachable,
    });
    if (archive.count != (if (kernel_options.window_runtime) @as(u32, 5) else if (kernel_options.display_runtime) @as(u32, 4) else @as(u32, 3))) return error.IncompleteInstalledCatalogue;
    // Inspect every executable and bind its identity before exposing any VFS
    // node. No archive field can grant a permission or widen memory limits.
    for (0..archive.count) |index| {
        const entry = archive.entry(index).?;
        if (kernel_options.window_runtime) {
            if (entry.app_id != app_policy.init_id and entry.app_id != app_policy.display_server_id and entry.app_id != app_policy.shell_id and entry.app_id != app_policy.files_id and entry.app_id != app_policy.notes_id) return error.InvalidInstalledIdentity;
        } else if (kernel_options.desktop_runtime) {
            if (entry.app_id != app_policy.init_id and entry.app_id != app_policy.display_server_id and entry.app_id != app_policy.shell_id and entry.app_id != app_policy.files_id) return error.InvalidInstalledIdentity;
        } else if (kernel_options.display_runtime) {
            if (entry.app_id != app_policy.init_id and entry.app_id != app_policy.display_server_id and entry.app_id != app_policy.surface_one_id and entry.app_id != app_policy.surface_two_id) return error.InvalidInstalledIdentity;
        } else if (entry.app_id != app_policy.init_id and entry.app_id != app_policy.observer_id and entry.app_id != app_policy.worker_id) return error.InvalidInstalledIdentity;
        try app_policy.validateIdentity(entry.app_id, entry.name, entry.path);
        _ = try inspectInstalled(entry.bytes, try app_policy.lookup(entry.app_id));
    }
    for (0..archive.count) |index| {
        const entry = archive.entry(index).?;
        const profile = try (try app_policy.lookup(entry.app_id)).profile();
        try storage.prepareContainer(profile.app_id);
        try storage.mountBundle(profile, entry.path, entry.bytes, true);
    }
    if (kernel_options.display_runtime) try display.initialize(info, &budget, write_console);
    const package = try app_policy.lookup(app_policy.init_id);
    const init = try processes.spawn(null);
    errdefer processes.abortSpawn(init) catch {};
    try load(init, .{ .path = try pathFrom(package.path), .package_id = package.id }, try package.profile());
    errdefer {
        session_teardown = true;
        processes.failInit(.{ .code = 99, .faulted = true }) catch {};
        cleanupZombies() catch {};
    }
    active = true;
    defer {
        active = false;
        selected = null;
    }
    console.write("[kernel] installed native init ready; persistent supervisor\n");
    var turns: usize = 0;
    while (true) {
        if (try processes.state(init) == .zombie) return error.PersistentInitExited;
        if (kernel_options.app_acceptance) {
            turns += 1;
            if (turns > (if (kernel_options.desktop_runtime) @as(usize, 500000) else @as(usize, 50000))) return error.InstalledRuntimeTimeout;
        }
        network.poll();
        wifi.poll(processes.ticks);
        try finishKernelRequests();
        if (try processes.dispatch()) |pid| {
            const task = &native[try processes.slot(pid)];
            if (!task.live or task.pending != .none) return error.ProcessDispatchedBeforeCompletion;
            selected = pid;
            arch.validateContext(task.context) catch {
                selected = null;
                try failProcess(pid);
                try cleanupZombies();
                continue;
            };
            arch.resumeContext(task.context);
            selected = null;
            try cleanupZombies();
        } else {
            try arch.idleUntilTick();
            idle_ticks += 1;
            try processes.advanceTicks(1);
        }
        if (kernel_options.app_acceptance and installed_ready and (!kernel_options.display_runtime or (display.finish_requested and display.metrics.input_events >= 3 and
            (if (kernel_options.desktop_runtime) display.metrics.presented > display_ready_frames_b else display.metrics.frames_b > display_ready_frames_b))))
        {
            // Only the test host stops the otherwise persistent supervisor.
            // All teardown happens after returning to the kernel root.
            try processes.failInit(.{ .code = 0, .faulted = true });
            try cleanupZombies();
            const after = memory.allocator().?.stats();
            if (after.free_pages != baseline_free or after.allocated_pages != baseline_allocated or budget.used.memory_pages != 0 or
                budget.used.processes != 0 or budget.used.handles != 0 or budget.used.ipc_bytes != 0 or pipes.liveCount() != 0 or network.liveCount() != 0 or (kernel_options.display_runtime and (display.registry.liveCount() != 0 or display.bus.liveCount() != 0 or display.bus.queuedCount() != 0)))
                return error.InstalledApplicationResourceLeak;
            if (kernel_options.window_runtime) {
                console.write("[kernel] window desktop teardown balanced\n");
                console.write("[kernel] window desktop acceptance complete\n");
            } else if (kernel_options.desktop_runtime) {
                console.write("[kernel] service desktop teardown balanced\n");
                console.write("[kernel] service desktop acceptance complete\n");
            } else if (kernel_options.display_runtime) {
                console.write("[kernel] focused display input verified\n");
                console.write("[kernel] display teardown balanced\n");
                console.write("[kernel] display acceptance complete\n");
            } else {
                console.write("[kernel] installed app teardown balanced; pages handles pipes reclaimed\n");
                console.write("[kernel] application runtime acceptance complete\n");
            }
            return;
        }
    }
}

fn verifyInstalledReady() !void {
    const cycles: usize = if (kernel_options.app_acceptance) 3 else 1;
    if (observer_starts != 1 or worker_starts != cycles * 2 + 1 or worker_reaped != cycles * 2 or faults != cycles or observer_ticks < 2)
        return error.ApplicationSupervisionIncomplete;
    const observer = observer_pid orelse return error.ApplicationSupervisionIncomplete;
    if (try processes.state(observer) == .zombie or !native[try processes.slot(observer)].live) return error.ObserverDidNotSurvive;
    var workers: usize = 0;
    for (native) |task| if (task.live and task.frames.app and task.profile.app_id == app_policy.worker_id and task.startup_read) {
        workers += 1;
    };
    if (workers != 1 or budget.used.processes != 3) return error.PersistentApplicationsMissing;
    installed_ready = true;
    write_console("[kernel] installed app identities 101/102/103 verified\n");
    write_console("[kernel] observer survived worker faults; zeroed heaps and relaunch cleanup verified\n");
}

fn pathFrom(bytes: []const u8) !Path {
    if (bytes.len == 0 or bytes.len > vfs.max_path) return error.PathTooLong;
    var result: Path = .{};
    @memcpy(result.bytes[0..bytes.len], bytes);
    result.length = bytes.len;
    return result;
}

fn copyPath(task: *const Native, address: u64, length: u64) !Path {
    if (length == 0 or length > vfs.max_path) return error.PathTooLong;
    var result: Path = .{ .length = @intCast(length) };
    try copyin(task, address, result.bytes[0..result.length]);
    return result;
}

fn catalogPath(id: u64) !Path {
    return pathFrom(switch (id) {
        abi.image.init => "/bundle/init.elf",
        abi.image.service => "/bundle/service.elf",
        abi.image.network => "/bundle/network.elf",
        abi.image.wifi => "/bundle/wifi.elf",
        abi.image.fault, abi.image.fault_stack, abi.image.fault_boundary => "/bundle/fault.elf",
        else => return error.UnknownUserImage,
    });
}

const ImageParts = struct { owner: FrameOwner, frames: contract.TaskMemory, space: contract.AddressSpace, context: contract.ContextHandle };

fn inspectInstalled(bytes: []const u8, package: app_policy.Package) !elf.Image {
    const image = try elf.inspectApplication(bytes, builtin.cpu.arch);
    for (image.segments[0..image.count]) |segment| {
        const base = if (segment.flags == 5) contract.application_code else contract.application_data;
        const pages = if (segment.flags == 5) package.code_pages else package.data_pages;
        if (segment.address + segment.memory_size > base + @as(u64, pages) * contract.page_size) return error.UnsupportedAddressRange;
    }
    return image;
}

/// Stages an entire image while the old image stays intact. This may fail at
/// full architecture capacity; no reclaim-old-first fallback weakens exec.
fn buildImage(pid: Pid, bytes: []const u8, inherited_token: u64, argument: u64, extended: bool, installed: ?app_policy.Package) !ImageParts {
    // The trusted launcher chooses the layout. ELF fields cannot enlarge it.
    const image = if (installed) |package| try inspectInstalled(bytes, package) else if (extended) try elf.inspectDesktop(bytes, builtin.cpu.arch) else try elf.inspect(bytes, builtin.cpu.arch);
    var code_pages: u16 = 1;
    var data_pages: u16 = 1;
    if (extended or installed != null) {
        for (image.segments[0..image.count]) |segment| {
            if (segment.flags == 5) code_pages = @intCast((segment.address + segment.memory_size - contract.desktop_code + 4095) / 4096) else data_pages = @intCast((segment.address + segment.memory_size - contract.desktop_data + 4095) / 4096);
        }
        if (installed) |package| {
            if (code_pages > package.code_pages or data_pages > package.data_pages) return error.UnsupportedAddressRange;
        } else if (code_pages > 4 or data_pages > 1) return error.UnsupportedAddressRange;
    }
    const stack_pages: u16 = if (installed) |package| package.stack_pages else if (extended) 4 else 1;
    const heap_pages: u16 = if (installed) |package| package.heap_pages else 0;
    const charge = @as(u64, code_pages) + data_pages + stack_pages + heap_pages + @intFromBool(installed != null);
    try budget.reserve(.{ .memory_pages = charge });
    errdefer budget.release(.{ .memory_pages = charge }) catch @panic("image quota rollback");
    var owner = try FrameOwner.init(memory.allocator().?, try memory.newOwnerId());
    errdefer owner.releaseAll() catch @panic("native frame rollback");
    const frames: contract.TaskMemory = .{ .code = try frameRange(&owner, code_pages), .data = try frameRange(&owner, data_pages), .stack = try frameRange(&owner, stack_pages), .code_pages = code_pages, .data_pages = data_pages, .stack_pages = stack_pages, .desktop = extended and installed == null, .app = installed != null, .startup = if (installed != null) try frameRange(&owner, 1) else 0, .heap = if (heap_pages != 0) try frameRange(&owner, heap_pages) else 0, .heap_pages = heap_pages };
    for (image.segments[0..image.count]) |segment| {
        const code_segment = segment.flags == 5;
        const window = if (code_segment) frames.codeVirtual() else frames.dataVirtual();
        const physical = (if (code_segment) frames.code else frames.data) + (segment.address - window);
        const destination: [*]volatile u8 = @ptrFromInt(physical);
        for (bytes[@intCast(segment.offset)..@intCast(segment.offset + segment.file_size)], 0..) |byte, index| destination[index] = byte;
    }
    const parent = try processes.parent(pid);
    if (installed) |package| {
        var startup: abi.Startup = .{ .pid = @backingInt(pid), .parent = if (parent) |value| @backingInt(value) else 0, .app_id = package.id, .inherited_token = inherited_token, .launch_arg = argument, .heap_capacity = @as(u64, heap_pages) * abi.page_size, .heap_length = @as(u64, heap_pages) * abi.page_size, .flags = if (kernel_options.app_acceptance) abi.application.test_mode else 0, .argc = 1, .envc = 1 };
        startup.args[0] = try abi.Text.init(package.name);
        var environment: [56]u8 = undefined;
        startup.environment[0] = try abi.Text.init(try @import("std").fmt.bufPrint(&environment, "BEDROCK_ROLE={s}", .{package.role}));
        const destination: [*]u8 = @ptrFromInt(frames.startup);
        @memcpy(destination[0..@sizeOf(abi.Startup)], @import("std").mem.asBytes(&startup));
    }
    const space = try arch.create(frames);
    errdefer arch.destroy(space) catch @panic("native space rollback");
    const context = try arch.createContext(space, .{ .entry = image.entry, .user_sp = frames.stackTop(), .arg0 = if (parent) |value| @backingInt(value) else 0, .arg1 = inherited_token, .arg2 = argument });
    errdefer arch.destroyContext(context) catch @panic("native context rollback");
    try arch.validateContext(context);
    return .{ .owner = owner, .frames = frames, .space = space, .context = context };
}

fn stdoutGrant() security.handles.Grant {
    return .{ .kind = .file, .object_id = 1, .rights = security.handles.rights.write };
}

fn load(pid: Pid, request: Spawn, profile: security.sandbox.Profile) !void {
    const bytes = try storage.execPath(profile, request.path.bytes[0..request.path.length]);
    const slot = try processes.slot(pid);
    if (native[slot].live) return error.ProcessSlotAlreadyOwned;
    try budget.reserve(.{ .processes = 1 });
    errdefer budget.release(.{ .processes = 1 }) catch @panic("native process rollback");
    var handles: Grants = .{};
    var pipe_descriptors = try PipeDescriptors.init(profile.app_id);
    const files = try Files.init(profile);
    const stdout_grant = stdoutGrant();
    try profile.authorizeGrant(stdout_grant, .{ .inherited_stream = security.handles.rights.write });
    try budget.reserve(.{ .handles = 1 });
    errdefer budget.release(.{ .handles = 1 }) catch @panic("native stdout rollback");
    const stdout = try handles.insert(stdout_grant);
    var inherited_token: u64 = 0;
    var inherited_charge = false;
    errdefer if (inherited_charge) budget.release(.{ .handles = 1 }) catch @panic("native IPC grant rollback");
    if (request.grant) |grant| {
        try profile.authorizeGrant(grant, .ipc_service);
        try budget.reserve(.{ .handles = 1 });
        inherited_charge = true;
        inherited_token = @backingInt(try handles.insert(grant));
    }
    var pipe_retained = false;
    errdefer if (pipe_retained) {
        _ = pipes.release(request.pipe_grant.?) catch @panic("inherited pipe rollback");
    };
    if (request.pipe_grant) |grant| {
        if (request.grant != null) return error.PermissionDenied;
        try budget.reserve(.{ .handles = 1 });
        inherited_charge = true;
        inherited_token = @backingInt(try pipe_descriptors.insert(profile.app_id, grant));
        try pipes.retain(grant);
        pipe_retained = true;
    }
    const argument = switch (request.image_id) {
        abi.image.fault_stack, abi.image.fault_boundary => request.image_id,
        else => request.argument,
    };
    const package: ?app_policy.Package = if (request.package_id != 0) try app_policy.lookup(request.package_id) else null;
    const image = try buildImage(pid, bytes, inherited_token, argument, extendedProfile(profile, request.path), package);
    if (request.grant) |grant| channelFor(grant.object_id).?.references += 1;
    // Moving a ledger transfers its lifetime; the local owner is no longer live.
    native[slot] = .{ .live = true, .pid = pid, .owner = image.owner, .frames = image.frames, .space = image.space, .context = image.context, .profile = profile, .handles = handles, .stdout = stdout, .files = files, .pipes = pipe_descriptors };
}

fn extendedProfile(profile: security.sandbox.Profile, path: Path) bool {
    return (kernel_options.wifi_acceptance or kernel_options.wifi_absence_probe) and profile.app_id == 1 and
        @import("std").mem.eql(u8, path.bytes[0..path.length], "/bundle/wifi.elf");
}
fn frameRange(owner: *FrameOwner, count: u16) !u64 {
    const ticket = try owner.allocate(count, 1);
    const range = try owner.resolve(ticket);
    memory.clearRange(range);
    return range.base;
}

const Regions = struct {
    values: [5 + contract.shared_surface_slots]user_memory.Region = undefined,
    count: usize,
    fn slice(self: *const Regions) []const user_memory.Region {
        return self.values[0..self.count];
    }
};
fn regions(task: *const Native) Regions {
    var result: Regions = .{ .count = task.frames.mappingCount() };
    const mappings = task.frames.allMappings();
    for (mappings[0..result.count], 0..) |mapping, index| result.values[index] = .{ .virtual = mapping.virtual, .physical = mapping.physical, .length = @as(u64, mapping.pages) * abi.page_size, .writable = mapping.writable };
    for (task.shared, 0..) |shared, slot| if (shared.object != 0) {
        result.values[result.count] = .{ .virtual = contract.shared_surface_base + slot * contract.shared_surface_stride, .physical = shared.mapping.physical, .length = @as(u64, shared.mapping.pages) * abi.page_size, .writable = shared.mapping.writable };
        result.count += 1;
    };
    return result;
}

pub fn dispatch(event: *const contract.Event, reply: *contract.Reply) void {
    reply.* = .{ .action = contract.action_terminate, .result = 0 };
    const pid = selected orelse @panic("native trap without a selected process");
    const task = &native[processes.slot(pid) catch @panic("native selected PID stale")];
    if (event.kind == contract.event_fault) {
        failProcess(pid) catch @panic("native fault transition failed");
        return;
    }
    const advance: u64 = if (event.kind == contract.event_syscall) switch (builtin.cpu.arch) {
        .x86_64 => 2,
        .aarch64 => 4,
        .riscv64 => 0,
        else => unreachable,
    } else 0;
    if (event.pc < advance or event.pc - advance < task.frames.codeVirtual() or event.pc - advance >= task.frames.codeEnd()) {
        failProcess(pid) catch @panic("invalid user PC transition failed");
        return;
    }
    if (event.kind == contract.event_timer) {
        processes.preempt(pid) catch @panic("native timer preemption state");
        reply.action = contract.action_suspend;
        return;
    }
    if (event.kind != contract.event_syscall) @panic("unexpected native trap kind");
    reply.action = contract.action_resume;
    syscall(pid, task, event, reply) catch |err| {
        if (processes.state(pid) catch @panic("native syscall identity lost") != .running)
            @panic("native syscall failed after committing a state transition");
        reply.result = errorResult(err);
    };
}

fn failProcess(pid: Pid) !void {
    faults += 1;
    if (kernel_options.window_runtime) desktopProcessLog("[kernel] window process fault", &native[try processes.slot(pid)]);
    const status: policy.ExitStatus = .{ .code = abi.fault_exit_status, .faulted = true };
    if (processes.init_pid == pid) try processes.failInit(status) else try processes.exit(pid, status);
}

fn syscall(pid: Pid, task: *Native, event: *const contract.Event, reply: *contract.Reply) !void {
    if (event.number >= 0x600 and event.number <= 0x624) {
        if (!kernel_options.display_runtime or !task.frames.app) return error.NotSupported;
        task.pending = .{ .display = .{ .number = event.number, .arg0 = event.arg0, .arg1 = event.arg1, .arg2 = event.arg2 } };
        try processes.block(pid, .kernel_request);
        reply.action = contract.action_suspend;
        return;
    }
    const mapped = regions(task);
    switch (event.number) {
        abi.syscall.getpid => reply.result = @backingInt(pid),
        abi.syscall.clock_ticks => reply.result = processes.ticks,
        abi.syscall.clock_read => reply.result = try clock_requests.read(wall_clock, mapped.slice(), event.arg0, event.arg1, event.arg2, processes.ticks),
        abi.syscall.startup_info => {
            if (!task.frames.app) return error.NotSupported;
            if (event.arg0 != 0 or event.arg1 != 0 or event.arg2 != 0) return error.InvalidStartupRequest;
            if (!task.startup_read) {
                task.startup_read = true;
                switch (task.profile.app_id) {
                    app_policy.observer_id => {
                        if (observer_pid) |existing| {
                            if (existing != pid) return error.ObserverWasRestarted;
                        } else {
                            observer_starts += 1;
                            observer_pid = pid;
                        }
                    },
                    app_policy.worker_id => worker_starts += 1,
                    app_policy.display_server_id => display_server_starts += 1,
                    app_policy.shell_id => desktop_shell_starts += 1,
                    app_policy.files_id => desktop_files_starts += 1,
                    app_policy.notes_id => window_notes_starts += 1,
                    app_policy.surface_one_id => display_client_a_starts += 1,
                    app_policy.surface_two_id => display_client_b_starts += 1,
                    else => {},
                }
                if (kernel_options.window_runtime) desktopProcessLog("[kernel] window process started", task) else if (kernel_options.desktop_runtime) desktopProcessLog("[kernel] desktop process started", task);
            }
            reply.result = contract.application_startup;
        },
        abi.syscall.application_ready => {
            if (kernel_options.display_runtime) return error.NotSupported;
            if (!task.frames.app or task.profile.app_id != app_policy.init_id or !task.profile.mayRequest(.app_launch)) return error.PermissionDenied;
            if (event.arg0 != 0 or event.arg1 != 0 or event.arg2 != 0) return error.InvalidStartupRequest;
            try verifyInstalledReady();
            reply.result = 0;
        },
        abi.syscall.display_ready => {
            if (!kernel_options.display_runtime or kernel_options.desktop_runtime or !task.frames.app or task.profile.app_id != app_policy.init_id or !task.profile.mayRequest(.app_launch)) return error.PermissionDenied;
            if (event.arg0 != 0 or event.arg1 != 0 or event.arg2 != 0) return error.InvalidStartupRequest;
            const cycles: usize = if (kernel_options.app_acceptance) 3 else 1;
            if (display_server_starts != 1 or display_client_b_starts != 1 or display_client_a_starts != cycles * 2 + 1 or display_client_a_exits != cycles * 2 or faults != cycles or display.metrics.reclaimed_a != cycles * 2 or
                display.metrics.frames_a < cycles * 6 + 3 or display.metrics.frames_b < 3 or display.metrics.ro_released < cycles * 6 + 3 or display.registry.liveCount() != 3 or budget.used.processes != 4) return error.DisplaySupervisionIncomplete;
            installed_ready = true;
            display_ready_frames_b = display.metrics.frames_b;
            write_console("[kernel] display identities and surface ownership verified\n");
            reply.result = 0;
        },
        abi.syscall.desktop_ready => {
            if (!kernel_options.desktop_runtime or kernel_options.window_runtime or !task.frames.app or task.profile.app_id != app_policy.init_id or !task.profile.mayRequest(.app_launch)) return error.PermissionDenied;
            if (event.arg0 != 0 or event.arg1 != 0 or event.arg2 != 0) return error.InvalidStartupRequest;
            if (display_server_starts != 1 or desktop_shell_starts != 1 or desktop_files_starts == 0 or liveDesktopPid(app_policy.files_id) == 0 or
                display.metrics.frames_files == 0 or display.metrics.frames_shell == 0 or display.metrics.presented == 0 or display.registry.liveCount() != 5 or budget.used.processes != 4) return error.DisplaySupervisionIncomplete;
            installed_ready = true;
            display_ready_frames_b = display.metrics.presented;
            write_console("[kernel] desktop service identities verified\n");
            reply.result = 0;
        },
        abi.syscall.window_ready => {
            if (!kernel_options.window_runtime or !task.frames.app or task.profile.app_id != app_policy.init_id or !task.profile.mayRequest(.app_launch)) return error.PermissionDenied;
            if (event.arg0 != 0 or event.arg1 != 0 or event.arg2 != 0) return error.InvalidStartupRequest;
            const files_windows = try display.producerCount(app_policy.files_id);
            const notes_windows = try display.producerCount(app_policy.notes_id);
            const expected_surfaces = try @import("window_message_policy.zig").sceneSurfaceCount(files_windows, notes_windows);
            if (display_server_starts != 1 or desktop_shell_starts != 1 or desktop_files_starts == 0 or window_notes_starts == 0 or
                liveDesktopPid(app_policy.files_id) == 0 or liveDesktopPid(app_policy.notes_id) == 0 or display.metrics.frames_files == 0 or display.metrics.frames_notes == 0 or
                files_windows == 0 or notes_windows == 0 or display.metrics.frames_shell == 0 or display.metrics.presented == 0 or display.registry.liveCount() != expected_surfaces or budget.used.processes != 5) return error.DisplaySupervisionIncomplete;
            installed_ready = true;
            display_ready_frames_b = display.metrics.presented;
            write_console("[kernel] window desktop identities verified\n");
            reply.result = 0;
        },
        abi.syscall.spawn_app => {
            const target_profile = try app_policy.authorizeLaunch(task.profile, event.arg0);
            if (!task.frames.app) return error.PermissionDenied;
            const package = try app_policy.lookup(target_profile.app_id);
            _ = try storage.execPath(target_profile, package.path);
            var request: Spawn = .{ .path = try pathFrom(package.path), .package_id = package.id, .argument = event.arg1 };
            if (event.arg2 != 0) {
                request.pipe_grant = try task.pipes.resolve(task.profile.app_id, @fromBackingInt(event.arg2), pipe.write_right);
                request.pipe_grant.?.rights = pipe.write_right;
            }
            if (package.id == app_policy.worker_id) {
                for (native) |candidate| if (candidate.live and candidate.frames.app and candidate.profile.app_id == app_policy.worker_id) return error.ApplicationAlreadyRunning;
                const pages = memory.allocator().?.stats().free_pages;
                if (worker_baseline) |expected| {
                    if (pages != expected or budget.used.memory_pages != worker_memory_baseline.?) return error.WorkerRelaunchResourceLeak;
                } else {
                    worker_baseline = pages;
                    worker_memory_baseline = budget.used.memory_pages;
                }
                worker_handles_baseline = budget.used.handles;
            }
            task.pending = .{ .spawn = request };
            try processes.block(pid, .kernel_request);
            reply.action = contract.action_suspend;
        },
        abi.syscall.wifi_status, abi.syscall.wifi_scan_start, abi.syscall.wifi_scan_read, abi.syscall.wifi_join, abi.syscall.wifi_disconnect, abi.syscall.wifi_enable => {
            reply.result = try wifi_requests.serve(task.profile, mapped.slice(), event.number, event.arg0, event.arg1, event.arg2, processes.ticks);
        },
        abi.syscall.udp_open, abi.syscall.udp_send, abi.syscall.udp_receive => {
            reply.result = try network_requests.serve(task.profile, &task.handles, &budget, mapped.slice(), event.number, event.arg0, event.arg1, event.arg2);
        },
        abi.syscall.list, abi.syscall.mkdir, abi.syscall.copy, abi.syscall.rename, abi.syscall.unlink, abi.syscall.nullify => {
            reply.result = try @import("directory_syscalls.zig").serve(task.profile, mapped.slice(), event.number, event.arg0, event.arg1, event.arg2);
            file_operations += 1;
            if (kernel_options.desktop_runtime and task.profile.app_id == app_policy.files_id and event.number == abi.syscall.nullify)
                write_console("[kernel] Files nullify logical banks verified\n");
        },
        abi.syscall.spawn => {
            if (task.frames.app) return error.NotSupported;
            if (event.arg0 != abi.image.service and event.arg0 != abi.image.fault and
                event.arg0 != abi.image.fault_stack and event.arg0 != abi.image.fault_boundary) return error.UnknownUserImage;
            var grant: ?security.handles.Grant = null;
            if (event.arg1 != 0) {
                const existing = try task.handles.resolve(@fromBackingInt(event.arg1), .ipc, 0);
                if (event.arg2 & ~existing.rights != 0) return error.PermissionDenied;
                try security.handles.validateRights(.ipc, event.arg2);
                grant = .{ .kind = .ipc, .object_id = existing.object_id, .rights = event.arg2 };
            } else if (event.arg2 != 0) return error.PermissionDenied;
            task.pending = .{ .spawn = .{ .path = try catalogPath(event.arg0), .image_id = event.arg0, .grant = grant } };
            try processes.block(pid, .kernel_request);
            reply.action = contract.action_suspend;
        },
        abi.syscall.spawn_path, abi.syscall.spawn_pipe => {
            // Installed application identities are assigned only by the
            // trusted launch service; path spawning remains a fixture API.
            if (task.frames.app) return error.NotSupported;
            const path = try copyPath(task, event.arg0, event.arg1);
            _ = try storage.execPath(task.profile, path.bytes[0..path.length]);
            var request: Spawn = .{ .path = path };
            if (event.number == abi.syscall.spawn_pipe) {
                request.pipe_grant = try task.pipes.resolve(task.profile.app_id, @fromBackingInt(event.arg2), pipe.write_right);
                // A transferred stream retains only the existing writer right.
                request.pipe_grant.?.rights = pipe.write_right;
            } else request.argument = event.arg2;
            task.pending = .{ .spawn = request };
            try processes.block(pid, .kernel_request);
            reply.action = contract.action_suspend;
        },
        abi.syscall.exec => {
            const path = try copyPath(task, event.arg0, event.arg1);
            _ = try storage.execPath(task.profile, path.bytes[0..path.length]);
            task.pending = .{ .exec = .{ .path = path, .argument = event.arg2 } };
            try processes.block(pid, .kernel_request);
            reply.action = contract.action_suspend;
        },
        abi.syscall.open => {
            const path = try copyPath(task, event.arg0, event.arg1);
            if (event.arg2 & ~@as(u64, 15) != 0) return error.InvalidOpenFlags;
            try budget.reserve(.{ .handles = 1 });
            errdefer budget.release(.{ .handles = 1 }) catch @panic("file descriptor rollback");
            const descriptor = try task.files.open(storage, task.profile, path.bytes[0..path.length], .{
                .read = event.arg2 & 1 != 0,
                .write = event.arg2 & 2 != 0,
                .create = event.arg2 & 4 != 0,
                .truncate = event.arg2 & 8 != 0,
            });
            reply.result = @backingInt(descriptor);
            file_operations += 1;
        },
        abi.syscall.read => {
            if (event.arg2 > 256) return error.InvalidReadLength;
            const length: usize = @intCast(event.arg2);
            var bytes: [256]u8 = undefined;
            // Validate the whole requested output before either backend consumes
            // bytes or advances an offset. Zero-length I/O still checks the fd.
            const physical = if (length != 0) try user_memory.translateWrite(mapped.slice(), event.arg1, length) else 0;
            const got = if (event.arg0 & (3 << 62) == pipe.descriptor_tag) blk: {
                const grant = try task.pipes.resolve(task.profile.app_id, @fromBackingInt(event.arg0), pipe.read_right);
                const count = try pipes.read(grant, bytes[0..length]);
                try budget.release(.{ .ipc_bytes = count });
                pipe_operations += 1;
                break :blk count;
            } else blk: {
                const count = try task.files.read(storage, task.profile, @fromBackingInt(event.arg0), bytes[0..length]);
                file_operations += 1;
                break :blk count;
            };
            if (got != 0) {
                const destination: [*]volatile u8 = @ptrFromInt(physical);
                for (bytes[0..got], 0..) |byte, index| destination[index] = byte;
            }
            reply.result = got;
        },
        abi.syscall.seek => {
            if (event.arg0 & (3 << 62) == pipe.descriptor_tag) {
                _ = try task.pipes.resolve(task.profile.app_id, @fromBackingInt(event.arg0), 0);
                return error.NotSeekable;
            }
            const whence: vfs.Whence = switch (event.arg2) {
                0 => .start,
                1 => .current,
                2 => .end,
                else => return error.InvalidSeek,
            };
            reply.result = try task.files.seek(storage, task.profile, @fromBackingInt(event.arg0), @bitCast(event.arg1), whence);
            file_operations += 1;
        },
        abi.syscall.pipe => {
            if (event.arg1 != 0 or event.arg2 != 0) return error.InvalidPipe;
            const physical = try user_memory.translateWrite(mapped.slice(), event.arg0, 16);
            try budget.reserve(.{ .handles = 2 });
            errdefer budget.release(.{ .handles = 2 }) catch @panic("pipe descriptor rollback");
            const object = try pipes.create();
            errdefer pipes.abandon(object) catch @panic("pipe object rollback");
            const reader_grant: pipe.Grant = .{ .object = object, .rights = pipe.read_right };
            const writer_grant: pipe.Grant = .{ .object = object, .rights = pipe.write_right };
            const reader = try task.pipes.insert(task.profile.app_id, reader_grant);
            errdefer _ = task.pipes.close(task.profile.app_id, reader) catch @panic("pipe reader rollback");
            const writer = try task.pipes.insert(task.profile.app_id, writer_grant);
            pipes.retain(reader_grant) catch @panic("pipe reader retain");
            pipes.retain(writer_grant) catch @panic("pipe writer retain");
            var pair: [16]u8 = undefined;
            putU64(pair[0..8], @backingInt(reader));
            putU64(pair[8..16], @backingInt(writer));
            const destination: [*]volatile u8 = @ptrFromInt(physical);
            for (pair, 0..) |byte, index| destination[index] = byte;
            reply.result = 0;
            pipe_operations += 1;
        },
        abi.syscall.dup => {
            if (event.arg2 != 0 or event.arg1 == 0) return error.PermissionDenied;
            var grant = try task.pipes.resolve(task.profile.app_id, @fromBackingInt(event.arg0), event.arg1);
            grant.rights = event.arg1;
            try budget.reserve(.{ .handles = 1 });
            errdefer budget.release(.{ .handles = 1 }) catch @panic("pipe duplicate rollback");
            const token = try task.pipes.insert(task.profile.app_id, grant);
            pipes.retain(grant) catch @panic("pipe duplicate retain");
            reply.result = @backingInt(token);
            pipe_operations += 1;
        },
        abi.syscall.exit => {
            if (event.arg0 > 255) return error.InvalidExitStatus;
            try processes.exit(pid, .{ .code = event.arg0 });
            reply.action = contract.action_terminate;
        },
        abi.syscall.wait => {
            const child: ?Pid = if (event.arg0 == 0) null else @fromBackingInt(event.arg0);
            if (event.arg1 > 1 or event.arg2 != 0) return error.InvalidWait;
            const result: policy.WaitResult = if (event.arg1 == 1) blk: {
                const ready = (try processes.pollWait(pid, child)) orelse return error.WouldBlock;
                break :blk .{ .ready = ready };
            } else try processes.wait(pid, child);
            switch (result) {
                .ready => |exit_record| {
                    if (native[try processes.slot(exit_record.pid)].live) @panic("wait before child resource teardown");
                    const reaped = try processes.reap(pid, exit_record.pid);
                    reply.result = reaped.status.code;
                },
                .blocked => {
                    task.pending = .{ .wait = child };
                    wait_blocks += 1;
                    reply.action = contract.action_suspend;
                },
            }
        },
        abi.syscall.yield => {
            try processes.yield(pid);
            reply.result = 0;
            reply.action = contract.action_suspend;
        },
        abi.syscall.sleep => {
            if (task.frames.app and task.profile.app_id == app_policy.observer_id) observer_ticks += 1;
            if (event.arg0 == 0) {
                try processes.yield(pid);
            } else {
                try processes.sleep(pid, event.arg0);
                task.pending = .{ .sleep = idle_ticks };
                sleep_blocks += 1;
            }
            reply.result = 0;
            reply.action = contract.action_suspend;
        },
        abi.syscall.ipc_create => {
            if (!task.profile.mayRequest(.ipc_service)) return error.PermissionDenied;
            const channel = for (&channels) |*candidate| {
                if (candidate.id == 0) break candidate;
            } else return error.ChannelCapacity;
            try budget.reserve(.{ .handles = 1 });
            errdefer budget.release(.{ .handles = 1 }) catch @panic("channel quota rollback");
            const object = try mailboxes.open(pid);
            errdefer {
                mailboxes.close(pid, object) catch @panic("channel rollback close");
                mailboxes.destroy(object) catch @panic("channel rollback destroy");
            }
            const grant: security.handles.Grant = .{ .kind = .ipc, .object_id = object, .rights = abi.send_right | abi.receive_right };
            try task.profile.authorizeGrant(grant, .ipc_service);
            const token = try task.handles.insert(grant);
            channel.* = .{ .id = object, .owner = pid, .references = 1 };
            reply.result = @backingInt(token);
        },
        abi.syscall.ipc_send => {
            const grant = try task.handles.resolve(@fromBackingInt(event.arg0), .ipc, abi.send_right);
            if (event.arg2 > abi.max_payload) return error.MessageTooLarge;
            const length: usize = @intCast(event.arg2);
            var bytes: [abi.max_payload]u8 = @splat(0);
            try copyin(task, event.arg1, bytes[0..length]);
            if (try send(grant.object_id, pid, bytes[0..length])) {
                reply.result = length;
                try notify(grant.object_id, false);
            } else {
                task.pending = .{ .send = .{ .object = grant.object_id, .length = length, .data = bytes } };
                try processes.block(pid, .{ .ipc_send = grant.object_id });
                send_blocks += 1;
                reply.action = contract.action_suspend;
            }
        },
        abi.syscall.ipc_receive => {
            const grant = try task.handles.resolve(@fromBackingInt(event.arg0), .ipc, abi.receive_right);
            if (event.arg2 < @sizeOf(abi.MessageHeader) or event.arg2 > @sizeOf(abi.MessageHeader) + abi.max_payload)
                return error.MessageTooLarge;
            const map = regions(task);
            _ = try user_memory.translateWrite(map.slice(), event.arg1, event.arg2);
            if (try receive(task, grant.object_id, event.arg1, @intCast(event.arg2))) |length| {
                reply.result = length;
                try notify(grant.object_id, true);
            } else {
                task.pending = .{ .receive = .{ .object = grant.object_id, .address = event.arg1, .capacity = @intCast(event.arg2) } };
                try processes.block(pid, .{ .ipc_receive = grant.object_id });
                receive_blocks += 1;
                reply.action = contract.action_suspend;
            }
        },
        abi.syscall.close => {
            if (event.arg0 & (1 << 63) != 0) {
                try task.files.close(task.profile, @fromBackingInt(event.arg0));
                try budget.release(.{ .handles = 1 });
                reply.result = 0;
                return;
            }
            if (event.arg0 & (3 << 62) == pipe.descriptor_tag) {
                try closePipe(task, @fromBackingInt(event.arg0));
                reply.result = 0;
                return;
            }
            const token: security.handles.Token = if (event.arg0 == 1) task.stdout orelse return error.InvalidToken else @fromBackingInt(event.arg0);
            const grant = try resolveAny(&task.handles, token);
            if (grant.kind == .surface or grant.kind == .service) {
                try display.close(displayClient(task), token, grant.kind);
                reply.result = 0;
                return;
            }
            if (grant.kind == .socket) {
                try network_requests.close(&task.handles, &budget, token);
                reply.result = 0;
                return;
            }
            try task.handles.close(token);
            if (task.stdout == token) task.stdout = null;
            try budget.release(.{ .handles = 1 });
            if (grant.kind == .ipc) try dropReference(grant.object_id);
            reply.result = 0;
        },
        abi.syscall.write => {
            if (event.arg2 > 256) return error.InvalidWriteLength;
            var bytes: [256]u8 = undefined;
            const length: usize = @intCast(event.arg2);
            try copyin(task, event.arg1, bytes[0..length]);
            if (event.arg0 == 1) {
                _ = try task.handles.resolve(task.stdout orelse return error.InvalidToken, .file, security.handles.rights.write);
                write_console(bytes[0..length]);
                reports += 1;
                reply.result = length;
            } else if (event.arg0 & (3 << 62) == pipe.descriptor_tag) {
                const grant = try task.pipes.resolve(task.profile.app_id, @fromBackingInt(event.arg0), pipe.write_right);
                try budget.reserve(.{ .ipc_bytes = length });
                errdefer budget.release(.{ .ipc_bytes = length }) catch @panic("pipe write rollback");
                reply.result = try pipes.write(grant, bytes[0..length]);
                pipe_operations += 1;
            } else {
                reply.result = try task.files.write(storage, task.profile, @fromBackingInt(event.arg0), bytes[0..length]);
                file_operations += 1;
            }
        },
        else => reply.result = abi.errno.unknown,
    }
}

fn send(object: u64, pid: Pid, bytes: []const u8) !bool {
    try budget.reserve(.{ .ipc_bytes = bytes.len });
    var committed = false;
    defer if (!committed) budget.release(.{ .ipc_bytes = bytes.len }) catch @panic("IPC charge rollback");
    switch (try mailboxes.send(object, pid, bytes)) {
        .sent => {
            committed = true;
            return true;
        },
        .full => return false,
        .closed => return error.ChannelClosed,
    }
}

fn receive(task: *Native, object: u64, address: u64, capacity_bytes: usize) !?usize {
    const message = switch (try mailboxes.peek(object)) {
        .message => |value| value,
        .empty => return null,
        .closed => return error.ChannelClosed,
    };
    const size = @sizeOf(abi.MessageHeader) + message.length;
    if (size > capacity_bytes) return error.MessageTooLarge;
    var output: [@sizeOf(abi.MessageHeader) + abi.max_payload]u8 = undefined;
    putU64(output[0..8], @backingInt(message.sender));
    putU64(output[8..16], message.length);
    @memcpy(output[16..size], message.data[0..message.length]);
    const map = regions(task);
    const physical = try user_memory.translateWrite(map.slice(), address, size);
    // All copyout permissions/ranges and capacity were checked before dequeue.
    _ = try mailboxes.receive(object);
    try budget.release(.{ .ipc_bytes = message.length });
    const destination: [*]volatile u8 = @ptrFromInt(physical);
    for (output[0..size], 0..) |byte, index| destination[index] = byte;
    return size;
}

fn copyin(task: *const Native, address: u64, output: []u8) !void {
    if (output.len == 0) return;
    const map = regions(task);
    const physical = try user_memory.translateRead(map.slice(), address, output.len);
    const source: [*]const volatile u8 = @ptrFromInt(physical);
    for (output, 0..) |*byte, index| byte.* = source[index];
}

fn putU64(output: []u8, value: u64) void {
    for (output, 0..) |*byte, index| byte.* = @truncate(value >> @intCast(index * 8));
}

fn notify(object: u64, sending: bool) !void {
    for (0..capacity) |slot| {
        const pid = processes.pidAt(slot) orelse continue;
        const reason = (try processes.blockedReason(pid)) orelse continue;
        const matches = switch (reason) {
            .ipc_send => |id| sending and id == object,
            .ipc_receive => |id| !sending and id == object,
            else => false,
        };
        if (matches) try processes.wake(pid, 0);
    }
}

fn finishKernelRequests() !void {
    for (0..capacity) |slot| {
        const pid = processes.pidAt(slot) orelse continue;
        const task = &native[slot];
        if (!task.live) continue;
        switch (task.pending) {
            .display => |request| {
                const mapped = regions(task);
                const result = (if (request.number == abi.syscall.window_state) windowState(task, request.arg0, request.arg1, request.arg2) else if (request.number == abi.syscall.desktop_state) desktopState(task, request.arg0, request.arg1, request.arg2) else display.execute(displayClient(task), request.number, request.arg0, request.arg1, request.arg2, mapped.slice())) catch |err| errorResult(err);
                try complete(pid, task, result);
            },
            .spawn => |request| {
                const profile = if (request.package_id != 0) try app_policy.authorizeLaunch(task.profile, request.package_id) else try task.profile.deriveChild(task.profile.permissions);
                const child = processes.spawn(pid) catch |err| {
                    try complete(pid, task, errorResult(err));
                    continue;
                };
                load(child, request, profile) catch |err| {
                    try processes.abortSpawn(child);
                    try complete(pid, task, errorResult(err));
                    continue;
                };
                try complete(pid, task, @backingInt(child));
            },
            .exec => |request| {
                arch.validateContext(task.context) catch {
                    try failProcess(pid);
                    try cleanupZombies();
                    continue;
                };
                replace(pid, task, request.path, request.argument) catch |err| {
                    try complete(pid, task, errorResult(err));
                };
            },
            .wait => |child| {
                if (try processes.state(pid) != .ready) continue;
                switch (try processes.wait(pid, child)) {
                    .ready => |value| {
                        if (native[try processes.slot(value.pid)].live) @panic("wait completion before cleanup");
                        const result = try processes.reap(pid, value.pid);
                        try complete(pid, task, result.status.code);
                    },
                    .blocked => return error.WaitWakeWithoutZombie,
                }
            },
            .sleep => |idle_at_block| {
                if (try processes.state(pid) == .ready) {
                    if (idle_ticks == idle_at_block) runnable_sleep_wakes += 1;
                    try complete(pid, task, 0);
                }
            },
            .send => |request| {
                if (try processes.state(pid) != .ready) continue;
                const sent = send(request.object, pid, request.data[0..request.length]) catch |err| {
                    try complete(pid, task, errorResult(err));
                    continue;
                };
                if (sent) {
                    try notify(request.object, false);
                    try complete(pid, task, request.length);
                } else {
                    _ = try processes.takeWake(pid);
                    try processes.reblockReady(pid, .{ .ipc_send = request.object });
                }
            },
            .receive => |request| {
                if (try processes.state(pid) != .ready) continue;
                const length = receive(task, request.object, request.address, request.capacity) catch |err| {
                    try complete(pid, task, errorResult(err));
                    continue;
                };
                if (length) |got| {
                    try notify(request.object, true);
                    try complete(pid, task, got);
                } else {
                    _ = try processes.takeWake(pid);
                    try processes.reblockReady(pid, .{ .ipc_receive = request.object });
                }
            },
            .none => {},
        }
    }
}

fn complete(pid: Pid, task: *Native, result: u64) !void {
    arch.validateContext(task.context) catch {
        try failProcess(pid);
        try cleanupZombies();
        return;
    };
    if (try processes.state(pid) == .blocked) try processes.wake(pid, result);
    _ = try processes.takeWake(pid);
    try arch.setContextResult(task.context, result);
    task.pending = .none;
}

fn cleanupZombies() !void {
    for (0..capacity) |slot| {
        const pid = processes.pidAt(slot) orelse continue;
        if (native[slot].live and try processes.state(pid) == .zombie) {
            _ = mailboxes.closeOwner(pid);
            for (channels) |channel| if (channel.id != 0 and channel.owner == pid) {
                try notify(channel.id, true);
                try notify(channel.id, false);
            };
            try unload(&native[slot]);
        }
    }
}

fn unload(task: *Native) !void {
    const worker = task.frames.app and task.profile.app_id == app_policy.worker_id;
    const display_a = task.frames.app and task.profile.app_id == app_policy.surface_one_id;
    if (kernel_options.display_runtime) try display.detach(displayClient(task));
    try arch.destroyContext(task.context);
    try arch.destroy(task.space);
    try closeAuthority(task, null);
    try task.owner.releaseAll();
    try budget.release(.{ .memory_pages = imageCharge(task.frames), .processes = 1 });
    task.stdout = null;
    task.pending = .none;
    task.live = false;
    if (kernel_options.desktop_runtime and task.profile.app_id == app_policy.files_id) {
        desktop_files_exits += 1;
        desktopProcessLog(if (kernel_options.window_runtime) "[kernel] window generation reclaimed" else "[kernel] desktop Files generation reclaimed", task);
    }
    if (kernel_options.window_runtime and task.profile.app_id == app_policy.notes_id) {
        window_notes_exits += 1;
        desktopProcessLog("[kernel] window generation reclaimed", task);
    }
    if (display_a and !installed_ready and !session_teardown) display_client_a_exits += 1;
    if (worker and !installed_ready and !session_teardown) {
        worker_reaped += 1;
        if (memory.allocator().?.stats().free_pages != worker_baseline.? or budget.used.memory_pages != worker_memory_baseline.? or budget.used.handles != worker_handles_baseline.?)
            return error.WorkerTeardownResourceLeak;
        write_console("[kernel] worker generation reclaimed; observer retained\n");
    }
}

fn closePipe(task: *Native, token: pipe.Descriptor) !void {
    const grant = try task.pipes.close(task.profile.app_id, token);
    const discarded = try pipes.release(grant);
    try budget.release(.{ .handles = 1, .ipc_bytes = discarded });
}

fn closeAuthority(task: *Native, retained: ?security.handles.Token) !void {
    if (kernel_options.display_runtime) try display.detach(displayClient(task));
    try budget.release(.{ .handles = task.files.closeAll() });
    for (0..task.pipes.slots.len) |index| if (task.pipes.tokenAt(index)) |token| try closePipe(task, token);
    // Close exact live tokens, including inherited descriptors, before release.
    for (&task.handles.slots, 0..) |*entry, index| {
        const grant = entry.grant orelse continue;
        const token: security.handles.Token = @fromBackingInt((@as(u64, entry.generation) << 32) | (index + 1));
        if (retained == token) continue;
        if (grant.kind == .socket) {
            try network_requests.close(&task.handles, &budget, token);
            continue;
        }
        try task.handles.close(token);
        try budget.release(.{ .handles = 1 });
        if (grant.kind == .ipc) try dropReference(grant.object_id);
    }
}

fn releaseImage(image: *ImageParts) !void {
    try arch.destroyContext(image.context);
    try arch.destroy(image.space);
    try image.owner.releaseAll();
    try budget.release(.{ .memory_pages = imageCharge(image.frames) });
}
fn imageCharge(frames: contract.TaskMemory) u64 {
    return @as(u64, frames.code_pages) + frames.data_pages + frames.stack_pages + frames.heap_pages + @intFromBool(frames.app);
}

/// Occupy every architecture registry slot with independently owned native
/// images, then exercise the real exec transaction. None of these temporary
/// children is dispatched; the original init must still start normally.
fn execCapacityProbe(init: Pid, profile: security.sandbox.Profile) !void {
    var children: [capacity - 1]Pid = undefined;
    for (&children) |*child| {
        child.* = try processes.spawn(init);
        errdefer processes.abortSpawn(child.*) catch {};
        try load(child.*, .{ .path = try catalogPath(abi.image.service), .image_id = abi.image.service }, profile);
    }
    const task = &native[try processes.slot(init)];
    const old_context = task.context;
    const old_space = task.space;
    const old_stdout = task.stdout;
    const before = memory.allocator().?.stats();
    const charges = budget.used;
    replace(init, task, try pathFrom("/bundle/exec.elf"), 0) catch |err| {
        if (err != error.AddressSpaceCapacity and err != error.ContextCapacityOrState)
            return error.UnexpectedExecCapacityFailure;
        const after = memory.allocator().?.stats();
        if (after.allocated_pages != before.allocated_pages or after.free_pages != before.free_pages or
            budget.used.memory_pages != charges.memory_pages or budget.used.handles != charges.handles or
            budget.used.processes != charges.processes or budget.used.ipc_bytes != charges.ipc_bytes or
            task.context != old_context or task.space.root != old_space.root or task.space.generation != old_space.generation or
            task.stdout != old_stdout or try processes.state(init) != .ready or exec_replacements != 0)
            return error.ExecCapacityRollbackFailed;
        try arch.validateContext(task.context);
        for (children) |child| try processes.exit(child, .{ .code = 0 });
        try cleanupZombies();
        for (children) |child| _ = try processes.reap(init, child);
        return;
    };
    return error.ExecUnexpectedlySucceededAtCapacity;
}

fn replace(pid: Pid, task: *Native, path: Path, argument: u64) !void {
    const bytes = try storage.execPath(task.profile, path.bytes[0..path.length]);
    // Stage the replacement stdout in the existing generational table. A full
    // or retired table fails before old authority is closed; stale tokens are
    // never made valid by resetting a table at exec.
    try task.profile.authorizeGrant(stdoutGrant(), .{ .inherited_stream = security.handles.rights.write });
    try budget.reserve(.{ .handles = 1 });
    errdefer budget.release(.{ .handles = 1 }) catch @panic("exec stdout charge rollback");
    const stdout = try task.handles.insert(stdoutGrant());
    errdefer task.handles.close(stdout) catch @panic("exec stdout rollback");
    const package: ?app_policy.Package = if (task.frames.app) try app_policy.lookup(task.profile.app_id) else null;
    var image = try buildImage(pid, bytes, 0, argument, extendedProfile(task.profile, path), package);
    errdefer releaseImage(&image) catch @panic("exec image rollback");
    var old: ImageParts = .{ .owner = task.owner, .frames = task.frames, .space = task.space, .context = task.context };
    // Everything fallible for an untrusted request has completed. Remaining
    // failures indicate a kernel ledger invariant, never an exec errno.
    closeAuthority(task, stdout) catch @panic("exec descriptor teardown");
    var remaining: usize = 0;
    for (task.handles.slots) |entry| remaining += @intFromBool(entry.grant != null);
    if (task.files.count() != 0 or task.pipes.count() != 0 or remaining != 1)
        @panic("exec retained old descriptor authority");
    task.owner = image.owner;
    task.frames = image.frames;
    task.space = image.space;
    task.context = image.context;
    task.stdout = stdout;
    task.pending = .none;
    task.startup_read = false;
    processes.wake(pid, 0) catch @panic("exec process wake");
    _ = processes.takeWake(pid) catch @panic("exec wake consumption");
    releaseImage(&old) catch @panic("exec old image teardown");
    exec_replacements += 1;
}

fn resolveAny(handles: *const Grants, token: security.handles.Token) !security.handles.Grant {
    for ([_]security.handles.ObjectKind{ .file, .ipc, .socket, .surface, .service }) |kind| {
        if (handles.resolve(token, kind, 0)) |grant| return grant else |err| if (err != error.WrongObjectKind) return err;
    }
    return error.WrongObjectKind;
}

fn displayClient(task: *Native) display_requests.Client {
    return .{ .identity = .{ .pid = @backingInt(task.pid), .app_id = task.profile.app_id }, .profile = task.profile, .space = task.space, .handles = &task.handles, .shared = &task.shared };
}

fn liveDesktopPid(app: u64) u64 {
    for (native) |task| if (task.live and task.startup_read and task.profile.app_id == app) return @backingInt(task.pid);
    return 0;
}

fn desktopProcessLog(prefix: []const u8, task: *const Native) void {
    var buffer: [160]u8 = undefined;
    const line = @import("std").fmt.bufPrint(&buffer, "{s} pid={d} app={d}\n", .{ prefix, @backingInt(task.pid), task.profile.app_id }) catch @panic("desktop lifecycle log");
    write_console(line);
}

/// Privileged service diagnostics authenticate resource identities here. The
/// service supplies its window-state label; policy and geometry stay userspace.
fn desktopState(task: *Native, state: u64, arg1: u64, arg2: u64) !u64 {
    if (!kernel_options.desktop_runtime or kernel_options.window_runtime or task.profile.app_id != app_policy.display_server_id or !task.profile.mayRequest(.display_service)) return error.PermissionDenied;
    if (arg1 != 0 or arg2 != 0 or state == 0 or state > 7) return error.InvalidDesktopState;
    const server_pid = liveDesktopPid(app_policy.display_server_id);
    const shell_pid = liveDesktopPid(app_policy.shell_id);
    const files_pid = liveDesktopPid(app_policy.files_id);
    const surfaces_count = display.registry.liveCount();
    if (server_pid != @backingInt(task.pid) or shell_pid == 0 or display_server_starts != 1 or desktop_shell_starts != 1) return error.DisplaySupervisionIncomplete;
    if (state == 3) {
        if (files_pid != 0 or surfaces_count != 4 or desktop_files_exits == 0) return error.WouldBlock;
    } else if (files_pid == 0 or surfaces_count != 5 or display.metrics.frames_files == 0 or display.metrics.frames_shell == 0) return error.WouldBlock;
    if (state == 4 and desktop_files_starts < 2) return error.DisplaySupervisionIncomplete;
    const label = switch (state) {
        1 => "ready",
        2 => "minimized",
        3 => "closed",
        4 => "relaunched",
        5 => "maximized",
        6 => "fullscreen",
        7 => "restored",
        else => unreachable,
    };
    var buffer: [224]u8 = undefined;
    const line = try @import("std").fmt.bufPrint(&buffer, "[kernel] service desktop state state={s} server_pid={d} shell_pid={d} files_pid={d} files_app=2 surface_count={d}\n", .{ label, server_pid, shell_pid, files_pid, surfaces_count });
    write_console(line);
    return 0;
}

fn windowState(task: *Native, state: u64, app: u64, aux: u64) !u64 {
    if (!kernel_options.window_runtime or task.profile.app_id != app_policy.display_server_id or !task.profile.mayRequest(.display_service)) return error.PermissionDenied;
    if (state == 0 or state > 11 or (app != 0 and app != app_policy.files_id and app != app_policy.notes_id)) return error.InvalidDesktopState;
    const server_pid = liveDesktopPid(app_policy.display_server_id);
    const shell_pid = liveDesktopPid(app_policy.shell_id);
    const files_pid = liveDesktopPid(app_policy.files_id);
    const notes_pid = liveDesktopPid(app_policy.notes_id);
    const target_pid = if (app == app_policy.files_id) files_pid else if (app == app_policy.notes_id) notes_pid else 0;
    if (server_pid != @backingInt(task.pid) or shell_pid == 0 or display_server_starts != 1 or desktop_shell_starts != 1) return error.DisplaySupervisionIncomplete;
    if (state == 9) {
        if (aux >= 4) return error.InvalidDesktopState;
    } else if (state == 10) {
        if (aux > 1) return error.InvalidDesktopState;
    } else if (state == 11) {
        if (aux != 0 and aux != files_pid and aux != notes_pid) return error.InvalidDesktopState;
    } else if (aux != 0) return error.InvalidDesktopState;
    const clients: u64 = @as(u64, @intFromBool(files_pid != 0)) + @as(u64, @intFromBool(notes_pid != 0));
    const surface_count = display.registry.liveCount();
    const expected_surfaces = try @import("window_message_policy.zig").sceneSurfaceCount(try display.producerCount(app_policy.files_id), try display.producerCount(app_policy.notes_id));
    if (surface_count != expected_surfaces or budget.used.processes != 3 + clients or display.metrics.frames_shell == 0) return error.WouldBlock;
    if (state == 3) {
        if (app == 0 or target_pid != 0 or (if (app == app_policy.files_id) desktop_files_exits else window_notes_exits) == 0) return error.WouldBlock;
    } else if (app != 0 and target_pid == 0) return error.WouldBlock;
    if (state == 1 and (files_pid == 0 or notes_pid == 0 or display.metrics.frames_files == 0 or display.metrics.frames_notes == 0)) return error.WouldBlock;
    if (state == 4 and (app == 0 or (if (app == app_policy.files_id) desktop_files_starts else window_notes_starts) < 2)) return error.DisplaySupervisionIncomplete;
    const labels = [_][]const u8{ "ready", "minimized", "closed", "relaunched", "maximized", "fullscreen", "restored", "resized", "workspace", "tiled", "focused" };
    var buffer: [320]u8 = undefined;
    const line = try @import("std").fmt.bufPrint(&buffer, "[kernel] window desktop state state={s} app={d} aux={d} server_pid={d} shell_pid={d} files_pid={d} notes_pid={d} surface_count={d} process_count={d}\n", .{ labels[state - 1], app, aux, server_pid, shell_pid, files_pid, notes_pid, surface_count, budget.used.processes });
    write_console(line);
    return 0;
}

fn channelFor(id: u64) ?*Channel {
    for (&channels) |*channel| if (channel.id == id and id != 0) return channel;
    return null;
}

fn dropReference(id: u64) !void {
    const channel = channelFor(id) orelse return error.UnknownChannel;
    if (channel.references == 0) return error.ChannelReferenceUnderflow;
    channel.references -= 1;
    if (channel.references != 0) return;
    try mailboxes.close(channel.owner, id);
    // No handle or runnable client can access this last-reference object.
    while (true) switch (try mailboxes.receive(id)) {
        .message => |message| try budget.release(.{ .ipc_bytes = message.length }),
        .empty, .closed => break,
    };
    try notify(id, true);
    try notify(id, false);
    try mailboxes.destroy(id);
    channel.* = .{};
}

pub fn errorResult(err: anyerror) u64 {
    return switch (err) {
        error.InvalidUserRange, error.InvalidMapping => abi.errno.fault,
        error.PermissionDenied => abi.errno.permission,
        error.InvalidToken, error.StaleToken, error.WrongObjectKind, error.InvalidDescriptor, error.StaleDescriptor, error.StaleNode, error.InvalidEndpointIdentity, error.StaleEndpoint, error.InvalidSurface, error.StaleSurface, error.InvalidConnection, error.ConnectionClosed, error.InvalidService, error.ServiceClosed, error.StaleConnection, error.StaleService, error.WrongServiceObjectKind => abi.errno.bad_descriptor,
        error.AlreadyExists => abi.errno.exists,
        error.DirectoryNotEmpty => abi.errno.not_empty,
        error.ReadOnly => abi.errno.read_only,
        error.FileTooLarge => abi.errno.file_too_large,
        error.RemountRequired, error.DeviceTimeout, error.DeviceFailed, error.IOError, error.NullifyVerificationFailed => abi.errno.io,
        error.WouldBlock => abi.errno.again,
        error.NetworkUnavailable => abi.errno.network_unavailable,
        error.RadioUnavailable, error.RadioDisabled => abi.errno.network_unavailable,
        error.UnsupportedSecurity, error.UnsupportedOperation, error.NotSupported => abi.errno.not_supported,
        error.StaleScan => abi.errno.stale,
        error.Busy, error.ApplicationAlreadyRunning, error.SurfaceBusy, error.SurfaceMappingActive => abi.errno.busy,
        error.NotSeekable => abi.errno.not_seekable,
        error.NotFound, error.ApplicationNotInstalled, error.ServiceUnavailable => abi.errno.no_entry,
        error.NoChildren, error.NotChild => abi.errno.no_child,
        error.InvalidPid, error.StalePid => abi.errno.no_process,
        error.ChannelClosed, error.UnknownChannel, error.StaleObjectIdentity, error.InvalidObjectIdentity => abi.errno.broken_pipe,
        error.MessageTooLarge, error.PayloadTooLarge, error.BufferTooSmall => abi.errno.message_size,
        error.OutOfMemory, error.ResourceLimitExceeded, error.ProcessCapacity, error.ChannelCapacity, error.MailboxCapacity, error.TableFull, error.PipeCapacity, error.FileTableFull, error.NodeCapacity, error.PageTableCapacity, error.ContextCapacityOrState, error.ContextCapacity, error.AddressSpaceCapacity, error.EndpointCapacity, error.PortExhausted, error.SurfaceCapacity, error.ConnectionCapacity, error.ServiceCapacity => abi.errno.no_memory,
        error.InitHasChildren => abi.errno.busy,
        else => abi.errno.invalid,
    };
}
