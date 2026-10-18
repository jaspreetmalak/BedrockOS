//! The architecture boundary for protected probes and saved user contexts.
//! These records carry trusted kernel state; they are not a public app ABI.
pub const page_size: u64 = 4096;
/// Bounded supervisor capacity for Debug syscall dispatch and nested helpers.
/// The guard page is additional and never counted as usable stack memory.
pub const kernel_dispatch_stack_pages: usize = 32;
pub const kernel_dispatch_stack_bytes: u64 = kernel_dispatch_stack_pages * page_size;
pub const user_base: u64 = 0x20_0000_0000;
pub const user_code: u64 = user_base;
pub const user_data: u64 = user_base + page_size;
pub const user_guard: u64 = user_base + 2 * page_size;
pub const user_stack: u64 = user_base + 3 * page_size;
pub const user_stack_top: u64 = user_base + 4 * page_size;

pub const KernelLayout = struct {
    kernel_start: u64,
    text_start: u64,
    text_end: u64,
    rodata_start: u64,
    rodata_end: u64,
    data_start: u64,
    data_end: u64,
    allocated_end: u64,
    stack_bottom: u64,
    stack_top: u64,
    stack_guard: u64,
};

pub fn validateKernelStack(layout: KernelLayout) error{InvalidKernelStack}!void {
    const guard_end = @addWithOverflow(layout.stack_guard, page_size);
    if (layout.stack_bottom == 0 or layout.stack_bottom % page_size != 0 or layout.stack_top % page_size != 0 or
        layout.stack_guard % page_size != 0 or guard_end[1] != 0 or guard_end[0] != layout.stack_bottom or
        layout.stack_bottom >= layout.stack_top or layout.stack_top - layout.stack_bottom < kernel_dispatch_stack_bytes)
        return error.InvalidKernelStack;
}
pub const desktop_code: u64 = user_base + 0x10000;
pub const desktop_data: u64 = user_base + 0x40000;
pub const desktop_stack: u64 = user_base + 0x1e0000;
pub const core_user_window_end: u64 = user_base + 0x200000;
pub const shared_surface_base: u64 = user_base + 0x800000;
pub const shared_surface_stride: u64 = 0x400000;
pub const shared_surface_slots: usize = 4;
pub const shared_surface_max_pages: u16 = 1024;
pub const user_window_end: u64 = shared_surface_base + shared_surface_slots * shared_surface_stride;
pub const application_code: u64 = desktop_code;
pub const application_data: u64 = desktop_data;
pub const application_startup: u64 = user_base + 0x30000;
pub const application_heap: u64 = user_base + 0x140000;
pub const application_stack: u64 = desktop_stack;
pub const application_max_code_pages: u16 = 32;
pub const application_max_data_pages: u16 = 256;
pub const application_max_stack_pages: u16 = 16;
pub const application_max_heap_pages: u16 = 128;
pub const Mapping = struct { virtual: u64, physical: u64, pages: u16, writable: bool, executable: bool = false };

pub const SharedMapping = struct {
    physical: u64 = 0,
    pages: u16 = 0,
    writable: bool = false,

    pub fn init(slot: usize, physical: u64, pages: u16, writable: bool) error{InvalidSharedMapping}!SharedMapping {
        if (slot >= shared_surface_slots or pages == 0 or pages > shared_surface_max_pages or
            physical == 0 or physical % page_size != 0 or @addWithOverflow(physical, @as(u64, pages) * page_size)[1] != 0)
            return error.InvalidSharedMapping;
        return .{ .physical = physical, .pages = pages, .writable = writable };
    }
    pub fn mapping(self: SharedMapping, slot: usize) error{InvalidSharedMapping}!Mapping {
        _ = try init(slot, self.physical, self.pages, self.writable);
        return .{ .virtual = shared_surface_base + slot * shared_surface_stride, .physical = self.physical, .pages = self.pages, .writable = self.writable };
    }
};

pub fn userMapping(task: TaskMemory, shared: []const SharedMapping, address: u64) ?Mapping {
    for (task.allMappings()) |mapping| {
        if (address >= mapping.virtual and address - mapping.virtual < @as(u64, mapping.pages) * page_size) return mapping;
    }
    for (shared, 0..) |record, slot| {
        if (record.pages == 0) continue;
        const mapping = record.mapping(slot) catch return null;
        if (address >= mapping.virtual and address - mapping.virtual < @as(u64, mapping.pages) * page_size) return mapping;
    }
    return null;
}

