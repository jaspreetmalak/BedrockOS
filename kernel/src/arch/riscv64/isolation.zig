//! Named QEMU RV64 UEFI isolation: fresh Sv39 roots and cooperative U-mode
//! probes and resumable timer-preempted tasks. All identity leaves are
//! supervisor-only; SUM and MXR remain clear.
const std = @import("std");
const protocol = @import("boot_protocol");
const memory = @import("memory_init");
const contract = @import("isolation_contract");
const timer = @import("timer.zig");

const page_size = contract.page_size;
const identity_limit: u64 = 1 << 38;
const max_table_pages = 256;
const max_spaces = 8;
const valid: u64 = 1;
const read: u64 = 1 << 1;
const write: u64 = 1 << 2;
const execute: u64 = 1 << 3;
const user: u64 = 1 << 4;
const accessed: u64 = 1 << 6;
const dirty: u64 = 1 << 7;
const leaf_bits: u64 = read | write | execute;
const supervisor_rw = valid | read | write | accessed | dirty;
const supervisor_rx = valid | read | execute | accessed;
const supervisor_ro = valid | read | accessed;

fn userFlags(mapping: contract.Mapping) u64 {
    return supervisor_ro | user | (if (mapping.writable) write | dirty else @as(u64, 0)) |
        (if (mapping.executable) execute else @as(u64, 0));
}

var ready = false;
var running = false;
var running_task: contract.TaskMemory = undefined;
var boot_info: *const protocol.BootInfo = undefined;
var kernel_layout: contract.KernelLayout = undefined;
var kernel_root: u64 = 0;
var kernel_tables: Tables = undefined;
var trap_guard: u64 = 0;
var trap_stack_top: u64 = 0;
var spaces: [max_spaces]Space = @splat(.{});
var next_space_generation: u64 = 1;
var preemption_ready = false;
var contexts: [max_spaces]Context = @splat(.{});
var current_context: ?*Context = null;

extern fn bedrock_riscv_isolation_enter(entry: u64, user_sp: u64, trap_sp: u64, satp: u64, arg0: u64, arg1: u64, arg2: u64) callconv(.c) void;
extern fn bedrock_riscv_isolation_resume(frame: *const Frame, trap_sp: u64, satp: u64) callconv(.c) void;
extern fn bedrock_user_dispatch(event: *const contract.Event, reply: *contract.Reply) callconv(.c) void;
extern var bedrock_riscv_user_program_start: u8;
extern var bedrock_riscv_user_program_end: u8;

const Frame = extern struct {
    registers: [32]u64,
    pc: u64,
    status: u64,
    cause: u64,
    value: u64,
};

const Context = struct {
    space: contract.AddressSpace = undefined,
    frame: Frame = undefined,
    generation: u32 = 1,
    state: enum { free, runnable, active, dead, retired } = .free,
};

const Space = struct {
    tables: Tables = undefined,
    // Issued globally, so root reuse in a different slot cannot revive a token.
    generation: u64 = 0,
    live: bool = false,
    task: contract.TaskMemory = undefined,
    shared: [contract.shared_surface_slots]contract.SharedMapping = @splat(.{}),
    shared_tables: [contract.shared_surface_slots][2]u64 = @splat(@splat(0)),
};

comptime {
    if (@sizeOf(Frame) != 288 or @offsetOf(Frame, "pc") != 256 or
        @offsetOf(Frame, "status") != 264 or @offsetOf(Frame, "cause") != 272 or
        @offsetOf(Frame, "value") != 280) @compileError("RV64 isolation trap frame changed");
    if (contract.user_code != 0x2000000000 or contract.user_data != 0x2000001000)
        @compileError("RV64 position-independent fixture constants changed");
}

fn table(address: u64) *[512]u64 {
    std.debug.assert(address != 0 and address % page_size == 0);
    return @ptrFromInt(address);
}

fn physical(pte: u64) u64 {
    return ((pte >> 10) & ((@as(u64, 1) << 44) - 1)) << 12;
}

fn levelSize(level: u2) u64 {
    return @as(u64, 1) << (@as(u6, 12) + @as(u6, level) * 9);
}

fn indexFor(address: u64, level: u2) usize {
    return @intCast((address >> (@as(u6, 12) + @as(u6, level) * 9)) & 511);
}

