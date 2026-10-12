const std = @import("std");
const pci = @import("root.zig");
const Fake = struct {
    words: [64]u32 = @splat(0),
    writes: usize = 0,
    command_write: u32 = 0,
    fn get(context: *anyopaque, _: pci.Bdf, offset: u16) !u32 {
        const self: *Fake = @ptrCast(@alignCast(context));
        return self.words[offset / 4];
    }
    fn put(context: *anyopaque, _: pci.Bdf, offset: u16, value: u32) !void {
        const self: *Fake = @ptrCast(@alignCast(context));
        self.writes += 1;
        self.command_write = value;
        if (offset == 4) self.words[1] = (self.words[1] & 0xffff0000) | (value & 0xffff);
    }
    fn config(self: *Fake) pci.Config {
        return .{ .context = self, .read32 = get, .write32 = put };
    }
};
const device: pci.Device = .{ .bdf = .{ .bus = 4, .device = 1, .function = 0 }, .vendor = 0x14c3, .product = 0x0616, .class = 2, .subclass = 0x80, .programming_interface = 0, .revision = 1, .header = 0 };
test "PCI BAR parser uses full 64-bit base and rejects high halves without destructive size writes" {
    var fake: Fake = .{};
    fake.words[4] = 4;
    fake.words[5] = 1;
    try std.testing.expectEqual(@as(u64, 0x1_0000_0000), try pci.memoryBar(fake.config(), device, 0));
    try std.testing.expectError(error.HighBarDword, pci.memoryBar(fake.config(), device, 1));
    fake.words[4] = 0xc0000001;
    try std.testing.expectError(error.IoBarUnsupported, pci.memoryBar(fake.config(), device, 0));
    fake.words[4] = 0;
    try std.testing.expectError(error.UnassignedBar, pci.memoryBar(fake.config(), device, 0));
    fake.words[9] = 4;
    try std.testing.expectError(error.InvalidBar, pci.memoryBar(fake.config(), device, 5));
    try std.testing.expectEqual(@as(usize, 0), fake.writes);
}
test "PCI command writes preserve W1C status and verify the retained command word" {
    var fake: Fake = .{};
    fake.words[0] = 0x061614c3;
    fake.words[1] = 0xf9000001;
    try pci.writeCommand(fake.config(), device, 0x406);
    try std.testing.expectEqual(@as(u32, 0x406), fake.command_write);
    try std.testing.expectEqual(@as(u32, 0xf9000406), fake.words[1]);
}
test "PCI legacy and ECAM selectors reject segment offset overflow and uncovered ranges" {
    const bdf: pci.Bdf = .{ .bus = 4, .device = 2, .function = 3 };
    try std.testing.expectEqual(@as(u32, 0x800413fc), try pci.legacyAddress(bdf, 252));
    try std.testing.expectError(error.InvalidConfigOffset, pci.legacyAddress(bdf, 256));
    try std.testing.expectError(error.UnsupportedSegment, pci.legacyAddress(.{ .segment = 1, .bus = 0, .device = 0, .function = 0 }, 0));
    try std.testing.expectEqual(@as(u64, 0xe0013ffc), try pci.ecamAddress(0xe0000000, 1 << 20, 0, 4, 4, bdf, 4092));
    try std.testing.expectError(error.UnmappedEcam, pci.ecamAddress(0xe0000000, 0x13fff, 0, 4, 4, bdf, 4092));
    try std.testing.expectError(error.InvalidBusRange, pci.ecamAddress(0xe0000000, 1 << 20, 0, 5, 5, bdf, 0));
    try std.testing.expectError(error.AddressOverflow, pci.ecamAddress(0xffffffffffF00000, 2 << 20, 0, 3, 4, bdf, 4092));
}
const Scan = struct {
    writes: usize = 0,
    fn read(_: *anyopaque, bdf: pci.Bdf, offset: u16) !u32 {
        if (bdf.bus == 4 and bdf.device == 2 and bdf.function < 2) return switch (offset) {
            0 => if (bdf.function == 0) 0x061614c3 else 0x27238086,
            8 => 0x02800001,
            12 => 0x00800000,
            else => 0,
        };
        return 0xffffffff;
    }
    fn write(context: *anyopaque, _: pci.Bdf, _: u16, _: u32) !void {
        const self: *Scan = @ptrCast(@alignCast(context));
        self.writes += 1;
    }
};
test "PCI wireless discovery traverses buses and multifunction entries without configuration writes" {
    var scan: Scan = .{};
    const result = try pci.wirelessInventory(.{ .context = &scan, .read32 = Scan.read, .write32 = Scan.write }, 0, 0, 5);
    try std.testing.expectEqual(@as(usize, 2), result.count);
    try std.testing.expectEqual(@as(u8, 4), result.items[0].bdf.bus);
    try std.testing.expectEqual(@as(u16, 0x2723), result.items[1].product);
    try std.testing.expectEqual(@as(usize, 0), scan.writes);
}

const BulkScan = struct {
    writes: usize = 0,
    fn read(_: *anyopaque, bdf: pci.Bdf, offset: u16) !u32 {
        if (bdf.bus != 0 or bdf.device >= 17 or bdf.function != 0) return 0xffffffff;
        return switch (offset) {
            0 => (@as(u32, 0x1000) + @as(u32, bdf.device)) << 16 | 0x8086,
            8 => 0x02800001,
            12 => 0,
            else => 0,
        };
    }
    fn write(context: *anyopaque, _: pci.Bdf, _: u16, _: u32) !void {
        const self: *BulkScan = @ptrCast(@alignCast(context));
        self.writes += 1;
    }
};
test "PCI inventory retains the first sixteen wireless devices and counts overflow without writes" {
    var scan: BulkScan = .{};
    const result = try pci.wirelessInventory(.{ .context = &scan, .read32 = BulkScan.read, .write32 = BulkScan.write }, 0, 0, 0);
    try std.testing.expectEqual(@as(usize, 16), result.count);
    try std.testing.expectEqual(@as(usize, 1), result.dropped);
    try std.testing.expectEqual(@as(usize, 32), result.functions_checked);
    for (result.items[0..result.count], 0..) |item, i| {
        try std.testing.expectEqual(@as(u5, @intCast(i)), item.bdf.device);
        try std.testing.expectEqual(@as(u16, @intCast(0x1000 + i)), item.product);
    }
    try std.testing.expectEqual(@as(usize, 0), scan.writes);
}
test "PCI command updates reject removed and substituted devices before any write" {
    var fake: Fake = .{};
    fake.words[0] = 0xffffffff;
    try std.testing.expectError(error.DeviceChanged, pci.writeCommand(fake.config(), device, 6));
    fake.words[0] = 0x27238086;
    try std.testing.expectError(error.DeviceChanged, pci.writeCommand(fake.config(), device, 6));
    try std.testing.expectEqual(@as(usize, 0), fake.writes);
    fake.words[0] = 0x061614c3;
    try pci.writeCommand(fake.config(), device, 6);
    try std.testing.expectEqual(@as(usize, 1), fake.writes);
}
