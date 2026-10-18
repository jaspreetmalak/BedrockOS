//! Owned EL1 stage-1 translation and a deliberately small EL0 probe boundary.
//! One CPU, protected cooperative probes and bounded timer-suspended contexts.
const protocol = @import("boot_protocol");
const memory = @import("memory_init");
const contract = @import("isolation_contract");
const timer = @import("timer.zig");

const page: u64 = contract.page_size;
const block: u64 = 2 * 1024 * 1024;
const address_mask: u64 = 0x0000_ffff_ffff_f000;
const af: u64 = 1 << 10;
const ap_user: u64 = 1 << 6;
const ap_readonly: u64 = 1 << 7;
const pxn: u64 = 1 << 53;
const uxn: u64 = 1 << 54;
const inner_shareable: u64 = 3 << 8;
const normal_wb: u64 = 1 << 2;
const normal_nc: u64 = 2 << 2;
const normal_wt: u64 = 3 << 2;
const supervisor_rw: u64 = af | inner_shareable | normal_wb | pxn | uxn;
const supervisor_ro: u64 = supervisor_rw | ap_readonly;
const supervisor_rx: u64 = af | inner_shareable | normal_wb | ap_readonly | uxn;
const device_rw: u64 = af | pxn | uxn;
const user_rx: u64 = af | inner_shareable | normal_wb | ap_user | ap_readonly | pxn | (1 << 11);
const user_rw: u64 = af | inner_shareable | normal_wb | ap_user | pxn | uxn | (1 << 11);
const user_ro: u64 = user_rx | uxn;

fn userAttributes(mapping: contract.Mapping) u64 {
    return if (mapping.executable) user_rx else if (mapping.writable) user_rw else user_ro;
}
const max_table_pages = 2048;
const max_spaces = 8;
// Core tasks need four private tables. Surface slots add owned L3 tables lazily.
const max_private_tables = 32;
const SpaceState = enum { vacant, building, live };
const SpaceRecord = struct {
    state: SpaceState = .vacant,
    generation: u64 = 0,
    root: u64 = 0,
    tables: [max_private_tables]u64 = undefined,
    table_count: usize = 0,
    task: contract.TaskMemory = undefined,
    table_limit: usize = max_private_tables,
    shared: [contract.shared_surface_slots]contract.SharedMapping = @splat(.{}),
    shared_tables: [contract.shared_surface_slots][2]u64 = @splat(@splat(0)),
};
const ContextRecord = struct {
    generation: u32 = 1,
    occupied: bool = false,
    retired: bool = false,
    context: Context = undefined,
};

var kernel_root: u64 = 0;
var prepared = false;
var active = false;
var active_task: contract.TaskMemory = undefined;
var physical_limit: u64 = 0;
var kernel_layout: contract.KernelLayout = undefined;
var boot_info: *const protocol.BootInfo = undefined;
var table_pages: [max_table_pages]u64 = undefined;
var table_count: usize = 0;
var spaces: [max_spaces]SpaceRecord = @splat(.{});
// The root page may migrate between slots after recycling. A global serial
// prevents root+generation collisions across different registry slots.
var next_space_generation: u64 = 1;
var preemption_ready = false;
var contexts: [max_spaces]ContextRecord = @splat(.{});
var active_context: ?*Context = null;

extern fn bedrock_arch_memory_features() callconv(.c) u64;
extern fn bedrock_arch_translation_state() callconv(.c) u64;
extern fn bedrock_arm_enable_mmu(root: u64, tcr: u64) callconv(.c) void;
extern fn bedrock_arm_publish_code(address: u64, length: u64) callconv(.c) void;
extern fn bedrock_arm_run_user(root: u64, invocation: *const contract.Invocation) callconv(.c) void;
extern fn bedrock_arm_finish_user() callconv(.c) noreturn;
extern fn bedrock_arm_current_ttbr() callconv(.c) u64;
extern fn bedrock_arm_current_cpacr() callconv(.c) u64;
extern fn bedrock_arm_current_sp() callconv(.c) u64;
extern fn bedrock_arm_current_user_sp() callconv(.c) u64;
extern fn bedrock_arm_current_daif() callconv(.c) u64;
extern fn bedrock_arm_current_cntkctl() callconv(.c) u64;
extern fn bedrock_arm_refresh_tables() callconv(.c) void;
extern fn bedrock_arm_retire_tables() callconv(.c) void;
extern fn bedrock_arm_resume_user(root: u64, frame: *const TrapFrame, pc: u64, user_sp: u64, deadline: u64) callconv(.c) void;
extern fn bedrock_arm_timer_arm(deadline: u64) callconv(.c) void;
extern fn bedrock_user_dispatch(event: *const contract.Event, reply: *contract.Reply) callconv(.c) void;
extern var bedrock_arm_user_program_start: u8;
extern var bedrock_arm_user_program_end: u8;

