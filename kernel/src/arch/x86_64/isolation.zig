//! CPL3 execution and timer suspension under kernel-owned page tables.
//! All physical aliases stay supervisor-only; PAT/cache choices come from the
//! live bootstrap leaves. This is a bounded bring-up path, not an SMP scheduler.
const std = @import("std");
const protocol = @import("boot_protocol");
const contract = @import("isolation_contract");
const memory = @import("memory_init");

const page: u64 = 4096;
const large_page: u64 = 0x200000;
const address_mask: u64 = 0x000ffffffffff000;
const present: u64 = 1;
const writable: u64 = 2;
const user: u64 = 4;
const ps: u64 = 1 << 7;
const nx: u64 = 1 << 63;
const user_base: u64 = 0x20_0000_0000;
const user_end = contract.user_window_end;
const max_tables = 256;

extern fn bedrock_arch_cr3() callconv(.c) u64;
extern fn bedrock_x86_nx_supported() callconv(.c) bool;
extern fn bedrock_x86_protect(root: u64) callconv(.c) void;
extern fn bedrock_x86_flush_tlb() callconv(.c) void;
extern fn bedrock_x86_install_gdt(base: u64, limit: u16) callconv(.c) void;
extern fn bedrock_x86_install_isolation_idt() callconv(.c) void;
extern fn bedrock_x86_enter(root: u64, invocation: *const contract.Invocation) callconv(.c) void;
extern fn bedrock_x86_resume(root: u64, frame: *const TrapFrame, fx: *const [512]u8) callconv(.c) void;
extern fn bedrock_x86_leave() callconv(.c) noreturn;
extern fn bedrock_pc_timer_prepare(info: *const protocol.BootInfo) callconv(.c) bool;
extern fn bedrock_pc_timer_arm() callconv(.c) void;
extern fn bedrock_pc_timer_acknowledge() callconv(.c) bool;
extern fn bedrock_pc_timer_stop() callconv(.c) void;
extern fn bedrock_pc_timer_idle_until_tick() callconv(.c) bool;
extern fn bedrock_user_dispatch(event: *const contract.Event, reply: *contract.Reply) callconv(.c) void;
extern var bedrock_x86_program_start: u8;
extern var bedrock_x86_program_end: u8;
extern var bedrock_x86_clean_fx: [512]u8;

var boot: *const protocol.BootInfo = undefined;
var sections: contract.KernelLayout = undefined;
var original_root: u64 = 0;
var kernel_root: u64 = 0;
var physical_limit: u64 = 0;
var trap_guard: u64 = 0;
var emergency_guard: u64 = 0;
var initialized: bool = false;
var running: bool = false;
var running_task: contract.TaskMemory = undefined;
var tss: [104]u8 align(16) = @splat(0);
var gdt: [8]u64 align(16) = @splat(0);
var preemption_ready = false;
const ContextState = enum { ready, suspended, terminated };
const Context = struct {
    space: contract.AddressSpace = .{ .root = 0, .generation = 0 },
    frame: TrapFrame = undefined,
    fx: [512]u8 align(16) = undefined,
    state: ContextState = .ready,
    generation: u32 = 0,
    occupied: bool = false,
    retired: bool = false,
};
const max_contexts = 8;
var contexts: [max_contexts]Context = @splat(.{});
var active_context: ?usize = null;
const max_spaces = 8;
const SpaceState = enum { free, building, live, destroying, retired };
const TableLedger = struct {
    addresses: [max_tables]u64 = undefined,
    count: usize = 0,

    fn release(self: *TableLedger) !void {
        if (self.count == 0) return;
        const allocator = memory.allocator() orelse return error.MemoryNotInitialized;
        // PCID/PGE are disabled by this entry profile and our new leaves have
        // no global bit. A CR3 reload invalidates the translations and paging
        // structure caches before any recorded frame becomes reusable.
        bedrock_x86_flush_tlb();
        while (self.count != 0) {
            const index = self.count - 1;
            try allocator.release(self.addresses[index]);
            self.addresses[index] = 0;
            self.count = index;
        }
    }
};
const Space = struct {
    root: u64 = 0,
    generation: u64 = 0,
    state: SpaceState = .free,
    tables: TableLedger = .{},
    task: contract.TaskMemory = undefined,
};
var spaces: [max_spaces]Space = @splat(.{});
// Root frames can move between slots. Issue generations globally, never wrap,
// so a stale root+generation cannot identify a different later address space.
var next_space_generation: u64 = 1;
var kernel_tables: TableLedger = .{};

