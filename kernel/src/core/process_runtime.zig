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
const capacity = 8;
comptime {
    if (elf.code_address != abi.code or elf.data_address != abi.data or elf.page_size != abi.page_size or
        contract.user_code != abi.code or contract.user_stack_top != abi.stack_top)
        @compileError("ELF, syscall ABI and architecture mapping windows must agree");
}
const Pid = policy.Pid;
const FrameOwner = memory.ownership.Owner(3);
const Grants = security.handles.GenerationTable(8, 0x3fff_ffff);
const Files = vfs.Files(8);
const PipeDescriptors = pipe.Descriptors(8);
const Path = struct { bytes: [vfs.max_path]u8 = undefined, length: usize = 0 };
const Spawn = struct { path: Path, image_id: u64 = 0, argument: u64 = 0, grant: ?security.handles.Grant = null, pipe_grant: ?pipe.Grant = null };
const Pending = union(enum) {
    none,
    spawn: Spawn,
    exec: struct { path: Path, argument: u64 },
    wait: ?Pid,
    sleep: u64,
    send: struct { object: u64, length: usize, data: [abi.max_payload]u8 },
    receive: struct { object: u64, address: u64, capacity: usize },
};
const Native = struct {
    live: bool = false,
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
var budget = security.quotas.Budget.init(.{ .memory_pages = 27, .processes = 8, .handles = 64, .ipc_bytes = 1024 });
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

pub fn isActive() bool {
    return active;
}

pub fn run(comptime console: type, info: *const protocol.BootInfo) !void {
    if (has_run) return error.ProcessRuntimeAlreadyInitialized;
    has_run = true;
    write_console = &struct {
        fn write(bytes: []const u8) void {
            console.write(bytes);
        }
    }.write;
    try disk_runtime.initialize(console, info);
    try network.initialize(info);
    try wifi.initialize(info, 0);
    for (wifi.inventory().candidates[0..wifi.inventory().count]) |candidate| {
        console.write("[kernel] Wi-Fi PCI adapter identified vendor/product/bus=");
        console.writeHex(candidate.device.vendor);
        console.write(" ");
        console.writeHex(candidate.device.product);
        console.write(" ");
        console.writeHex(candidate.device.bdf.bus);
        console.write("; operational driver unavailable\n");
    }
    if (kernel_options.wifi_acceptance) console.write("[kernel] Wi-Fi simulated test radio active\n");
    if (kernel_options.wifi_absence_probe) console.write("[kernel] Wi-Fi physical driver unavailable\n");
    if (network.isAvailable()) console.write("[kernel] network device ready\n");
    const pages = memory.allocator() orelse return error.MemoryNotInitialized;
    const baseline = pages.stats();
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

/// Stages an entire image while the old image stays intact. This may fail at
/// full architecture capacity; no reclaim-old-first fallback weakens exec.
fn buildImage(pid: Pid, bytes: []const u8, inherited_token: u64, argument: u64, extended: bool) !ImageParts {
    // The trusted launcher chooses the layout. ELF fields cannot enlarge it.
    const image = if (extended) try elf.inspectDesktop(bytes, builtin.cpu.arch) else try elf.inspect(bytes, builtin.cpu.arch);
    var code_pages: u16 = 1;
    var data_pages: u16 = 1;
    if (extended) {
        for (image.segments[0..image.count]) |segment| {
            if (segment.flags == 5) code_pages = @intCast((segment.address + segment.memory_size - contract.desktop_code + 4095) / 4096) else data_pages = @intCast((segment.address + segment.memory_size - contract.desktop_data + 4095) / 4096);
        }
        if (code_pages > 4 or data_pages > 1) return error.UnsupportedAddressRange;
    }
    const stack_pages: u16 = if (extended) 4 else 1;
    const charge = @as(u64, code_pages) + data_pages + stack_pages;
    try budget.reserve(.{ .memory_pages = charge });
    errdefer budget.release(.{ .memory_pages = charge }) catch @panic("image quota rollback");
    var owner = try FrameOwner.init(memory.allocator().?, try memory.newOwnerId());
    errdefer owner.releaseAll() catch @panic("native frame rollback");
    const frames: contract.TaskMemory = .{ .code = try frameRange(&owner, code_pages), .data = try frameRange(&owner, data_pages), .stack = try frameRange(&owner, stack_pages), .code_pages = code_pages, .data_pages = data_pages, .stack_pages = stack_pages, .desktop = extended };
    for (image.segments[0..image.count]) |segment| {
        const code_segment = segment.flags == 5;
        const window = if (code_segment) frames.codeVirtual() else frames.dataVirtual();
        const physical = (if (code_segment) frames.code else frames.data) + (segment.address - window);
        const destination: [*]volatile u8 = @ptrFromInt(physical);
        for (bytes[@intCast(segment.offset)..@intCast(segment.offset + segment.file_size)], 0..) |byte, index| destination[index] = byte;
    }
    const space = try arch.create(frames);
    errdefer arch.destroy(space) catch @panic("native space rollback");
    const parent = try processes.parent(pid);
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
    const image = try buildImage(pid, bytes, inherited_token, argument, extendedProfile(profile, request.path));
    if (request.grant) |grant| channelFor(grant.object_id).?.references += 1;
    // Moving a ledger transfers its lifetime; the local owner is no longer live.
    native[slot] = .{ .live = true, .owner = image.owner, .frames = image.frames, .space = image.space, .context = image.context, .profile = profile, .handles = handles, .stdout = stdout, .files = files, .pipes = pipe_descriptors };
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

fn regions(task: *const Native) [3]user_memory.Region {
    var result: [3]user_memory.Region = undefined;
    for (task.frames.mappings(), 0..) |mapping, index| result[index] = .{ .virtual = mapping.virtual, .physical = mapping.physical, .length = @as(u64, mapping.pages) * abi.page_size, .writable = mapping.writable };
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
    const status: policy.ExitStatus = .{ .code = abi.fault_exit_status, .faulted = true };
    if (processes.init_pid == pid) try processes.failInit(status) else try processes.exit(pid, status);
}

fn syscall(pid: Pid, task: *Native, event: *const contract.Event, reply: *contract.Reply) !void {
    switch (event.number) {
        abi.syscall.getpid => reply.result = @backingInt(pid),
        abi.syscall.clock_ticks => reply.result = processes.ticks,
        abi.syscall.wifi_status, abi.syscall.wifi_scan_start, abi.syscall.wifi_scan_read, abi.syscall.wifi_join, abi.syscall.wifi_disconnect, abi.syscall.wifi_enable => {
            reply.result = try wifi_requests.serve(task.profile, &regions(task), event.number, event.arg0, event.arg1, event.arg2, processes.ticks);
        },
        abi.syscall.udp_open, abi.syscall.udp_send, abi.syscall.udp_receive => {
            reply.result = try network_requests.serve(task.profile, &task.handles, &budget, &regions(task), event.number, event.arg0, event.arg1, event.arg2);
        },
        abi.syscall.list, abi.syscall.mkdir, abi.syscall.copy, abi.syscall.rename, abi.syscall.unlink, abi.syscall.nullify => {
            reply.result = try @import("directory_syscalls.zig").serve(task.profile, &regions(task), event.number, event.arg0, event.arg1, event.arg2);
            file_operations += 1;
        },
        abi.syscall.spawn => {
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
            const physical = if (length != 0) try user_memory.translateWrite(&regions(task), event.arg1, length) else 0;
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
            const physical = try user_memory.translateWrite(&regions(task), event.arg0, 16);
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
            switch (try processes.wait(pid, child)) {
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
            _ = try user_memory.translateWrite(&map, event.arg1, event.arg2);
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
    const physical = try user_memory.translateWrite(&map, address, size);
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
    const physical = try user_memory.translateRead(&map, address, output.len);
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
            .spawn => |request| {
                const profile = try task.profile.deriveChild(task.profile.permissions);
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
    try arch.destroyContext(task.context);
    try arch.destroy(task.space);
    try closeAuthority(task, null);
    try task.owner.releaseAll();
    try budget.release(.{ .memory_pages = imageCharge(task.frames), .processes = 1 });
    task.stdout = null;
    task.pending = .none;
    task.live = false;
}

fn closePipe(task: *Native, token: pipe.Descriptor) !void {
    const grant = try task.pipes.close(task.profile.app_id, token);
    const discarded = try pipes.release(grant);
    try budget.release(.{ .handles = 1, .ipc_bytes = discarded });
}

fn closeAuthority(task: *Native, retained: ?security.handles.Token) !void {
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
    return @as(u64, frames.code_pages) + frames.data_pages + frames.stack_pages;
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
    var image = try buildImage(pid, bytes, 0, argument, extendedProfile(task.profile, path));
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
    processes.wake(pid, 0) catch @panic("exec process wake");
    _ = processes.takeWake(pid) catch @panic("exec wake consumption");
    releaseImage(&old) catch @panic("exec old image teardown");
    exec_replacements += 1;
}

fn resolveAny(handles: *const Grants, token: security.handles.Token) !security.handles.Grant {
    return handles.resolve(token, .ipc, 0) catch |err| {
        if (err != error.WrongObjectKind) return err;
        return handles.resolve(token, .file, 0) catch |file_error| {
            if (file_error != error.WrongObjectKind) return file_error;
            return handles.resolve(token, .socket, 0);
        };
    };
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
        error.InvalidToken, error.StaleToken, error.WrongObjectKind, error.InvalidDescriptor, error.StaleDescriptor, error.StaleNode, error.InvalidEndpointIdentity, error.StaleEndpoint => abi.errno.bad_descriptor,
        error.AlreadyExists => abi.errno.exists,
        error.DirectoryNotEmpty => abi.errno.not_empty,
        error.ReadOnly => abi.errno.read_only,
        error.FileTooLarge => abi.errno.file_too_large,
        error.RemountRequired, error.DeviceTimeout, error.DeviceFailed, error.IOError, error.NullifyVerificationFailed => abi.errno.io,
        error.WouldBlock => abi.errno.again,
        error.NetworkUnavailable => abi.errno.network_unavailable,
        error.RadioUnavailable, error.RadioDisabled => abi.errno.network_unavailable,
        error.UnsupportedSecurity, error.UnsupportedOperation => abi.errno.not_supported,
        error.StaleScan => abi.errno.stale,
        error.Busy => abi.errno.busy,
        error.NotSeekable => abi.errno.not_seekable,
        error.NotFound => abi.errno.no_entry,
        error.NoChildren, error.NotChild => abi.errno.no_child,
        error.InvalidPid, error.StalePid => abi.errno.no_process,
        error.ChannelClosed, error.UnknownChannel, error.StaleObjectIdentity, error.InvalidObjectIdentity => abi.errno.broken_pipe,
        error.MessageTooLarge, error.PayloadTooLarge, error.BufferTooSmall => abi.errno.message_size,
        error.OutOfMemory, error.ResourceLimitExceeded, error.ProcessCapacity, error.ChannelCapacity, error.MailboxCapacity, error.TableFull, error.PipeCapacity, error.FileTableFull, error.NodeCapacity, error.PageTableCapacity, error.ContextCapacityOrState, error.ContextCapacity, error.AddressSpaceCapacity, error.EndpointCapacity, error.PortExhausted => abi.errno.no_memory,
        error.InitHasChildren => abi.errno.busy,
        else => abi.errno.invalid,
    };
}
