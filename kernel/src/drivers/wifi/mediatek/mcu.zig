// SPDX-License-Identifier: ISC
// Copyright (C) 2020, 2022 MediaTek Inc.
// Copyright (C) 2026 Bedrock contributors
// Derived from Linux v6.18 mt76_connac_mcu.{c,h}, mt76_connac2_mac.h,
// mt7921/mcu.c and mt7921/pci_mcu.c. See PROVENANCE.json and LICENSE.
const w = @import("wire.zig");
const firmware = @import("firmware.zig");
const dma = @import("dma.zig");
const mac = @import("mac.zig");
pub const Queue = enum { wm, fwdl };
pub const Command = enum(u8) { target = 1, start = 2, patch_start = 5, patch_finish = 7, patch_semaphore = 0x10 };
pub const tx_header_size = 64;
pub const rx_header_size = 36;
pub const scatter_size = 4096;
pub const Channel = struct {
    context: *anyopaque,
    /// Synchronously wait for actual DMA consumption. Never retain packet bytes.
    submit: *const fn (*anyopaque, Queue, []const u8) anyerror!void,
    /// One complete hardware MCU RXD event; null means no event is available.
    receive: *const fn (*anyopaque, []u8) anyerror!?usize,
    delayUs: *const fn (*anyopaque, u32) anyerror!void,
};
/// Direct binding to the real caller-owned WFDMA rings. No simulated completion
/// or successful fallback is supplied by this adapter.
pub const DmaChannel = struct {
    wm: *dma.Ring,
    fwdl: *dma.Ring,
    event: *dma.Ring,
    pub fn channel(self: *DmaChannel) Channel {
        return .{ .context = self, .submit = submit, .receive = receive, .delayUs = delay };
    }
    fn cast(p: *anyopaque) *DmaChannel {
        return @ptrCast(@alignCast(p));
    }
    fn submit(p: *anyopaque, queue: Queue, packet: []const u8) !void {
        const self = cast(p);
        const ring = if (queue == .wm) self.wm else self.fwdl;
        try ring.send(packet, 3_000_000);
    }
    fn receive(p: *anyopaque, output: []u8) !?usize {
        return cast(p).event.receive(output);
    }
    fn delay(p: *anyopaque, us: u32) !void {
        const hooks = cast(p).event.hooks;
        try hooks.delayUs(hooks.context, us);
    }
};
pub fn encode(command: Command, seq: u8, payload: []const u8, out: []u8) ![]const u8 {
    return encodeRaw(@backingInt(command), seq, false, payload, out);
}
pub fn encodeRaw(command: u8, seq: u8, ce: bool, payload: []const u8, out: []u8) ![]const u8 {
    if (seq == 0 or seq > 15) return error.InvalidMcuSequence;
    if (payload.len > scatter_size or out.len < tx_header_size + payload.len) return error.OutputTooSmall;
    const b = out[0 .. tx_header_size + payload.len];
    @memset(b, 0);
    w.put32(b, @as(u32, @intCast(b.len)) | (2 << 23) | (0x20 << 25));
    w.put32(b[4..], (1 << 31) | (1 << 16));
    w.put16(b[32..], @intCast(b.len - 32));
    w.put16(b[34..], 0x8000);
    b[36] = command;
    b[37] = 0xa0;
    b[38] = if (ce) 1 else 3;
    b[39] = seq;
    @memcpy(b[tx_header_size..], payload);
    return b;
}
pub fn response(packet: []const u8, command: Command, seq: u8) !?u8 {
    if (packet.len < rx_header_size) return error.MalformedMcuResponse;
    const received = mac.packet(packet) catch return error.MalformedMcuResponse;
    if (received.kind != .event) return error.UnexpectedMcuEvent;
    const len = w.le16(packet[24..]);
    if (len < 12 or len > packet.len - 24 or packet.len - 24 - len > 3) return error.MalformedMcuResponse;
    if (packet[29] != seq) return null;
    const expected: u8 = if (command == .patch_semaphore) 4 else 1;
    if (packet[28] != expected) return error.UnexpectedMcuEvent;
    // MT7921 boot ROM returns semaphore/finish status in RXD byte32.
    // Linux's parse_response explicitly pulls sizeof(rxd)-4 for these commands.
    return if (command == .patch_semaphore or command == .patch_finish) packet[32] else 0;
}
pub const Mcu = struct {
    channel: Channel,
    seq: u8 = 0,
    stopped: bool = false,
    busy: bool = false,
    tx: [tx_header_size + scatter_size]u8 = undefined,
    rx: [scatter_size]u8 = undefined,
    /// In-place initialization avoids copying the retained packet workspaces.
    pub fn init(self: *Mcu, channel: Channel) void {
        self.channel = channel;
        self.seq = 0;
        self.stopped = false;
        self.busy = false;
    }
    pub fn request(self: *Mcu, command: Command, payload: []const u8) !u8 {
        if (self.stopped) return error.McuStopped;
        if (self.busy) return error.McuBusy;
        if (payload.len > scatter_size) return error.InvalidMcuPayload;
        self.busy = true;
        defer self.busy = false;
        errdefer self.stopped = true;
        self.seq = if (self.seq == 15) 1 else self.seq + 1;
        const packet = try encode(command, self.seq, payload, &self.tx);
        try self.channel.submit(self.channel.context, .wm, packet);
        for (0..3000) |_| {
            if (try self.channel.receive(self.channel.context, &self.rx)) |size| {
                if (size > self.rx.len) return error.MalformedMcuResponse;
                if (try response(self.rx[0..size], command, self.seq)) |status| return status;
            }
            try self.channel.delayUs(self.channel.context, 1000);
        }
        return error.McuTimeout;
    }
    /// Submit a real legacy CE command. Success means DMA consumption only;
    /// asynchronous scan results/completion must be decoded separately.
    pub fn sendCe(self: *Mcu, command: u8, payload: []const u8) !void {
        if (self.stopped) return error.McuStopped;
        if (self.busy) return error.McuBusy;
        if (payload.len > scatter_size) return error.InvalidMcuPayload;
        self.busy = true;
        defer self.busy = false;
        errdefer self.stopped = true;
        self.seq = if (self.seq == 15) 1 else self.seq + 1;
        const packet = try encodeRaw(command, self.seq, true, payload, &self.tx);
        try self.channel.submit(self.channel.context, .wm, packet);
    }
    fn scatter(self: *Mcu, data: []const u8) !void {
        var offset: usize = 0;
        while (offset < data.len) {
            const len = @min(scatter_size, data.len - offset);
            // FW_SCATTER uses raw bytes on the separate FWDL queue, no MCU TXD.
            try self.channel.submit(self.channel.context, .fwdl, data[offset..][0..len]);
            offset += len;
        }
    }
    fn download(self: *Mcu, r: firmware.Region) !void {
        var payload: [12]u8 = undefined;
        w.put32(&payload, r.address);
        w.put32(payload[4..], @intCast(r.data.len));
        w.put32(payload[8..], r.download_mode);
        const command: Command = if (r.address == 0x200000 or r.address == 0x900000) .patch_start else .target;
        if (try self.request(command, &payload) != 0) return error.FirmwareRejected;
        try self.scatter(r.data);
    }
    pub fn loadPatch(self: *Mcu, patch: firmware.Patch) !void {
        if (self.stopped) return error.McuStopped;
        errdefer self.stopped = true;
        var op: [4]u8 = undefined;
        w.put32(&op, 1);
        const status = try self.request(.patch_semaphore, &op);
        if (status == 1) return; // device boot ROM reports patch already downloaded
        if (status != 2) return error.PatchSemaphoreUnavailable;
        // On failure do not submit another packet on a possibly timed-out DMA
        // ring. The caller must quiesce/reset hardware, retaining all leases.
        for (0..patch.region_count) |i| try self.download(try patch.region(i));
        if (try self.request(.patch_finish, &.{ 0, 0, 0, 0 }) != 0) return error.FirmwareRejected;
        w.put32(&op, 0);
        if (try self.request(.patch_semaphore, &op) != 3) return error.PatchSemaphoreReleaseFailed;
    }
    pub fn loadRam(self: *Mcu, ram: firmware.Ram) !void {
        if (self.stopped) return error.McuStopped;
        errdefer self.stopped = true;
        var override: u32 = 0;
        for (0..ram.region_count) |i| {
            const r = try ram.region(i);
            if (!r.download) continue;
            if (r.feature & 0x20 != 0) override = r.address;
            try self.download(r);
        }
        var payload: [8]u8 = undefined;
        w.put32(&payload, if (override != 0) 1 else 0);
        w.put32(payload[4..], override);
        if (try self.request(.start, &payload) != 0) return error.FirmwareRejected;
    }
};
