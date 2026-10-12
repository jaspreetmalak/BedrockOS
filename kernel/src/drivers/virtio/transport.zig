//! VirtIO 1.x MMIO and modern PCI, polling-only. PCI configuration ports are
//! confined to the named q35 profile; device register ranges require explicit
//! supervisor identity coverage before the first MMIO access.
const std = @import("std");
const builtin = @import("builtin");
const protocol = @import("boot_protocol");
const io = @import("io.zig");
pub const poll_limit: usize = 20_000_000;
pub const version_1: u64 = @as(u64, 1) << 32;
pub const net_id: u32 = 1;
pub const block_id: u32 = 2;
pub const input_id: u32 = 18;
pub const max_devices = 8;

pub const Transport = struct {
    kind: enum { mmio, pci },
    device_id: u32,
    common: u64,
    notify_base: u64 = 0,
    notify_length: u64 = 0,
    notify_multiplier: u32 = 0,
    isr: u64 = 0,
    config: u64,
    config_length: u64,

    pub fn status(self: Transport) u8 {
        return if (self.kind == .mmio) @truncate(io.read(u32, self.common + 0x70)) else io.read(u8, self.common + 20);
    }

    pub fn setStatus(self: Transport, value: u8) void {
        if (self.kind == .mmio) io.write(u32, self.common + 0x70, value) else io.write(u8, self.common + 20, value);
        io.fence();
    }

    /// Successful reset is the DMA-quiescence boundary before releasing RAM.
    pub fn reset(self: Transport) !void {
        self.setStatus(0);
        for (0..poll_limit) |_| {
            if (self.status() == 0) {
                io.fence();
                return;
            }
            io.relax();
        }
        return error.DeviceResetTimeout;
    }

    pub fn begin(self: Transport, wanted: u64) !u64 {
        try self.reset();
        self.setStatus(1);
        self.setStatus(3);
        const offered = self.features();
        if (offered & version_1 == 0) return error.LegacyVirtioUnsupported;
        const accepted = version_1 | (offered & wanted);
        if (self.kind == .mmio) {
            io.write(u32, self.common + 0x24, 0);
            io.write(u32, self.common + 0x20, @truncate(accepted));
            io.write(u32, self.common + 0x24, 1);
            io.write(u32, self.common + 0x20, @truncate(accepted >> 32));
        } else {
            io.write(u32, self.common + 8, 0);
            io.write(u32, self.common + 12, @truncate(accepted));
            io.write(u32, self.common + 8, 1);
            io.write(u32, self.common + 12, @truncate(accepted >> 32));
            // No MSI-X delivery; queues suppress interrupts and are polled.
            io.write(u16, self.common + 16, 0xffff);
        }
        io.fence();
        self.setStatus(11);
        if (self.status() & 8 == 0) return error.FeatureNegotiationRejected;
        return offered;
    }

    pub fn ready(self: Transport) !void {
        self.setStatus(15);
        if (self.status() & (64 | 128) != 0) return error.DeviceNeedsReset;
    }

    fn features(self: Transport) u64 {
        const select: u64 = self.common + (if (self.kind == .mmio) @as(u64, 0x14) else 0);
        const value: u64 = self.common + (if (self.kind == .mmio) @as(u64, 0x10) else 4);
        io.write(u32, select, 0);
        const low = io.read(u32, value);
        io.write(u32, select, 1);
        return @as(u64, low) | (@as(u64, io.read(u32, value)) << 32);
    }

    pub fn queueMaximum(self: Transport, index: u16) !u16 {
        if (self.kind == .mmio) {
            io.write(u32, self.common + 0x30, index);
            if (io.read(u32, self.common + 0x44) != 0) return error.QueueAlreadyReady;
            const maximum = io.read(u32, self.common + 0x34);
            if (maximum == 0) return error.QueueUnavailable;
            return @intCast(@min(maximum, 32768));
        }
        if (index >= io.read(u16, self.common + 18)) return error.QueueUnavailable;
        io.write(u16, self.common + 22, index);
        if (io.read(u16, self.common + 28) != 0) return error.QueueAlreadyReady;
        const maximum = io.read(u16, self.common + 24);
        if (maximum == 0) return error.QueueUnavailable;
        return maximum;
    }

    pub fn configureQueue(self: Transport, index: u16, size: u16, descriptor: u64, driver: u64, device: u64) !u64 {
        if (self.kind == .mmio) {
            io.write(u32, self.common + 0x30, index);
            io.write(u32, self.common + 0x38, size);
            writePair(self.common + 0x80, descriptor);
            writePair(self.common + 0x90, driver);
            writePair(self.common + 0xa0, device);
            io.fence();
            io.write(u32, self.common + 0x44, 1);
            return self.common + 0x50;
        }
        io.write(u16, self.common + 22, index);
        io.write(u16, self.common + 24, size);
        io.write(u16, self.common + 26, 0xffff);
        writePair(self.common + 32, descriptor);
        writePair(self.common + 40, driver);
        writePair(self.common + 48, device);
        const offset = try std.math.mul(u64, io.read(u16, self.common + 30), self.notify_multiplier);
        if (offset > self.notify_length or self.notify_length - offset < 2) return error.InvalidNotificationCapability;
        io.fence();
        io.write(u16, self.common + 28, 1);
        return try std.math.add(u64, self.notify_base, offset);
    }

    pub fn notify(self: Transport, address: u64, queue_index: u16) void {
        io.fence();
        if (self.kind == .mmio) io.write(u32, address, queue_index) else io.write(u16, address, queue_index);
    }

    pub fn acknowledge(self: Transport) void {
        if (self.kind == .mmio) {
            const pending = io.read(u32, self.common + 0x60);
            if (pending != 0) io.write(u32, self.common + 0x64, pending & 3);
        } else {
            _ = io.read(u8, self.isr);
        }
    }

    pub fn generation(self: Transport) u8 {
        return if (self.kind == .mmio) @truncate(io.read(u32, self.common + 0xfc)) else io.read(u8, self.common + 21);
    }

    pub fn configRead(self: Transport, comptime T: type, offset: u64) !T {
        if (offset > self.config_length or self.config_length - offset < @sizeOf(T)) return error.ConfigOutsideCapability;
        const address = try std.math.add(u64, self.config, offset);
        if (address % @alignOf(T) != 0) return error.UnalignedDeviceRegister;
        return io.read(T, address);
    }

    pub fn configSelect(self: Transport, select: u8, subselect: u8) !void {
        if (self.config_length < 136) return error.ConfigOutsideCapability;
        io.write(u8, self.config, select);
        io.write(u8, self.config + 1, subselect);
        io.fence();
    }
};