const Tables = struct {
    root: u64,
    count: usize,
    limit: usize,
    pages: [max_table_pages]u64,

    fn init(self: *Tables, limit: usize) !void {
        if (limit == 0) return error.PageTableCapacity;
        if (limit > max_table_pages) return error.InvalidPageTableLimit;
        const root = try memory.allocateZeroed();
        self.root = root;
        self.count = 1;
        self.limit = limit;
        self.pages[0] = root;
    }

    fn allocate(self: *Tables) !u64 {
        if (self.count == self.limit) return error.PageTableCapacity;
        const address = try memory.allocateZeroed();
        self.pages[self.count] = address;
        self.count += 1;
        return address;
    }

    /// Only this tree's ledger is returned, without traversing mapped leaves.
    /// Task teardown never releases user frames or the permanent kernel tree
    /// and trap stack. A failed prepare may release its unfinished kernel tree.
    fn release(self: *Tables) void {
        std.debug.assert(self.count != 0 and readSatp() != satpFor(self.root));
        table(self.root).* = @splat(0);
        // All roots use ASID zero. Flush globally before any table-page reuse,
        // including a partially constructed root that was never installed.
        asm volatile ("fence rw, rw\nsfence.vma" ::: .{ .memory = true });
        const allocator = memory.allocator() orelse @panic("RV64 table allocator disappeared");
        while (self.count != 0) {
            self.count -= 1;
            allocator.release(self.pages[self.count]) catch @panic("RV64 table ownership corrupted");
        }
        self.root = 0;
    }

    /// Descend while splitting an existing huge leaf with identical rights.
    /// A split preserves complete physical coverage, not an accidental alias.
    fn child(self: *Tables, slot: *u64, level: u2) !u64 {
        if (level == 0) return error.InvalidPageTableLevel;
        if ((slot.* & valid) == 0) {
            const next = try self.allocate();
            slot.* = (next >> 12) << 10 | valid;
            return next;
        }
        if ((slot.* & leaf_bits) == 0) return physical(slot.*);
        const next = try self.allocate();
        const base = physical(slot.*);
        const flags = slot.* & 0x3ff;
        const stride = levelSize(level - 1);
        for (table(next), 0..) |*entry, index|
            entry.* = ((base + index * stride) >> 12) << 10 | flags;
        slot.* = (next >> 12) << 10 | valid;
        return next;
    }

    fn mapLeaf(self: *Tables, virtual_address: u64, physical_address: u64, level: u2, flags: u64) !void {
        const size = levelSize(level);
        if (virtual_address >= identity_limit or virtual_address % size != 0 or
            physical_address >= (@as(u64, 1) << 56) or physical_address % size != 0)
            return error.InvalidMapping;
        var current = self.root;
        var current_level: u2 = 2;
        while (current_level > level) : (current_level -= 1) {
            current = try self.child(&table(current)[indexFor(virtual_address, current_level)], current_level);
        }
        const slot = &table(current)[indexFor(virtual_address, level)];
        if ((slot.* & valid) != 0 and (slot.* & leaf_bits) == 0) return error.MappingCollision;
        slot.* = (physical_address >> 12) << 10 | flags;
    }

    fn identity(self: *Tables, range: protocol.PhysicalRange) !void {
        const raw_end = try range.endExclusive();
        if (range.length == 0 or raw_end > identity_limit) return error.UnsupportedIdentityAddress;
        const rounded = @addWithOverflow(raw_end, page_size - 1);
        if (rounded[1] != 0) return error.UnsupportedIdentityAddress;
        var address = @max(range.base & ~(page_size - 1), page_size);
        const end = rounded[0] & ~(page_size - 1);
        while (address < end) {
            var level: u2 = if (address % levelSize(2) == 0 and end - address >= levelSize(2))
                2
            else if (address % levelSize(1) == 0 and end - address >= levelSize(1))
                1
            else
                0;
            while (true) {
                self.mapLeaf(address, address, level, supervisor_rw) catch |err| {
                    // Partial descriptor coverage can round into a page already
                    // represented by a smaller subtree. Preserve that subtree.
                    if (err == error.MappingCollision and level != 0) {
                        level -= 1;
                        continue;
                    }
                    return err;
                };
                break;
            }
            address += levelSize(level);
        }
    }

    fn protect(self: *Tables, start: u64, end: u64, flags: u64) !void {
        var address = start;
        while (address < end) : (address += page_size)
            try self.mapLeaf(address, address, 0, flags);
    }

    fn unmap(self: *Tables, address: u64) !void {
        var current = self.root;
        var level: u2 = 2;
        while (level != 0) : (level -= 1) {
            const slot = &table(current)[indexFor(address, level)];
            if ((slot.* & valid) == 0) return;
            current = try self.child(slot, level);
        }
        table(current)[indexFor(address, 0)] = 0;
    }
};

const Translation = struct { address: u64, flags: u64 };

fn lookup(root: u64, virtual_address: u64) ?Translation {
    if (virtual_address >= identity_limit) return null;
    var current = root;
    var level: u2 = 2;
    while (true) {
        const pte = table(current)[indexFor(virtual_address, level)];
        if ((pte & valid) == 0) return null;
        if ((pte & leaf_bits) != 0) {
            const size = levelSize(level);
            if ((pte & write) != 0 and (pte & read) == 0 or physical(pte) % size != 0) return null;
            return .{ .address = physical(pte) + virtual_address % size, .flags = pte & 0x3ff };
        }
        if (level == 0) return null;
        current = physical(pte);
        level -= 1;
    }
}

fn auditNode(root: u64, current: u64, level: u2, base: u64, task_memory: ?contract.TaskMemory, shared: []const contract.SharedMapping) anyerror!void {
    const backing = lookup(root, current) orelse return error.PageTableNotAccessible;
    if (backing.address != current or (backing.flags & (read | write | execute | user)) != (read | write))
        return error.PageTableNotWritable;
    for (table(current), 0..) |pte, index| {
        if ((pte & valid) == 0) continue;
        const address = base + index * levelSize(level);
        if ((pte & leaf_bits) == 0) {
            if (level == 0 or (pte & 0x3ff) != valid) return error.InvalidPageTable;
            try auditNode(root, physical(pte), level - 1, address, task_memory, shared);
            continue;
        }
        if ((pte & write) != 0 and (pte & read) == 0 or
            (pte & (write | execute)) == (write | execute) or
            physical(pte) % levelSize(level) != 0) return error.InvalidLeafPermissions;
        if ((pte & user) == 0) {
            if (physical(pte) != address) return error.NonIdentitySupervisorMapping;
            continue;
        }
        const task = task_memory orelse return error.UnexpectedUserMapping;
        if (level != 0) return error.UserHugePage;
        const Expected = struct { physical_address: u64, flags: u64 };
        const mapping = contract.userMapping(task, shared, address) orelse return error.UnexpectedUserMapping;
        const expected: Expected = .{ .physical_address = mapping.physical + address - mapping.virtual, .flags = userFlags(mapping) & (read | write | execute | user) };
        if (physical(pte) != expected.physical_address or (pte & (read | write | execute | user)) != expected.flags)
            return error.InvalidUserPermissions;
    }
}

