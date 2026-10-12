// SPDX-License-Identifier: ISC
// Copyright (C) 2020 MediaTek Inc.
// Copyright (C) 2026 Bedrock contributors
// Derived from Linux v6.18 mt76_connac_mcu.{c,h}, mt7921/{mcu,main}.c.
const w = @import("wire.zig");
const mac = @import("mac.zig");
const Mcu = @import("mcu.zig").Mcu;
pub const request_size = 1186;
pub const done_size = 348;
pub const start_command: u8 = 3;
pub const cancel_command: u8 = 0x1b;
pub const Channel = struct { band: mac.Band, number: u8 };
pub const Options = struct {
    sequence: u8,
    bss_index: u8 = 0,
    active: bool = false,
    channels: []const Channel,
    ssids: []const []const u8 = &.{},
    ies: []const u8 = &.{},
    bssid: [6]u8 = @splat(0xff),
};
/// Regulatory/channel authority is caller-supplied; no implicit full-band scan.
pub fn encode(options: Options, output: []u8) ![]const u8 {
    if (output.len < request_size) return error.OutputTooSmall;
    if (options.sequence == 0 or options.sequence > 127 or options.bss_index >= 4 or options.channels.len == 0 or options.channels.len > 64 or options.ssids.len > 4 or options.ies.len > 600) return error.InvalidScanRequest;
    if (!options.active and options.ssids.len != 0) return error.InvalidScanRequest;
    for (options.ssids) |ssid| if (ssid.len == 0 or ssid.len > 32) return error.InvalidScanRequest;
    for (options.channels, 0..) |channel, i| {
        switch (channel.band) {
            .ghz2 => if (channel.number == 0 or channel.number > 14) return error.InvalidScanChannel,
            .ghz5 => if (channel.number < 15 or channel.number > 177) return error.InvalidScanChannel,
            .ghz6 => if (channel.number == 0 or channel.number > 233 or channel.number % 4 != 1) return error.InvalidScanChannel,
        }
        for (options.channels[0..i]) |previous| if (previous.band == channel.band and previous.number == channel.number) return error.DuplicateScanChannel;
    }
    var ie: usize = 0;
    while (ie < options.ies.len) {
        if (options.ies.len - ie < 2 or options.ies[ie + 1] > options.ies.len - ie - 2) return error.InvalidScanInformationElements;
        ie += 2 + options.ies[ie + 1];
    }
    const b = output[0..request_size];
    @memset(b, 0);
    b[0] = options.sequence;
    b[1] = options.bss_index;
    b[2] = @intFromBool(options.active);
    b[3] = if (options.ssids.len == 0) 1 else 4;
    b[4] = @intCast(options.ssids.len);
    b[5] = if (options.active) 2 else 0;
    b[6] = 1 << 5;
    b[7] = 1;
    for (options.ssids, 0..) |ssid, i| {
        const offset = 8 + i * 36;
        w.put32(b[offset..], @intCast(ssid.len));
        @memcpy(b[offset + 4 ..][0..ssid.len], ssid);
    }
    // MT7922 belongs to Linux is_mt7921(): dwell/min/timeout remain firmware0.
    b[158] = 4;
    b[159] = @intCast(@min(options.channels.len, 32));
    for (options.channels, 0..) |channel, i| {
        const offset = if (i < 32) 160 + i * 2 else 830 + (i - 32) * 2;
        b[offset] = @backingInt(channel.band);
        b[offset + 1] = channel.number;
    }
    w.put16(b[224..], @intCast(options.ies.len));
    @memcpy(b[226..][0..options.ies.len], options.ies);
    b[826] = @intCast(options.channels.len - @min(options.channels.len, 32));
    @memcpy(b[1110..1116], &options.bssid);
    b[1185] = @intFromBool(options.ssids.len != 0);
    return b;
}
pub const Done = struct { sequence: u8, completed_channels: u8, state: u8, version: u8, beacons: u32, beacons_2g: u32, beacons_5g: u32 };
pub fn completion(packet: []const u8, expected_sequence: u8) !Done {
    if (expected_sequence == 0 or expected_sequence > 127) return error.InvalidScanCompletion;
    const p = try mac.packet(packet);
    if (p.kind != .event or p.bytes.len < 36 + done_size) return error.InvalidScanCompletion;
    const b = p.bytes;
    const declared = w.le16(b[24..]);
    if (b[28] != 0x0d or b[30] & 4 != 0 or declared < 12 + done_size or declared > b.len - 24) return error.InvalidScanCompletion;
    const body = b[36..][0..done_size];
    if (body[0] != expected_sequence) return error.StaleScanCompletion;
    if (body[4] > 64 or body[16] > 64 or body[1] > 64) return error.InvalidScanCompletion;
    return .{ .sequence = body[0], .completed_channels = body[4], .state = body[5], .version = body[6], .beacons = w.le32(body[8..]), .beacons_2g = w.le32(body[340..]), .beacons_5g = w.le32(body[344..]) };
}
pub const Sequence = struct {
    issued: u8 = 0,
    pub fn next(self: *Sequence) !u8 {
        if (self.issued == 127) return error.ScanSequenceExhausted;
        self.issued += 1;
        return self.issued;
    }
};
pub const Session = struct {
    sequence: Sequence = .{},
    active: ?u8 = null,
    request: [request_size]u8 = undefined,
    /// The caller must first establish NIC/EEPROM, MAC/interface and regulatory
    /// initialization. This primitive does not itself publish radio readiness.
    pub fn start(self: *Session, mcu: *Mcu, options: Options) !u8 {
        if (self.active != null) return error.ScanBusy;
        var request = options;
        request.sequence = try self.sequence.next();
        const payload = try encode(request, &self.request);
        try mcu.sendCe(start_command, payload);
        self.active = request.sequence;
        return request.sequence;
    }
    pub fn completed(self: *Session, raw: []const u8) !Done {
        const seq = self.active orelse return error.NoActiveScan;
        const event = try completion(raw, seq);
        self.active = null;
        return event;
    }
    /// DMA consumption acknowledges submission, not firmware/RF cancellation.
    /// Stop accepting old results; a backend needs separate cancellation proof.
    pub fn cancelRequest(self: *Session, mcu: *Mcu) !void {
        const seq = self.active orelse return;
        try mcu.sendCe(cancel_command, &.{ seq, 0, 0, 0 });
        self.active = null;
    }
};
