//! Protected boot-time tasks and a timer-preempted saved-context workload.
//! Owns/reclaims fixture resources before starting native ELF processes.
const protocol = @import("boot_protocol");
const memory = @import("memory_init");
const arch = @import("isolation_arch");
const contract = @import("isolation_contract");
const user_memory = @import("user_memory.zig");
const security = @import("security");
const scheduler = @import("scheduler.zig");
const process_runtime = @import("process_runtime.zig");
const desktop_runtime = @import("desktop_runtime.zig");
pub const runDesktop = desktop_runtime.run;
const FrameOwner = memory.ownership.Owner(3);
const task_charge: security.quotas.Resources = .{ .memory_pages = 3, .handles = 1, .processes = 1 };

extern var __kernel_image_start: u8;
extern var __text_start: u8;
extern var __text_end: u8;
extern var __rodata_start: u8;
extern var __rodata_end: u8;
extern var __data_start: u8;
extern var __data_end: u8;
extern var __kernel_allocated_end: u8;
extern var __stack_bottom: u8;
extern var __stack_top: u8;
extern var __stack_guard: u8;

const Observation = struct {
    syscalls: u64 = 0,
    reports: u64 = 0,
    invalid_pointers: u64 = 0,
    unknown_calls: u64 = 0,
    denied_writes: u64 = 0,
    exited: bool = false,
    exit_status: u64 = 99,
    fault: ?contract.Event = null,
    invalid: bool = false,
    timer_ticks: u64 = 0,
};
const Task = struct {
    owner: FrameOwner,
    live: bool = true,
    memory: contract.TaskMemory,
    space: contract.AddressSpace,
    sentinel: u64,
    profile: security.sandbox.Profile,
    budget: security.quotas.Budget,
    handles: security.handles.Table(1),
    read_handle: security.handles.Token,
    observation: Observation = .{},

    fn regions(self: *const Task) [3]user_memory.Region {
        return .{
            .{ .virtual = contract.user_code, .physical = self.memory.code, .length = contract.page_size },
            .{ .virtual = contract.user_data, .physical = self.memory.data, .length = contract.page_size },
            .{ .virtual = contract.user_stack, .physical = self.memory.stack, .length = contract.page_size },
        };
    }
};

// Kernel state is never selected by a user-supplied task ID or handle token.
var tasks: [2]Task = undefined;
var current: ?*Task = null;
var has_run = false;
var preemptive = false;

pub fn run(comptime console: type, info: *const protocol.BootInfo) !void {
    if (has_run or current != null) return error.IsolationAlreadyInitialized;
    has_run = true;
    const layout = kernelLayout();
    try arch.prepare(info, layout);
    // Establish permanent timer mappings before the ownership baseline. User
    // interrupts remain masked until a saved context is explicitly resumed.
    try arch.preparePreemption(info);
    const baseline = memory.allocator().?.stats();
    console.write("[kernel] protected mappings ready\n");
    try verifyCreationRollback();
    tasks[0] = try createTask(1, 0x1122334455667788);
    errdefer destroyTask(&tasks[0]) catch @panic("task rollback invariant");
    tasks[1] = try createTask(2, 0x8877665544332211);
    errdefer destroyTask(&tasks[1]) catch @panic("task rollback invariant");
    if (tasks[0].space.root == tasks[1].space.root or
        tasks[0].memory.data == tasks[1].memory.data) return error.SharedTaskAddressSpace;

    try runNormal(&tasks[0], layout.kernel_start);
    try runNormal(&tasks[1], layout.kernel_start);
    console.write("[kernel] user mode verified\n[kernel] syscall checks verified\n");
    for ([_]struct { probe: contract.Probe, target: u64 }{
        .{ .probe = .kernel_read, .target = layout.kernel_start },
        .{ .probe = .peer_read, .target = tasks[1].memory.data },
        .{ .probe = .code_write, .target = contract.user_code },
        .{ .probe = .stack_execute, .target = contract.user_stack },
        .{ .probe = .guard_read, .target = contract.user_guard },
    }) |check| {
        invoke(&tasks[0], check.probe, check.target);
        const observation = tasks[0].observation;
        const fault = observation.fault orelse return error.UserFaultNotDelivered;
        if (observation.invalid or observation.exited or observation.syscalls != 0 or
            fault.fault_address != check.target) return error.UnexpectedUserFault;
        try arch.validateFault(check.probe, fault);
        console.write("[kernel] user fault contained mode=");
        console.writeHex(@backingInt(check.probe));
        console.write(" address=");
        console.writeHex(fault.fault_address);
        console.write(" syndrome=");
        console.writeHex(fault.syndrome);
        console.write("\n");
        // The kernel returns from the failed task, selects a different root and
        // handle table, and verifies the second task's private data via syscall.
        try runNormal(&tasks[1], layout.kernel_start);
    }
    console.write("[kernel] isolation probes verified\n[kernel] second task survived\n");
    try runPreemption(console);
    try destroyTask(&tasks[0]);
    try destroyTask(&tasks[1]);
    try requireStats(baseline);
    console.write("[kernel] page-table rollback verified\n[kernel] task teardown verified\n");
    try verifyReuse(layout.kernel_start, baseline);
    console.write("[kernel] resource reuse verified\n");
    try process_runtime.run(console, info);
}