fn auditRange(root: u64, start: u64, end: u64, flags: u64) !void {
    var address = start;
    while (address < end) : (address += page_size) {
        const translated = lookup(root, address) orelse return error.KernelMappingMissing;
        if (translated.address != address or (translated.flags & (read | write | execute | user)) != flags)
            return error.KernelPermissionsWrong;
    }
}

fn audit(tables: *const Tables, task_memory: ?contract.TaskMemory, shared: []const contract.SharedMapping) !void {
    try auditNode(tables.root, tables.root, 2, 0, task_memory, shared);
    try auditRange(tables.root, kernel_layout.text_start, kernel_layout.text_end, read | execute);
    try auditRange(tables.root, kernel_layout.rodata_start, kernel_layout.rodata_end, read);
    try auditRange(tables.root, kernel_layout.data_start, kernel_layout.data_end, read | write);
    if (boot_info.apps.reservation.length != 0)
        try auditRange(tables.root, boot_info.apps.reservation.base, try boot_info.apps.reservation.endExclusive(), read);
    for (boot_info.drivers.records[0..boot_info.drivers.count]) |driver|
        for (driver.segments[0..driver.segment_count]) |segment|
            try auditRange(tables.root, segment.range.base, try segment.range.endExclusive(), read | (if (segment.flags & 2 != 0) write else @as(u64, 0)) | (if (segment.flags & 1 != 0) execute else @as(u64, 0)));
    try auditRange(tables.root, kernel_layout.stack_bottom, kernel_layout.stack_top, read | write);
    if (lookup(tables.root, kernel_layout.stack_guard) != null or lookup(tables.root, trap_guard) != null or
        lookup(tables.root, contract.user_guard) != null or lookup(tables.root, 0) != null)
        return error.GuardPageMapped;
    if (task_memory) |task| {
        if (lookup(tables.root, task.guard()) != null) return error.GuardPageMapped;
        for (task.allMappings()) |mapping| {
            for (0..mapping.pages) |index| {
                const address = mapping.physical + index * page_size;
                const alias = lookup(tables.root, address) orelse return error.PrivateBackingNotAccessible;
                if (alias.address != address or (alias.flags & (user | execute)) != 0)
                    return error.PrivatePhysicalAliasExposed;
                const leaf = lookup(tables.root, mapping.virtual + index * page_size) orelse return error.UserMappingMissing;
                const expected = userFlags(mapping) & (read | write | execute | user);
                if (leaf.address != address or leaf.flags & (read | write | execute | user) != expected) return error.InvalidUserPermissions;
            }
        }
        for (shared, 0..) |record, slot| {
            if (record.pages == 0) continue;
            const mapping = try record.mapping(slot);
            for (0..mapping.pages) |index| {
                const leaf = lookup(tables.root, mapping.virtual + index * page_size) orelse return error.UserMappingMissing;
                if (leaf.address != mapping.physical + index * page_size or leaf.flags & (read | write | execute | user) != userFlags(mapping) & (read | write | execute | user)) return error.InvalidUserPermissions;
            }
        }
    }
}

fn makeKernelMappings(tables: *Tables, limit: usize) !void {
    try tables.init(limit);
    errdefer tables.release();
    for (boot_info.mapped_ranges[0..boot_info.mapped_range_count]) |range| try tables.identity(range);
    // The named QEMU SiFive test device is used only for the smoke exit.
    try tables.mapLeaf(0x100000, 0x100000, 0, supervisor_rw);
    try tables.protect(kernel_layout.text_start, kernel_layout.text_end, supervisor_rx);
    try tables.protect(kernel_layout.rodata_start, kernel_layout.rodata_end, supervisor_ro);
    if (boot_info.apps.reservation.length != 0)
        try tables.protect(boot_info.apps.reservation.base, try boot_info.apps.reservation.endExclusive(), supervisor_ro);
    for (boot_info.drivers.records[0..boot_info.drivers.count]) |driver|
        for (driver.segments[0..driver.segment_count]) |segment|
            try tables.protect(segment.range.base, try segment.range.endExclusive(), if (segment.flags & 1 != 0) supervisor_rx else if (segment.flags & 2 != 0) supervisor_rw else supervisor_ro);
    try tables.unmap(kernel_layout.stack_guard);
    try tables.unmap(trap_guard);
}

fn satpFor(root: u64) u64 {
    return (@as(u64, 8) << 60) | (root >> 12);
}

fn readSatp() u64 {
    return asm volatile ("csrr %[value], satp"
        : [value] "=r" (-> u64),
        :
        : .{ .memory = true });
}

fn readStatus() u64 {
    return asm volatile ("csrr %[value], sstatus"
        : [value] "=r" (-> u64),
        :
        : .{ .memory = true });
}

fn publish() void {
    asm volatile ("fence rw, rw\nfence.i" ::: .{ .memory = true });
}

