//! Bounded PCI configuration discovery. Discovery never writes a BAR, enables
//! bus mastering or attempts a destructive BAR size probe. Callers serialize.
const std = @import("std");
pub const Bdf = struct {
    segment: u16 = 0,
    bus: u8,
    device: u5,
    function: u3,
    pub fn eql(self: Bdf, other: Bdf) bool {
        return self.segment == other.segment and self.bus == other.bus and self.device == other.device and self.function == other.function;
    }
};
pub const Config = struct {
    context: *anyopaque,
    read32: *const fn (*anyopaque, Bdf, u16) anyerror!u32,
    write32: *const fn (*anyopaque, Bdf, u16, u32) anyerror!void,
    pub fn read(self: Config, bdf: Bdf, offset: u16) !u32 {
        if (offset % 4 != 0 or offset > 4092) return error.InvalidConfigOffset;
        return self.read32(self.context, bdf, offset);
    }
    pub fn byte(self: Config, bdf: Bdf, offset: u16) !u8 {
        if (offset > 4095) return error.InvalidConfigOffset;
        const shift: u5 = @intCast((offset & 3) * 8);
        return @truncate(try self.read(bdf, offset & ~@as(u16, 3)) >> shift);
    }
};
pub const Device = struct {
    bdf: Bdf,
    vendor: u16,
    product: u16,
    class: u8,
    subclass: u8,
    programming_interface: u8,
    revision: u8,
    header: u8,
    pub fn wireless(self: Device) bool {
        return self.class == 2 and self.subclass == 0x80;
    }
};
pub const Inventory = struct {
    items: [16]Device = undefined,
    count: usize = 0,
    dropped: usize = 0,
    functions_checked: usize = 0,
};
/// Inclusive bus range supplied by platform policy, not by an application.
/// Mechanism-one uses only segment zero; ECAM callers supply their real segment.
pub fn wirelessInventory(config: Config, segment: u16, first: u8, last: u8) !Inventory {
    if (last < first) return error.InvalidBusRange;
    var result: Inventory = .{};
    var bus: u16 = first;
    while (bus <= last) : (bus += 1) {
        for (0..32) |slot| {
            var bdf: Bdf = .{ .segment = segment, .bus = @intCast(bus), .device = @intCast(slot), .function = 0 };
            const first_id = try config.read(bdf, 0);
            result.functions_checked += 1;
            if (absent(first_id)) continue;
            const header = try config.byte(bdf, 0x0e);
            const functions: usize = if (header & 0x80 != 0) 8 else 1;
            for (0..functions) |function| {
                bdf.function = @intCast(function);
                const id = if (function == 0) first_id else try config.read(bdf, 0);
                if (function != 0) result.functions_checked += 1;
                if (absent(id)) continue;
                const class = try config.read(bdf, 8);
                const item: Device = .{ .bdf = bdf, .vendor = @truncate(id), .product = @truncate(id >> 16), .class = @truncate(class >> 24), .subclass = @truncate(class >> 16), .programming_interface = @truncate(class >> 8), .revision = @truncate(class), .header = if (function == 0) header else try config.byte(bdf, 0x0e) };
                if (!item.wireless()) continue;
                if (result.count == result.items.len) {
                    result.dropped += 1;
                    continue;
                }
                result.items[result.count] = item;
                result.count += 1;
            }
        }
    }
    return result;
}
fn absent(id: u32) bool {
    return id & 0xffff == 0xffff or id & 0xffff == 0;
}

/// Memory BAR address only. Size is a separately supplied device/platform
/// requirement; this routine never writes all ones to discover a live BAR size.
pub fn memoryBar(config: Config, device: Device, index: u3) !u64 {
    if (device.header & 0x7f != 0 or index > 5) return error.UnsupportedHeader;
    // A requested slot cannot be the high dword of an earlier 64-bit BAR.
    var previous: u8 = 0;
    while (previous < index) {
        const value = try config.read(device.bdf, 0x10 + @as(u16, previous) * 4);
        const width: u8 = if (value & 1 == 0 and (value >> 1) & 3 == 2) 2 else 1;
        if (previous + width > index) return error.HighBarDword;
        previous += width;
    }
    const low = try config.read(device.bdf, 0x10 + @as(u16, index) * 4);
    if (low & 1 != 0) return error.IoBarUnsupported;
    const kind = (low >> 1) & 3;
    const base: u64 = switch (kind) {
        0 => low & 0xfffffff0,
        2 => if (index == 5) return error.InvalidBar else @as(u64, low & 0xfffffff0) | (@as(u64, try config.read(device.bdf, 0x14 + @as(u16, index) * 4)) << 32),
        else => return error.InvalidBar,
    };
    if (base == 0) return error.UnassignedBar;
    return base;
}
/// Safe command-word update: upper status half is zero, avoiding W1C clears.
/// Call only after proving MMIO/DMA ownership. No automatic activation in discovery.
pub fn writeCommand(config: Config, device: Device, command: u16) !void {
    const identity = @as(u32, device.vendor) | @as(u32, device.product) << 16;
    if (try config.read(device.bdf, 0) != identity) return error.DeviceChanged;
    try config.write32(config.context, device.bdf, 4, command);
    if (@as(u16, @truncate(try config.read(device.bdf, 4))) != command) return error.CommandRejected;
}
pub fn legacyAddress(bdf: Bdf, offset: u16) !u32 {
    if (bdf.segment != 0) return error.UnsupportedSegment;
    if (offset >= 256 or offset % 4 != 0) return error.InvalidConfigOffset;
    return 0x80000000 | @as(u32, bdf.bus) << 16 | @as(u32, bdf.device) << 11 | @as(u32, bdf.function) << 8 | offset;
}
pub fn ecamAddress(base: u64, span: u64, segment: u16, first: u8, last: u8, bdf: Bdf, offset: u16) !u64 {
    if (last < first or bdf.segment != segment or bdf.bus < first or bdf.bus > last) return error.InvalidBusRange;
    if (base % (1 << 20) != 0 or offset > 4092 or offset % 4 != 0) return error.InvalidConfigOffset;
    const delta = @as(u64, bdf.bus - first) << 20 | @as(u64, bdf.device) << 15 | @as(u64, bdf.function) << 12 | offset;
    if (delta > span or span - delta < 4) return error.UnmappedEcam;
    const address = @addWithOverflow(base, delta);
    if (address[1] != 0 or address[0] > std.math.maxInt(u64) - 4) return error.AddressOverflow;
    return address[0];
}

test {
    _ = @import("tests.zig");
}