fn runPreemption(comptime console: type) !void {
    console.write("[kernel] timer ready\n");
    var queue: scheduler.Scheduler(2) = .{};
    var contexts: [2]contract.ContextHandle = undefined;
    var context_count: usize = 0;
    defer for (contexts[0..context_count]) |handle| {
        arch.destroyContext(handle) catch @panic("context cleanup invariant");
    };
    var counters: [2]u64 = @splat(0);
    for (&tasks, 0..) |*task, slot| {
        task.observation = .{};
        const counter: *volatile u64 = @ptrFromInt(task.memory.data + 8);
        counter.* = 0;
        const entries: *volatile u64 = @ptrFromInt(task.memory.data + 16);
        entries.* = 0;
        contexts[slot] = try arch.createContext(task.space, .{
            .entry = contract.user_code,
            .user_sp = contract.user_stack_top,
            .arg0 = @backingInt(contract.Probe.spin),
            .arg1 = task.sentinel,
            .arg2 = 0,
        });
        context_count += 1;
        // Resume a replacement generation in the real timer workload, rather
        // than testing reused handles only through the validation API.
        const discarded = contexts[slot];
        try arch.destroyContext(discarded);
        context_count -= 1;
        contexts[slot] = try arch.createContext(task.space, .{
            .entry = contract.user_code,
            .user_sp = contract.user_stack_top,
            .arg0 = @backingInt(contract.Probe.spin),
            .arg1 = task.sentinel,
            .arg2 = 0,
        });
        context_count += 1;
        if (contexts[slot] == discarded) return error.ContextGenerationReused;
        if (arch.validateContext(discarded)) |_| return error.StaleContextAccepted else |err| {
            if (err != error.StaleContextHandle and err != error.InvalidContextHandle) return err;
        }
        try queue.add(slot);
    }
    if (contexts[0] == contexts[1]) return error.SharedNativeContext;
    preemptive = true;
    defer {
        current = null;
        preemptive = false;
    }
    // A short, bounded acceptance workload: both apps spin without yielding.
    // Hardware timer entry returns control to this round-robin policy, and each
    // subsequent entry resumes the saved native context rather than its entry.
    while (try queue.dispatch()) |slot| {
        const task = &tasks[slot];
        const before = task.observation.timer_ticks;
        current = task;
        arch.resumeContext(contexts[slot]);
        current = null;
        const got = task.observation;
        if (got.invalid or got.exited or got.fault != null or got.syscalls != 0 or
            got.timer_ticks != before + 1) return error.UserPreemptionFailed;
        const counter: *const volatile u64 = @ptrFromInt(task.memory.data + 8);
        const sentinel: *const volatile u64 = @ptrFromInt(task.memory.data);
        const entries: *const volatile u64 = @ptrFromInt(task.memory.data + 16);
        if (counter.* <= counters[slot] or sentinel.* != task.sentinel or entries.* != 1)
            return error.UserContextDidNotProgress;
        counters[slot] = counter.*;
        try queue.preempt(slot);
        console.write("[kernel] timer preempted task=");
        console.writeHex(slot);
        console.write(" quantum=");
        console.writeHex(queue.quanta[slot]);
        console.write(" progress=");
        console.writeHex(counters[slot]);
        console.write("\n");
        if (queue.quanta[slot] == 3) try queue.stopReady(slot, .budget);
    }
    if (queue.ticks != 6 or queue.quanta[0] != 3 or queue.quanta[1] != 3 or
        tasks[0].observation.timer_ticks != 3 or tasks[1].observation.timer_ticks != 3)
        return error.UnfairUserScheduling;
    console.write("[kernel] no-yield tasks preempted\n[kernel] context resume verified\n[kernel] preemptive scheduling verified\n");
}