const SourceLeaf = struct { physical: u64, bytes: u64, cache: u3 };
const Mapping = struct { physical: u64, bytes: u64, is_user: bool, write: bool, execute: bool, cache: u3 };

fn leafCache(entry: u64, is_large: bool) u3 {
    const pat_bit: u6 = if (is_large) 12 else 7;
    return @as(u3, @intCast((entry >> 3) & 3)) | @as(u3, @intCast(((entry >> pat_bit) & 1) << 2));
}

fn cacheFlags(index: u3, is_large: bool) u64 {
    return (@as(u64, index & 3) << 3) | (@as(u64, index >> 2) << @as(u6, if (is_large) 12 else 7));
}

fn source(address: u64) !SourceLeaf {
    if (address >= physical_limit) return error.AddressOutsideBootstrapMap;
    var table_address = original_root;
    const shifts = [_]u6{ 39, 30, 21, 12 };
    for (shifts, 0..) |shift, level| {
        if (table_address == 0 or !boot.isMapped(.{ .base = table_address, .length = page }))
            return error.InvalidBootstrapTable;
        const entries: [*]const volatile u64 = @ptrFromInt(table_address);
        const entry = entries[@intCast((address >> shift) & 511)];
        if (entry & present == 0) return error.UnmappedBootstrapAddress;
        const is_large = (level == 1 or level == 2) and entry & ps != 0;
        if (is_large or level == 3) {
            const bytes = @as(u64, 1) << @as(u6, if (is_large) shift else 12);
            const physical = (entry & address_mask & ~(bytes - 1)) | (address & (bytes - 1));
            if (physical != address) return error.NonIdentityBootstrapAddress;
            return .{ .physical = physical, .bytes = bytes, .cache = leafCache(entry, is_large) };
        }
        table_address = entry & address_mask;
    }
    return error.InvalidBootstrapTable;
}