/// The raw EFI cache capabilities distinguish normal RAM from device mappings;
/// the normalized map controls ownership, while explicit coverage bounds access.
pub fn prepare(info: *const protocol.BootInfo, layout: contract.KernelLayout) !void {
    if (prepared or kernel_root != 0) return error.IsolationAlreadyInitialized;
    if (info.boot_environment != @backingInt(protocol.BootEnvironment.uefi) or
        info.entry_state != @backingInt(protocol.EntryState.aarch64_el1) or
        bedrock_arch_translation_state() & ((1 << 0) | (1 << 2) | (1 << 12)) != 0)
        return error.UnexpectedIsolationEntry;
    const features = bedrock_arch_memory_features();
    const pa_encoding = features & 15;
    if ((features >> 28) & 15 != 0 or pa_encoding > 5) return error.UnsupportedTranslationFormat;
    const pa_bits: u6 = switch (pa_encoding) {
        0 => 32,
        1 => 36,
        2 => 40,
        3 => 42,
        4 => 44,
        5 => 48,
        else => unreachable,
    };
    physical_limit = @as(u64, 1) << pa_bits;
    if (info.physical_address_bits > pa_bits or info.mapped_range_count == 0 or
        info.mapped_range_count > protocol.max_mapped_ranges) return error.InvalidPhysicalCoverage;
    for (info.mapped_ranges[0..info.mapped_range_count]) |range| {
        const end = try range.endExclusive();
        if (range.length == 0 or end > physical_limit or
            overlaps(range.base, end, contract.user_base, contract.user_window_end))
            return error.UserWindowOverlapsPhysicalCoverage;
    }
    try validateLayout(info, layout);
    boot_info = info;
    kernel_layout = layout;
    kernel_root = try newTable();

    if (info.firmware_descriptor_size < 40 or info.firmware_memory_map.length == 0 or
        info.firmware_memory_map.length % info.firmware_descriptor_size != 0)
        return error.InvalidFirmwareMemoryMap;
    const raw: [*]const u8 = @ptrFromInt(info.firmware_memory_map.base);
    const count = info.firmware_memory_map.length / info.firmware_descriptor_size;
    if (count > 8192) return error.TooManyFirmwareDescriptors;
    for (0..@intCast(count)) |i| {
        const offset = i * @as(usize, info.firmware_descriptor_size);
        const kind = readLittle(raw + offset, 4);
        // UEFI RAM, including retained firmware and ACPI RAM, is EL1-only.
        if (!(kind >= 1 and kind <= 7) and kind != 9 and kind != 10) continue;
        const start = readLittle(raw + offset + 8, 8);
        const pages = readLittle(raw + offset + 24, 8);
        const size = @mulWithOverflow(pages, page);
        const sum = @addWithOverflow(start, size[0]);
        if (pages == 0 or start % page != 0 or size[1] != 0 or sum[1] != 0 or sum[0] > physical_limit)
            return error.InvalidFirmwareDescriptor;
        const attributes = readLittle(raw + offset + 32, 8);
        const cache: u64 = if (attributes & 8 != 0) normal_wb else if (attributes & 4 != 0) normal_wt else if (attributes & 3 != 0) normal_nc else return error.UnsupportedRamCachePolicy;
        for (info.mapped_ranges[0..info.mapped_range_count]) |coverage| {
            const begin = @max(start, coverage.base);
            const end = @min(sum[0], try coverage.endExclusive());
            if (begin >= end) continue;
            // Only whole owned-accessible pages become page-table leaves.
            const aligned_start = try alignUp(begin);
            const aligned_end = end & ~(page - 1);
            if (aligned_start < aligned_end)
                try mapRange(kernel_root, aligned_start, aligned_end, af | inner_shareable | cache | pxn | uxn);
        }
    }

    if (info.console.kind == @backingInt(protocol.ConsoleKind.pl011))
        try mapDevice(info, info.console.base, 0x48, device_rw);
    try mapDevice(info, 0x0a000000, 0x4000, device_rw);
    try mapDevice(info, 0x09000000, 0x1000, device_rw);
    if (info.framebuffer.size != 0) {
        // A RAM-backed GOP surface is non-cacheable normal memory. A device
        // aperture remains Device; either case is writable only from EL1.
        const existing = descriptor(kernel_root, info.framebuffer.base);
        const attributes: u64 = if (existing != null and ((existing.? >> 2) & 7) != 0)
            af | inner_shareable | normal_nc | pxn | uxn
        else
            device_rw;
        try mapDevice(info, info.framebuffer.base, info.framebuffer.size, attributes);
    }
    try protectRange(layout.text_start, layout.text_end, supervisor_rx);
    try protectRange(layout.rodata_start, layout.rodata_end, supervisor_ro);
    try protectRange(layout.data_start, layout.data_end, supervisor_rw);
    if (info.apps.reservation.length != 0)
        try protectRange(info.apps.reservation.base, try info.apps.reservation.endExclusive(), supervisor_ro);
    for (info.drivers.records[0..info.drivers.count]) |driver|
        for (driver.segments[0..driver.segment_count]) |segment|
            try protectRange(segment.range.base, try segment.range.endExclusive(), if (segment.flags & 1 != 0) supervisor_rx else if (segment.flags & 2 != 0) supervisor_rw else supervisor_ro);
    try protectRange(layout.stack_bottom, layout.stack_top, supervisor_rw);
    try replacePage(kernel_root, layout.stack_guard, 0);
    try audit(kernel_root, false);
    try auditKernel(kernel_root);
    // Cache publication precedes enabling both translation and caches. Firmware
    // handed us clean, disabled caches; all table pages are allocator-owned RAM.
    const tcr: u64 = 16 | (1 << 8) | (1 << 10) | (3 << 12) |
        (@as(u64, 16) << 16) | (1 << 23) | (@as(u64, 2) << 30) | (pa_encoding << 32);
    bedrock_arm_enable_mmu(kernel_root, tcr);
    prepared = true;
}

pub fn create(frames: contract.TaskMemory) !contract.AddressSpace {
    return createWithTableLimit(frames, max_private_tables);
}

/// A bounded allocation ceiling also exercises rollback of each private-table
/// prefix. The fixed address-space layout always needs all four pages.
pub fn createWithTableLimit(frames: contract.TaskMemory, table_limit: usize) !contract.AddressSpace {
    if (!prepared or active) return error.IsolationNotReady;
    checkKernelContinuation();
    const record = vacantSpace() orelse return error.AddressSpaceCapacity;
    if (next_space_generation == 0) return error.AddressSpaceGenerationExhausted;
    try frames.validate();
    for (frames.allMappings()) |mapping| {
        if (mapping.pages == 0) continue;
        const bytes = @as(u64, mapping.pages) * page;
        if (mapping.physical + bytes > physical_limit or !boot_info.isMapped(.{ .base = mapping.physical, .length = bytes })) return error.InvalidUserPhysicalFrame;
        if (boot_info.apps.reservation.length != 0 and overlaps(mapping.physical, mapping.physical + bytes, boot_info.apps.reservation.base, try boot_info.apps.reservation.endExclusive())) return error.AppArchiveCannotBackUserMemory;
        for (0..mapping.pages) |offset| {
            const address = mapping.physical + offset * page;
            const alias = descriptor(kernel_root, address) orelse return error.UserFrameNotIdentityMapped;
            if (alias & (ap_user | ap_readonly) != 0 or alias & (pxn | uxn) != (pxn | uxn) or
                (alias >> 2) & 7 != 1) return error.InvalidUserPhysicalAlias;
        }
    }
    record.generation = next_space_generation;
    record.task = frames;
    record.table_limit = @min(table_limit, max_private_tables);
    record.shared = @splat(.{});
    record.shared_tables = @splat(@splat(0));
    record.state = .building;
    errdefer rollbackSpace(record);
    const root = try newSpaceTable(record, table_limit);
    record.root = root;
    @memcpy(table(root), table(kernel_root));
    // 128 GiB shares L0[0] with low physical RAM, so copy its L1 before
    // inserting the private user branch. All EL1-only lower trees are shared.
    const l0_index = index(contract.user_base, 0);
    const old_l0 = table(root)[l0_index];
    if (old_l0 & 3 != 3) return error.MissingKernelIdentityTree;
    const private_l1 = try newSpaceTable(record, table_limit);
    @memcpy(table(private_l1), table(old_l0 & address_mask));
    table(root)[l0_index] = private_l1 | 3;
    if (table(private_l1)[index(contract.user_base, 1)] != 0) return error.UserWindowAlreadyMapped;
    const private_l2 = try newSpaceTable(record, table_limit);
    const private_l3 = try newSpaceTable(record, table_limit);
    table(private_l1)[index(contract.user_base, 1)] = private_l2 | 3;
    table(private_l2)[index(contract.user_base, 2)] = private_l3 | 3;
    for (frames.allMappings()) |mapping| {
        for (0..mapping.pages) |offset| {
            table(private_l3)[index(mapping.virtual + offset * page, 3)] = mapping.physical + offset * page |
                userAttributes(mapping) | 3;
        }
    }
    try audit(root, true);
    try auditKernel(root);
    if (descriptor(root, frames.guard()) != null) return error.UserGuardMapped;
    for (frames.allMappings()) |mapping| {
        for (0..mapping.pages) |offset| try expectLeaf(root, mapping.virtual + offset * page, mapping.physical + offset * page, userAttributes(mapping));
    }
    bedrock_arm_publish_code(frames.code, @as(u64, frames.code_pages) * page);
    bedrock_arm_refresh_tables();
    record.state = .live;
    next_space_generation = if (next_space_generation == ~@as(u64, 0)) 0 else next_space_generation + 1;
    return .{ .root = root, .generation = record.generation };
}