fn createTask(app_id: u64, sentinel: u64) !Task {
    return createTaskWithLimit(app_id, sentinel, null);
}

fn createTaskWithLimit(app_id: u64, sentinel: u64, table_limit: ?usize) !Task {
    var budget = security.quotas.Budget.init(task_charge);
    try budget.reserve(task_charge);
    errdefer budget.release(task_charge) catch @panic("quota rollback invariant");
    var owner = try FrameOwner.init(memory.allocator() orelse return error.MemoryNotInitialized, try memory.newOwnerId());
    errdefer owner.releaseAll() catch @panic("frame rollback invariant");
    const frames: contract.TaskMemory = .{
        .code = try allocateTaskFrame(&owner),
        .data = try allocateTaskFrame(&owner),
        .stack = try allocateTaskFrame(&owner),
    };
    const program = arch.programBytes();
    if (program.len == 0 or program.len > contract.page_size) return error.InvalidUserFixture;
    const code: [*]volatile u8 = @ptrFromInt(frames.code);
    for (program, 0..) |byte, index| code[index] = byte;
    const data: *volatile u64 = @ptrFromInt(frames.data);
    data.* = sentinel;
    const profile = try security.sandbox.Profile.init(app_id, 0, 0);
    const grant: security.handles.Grant = .{ .kind = .file, .object_id = app_id, .rights = security.handles.rights.read };
    // A test object with bundle provenance. There is no filesystem operation
    // behind this handle yet; the denied-write syscall exercises authority.
    try profile.authorizeGrant(grant, .{ .app_bundle = app_id });
    var handles: security.handles.Table(1) = .{};
    const read_handle = try handles.insert(grant);
    errdefer handles.close(read_handle) catch @panic("handle rollback invariant");
    const space = if (table_limit) |limit| try arch.createWithTableLimit(frames, limit) else try arch.create(frames);
    return .{ .owner = owner, .memory = frames, .space = space, .sentinel = sentinel, .profile = profile, .budget = budget, .handles = handles, .read_handle = read_handle };
}

fn allocateTaskFrame(owner: *FrameOwner) !u64 {
    const ticket = try owner.allocate(1, 1);
    const range = try owner.resolve(ticket);
    memory.clearRange(range);
    return range.base;
}

fn destroyTask(task: *Task) !void {
    if (!task.live) return;
    if (current == task) return error.ActiveTask;
    // The architecture refuses spaces with active or still-saved contexts.
    // It removes mappings and flushes translations before any RAM is reused.
    try arch.destroy(task.space);
    try task.handles.close(task.read_handle);
    try task.owner.releaseAll();
    try task.budget.release(task_charge);
    if (task.budget.used.memory_pages != 0 or task.budget.used.handles != 0 or
        task.budget.used.processes != 0 or task.budget.used.ipc_bytes != 0) return error.TaskQuotaLeak;
    task.live = false;
}

fn verifyCreationRollback() !void {
    const before = memory.allocator().?.stats();
    // Failure before allocation and after each partial page-table prefix.
    for (0..4) |limit| {
        if (createTaskWithLimit(1, 1, limit)) |value| {
            var unexpected = value;
            try destroyTask(&unexpected);
            return error.TableLimitNotEnforced;
        } else |err| if (err != error.PageTableCapacity) return err;
        try requireStats(before);
    }
    // A policy failure after all three payload allocations must also unwind.
    if (createTask(0, 1)) |value| {
        var unexpected = value;
        try destroyTask(&unexpected);
        return error.InvalidAppAccepted;
    } else |err| if (err != error.InvalidAppIdentity) return err;
    try requireStats(before);
}