pub fn prepare(info: *const protocol.BootInfo, layout: contract.KernelLayout) !void {
    if (ready) return error.IsolationAlreadyPrepared;
    if (info.entry_state != @backingInt(protocol.EntryState.riscv64_s) or
        info.boot_environment != @backingInt(protocol.BootEnvironment.uefi) or
        info.mapped_range_count == 0 or info.mapped_range_count > protocol.max_mapped_ranges or
        readSatp() != 0) return error.UnexpectedSupervisorEntry;
    if ((readStatus() & ((1 << 18) | (1 << 19) | (1 << 1))) != 0)
        return error.UnexpectedSupervisorStatus;
    try contract.validateKernelStack(layout);
    for ([_]u64{ layout.kernel_start, layout.text_start, layout.text_end, layout.rodata_start, layout.rodata_end, layout.data_start, layout.data_end, layout.allocated_end, layout.stack_bottom, layout.stack_top, layout.stack_guard }) |address| {
        if (address >= identity_limit or address % page_size != 0) return error.InvalidKernelLayout;
    }
    if (layout.kernel_start != layout.text_start or layout.text_start >= layout.text_end or
        layout.text_end != layout.rodata_start or layout.rodata_start >= layout.rodata_end or
        layout.rodata_end != layout.data_start or layout.data_start > layout.data_end or
        layout.data_end > layout.stack_guard or layout.stack_guard + page_size != layout.stack_bottom or
        layout.stack_bottom >= layout.stack_top or layout.stack_top != layout.allocated_end)
        return error.InvalidKernelLayout;
    for (info.mapped_ranges[0..info.mapped_range_count]) |range| {
        const end = try range.endExclusive();
        if (end > identity_limit) return error.UnsupportedIdentityAddress;
        if (range.base < contract.user_window_end and contract.user_base < end)
            return error.UserWindowInIdentityCoverage;
    }
    if (!info.isMapped(.{ .base = layout.kernel_start, .length = layout.allocated_end - layout.kernel_start }))
        return error.KernelNotAccessible;
    boot_info = info;
    kernel_layout = layout;
    const allocator = memory.allocator() orelse return error.MemoryNotInitialized;
    // A guarded, kernel-owned 128 KiB dispatcher stack. The cooperative probes
    // are serialized; no user token can select or modify this stack.
    const stack = (try allocator.allocateContiguous(contract.kernel_dispatch_stack_pages + 1, 1)) orelse return error.OutOfMemory;
    errdefer {
        allocator.releaseContiguous(stack) catch @panic("RV64 trap-stack ownership corrupted");
        trap_guard = 0;
        trap_stack_top = 0;
    }
    const words: [*]volatile u64 = @ptrFromInt(stack.base);
    for (0..@as(usize, @intCast(stack.length / 8))) |index| words[index] = 0;
    trap_guard = stack.base;
    trap_stack_top = stack.base + stack.length;
    try makeKernelMappings(&kernel_tables, max_table_pages);
    errdefer {
        // prepare requires bare entry. Restore it before releasing a failed
        // bootstrap root, including an unsupported SATP readback.
        asm volatile ("csrw satp, zero\nsfence.vma" ::: .{ .memory = true });
        kernel_tables.release();
        kernel_root = 0;
    }
    try audit(&kernel_tables, null, &.{});
    kernel_root = kernel_tables.root;
    publish();
    const value = satpFor(kernel_root);
    asm volatile ("csrw sscratch, zero\ncsrw satp, %[value]\nsfence.vma"
        :
        : [value] "r" (value),
        : .{ .memory = true });
    if (readSatp() != value) return error.Sv39Unsupported;
    ready = true;
}

pub fn create(task_memory: contract.TaskMemory) !contract.AddressSpace {
    return createWithTableLimit(task_memory, max_table_pages);
}

/// A per-space table-page resource bound, including its root and every split.
/// Failure returns every allocated table page without taking user-frame ownership.
pub fn createWithTableLimit(task_memory: contract.TaskMemory, table_limit: usize) !contract.AddressSpace {
    if (!ready or running or current_context != null) return error.IsolationNotPrepared;
    if (readSatp() != satpFor(kernel_root) or readStatus() & (1 << 1) != 0)
        return error.UnexpectedSupervisorState;
    if (next_space_generation == 0) return error.AddressSpaceGenerationExhausted;
    const slot = for (&spaces) |*candidate| {
        if (!candidate.live) break candidate;
    } else return error.AddressSpaceCapacity;
    try task_memory.validate();
    for (task_memory.allMappings()) |mapping| {
        if (mapping.pages == 0) continue;
        const range: protocol.PhysicalRange = .{ .base = mapping.physical, .length = @as(u64, mapping.pages) * page_size };
        if (try range.endExclusive() > identity_limit or !boot_info.isMapped(range)) return error.InvalidTaskMemory;
        if (boot_info.apps.reservation.length != 0 and range.base < try boot_info.apps.reservation.endExclusive() and
            boot_info.apps.reservation.base < try range.endExclusive()) return error.AppArchiveCannotBackUserMemory;
        for (0..mapping.pages) |offset| {
            const address = mapping.physical + offset * page_size;
            const alias = lookup(kernel_root, address) orelse return error.PrivateBackingNotAccessible;
            if (alias.address != address or alias.flags & (user | execute) != 0) return error.PrivatePhysicalAliasExposed;
        }
    }
    const tables = &slot.tables;
    slot.shared = @splat(.{});
    slot.shared_tables = @splat(@splat(0));
    try makeKernelMappings(tables, table_limit);
    errdefer tables.release();
    for (task_memory.allMappings()) |mapping| {
        for (0..mapping.pages) |offset| try tables.mapLeaf(mapping.virtual + offset * page_size, mapping.physical + offset * page_size, 0, userFlags(mapping));
    }
    try tables.unmap(task_memory.guard());
    try audit(tables, task_memory, &slot.shared);
    publish();
    slot.generation = next_space_generation;
    slot.task = task_memory;
    next_space_generation = if (next_space_generation == std.math.maxInt(u64)) 0 else next_space_generation + 1;
    slot.live = true;
    return .{ .root = tables.root, .generation = slot.generation };
}