fn sharedReady() !void {
    if (!prepared or active or active_context != null or bedrock_arm_current_ttbr() != kernel_root or
        (preemption_ready and !timer.isQuiescent())) return error.ActiveAddressSpace;
    checkKernelContinuation();
}
fn sharedBacking(physical: u64, pages: u16) !void {
    try contract.validateSharedBacking(boot_info, physical, pages);
    const allocator = memory.allocator() orelse return error.MemoryNotInitialized;
    try contract.validateSharedAllocation(allocator, physical, pages);
    const bytes = @as(u64, pages) * page;
    if (physical + bytes > physical_limit) return error.InvalidSharedBacking;
    for (table_pages[0..table_count]) |address|
        if (contract.physicalOverlap(physical, bytes, address, page)) return error.ProtectedSharedBacking;
    for (&spaces) |*candidate| {
        if (candidate.state != .building and candidate.state != .live) continue;
        for (candidate.tables[0..candidate.table_count]) |address|
            if (contract.physicalOverlap(physical, bytes, address, page)) return error.ProtectedSharedBacking;
        for (candidate.task.allMappings()) |mapping|
            if (contract.physicalOverlap(physical, bytes, mapping.physical, @as(u64, mapping.pages) * page)) return error.ProtectedSharedBacking;
    }
    for (0..pages) |offset| {
        const address = physical + offset * page;
        const alias = descriptor(kernel_root, address) orelse return error.InvalidSharedBacking;
        if (alias & (ap_user | ap_readonly) != 0 or alias & (pxn | uxn) != pxn | uxn or (alias >> 2) & 7 != 1)
            return error.InvalidSharedPhysicalAlias;
    }
}
fn auditShared(record: *const SpaceRecord) !void {
    try audit(record.root, true);
    try auditKernel(record.root);
    for (record.shared, 0..) |item, slot| {
        if (item.pages == 0) continue;
        const mapping = try item.mapping(slot);
        for (0..mapping.pages) |offset|
            try expectLeaf(record.root, mapping.virtual + offset * page, mapping.physical + offset * page, userAttributes(mapping));
    }
}
fn releaseSharedTable(record: *SpaceRecord, address: u64) !void {
    const at = for (record.tables[0..record.table_count], 0..) |owned, offset| {
        if (owned == address and offset >= 4) break offset;
    } else return error.InvalidPrivateTableLedger;
    try memory.allocator().?.release(address);
    @import("std").mem.copyForwards(u64, record.tables[at .. record.table_count - 1], record.tables[at + 1 .. record.table_count]);
    record.table_count -= 1;
    record.tables[record.table_count] = 0;
}

pub fn mapShared(space: contract.AddressSpace, slot: usize, physical: u64, pages: u16, writable_mapping: bool) !void {
    try sharedReady();
    const item = try contract.SharedMapping.init(slot, physical, pages, writable_mapping);
    const mapping = try item.mapping(slot);
    const record = spaceRecord(space) orelse return error.InvalidAddressSpace;
    if (record.shared[slot].pages != 0) return error.SharedSlotOccupied;
    try sharedBacking(physical, pages);
    try synchronizeKernelMappings(record);
    const directory = table(record.tables[2]);
    const first = index(mapping.virtual, 2);
    const needed: usize = if (pages > 512) 2 else 1;
    if (record.table_count + needed > record.table_limit) return error.PageTableCapacity;
    for (0..needed) |offset| if (directory[first + offset] != 0) return error.SharedWindowAlreadyMapped;
    const checkpoint = record.table_count;
    var allocated: [2]u64 = @splat(0);
    var published = false;
    errdefer {
        if (published) {
            for (0..needed) |offset| directory[first + offset] = 0;
            record.shared[slot] = .{};
            record.shared_tables[slot] = @splat(0);
        }
        bedrock_arm_retire_tables();
        while (record.table_count > checkpoint) {
            record.table_count -= 1;
            releaseTable(record.tables[record.table_count]);
            record.tables[record.table_count] = 0;
        }
    }
    for (0..needed) |offset| allocated[offset] = try newSpaceTable(record, record.table_limit);
    for (0..pages) |offset|
        table(allocated[offset / 512])[offset % 512] = physical + offset * page | userAttributes(mapping) | 3;
    for (allocated[0..needed], 0..) |address, offset| directory[first + offset] = address | 3;
    record.shared[slot] = item;
    record.shared_tables[slot] = allocated;
    published = true;
    try auditShared(record);
    bedrock_arm_refresh_tables();
}

pub fn unmapShared(space: contract.AddressSpace, slot: usize) !void {
    try sharedReady();
    if (slot >= contract.shared_surface_slots) return error.InvalidSharedMapping;
    const record = spaceRecord(space) orelse return error.InvalidAddressSpace;
    const item = record.shared[slot];
    if (item.pages == 0) return error.SharedSlotEmpty;
    const mapping = try item.mapping(slot);
    try synchronizeKernelMappings(record);
    try auditShared(record);
    const directory = table(record.tables[2]);
    const first = index(mapping.virtual, 2);
    const needed: usize = if (item.pages > 512) 2 else 1;
    const allocated = record.shared_tables[slot];
    for (allocated[0..needed], 0..) |address, offset|
        if (!ownsPrivateTable(record, address) or directory[first + offset] != address | 3) return error.InvalidPrivateTableLedger;
    for (0..needed) |offset| directory[first + offset] = 0;
    record.shared[slot] = .{};
    record.shared_tables[slot] = @splat(0);
    bedrock_arm_retire_tables();
    for (allocated[0..needed]) |address| try releaseSharedTable(record, address);
    try auditShared(record);
}