pub fn physicalOverlap(base: u64, length: u64, other_base: u64, other_length: u64) bool {
    if (length == 0 or other_length == 0) return false;
    const end = @addWithOverflow(base, length);
    const other_end = @addWithOverflow(other_base, other_length);
    return end[1] != 0 or other_end[1] != 0 or base < other_end[0] and other_base < end[0];
}

/// Architecture checks cannot identify a lease owner from a physical address.
/// The trusted broker resolves and retains its owner ticket before this call.
pub fn validateSharedBacking(info: anytype, physical: u64, pages: u16) !void {
    _ = try SharedMapping.init(0, physical, pages, false);
    const Range = @TypeOf(info.ram);
    const range: Range = .{ .base = physical, .length = @as(u64, pages) * page_size };
    const end = try range.endExclusive();
    if (!info.isMapped(range) or info.memory_region_count == 0 or info.memory_region_count > info.memory_regions.len or
        info.drivers.count > info.drivers.records.len) return error.InvalidSharedBacking;
    for ([_]Range{ info.loader_reserved, info.kernel_reserved, info.apps.reservation, info.wifi.reservation, .{ .base = info.framebuffer.base, .length = info.framebuffer.size } }) |protected|
        if (physicalOverlap(physical, range.length, protected.base, protected.length)) return error.ProtectedSharedBacking;
    for (info.drivers.records[0..info.drivers.count]) |driver|
        if (physicalOverlap(physical, range.length, driver.reservation.base, driver.reservation.length)) return error.ProtectedSharedBacking;
    var cursor = physical;
    var previous_end: u64 = 0;
    for (info.memory_regions[0..info.memory_region_count], 0..) |region, index| {
        const region_end = try region.range.endExclusive();
        if (region.range.length == 0 or index != 0 and region.range.base < previous_end) return error.InvalidSharedBacking;
        previous_end = region_end;
        if (!physicalOverlap(physical, range.length, region.range.base, region.range.length)) continue;
        if (!region.isUsable() or region.range.base > cursor) return error.SharedBackingNotUsable;
        cursor = @min(end, region_end);
    }
    if (cursor != end) return error.SharedBackingNotUsable;
}