pub fn programBytes() []const u8 {
    const start = @intFromPtr(&bedrock_riscv_user_program_start);
    const end = @intFromPtr(&bedrock_riscv_user_program_end);
    std.debug.assert(end > start and end - start <= page_size);
    return @as([*]const u8, @ptrFromInt(start))[0 .. end - start];
}

pub fn run(space: contract.AddressSpace, invocation: contract.Invocation) void {
    if (!ready or running or readSatp() != satpFor(kernel_root) or
        invocation.entry != contract.user_code or invocation.user_sp != contract.user_stack_top)
        @panic("Invalid RV64 user transition");
    const owned = findSpace(space) orelse @panic("Unknown RV64 address space");
    if (owned.task.desktop or owned.task.app) @panic("RV64 cooperative fixture needs fixture layout");
    running_task = owned.task;
    running = true;
    bedrock_riscv_isolation_enter(invocation.entry, invocation.user_sp, trap_stack_top, satpFor(space.root), invocation.arg0, invocation.arg1, invocation.arg2);
    running = false;
    if (readSatp() != satpFor(kernel_root) or (readStatus() & ((1 << 18) | (1 << 19))) != 0)
        @panic("RV64 supervisor state was not restored");
}

fn knownSpace(space: contract.AddressSpace) bool {
    return findSpace(space) != null;
}

fn findSpace(space: contract.AddressSpace) ?*Space {
    for (&spaces) |*candidate| {
        if (candidate.live and candidate.tables.root == space.root and
            candidate.generation == space.generation) return candidate;
    }
    return null;
}

fn sharedReady() !void {
    if (!ready or running or current_context != null or readStatus() & (1 << 1) != 0 or readSatp() != satpFor(kernel_root))
        return error.InvalidAddressSpaceState;
}
fn ownsTable(tables: *const Tables, address: u64) bool {
    for (tables.pages[0..tables.count]) |owned| if (owned == address) return true;
    return false;
}
fn sharedBacking(address: u64, pages: u16) !void {
    try contract.validateSharedBacking(boot_info, address, pages);
    const allocator = memory.allocator() orelse return error.MemoryNotInitialized;
    try contract.validateSharedAllocation(allocator, address, pages);
    const bytes = @as(u64, pages) * page_size;
    if (address + bytes > identity_limit or contract.physicalOverlap(address, bytes, trap_guard, (contract.kernel_dispatch_stack_pages + 1) * page_size)) return error.ProtectedSharedBacking;
    for (kernel_tables.pages[0..kernel_tables.count]) |physical_address|
        if (contract.physicalOverlap(address, bytes, physical_address, page_size)) return error.ProtectedSharedBacking;
    for (&spaces) |*candidate| {
        if (!candidate.live) continue;
        for (candidate.tables.pages[0..candidate.tables.count]) |physical_address|
            if (contract.physicalOverlap(address, bytes, physical_address, page_size)) return error.ProtectedSharedBacking;
        for (candidate.task.allMappings()) |mapping|
            if (contract.physicalOverlap(address, bytes, mapping.physical, @as(u64, mapping.pages) * page_size)) return error.ProtectedSharedBacking;
    }
    for (0..pages) |index| {
        const physical_address = address + index * page_size;
        const alias = lookup(kernel_root, physical_address) orelse return error.InvalidSharedBacking;
        if (alias.address != physical_address or alias.flags & (user | execute | read | write) != read | write) return error.InvalidSharedPhysicalAlias;
    }
}
fn sharedDirectory(owned: *const Space) !*[512]u64 {
    const pointer = table(owned.tables.root)[indexFor(contract.user_base, 2)];
    if (pointer & (valid | leaf_bits) != valid or !ownsTable(&owned.tables, physical(pointer))) return error.InvalidPageTable;
    return table(physical(pointer));
}
fn releaseSharedTable(owned: *Space, address: u64) !void {
    const index = for (owned.tables.pages[0..owned.tables.count], 0..) |value, at| {
        if (value == address and at != 0) break at;
    } else return error.InvalidPageTable;
    try memory.allocator().?.release(address);
    std.mem.copyForwards(u64, owned.tables.pages[index .. owned.tables.count - 1], owned.tables.pages[index + 1 .. owned.tables.count]);
    owned.tables.count -= 1;
    owned.tables.pages[owned.tables.count] = 0;
}