const Builder = struct {
    root: u64,
    ledger: *TableLedger,
    table_limit: usize,

    fn init(ledger: *TableLedger, table_limit: usize) !Builder {
        std.debug.assert(ledger.count == 0);
        var result: Builder = .{ .root = 0, .ledger = ledger, .table_limit = table_limit };
        result.root = try result.allocate();
        return result;
    }

    fn table(address: u64) *[512]u64 {
        return @ptrFromInt(address);
    }

    fn allocateTable() !u64 {
        const address = try memory.allocateZeroed();
        errdefer {
            bedrock_x86_flush_tlb();
            const allocator = memory.allocator() orelse @panic("x86 table allocator disappeared");
            allocator.release(address) catch @panic("x86 table allocation rollback failed");
        }
        const cache = (try source(address)).cache;
        // Page walks use their own memory type controls. This named profile
        // requires WB table storage instead of guessing a firmware RAM policy.
        if (cache != 0 and cache != 4) return error.UnsupportedPageTableCache;
        return address;
    }

    fn allocate(self: *Builder) !u64 {
        if (self.ledger.count == self.table_limit) return error.PageTableCapacity;
        const address = try allocateTable();
        self.ledger.addresses[self.ledger.count] = address;
        self.ledger.count += 1;
        return address;
    }

    fn child(self: *Builder, parent: *[512]u64, index: usize, is_user: bool) !*[512]u64 {
        if (parent[index] & present == 0) parent[index] = try self.allocate() | present | writable;
        if (parent[index] & ps != 0) return error.InvalidOwnedPageTable;
        if (is_user) parent[index] |= user;
        return table(parent[index] & address_mask);
    }

    fn directory(self: *Builder, address: u64, is_user: bool) !*[512]u64 {
        const pdpt = try self.child(table(self.root), @intCast((address >> 39) & 511), is_user);
        return self.child(pdpt, @intCast((address >> 30) & 511), is_user);
    }

    fn split(self: *Builder, entry: *u64) !*[512]u64 {
        const old = entry.*;
        const allocated = try self.allocate();
        const entries = table(allocated);
        const base = old & address_mask & ~(large_page - 1);
        const flags = (old & (present | writable | user | nx)) | cacheFlags(leafCache(old, true), false);
        for (entries, 0..) |*leaf, index| leaf.* = base + index * page | flags;
        entry.* = allocated | present | writable | (old & user);
        return entries;
    }

    fn mapLarge(self: *Builder, address: u64, cache: u3) !void {
        const pd = try self.directory(address, false);
        const index: usize = @intCast((address >> 21) & 511);
        if (pd[index] & present != 0) return error.OverlappingBootstrapCoverage;
        pd[index] = address | present | writable | nx | ps | cacheFlags(cache, true);
    }

    fn mapPage(self: *Builder, virtual: u64, physical: u64, permissions: u64, cache: u3) !void {
        const pd = try self.directory(virtual, permissions & user != 0);
        const index: usize = @intCast((virtual >> 21) & 511);
        const pt = if (pd[index] & ps != 0) try self.split(&pd[index]) else try self.child(pd, index, permissions & user != 0);
        if (permissions & user != 0) pd[index] |= user;
        pt[@intCast((virtual >> 12) & 511)] = physical | present | permissions | cacheFlags(cache, false);
    }

    fn coverage(self: *Builder) !void {
        for (boot.mapped_ranges[0..boot.mapped_range_count]) |range| {
            const end = try range.endExclusive();
            if (range.base % page != 0 or end % page != 0) return error.UnalignedBootstrapCoverage;
            var address = range.base;
            while (address < end) {
                const old = try source(address);
                const leaf_end = (address & ~(old.bytes - 1)) + old.bytes;
                const block_end = @min(end, leaf_end);
                while (address < block_end) {
                    if (address % large_page == 0 and block_end - address >= large_page) {
                        try self.mapLarge(address, old.cache);
                        address += large_page;
                    } else {
                        try self.mapPage(address, address, writable | nx, old.cache);
                        address += page;
                    }
                }
            }
        }
    }

    fn protect(self: *Builder, start: u64, end: u64, permissions: u64) !void {
        if (start % page != 0 or end % page != 0 or start > end) return error.InvalidKernelLayout;
        var address = start;
        while (address < end) : (address += page)
            try self.mapPage(address, address, permissions, (try source(address)).cache);
    }

    fn unmap(self: *Builder, address: u64) !void {
        const pd = try self.directory(address, false);
        const index: usize = @intCast((address >> 21) & 511);
        const pt = if (pd[index] & ps != 0) try self.split(&pd[index]) else try self.child(pd, index, false);
        pt[@intCast((address >> 12) & 511)] = 0;
    }

    fn kernel(ledger: *TableLedger, table_limit: usize) !Builder {
        var result = try init(ledger, table_limit);
        errdefer ledger.release() catch @panic("x86 kernel table rollback failed");
        try result.coverage();
        try result.protect(sections.text_start, sections.text_end, 0);
        try result.protect(sections.rodata_start, sections.rodata_end, nx);
        try result.protect(sections.data_start, sections.data_end, writable | nx);
        try result.unmap(sections.stack_guard);
        try result.unmap(trap_guard);
        try result.unmap(emergency_guard);
        return result;
    }
};

fn mapped(root: u64, address: u64) !?Mapping {
    var table_address = root;
    var can_user = true;
    var can_write = true;
    var can_execute = true;
    const shifts = [_]u6{ 39, 30, 21, 12 };
    for (shifts, 0..) |shift, level| {
        if (table_address == 0 or table_address % page != 0 or
            !boot.isMapped(.{ .base = table_address, .length = page })) return error.InvalidOwnedPageTable;
        const entries: *const [512]u64 = @ptrFromInt(table_address);
        const entry = entries[@intCast((address >> shift) & 511)];
        if (entry & present == 0) return null;
        can_user = can_user and entry & user != 0;
        can_write = can_write and entry & writable != 0;
        can_execute = can_execute and entry & nx == 0;
        const is_large = (level == 1 or level == 2) and entry & ps != 0;
        if (is_large or level == 3) {
            const bytes = @as(u64, 1) << @as(u6, if (is_large) shift else 12);
            return .{ .physical = (entry & address_mask & ~(bytes - 1)) | (address & (bytes - 1)), .bytes = bytes, .is_user = can_user, .write = can_write, .execute = can_execute, .cache = leafCache(entry, is_large) };
        }
        table_address = entry & address_mask;
    }
    return error.InvalidOwnedPageTable;
}

fn isGuard(address: u64) bool {
    return address == sections.stack_guard or address == trap_guard or address == emergency_guard;
}