pub fn validateSharedAllocation(allocator: anytype, physical: u64, pages: u16) !void {
    _ = try SharedMapping.init(0, physical, pages, false);
    const bytes = @as(u64, pages) * page_size;
    const metadata = allocator.layout.storage;
    if (physicalOverlap(physical, bytes, metadata.base, metadata.length)) return error.ProtectedSharedBacking;
    for (0..pages) |page_index| {
        const address = physical + page_index * page_size;
        const index = for (allocator.layout.spans[0..allocator.layout.span_count]) |span| {
            if (address >= span.base and address - span.base < span.page_count * page_size)
                break span.first_index + (address - span.base) / page_size;
        } else return error.SharedBackingNotAllocated;
        if (index / 8 >= allocator.bitmap.len or allocator.bitmap[@intCast(index / 8)] & (@as(u8, 1) << @as(u3, @intCast(index % 8))) == 0)
            return error.SharedBackingNotAllocated;
    }
}
/// Contiguous, owned physical ranges. Only the kernel-defined layouts are
/// accepted; applications cannot choose mappings, permissions or addresses.
pub const TaskMemory = struct {
    code: u64,
    data: u64,
    stack: u64,
    code_pages: u16 = 1,
    data_pages: u16 = 1,
    stack_pages: u16 = 1,
    desktop: bool = false,
    app: bool = false,
    startup: u64 = 0,
    heap: u64 = 0,
    heap_pages: u16 = 0,

    pub fn mappings(self: TaskMemory) [3]Mapping {
        return .{
            .{ .virtual = self.codeVirtual(), .physical = self.code, .pages = self.code_pages, .writable = false, .executable = true },
            .{ .virtual = self.dataVirtual(), .physical = self.data, .pages = self.data_pages, .writable = true },
            .{ .virtual = self.stackVirtual(), .physical = self.stack, .pages = self.stack_pages, .writable = true },
        };
    }
    /// The extra regions exist only for installed applications. Existing
    /// fixture and Files callers retain their three-region mapping contract.
    pub fn allMappings(self: TaskMemory) [5]Mapping {
        const core = self.mappings();
        return .{
            core[0],
            core[1],
            core[2],
            .{ .virtual = application_startup, .physical = self.startup, .pages = if (self.app) 1 else 0, .writable = false },
            .{ .virtual = application_heap, .physical = self.heap, .pages = self.heap_pages, .writable = true },
        };
    }
    pub fn mappingCount(self: TaskMemory) usize {
        return if (self.app) 5 else 3;
    }
    pub fn codeVirtual(self: TaskMemory) u64 {
        return if (self.desktop or self.app) desktop_code else user_code;
    }
    pub fn dataVirtual(self: TaskMemory) u64 {
        return if (self.desktop or self.app) desktop_data else user_data;
    }
    pub fn stackVirtual(self: TaskMemory) u64 {
        return if (self.desktop or self.app) desktop_stack else user_stack;
    }
    pub fn codeEnd(self: TaskMemory) u64 {
        return self.codeVirtual() + @as(u64, self.code_pages) * page_size;
    }
    pub fn stackTop(self: TaskMemory) u64 {
        return self.stackVirtual() + @as(u64, self.stack_pages) * page_size;
    }
    pub fn guard(self: TaskMemory) u64 {
        return self.stackVirtual() - page_size;
    }
    pub fn validate(self: TaskMemory) !void {
        if (self.app and self.desktop) return error.InvalidTaskMemory;
        if (self.desktop or self.app) {
            if (self.code_pages == 0 or self.code_pages > application_max_code_pages or self.data_pages == 0 or self.data_pages > application_max_data_pages or
                self.stack_pages == 0 or self.stack_pages > application_max_stack_pages) return error.InvalidTaskMemory;
        } else if (self.code_pages != 1 or self.data_pages != 1 or self.stack_pages != 1) return error.InvalidTaskMemory;
        if (self.app) {
            if (self.heap_pages == 0 or self.heap_pages > application_max_heap_pages) return error.InvalidTaskMemory;
        } else if (self.startup != 0 or self.heap != 0 or self.heap_pages != 0) return error.InvalidTaskMemory;
        const ranges = self.allMappings();
        for (ranges, 0..) |range, i| {
            if (range.pages == 0) continue;
            const bytes = @as(u64, range.pages) * page_size;
            const limit = @addWithOverflow(range.physical, bytes);
            if (range.physical == 0 or range.physical % page_size != 0 or limit[1] != 0) return error.InvalidTaskMemory;
            for (ranges[0..i]) |earlier| {
                if (earlier.pages == 0) continue;
                if (range.physical < earlier.physical + @as(u64, earlier.pages) * page_size and earlier.physical < limit[0])
                    return error.InvalidTaskMemory;
            }
        }
    }
};
/// Kernel-only identity; a recycled root must never revive a stale reference.
pub const AddressSpace = struct { root: u64, generation: u64 = 0 };
/// Opaque kernel-only reference to a saved native context. Apps never supply it.
pub const ContextHandle = enum(u64) { _ };
pub const Invocation = extern struct { entry: u64, user_sp: u64, arg0: u64, arg1: u64, arg2: u64 };
pub const Event = extern struct {
    kind: u64,
    number: u64,
    arg0: u64,
    arg1: u64,
    arg2: u64,
    pc: u64,
    fault_address: u64,
    syndrome: u64,
};
pub const Reply = extern struct { action: u64, result: u64 };
pub const event_syscall: u64 = 1;
pub const event_fault: u64 = 2;
pub const event_timer: u64 = 3;
pub const action_resume: u64 = 0;
pub const action_terminate: u64 = 1;
pub const action_suspend: u64 = 2;
pub const syscall_report: u64 = 0;
pub const syscall_exit: u64 = 1;
pub const syscall_write_handle: u64 = 2;
pub const syscall_unknown: u64 = 0xffff;
pub const errno_fault: u64 = @bitCast(@as(i64, -14));
pub const errno_access: u64 = @bitCast(@as(i64, -13));
pub const errno_unknown: u64 = @bitCast(@as(i64, -38));

pub const Probe = enum(u64) { normal, kernel_read, peer_read, code_write, stack_execute, guard_read, spin };

comptime {
    if (@sizeOf(Event) != 64 or @sizeOf(Reply) != 16 or @sizeOf(Invocation) != 40)
        @compileError("User transition assembly contract changed");
}

