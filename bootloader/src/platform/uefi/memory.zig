//! Convert the complete EFI descriptor map without allocating or changing it.
const std = @import("std");
const uefi = std.os.uefi;
const protocol = @import("boot_protocol");
const max_descriptors = 1024;
pub const Error = protocol.MemoryMapError || protocol.RangeError || error{
    UnsupportedMemoryMap,
    TooManyFirmwareDescriptors,
    FirmwareMapOverlap,
    UnalignedFirmwareDescriptor,
    NoBootRam,
    InvalidBootArena,
    BootArenaNotOwned,
    OverlappingBootArenas,
};

fn rangeOf(descriptor: *const uefi.tables.MemoryDescriptor) Error!protocol.PhysicalRange {
    if (descriptor.physical_start % 4096 != 0) return error.UnalignedFirmwareDescriptor;
    const bytes = @mulWithOverflow(descriptor.number_of_pages, @as(u64, 4096));
    if (bytes[1] != 0) return error.PhysicalRangeOverflow;
    const range: protocol.PhysicalRange = .{ .base = descriptor.physical_start, .length = bytes[0] };
    _ = try range.endExclusive();
    return range;
}
fn ramBacked(kind: uefi.tables.MemoryType) bool {
    return switch (kind) {
        .loader_code,
        .loader_data,
        .boot_services_code,
        .boot_services_data,
        .runtime_services_code,
        .runtime_services_data,
        .conventional_memory,
        .acpi_reclaim_memory,
        .acpi_memory_nvs,
        => true,
        else => false,
    };
}
fn memoryKind(descriptor: *const uefi.tables.MemoryDescriptor) protocol.MemoryKind {
    // Runtime ownership wins even if firmware applies it to an unusual type.
    if (descriptor.attribute.memory_runtime) return .firmware_runtime;
    return switch (descriptor.type) {
        .conventional_memory, .boot_services_code, .boot_services_data => .usable,
        .loader_code, .loader_data => .loader_reclaimable,
        .runtime_services_code, .runtime_services_data => .firmware_runtime,
        .memory_mapped_io, .memory_mapped_io_port_space => .mmio,
        // ACPI reclaim data is preserved until the kernel has parsed it.
        // Unknown, unaccepted, unusable and persistent memory stays reserved.
        else => .reserved,
    };
}
fn recordRam(builder: *protocol.MemoryMap, range: protocol.PhysicalRange, boot_ram: *?protocol.PhysicalRange) Error!void {
    try builder.addRam(range);
    const end = try range.endExclusive();
    if (boot_ram.*) |*envelope| {
        const envelope_end = try envelope.endExclusive();
        const base = @min(envelope.base, range.base);
        envelope.* = .{ .base = base, .length = @max(envelope_end, end) - base };
    } else boot_ram.* = range;
}

fn validateArena(map: uefi.tables.MemoryMapSlice, order: []const u16, arena: protocol.PhysicalRange) Error!void {
    if (arena.length == 0 or arena.base % 4096 != 0 or arena.length % 4096 != 0)
        return error.InvalidBootArena;
    const arena_end = try arena.endExclusive();
    var cursor = arena.base;
    for (order) |index| {
        const descriptor = map.getUnchecked(index);
        const range = try rangeOf(descriptor);
        const end = try range.endExclusive();
        if (end <= cursor) continue;
        if (range.base > cursor or descriptor.attribute.memory_runtime or
            (descriptor.type != .loader_data and descriptor.type != .loader_code))
            return error.BootArenaNotOwned;
        cursor = @min(end, arena_end);
        if (cursor == arena_end) return;
    }
    return error.BootArenaNotOwned;
}