/// Destroy only inactive private tables. User frames belong to the core and
/// may be returned only after this succeeds. Shared identity trees stay live.
pub fn destroy(space: contract.AddressSpace) !void {
    if (!prepared) return error.IsolationNotReady;
    const record = spaceRecord(space) orelse return error.InvalidAddressSpace;
    for (record.shared) |mapping| if (mapping.pages != 0) return error.AddressSpaceHasSharedMappings;
    if (active or active_context != null or bedrock_arm_current_ttbr() != kernel_root)
        return error.ActiveAddressSpace;
    checkKernelContinuation();
    for (&contexts) |*slot| {
        if (slot.occupied and slot.context.root == space.root and
            slot.context.space_generation == space.generation)
            return error.AddressSpaceHasContexts;
    }
    if (preemption_ready and !timer.isQuiescent()) return error.ActiveAddressSpace;
    retirePrivateTables(record);
    record.root = 0;
    record.generation = 0;
    record.state = .vacant;
}

pub fn programBytes() []const u8 {
    const start = @intFromPtr(&bedrock_arm_user_program_start);
    const end = @intFromPtr(&bedrock_arm_user_program_end);
    if (end <= start or end - start > page) @panic("invalid ARM user fixture");
    return @as([*]const u8, @ptrFromInt(start))[0 .. end - start];
}

pub fn run(space: contract.AddressSpace, invocation: contract.Invocation) void {
    if (!prepared or active or invocation.entry != contract.user_code or
        invocation.user_sp != contract.user_stack_top) @panic("invalid ARM user invocation");
    const owned = spaceRecord(space) orelse @panic("unknown or stale ARM task root");
    if (owned.task.desktop or owned.task.app) @panic("cooperative ARM fixture needs fixture layout");
    active_task = owned.task;
    checkKernelContinuation();
    active = true;
    bedrock_arm_run_user(space.root, &invocation);
    active = false;
    checkKernelContinuation();
}

fn checkKernelContinuation() void {
    if (!kernelContinuationValid()) @panic("ARM kernel continuation was not restored");
}

fn kernelContinuationValid() bool {
    const sp = bedrock_arm_current_sp();
    return bedrock_arm_current_ttbr() == kernel_root and
        bedrock_arm_current_cpacr() & (3 << 20) == (3 << 20) and
        bedrock_arm_current_daif() & (1 << 7) != 0 and
        sp >= kernel_layout.stack_bottom and sp < kernel_layout.stack_top and sp % 16 == 0;
}

fn inactiveKernelContext() !void {
    if (!prepared or !preemption_ready) return error.InvalidPreemptionState;
    if (active or active_context != null) return error.ActiveContext;
    if (!kernelContinuationValid()) return error.InvalidKernelContinuation;
    if (!timer.isQuiescent()) return error.ActiveTimer;
    if (bedrock_arm_current_cntkctl() != 0 or bedrock_arch_translation_state() & (1 << 9) != 0)
        return error.InvalidTimerAuthority;
}

/// Extend only DTB-declared, non-RAM GIC ranges while all kernel IRQs are masked.
pub fn preparePreemption(info: *const protocol.BootInfo) !void {
    if (!prepared or active or preemption_ready) return error.InvalidPreemptionState;
    checkKernelContinuation();
    if (info.dtb.length == 0 or info.dtb.length > 1024 * 1024 or !info.isMapped(info.dtb))
        return error.MissingTimerDeviceTree;
    const blob = @as([*]const u8, @ptrFromInt(info.dtb.base))[0..@intCast(info.dtb.length)];
    const hardware = try timer.discover(blob);
    for ([_]protocol.PhysicalRange{ hardware.distributor, hardware.cpu_interface }) |range| {
        try validateInterruptDevice(info, range);
        var at = range.base;
        const end = try alignUp(try range.endExclusive());
        while (at < end) : (at += page) {
            try replacePage(kernel_root, at, at | device_rw | 3);
        }
    }
    for (&spaces) |*record| {
        if (record.state == .live) try synchronizeKernelMappings(record);
    }
    bedrock_arm_refresh_tables();
    try audit(kernel_root, false);
    try auditKernel(kernel_root);
    for (&spaces) |*record| {
        if (record.state != .live) continue;
        try audit(record.root, true);
        try auditKernel(record.root);
    }
    try timer.initialize(hardware);
    if (bedrock_arch_translation_state() & (1 << 9) != 0 or bedrock_arm_current_cntkctl() != 0)
        return error.UserTimerAuthorityEnabled;
    preemption_ready = true;
}

pub fn createContext(space: contract.AddressSpace, invocation: contract.Invocation) !contract.ContextHandle {
    try inactiveKernelContext();
    const owned = spaceRecord(space) orelse return error.InvalidContextInvocation;
    if (invocation.entry < owned.task.codeVirtual() or
        invocation.entry >= owned.task.codeEnd() or invocation.entry % 4 != 0 or
        invocation.user_sp != owned.task.stackTop())
        return error.InvalidContextInvocation;
    checkKernelContinuation();
    for (&contexts, 0..) |*slot, i| {
        if (slot.occupied or slot.retired) continue;
        slot.context = .{
            .root = space.root,
            .space_generation = space.generation,
            .frame = .{ .x = @splat(0), .spsr = 0x340, .simd = @splat(0), .fpcr = 0, .fpsr = 0 },
            .pc = invocation.entry,
            .user_sp = invocation.user_sp,
        };
        slot.context.frame.x[0] = invocation.arg0;
        slot.context.frame.x[1] = invocation.arg1;
        slot.context.frame.x[2] = invocation.arg2;
        slot.occupied = true;
        return @fromBackingInt((@as(u64, slot.generation) << 32) | @as(u64, i + 1));
    }
    return error.ContextCapacityOrState;
}

pub fn validateContext(handle: contract.ContextHandle) !void {
    try inactiveKernelContext();
    const slot = try contextRecord(handle);
    const owned = spaceRecord(.{ .root = slot.context.root, .generation = slot.context.space_generation }) orelse return error.InvalidContextHandle;
    if (!slot.context.alive) return error.ContextStopped;
    const context = &slot.context;
    if (!savedUserFrameValid(&context.frame, owned.task, context.pc, context.user_sp, false, true)) return error.InvalidContextInvocation;
}

/// Only the trusted scheduler may update an inactive saved syscall result.
pub fn setContextResult(handle: contract.ContextHandle, result: u64) !void {
    try inactiveKernelContext();
    try validateContext(handle);
    const slot = try contextRecord(handle);
    slot.context.frame.x[0] = result;
}

/// Poll a physical timer quantum under the kernel root with IRQ masked. The
/// controller acknowledges the posted source before any scheduler tick is valid.
pub fn idleUntilTick() !void {
    try inactiveKernelContext();
    const deadline = timer.beginQuantum();
    defer timer.quiesce();
    bedrock_arm_timer_arm(deadline);
    var polls: u32 = 0;
    while (polls < 10_000_000) : (polls += 1) {
        if (timer.pending()) {
            _ = try timer.acknowledge();
            return;
        }
        asm volatile ("yield" ::: .{ .memory = true });
    }
    return error.TimerWaitTimeout;
}