fn writePair(address: u64, value: u64) void {
    io.write(u32, address, @truncate(value));
    io.write(u32, address + 4, @truncate(value >> 32));
}

pub const Devices = struct {
    items: [max_devices]Transport = undefined,
    count: usize = 0,
    fn add(self: *Devices, transport: Transport) !void {
        if (self.count == self.items.len) return error.TooManyVirtioDevices;
        self.items[self.count] = transport;
        self.count += 1;
    }
};

/// This is explicit named-platform discovery, not unrestricted physical MMIO
/// scanning. The integration must map the profile's transport windows first.
pub fn discover(info: *const protocol.BootInfo) !Devices {
    var devices: Devices = .{};
    switch (builtin.cpu.arch) {
        .aarch64 => try mmioDiscover(info, &devices, 0x0a000000, 0x200, 32),
        .riscv64 => try mmioDiscover(info, &devices, 0x10001000, 0x1000, 8),
        .x86_64 => try pciDiscover(info, &devices),
        else => return error.UnsupportedVirtioPlatform,
    }
    return devices;
}

fn mmioDiscover(info: *const protocol.BootInfo, devices: *Devices, base: u64, stride: u64, count: usize) !void {
    for (0..count) |slot| {
        const address = base + slot * stride;
        if (!info.isMapped(.{ .base = address, .length = 0x200 })) return error.UnmappedVirtioRegisters;
        if (io.read(u32, address) != 0x74726976) return error.InvalidVirtioMagic;
        const id = io.read(u32, address + 8);
        if (id == 0) continue;
        if (!supportedDevice(id)) continue;
        if (io.read(u32, address + 4) != 2) return error.LegacyVirtioUnsupported;
        try devices.add(.{ .kind = .mmio, .device_id = id, .common = address, .config = address + 0x100, .config_length = 0x100 });
    }
}