/// Each caller-selected arena must be completely backed by non-runtime EFI
/// loader pages. They may belong to separate banks on any supported ISA. The
/// ram prefix is an informational envelope, including holes between banks;
/// only normalized usable regions grant allocation permission. The original
/// map stays byte-for-byte intact, including all 64-bit EFI attributes.
pub fn populate(map: uefi.tables.MemoryMapSlice, info: *protocol.BootInfo) Error!void {
    if (map.info.descriptor_version != 1 or map.info.descriptor_size < @sizeOf(uefi.tables.MemoryDescriptor) or
        map.info.descriptor_size % @alignOf(uefi.tables.MemoryDescriptor) != 0 or
        map.info.descriptor_size > std.math.maxInt(u32)) return error.UnsupportedMemoryMap;
    if (map.info.len > max_descriptors) return error.TooManyFirmwareDescriptors;
    var order: [max_descriptors]u16 = undefined;
    var count: usize = 0;
    for (0..map.info.len) |index| {
        const descriptor = map.getUnchecked(index);
        const range = try rangeOf(descriptor);
        if (range.length == 0) continue;
        var position = count;
        while (position > 0 and map.getUnchecked(order[position - 1]).physical_start > range.base) : (position -= 1)
            order[position] = order[position - 1];
        order[position] = @intCast(index);
        count += 1;
    }
    var previous_end: u64 = 0;
    for (order[0..count], 0..) |index, position| {
        const range = try rangeOf(map.getUnchecked(index));
        if (position != 0 and range.base < previous_end) return error.FirmwareMapOverlap;
        previous_end = try range.endExclusive();
    }
    try validateArena(map, order[0..count], info.loader_reserved);
    try validateArena(map, order[0..count], info.kernel_reserved);
    if (info.loader_reserved.base < try info.kernel_reserved.endExclusive() and
        info.kernel_reserved.base < try info.loader_reserved.endExclusive())
        return error.OverlappingBootArenas;
    if (info.wifi.reservation.length != 0) {
        try validateArena(map, order[0..count], info.wifi.reservation);
        const end = try info.wifi.reservation.endExclusive();
        for ([_]protocol.PhysicalRange{ info.loader_reserved, info.kernel_reserved }) |arena|
            if (info.wifi.reservation.base < try arena.endExclusive() and arena.base < end)
                return error.OverlappingBootArenas;
    }

    if (info.drivers.count > protocol.max_boot_drivers) return error.InvalidBootArena;
    if (info.apps.reservation.length != 0) {
        try validateArena(map, order[0..count], info.apps.reservation);
        const end = try info.apps.reservation.endExclusive();
        for ([_]protocol.PhysicalRange{ info.loader_reserved, info.kernel_reserved, info.wifi.reservation }) |arena|
            if (arena.length != 0 and info.apps.reservation.base < try arena.endExclusive() and arena.base < end) return error.OverlappingBootArenas;
    }
    for (info.drivers.records[0..info.drivers.count], 0..) |driver, i| {
        try validateArena(map, order[0..count], driver.reservation);
        const end = try driver.reservation.endExclusive();
        for ([_]protocol.PhysicalRange{ info.loader_reserved, info.kernel_reserved, info.wifi.reservation, info.apps.reservation }) |arena|
            if (arena.length != 0 and driver.reservation.base < try arena.endExclusive() and arena.base < end) return error.OverlappingBootArenas;
        for (info.drivers.records[0..i]) |prior|
            if (driver.reservation.base < try prior.reservation.endExclusive() and prior.reservation.base < end) return error.OverlappingBootArenas;
    }
    var builder: protocol.MemoryMap = .{};
    var pending_ram: ?protocol.PhysicalRange = null;
    var boot_ram: ?protocol.PhysicalRange = null;
    // Merge adjacent RAM descriptors before using the bounded common builder.
    for (order[0..count]) |index| {
        const descriptor = map.getUnchecked(index);
        const range = try rangeOf(descriptor);
        if (ramBacked(descriptor.type)) {
            if (pending_ram) |*pending| {
                if (try pending.endExclusive() == range.base) {
                    pending.length = try range.endExclusive() - pending.base;
                    continue;
                }
                try recordRam(&builder, pending.*, &boot_ram);
            }
            pending_ram = range;
        } else if (pending_ram) |pending| {
            try recordRam(&builder, pending, &boot_ram);
            pending_ram = null;
        }
    }
    if (pending_ram) |pending| try recordRam(&builder, pending, &boot_ram);

    var pending_reservation: ?struct { range: protocol.PhysicalRange, kind: protocol.MemoryKind } = null;
    for (order[0..count]) |index| {
        const descriptor = map.getUnchecked(index);
        const kind = memoryKind(descriptor);
        const range = try rangeOf(descriptor);
        if (kind != .usable) {
            if (pending_reservation) |*pending| {
                if (pending.kind == kind and try pending.range.endExclusive() == range.base) {
                    pending.range.length = try range.endExclusive() - pending.range.base;
                    continue;
                }
                try builder.addReservation(pending.range, pending.kind);
            }
            pending_reservation = .{ .range = range, .kind = kind };
        } else if (pending_reservation) |pending| {
            try builder.addReservation(pending.range, pending.kind);
            pending_reservation = null;
        }
    }
    if (pending_reservation) |pending| try builder.addReservation(pending.range, pending.kind);
    try builder.addReservation(info.loader_reserved, .loader_reclaimable);
    try builder.addReservation(info.kernel_reserved, .kernel);
    if (info.wifi.reservation.length != 0)
        try builder.addReservation(info.wifi.reservation, .reserved);
    for (info.drivers.records[0..info.drivers.count]) |driver| try builder.addReservation(driver.reservation, .reserved);
    if (info.apps.reservation.length != 0) try builder.addReservation(info.apps.reservation, .reserved);
    if (info.framebuffer.base != 0)
        try builder.addReservation(.{ .base = info.framebuffer.base, .length = info.framebuffer.size }, .mmio);
    info.ram = boot_ram orelse return error.NoBootRam;
    try builder.finalize(info);
    const raw_size = @mulWithOverflow(map.info.len, map.info.descriptor_size);
    if (raw_size[1] != 0) return error.PhysicalRangeOverflow;
    info.firmware_memory_map = .{ .base = @intFromPtr(map.ptr), .length = raw_size[0] };
    info.firmware_descriptor_size = @intCast(map.info.descriptor_size);
    info.firmware_descriptor_version = map.info.descriptor_version;
}