/// Even a stopped context must be explicitly destroyed before its space can be
/// retired. Generation changes invalidate every copy of the old opaque token.
pub fn destroyContext(handle: contract.ContextHandle) !void {
    const slot = try contextRecord(handle);
    if (active or active_context != null) return error.ActiveContext;
    if (!prepared or bedrock_arm_current_ttbr() != kernel_root) return error.ActiveContext;
    checkKernelContinuation();
    if (preemption_ready and !timer.isQuiescent()) return error.ActiveContext;
    @memset(@as([*]u8, @ptrCast(&slot.context))[0..@sizeOf(Context)], 0);
    slot.occupied = false;
    if (slot.generation == ~@as(u32, 0)) {
        slot.retired = true;
    } else {
        slot.generation += 1;
    }
}

pub fn resumeContext(handle: contract.ContextHandle) void {
    if (!preemption_ready or active) @panic("invalid ARM context state");
    validateContext(handle) catch @panic("invalid or stale ARM context handle");
    const slot = contextRecord(handle) catch unreachable;
    const context = &slot.context;
    const owned = spaceRecord(.{ .root = context.root, .generation = context.space_generation }) orelse @panic("stale ARM context root");
    active_task = owned.task;
    checkKernelContinuation();
    if (bedrock_arm_current_cntkctl() != 0 or bedrock_arch_translation_state() & (1 << 9) != 0 or !timer.isQuiescent())
        @panic("ARM timer boundary lost kernel authority");
    active_context = context;
    active = true;
    const deadline = timer.beginQuantum();
    bedrock_arm_resume_user(context.root, &context.frame, context.pc, context.user_sp, deadline);
    active = false;
    active_context = null;
    checkKernelContinuation();
    if (!timer.isQuiescent()) @panic("ARM timer remained active in the kernel");
}

fn vacantSpace() ?*SpaceRecord {
    for (&spaces) |*record| if (record.state == .vacant) return record;
    return null;
}

fn spaceRecord(space: contract.AddressSpace) ?*SpaceRecord {
    if (space.root == 0 or space.generation == 0) return null;
    for (&spaces) |*record| {
        if (record.state == .live and record.root == space.root and
            record.generation == space.generation) return record;
    }
    return null;
}

fn contextRecord(handle: contract.ContextHandle) !*ContextRecord {
    const value = @backingInt(handle);
    const number: u32 = @truncate(value);
    const generation: u32 = @truncate(value >> 32);
    if (number == 0 or number > contexts.len or generation == 0) return error.InvalidContextHandle;
    const slot = &contexts[number - 1];
    if (!slot.occupied or slot.retired or slot.generation != generation) return error.InvalidContextHandle;
    return slot;
}

fn validateInterruptDevice(info: *const protocol.BootInfo, range: protocol.PhysicalRange) !void {
    const end = try alignUp(try range.endExclusive());
    if (range.base % page != 0 or range.length == 0 or end > physical_limit or
        overlaps(range.base, end, contract.user_base, contract.user_window_end) or
        overlaps(range.base, end, info.kernel_reserved.base, try info.kernel_reserved.endExclusive()) or
        overlaps(range.base, end, info.loader_reserved.base, try info.loader_reserved.endExclusive()) or
        (info.apps.reservation.length != 0 and overlaps(range.base, end, info.apps.reservation.base, try info.apps.reservation.endExclusive())) or
        (info.framebuffer.size != 0 and overlaps(range.base, end, info.framebuffer.base, info.framebuffer.base + info.framebuffer.size)) or
        (info.console.kind == @backingInt(protocol.ConsoleKind.pl011) and overlaps(range.base, end, info.console.base, info.console.base + 0x48)))
        return error.InterruptDeviceOverlapsOwnedMemory;
    // The normalized ownership map may label retained RAM as reserved. Check
    // raw EFI RAM types as well, so no discovered MMIO can retype live RAM.
    const raw: [*]const u8 = @ptrFromInt(info.firmware_memory_map.base);
    const count = info.firmware_memory_map.length / info.firmware_descriptor_size;
    for (0..@intCast(count)) |i| {
        const offset = i * @as(usize, info.firmware_descriptor_size);
        const kind = readLittle(raw + offset, 4);
        if (!(kind >= 1 and kind <= 7) and kind != 9 and kind != 10) continue;
        const base = readLittle(raw + offset + 8, 8);
        const length = readLittle(raw + offset + 24, 8) * page;
        if (overlaps(range.base, end, base, base + length)) return error.InterruptDeviceOverlapsRam;
    }
}

/// Exact ESR causes prove protections, rather than accepting any user fault.
pub fn validateFault(probe: contract.Probe, event: contract.Event) !void {
    if (event.kind != contract.event_fault) return error.UnexpectedUserFaultKind;
    const ec = (event.syndrome >> 26) & 63;
    const fsc = event.syndrome & 63;
    const permission = fsc >= 0x0c and fsc <= 0x0f;
    const translation = fsc >= 0x04 and fsc <= 0x07;
    const write = event.syndrome & (1 << 6) != 0;
    switch (probe) {
        .kernel_read, .peer_read => if (ec != 0x24 or !permission or write) return error.ExpectedReadPermissionFault,
        .code_write => if (ec != 0x24 or !permission or !write) return error.ExpectedWritePermissionFault,
        .stack_execute => if (ec != 0x20 or !permission) return error.ExpectedExecutePermissionFault,
        .guard_read => if (ec != 0x24 or !translation or write) return error.ExpectedGuardTranslationFault,
        .normal, .spin => return error.UnexpectedNormalTaskFault,
    }
    if (event.syndrome & (1 << 10) != 0) return error.InvalidFaultAddress; // FnV
}

const TrapFrame = extern struct { x: [31]u64, spsr: u64, simd: [32]u128, fpcr: u64, fpsr: u64 };
const Context = struct { root: u64, space_generation: u64, frame: TrapFrame, pc: u64, user_sp: u64, alive: bool = true };

fn savedUserFrameValid(frame: *const TrapFrame, task: contract.TaskMemory, pc: u64, user_sp: u64, allow_code_end: bool, interrupts_enabled: bool) bool {
    // The private window is in the installed translation regime's lower half.
    const code_end = task.codeEnd();
    const required_masks: u64 = if (interrupts_enabled) 0x340 else 0x3c0;
    return pc >= task.codeVirtual() and (pc < code_end or (allow_code_end and pc == code_end)) and pc % 4 == 0 and
        user_sp >= task.stackVirtual() and user_sp <= task.stackTop() and user_sp % 16 == 0 and
        frame.spsr & ~@as(u64, 0xf000_03c0) == 0 and frame.spsr & 0x3c0 == required_masks;
}