fn auditKernel(root: u64, private_code: ?protocol.PhysicalRange) !void {
    // Audit every retained physical alias, jumping by actual leaf size rather
    // than assuming that a neighboring large block has the same permissions.
    for (boot.mapped_ranges[0..boot.mapped_range_count]) |range| {
        const end = try range.endExclusive();
        var address = range.base;
        while (address < end) {
            if (isGuard(address)) {
                if (try mapped(root, address) != null) return error.MappedKernelGuard;
                address += page;
                continue;
            }
            const found = (try mapped(root, address)) orelse return error.MissingKernelMapping;
            const in_text = address >= sections.text_start and address < sections.text_end;
            const read_only = in_text or (address >= sections.rodata_start and address < sections.rodata_end) or
                (private_code != null and address >= private_code.?.base and address - private_code.?.base < private_code.?.length);
            if (found.physical != address or found.is_user or found.execute != in_text or found.write == read_only or
                found.cache != (try source(address)).cache) return error.InvalidKernelPermissions;
            const next = (address & ~(found.bytes - 1)) + found.bytes;
            address = @min(next, end);
        }
    }
    const guarded = [_]u64{ sections.stack_guard, trap_guard, emergency_guard };
    for (guarded) |address| if (try mapped(root, address) != null) return error.MappedKernelGuard;
}

fn auditUser(root: u64, task: contract.TaskMemory) !void {
    var virtual = user_base;
    while (virtual < user_end) : (virtual += page) {
        const found = try mapped(root, virtual);
        var expected: ?contract.Mapping = null;
        for (task.mappings()) |mapping| {
            if (virtual >= mapping.virtual and virtual - mapping.virtual < @as(u64, mapping.pages) * page) {
                expected = mapping;
                break;
            }
        }
        if (expected) |mapping| {
            const leaf = found orelse return error.MissingUserMapping;
            const physical = mapping.physical + virtual - mapping.virtual;
            if (leaf.physical != physical or leaf.bytes != page or !leaf.is_user or
                leaf.write != mapping.writable or leaf.execute == mapping.writable or
                leaf.cache != (try source(physical)).cache) return error.InvalidUserPermissions;
        } else if (found != null) return error.UnexpectedUserMapping;
    }
    if (try mapped(root, task.guard()) != null) return error.MappedUserGuard;
}

fn setTss64(offset: usize, value: u64) void {
    @as(*align(1) u64, @ptrCast(&tss[offset])).* = value;
}

fn installDescriptors(trap_top: u64, emergency_top: u64) void {
    @memset(&tss, 0);
    setTss64(4, trap_top);
    setTss64(36, emergency_top);
    @as(*align(1) u16, @ptrCast(&tss[102])).* = tss.len;
    gdt = .{ 0, 0, 0x00cf93000000ffff, 0x00af9b000000ffff, 0x00affb000000ffff, 0x00cff3000000ffff, 0, 0 };
    const base = @intFromPtr(&tss);
    gdt[6] = 103 | ((base & 0xffffff) << 16) | (@as(u64, 0x89) << 40) | (((base >> 24) & 0xff) << 56);
    gdt[7] = base >> 32;
    bedrock_x86_install_gdt(@intFromPtr(&gdt), @sizeOf(@TypeOf(gdt)) - 1);
}

pub fn prepare(info: *const protocol.BootInfo, layout: contract.KernelLayout) !void {
    if (initialized) return error.IsolationAlreadyInitialized;
    if (!interruptsMasked() or !translationTagsDisabled()) return error.InvalidIsolationState;
    if (info.boot_environment != @backingInt(protocol.BootEnvironment.uefi) or info.mapped_range_count == 0)
        return error.UnsupportedIsolationEnvironment;
    if (!bedrock_x86_nx_supported()) return error.ExecuteDisableUnavailable;
    if (info.physical_address_bits < 32 or info.physical_address_bits > 52) return error.InvalidPhysicalWidth;
    physical_limit = @min(@as(u64, 1) << 47, @as(u64, 1) << @as(u6, @intCast(info.physical_address_bits)));
    for (info.mapped_ranges[0..info.mapped_range_count]) |range| {
        const end = try range.endExclusive();
        if (range.base < user_end and end > user_base) return error.UserWindowOverlapsPhysicalCoverage;
    }
    if (layout.kernel_start != layout.text_start or layout.text_start >= layout.text_end or
        layout.text_end != layout.rodata_start or layout.rodata_start > layout.rodata_end or
        layout.rodata_end != layout.data_start or layout.data_start > layout.data_end or
        layout.data_end > layout.stack_guard or layout.stack_guard + page != layout.stack_bottom or
        layout.stack_bottom >= layout.stack_top or layout.stack_top != layout.allocated_end or
        layout.kernel_start != info.kernel_reserved.base or layout.allocated_end > try info.kernel_reserved.endExclusive())
        return error.InvalidKernelLayout;
    boot = info;
    sections = layout;
    original_root = bedrock_arch_cr3() & address_mask;
    const allocator = memory.allocator() orelse return error.MemoryNotInitialized;
    const trap = (try allocator.allocateContiguous(9, 1)) orelse return error.OutOfMemory;
    errdefer allocator.releaseContiguous(trap) catch @panic("x86 trap stack rollback failed");
    const emergency = (try allocator.allocateContiguous(3, 1)) orelse return error.OutOfMemory;
    errdefer allocator.releaseContiguous(emergency) catch @panic("x86 emergency stack rollback failed");
    trap_guard = trap.base;
    emergency_guard = emergency.base;
    @memset(@as([*]u8, @ptrFromInt(trap.base))[0..@intCast(trap.length)], 0);
    @memset(@as([*]u8, @ptrFromInt(emergency.base))[0..@intCast(emergency.length)], 0);
    const builder = try Builder.kernel(&kernel_tables, max_tables);
    errdefer kernel_tables.release() catch @panic("x86 permanent table rollback failed");
    kernel_root = builder.root;
    errdefer kernel_root = 0;
    try auditKernel(kernel_root, null);
    installDescriptors(trap.base + trap.length, emergency.base + emergency.length);
    bedrock_x86_install_isolation_idt();
    bedrock_x86_protect(kernel_root);
    initialized = true;
}