test "EFI Wi-Fi assets remain reserved and require distinct owned loader pages" {
    var descriptors = [_]uefi.tables.MemoryDescriptor{
        testDescriptor(0x100000, 0x300, .loader_data, false),
        testDescriptor(0x800000, 0x200, .loader_data, false),
    };
    var info = testInfo();
    info.wifi.reservation = .{ .base = 0x800000, .length = 0x200000 };
    try populate(testMap(&descriptors), &info);
    var found = false;
    for (info.memory_regions[0..info.memory_region_count]) |region| {
        if (region.range.base == info.wifi.reservation.base) {
            try std.testing.expectEqual(@backingInt(protocol.MemoryKind.reserved), region.kind);
            try std.testing.expectEqual(info.wifi.reservation, region.range);
            found = true;
        }
    }
    try std.testing.expect(found);
    descriptors[1].type = .conventional_memory;
    try std.testing.expectError(error.BootArenaNotOwned, populate(testMap(&descriptors), &info));
    descriptors[1].type = .loader_data;
    descriptors[1].attribute.memory_runtime = true;
    try std.testing.expectError(error.BootArenaNotOwned, populate(testMap(&descriptors), &info));
    info.wifi.reservation = info.loader_reserved;
    try std.testing.expectError(error.OverlappingBootArenas, populate(testMap(&descriptors), &info));
}

fn testDescriptor(base: u64, pages: u64, kind: uefi.tables.MemoryType, runtime: bool) uefi.tables.MemoryDescriptor {
    var attribute: uefi.tables.MemoryDescriptorAttribute = @bitCast(@as(u64, 0));
    attribute.memory_runtime = runtime;
    return .{ .type = kind, .physical_start = base, .virtual_start = 0, .number_of_pages = pages, .attribute = attribute };
}
fn testInfo() protocol.BootInfo {
    return .{
        .header = protocol.Header.init(.x86_64),
        .uart_base = 0,
        .dtb = .{ .base = 0, .length = 0 },
        .kernel_image = .{ .base = 0x200000, .length = 1 },
        .ram = .{ .base = 0, .length = 0 },
        .loader_reserved = .{ .base = 0x100000, .length = 0x100000 },
        .kernel_reserved = .{ .base = 0x200000, .length = 0x200000 },
        .flags = 0,
    };
}
fn testMap(descriptors: []uefi.tables.MemoryDescriptor) uefi.tables.MemoryMapSlice {
    return .{ .ptr = @ptrCast(descriptors.ptr), .info = .{ .key = undefined, .descriptor_size = @sizeOf(uefi.tables.MemoryDescriptor), .descriptor_version = 1, .len = descriptors.len } };
}
test "EFI conversion sorts, overlays boot arenas and preserves runtime ownership" {
    var descriptors = [_]uefi.tables.MemoryDescriptor{
        testDescriptor(0x500000, 1, .conventional_memory, true),
        testDescriptor(0x100000, 0x300, .loader_data, false),
        testDescriptor(0x400000, 0x100, .conventional_memory, false),
    };
    const original = descriptors;
    var info = testInfo();
    try populate(testMap(&descriptors), &info);
    try std.testing.expectEqualDeep(original, descriptors);
    try std.testing.expectEqual(@as(u64, 0x100000), info.ram.base);
    var found_runtime = false;
    for (info.memory_regions[0..info.memory_region_count]) |region| {
        if (region.range.base == 0x500000) {
            try std.testing.expectEqual(@backingInt(protocol.MemoryKind.firmware_runtime), region.kind);
            found_runtime = true;
        }
        if (region.isUsable()) try std.testing.expect(region.range.base >= 0x400000);
    }
    try std.testing.expect(found_runtime);
}
test "EFI conversion rejects overlapping and overflowing descriptors" {
    var descriptors = [_]uefi.tables.MemoryDescriptor{
        testDescriptor(0x100000, 0x300, .loader_data, false),
        testDescriptor(0x200000, 1, .conventional_memory, false),
    };
    var info = testInfo();
    try std.testing.expectError(error.FirmwareMapOverlap, populate(testMap(&descriptors), &info));
    descriptors[1] = testDescriptor(0x400000, std.math.maxInt(u64), .conventional_memory, false);
    try std.testing.expectError(error.PhysicalRangeOverflow, populate(testMap(&descriptors), &info));
}