test "desktop layout remains bounded and fixture pages cannot widen" {
    const t = @import("std").testing;
    const wide: TaskMemory = .{ .code = 0x100000, .data = 0x200000, .stack = 0x400000, .desktop = true, .code_pages = 32, .data_pages = 256, .stack_pages = 16 };
    try wide.validate();
    try t.expect(wide.codeEnd() < wide.dataVirtual());
    try t.expect(wide.dataVirtual() + @as(u64, wide.data_pages) * page_size < wide.guard());
    try t.expect(wide.stackTop() <= core_user_window_end);
    var bad = wide;
    bad.desktop = false;
    try t.expectError(error.InvalidTaskMemory, bad.validate());
    bad = wide;
    bad.code_pages = 33;
    try t.expectError(error.InvalidTaskMemory, bad.validate());
    bad = wide;
    bad.data_pages = 257;
    try t.expectError(error.InvalidTaskMemory, bad.validate());
}
test "task ranges reject interior overlap wraparound and zero lengths" {
    const t = @import("std").testing;
    var task: TaskMemory = .{ .code = 0x100000, .data = 0x101000, .stack = 0x400000, .desktop = true, .code_pages = 2 };
    try t.expectError(error.InvalidTaskMemory, task.validate());
    task.data = 0x200000;
    task.stack = 0xfffffffffffff000;
    task.stack_pages = 2;
    try t.expectError(error.InvalidTaskMemory, task.validate());
    task.stack = 0x400000;
    task.stack_pages = 0;
    try t.expectError(error.InvalidTaskMemory, task.validate());
}

fn applicationFixture() TaskMemory {
    return .{
        .code = 0x100000,
        .data = 0x200000,
        .stack = 0x400000,
        .startup = 0x500000,
        .heap = 0x600000,
        .app = true,
        .code_pages = application_max_code_pages,
        .data_pages = application_max_data_pages,
        .stack_pages = application_max_stack_pages,
        .heap_pages = application_max_heap_pages,
    };
}

test "installed applications separate RX code RO startup and RW heap within the existing window" {
    const t = @import("std").testing;
    const app = applicationFixture();
    try app.validate();
    const maps = app.allMappings();
    try t.expectEqual(@as(usize, 5), app.mappingCount());
    try t.expect(maps[0].executable and !maps[0].writable);
    try t.expect(!maps[1].executable and maps[1].writable);
    try t.expect(!maps[2].executable and maps[2].writable);
    try t.expect(!maps[3].executable and !maps[3].writable and maps[3].pages == 1);
    try t.expect(!maps[4].executable and maps[4].writable);
    try t.expectEqual(application_startup, maps[3].virtual);
    try t.expectEqual(application_heap, maps[4].virtual);
    try t.expectEqual(application_startup, app.codeEnd());
    try t.expect(maps[3].virtual + page_size <= app.dataVirtual());
    try t.expectEqual(application_heap, app.dataVirtual() + @as(u64, app.data_pages) * page_size);
    try t.expect(application_heap + @as(u64, app.heap_pages) * page_size < app.guard());
    try t.expect(app.stackTop() <= core_user_window_end);
}

test "applications require independently owned startup and bounded heap leases" {
    const t = @import("std").testing;
    inline for (.{ "startup", "heap" }) |field| {
        var invalid = applicationFixture();
        @field(invalid, field) = 0;
        try t.expectError(error.InvalidTaskMemory, invalid.validate());
        invalid = applicationFixture();
        @field(invalid, field) += 1;
        try t.expectError(error.InvalidTaskMemory, invalid.validate());
        invalid = applicationFixture();
        @field(invalid, field) = invalid.code + page_size;
        try t.expectError(error.InvalidTaskMemory, invalid.validate());
    }
    for ([_]u16{ 0, application_max_heap_pages + 1 }) |pages| {
        var invalid = applicationFixture();
        invalid.heap_pages = pages;
        try t.expectError(error.InvalidTaskMemory, invalid.validate());
    }
    var invalid = applicationFixture();
    invalid.heap = 0xfffffffffffff000;
    try t.expectError(error.InvalidTaskMemory, invalid.validate());
    invalid = applicationFixture();
    invalid.heap = invalid.startup;
    try t.expectError(error.InvalidTaskMemory, invalid.validate());
}

