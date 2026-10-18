// SPDX-License-Identifier: ISC
// Copyright (C) 2020, 2023 MediaTek Inc.
// Copyright (C) 2026 Bedrock contributors
// Derived from Linux v6.18 mt7921/pci.c, pci_mcu.c and mt792x_{core,dma}.c.
// See PROVENANCE.json and LICENSE; no Linux kernel API bindings are used.
const r = @import("regs.zig");
const Registers = @import("registers.zig").Registers;
const dma = @import("dma.zig");
const Mcu = @import("mcu.zig").Mcu;
const firmware = @import("firmware.zig");
pub const Clock = struct { context: *anyopaque, delayUs: *const fn (*anyopaque, u32) anyerror!void };
pub const State = enum { cold, owned, reset, dma_ready, firmware_ready, stopped, failed };
pub const Identity = struct { chip: u16, revision: u8 };
pub const Snapshot = struct { state: State, identity: ?Identity, mac_initialized: bool = false };
pub const Driver = struct {
    registers: Registers,
    clock: Clock,
    state: State = .cold,
    identity: ?Identity = null,
    mac_initialized: bool = false,
    pub fn init(registers: Registers, clock: Clock) Driver {
        return .{ .registers = registers, .clock = clock };
    }
    pub fn snapshot(self: *const Driver) Snapshot {
        return .{ .state = self.state, .identity = self.identity, .mac_initialized = self.mac_initialized };
    }
    fn poll(self: *Driver, address: u32, mask: u32, want: u32, ms: u32) !void {
        for (0..ms) |_| {
            const value = try self.registers.read(address);
            if (value == 0xffffffff) return error.DeviceRemoved;
            if (value & mask == want) return;
            try self.clock.delayUs(self.clock.context, 1000);
        }
        return error.DeviceTimeout;
    }
    pub fn identify(self: *Driver) !Identity {
        const chip = try self.registers.read(r.chip_id);
        const revision = try self.registers.read(r.chip_revision);
        if (chip == 0xffffffff or revision == 0xffffffff) return error.DeviceRemoved;
        if (chip & 0xffff != 0x7922) return error.WrongChip;
        return .{ .chip = @truncate(chip), .revision = @truncate(revision) };
    }
    /// PCI memory decode, BAR mapping and bus permissions are caller-owned.
    pub fn driverOwn(self: *Driver) !void {
        if (self.state != .cold) return error.InvalidDriverState;
        errdefer self.state = .failed;
        try self.registers.write(r.conn_lpc, 1);
        try self.poll(r.conn_lpc, r.conn_own_sync, r.conn_own_sync, 500);
        try self.registers.write(r.conn_lpc, 2);
        try self.poll(r.conn_lpc, r.conn_own_sync, 0, 500);
        self.identity = try self.identify();
        self.state = .owned;
    }
    pub fn disableDma(self: *Driver) !void {
        try self.registers.write(r.interrupt_enable, 0);
        _ = try self.registers.update(r.global_config, r.dma_disable_mask, 0);
        try self.poll(r.global_config, r.tx_busy | r.rx_busy, 0, 100);
        _ = try self.registers.update(r.global_config_ext, 1 << 6, 0);
        _ = try self.registers.update(r.scheduler_control, r.scheduler_bypass, r.scheduler_bypass);
        _ = try self.registers.update(r.wfdma_reset, r.reset_mask, 0);
        _ = try self.registers.update(r.wfdma_reset, r.reset_mask, r.reset_mask);
    }
    pub fn reset(self: *Driver) !void {
        if (self.state != .owned) return error.InvalidDriverState;
        errdefer self.state = .failed;
        self.mac_initialized = false;
        try self.disableDma();
        _ = try self.registers.update(r.wfsys_reset, r.reset_bit, 0);
        try self.clock.delayUs(self.clock.context, 50000);
        _ = try self.registers.update(r.wfsys_reset, r.reset_bit, r.reset_bit);
        try self.poll(r.wfsys_reset, r.reset_done, r.reset_done, 500);
        try self.registers.write(r.interrupt_enable, 0);
        // Polling bring-up does not enable PCI/MSI/legacy IRQ delivery.
        try self.registers.write(r.pcie_interrupt_enable, 0);
        self.state = .reset;
    }
    /// Rings must already be initialized while DMA was disabled. Shared caller
    /// leases remain retained until stop confirms quiescence, even after errors.
    pub fn configureDma(self: *Driver, wm: *dma.Ring, fwdl: *dma.Ring, event: *dma.Ring) !void {
        if (self.state != .reset) return error.InvalidDriverState;
        const required = [_]struct { ring: *dma.Ring, base: u32, kind: dma.Direction }{
            .{ .ring = wm, .base = try r.txRing(17), .kind = .tx }, .{ .ring = fwdl, .base = try r.txRing(16), .kind = .tx }, .{ .ring = event, .base = r.event_ring_base, .kind = .rx },
        };
        for (required) |q| {
            try q.ring.config.validate();
            if (q.ring.registers != &self.registers or q.ring.config.register_base != q.base or q.ring.config.direction != q.kind or q.ring.stopped) return error.InvalidRing;
        }
        // Individually valid rings must not share any DMA storage.
        for (required, 0..) |a, i| for (required[0..i]) |b| {
            if (dmaOverlap(a.ring.config.descriptors, b.ring.config.descriptors)) return error.InvalidDmaBuffers;
            for (a.ring.config.buffers) |ab| {
                if (dmaOverlap(ab, b.ring.config.descriptors)) return error.InvalidDmaBuffers;
                for (b.ring.config.buffers) |bb| if (dmaOverlap(ab, bb)) return error.InvalidDmaBuffers;
            }
            for (b.ring.config.buffers) |bb| if (dmaOverlap(a.ring.config.descriptors, bb)) return error.InvalidDmaBuffers;
        };
        errdefer self.state = .failed;
        const rx_bases = [_]u16{ 0, 0x40, 0x80, 0xc0, 0x100 };
        const rx_indices = [_]u8{ 0, 2, 3, 4, 5 };
        for (rx_bases, rx_indices) |base, index| try self.registers.write(r.rx_ext_base + @as(u32, index) * 4, @as(u32, base) << 16 | 4);
        const tx_indices = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 16, 17 };
        const tx_bases = [_]u16{ 0x140, 0x180, 0x1c0, 0x200, 0x240, 0x280, 0x2c0, 0x340, 0x380 };
        for (tx_bases, tx_indices) |base, index| try self.registers.write(r.tx_ext_base + @as(u32, index) * 4, @as(u32, base) << 16 | 4);
        try self.registers.write(r.tx_reset_pointer, 0xffffffff);
        try self.registers.write(r.delayed_interrupt, 0);
        _ = try self.registers.update(r.global_config, r.dma_configuration, r.dma_configuration);
        _ = try self.registers.update(r.global_config, r.tx_enable | r.rx_enable, r.tx_enable | r.rx_enable);
        _ = try self.registers.update(r.dummy_config, 2, 2);
        self.state = .dma_ready;
    }
    pub fn loadFirmware(self: *Driver, mcu: *Mcu, patch_bytes: []const u8, ram_bytes: []const u8) !void {
        if (self.state != .dma_ready) return error.InvalidDriverState;
        // Validate both complete formats before issuing ANY download command.
        const patch = try firmware.parsePatch(patch_bytes);
        const ram = try firmware.parseRam(ram_bytes);
        errdefer self.state = .failed;
        // Linux initializes SWDEF normal firmware mode before download.
        try self.registers.write(0x41f23c, 0);
        try self.registers.write(r.top_lpc, r.top_driver_own);
        try self.poll(r.top_lpc, r.top_fw_own, 0, 500);
        _ = try self.registers.update(r.pcie_power, 1 << 8, 1 << 8);
        try mcu.loadPatch(patch);
        try mcu.loadRam(ram);
        try self.poll(r.conn_misc, r.firmware_ready_mask, r.firmware_ready_mask, 1500);
        self.state = .firmware_ready;
    }
    /// Explicit raw80211 global MAC register setup, after trusted firmware/
    /// EEPROM prerequisites. Caller still submits actual RTS/RX-path/MAC-enable
    /// commands and supplies verified calibration/regulatory authority.
    pub fn initMac(self: *Driver) !void {
        if (self.state != .firmware_ready or self.mac_initialized) return error.InvalidDriverState;
        errdefer self.state = .failed;
        try @import("nic_registers.zig").initialize(&self.registers, .{ .context = self.clock.context, .delayUs = self.clock.delayUs });
        self.mac_initialized = true;
    }
    /// Success proves DMA disable/reset, permitting the caller to release leases.
    pub fn stop(self: *Driver) !void {
        self.mac_initialized = false;
        errdefer self.state = .failed;
        try self.disableDma();
        self.state = .stopped;
    }
};
fn dmaOverlap(a: dma.Buffer, b: dma.Buffer) bool {
    return a.address < b.address + b.bytes.len and b.address < a.address + a.bytes.len;
}