test "EFI conversion retains extended descriptor bytes and rejects unsupported layout" {
    const ExtendedDescriptor = extern struct {
        descriptor: uefi.tables.MemoryDescriptor,
        extension: [16]u8,
    };
    var descriptor: ExtendedDescriptor = .{
        .descriptor = testDescriptor(0x100000, 0x400, .loader_data, false),
        .extension = @splat(0xa5),
    };
    descriptor.descriptor.attribute.wb = true;
    const original = descriptor;
    const map: uefi.tables.MemoryMapSlice = .{
        .ptr = @ptrCast(&descriptor),
        .info = .{ .key = undefined, .descriptor_size = @sizeOf(ExtendedDescriptor), .descriptor_version = 1, .len = 1 },
    };
    var info = testInfo();
    try populate(map, &info);
    try std.testing.expectEqualDeep(original, descriptor);
    try std.testing.expectEqual(@as(u64, @intFromPtr(&descriptor)), info.firmware_memory_map.base);
    try std.testing.expectEqual(@as(u64, @sizeOf(ExtendedDescriptor)), info.firmware_memory_map.length);
    try std.testing.expectEqual(@as(u32, @sizeOf(ExtendedDescriptor)), info.firmware_descriptor_size);
    var invalid_map = map;
    invalid_map.info.descriptor_version = 2;
    try std.testing.expectError(error.UnsupportedMemoryMap, populate(invalid_map, &info));
    invalid_map = map;
    invalid_map.info.descriptor_size = 39;
    try std.testing.expectError(error.UnsupportedMemoryMap, populate(invalid_map, &info));
    invalid_map = map;
    invalid_map.info.len = max_descriptors + 1;
    try std.testing.expectError(error.TooManyFirmwareDescriptors, populate(invalid_map, &info));
}

test "EFI conversion rejects firmware-owned holes inside a dynamic boot arena" {
    var descriptors = [_]uefi.tables.MemoryDescriptor{
        testDescriptor(0x100000, 0x100, .loader_data, false),
        testDescriptor(0x200000, 0x100, .reserved_memory_type, false),
        testDescriptor(0x300000, 0x100, .loader_data, false),
    };
    var info = testInfo();
    try std.testing.expectError(error.BootArenaNotOwned, populate(testMap(&descriptors), &info));
    descriptors[1] = testDescriptor(0x200001, 1, .loader_data, false);
    try std.testing.expectError(error.UnalignedFirmwareDescriptor, populate(testMap(&descriptors), &info));
}

test "EFI conversion conservatively retains unknown and non-RAM runtime memory" {
    var descriptors = [_]uefi.tables.MemoryDescriptor{
        testDescriptor(0x100000, 0x400, .loader_data, false),
        testDescriptor(0x500000, 1, @fromBackingInt(0x80000001), false),
        testDescriptor(0x600000, 1, .memory_mapped_io, true),
    };
    var info = testInfo();
    try populate(testMap(&descriptors), &info);
    var unknown_reserved = false;
    var runtime_retained = false;
    for (info.memory_regions[0..info.memory_region_count]) |region| {
        if (region.range.base == 0x500000) {
            try std.testing.expectEqual(@backingInt(protocol.MemoryKind.reserved), region.kind);
            unknown_reserved = true;
        }
        if (region.range.base == 0x600000) {
            try std.testing.expectEqual(@backingInt(protocol.MemoryKind.firmware_runtime), region.kind);
            runtime_retained = true;
        }
    }
    try std.testing.expect(unknown_reserved and runtime_retained);
}