test "fixture and Files layouts cannot acquire application startup or heap authority" {
    const t = @import("std").testing;
    const fixture_task: TaskMemory = .{ .code = 0x100000, .data = 0x200000, .stack = 0x400000 };
    try fixture_task.validate();
    try t.expectEqual(@as(usize, 3), fixture_task.mappingCount());
    const maps = fixture_task.allMappings();
    try t.expectEqual(@as(u16, 0), maps[3].pages);
    try t.expectEqual(@as(u16, 0), maps[4].pages);
    for ([_]bool{ false, true }) |desktop| {
        var invalid = fixture_task;
        invalid.desktop = desktop;
        invalid.startup = 0x500000;
        try t.expectError(error.InvalidTaskMemory, invalid.validate());
        invalid = fixture_task;
        invalid.desktop = desktop;
        invalid.heap = 0x600000;
        invalid.heap_pages = 1;
        try t.expectError(error.InvalidTaskMemory, invalid.validate());
    }
    var mixed = applicationFixture();
    mixed.desktop = true;
    try t.expectError(error.InvalidTaskMemory, mixed.validate());
}

test "supervisor dispatcher stack rejects undersized unguarded unaligned and overflowing geometry" {
    const std = @import("std");
    const t = std.testing;
    var layout = std.mem.zeroes(KernelLayout);
    layout.stack_guard = 0x100000;
    layout.stack_bottom = layout.stack_guard + page_size;
    layout.stack_top = layout.stack_bottom + kernel_dispatch_stack_bytes;
    try validateKernelStack(layout);
    const valid = layout;
    layout.stack_top -= page_size;
    try t.expectError(error.InvalidKernelStack, validateKernelStack(layout));
    layout = valid;
    layout.stack_top = layout.stack_bottom;
    try t.expectError(error.InvalidKernelStack, validateKernelStack(layout));
    layout = valid;
    layout.stack_guard -= page_size;
    try t.expectError(error.InvalidKernelStack, validateKernelStack(layout));
    layout = valid;
    layout.stack_bottom += 1;
    try t.expectError(error.InvalidKernelStack, validateKernelStack(layout));
    layout = valid;
    layout.stack_top += 1;
    try t.expectError(error.InvalidKernelStack, validateKernelStack(layout));
    layout = valid;
    layout.stack_guard = 0xfffffffffffff000;
    layout.stack_bottom = 0;
    try t.expectError(error.InvalidKernelStack, validateKernelStack(layout));
}

test "shared slots are bounded NX and do not widen core application mappings" {
    const t = @import("std").testing;
    const task = applicationFixture();
    var shared: [shared_surface_slots]SharedMapping = @splat(.{});
    shared[0] = try SharedMapping.init(0, 0x800000, 600, true);
    shared[3] = try SharedMapping.init(3, 0xc00000, shared_surface_max_pages, false);
    const writer = userMapping(task, &shared, shared_surface_base + 513 * page_size).?;
    try t.expect(writer.writable and !writer.executable);
    const reader = userMapping(task, &shared, shared_surface_base + 3 * shared_surface_stride).?;
    try t.expect(!reader.writable and !reader.executable);
    try t.expect(userMapping(task, &shared, shared_surface_base + 600 * page_size) == null);
    try t.expect(userMapping(task, &shared, shared_surface_base + shared_surface_stride) == null);
    try t.expect(userMapping(task, &shared, core_user_window_end) == null);
    try t.expect(userMapping(task, &shared, user_window_end) == null);
    try t.expectEqual(application_startup, userMapping(task, &shared, application_startup).?.virtual);
    try t.expectEqual(@as(usize, 5), task.mappingCount());
    try t.expectError(error.InvalidSharedMapping, SharedMapping.init(shared_surface_slots, 0x800000, 1, false));
    try t.expectError(error.InvalidSharedMapping, SharedMapping.init(0, 0x800000, 0, false));
    try t.expectError(error.InvalidSharedMapping, SharedMapping.init(0, 0x800000, shared_surface_max_pages + 1, false));
    try t.expectError(error.InvalidSharedMapping, SharedMapping.init(0, 0x800001, 1, false));
    try t.expectError(error.InvalidSharedMapping, SharedMapping.init(0, 0xfffffffffffff000, 2, false));
}