pub fn mapShared(space: contract.AddressSpace, slot: usize, physical_address: u64, pages: u16, writable_mapping: bool) !void {
    try sharedReady();
    const record = try contract.SharedMapping.init(slot, physical_address, pages, writable_mapping);
    const mapping = try record.mapping(slot);
    const owned = findSpace(space) orelse return error.UnknownAddressSpace;
    if (owned.shared[slot].pages != 0) return error.SharedSlotOccupied;
    try sharedBacking(physical_address, pages);
    const directory = try sharedDirectory(owned);
    const first = indexFor(mapping.virtual, 1);
    const needed: usize = if (pages > 512) 2 else 1;
    if (owned.tables.count + needed > owned.tables.limit) return error.PageTableCapacity;
    for (0..needed) |index| if (directory[first + index] != 0) return error.SharedWindowAlreadyMapped;
    const checkpoint = owned.tables.count;
    var allocated: [2]u64 = @splat(0);
    var published = false;
    errdefer {
        if (published) {
            for (0..needed) |index| directory[first + index] = 0;
            owned.shared[slot] = .{};
            owned.shared_tables[slot] = @splat(0);
        }
        asm volatile ("fence rw, rw\nsfence.vma" ::: .{ .memory = true });
        while (owned.tables.count > checkpoint) {
            owned.tables.count -= 1;
            memory.allocator().?.release(owned.tables.pages[owned.tables.count]) catch @panic("RV64 shared table rollback");
            owned.tables.pages[owned.tables.count] = 0;
        }
    }
    for (0..needed) |index| allocated[index] = try owned.tables.allocate();
    for (0..pages) |index|
        table(allocated[index / 512])[index % 512] = ((physical_address + index * page_size) >> 12) << 10 | userFlags(mapping);
    for (allocated[0..needed], 0..) |address, index| directory[first + index] = (address >> 12) << 10 | valid;
    owned.shared[slot] = record;
    owned.shared_tables[slot] = allocated;
    published = true;
    try audit(&owned.tables, owned.task, &owned.shared);
    publish();
    asm volatile ("sfence.vma" ::: .{ .memory = true });
}

pub fn unmapShared(space: contract.AddressSpace, slot: usize) !void {
    try sharedReady();
    if (slot >= contract.shared_surface_slots) return error.InvalidSharedMapping;
    const owned = findSpace(space) orelse return error.UnknownAddressSpace;
    const record = owned.shared[slot];
    if (record.pages == 0) return error.SharedSlotEmpty;
    const mapping = try record.mapping(slot);
    const directory = try sharedDirectory(owned);
    const first = indexFor(mapping.virtual, 1);
    const allocated = owned.shared_tables[slot];
    const needed: usize = if (record.pages > 512) 2 else 1;
    try audit(&owned.tables, owned.task, &owned.shared);
    for (allocated[0..needed], 0..) |address, index|
        if (!ownsTable(&owned.tables, address) or directory[first + index] != (address >> 12) << 10 | valid) return error.InvalidPageTable;
    for (0..needed) |index| directory[first + index] = 0;
    owned.shared[slot] = .{};
    owned.shared_tables[slot] = @splat(0);
    asm volatile ("fence rw, rw\nsfence.vma" ::: .{ .memory = true });
    for (allocated[0..needed]) |address| try releaseSharedTable(owned, address);
    try audit(&owned.tables, owned.task, &owned.shared);
}

/// Saved contexts must be destroyed before their address-space tables. This
/// leaves the core-owned code/data/stack frames available for separate cleanup.
pub fn destroy(space: contract.AddressSpace) !void {
    if (!ready or running or current_context != null or readStatus() & (1 << 1) != 0)
        return error.InvalidAddressSpaceState;
    if (readSatp() != satpFor(kernel_root) or readSatp() == satpFor(space.root))
        return error.ActiveAddressSpace;
    const owned = findSpace(space) orelse return error.UnknownAddressSpace;
    for (owned.shared) |record| if (record.pages != 0) return error.AddressSpaceHasSharedMappings;
    for (&contexts) |*context| {
        if (context.state != .free and context.state != .retired and
            context.space.root == space.root and context.space.generation == space.generation)
            return error.AddressSpaceHasContexts;
    }
    owned.tables.release();
    owned.live = false;
    owned.generation = 0;
}

pub fn preparePreemption(info: *const protocol.BootInfo) !void {
    if (!ready or running or current_context != null or preemption_ready)
        return error.InvalidPreemptionState;
    if (readSatp() != satpFor(kernel_root) or readStatus() & (1 << 1) != 0)
        return error.UnexpectedSupervisorState;
    const end = try info.dtb.endExclusive();
    const loader_end = try info.loader_reserved.endExclusive();
    if (info.dtb.length < 40 or info.dtb.length > 512 * 1024 or
        info.dtb.base < info.loader_reserved.base or end > loader_end or !info.isMapped(info.dtb))
        return error.InvalidTimerDtb;
    // Check the installed root as well as the handoff's accessibility claim
    // before any read through the copied DTB's supervisor physical alias.
    var at = info.dtb.base & ~(page_size - 1);
    while (at < end) : (at += page_size) {
        const translated = lookup(kernel_root, at) orelse return error.TimerDtbNotAccessible;
        if (translated.address != at or translated.flags & read == 0 or translated.flags & user != 0)
            return error.TimerDtbNotAccessible;
    }
    const bytes: [*]const u8 = @ptrFromInt(info.dtb.base);
    try timer.prepare(bytes[0..@intCast(info.dtb.length)]);
    preemption_ready = true;
}