pub fn create(task: contract.TaskMemory) !contract.AddressSpace {
    return createWithTableLimit(task, max_tables);
}

/// Bounded allocation cap for rollback probes. Every allocation, including
/// the root and split tables, consumes the supplied table budget.
pub fn createWithTableLimit(task: contract.TaskMemory, table_limit: usize) !contract.AddressSpace {
    try lifecycleReady();
    if (table_limit > max_tables) return error.InvalidPageTableCapacity;
    if (next_space_generation == 0) return error.AddressSpaceGenerationExhausted;
    try task.validate();
    for (task.mappings()) |mapping| {
        const range: protocol.PhysicalRange = .{ .base = mapping.physical, .length = @as(u64, mapping.pages) * page };
        if (!boot.isMapped(range) or try range.endExclusive() > physical_limit) return error.InvalidTaskMemory;
        for (0..mapping.pages) |index| _ = try source(mapping.physical + index * page);
    }
    const owned: *Space = for (&spaces) |*candidate| {
        if (candidate.state == .free) break candidate;
    } else return error.AddressSpaceCapacity;
    owned.state = .building;
    errdefer {
        owned.tables.release() catch @panic("x86 address space rollback failed");
        owned.root = 0;
        owned.generation = 0;
        owned.state = .free;
    }
    var builder = try Builder.kernel(&owned.tables, table_limit);
    for (task.mappings()) |mapping| {
        for (0..mapping.pages) |index| {
            const physical = mapping.physical + index * page;
            const cache = (try source(physical)).cache;
            if (!mapping.writable) try builder.mapPage(physical, physical, nx, cache);
            try builder.mapPage(mapping.virtual + index * page, physical, user | (if (mapping.writable) writable | nx else 0), cache);
        }
    }
    try auditKernel(builder.root, .{ .base = task.code, .length = @as(u64, task.code_pages) * page });
    try auditUser(builder.root, task);
    asm volatile ("mfence" ::: .{ .memory = true });
    owned.root = builder.root;
    owned.task = task;
    owned.generation = next_space_generation;
    next_space_generation = if (next_space_generation == std.math.maxInt(u64)) 0 else next_space_generation + 1;
    owned.state = .live;
    return .{ .root = owned.root, .generation = owned.generation };
}

fn findSpace(space: contract.AddressSpace, allow_destroying: bool) !*Space {
    if (space.root == 0 or space.root == kernel_root or space.root % page != 0 or space.generation == 0)
        return error.InvalidAddressSpace;
    for (&spaces) |*owned| {
        if (owned.root == space.root and owned.generation == space.generation and
            (owned.state == .live or (allow_destroying and owned.state == .destroying))) return owned;
    }
    return error.StaleAddressSpace;
}

/// Release this space's independently owned table frames. Task payload pages,
/// permanent kernel tables, and kernel trap stacks belong to other owners.
pub fn destroy(space: contract.AddressSpace) !void {
    try lifecycleReady();
    const owned = try findSpace(space, true);
    for (&contexts) |*context| {
        if (context.occupied and context.space.root == space.root and context.space.generation == space.generation)
            return error.AddressSpaceHasContexts;
    }
    // An allocator error leaves the slot quarantined and its remaining ledger
    // intact. Only destroy may retry; run/createContext cannot use partial trees.
    owned.state = .destroying;
    try owned.tables.release();
    owned.root = 0;
    owned.generation = 0;
    owned.state = if (next_space_generation == 0) .retired else .free;
}

