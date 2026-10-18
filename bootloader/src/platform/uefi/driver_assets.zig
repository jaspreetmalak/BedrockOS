//! Select installed driver images by read-only firmware PCI inventory, then
//! load/relocate them before the final EFI memory map. No driver code runs here.
const std = @import("std");
const uefi = std.os.uefi;
const protocol = @import("boot_protocol");
const kit = @import("driver_kit");
const cc = uefi.cc;
const PciIo = extern struct {
    pub const guid: uefi.Guid = .{ .time_low = 0x4cf5b200, .time_mid = 0x68b8, .time_high_and_version = 0x4ca5, .clock_seq_high_and_reserved = 0x9e, .clock_seq_low = 0xec, .node = .{ 0xb2, 0x3e, 0x3f, 0x50, 0x02, 0x9a } };
    poll_mem: usize,
    poll_io: usize,
    mem: [2]usize,
    io: [2]usize,
    pci: extern struct {
        read: *const fn (*PciIo, u32, u32, usize, *anyopaque) callconv(cc) uefi.Status,
        write: usize,
    },
};
pub const Device = struct { vendor: u16, product: u16, subsystem_vendor: u16, subsystem_product: u16 };
pub const Inventory = struct { devices: [64]Device = undefined, count: usize = 0, dropped: bool = false };
fn wirelessDevice(words: *const [12]u32) ?Device {
    if (@as(u16, @truncate(words[0])) == 0xffff or
        @as(u8, @truncate(words[2] >> 24)) != 2 or
        @as(u8, @truncate(words[2] >> 16)) != 0x80 or
        @as(u8, @truncate(words[3] >> 16)) & 0x7f != 0) return null;
    return .{ .vendor = @truncate(words[0]), .product = @truncate(words[0] >> 16), .subsystem_vendor = @truncate(words[11]), .subsystem_product = @truncate(words[11] >> 16) };
}
pub fn inventory(bs: *uefi.tables.BootServices, image: uefi.Handle) !Inventory {
    const handles = (try bs.locateHandleBuffer(.{ .by_protocol = &PciIo.guid })) orelse return .{};
    defer bs.freePool(@ptrCast(handles.ptr)) catch {};
    if (handles.len > 4096) return error.PciInventoryTooLarge;
    var result: Inventory = .{};
    for (handles) |handle| {
        const pci = (try bs.openProtocol(PciIo, handle, .{ .by_handle_protocol = .{ .agent = image } })) orelse continue;
        var words: [12]u32 = undefined;
        if (pci.pci.read(pci, 2, 0, words.len, &words) != .success) return error.PciInventoryReadFailed;
        const device = wirelessDevice(&words) orelse continue;
        if (result.count == result.devices.len) {
            result.dropped = true;
            continue;
        }
        result.devices[result.count] = device;
        result.count += 1;
    }
    return result;
}
pub fn matching(layout: *const kit.elf.Image, devices: *const Inventory) !bool {
    if (devices.dropped) return error.PciInventoryIncomplete;
    if (devices.count > devices.devices.len) return error.PciInventoryTooLarge;
    for (devices.devices[0..devices.count]) |device|
        if (layout.matchesDevice(device.vendor, device.product, device.subsystem_vendor, device.subsystem_product)) return true;
    return false;
}
pub const Retained = struct {
    pages: []align(4096) uefi.Page,
    record: protocol.DriverRecord,
    pub fn release(self: *Retained, bs: *uefi.tables.BootServices) !void {
        try bs.freePages(self.pages);
    }
};
fn name(comptime text: []const u8) [text.len:0]u16 {
    var result: [text.len:0]u16 = undefined;
    for (text, 0..) |b, i| result[i] = b;
    result[text.len] = 0;
    return result;
}
/// force_fixture is only passed by a dedicated acceptance image. Production
/// never loads a fixture or bypasses an installed module's hardware match.
pub fn stage(bs: *uefi.tables.BootServices, image: uefi.Handle, arch: std.Target.Cpu.Arch, address_limit: u64, force_fixture: bool) !?Retained {
    const loaded = (try bs.openProtocol(uefi.protocol.LoadedImage, image, .{ .by_handle_protocol = .{ .agent = image } })) orelse return error.LoadedImageUnavailable;
    const fs = (try bs.openProtocol(uefi.protocol.SimpleFileSystem, loaded.device_handle orelse return error.LoadedImageDeviceUnavailable, .{ .by_handle_protocol = .{ .agent = image } })) orelse return error.LoadedImageFilesystemUnavailable;
    const root = try fs.openVolume();
    defer root.close() catch {};
    const production = comptime name("\\EFI\\Bedrock\\Drivers\\mt7922.bdm");
    const fixture = comptime name("\\EFI\\Bedrock\\Drivers\\test-driver.bdm");
    const file = root.open(if (force_fixture) &fixture else &production, .read, .{}) catch |err| switch (err) {
        error.NotFound => return null,
        else => return err,
    };
    defer file.close() catch {};
    var information: [512]u8 align(8) = undefined;
    var size: usize = information.len;
    if (file._get_info(file, &uefi.protocol.File.Info.File.guid, &size, &information) != .success or size < @sizeOf(uefi.protocol.File.Info.File) or size > information.len) return error.InvalidDriverFileInfo;
    const info: *const uefi.protocol.File.Info.File = @ptrCast(&information);
    if (info.size < @sizeOf(uefi.protocol.File.Info.File) or info.size > size or info.attribute.directory or info.file_size == 0 or info.file_size > kit.elf.max_file_size) return error.InvalidDriverFileInfo;
    const buffer = try bs.allocatePool(.loader_data, @intCast(info.file_size));
    defer bs.freePool(buffer.ptr) catch {};
    var used: usize = 0;
    var reads: usize = 0;
    while (used < buffer.len) {
        reads += 1;
        if (reads > 4096) return error.DriverReadBudget;
        const n = try file.read(buffer[used..]);
        if (n == 0 or n > buffer.len - used) return error.TruncatedDriver;
        used += n;
    }
    var trailing: [1]u8 = undefined;
    if (try file.read(&trailing) != 0) return error.TrailingDriverBytes;
    const layout = try kit.elf.inspect(buffer, arch);
    const expected_id = if (force_fixture) "org.bedrock.test-driver" else "org.bedrock.mt7922";
    const id_end = std.mem.indexOfScalar(u8, &layout.descriptor.id, 0) orelse return error.InvalidModuleIdentity;
    if (!std.mem.eql(u8, layout.descriptor.id[0..id_end], expected_id)) return error.InvalidModuleIdentity;
    if (!force_fixture and !try matching(&layout, &(try inventory(bs, image)))) return null;
    const length = (layout.span + 4095) & ~@as(u64, 4095);
    const capacity = length + layout.alignment - 4096;
    const pages = try bs.allocatePages(.any, .loader_data, @intCast(capacity / 4096));
    errdefer bs.freePages(pages) catch {};
    const low = @intFromPtr(pages.ptr);
    if (low == 0 or capacity > address_limit -| low) return error.DriverOutsideAddressableRange;
    const base = (low + layout.alignment - 1) & ~(layout.alignment - 1);
    const destination: [*]u8 = @ptrFromInt(base);
    @memset(@as([*]u8, @ptrCast(pages.ptr))[0..@intCast(capacity)], 0);
    const entry = try kit.elf.load(buffer, arch, destination[0..@intCast(length)]);
    var result: Retained = .{ .pages = pages, .record = .{ .reservation = .{ .base = low, .length = capacity }, .image = .{ .base = base, .length = length }, .entry = entry, .segment_count = @intCast(layout.segment_count), .class = layout.descriptor.class } };
    for (layout.segments[0..layout.segment_count], 0..) |segment, i|
        result.record.segments[i] = .{ .range = .{ .base = base + segment.address, .length = (segment.memory_size + 4095) & ~@as(u64, 4095) }, .flags = segment.flags };
    std.crypto.hash.sha2.Sha256.hash(destination[0..@intCast(length)], &result.record.image_sha256, .{});
    try result.record.validate();
    return result;
}
comptime {
    if (@offsetOf(PciIo, "pci") != 48) @compileError("EFI PCI I/O prefix ABI changed");
}
test "PCI inventory filters non-wireless functions and preserves subsystem identity" {
    var words: [12]u32 = @splat(0);
    words[0] = 0x061614c3;
    words[2] = 0x02800001;
    words[11] = 0x12341043;
    const device = wirelessDevice(&words).?;
    try std.testing.expectEqual(@as(u16, 0x14c3), device.vendor);
    try std.testing.expectEqual(@as(u16, 0x0616), device.product);
    try std.testing.expectEqual(@as(u16, 0x1043), device.subsystem_vendor);
    try std.testing.expectEqual(@as(u16, 0x1234), device.subsystem_product);
    words[2] = 0x02000001;
    try std.testing.expect(wirelessDevice(&words) == null);
    words[2] = 0x02800001;
    words[3] = 0x00010000;
    try std.testing.expect(wirelessDevice(&words) == null);
    words[3] = 0;
    words[0] = 0xffffffff;
    try std.testing.expect(wirelessDevice(&words) == null);
}
test "runtime hardware selection uses exact device aliases and refuses incomplete inventory" {
    var layout: kit.elf.Image = undefined;
    layout.match_count = 1;
    layout.matches[0] = .{ .vendor = 0x14c3, .product = 0x0616, .architecture = 62, .capabilities = 3, .id = @splat(0) };
    @memcpy(layout.matches[0].id[0..18], "org.bedrock.mt7922");
    var devices: Inventory = .{ .count = 1 };
    devices.devices[0] = .{ .vendor = 0x14c3, .product = 0x0616, .subsystem_vendor = 1, .subsystem_product = 2 };
    try std.testing.expect(try matching(&layout, &devices));
    devices.devices[0].product = 0x7921;
    try std.testing.expect(!try matching(&layout, &devices));
    devices.devices[0].product = 0x0616;
    layout.matches[0].subsystem_product = 3;
    try std.testing.expect(!try matching(&layout, &devices));
    devices.dropped = true;
    try std.testing.expectError(error.PciInventoryIncomplete, matching(&layout, &devices));
    devices.dropped = false;
    devices.count = 65;
    try std.testing.expectError(error.PciInventoryTooLarge, matching(&layout, &devices));
}