const SharedTestRange = struct {
    base: u64 = 0,
    length: u64 = 0,
    fn endExclusive(self: @This()) !u64 {
        const sum = @addWithOverflow(self.base, self.length);
        if (sum[1] != 0) return error.PhysicalRangeOverflow;
        return sum[0];
    }
};
const SharedTestRegion = struct {
    range: SharedTestRange = .{},
    usable: bool = true,
    fn isUsable(self: @This()) bool {
        return self.usable;
    }
};
const SharedTestInfo = struct {
    ram: SharedTestRange = .{ .base = 0x100000, .length = 16 * page_size },
    loader_reserved: SharedTestRange = .{},
    kernel_reserved: SharedTestRange = .{},
    apps: struct { reservation: SharedTestRange = .{} } = .{},
    wifi: struct { reservation: SharedTestRange = .{} } = .{},
    framebuffer: struct { base: u64 = 0, size: u64 = 0 } = .{},
    drivers: struct { count: usize = 0, records: [4]struct { reservation: SharedTestRange = .{} } = @splat(.{}) } = .{},
    memory_region_count: usize = 1,
    memory_regions: [4]SharedTestRegion = .{ .{ .range = .{ .base = 0x100000, .length = 16 * page_size } }, .{}, .{}, .{} },
    fn isMapped(self: *const @This(), range: SharedTestRange) bool {
        return range.base >= self.ram.base and (range.endExclusive() catch return false) <= (self.ram.endExclusive() catch return false);
    }
};

test "shared backing rejects every boot arena MMIO holes and malformed ownership maps" {
    const t = @import("std").testing;
    var info: SharedTestInfo = .{};
    try validateSharedBacking(&info, 0x101000, 2);
    inline for (.{ "loader_reserved", "kernel_reserved" }) |field_name| {
        info = .{};
        @field(info, field_name) = .{ .base = 0x102000, .length = page_size };
        try t.expectError(error.ProtectedSharedBacking, validateSharedBacking(&info, 0x101000, 2));
    }
    inline for (.{ "apps", "wifi" }) |field_name| {
        info = .{};
        @field(info, field_name).reservation = .{ .base = 0x102000, .length = page_size };
        try t.expectError(error.ProtectedSharedBacking, validateSharedBacking(&info, 0x101000, 2));
    }
    info = .{};
    info.framebuffer = .{ .base = 0x102000, .size = page_size };
    try t.expectError(error.ProtectedSharedBacking, validateSharedBacking(&info, 0x101000, 2));
    info = .{};
    info.drivers.count = 1;
    info.drivers.records[0].reservation = .{ .base = 0x102000, .length = page_size };
    try t.expectError(error.ProtectedSharedBacking, validateSharedBacking(&info, 0x101000, 2));
    info = .{};
    info.memory_regions[0].usable = false;
    try t.expectError(error.SharedBackingNotUsable, validateSharedBacking(&info, 0x101000, 2));
    info = .{};
    info.memory_regions[0].range.length = page_size;
    info.memory_region_count = 2;
    info.memory_regions[1].range = .{ .base = 0x102000, .length = 14 * page_size };
    try t.expectError(error.SharedBackingNotUsable, validateSharedBacking(&info, 0x100000, 3));
    info = .{};
    info.memory_region_count = 2;
    info.memory_regions[1] = info.memory_regions[0];
    try t.expectError(error.InvalidSharedBacking, validateSharedBacking(&info, 0x101000, 2));
    info = .{};
    try t.expectError(error.InvalidSharedBacking, validateSharedBacking(&info, 0x110000, 1));
}

test "shared allocation requires every frame live and excludes allocator metadata" {
    const t = @import("std").testing;
    const Fake = struct {
        layout: struct {
            storage: SharedTestRange = .{ .base = 0x100000, .length = page_size },
            span_count: usize = 1,
            spans: [1]struct { base: u64 = 0x100000, page_count: u64 = 16, first_index: u64 = 0 } = @splat(.{}),
        } = .{},
        bitmap: [2]u8 = .{ 0x0f, 0 },
    };
    const allocator: Fake = .{};
    try validateSharedAllocation(&allocator, 0x101000, 2);
    try t.expectError(error.ProtectedSharedBacking, validateSharedAllocation(&allocator, 0x100000, 1));
    try t.expectError(error.SharedBackingNotAllocated, validateSharedAllocation(&allocator, 0x103000, 2));
    try t.expectError(error.SharedBackingNotAllocated, validateSharedAllocation(&allocator, 0x200000, 1));
}