fn pciRead(address: u32, offset: u8) u32 {
    io.out32(0xcf8, 0x80000000 | address | (offset & 0xfc));
    return io.in32(0xcfc);
}
fn pciByte(address: u32, offset: u8) u8 {
    return @truncate(pciRead(address, offset) >> @as(u5, @intCast((offset & 3) * 8)));
}
fn pciWrite(address: u32, offset: u8, value: u32) void {
    io.out32(0xcf8, 0x80000000 | address | (offset & 0xfc));
    io.out32(0xcfc, value);
}

const Capability = struct { base: u64 = 0, length: u64 = 0, multiplier: u32 = 0 };

fn memoryBarBase(bar: u8, low: u32, high: u32) !u64 {
    if (bar > 5 or low & 1 != 0) return error.InvalidPciBar;
    const base: u64 = switch ((low >> 1) & 3) {
        0 => low & 0xfffffff0,
        2 => if (bar == 5) return error.InvalidPciBar else @as(u64, low & 0xfffffff0) | (@as(u64, high) << 32),
        else => return error.InvalidPciBar,
    };
    // A 64-bit BAR can have no address bits in its low dword: validate the
    // complete address only after incorporating its high dword.
    if (base == 0) return error.InvalidPciBar;
    return base;
}

fn capability(info: *const protocol.BootInfo, function: u32, offset: u8, length: u8) !Capability {
    const bar = pciByte(function, offset + 4);
    if (bar > 5 or length < 16) return error.InvalidPciCapability;
    const low = pciRead(function, 0x10 + bar * 4);
    const high = if ((low >> 1) & 3 == 2 and bar < 5) pciRead(function, 0x14 + bar * 4) else 0;
    const base = try memoryBarBase(bar, low, high);
    const result = try std.math.add(u64, base, pciRead(function, offset + 8));
    const bytes = pciRead(function, offset + 12);
    if (bytes == 0 or !info.isMapped(.{ .base = result, .length = bytes })) return error.UnmappedVirtioRegisters;
    return .{ .base = result, .length = bytes, .multiplier = if (length >= 20) pciRead(function, offset + 16) else 0 };
}

test "PCI memory BAR combines high address before checking assignment" {
    try std.testing.expectEqual(@as(u64, 0x1_0000_0000), try memoryBarBase(4, 0x0c, 1));
    try std.testing.expectEqual(@as(u64, 0x12_3456_7000), try memoryBarBase(0, 0x3456_7004, 0x12));
    try std.testing.expectEqual(@as(u64, 0xc000_0000), try memoryBarBase(5, 0xc000_0008, 0));
    try std.testing.expectError(error.InvalidPciBar, memoryBarBase(4, 4, 0));
    try std.testing.expectError(error.InvalidPciBar, memoryBarBase(0, 0, 0));
    try std.testing.expectError(error.InvalidPciBar, memoryBarBase(5, 4, 1));
    try std.testing.expectError(error.InvalidPciBar, memoryBarBase(0, 0x3f9, 0));
    try std.testing.expectError(error.InvalidPciBar, memoryBarBase(0, 0xc000_0002, 0));
    try std.testing.expectError(error.InvalidPciBar, memoryBarBase(0, 0xc000_0006, 0));
}