comptime {
    if (@sizeOf(TrapFrame) != 784 or @offsetOf(TrapFrame, "spsr") != 248 or
        @offsetOf(TrapFrame, "fpcr") != 768) @compileError("ARM exception frame changed");
    if (contract.user_base / block != (contract.core_user_window_end - 1) / block or
        contract.user_base >> 30 != (contract.user_window_end - 1) >> 30)
        @compileError("ARM core must fit one L3 and all user windows must fit one private L2");
}

export fn bedrock_arm_user_exception(frame: *TrapFrame, esr: u64, elr: u64, far: u64, slot: u64) callconv(.c) u64 {
    if (!active or frame.spsr & 15 != 0) @panic("unexpected lower-EL exception");
    if (slot == 9) {
        const context = active_context orelse @panic("IRQ without a resumable user context");
        context.frame = frame.*;
        context.pc = elr;
        context.user_sp = bedrock_arm_current_user_sp();
        const interrupt_id = timer.acknowledge() catch @panic("unexpected ARM timer IRQ");
        var event: contract.Event = .{ .kind = contract.event_timer, .number = interrupt_id, .arg0 = 0, .arg1 = 0, .arg2 = 0, .pc = elr, .fault_address = 0, .syndrome = 0 };
        if (!savedUserFrameValid(frame, active_task, elr, context.user_sp, false, true)) {
            event.kind = contract.event_fault;
            event.number = 0;
            event.fault_address = context.user_sp;
        }
        var reply: contract.Reply = .{ .action = contract.action_terminate, .result = 0 };
        bedrock_user_dispatch(&event, &reply);
        switch (reply.action) {
            contract.action_suspend => if (event.kind != contract.event_timer) @panic("cannot suspend an ARM user fault"),
            contract.action_terminate => context.alive = false,
            else => @panic("invalid ARM timer dispatch reply"),
        }
        bedrock_arm_finish_user();
    }
    if (slot != 8) @panic("unexpected ARM lower-EL vector");
    const ec = (esr >> 26) & 63;
    var syscall = ec == 0x15;
    var event: contract.Event = .{
        .kind = if (syscall) contract.event_syscall else contract.event_fault,
        .number = if (syscall) frame.x[8] else 0,
        .arg0 = frame.x[0],
        .arg1 = frame.x[1],
        .arg2 = frame.x[2],
        .pc = elr,
        .fault_address = if (ec == 0x20 or ec == 0x24) far else 0,
        .syndrome = esr,
    };
    if (syscall) {
        const user_sp = bedrock_arm_current_user_sp();
        if (!savedUserFrameValid(frame, active_task, elr, user_sp, true, active_context != null)) {
            event.kind = contract.event_fault;
            event.number = 0;
            event.fault_address = user_sp;
            event.syndrome = 0;
            syscall = false;
        }
    }
    var reply: contract.Reply = .{ .action = contract.action_terminate, .result = 0 };
    bedrock_user_dispatch(&event, &reply);
    switch (reply.action) {
        contract.action_resume => {
            if (!syscall) @panic("attempt to resume a failed user task");
            frame.x[0] = reply.result;
            return elr; // SVC records the instruction AFTER the call.
        },
        contract.action_suspend => {
            if (!syscall) @panic("cannot suspend an ARM user fault");
            const context = active_context orelse @panic("ARM suspension needs a saved context");
            frame.x[0] = reply.result;
            context.frame = frame.*;
            context.pc = elr; // Already after SVC; never advance it again.
            context.user_sp = bedrock_arm_current_user_sp();
            timer.quiesce();
            bedrock_arm_finish_user();
        },
        contract.action_terminate => {
            if (active_context) |context| {
                context.alive = false;
                timer.quiesce();
            }
            bedrock_arm_finish_user();
        },
        else => @panic("invalid user dispatcher action"),
    }
}