pub fn createContext(space: contract.AddressSpace, invocation: contract.Invocation) !contract.ContextHandle {
    if (!preemption_ready or running or current_context != null) return error.InvalidPreemptionState;
    if (readSatp() != satpFor(kernel_root) or readStatus() & (1 << 1) != 0)
        return error.UnexpectedSupervisorState;
    const owned = findSpace(space) orelse return error.UnknownAddressSpace;
    const slot = for (&contexts, 0..) |*candidate, index| {
        if (candidate.state == .free) break index;
    } else return error.ContextCapacity;
    if (invocation.entry < owned.task.codeVirtual() or invocation.entry >= owned.task.codeEnd() or
        invocation.entry % 2 != 0 or invocation.user_sp != owned.task.stackTop())
        return error.InvalidUserInvocation;
    // UXL and other immutable architectural state come from the kernel. Keep
    // SUM/MXR, FP/vector state and SIE clear; SRET uses SPIE for user delivery.
    const clear: u64 = (1 << 1) | (1 << 5) | (1 << 8) | (1 << 18) | (1 << 19) | (3 << 13) | (3 << 9);
    var frame: Frame = .{
        .registers = @splat(0),
        .pc = invocation.entry,
        .status = (readStatus() & ~clear) | (1 << 5),
        .cause = 0,
        .value = 0,
    };
    frame.registers[2] = invocation.user_sp;
    frame.registers[10] = invocation.arg0;
    frame.registers[11] = invocation.arg1;
    frame.registers[12] = invocation.arg2;
    const context = &contexts[slot];
    context.space = space;
    context.frame = frame;
    context.state = .runnable;
    return @fromBackingInt((@as(u64, context.generation) << 32) | @as(u64, @intCast(slot + 1)));
}

fn contextFor(handle: contract.ContextHandle) !*Context {
    const token = @backingInt(handle);
    const slot: u32 = @truncate(token);
    const generation: u32 = @intCast(token >> 32);
    if (slot == 0 or slot > contexts.len or generation == 0) return error.InvalidContextHandle;
    const context = &contexts[@intCast(slot - 1)];
    if (context.state == .free or context.state == .retired or context.generation != generation)
        return error.InvalidContextHandle;
    if (!knownSpace(context.space)) return error.UnknownAddressSpace;
    return context;
}

/// Validate a kernel token without entering user mode, including its generation.
pub fn validateContext(handle: contract.ContextHandle) !void {
    try inactiveKernelContext();
    const context = try contextFor(handle);
    if (context.state == .active) return error.ActiveContext;
    if (context.state != .runnable) return error.ContextStopped;
    const owned = findSpace(context.space) orelse return error.UnknownAddressSpace;
    if (!savedUserFrameValid(&context.frame, owned.task, true)) return error.InvalidUserInvocation;
}

fn inactiveKernelContext() !void {
    if (!preemption_ready) return error.InvalidPreemptionState;
    if (running or current_context != null) return error.ActiveContext;
    if (readSatp() != satpFor(kernel_root) or readStatus() & ((1 << 1) | (1 << 18) | (1 << 19)) != 0)
        return error.UnexpectedSupervisorState;
}

pub fn setContextResult(handle: contract.ContextHandle, result: u64) !void {
    try inactiveKernelContext();
    const context = try contextFor(handle);
    if (context.state == .active) return error.ActiveContext;
    if (context.state != .runnable) return error.ContextStopped;
    context.frame.registers[10] = result;
}

/// Observe a real SBI TIME deadline and posted STIP with kernel SIE clear.
/// Polling does not enter a user root or synthesize a scheduler timer event.
pub fn idleUntilTick() !void {
    try inactiveKernelContext();
    try timer.arm();
    defer timer.quiesce() catch @panic("cannot quiesce RV64 kernel timer wait");
    var polls: u32 = 0;
    while (polls < 10_000_000) : (polls += 1) {
        const pending = asm volatile ("csrr %[pending], sip"
            : [pending] "=r" (-> u64),
            :
            : .{ .memory = true });
        if (pending & (1 << 5) != 0 and timer.expired()) {
            try timer.acknowledge();
            return;
        }
        asm volatile ("nop" ::: .{ .memory = true });
    }
    return error.TimerWaitTimeout;
}

pub fn destroyContext(handle: contract.ContextHandle) !void {
    if (!preemption_ready or running or current_context != null or
        readSatp() != satpFor(kernel_root) or readStatus() & (1 << 1) != 0)
        return error.InvalidPreemptionState;
    const context = try contextFor(handle);
    if (context.state == .active) return error.ActiveContext;
    context.space = .{ .root = 0, .generation = 0 };
    context.frame = undefined;
    if (context.generation == std.math.maxInt(u32)) {
        context.state = .retired;
    } else {
        context.generation += 1;
        context.state = .free;
    }
}

pub fn resumeContext(handle: contract.ContextHandle) void {
    if (!preemption_ready or running or current_context != null or
        readSatp() != satpFor(kernel_root) or readStatus() & (1 << 1) != 0)
        @panic("Invalid RV64 context resume");
    const context = contextFor(handle) catch @panic("Invalid RV64 context handle");
    if (context.state != .runnable or !knownSpace(context.space) or
        context.frame.status & ((1 << 1) | (1 << 8) | (1 << 18) | (1 << 19) | (3 << 13) | (3 << 9)) != 0)
        @panic("Invalid RV64 saved user context");
    const owned = findSpace(context.space) orelse @panic("Stale RV64 context space");
    running_task = owned.task;
    context.state = .active;
    current_context = context;
    running = true;
    timer.arm() catch @panic("Cannot arm RV64 user timer");
    bedrock_riscv_isolation_resume(&context.frame, trap_stack_top, satpFor(context.space.root));
    running = false;
    current_context = null;
    if (context.state == .active or readSatp() != satpFor(kernel_root) or
        readStatus() & ((1 << 1) | (1 << 18) | (1 << 19)) != 0)
        @panic("RV64 preemption continuation was not restored");
}