fn pciTransport(info: *const protocol.BootInfo, function: u32, id: u32) !Transport {
    if (pciRead(function, 4) & (1 << 20) == 0) return error.MissingPciCapabilities;
    var pointer = pciByte(function, 0x34);
    var visited: u64 = 0;
    var common: Capability = .{};
    var notify: Capability = .{};
    var isr: Capability = .{};
    var config: Capability = .{};
    for (0..48) |_| {
        if (pointer == 0) break;
        if (pointer < 0x40 or pointer % 4 != 0) return error.InvalidPciCapability;
        const bit = @as(u64, 1) << @as(u6, @intCast(pointer / 4));
        if (visited & bit != 0) return error.PciCapabilityCycle;
        visited |= bit;
        const next = pciByte(function, pointer + 1);
        if (pciByte(function, pointer) == 9) {
            const length = pciByte(function, pointer + 2);
            if (@as(u16, pointer) + length > 256 or length < 16) return error.InvalidPciCapability;
            const kind = pciByte(function, pointer + 3);
            if (kind >= 1 and kind <= 4) {
                const cap = try capability(info, function, pointer, length);
                switch (kind) {
                    1 => if (common.base == 0) {
                        common = cap;
                    },
                    2 => if (notify.base == 0) {
                        if (length < 20) return error.InvalidPciCapability;
                        notify = cap;
                    },
                    3 => if (isr.base == 0) {
                        isr = cap;
                    },
                    4 => if (config.base == 0) {
                        config = cap;
                    },
                    else => unreachable,
                }
            }
        }
        pointer = next;
    } else return error.PciCapabilityLimit;
    const minimum_config: u64 = if (id == net_id) 6 else 8;
    if (common.length < 56 or common.base % 4 != 0 or notify.length < 2 or notify.base % 2 != 0 or isr.length < 1 or config.length < minimum_config)
        return error.MissingPciCapabilities;
    // Retain only the command word; writing zero to status avoids W1C effects.
    const command = pciRead(function, 4) & 0xffff;
    pciWrite(function, 4, (command | 6 | (1 << 10)) & ~@as(u32, 1));
    return .{ .kind = .pci, .device_id = id, .common = common.base, .notify_base = notify.base, .notify_length = notify.length, .notify_multiplier = notify.multiplier, .isr = isr.base, .config = config.base, .config_length = config.length };
}

fn pciDiscover(info: *const protocol.BootInfo, devices: *Devices) !void {
    // Bus zero only: explicitly attach the reference devices to q35's root
    // bus. Bridges/hotplug/ECAM and arbitrary motherboard enumeration follow.
    for (0..32) |slot| {
        const first: u32 = @intCast(slot << 11);
        if (pciRead(first, 0) & 0xffff == 0xffff) continue;
        const functions: usize = if (pciByte(first, 0x0e) & 0x80 != 0) 8 else 1;
        for (0..functions) |number| {
            const function = first | @as(u32, @intCast(number << 8));
            const vendor_device = pciRead(function, 0);
            if (vendor_device & 0xffff != 0x1af4) continue;
            const product = vendor_device >> 16;
            const id: u32 = if (product >= 0x1040 and product <= 0x107f) product - 0x1040 else if (product == 0x1001) block_id else continue;
            if (supportedDevice(id)) try devices.add(try pciTransport(info, function, id));
        }
    }
}

fn supportedDevice(id: u32) bool {
    return id == net_id or id == block_id or id == input_id;
}

test "named VirtIO discovery supports modern network block and input IDs" {
    try std.testing.expect(supportedDevice(1));
    try std.testing.expect(supportedDevice(2));
    try std.testing.expect(supportedDevice(18));
    try std.testing.expect(!supportedDevice(0));
    try std.testing.expect(!supportedDevice(3));
    try std.testing.expect(!supportedDevice(19));
}