fn table(address: u64) *[512]u64 {
    return @ptrFromInt(address);
}
fn index(address: u64, level: u2) usize {
    return @intCast((address >> @as(u6, @intCast(39 - @as(u8, level) * 9))) & 511);
}
fn overlaps(a: u64, ae: u64, b: u64, be: u64) bool {
    return a < be and b < ae;
}
fn alignUp(value: u64) !u64 {
    const sum = @addWithOverflow(value, page - 1);
    if (sum[1] != 0) return error.PhysicalRangeOverflow;
    return sum[0] & ~(page - 1);
}
fn readLittle(bytes: [*]const u8, count: usize) u64 {
    var result: u64 = 0;
    for (0..count) |i| result |= @as(u64, bytes[i]) << @intCast(i * 8);
    return result;
}
fn newTable() !u64 {
    if (table_count == max_table_pages) return error.TooManyTranslationTables;
    const address = try memory.allocateZeroed();
    errdefer releaseTable(address);
    if (address >= physical_limit) return error.TableOutsidePhysicalWidth;
    table_pages[table_count] = address;
    table_count += 1;
    return address;
}
fn isPermanentTable(address: u64) bool {
    for (table_pages[0..table_count]) |owned| if (owned == address) return true;
    return false;
}
fn newSpaceTable(record: *SpaceRecord, table_limit: usize) !u64 {
    if (record.state != .building and record.state != .live) return error.InvalidPrivateTableLedger;
    if (record.table_count >= @min(table_limit, max_private_tables))
        return error.PageTableCapacity;
    const address = try memory.allocateZeroed();
    errdefer releaseTable(address);
    if (address == 0 or address % page != 0 or address >= physical_limit)
        return error.TableOutsidePhysicalWidth;
    try auditTableAlias(kernel_root, address);
    record.tables[record.table_count] = address;
    record.table_count += 1;
    return address;
}
fn releaseTable(address: u64) void {
    const allocator = memory.allocator() orelse @panic("ARM table allocator unavailable");
    allocator.release(address) catch @panic("ARM translation-table ownership lost");
}
fn ownsPrivateTable(record: *const SpaceRecord, address: u64) bool {
    for (record.tables[0..record.table_count]) |owned| if (owned == address) return true;
    return false;
}
fn retirePrivateTables(record: *SpaceRecord) void {
    // Teardown and rollback run under the permanent root with IRQs masked.
    // Validate the complete ledger before detaching or releasing any page.
    if (active or active_context != null or bedrock_arm_current_ttbr() != kernel_root or
        record.table_count > max_private_tables)
        @panic("ARM private table retirement outside kernel continuation");
    for (record.tables[0..record.table_count], 0..) |address, i| {
        if (address == 0 or address % page != 0 or address >= physical_limit or isPermanentTable(address))
            @panic("invalid ARM private table ledger");
        for (record.tables[0..i]) |previous| if (previous == address)
            @panic("duplicate ARM private table ownership");
        for (&spaces) |*other| {
            if (other != record and (other.state == .building or other.state == .live) and
                ownsPrivateTable(other, address)) @panic("shared ARM private table ownership");
        }
        auditTableAlias(kernel_root, address) catch @panic("ARM private table alias lost");
    }
    for (record.tables[0..record.table_count]) |address| @memset(table(address), 0);
    // Publish invalid descriptors, invalidate translations/walk caches and old
    // executable aliases, then complete maintenance before page recycling.
    bedrock_arm_retire_tables();
    while (record.table_count != 0) {
        record.table_count -= 1;
        const address = record.tables[record.table_count];
        record.tables[record.table_count] = 0;
        releaseTable(address);
    }
}
fn rollbackSpace(record: *SpaceRecord) void {
    retirePrivateTables(record);
    record.root = 0;
    record.generation = 0;
    record.state = .vacant;
}
fn synchronizeKernelMappings(record: *SpaceRecord) !void {
    if (record.state != .live or record.table_count < 4 or record.table_count > max_private_tables or
        record.root != record.tables[0]) return error.InvalidPrivateTableLedger;
    const l0_slot = index(contract.user_base, 0);
    const l1_slot = index(contract.user_base, 1);
    const l2_slot = index(contract.user_base, 2);
    const permanent = table(kernel_root)[l0_slot];
    if (permanent & 3 != 3 or !isPermanentTable(permanent & address_mask))
        return error.MissingKernelIdentityTree;
    if (table(permanent & address_mask)[l1_slot] != 0) return error.UserWindowAlreadyMapped;
    if (table(record.root)[l0_slot] != (record.tables[1] | 3) or
        table(record.tables[1])[l1_slot] != (record.tables[2] | 3) or
        table(record.tables[2])[l2_slot] != (record.tables[3] | 3))
        return error.InvalidPrivateTableLedger;
    var expected_count: usize = 4;
    for (record.shared, 0..) |mapping, slot| {
        const needed: usize = if (mapping.pages == 0) 0 else if (mapping.pages > 512) 2 else 1;
        const first = index(contract.shared_surface_base + slot * contract.shared_surface_stride, 2);
        for (0..2) |part| {
            const address = record.shared_tables[slot][part];
            if (part < needed) {
                if (address == 0 or !ownsPrivateTable(record, address) or table(record.tables[2])[first + part] != address | 3) return error.InvalidPrivateTableLedger;
            } else if (address != 0 or table(record.tables[2])[first + part] != 0) return error.InvalidPrivateTableLedger;
        }
        expected_count += needed;
    }
    if (record.table_count != expected_count) return error.InvalidPrivateTableLedger;
    @memcpy(table(record.root), table(kernel_root));
    table(record.root)[l0_slot] = record.tables[1] | 3;
    @memcpy(table(record.tables[1]), table(permanent & address_mask));
    table(record.tables[1])[l1_slot] = record.tables[2] | 3;
}
fn child(parent: u64, slot: usize, level: u2) !u64 {
    const old = table(parent)[slot];
    if (old == 0) {
        const next = try newTable();
        table(parent)[slot] = next | 3;
        return next;
    }
    if (old & 3 == 3 and level < 3) return old & address_mask;
    if (level != 2 or old & 3 != 1) return error.UnexpectedTranslationDescriptor;
    // Split a 2 MiB identity block without broadening its existing attributes.
    const next = try newTable();
    const base = old & address_mask;
    const attributes = old & ~address_mask & ~@as(u64, 3);
    for (table(next), 0..) |*entry, i| entry.* = (base + i * page) | attributes | 3;
    table(parent)[slot] = next | 3;
    return next;
}
fn pageSlot(root: u64, address: u64) !*u64 {
    var node = root;
    for (0..3) |level| node = try child(node, index(address, @intCast(level)), @intCast(level));
    return &table(node)[index(address, 3)];
}
fn mapPage(root: u64, virtual: u64, physical: u64, attributes: u64) !void {
    const slot = try pageSlot(root, virtual);
    if (slot.* != 0) return error.OverlappingTranslationMapping;
    slot.* = physical | attributes | 3;
}
fn replacePage(root: u64, address: u64, value: u64) !void {
    const slot = try pageSlot(root, address);
    slot.* = value;
}
fn mapRange(root: u64, begin: u64, end: u64, attributes: u64) !void {
    var address = begin;
    while (address < end) {
        if (address % block == 0 and end - address >= block) {
            const l1 = try child(root, index(address, 0), 0);
            const l2 = try child(l1, index(address, 1), 1);
            const slot = &table(l2)[index(address, 2)];
            if (slot.* != 0) return error.OverlappingTranslationMapping;
            slot.* = address | attributes | 1;
            address += block;
        } else {
            try mapPage(root, address, address, attributes);
            address += page;
        }
    }
}
fn mapDevice(info: *const protocol.BootInfo, base: u64, length: u64, attributes: u64) !void {
    const end = @addWithOverflow(base, length);
    if (length == 0 or end[1] != 0 or end[0] > physical_limit or
        !info.isMapped(.{ .base = base, .length = length })) return error.DeviceNotCovered;
    const first = base & ~(page - 1);
    const last = try alignUp(end[0]);
    if (overlaps(first, last, contract.user_base, contract.user_window_end) or
        overlaps(first, last, info.kernel_reserved.base, try info.kernel_reserved.endExclusive()) or
        overlaps(first, last, info.loader_reserved.base, try info.loader_reserved.endExclusive()))
        return error.DeviceOverlapsOwnedArena;
    if (info.wifi.reservation.length != 0 and overlaps(first, last, info.wifi.reservation.base, try info.wifi.reservation.endExclusive())) return error.DeviceOverlapsOwnedArena;
    if (info.apps.reservation.length != 0 and overlaps(first, last, info.apps.reservation.base, try info.apps.reservation.endExclusive())) return error.DeviceOverlapsOwnedArena;
    for (info.drivers.records[0..info.drivers.count]) |driver|
        if (overlaps(first, last, driver.reservation.base, try driver.reservation.endExclusive())) return error.DeviceOverlapsOwnedArena;
    // Only page-rounded referred MMIO is introduced beyond RAM descriptors.
    var at = first;
    while (at < last) : (at += page) try replacePage(kernel_root, at, at | attributes | 3);
}
fn protectRange(begin: u64, end: u64, attributes: u64) !void {
    var at = begin;
    while (at < end) : (at += page) {
        const original = descriptor(kernel_root, at) orelse return error.KernelNotIdentityMapped;
        if ((original >> 2) & 7 != 1) return error.UnsupportedKernelCachePolicy;
        try replacePage(kernel_root, at, at | attributes | 3);
    }
}
fn descriptor(root: u64, address: u64) ?u64 {
    var node = root;
    for (0..4) |level| {
        const value = table(node)[index(address, @intCast(level))];
        if (value & 1 == 0) return null;
        if (level == 3 or value & 3 == 1) return value;
        node = value & address_mask;
    }
    return null;
}
fn validateLayout(info: *const protocol.BootInfo, layout: contract.KernelLayout) !void {
    try contract.validateKernelStack(layout);
    if (layout.kernel_start != info.kernel_image.base or layout.kernel_start < info.kernel_reserved.base)
        return error.KernelStartMismatch;
    if (layout.text_start != layout.kernel_start or layout.text_start >= layout.text_end) return error.InvalidTextLayout;
    if (layout.text_end != layout.rodata_start or layout.rodata_start > layout.rodata_end) return error.InvalidRodataLayout;
    if (layout.rodata_end != layout.data_start or layout.data_start > layout.data_end) return error.InvalidDataLayout;
    if (layout.data_end > layout.stack_guard) return error.KernelDataOverlapsGuard;
    if (layout.stack_guard + page != layout.stack_bottom or layout.stack_bottom >= layout.stack_top) return error.InvalidStackLayout;
    if (layout.stack_top != layout.allocated_end or layout.allocated_end != try info.kernel_image.endExclusive() or
        layout.allocated_end > try info.kernel_reserved.endExclusive()) return error.KernelEndMismatch;
    for ([_]u64{ layout.kernel_start, layout.text_start, layout.text_end, layout.rodata_start, layout.rodata_end, layout.data_start, layout.data_end, layout.stack_guard, layout.stack_bottom, layout.stack_top }) |address| if (address % page != 0) return error.UnalignedKernelLayout;
}
fn expectLeaf(root: u64, virtual: u64, physical: u64, attributes: u64) !void {
    const got = descriptor(root, virtual) orelse return error.ExpectedMappingMissing;
    if (got & address_mask != physical or got & ~address_mask != attributes | 3)
        return error.UnexpectedMappingPermissions;
}
fn auditKernel(root: u64) !void {
    const layout = kernel_layout;
    if (boot_info.apps.reservation.length != 0) {
        var at = boot_info.apps.reservation.base;
        const end = try boot_info.apps.reservation.endExclusive();
        while (at < end) : (at += page) try expectLeaf(root, at, at, supervisor_ro);
    }
    for (boot_info.drivers.records[0..boot_info.drivers.count]) |driver|
        for (driver.segments[0..driver.segment_count]) |segment| {
            var at = segment.range.base;
            while (at < try segment.range.endExclusive()) : (at += page)
                try expectLeaf(root, at, at, if (segment.flags & 1 != 0) supervisor_rx else if (segment.flags & 2 != 0) supervisor_rw else supervisor_ro);
        };
    for ([_]struct { begin: u64, end: u64, attributes: u64 }{
        .{ .begin = layout.text_start, .end = layout.text_end, .attributes = supervisor_rx },
        .{ .begin = layout.rodata_start, .end = layout.rodata_end, .attributes = supervisor_ro },
        .{ .begin = layout.data_start, .end = layout.data_end, .attributes = supervisor_rw },
        .{ .begin = layout.stack_bottom, .end = layout.stack_top, .attributes = supervisor_rw },
    }) |range| {
        var at = range.begin;
        while (at < range.end) : (at += page) try expectLeaf(root, at, at, range.attributes);
    }
    if (descriptor(root, layout.stack_guard) != null) return error.KernelStackGuardMapped;
    for (table_pages[0..table_count]) |physical| try auditTableAlias(root, physical);
    for (&spaces) |*record| {
        if (record.state != .building and record.state != .live) continue;
        for (record.tables[0..record.table_count]) |physical| try auditTableAlias(root, physical);
    }
}
fn auditTableAlias(root: u64, physical: u64) !void {
    const alias = descriptor(root, physical) orelse return error.TableNotIdentityMapped;
    if (alias & (ap_user | ap_readonly) != 0 or alias & (pxn | uxn) != (pxn | uxn) or
        (alias >> 2) & 7 != 1) return error.InvalidTableIdentityAlias;
}
fn audit(root: u64, allow_user: bool) !void {
    var owner: ?*const SpaceRecord = null;
    if (allow_user) {
        for (&spaces) |*record| {
            if ((record.state == .building or record.state == .live) and record.root == root) {
                owner = record;
                break;
            }
        }
        if (owner == null) return error.UnownedTranslationRoot;
    } else if (root != kernel_root) return error.UnownedTranslationRoot;
    try auditNode(root, 0, 0, owner);
}
fn auditNode(node: u64, level: u2, base: u64, owner: ?*const SpaceRecord) !void {
    if (!isPermanentTable(node) and !(if (owner) |record| ownsPrivateTable(record, node) else false))
        return error.UnownedTranslationTable;
    const shift: u6 = @intCast(39 - @as(u8, level) * 9);
    for (table(node), 0..) |entry, slot| {
        if (entry == 0) continue;
        const virtual = base + (@as(u64, slot) << shift);
        if (level < 3 and entry & 3 == 3) {
            if (entry & ~address_mask != 3) return error.InvalidTableDescriptor;
            try auditNode(entry & address_mask, level + 1, virtual, owner);
            continue;
        }
        if (level < 2 or entry & 3 != (if (level == 3) @as(u64, 3) else 1) or entry & af == 0)
            return error.InvalidLeafDescriptor;
        if (entry & ap_user != 0) {
            const record = owner orelse return error.UnexpectedUserMapping;
            if (level != 3) return error.UnexpectedUserMapping;
            const mapping = contract.userMapping(record.task, &record.shared, virtual) orelse return error.UnexpectedUserMapping;
            const physical = mapping.physical + virtual - mapping.virtual;
            const attributes = userAttributes(mapping);
            if (entry & address_mask != physical or entry & ~address_mask != attributes | 3) return error.InvalidUserMapping;
            if (entry & pxn == 0 or (entry & ap_readonly == 0 and entry & uxn == 0)) return error.UserWritableExecutableMapping;
        } else {
            if (entry & address_mask != virtual or entry & uxn == 0) return error.InvalidSupervisorMapping;
            const approved_code = (virtual >= kernel_layout.text_start and virtual < kernel_layout.text_end) or driverExecutable(virtual);
            if (entry & pxn == 0 and (entry & ap_readonly == 0 or !approved_code)) return error.SupervisorWritableExecutableMapping;
        }
    }
}
fn driverExecutable(address: u64) bool {
    for (boot_info.drivers.records[0..boot_info.drivers.count]) |driver|
        for (driver.segments[0..driver.segment_count]) |segment|
            if (segment.flags & 1 != 0 and address >= segment.range.base and address - segment.range.base < segment.range.length) return true;
    return false;
}