fn verifyReuse(kernel_address: u64, baseline: @TypeOf(memory.allocator().?.stats())) !void {
    // More cycles than any current space/context registry capacity. Keep a peer
    // running across deletion/replacement to detect shared-table corruption.
    for (0..12) |iteration| {
        tasks[0] = try createTask(1, 0x1122334455667788 + iteration);
        errdefer destroyTask(&tasks[0]) catch @panic("reuse rollback invariant");
        tasks[1] = try createTask(2, 0x8877665544332211 + iteration);
        errdefer destroyTask(&tasks[1]) catch @panic("reuse rollback invariant");
        var live_context: ?contract.ContextHandle = null;
        defer if (live_context) |handle| {
            arch.destroyContext(handle) catch @panic("reuse context cleanup invariant");
        };
        const invocation: contract.Invocation = .{ .entry = contract.user_code, .user_sp = contract.user_stack_top, .arg0 = @backingInt(contract.Probe.spin), .arg1 = tasks[0].sentinel, .arg2 = 0 };
        const old_context = try arch.createContext(tasks[0].space, invocation);
        live_context = old_context;
        if (arch.destroy(tasks[0].space)) |_| return error.LiveContextSpaceDestroyed else |err| {
            if (err != error.AddressSpaceHasContexts) return err;
        }
        try arch.validateContext(old_context);
        try arch.destroyContext(old_context);
        live_context = null;
        const new_context = try arch.createContext(tasks[0].space, invocation);
        live_context = new_context;
        if (new_context == old_context) return error.ContextGenerationReused;
        if (arch.validateContext(old_context)) |_| return error.StaleContextAccepted else |err| {
            if (err != error.StaleContextHandle and err != error.InvalidContextHandle) return err;
        }
        if (arch.destroyContext(old_context)) |_| return error.StaleContextDestroyed else |err| {
            if (err != error.StaleContextHandle and err != error.InvalidContextHandle) return err;
        }
        try arch.validateContext(new_context);
        try arch.destroyContext(new_context);
        live_context = null;
        const stale_space = tasks[0].space;
        try destroyTask(&tasks[0]);
        try runNormal(&tasks[1], kernel_address);
        tasks[0] = try createTask(1, 0x1122334455667788 + iteration);
        if (tasks[0].space.root != stale_space.root) return error.AddressSpaceRootNotReused;
        if (tasks[0].space.generation == stale_space.generation) return error.SpaceGenerationReused;
        const before_stale = memory.allocator().?.stats();
        if (arch.destroy(stale_space)) |_| return error.StaleAddressSpaceAccepted else |err| {
            if (err != error.StaleAddressSpace and err != error.InvalidAddressSpace and
                err != error.UnknownAddressSpace) return err;
        }
        try requireStats(before_stale);
        try runNormal(&tasks[0], kernel_address);
        try runNormal(&tasks[1], kernel_address);
        try destroyTask(&tasks[0]);
        try destroyTask(&tasks[1]);
        try requireStats(baseline);
    }
}

fn requireStats(before: @TypeOf(memory.allocator().?.stats())) !void {
    const after = memory.allocator().?.stats();
    if (after.free_pages != before.free_pages or after.allocated_pages != before.allocated_pages or
        after.metadata_pages != before.metadata_pages or after.managed_pages != before.managed_pages)
        return error.TaskResourceLeak;
}

fn invoke(task: *Task, probe: contract.Probe, target: u64) void {
    task.observation = .{};
    current = task;
    arch.run(task.space, .{ .entry = contract.user_code, .user_sp = contract.user_stack_top, .arg0 = @backingInt(probe), .arg1 = target, .arg2 = @backingInt(task.read_handle) });
    current = null;
}

fn runNormal(task: *Task, kernel_address: u64) !void {
    invoke(task, .normal, kernel_address);
    const got = task.observation;
    if (got.invalid or got.fault != null or !got.exited or got.exit_status != 0 or
        got.syscalls != 5 or got.reports != 1 or got.invalid_pointers != 1 or
        got.unknown_calls != 1 or got.denied_writes != 1) return error.UserSyscallVerificationFailed;
    const data: *const volatile u64 = @ptrFromInt(task.memory.data);
    if (data.* != task.sentinel) return error.PeerTaskMemoryCorrupted;
}