pub fn validateFault(probe: contract.Probe, event: contract.Event) !void {
    const expected: u64 = switch (probe) {
        .kernel_read, .peer_read, .guard_read => 13,
        .code_write => 15,
        .stack_execute => 12,
        .normal, .spin => return error.UnexpectedFaultProbe,
    };
    if (event.kind != contract.event_fault or event.syndrome != expected)
        return error.UnexpectedPageFaultCause;
}

fn savedUserFrameValid(frame: *const Frame, task: contract.TaskMemory, interrupts_enabled: bool) bool {
    // The private window is canonical in Sv39. Compressed ISA permits two-byte
    // instruction alignment; no architectural stack alignment is required.
    return frame.pc >= task.codeVirtual() and frame.pc < task.codeEnd() and frame.pc % 2 == 0 and
        frame.registers[2] >= task.stackVirtual() and frame.registers[2] <= task.stackTop() and
        frame.status & ((1 << 1) | (1 << 8) | (1 << 18) | (1 << 19) | (3 << 13) | (3 << 9)) == 0 and
        (!interrupts_enabled or frame.status & (1 << 5) != 0);
}

export fn bedrock_riscv_isolation_trap(frame: *Frame) callconv(.c) u64 {
    if (!running or (frame.status & ((1 << 8) | (1 << 18) | (1 << 19))) != 0)
        @panic("Unexpected supervisor isolation trap");
    if (frame.cause == timer.interrupt_cause) {
        const context = current_context orelse @panic("Timer interrupted a cooperative probe");
        if (!preemption_ready or context.state != .active)
            @panic("Unexpected RV64 timer context");
        if (!timer.expired() and savedUserFrameValid(frame, running_task, true)) {
            timer.resumeEarly() catch @panic("Cannot rearm an early RV64 timer");
            return 0; // The interrupted user PC must not advance.
        }
        if (timer.expired()) {
            timer.acknowledge() catch @panic("Cannot acknowledge RV64 timer");
        } else {
            timer.quiesce() catch @panic("Cannot stop invalid RV64 user context");
        }
        context.frame = frame.*; // Save every integer register before dispatch.
        var event: contract.Event = .{
            .kind = contract.event_timer,
            .number = timer.interrupt_number,
            .arg0 = 0,
            .arg1 = 0,
            .arg2 = 0,
            .pc = frame.pc,
            .fault_address = 0,
            .syndrome = frame.cause,
        };
        if (!savedUserFrameValid(frame, running_task, true)) {
            event.kind = contract.event_fault;
            event.number = 0;
            event.fault_address = frame.registers[2];
            event.syndrome = 0;
        }
        var reply: contract.Reply = .{ .action = contract.action_terminate, .result = 0 };
        bedrock_user_dispatch(&event, &reply);
        switch (reply.action) {
            contract.action_suspend => {
                if (event.kind != contract.event_timer) @panic("cannot suspend an RV64 user fault");
                context.state = .runnable;
            },
            contract.action_terminate => context.state = .dead,
            else => @panic("Invalid RV64 timer scheduling reply"),
        }
        return 1;
    }
    if (frame.cause >> 63 != 0) @panic("Unexpected RV64 user interrupt source");
    var event: contract.Event = .{
        .kind = if (frame.cause == 8) contract.event_syscall else contract.event_fault,
        .number = if (frame.cause == 8) frame.registers[17] else frame.cause,
        .arg0 = frame.registers[10],
        .arg1 = frame.registers[11],
        .arg2 = frame.registers[12],
        .pc = frame.pc,
        .fault_address = frame.value,
        .syndrome = frame.cause,
    };
    const syscall = frame.cause == 8 and savedUserFrameValid(frame, running_task, current_context != null);
    if (frame.cause == 8 and !syscall) {
        event.kind = contract.event_fault;
        event.number = 0;
        event.fault_address = frame.registers[2];
        event.syndrome = 0;
    }
    var reply: contract.Reply = undefined;
    bedrock_user_dispatch(&event, &reply);
    if (reply.action == contract.action_terminate) {
        if (current_context) |context| {
            timer.quiesce() catch @panic("Cannot stop terminated RV64 task timer");
            context.frame = frame.*;
            context.state = .dead;
        }
        return 1;
    }
    if (reply.action == contract.action_suspend) {
        if (!syscall) @panic("cannot suspend an RV64 user fault");
        const context = current_context orelse @panic("RV64 suspension needs a saved context");
        if (context.state != .active) @panic("inactive RV64 syscall suspension");
        timer.quiesce() catch @panic("cannot stop suspended RV64 task timer");
        frame.registers[10] = reply.result;
        // ECALL is always 32 bits, including on CPUs supporting compressed ISA.
        const next_pc = @addWithOverflow(frame.pc, @as(u64, 4));
        if (next_pc[1] != 0) @panic("RV64 syscall PC overflow");
        frame.pc = next_pc[0];
        context.frame = frame.*;
        context.state = .runnable;
        return 1;
    }
    if (reply.action != contract.action_resume or !syscall)
        @panic("Invalid RV64 user trap reply");
    frame.registers[10] = reply.result;
    frame.pc += 4;
    return 0;
}
