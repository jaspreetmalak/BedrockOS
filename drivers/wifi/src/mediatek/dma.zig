// SPDX-License-Identifier: ISC
// Copyright (C) 2016 Felix Fietkau <nbd@nbd.name>
// Copyright (C) 2020, 2023 MediaTek Inc.
// Copyright (C) 2026 Bedrock contributors
// Derived from Linux v6.18 mt76/dma.{c,h}; see PROVENANCE.json and LICENSE.
//! Caller-owned coherent 32-bit DMA. This module never allocates/frees leases.
const std = @import("std");
const w = @import("wire.zig");
const Registers = @import("registers.zig").Registers;
pub const done: u32 = 1 << 31;
pub const last: u32 = 1 << 30;
pub const max_buffer: u32 = 0x3fff;
pub const Descriptor = extern struct {
    buf0: u32 = 0,
    ctrl: u32 = done,
    buf1: u32 = 0,
    info: u32 = 0,
    pub fn encode(self: Descriptor) [16]u8 {
        var b: [16]u8 = undefined;
        w.put32(&b, self.buf0);
        w.put32(b[4..], self.ctrl);
        w.put32(b[8..], self.buf1);
        w.put32(b[12..], self.info);
        return b;
    }
    pub fn decode(b: []const u8) !Descriptor {
        if (b.len != 16) return error.InvalidDescriptor;
        return .{ .buf0 = w.le32(b), .ctrl = w.le32(b[4..]), .buf1 = w.le32(b[8..]), .info = w.le32(b[12..]) };
    }
    pub fn transmit(address: u64, len: usize) !Descriptor {
        try range32(address, len);
        if (len > max_buffer) return error.InvalidDmaLength;
        return .{ .buf0 = @intCast(address), .ctrl = @as(u32, @intCast(len)) << 16 | last };
    }
    pub fn receive(address: u64, len: usize) !Descriptor {
        var d = try transmit(address, len);
        d.ctrl &= ~last;
        return d;
    }
};
comptime {
    if (@sizeOf(Descriptor) != 16 or @alignOf(Descriptor) != 4 or @offsetOf(Descriptor, "ctrl") != 4) @compileError("MT76 descriptor ABI");
}
pub const Buffer = struct { address: u64, bytes: []volatile u8 };
pub const Direction = enum { tx, rx };
pub const Hooks = struct {
    context: *anyopaque,
    /// Optional owner/generation check. Callback context must outlive copied
    /// rings; reject retired storage before any descriptor/buffer access.
    /// Without this callback the caller must keep every borrowed lease alive.
    validateLease: ?*const fn (*anyopaque) anyerror!void = null,
    /// Cache maintenance and DMA write/read barriers, including descriptor RAM.
    toDevice: *const fn (*anyopaque, Buffer, usize) anyerror!void,
    fromDevice: *const fn (*anyopaque, Buffer, usize) anyerror!void,
    delayUs: *const fn (*anyopaque, u32) anyerror!void,
};
fn checkLease(hooks: Hooks) !void {
    if (hooks.validateLease) |validate| try validate(hooks.context);
}
pub fn range32(address: u64, len: usize) !void {
    if (address == 0 or len == 0 or address >= 0x1_0000_0000 or len > 0x1_0000_0000 - address) return error.InvalidDmaAddress;
}
fn overlap(a: Buffer, b: Buffer) bool {
    return a.address < b.address + b.bytes.len and b.address < a.address + a.bytes.len;
}
pub const Config = struct {
    register_base: u32,
    descriptors: Buffer,
    buffers: []const Buffer,
    direction: Direction,
    pub fn validate(self: Config) !void {
        const n = self.buffers.len;
        if (n < 4 or n > 64 or !std.math.isPowerOfTwo(n) or self.register_base & 15 != 0) return error.InvalidRing;
        try range32(self.descriptors.address, self.descriptors.bytes.len);
        if (self.descriptors.address & 15 != 0 or self.descriptors.bytes.len < n * 16) return error.InvalidRing;
        for (self.buffers, 0..) |b, i| {
            try range32(b.address, b.bytes.len);
            if (b.bytes.len > max_buffer or overlap(self.descriptors, b)) return error.InvalidDmaBuffers;
            for (self.buffers[0..i]) |other| if (overlap(b, other)) return error.InvalidDmaBuffers;
        }
    }
};
pub const Ring = struct {
    registers: *Registers,
    config: Config,
    hooks: Hooks,
    head: usize,
    tail: usize = 0,
    stopped: bool = false,
    busy: bool = false,
    /// DMA must be disabled before initialization. Caller retains every lease.
    pub fn init(registers: *Registers, config: Config, hooks: Hooks) !Ring {
        try checkLease(hooks);
        try config.validate();
        var ring: Ring = .{ .registers = registers, .config = config, .hooks = hooks, .head = if (config.direction == .rx) config.buffers.len - 1 else 0 };
        for (0..config.buffers.len) |i| try ring.store(i, if (config.direction == .rx and i < config.buffers.len - 1) try Descriptor.receive(config.buffers[i].address, config.buffers[i].bytes.len) else .{});
        try hooks.toDevice(hooks.context, config.descriptors, config.buffers.len * 16);
        try registers.write(config.register_base, @intCast(config.descriptors.address));
        try registers.write(config.register_base + 4, @intCast(config.buffers.len));
        try registers.write(config.register_base + 8, if (config.direction == .rx) @intCast(config.buffers.len - 2) else 0);
        try registers.write(config.register_base + 12, 0);
        return ring;
    }
    fn store(self: *Ring, index: usize, d: Descriptor) !void {
        try checkLease(self.hooks);
        if (self.config.direction == .rx and d.ctrl & done == 0) try self.hooks.toDevice(self.hooks.context, self.config.buffers[index], self.config.buffers[index].bytes.len);
        try checkLease(self.hooks);
        const b = d.encode();
        const off = index * 16;
        for (b, 0..) |v, i| self.config.descriptors.bytes[off + i] = v;
        try self.hooks.toDevice(self.hooks.context, self.config.descriptors, off + 16);
    }
    fn load(self: *Ring, index: usize) !Descriptor {
        try checkLease(self.hooks);
        try self.hooks.fromDevice(self.hooks.context, self.config.descriptors, index * 16 + 16);
        try checkLease(self.hooks);
        var b: [16]u8 = undefined;
        for (&b, 0..) |*v, i| v.* = self.config.descriptors.bytes[index * 16 + i];
        return Descriptor.decode(&b);
    }
    pub fn send(self: *Ring, packet: []const u8, polls: u32) !void {
        try checkLease(self.hooks);
        if (self.config.direction != .tx) return error.WrongRingDirection;
        if (self.stopped) return error.DmaStopped;
        if (self.busy) return error.DmaBusy;
        if (polls == 0 or polls > 3_000_000 or packet.len == 0 or packet.len > self.config.buffers[self.head].bytes.len) return error.InvalidDmaLength;
        self.busy = true;
        defer self.busy = false;
        errdefer self.stopped = true;
        const i = self.head;
        const b = self.config.buffers[i];
        for (packet, 0..) |v, j| b.bytes[j] = v;
        try self.hooks.toDevice(self.hooks.context, b, packet.len);
        try self.store(i, try Descriptor.transmit(b.address, packet.len));
        const next = (i + 1) % self.config.buffers.len;
        try self.registers.write(self.config.register_base + 8, @intCast(next));
        for (0..polls) |_| {
            const hardware = try self.registers.read(self.config.register_base + 12);
            if (hardware >= self.config.buffers.len) return error.InvalidDmaCompletion;
            const d = try self.load(i);
            if (hardware == next and d.ctrl & done != 0) {
                if (d.buf0 != b.address or d.buf1 != 0 or (d.ctrl >> 16) & 0x3fff != packet.len or d.ctrl & last == 0) return error.InvalidDmaCompletion;
                self.head = next;
                return;
            }
            try self.hooks.delayUs(self.hooks.context, 1);
        }
        return error.DmaTimeout;
    }
    pub fn receive(self: *Ring, output: []u8) !?usize {
        try checkLease(self.hooks);
        if (self.config.direction != .rx) return error.WrongRingDirection;
        if (self.stopped) return error.DmaStopped;
        if (self.busy) return error.DmaBusy;
        self.busy = true;
        defer self.busy = false;
        const d = self.load(self.tail) catch |e| {
            self.stopped = true;
            return e;
        };
        if (d.ctrl & done == 0) return null;
        const b = self.config.buffers[self.tail];
        const len = (d.ctrl >> 16) & 0x3fff;
        if (d.buf0 != b.address or d.buf1 != 0 or len == 0 or len > b.bytes.len or d.ctrl & last == 0 or d.ctrl & 0xffff != 0) {
            self.stopped = true;
            return error.InvalidDmaCompletion;
        }
        if (output.len < len) return error.OutputTooSmall;
        errdefer self.stopped = true;
        try self.hooks.fromDevice(self.hooks.context, b, len);
        try checkLease(self.hooks);
        for (output[0..len], 0..) |*v, i| v.* = b.bytes[i];
        const next_buffer = self.config.buffers[self.head];
        try self.store(self.head, try Descriptor.receive(next_buffer.address, next_buffer.bytes.len));
        try self.registers.write(self.config.register_base + 8, @intCast(self.head));
        self.head = (self.head + 1) % self.config.buffers.len;
        self.tail = (self.tail + 1) % self.config.buffers.len;
        return len;
    }
};