pub fn programBytes() []const u8 {
    const start = @intFromPtr(&bedrock_x86_program_start);
    const end = @intFromPtr(&bedrock_x86_program_end);
    std.debug.assert(end > start and end - start <= page);
    return @as([*]const u8, @ptrFromInt(start))[0 .. end - start];
}

pub fn run(space: contract.AddressSpace, invocation: contract.Invocation) void {
    lifecycleReady() catch @panic("invalid x86 address space entry state");
    const owned = findSpace(space, false) catch @panic("stale x86 address space entry");
    std.debug.assert(!owned.task.desktop and invocation.entry == user_base and invocation.user_sp > contract.user_stack and invocation.user_sp <= contract.user_stack_top);
    running_task = owned.task;
    running = true;
    bedrock_x86_enter(space.root, &invocation);
    running = false;
}

fn interruptsMasked() bool {
    const flags = asm volatile ("pushfq; popq %[flags]"
        : [flags] "=r" (-> u64),
        :
        : .{ .memory = true });
    return flags & (1 << 9) == 0;
}

fn translationTagsDisabled() bool {
    const cr4 = asm volatile ("movq %%cr4, %[value]"
        : [value] "=r" (-> u64),
    );
    return cr4 & ((1 << 7) | (1 << 17)) == 0;
}

fn lifecycleReady() !void {
    if (!initialized) return error.IsolationNotInitialized;
    if (running or active_context != null) return error.ActiveAddressSpace;
    if (!interruptsMasked() or !translationTagsDisabled() or bedrock_arch_cr3() & address_mask != kernel_root)
        return error.InvalidAddressSpaceState;
}

pub fn preparePreemption(info: *const protocol.BootInfo) !void {
    if (!initialized or running or !interruptsMasked()) return error.InvalidPreemptionState;
    if (preemption_ready) return error.PreemptionAlreadyInitialized;
    if (!bedrock_pc_timer_prepare(info)) return error.UnsupportedPreemptionTimer;
    preemption_ready = true;
}

pub fn createContext(space: contract.AddressSpace, invocation: contract.Invocation) !contract.ContextHandle {
    try lifecycleReady();
    if (!preemption_ready) return error.InvalidPreemptionState;
    const owned = try findSpace(space, false);
    const index: usize = for (&contexts, 0..) |*candidate, candidate_index| {
        if (!candidate.occupied and !candidate.retired) break candidate_index;
    } else return error.ContextRegistryFull;
    // x86 instructions have byte alignment; the loader validates the ELF entry.
    if (invocation.entry < owned.task.codeVirtual() or invocation.entry >= owned.task.codeEnd() or
        invocation.user_sp != owned.task.stackTop())
        return error.InvalidUserContext;
    // Do not accept an unaudited root merely because its physical address is
    // accessible. Check supervisor aliases and the three actual user leaves.
    try auditKernel(space.root, .{ .base = owned.task.code, .length = @as(u64, owned.task.code_pages) * page });
    try auditUser(space.root, owned.task);
    const context = &contexts[index];
    context.space = space;
    context.frame = .{
        .r15 = 0,
        .r14 = 0,
        .r13 = 0,
        .r12 = 0,
        .r11 = 0,
        .r10 = 0,
        .r9 = 0,
        .r8 = 0,
        .rbp = 0,
        .rdi = invocation.arg0,
        .rsi = invocation.arg1,
        .rdx = invocation.arg2,
        .rcx = 0,
        .rbx = 0,
        .rax = 0,
        .vector = 0,
        .error_code = 0,
        .rip = invocation.entry,
        .cs = 0x23,
        .rflags = 0x202,
        .rsp = invocation.user_sp,
        .ss = 0x2b,
    };
    context.fx = bedrock_x86_clean_fx;
    context.state = .ready;
    if (context.generation == 0) context.generation = 1;
    context.occupied = true;
    return @fromBackingInt((@as(u64, context.generation) << 32) | @as(u64, index + 1));
}

fn contextIndex(handle: contract.ContextHandle) !usize {
    const value = @backingInt(handle);
    const slot: u32 = @truncate(value);
    const generation: u32 = @intCast(value >> 32);
    if (slot == 0 or slot > max_contexts or generation == 0) return error.InvalidContextHandle;
    const index: usize = slot - 1;
    const context = &contexts[index];
    if (!context.occupied or context.retired or context.generation != generation)
        return error.StaleContextHandle;
    _ = findSpace(context.space, false) catch return error.StaleContextHandle;
    return index;
}