export fn bedrock_user_dispatch(event: *const contract.Event, reply: *contract.Reply) callconv(.c) void {
    if (desktop_runtime.isActive()) {
        desktop_runtime.dispatch(event, reply);
        return;
    }
    if (process_runtime.isActive()) {
        process_runtime.dispatch(event, reply);
        return;
    }
    reply.* = .{ .action = contract.action_terminate, .result = 0 };
    const task = current orelse return;
    const got = &task.observation;
    if (event.kind == contract.event_timer) {
        if (!preemptive or got.exited or got.fault != null or
            event.pc < contract.user_code or event.pc >= contract.user_code + contract.page_size)
        {
            got.invalid = true;
            return;
        }
        got.timer_ticks += 1;
        reply.action = contract.action_suspend;
        return;
    }
    if (event.kind == contract.event_fault) {
        got.fault = event.*;
        return;
    }
    if (event.kind != contract.event_syscall or got.exited or got.fault != null or
        event.pc < contract.user_code or event.pc >= contract.user_code + contract.page_size)
    {
        got.invalid = true;
        return;
    }
    got.syscalls += 1;
    reply.action = contract.action_resume;
    switch (event.number) {
        contract.syscall_report => {
            if (event.arg1 != 8) {
                reply.result = contract.errno_fault;
                got.invalid_pointers += 1;
                return;
            }
            const regions = task.regions();
            const physical = user_memory.translateRead(&regions, event.arg0, event.arg1) catch {
                reply.result = contract.errno_fault;
                got.invalid_pointers += 1;
                return;
            };
            // Byte loads also support unaligned app pointers on strict ARM.
            const bytes: [*]const volatile u8 = @ptrFromInt(physical);
            var value: u64 = 0;
            for (0..8) |index| value |= @as(u64, bytes[index]) << @intCast(index * 8);
            // arg2 was loaded directly by a user instruction. Comparing it
            // as well as copyin proves the CPU selected this task's data root.
            if (value != task.sentinel or event.arg2 != task.sentinel) got.invalid = true;
            got.reports += 1;
            reply.result = 8;
        },
        contract.syscall_exit => {
            got.exited = true;
            got.exit_status = event.arg0;
            reply.action = contract.action_terminate;
        },
        contract.syscall_write_handle => {
            const token: security.handles.Token = @fromBackingInt(@intCast(event.arg0));
            if (token != task.read_handle) got.invalid = true;
            _ = task.handles.resolve(token, .file, security.handles.rights.write) catch |err| {
                if (err != error.PermissionDenied) got.invalid = true;
                got.denied_writes += 1;
                reply.result = contract.errno_access;
                return;
            };
            // No writable object or I/O backend exists in this probe ABI.
            got.invalid = true;
            reply.result = contract.errno_unknown;
        },
        else => {
            got.unknown_calls += 1;
            reply.result = contract.errno_unknown;
        },
    }
}

fn kernelLayout() contract.KernelLayout {
    return .{ .kernel_start = linkerAddress(&__kernel_image_start), .text_start = linkerAddress(&__text_start), .text_end = linkerAddress(&__text_end), .rodata_start = linkerAddress(&__rodata_start), .rodata_end = linkerAddress(&__rodata_end), .data_start = linkerAddress(&__data_start), .data_end = linkerAddress(&__data_end), .allocated_end = linkerAddress(&__kernel_allocated_end), .stack_bottom = linkerAddress(&__stack_bottom), .stack_top = linkerAddress(&__stack_top), .stack_guard = linkerAddress(&__stack_guard) };
}

fn linkerAddress(symbol: *const u8) u64 {
    // Boundary symbols may intentionally alias (text_end/rodata_start).
    // They are linker addresses, not distinct Zig objects. Optimized checks
    // must compare actual relocated values without LLVM object-identity facts.
    return asm volatile (""
        : [address] "=r" (-> u64),
        : [symbol] "0" (@intFromPtr(symbol)),
    );
}
