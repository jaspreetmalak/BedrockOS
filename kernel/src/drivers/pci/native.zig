//! Native configuration access is selected by the kernel's platform policy.
//! ECAM must come from a verified platform resource, never a guessed address.
const builtin = @import("builtin");
const std = @import("std");
const protocol = @import("boot_protocol");
const pci = @import("pci");
var legacy_context: u8 = 0;
pub fn legacy(info: *const protocol.BootInfo) !pci.Config {
    if (builtin.cpu.arch != .x86_64 or info.boot_environment != @backingInt(protocol.BootEnvironment.uefi)) return error.UnsupportedConfigTransport;
    return .{ .context = &legacy_context, .read32 = legacyRead, .write32 = legacyWrite };
}
fn select(address: u32) void {
    if (builtin.cpu.arch == .x86_64) asm volatile ("outl %[value], %[port]"
        :
        : [value] "{eax}" (address),
          [port] "{dx}" (@as(u16, 0xcf8)),
        : .{ .memory = true }) else unreachable;
}
fn legacyRead(_: *anyopaque, bdf: pci.Bdf, offset: u16) !u32 {
    const address = try pci.legacyAddress(bdf, offset);
    if (builtin.cpu.arch == .x86_64) {
        select(address);
        return asm volatile ("inl %[port], %[value]"
            : [value] "={eax}" (-> u32),
            : [port] "{dx}" (@as(u16, 0xcfc)),
            : .{ .memory = true });
    } else return error.UnsupportedConfigTransport;
}
fn legacyWrite(_: *anyopaque, bdf: pci.Bdf, offset: u16, value: u32) !void {
    const address = try pci.legacyAddress(bdf, offset);
    if (builtin.cpu.arch == .x86_64) {
        select(address);
        asm volatile ("outl %[value], %[port]"
            :
            : [value] "{eax}" (value),
              [port] "{dx}" (@as(u16, 0xcfc)),
            : .{ .memory = true });
    } else return error.UnsupportedConfigTransport;
}
pub const Ecam = struct {
    base: u64,
    length: u64,
    segment: u16,
    first: u8,
    last: u8,
    pub fn init(info: *const protocol.BootInfo, base: u64, length: u64, segment: u16, first: u8, last: u8) !Ecam {
        if (last < first or base == 0 or base % (1 << 20) != 0 or length != (@as(u64, last) - first + 1) << 20) return error.InvalidEcam;
        const range: protocol.PhysicalRange = .{ .base = base, .length = length };
        const aperture_end = try range.endExclusive();
        if (info.memory_region_count == 0 or info.memory_region_count > protocol.max_memory_regions) return error.InvalidMemoryRegionCount;
        if (info.mapped_range_count == 0 or info.mapped_range_count > protocol.max_mapped_ranges) return error.InvalidMappedRangeCount;
        if (info.loader_reserved.length == 0 or info.kernel_reserved.length == 0) return error.InvalidReservedRange;
        if ((info.framebuffer.base == 0) != (info.framebuffer.size == 0)) return error.InvalidFramebufferRange;
        for ([_]protocol.PhysicalRange{ info.loader_reserved, info.kernel_reserved, info.wifi.reservation, info.apps.reservation, .{ .base = info.framebuffer.base, .length = info.framebuffer.size } }) |protected| {
            const protected_end = try protected.endExclusive();
            if (protected.length != 0 and base < protected_end and protected.base < aperture_end) return error.ProtectedMemoryAlias;
        }
        if (info.drivers.count > protocol.max_boot_drivers) return error.InvalidDriverRecord;
        for (info.drivers.records[0..info.drivers.count]) |driver|
            if (base < try driver.reservation.endExclusive() and driver.reservation.base < aperture_end) return error.ProtectedMemoryAlias;
        var prior_end: u64 = 0;
        for (info.memory_regions[0..info.memory_region_count], 0..) |region, i| {
            const region_end = try region.range.endExclusive();
            if (region.range.length == 0 or (i != 0 and region.range.base < prior_end)) return error.InvalidMemoryMap;
            if (region.isUsable() and base < region_end and region.range.base < aperture_end) return error.ProtectedMemoryAlias;
            prior_end = region_end;
        }
        prior_end = 0;
        for (info.mapped_ranges[0..info.mapped_range_count], 0..) |mapped, i| {
            const mapped_end = try mapped.endExclusive();
            if (mapped.length == 0 or (i != 0 and mapped.base < prior_end)) return error.InvalidMappedRanges;
            prior_end = mapped_end;
        }
        if (!info.isMapped(range)) return error.UnmappedEcam;
        return .{ .base = base, .length = length, .segment = segment, .first = first, .last = last };
    }
    pub fn config(self: *Ecam) pci.Config {
        return .{ .context = self, .read32 = read, .write32 = write };
    }
    fn read(context: *anyopaque, bdf: pci.Bdf, offset: u16) !u32 {
        const self: *Ecam = @ptrCast(@alignCast(context));
        const address = try pci.ecamAddress(self.base, self.length, self.segment, self.first, self.last, bdf, offset);
        const pointer: *const volatile u32 = @ptrFromInt(address);
        return pointer.*;
    }
    fn write(context: *anyopaque, bdf: pci.Bdf, offset: u16, value: u32) !void {
        const self: *Ecam = @ptrCast(@alignCast(context));
        const address = try pci.ecamAddress(self.base, self.length, self.segment, self.first, self.last, bdf, offset);
        const pointer: *volatile u32 = @ptrFromInt(address);
        pointer.* = value;
        _ = pointer.*;
    }
};