/// Validate a kernel-only token without entering CPL3. Destroyed/reused slots
/// cannot resolve through their old generation, and terminated tasks cannot run.
pub fn validateContext(handle: contract.ContextHandle) !void {
    try lifecycleReady();
    if (!preemption_ready) return error.InvalidPreemptionState;
    const index = try contextIndex(handle);
    const context = &contexts[index];
    if (context.state == .terminated) return error.ContextTerminated;
    const owned = try findSpace(context.space, false);
    if (!savedUserFrameValid(&context.frame, owned.task, false, true)) return error.InvalidUserContext;
}

/// Trusted wakeup result for an inactive saved context. Scheduling policy owns
/// whether that context is blocked or eligible to resume.
pub fn setContextResult(handle: contract.ContextHandle, result: u64) !void {
    if (running or active_context != null) return error.ActiveContext;
    try lifecycleReady();
    if (!preemption_ready) return error.InvalidPreemptionState;
    const index = try contextIndex(handle);
    if (contexts[index].state == .terminated) return error.ContextTerminated;
    contexts[index].frame.rax = result;
}

/// Wait for a real platform timer expiry without enabling kernel interrupts.
/// This masked polling path provides no CPU power-saving or fake timer event.
pub fn idleUntilTick() !void {
    try lifecycleReady();
    if (!preemption_ready) return error.InvalidPreemptionState;
    if (!bedrock_pc_timer_idle_until_tick()) return error.TimerWaitFailed;
}

/// A context owns saved registers, not table or payload frames. Destroy it
/// before destroying the referenced address space.
pub fn destroyContext(handle: contract.ContextHandle) !void {
    try lifecycleReady();
    const index = try contextIndex(handle);
    const context = &contexts[index];
    @memset(std.mem.asBytes(&context.frame), 0);
    @memset(&context.fx, 0);
    context.space = .{ .root = 0, .generation = 0 };
    context.state = .terminated;
    context.occupied = false;
    if (context.generation == std.math.maxInt(u32)) {
        context.retired = true;
    } else {
        context.generation += 1;
    }
}

pub fn resumeContext(handle: contract.ContextHandle) void {
    lifecycleReady() catch @panic("invalid x86 context resume state");
    if (!preemption_ready) @panic("x86 preemption is not initialized");
    const index = contextIndex(handle) catch @panic("stale x86 context resume");
    const context = &contexts[index];
    if (context.state == .terminated) @panic("terminated x86 context resume");
    const owned = findSpace(context.space, false) catch @panic("stale x86 context space");
    running_task = owned.task;
    active_context = index;
    running = true;
    bedrock_pc_timer_arm();
    bedrock_x86_resume(context.space.root, &context.frame, &context.fx);
    std.debug.assert(interruptsMasked());
    running = false;
    active_context = null;
}

pub fn validateFault(probe: contract.Probe, event: contract.Event) !void {
    if (event.kind != contract.event_fault or event.number != 14 or event.syndrome & 8 != 0)
        return error.InvalidProtectionFault;
    // Match Present/Write/User/Instruction bits. Other optional architectural
    // flags do not substitute for the required page-protection cause.
    const expected: u64 = switch (probe) {
        .kernel_read, .peer_read => 1 | 4,
        .code_write => 1 | 2 | 4,
        .stack_execute => 1 | 4 | 16,
        .guard_read => 4,
        .normal, .spin => return error.InvalidProtectionProbe,
    };
    if (event.syndrome & 0x17 != expected) return error.InvalidProtectionFault;
}

/// The ISR wrapper retains this fixed frame on a supervisor TSS stack. Only
/// RAX is changed for resumed syscalls; all user GPR/FPU state is restored.
const TrapFrame = extern struct {
    r15: u64,
    r14: u64,
    r13: u64,
    r12: u64,
    r11: u64,
    r10: u64,
    r9: u64,
    r8: u64,
    rbp: u64,
    rdi: u64,
    rsi: u64,
    rdx: u64,
    rcx: u64,
    rbx: u64,
    rax: u64,
    vector: u64,
    error_code: u64,
    rip: u64,
    cs: u64,
    rflags: u64,
    rsp: u64,
    ss: u64,
};

