//! Retained raw MT7922 data-path ownership. The caller owns calibrated channel,
//! MAC/NIC/security readiness. DMA/TX_FREE events never manufacture RF readiness.
const std = @import("std");
const mt = @import("mediatek/root.zig");
const w = @import("mediatek/wire.zig");
pub const tx_ring_base: u32 = 0xd4300; // MT7921_TXQ_BAND0=0 at MT_TX_RING_BASE
pub const rx_ring_base: u32 = 0xd4520; // MT7921_RXQ_BAND0=0 at MT_RX_DATA_RING_BASE
pub const event_ring_base: u32 = 0xd4540; // normal MCU queue after firmware download
pub const max_pending = 4;
pub const max_frame = 4095;
pub const descriptor_bytes = 64;
pub const TxOptions = struct {
    wlan_index: u16,
    own_mac: u8 = 0,
    queue: u8 = 0x10,
    fixed_rate: u16,
    no_ack: bool = false,
    preserve_sequence: bool = true,
    software_encrypted: bool = false,
    request_status: bool = false,
    polls: u32 = 100_000,
};
pub const Event = union(enum) {
    frame: mt.mac.Raw,
    event: []const u8,
    tx_free: mt.mac.Freed,
    tx_status: Statuses,
    other: []const u8,
};
const Pending = struct { token: u16 = 0, consumed: bool = false };
const StatusPending = struct { token: u16 = 0, wlan_index: u16 = 0, sequence: ?u16 = null, active: bool = false };
pub const Status = struct { token: u16, pid: u8, wlan_index: u16, acknowledged: bool, error_bits: u32 };
pub const Statuses = struct { count: usize = 0, entries: [32]Status = undefined };
fn overlaps(a: usize, an: usize, b: usize, bn: usize) bool {
    if (an == 0 or bn == 0) return false;
    return if (a >= b) a - b < bn else b - a < an;
}
fn dmaOverlaps(a: mt.dma.Buffer, b: mt.dma.Buffer) bool {
    return overlaps(@intCast(a.address), a.bytes.len, @intCast(b.address), b.bytes.len) or overlaps(@intFromPtr(a.bytes.ptr), a.bytes.len, @intFromPtr(b.bytes.ptr), b.bytes.len);
}
pub const Path = struct {
    owner_address: usize = 0,
    tx: *mt.dma.Ring = undefined,
    rx: *mt.dma.Ring = undefined,
    events: *mt.dma.Ring = undefined,
    pending: [max_pending]Pending = @splat(.{}),
    issued: u16 = 0,
    issued_pid: u16 = 2,
    statuses: [256]StatusPending = undefined,
    busy: bool = false,
    stopped: bool = false,
    antenna_mask: u8 = 1,
    /// All rings must be freshly posted with hardware DMA still disabled. The
    /// control objects and immutable Buffer metadata must live outside DMA RAM.
    pub fn init(self: *Path, tx: *mt.dma.Ring, rx: *mt.dma.Ring, events: *mt.dma.Ring, antenna_mask: u8) !void {
        if (self.owner_address != 0) return error.DataAlreadyInitialized;
        if (antenna_mask == 0 or antenna_mask & 0xf0 != 0) return error.InvalidAntennaMask;
        const rings = [_]*mt.dma.Ring{ tx, rx, events };
        for (rings, [_]u32{ tx_ring_base, rx_ring_base, event_ring_base }, 0..) |ring, base, index| {
            const validate = ring.hooks.validateLease orelse return error.UnguardedDataRing;
            try validate(ring.hooks.context);
            try ring.config.validate();
            if (ring.config.register_base != base or ring.config.buffers.len != max_pending or ring.stopped or ring.config.direction != (if (index == 0) mt.dma.Direction.tx else mt.dma.Direction.rx)) return error.InvalidDataRing;
            if (ring.registers != tx.registers or ring.hooks.validateLease == null) return error.UnguardedDataRing;
            if (ring.busy or ring.head != (if (index == 0) @as(usize, 0) else max_pending - 1) or ring.tail != 0 or ring.hooks.context != tx.hooks.context or ring.hooks.validateLease != tx.hooks.validateLease) return error.InvalidDataRing;
            if (index == 0) for (ring.config.buffers) |buffer| if (buffer.bytes.len < descriptor_bytes + max_frame) return error.DataBufferTooSmall;
            for (ring.config.buffers, 0..) |buffer, buffer_index| {
                if (dmaOverlaps(buffer, ring.config.descriptors)) return error.AliasedDataRing;
                for (ring.config.buffers[0..buffer_index]) |previous| if (dmaOverlaps(buffer, previous)) return error.AliasedDataRing;
            }
            for (rings[0..index]) |previous| {
                if (dmaOverlaps(ring.config.descriptors, previous.config.descriptors)) return error.AliasedDataRing;
                for (ring.config.buffers) |buffer| {
                    if (dmaOverlaps(buffer, previous.config.descriptors)) return error.AliasedDataRing;
                    for (previous.config.buffers) |other| if (dmaOverlaps(buffer, other)) return error.AliasedDataRing;
                }
                for (previous.config.buffers) |buffer| if (dmaOverlaps(buffer, ring.config.descriptors)) return error.AliasedDataRing;
            }
        }
        // Buffer descriptors are CPU-owned metadata; a device write must never
        // corrupt the in-place owner, ring controls or their borrowed pointers.
        for (rings) |ring| {
            if (overlaps(@intFromPtr(self), @sizeOf(Path), @intFromPtr(ring), @sizeOf(mt.dma.Ring)) or
                overlaps(@intFromPtr(self), @sizeOf(Path), @intFromPtr(ring.registers), @sizeOf(mt.Registers)) or
                overlaps(@intFromPtr(self), @sizeOf(Path), @intFromPtr(ring.config.buffers.ptr), ring.config.buffers.len * @sizeOf(mt.dma.Buffer))) return error.AliasedDataControl;
            for (rings) |storage| {
                try validateControl(@intFromPtr(self), @sizeOf(Path), storage);
                try validateControl(@intFromPtr(ring), @sizeOf(mt.dma.Ring), storage);
                try validateControl(@intFromPtr(ring.registers), @sizeOf(mt.Registers), storage);
                try validateControl(@intFromPtr(ring.config.buffers.ptr), ring.config.buffers.len * @sizeOf(mt.dma.Buffer), storage);
            }
        }
        self.owner_address = @intFromPtr(self);
        self.tx = tx;
        self.rx = rx;
        self.events = events;
        self.antenna_mask = antenna_mask;
        self.issued = 0;
        self.issued_pid = 2;
        self.stopped = false;
        self.busy = false;
        for (&self.pending) |*pending| pending.* = .{};
        for (&self.statuses) |*pending| pending.* = .{};
    }
    fn validateControl(pointer: usize, length: usize, ring: *const mt.dma.Ring) !void {
        const descriptor = ring.config.descriptors.bytes;
        if (overlaps(pointer, length, @intFromPtr(descriptor.ptr), descriptor.len)) return error.AliasedDataControl;
        for (ring.config.buffers) |buffer| if (overlaps(pointer, length, @intFromPtr(buffer.bytes.ptr), buffer.bytes.len)) return error.AliasedDataControl;
    }
    fn owner(self: *const Path) !void {
        if (self.owner_address == 0 or self.owner_address != @intFromPtr(self)) return error.MovedDataPath;
    }
    fn begin(self: *Path) !void {
        try self.owner();
        if (self.stopped) return error.DataStopped;
        if (self.busy) return error.DataBusy;
        try self.tx.hooks.validateLease.?(self.tx.hooks.context);
        self.busy = true;
    }
    fn guard(self: *Path) !void {
        try self.tx.hooks.validateLease.?(self.tx.hooks.context);
        if (self.stopped) return error.DataStopped;
    }
    fn aliases(self: *const Path, bytes: []const u8) bool {
        const pointer = @intFromPtr(bytes.ptr);
        if (overlaps(@intFromPtr(self), @sizeOf(Path), pointer, bytes.len)) return true;
        for ([_]*mt.dma.Ring{ self.tx, self.rx, self.events }) |ring| {
            if (overlaps(@intFromPtr(ring), @sizeOf(mt.dma.Ring), pointer, bytes.len) or
                overlaps(@intFromPtr(ring.registers), @sizeOf(mt.Registers), pointer, bytes.len) or
                overlaps(@intFromPtr(ring.config.buffers.ptr), ring.config.buffers.len * @sizeOf(mt.dma.Buffer), pointer, bytes.len) or
                overlaps(@intFromPtr(ring.config.descriptors.bytes.ptr), ring.config.descriptors.bytes.len, pointer, bytes.len)) return true;
            for (ring.config.buffers) |buffer| if (overlaps(@intFromPtr(buffer.bytes.ptr), buffer.bytes.len, pointer, bytes.len)) return true;
        }
        return false;
    }
    /// Wire tokens never repeat in this path lifetime. Payload AND TXWI stay
    /// reserved after WFDMA consumption until the exact TX_FREE token arrives.
    pub fn sendManagement(self: *Path, frame: []const u8, options: TxOptions) !u16 {
        return self.send(frame, options, 0);
    }
    pub fn sendData(self: *Path, frame: []const u8, options: TxOptions) !u16 {
        return self.send(frame, options, 2);
    }
    fn send(self: *Path, frame: []const u8, options: TxOptions, frame_type: u16) !u16 {
        try self.begin();
        defer self.busy = false;
        if (self.aliases(frame)) return error.AliasedDataInput;
        if (frame.len < 24 or frame.len > max_frame or (w.le16(frame) >> 2) & 3 != frame_type or options.polls == 0 or options.polls > 3_000_000) return error.InvalidDataFrame;
        if (self.issued == 0x7fff) return error.TxTokenExhausted;
        const index = self.tx.head;
        if (index >= max_pending) return error.InvalidDataRing;
        if (self.pending[index].token != 0) return error.WouldBlock;
        const buffer = self.tx.config.buffers[index];
        const token = self.issued + 1;
        const request_status = options.request_status or (frame_type == 0 and !options.no_ack and frame[4] & 1 == 0);
        if (request_status and self.issued_pid == 255) return error.TxStatusIdExhausted;
        const pid: u8 = if (request_status) @intCast(self.issued_pid + 1) else 0;
        var header: [descriptor_bytes]u8 = undefined;
        _ = try mt.mac.transmit(frame, buffer.address + descriptor_bytes, .{ .token = token, .wlan_index = options.wlan_index, .own_mac = options.own_mac, .queue = options.queue, .fixed_rate = options.fixed_rate, .no_ack = options.no_ack, .preserve_sequence = options.preserve_sequence, .software_encrypted = options.software_encrypted, .status_pid = pid }, &header);
        // All input failures precede token issuance or mutation. From this point
        // any ambiguous hardware/cache failure pins storage until real reset.
        self.issued = token;
        self.pending[index] = .{ .token = token };
        if (request_status) {
            self.issued_pid = pid;
            self.statuses[pid] = .{ .token = token, .wlan_index = options.wlan_index, .sequence = if (options.preserve_sequence) w.le16(frame[22..]) >> 4 else null, .active = true };
        }
        errdefer self.stopped = true;
        try self.guard();
        for (header, 0..) |byte, i| buffer.bytes[i] = byte;
        for (frame, 0..) |byte, i| buffer.bytes[descriptor_bytes + i] = byte;
        try self.tx.hooks.toDevice(self.tx.hooks.context, buffer, descriptor_bytes + frame.len);
        try self.guard();
        const descriptor = (try mt.dma.Descriptor.transmit(buffer.address, descriptor_bytes)).encode();
        const offset = index * 16;
        for (descriptor, 0..) |byte, i| self.tx.config.descriptors.bytes[offset + i] = byte;
        try self.tx.hooks.toDevice(self.tx.hooks.context, self.tx.config.descriptors, offset + 16);
        try self.guard();
        const next = (index + 1) % max_pending;
        try self.tx.registers.write(tx_ring_base + 8, @intCast(next));
        for (0..options.polls) |_| {
            const hardware = try self.tx.registers.read(tx_ring_base + 12);
            if (hardware >= max_pending) return error.InvalidDmaCompletion;
            try self.tx.hooks.fromDevice(self.tx.hooks.context, self.tx.config.descriptors, offset + 16);
            try self.guard();
            var bytes: [16]u8 = undefined;
            for (&bytes, 0..) |*byte, i| byte.* = self.tx.config.descriptors.bytes[offset + i];
            const done = try mt.dma.Descriptor.decode(&bytes);
            if (hardware == next and done.ctrl & mt.dma.done != 0) {
                if (done.buf0 != buffer.address or done.buf1 != 0 or (done.ctrl >> 16) & 0x3fff != descriptor_bytes or done.ctrl & mt.dma.last == 0) return error.InvalidDmaCompletion;
                self.pending[index].consumed = true;
                self.tx.head = next;
                return token;
            }
            try self.tx.hooks.delayUs(self.tx.hooks.context, 1);
        }
        return error.DmaTimeout;
    }
    /// Returned frame/event slices borrow the caller's output buffer. No DMA
    /// memory escapes, and too-small output preserves the pending RX descriptor.
    pub fn pollData(self: *Path, output: []u8) !?Event {
        try self.owner();
        return self.poll(self.rx, output);
    }
    pub fn pollEvent(self: *Path, output: []u8) !?Event {
        try self.owner();
        return self.poll(self.events, output);
    }
    fn poll(self: *Path, ring: *mt.dma.Ring, output: []u8) !?Event {
        try self.begin();
        defer self.busy = false;
        if (self.aliases(output)) return error.AliasedDataOutput;
        const length = ring.receive(output) catch |err| {
            if (ring.stopped) self.stopped = true;
            return err;
        } orelse return null;
        return try self.routeInner(output[0..length]);
    }
    /// Route an already-received NIC event exactly once. The packet borrows
    /// external caller storage; this method does not dequeue another RX packet.
    pub fn route(self: *Path, bytes: []const u8) !Event {
        try self.begin();
        defer self.busy = false;
        if (self.aliases(bytes)) return error.AliasedDataInput;
        return self.routeInner(bytes);
    }
    fn routeInner(self: *Path, bytes: []const u8) !Event {
        const packet = try mt.mac.packet(bytes);
        return switch (packet.kind) {
            // Corrupt/unsupported peer MPDUs are ordinary drops. Keep the strict
            // decoder separate; never turn rejected bytes into an admitted frame.
            .normal => if (mt.mac.raw(packet.bytes, self.antenna_mask)) |frame| .{ .frame = frame } else |_| .{ .other = packet.bytes },
            .event => .{ .event = packet.bytes },
            .tx_free => .{ .tx_free = try self.complete(packet.bytes) },
            .tx_status => .{ .tx_status = try self.status(packet.bytes) },
            .other => .{ .other = packet.bytes },
        };
    }
    fn status(self: *Path, bytes: []const u8) !Statuses {
        const received = try mt.mac.transmitStatus(bytes);
        var result: Statuses = .{ .count = received.count };
        for (received.entries[0..received.count], 0..) |entry, index| {
            const pending = self.statuses[entry.pid];
            if (!pending.active or pending.token == 0 or pending.wlan_index != entry.wlan_index or (pending.sequence != null and pending.sequence.? != entry.sequence)) return error.StaleTxStatus;
            result.entries[index] = .{ .token = pending.token, .pid = entry.pid, .wlan_index = entry.wlan_index, .acknowledged = entry.acknowledged, .error_bits = entry.error_bits };
        }
        try self.guard();
        for (received.entries[0..received.count]) |entry| self.statuses[entry.pid].active = false;
        return result;
    }
    fn complete(self: *Path, bytes: []const u8) !mt.mac.Freed {
        const freed = try mt.mac.transmitFree(bytes);
        var indices: [32]usize = undefined;
        // Atomic batch preflight: unknown/retired/duplicate tokens cannot release
        // any other live payload, even when the event also contains valid IDs.
        for (freed.entries[0..freed.count], 0..) |entry, i| {
            var found: ?usize = null;
            for (self.pending, 0..) |pending, index| if (pending.token == entry.token and pending.token != 0) {
                if (!pending.consumed) return error.UnconsumedTxFree;
                found = index;
            };
            indices[i] = found orelse return error.StaleTxFree;
        }
        try self.guard();
        for (indices[0..freed.count]) |index| self.pending[index] = .{};
        return freed;
    }
    pub fn outstanding(self: *const Path) !usize {
        try self.owner();
        var count: usize = 0;
        for (self.pending) |pending| count += @intFromBool(pending.token != 0);
        return count;
    }
    pub fn retire(self: *Path) !void {
        try self.owner();
        if (self.busy) return error.DataBusy;
        self.stopped = true;
    }
    /// Trusted caller must already prove hardware DMA/reset quiescence. This
    /// clears ownership records only; it never frees memory or restarts tokens.
    pub fn reclaimAfterQuiescence(self: *Path) !void {
        try self.owner();
        if (self.busy) return error.DataBusy;
        if (!self.stopped) return error.DataStillActive;
        self.pending = @splat(.{});
        for (&self.statuses) |*pending| pending.* = .{};
    }
};
test {
    _ = @import("mt7922_data_tests.zig");
}