test "EFI conversion refuses a map exceeding the normalized handoff capacity" {
    var descriptors: [81]uefi.tables.MemoryDescriptor = undefined;
    descriptors[0] = testDescriptor(0x100000, 0x300, .loader_data, false);
    for (descriptors[1..], 0..) |*descriptor, index| {
        descriptor.* = testDescriptor(0x400000 + index * 4096, 1, if (index % 2 == 0) .conventional_memory else .acpi_reclaim_memory, false);
    }
    var info = testInfo();
    try std.testing.expectError(error.TooManyRegions, populate(testMap(&descriptors), &info));
}

test "EFI conversion accepts separate high dynamic arenas on every supported architecture" {
    inline for (.{ protocol.Architecture.x86_64, protocol.Architecture.aarch64, protocol.Architecture.riscv64 }) |arch| {
        const loader_base: u64 = 0x100100000;
        const kernel_base: u64 = 0x200200000;
        var descriptors = [_]uefi.tables.MemoryDescriptor{
            testDescriptor(kernel_base, 0x200, .loader_data, false),
            testDescriptor(0x40000000, 0x100, .conventional_memory, false),
            testDescriptor(loader_base, 0x100, .loader_data, false),
            testDescriptor(0, 0x100, .conventional_memory, false),
        };
        var info = testInfo();
        info.header.architecture = @backingInt(arch);
        info.loader_reserved = .{ .base = loader_base, .length = 0x100000 };
        info.kernel_reserved = .{ .base = kernel_base, .length = 0x200000 };
        info.kernel_image = .{ .base = kernel_base, .length = 1 };
        try populate(testMap(&descriptors), &info);
        try std.testing.expectEqualDeep(protocol.PhysicalRange{ .base = 0, .length = kernel_base + 0x200000 }, info.ram);
        try std.testing.expect(info.memory_regions[0].isUsable()); // No guessed low-memory reservation.
        for (info.memory_regions[0..info.memory_region_count]) |region| {
            if (region.range.base == kernel_base) try std.testing.expectEqual(@backingInt(protocol.MemoryKind.kernel), region.kind);
        }
        try std.testing.expectEqual(@as(u64, @intFromPtr(&descriptors)), info.firmware_memory_map.base);
    }
}

test "EFI dynamic arenas require complete page-aligned loader ownership" {
    var descriptors = [_]uefi.tables.MemoryDescriptor{
        testDescriptor(0x1000000, 1, .loader_code, false),
        testDescriptor(0x1001000, 2, .loader_data, false),
        testDescriptor(0x2000000, 2, .loader_data, false),
    };
    var info = testInfo();
    info.loader_reserved = .{ .base = 0x1000000, .length = 0x3000 };
    info.kernel_reserved = .{ .base = 0x2000000, .length = 0x2000 };
    info.kernel_image = .{ .base = info.kernel_reserved.base, .length = 1 };
    try populate(testMap(&descriptors), &info);
    descriptors[1].type = .conventional_memory;
    try std.testing.expectError(error.BootArenaNotOwned, populate(testMap(&descriptors), &info));
    descriptors[1].type = .loader_data;
    descriptors[1].attribute.memory_runtime = true;
    try std.testing.expectError(error.BootArenaNotOwned, populate(testMap(&descriptors), &info));
    descriptors[1].attribute.memory_runtime = false;
    info.loader_reserved.length = 0x4000;
    try std.testing.expectError(error.BootArenaNotOwned, populate(testMap(&descriptors), &info));
    info.loader_reserved = .{ .base = info.kernel_reserved.base, .length = 4096 };
    try std.testing.expectError(error.OverlappingBootArenas, populate(testMap(&descriptors), &info));
    info.loader_reserved.base += 1;
    try std.testing.expectError(error.InvalidBootArena, populate(testMap(&descriptors), &info));
    info.loader_reserved = .{ .base = 0x1000000, .length = 0 };
    try std.testing.expectError(error.InvalidBootArena, populate(testMap(&descriptors), &info));
}