fn savedUserFrameValid(frame: *const TrapFrame, task: contract.TaskMemory, allow_code_end: bool, interrupts_enabled: bool) bool {
    // These bounded intervals lie in the canonical lower half. x86 permits
    // byte-aligned instructions and stacks; saved application values are not
    // trusted merely because their owning context handle is valid.
    const code_end = task.codeEnd();
    const required_flags: u64 = if (interrupts_enabled) 0x202 else 2;
    return frame.rip >= task.codeVirtual() and
        (frame.rip < code_end or (allow_code_end and frame.rip == code_end)) and
        frame.rsp >= task.stackVirtual() and frame.rsp <= task.stackTop() and
        frame.cs == 0x23 and frame.ss == 0x2b and
        frame.rflags & ((3 << 12) | (1 << 14) | (1 << 17) | (1 << 19) | (1 << 20)) == 0 and
        frame.rflags & required_flags == required_flags;
}

export fn bedrock_x86_isolation_trap(frame: *TrapFrame, fx_state: *const [512]u8) callconv(.c) bool {
    if (frame.cs & 3 != 3) return false;
    if (!running) unreachable;
    const is_timer = frame.vector == 32;
    var is_syscall = frame.vector == 128;
    if (is_timer and (active_context == null or frame.cs != 0x23 or frame.ss != 0x2b or
        frame.error_code != 0 or frame.rflags & (1 << 9) == 0 or !bedrock_pc_timer_acknowledge())) unreachable;
    var event: contract.Event = .{
        .kind = if (is_timer) contract.event_timer else if (is_syscall) contract.event_syscall else contract.event_fault,
        .number = if (is_timer) 0 else if (is_syscall) frame.rax else frame.vector,
        .arg0 = if (is_timer) 0 else frame.rdi,
        .arg1 = if (is_timer) 0 else frame.rsi,
        .arg2 = if (is_timer) 0 else frame.rdx,
        .pc = frame.rip,
        .fault_address = if (is_timer) 0 else if (frame.vector == 14) asm ("movq %%cr2, %[value]"
            : [value] "=r" (-> u64),
        ) else frame.rip,
        .syndrome = frame.error_code,
    };
    if ((is_timer or is_syscall) and !savedUserFrameValid(frame, running_task, is_syscall, active_context != null)) {
        // A noncanonical IRET stack can fault at CPL0. Reject invalid saved
        // user registers through the ordinary task-fault policy before any
        // dispatcher reply could restore them. A trailing syscall PC may still
        // return directly to the NX data page and fault safely at CPL3.
        event.kind = contract.event_fault;
        event.number = 13;
        event.fault_address = if (frame.rsp < running_task.stackVirtual() or frame.rsp > running_task.stackTop()) frame.rsp else frame.rip;
        event.syndrome = 0;
        is_syscall = false;
    }
    var reply: contract.Reply = .{ .action = 1, .result = 0 };
    bedrock_user_dispatch(&event, &reply);
    if (reply.action == contract.action_suspend) {
        if (event.kind == contract.event_fault) @panic("cannot suspend an x86 user fault");
        const index = active_context orelse @panic("x86 suspension needs a saved context");
        const context = &contexts[index];
        context.frame = frame.*;
        context.fx = fx_state.*;
        // INT80 already records the following instruction. Store its result
        // before leaving so wakeup resumes after the call exactly once.
        if (is_syscall) {
            context.frame.rax = reply.result;
            bedrock_pc_timer_stop();
        }
        // Restore arithmetic/DF/debug flags, while privilege-control bits
        // cannot be carried into a fresh kernel IRET operation by an app.
        context.frame.rflags &= ~@as(u64, (3 << 12) | (1 << 14) | (1 << 17) | (1 << 19) | (1 << 20));
        context.frame.rflags |= 0x202;
        context.state = .suspended;
        bedrock_x86_leave();
    }
    if (reply.action == contract.action_terminate) {
        if (active_context) |index| {
            contexts[index].state = .terminated;
            bedrock_pc_timer_stop();
        }
        bedrock_x86_leave();
    }
    if (reply.action != contract.action_resume or !is_syscall)
        @panic("invalid x86 user dispatcher reply");
    frame.rax = reply.result;
    return true;
}

comptime {
    if (@sizeOf(TrapFrame) != 176 or @offsetOf(TrapFrame, "vector") != 120 or @offsetOf(TrapFrame, "cs") != 144)
        @compileError("x86 isolation trap frame layout changed");
    if (@offsetOf(Context, "fx") % 16 != 0)
        @compileError("x86 context FXSAVE image must be aligned");
}