fn apertureFixture() protocol.BootInfo {
    var info: protocol.BootInfo = undefined;
    info.wifi = .{};
    info.drivers = .{};
    info.apps = .{};
    info.loader_reserved = .{ .base = 0x100000, .length = 0x100000 };
    info.kernel_reserved = .{ .base = 0x200000, .length = 0x100000 };
    info.framebuffer = .{ .base = 0x300000, .size = 0x10000 };
    info.memory_region_count = 1;
    info.memory_regions[0] = .{ .range = .{ .base = 0x400000, .length = 0x400000 }, .kind = @backingInt(protocol.MemoryKind.usable), .attributes = 0 };
    info.mapped_range_count = 1;
    info.mapped_ranges[0] = .{ .base = 0x100000, .length = 0x800000 };
    info.ram = .{ .base = 0x100000, .length = 0x800000 }; // Contains mapped gaps.
    return info;
}
test "ECAM aperture cannot alias loader kernel framebuffer or usable RAM" {
    var info = apertureFixture();
    for ([_]u64{ 0x100000, 0x200000, 0x300000, 0x400000, 0x700000 }) |base|
        try std.testing.expectError(error.ProtectedMemoryAlias, Ecam.init(&info, base, 1 << 20, 0, 0, 0));
    try std.testing.expectError(error.ProtectedMemoryAlias, Ecam.init(&info, 0x700000, 2 << 20, 0, 0, 1));
    var ecam = try Ecam.init(&info, 0x800000, 1 << 20, 7, 4, 4);
    try std.testing.expectEqual(@as(u64, 0x800000), ecam.base);
    try std.testing.expectEqual(@as(u16, 7), ecam.segment);
    try std.testing.expect(ecam.config().context == @as(*anyopaque, @ptrCast(&ecam)));
    // No provider read/write callback is invoked in these native tests.
}
test "ECAM requires complete mapped coverage and bounded sorted map records" {
    var info = apertureFixture();
    info.memory_region_count = protocol.max_memory_regions + 1;
    try std.testing.expectError(error.InvalidMemoryRegionCount, Ecam.init(&info, 0x800000, 1 << 20, 0, 0, 0));
    info = apertureFixture();
    info.mapped_range_count = protocol.max_mapped_ranges + 1;
    try std.testing.expectError(error.InvalidMappedRangeCount, Ecam.init(&info, 0x800000, 1 << 20, 0, 0, 0));
    info = apertureFixture();
    info.mapped_ranges[0].length = 0x7ff000;
    try std.testing.expectError(error.UnmappedEcam, Ecam.init(&info, 0x800000, 1 << 20, 0, 0, 0));
    info = apertureFixture();
    info.mapped_range_count = 2;
    info.mapped_ranges[1] = info.mapped_ranges[0];
    try std.testing.expectError(error.InvalidMappedRanges, Ecam.init(&info, 0x800000, 1 << 20, 0, 0, 0));
    info = apertureFixture();
    info.memory_region_count = 2;
    info.memory_regions[1] = info.memory_regions[0];
    try std.testing.expectError(error.InvalidMemoryMap, Ecam.init(&info, 0x800000, 1 << 20, 0, 0, 0));
}
test "ECAM rejects malformed aperture and overflowing protected extents before provider access" {
    var info = apertureFixture();
    try std.testing.expectError(error.InvalidEcam, Ecam.init(&info, 0x800001, 1 << 20, 0, 0, 0));
    try std.testing.expectError(error.InvalidEcam, Ecam.init(&info, 0x800000, 1 << 20, 0, 1, 0));
    try std.testing.expectError(error.InvalidEcam, Ecam.init(&info, 0x800000, 0, 0, 0, 0));
    try std.testing.expectError(error.PhysicalRangeOverflow, Ecam.init(&info, 0xfffffffffff00000, 1 << 20, 0, 0, 0));
    info.kernel_reserved = .{ .base = 0xfffffffffffff000, .length = 0x2000 };
    try std.testing.expectError(error.PhysicalRangeOverflow, Ecam.init(&info, 0x800000, 1 << 20, 0, 0, 0));
}

test "ECAM cannot alias an interior application archive reservation or overflow its bounds" {
    var info = apertureFixture();
    info.apps.reservation = .{ .base = 0x880000, .length = 0x1000 };
    try std.testing.expectError(error.ProtectedMemoryAlias, Ecam.init(&info, 0x800000, 1 << 20, 0, 0, 0));
    info.apps.reservation = .{ .base = 0x900000, .length = 0x1000 };
    _ = try Ecam.init(&info, 0x800000, 1 << 20, 0, 0, 0);
    info.apps.reservation = .{ .base = 0xfffffffffffff000, .length = 0x2000 };
    try std.testing.expectError(error.PhysicalRangeOverflow, Ecam.init(&info, 0x800000, 1 << 20, 0, 0, 0));
}
