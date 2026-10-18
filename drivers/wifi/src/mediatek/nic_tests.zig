// SPDX-License-Identifier: ISC
// Copyright (C) 2026 Bedrock contributors
const std = @import("std");
const t = std.testing;
const n = @import("nic.zig");
const m = @import("mcu.zig");
const w = @import("wire.zig");
const address = [_]u8{ 2, 3, 4, 5, 6, 7 };
const device = n.Device{ .omac_index = 2, .address = address, .enabled = true };
const bss = n.Bss{ .bss_index = 1, .omac_index = 2, .wmm_index = 0, .wlan_index = 7, .band = .ghz2, .bssid = address, .connected = true, .beacon_interval = 100, .dtim_period = 2, .basic_rates = 15 };
const station = n.Station{ .bss_index = 1, .omac_index = 2, .wlan_index = 7, .peer = address, .aid = 123, .band = .ghz2, .supported_rates = 0x0fff, .basic_rates = 15, .rcpi = 100, .state = .associated };
fn header(bytes: []u8, eid: u8, sequence: u8) void {
    @memset(bytes, 0);
    w.put32(bytes, (7 << 27) | @as(u32, @intCast(bytes.len)));
    w.put16(bytes[24..], @intCast(bytes.len - 24));
    bytes[28] = eid;
    bytes[29] = sequence;
}
fn capabilities(sequence: u8) [99]u8 {
    var bytes: [99]u8 = undefined;
    header(&bytes, 6, sequence);
    const b = bytes[36..];
    w.put16(b, 4);
    w.put32(b[4..], 7);
    w.put32(b[8..], 6);
    @memcpy(b[12..18], &address);
    w.put32(b[18..], 8);
    w.put32(b[22..], 12);
    @memcpy(b[26..38], &[_]u8{ 1, 1, 1, 3, 2, 0, 1, 1, 1, 1, 3, 1 });
    w.put32(b[38..], 0x18);
    w.put32(b[42..], 1);
    b[46] = 1;
    w.put32(b[47..], 0x20);
    w.put32(b[51..], 8);
    w.put32(b[55..], 1);
    w.put32(b[59..], 2);
    return bytes;
}
fn ack(sequence: u8, command: u8, status: u32) [44]u8 {
    var bytes: [44]u8 = undefined;
    header(&bytes, 1, sequence);
    bytes[30] = 2;
    bytes[36] = command;
    w.put32(bytes[40..], status);
    return bytes;
}
fn canary(bytes: []const u8) !void {
    for (bytes) |b| try t.expectEqual(@as(u8, 0xaa), b);
}
test "NIC capability literal TLVs produce MAC PHY band and chip facts only" {
    const bytes = capabilities(3);
    const facts = try n.decodeCapabilities(&bytes, 3);
    try t.expectEqualSlices(u8, &address, &facts.address);
    try t.expectEqual(@as(u8, 2), facts.phy.nss);
    try t.expectEqual(@as(u8, 3), facts.phy.antenna_mask);
    try t.expect(facts.phy.has_2ghz and facts.phy.has_5ghz and facts.has_6ghz);
    try t.expectEqual(@as(?u64, 0x200000001), facts.chip_capability);
    try t.expectError(error.StaleNicResponse, n.decodeCapabilities(&bytes, 4));
}
test "NIC capability bounds duplicate fields invalid MAC PHY and incomplete sets reject" {
    var bytes = capabilities(3);
    w.put32(bytes[44..], 0xffffffff);
    try t.expectError(error.TruncatedNicCapability, n.decodeCapabilities(&bytes, 3));
    bytes = capabilities(3);
    bytes[48] = 1;
    try t.expectError(error.InvalidNicMac, n.decodeCapabilities(&bytes, 3));
    bytes = capabilities(3);
    bytes[66] = 0;
    try t.expectError(error.InvalidNicPhy, n.decodeCapabilities(&bytes, 3));
    bytes = capabilities(3);
    w.put32(bytes[74..], 7);
    try t.expectError(error.InvalidNicMac, n.decodeCapabilities(&bytes, 3));
    bytes = capabilities(3);
    w.put16(bytes[36..], 3);
    try t.expectError(error.IncompleteNicCapabilities, n.decodeCapabilities(&bytes, 3));
    bytes = capabilities(3);
    bytes[82] = 2;
    try t.expectError(error.InvalidNicBand, n.decodeCapabilities(&bytes, 3));
    try t.expectError(error.InvalidRxLength, n.decodeCapabilities(bytes[0..98], 3));
}
test "NIC unified and legacy command headers match source48and64byte layouts" {
    var output: [128]u8 = undefined;
    const unified = try n.encodeRequest(.device, 5, &.{ 1, 2 }, &output);
    try t.expectEqual(@as(usize, 50), unified.len);
    try t.expectEqual(@as(u32, 0x41000032), w.le32(unified));
    try t.expectEqualSlices(u8, &.{ 18, 0, 1, 0, 0, 0xa0, 0, 5 }, unified[32..40]);
    try t.expectEqual(@as(u8, 7), unified[43]);
    const cap = try n.encodeRequest(.capabilities, 1, &.{}, &output);
    try t.expectEqual(@as(usize, 64), cap.len);
    try t.expectEqualSlices(u8, &.{ 32, 0, 0, 128, 0x8a, 0xa0, 1, 1 }, cap[32..40]);
    const channel = try n.encodeRequest(.channel, 2, &.{1}, &output);
    try t.expectEqual(@as(u8, 0xed), channel[36]);
    try t.expectEqual(@as(u8, 8), channel[41]);
    try t.expectEqual(@as(u8, 1), channel[43]);
}
test "NIC actual unified result requires matching sequence CID and status and legacy proof has no invented status" {
    var bytes = ack(3, 1, 0);
    const proof = try n.decodeResponse(&bytes, 3, .device);
    try t.expectEqual(@as(?u32, 0), proof.status);
    try t.expectError(error.StaleNicResponse, n.decodeResponse(&bytes, 4, .device));
    try t.expectError(error.UnexpectedNicResponse, n.decodeResponse(&bytes, 3, .bss));
    try t.expectError(error.UnexpectedNicResponse, n.decodeResponse(&bytes, 3, .channel));
    bytes = ack(3, 1, 2);
    try t.expectError(error.FirmwareRejected, n.decodeResponse(&bytes, 3, .device));
    var legacy: [36]u8 = undefined;
    header(&legacy, 1, 3);
    try t.expectEqual(@as(?u32, null), (try n.decodeResponse(&legacy, 3, .channel)).status);
    legacy[28] = 0x0d;
    try t.expectError(error.UnexpectedNicResponse, n.decodeResponse(&legacy, 3, .channel));
}
test "NIC device BSS station and nested WTBL records have exact golden offsets" {
    var output: [256]u8 = undefined;
    const dev = try n.encodeDevice(device, &output);
    try t.expectEqualSlices(u8, &.{ 2, 0, 0, 0, 0, 0, 12, 0, 1, 0, 2, 3, 4, 5, 6, 7 }, dev);
    const network = try n.encodeBss(bss, &output);
    try t.expectEqual(@as(usize, 44), network.len);
    try t.expectEqual(@as(u32, 0x10001), w.le32(network[12..]));
    try t.expectEqual(@as(u16, 100), w.le16(network[26..]));
    try t.expectEqualSlices(u8, &.{ 2, 6, 7, 0, 3, 0, 0, 0 }, network[28..36]);
    const peer = try n.encodeStation(station, &output);
    try t.expectEqual(@as(usize, 120), peer.len);
    try t.expectEqualSlices(u8, &.{ 1, 7, 5, 0, 1, 2, 0, 0 }, peer[0..8]);
    try t.expectEqual(@as(u16, 0x3fcf), w.le16(peer[44..]));
    try t.expectEqualSlices(u8, &.{ 13, 0, 52, 0, 7, 1, 3, 0, 0, 0, 0, 0 }, peer[68..80]);
    try t.expectEqual(@as(u16, 123), w.le16(peer[96..]));
    try t.expectEqualSlices(u8, &.{ 6, 0, 8, 0, 1, 0, 1, 0 }, peer[112..120]);
    var removed = station;
    removed.enabled = false;
    const deletion = try n.encodeStation(removed, &output);
    try t.expectEqual(@as(usize, 40), deletion.len);
    try t.expectEqual(@as(u8, 0), deletion[16]);
    try t.expectEqual(@as(u16, 0), w.le16(deletion[34..]));
}
test "NIC channel20MHz and RLM metadata preserve real antenna count versus mask" {
    var output: [256]u8 = undefined;
    const channel = try n.encodeChannel(.{ .band = .ghz5, .number = 36, .antenna_mask = 3, .passive = true }, &output);
    try t.expectEqualSlices(u8, &.{ 36, 36, 0, 2, 2, 5, 0, 0, 0, 0, 1, 0 }, channel[0..12]);
    const rlm = try n.encodeRlm(1, .{ .band = .ghz5, .number = 36, .antenna_mask = 3, .passive = false }, &output);
    try t.expectEqualSlices(u8, &.{ 1, 0, 0, 0, 2, 0, 16, 0, 36, 36, 0, 0, 2, 3, 1, 0, 0, 1, 0, 0 }, rlm);
}
test "NIC CCMP record source full allocation zeroes padding and does not invent PN" {
    const key: [16]u8 = @splat(0x42);
    var output: [256]u8 = undefined;
    const encoded = try n.encodeCcmp(.{ .bss_index = 1, .omac_index = 2, .wlan_index = 7, .key_id = 2, .install = true, .bytes = &key }, &output);
    try t.expectEqual(@as(usize, 88), encoded.len);
    try t.expectEqualSlices(u8, &.{ 17, 0, 44, 0, 0, 1, 0, 0, 5, 36, 2, 16 }, encoded[8..20]);
    try t.expectEqualSlices(u8, &key, encoded[20..36]);
    for (encoded[36..]) |b| try t.expectEqual(@as(u8, 0), b);
    const removed = try n.encodeCcmp(.{ .bss_index = 1, .omac_index = 2, .wlan_index = 7, .key_id = 2, .install = false, .bytes = &.{} }, &output);
    try t.expectEqualSlices(u8, &.{ 17, 0, 8, 0, 1, 0, 0, 0 }, removed[8..16]);
    for (removed[16..]) |b| try t.expectEqual(@as(u8, 0), b);
}
test "NIC invalid record requests fail atomically before modifying wire buffers" {
    var output: [256]u8 = @splat(0xaa);
    var dev = device;
    dev.address[0] = 1;
    try t.expectError(error.InvalidDeviceRecord, n.encodeDevice(dev, &output));
    var network = bss;
    network.band = .ghz6;
    try t.expectError(error.InvalidBssRecord, n.encodeBss(network, &output));
    var peer = station;
    peer.secured = true;
    try t.expectError(error.InvalidStationRecord, n.encodeStation(peer, &output));
    peer = station;
    peer.basic_rates = 0x8000;
    try t.expectError(error.InvalidLegacyRates, n.encodeStation(peer, &output));
    try t.expectError(error.InvalidNicChannel, n.encodeChannel(.{ .band = .ghz5, .number = 38, .antenna_mask = 3, .passive = true }, &output));
    try t.expectError(error.InvalidCcmpKey, n.encodeCcmp(.{ .bss_index = 1, .omac_index = 2, .wlan_index = 7, .key_id = 4, .install = true, .bytes = &.{} }, &output));
    try t.expectError(error.OutputTooSmall, n.encodeStation(station, output[0..119]));
    try canary(&output);
}
const Replay = struct {
    count: usize = 0,
    sequence: u8 = 0,
    command: u8 = 0,
    legacy: bool = false,
    cap: bool = false,
    power: bool = false,
    bad_power: bool = false,
    efuse: bool = false,
    efuse_address: u32 = 0,
    waiting: bool = false,
    no_response: bool = false,
    fail_submit: bool = false,
    wrong_cid: bool = false,
    negative_status: bool = false,
    stale_once: bool = false,
    stale_sent: bool = false,
    non_event_once: bool = false,
    non_event_sent: bool = false,
    delays: usize = 0,
    fn cast(context: *anyopaque) *Replay {
        return @ptrCast(@alignCast(context));
    }
    fn submit(context: *anyopaque, queue: m.Queue, bytes: []const u8) !void {
        const self = cast(context);
        try t.expectEqual(m.Queue.wm, queue);
        if (self.fail_submit) return error.InjectedIO;
        self.count += 1;
        self.sequence = bytes[39];
        self.cap = bytes[36] == 0x8a;
        self.power = bytes[36] == 0xd0;
        self.legacy = bytes[36] == 0xed;
        self.command = if (self.power) 0xd0 else if (self.cap) 0x8a else if (self.legacy) bytes[41] else @intCast(w.le16(bytes[34..]));
        if (self.power) try t.expectEqualSlices(u8, &@as([8]u8, @splat(0)), bytes[64..]);
        if (self.legacy and self.command == 0x21) try t.expectEqualSlices(u8, &.{ 0, 1, 0, 0 }, bytes[64..]);
        self.efuse = self.legacy and self.command == 1 and bytes[38] == 0;
        if (self.efuse) self.efuse_address = w.le32(bytes[64..]);
        self.waiting = true;
    }
    fn receive(context: *anyopaque, output: []u8) !?usize {
        const self = cast(context);
        if (!self.waiting or self.no_response) return null;
        if (self.non_event_once and !self.non_event_sent) {
            var bytes: [12]u8 = @splat(0);
            w.put32(&bytes, (6 << 27) | (1 << 16) | 12);
            w.put32(bytes[8..], 7 << 16);
            @memcpy(output[0..12], &bytes);
            self.non_event_sent = true;
            return 12;
        }
        if (self.stale_once and !self.stale_sent) {
            const old = ack(if (self.sequence == 1) 15 else self.sequence - 1, 1, 0);
            @memcpy(output[0..44], &old);
            self.stale_sent = true;
            return 44;
        }
        self.waiting = false;
        if (self.power) {
            var bytes: [530]u8 = undefined;
            header(&bytes, 0xd0, self.sequence);
            w.put16(bytes[38..], if (self.bad_power) 0 else 494);
            bytes[40] = 6;
            for (0..3) |table| {
                bytes[44 + table * 162] = 6;
                @memset(bytes[45 + table * 162 ..][0..161], @intCast(40 - table * 5));
            }
            bytes[45 + 162 + 160] = 127;
            @memcpy(output[0..530], &bytes);
            return 530;
        }
        if (self.cap) {
            const b = capabilities(self.sequence);
            @memcpy(output[0..99], &b);
            return 99;
        }
        if (self.legacy) {
            if (self.efuse) {
                var b: [60]u8 = undefined;
                header(&b, 0xed, self.sequence);
                b[32] = 1;
                w.put32(b[36..], self.efuse_address);
                w.put32(b[40..], 0x1234);
                @memset(b[44..60], 0x42);
                @memcpy(output[0..60], &b);
                return 60;
            }
            var b: [36]u8 = undefined;
            header(&b, 1, self.sequence);
            @memcpy(output[0..36], &b);
            return 36;
        }
        const b = ack(self.sequence, if (self.wrong_cid) 0xff else self.command, if (self.negative_status) 1 else 0);
        @memcpy(output[0..44], &b);
        return 44;
    }
    fn delay(context: *anyopaque, _: u32) !void {
        cast(context).delays += 1;
    }
    fn channel(self: *Replay) m.Channel {
        return .{ .context = self, .submit = submit, .receive = receive, .delayUs = delay };
    }
};
test "NIC client uses actual response path and reusable source sequence wraps after successful consumption" {
    var replay: Replay = .{ .stale_once = true };
    var mcu: m.Mcu = undefined;
    mcu.init(replay.channel());
    var client: n.Client = .{};
    try client.initReusable(&mcu, 1);
    const facts = try client.capabilities();
    try t.expectEqualSlices(u8, &address, &facts.address);
    for (0..20) |_| try t.expectEqual(@as(?u32, 0), (try client.device(device)).status);
    try t.expectEqual(@as(usize, 21), replay.count);
    try t.expectEqual(@as(u8, 6), mcu.seq);
    try t.expectEqual(@as(?u32, 0), (try client.bss(bss)).status);
    try t.expectEqual(@as(?u32, 0), (try client.station(station)).status);
    try t.expectEqual(@as(?u32, null), (try client.channel(.{ .band = .ghz5, .number = 36, .antenna_mask = 3, .passive = false })).status);
    try t.expectEqual(@as(?u32, 0), (try client.rlm(1, .{ .band = .ghz5, .number = 36, .antenna_mask = 3, .passive = false })).status);
    try t.expect(!mcu.busy and !mcu.stopped);
}
test "NIC bounded history copied clients and invalid requests reject before hardware IO" {
    var replay: Replay = .{};
    var mcu: m.Mcu = undefined;
    mcu.init(replay.channel());
    var client: n.Client = .{};
    try client.init(&mcu, 1, 0xfffe);
    try t.expectError(error.NicSequenceExhausted, client.device(device));
    var copy = client;
    try t.expectError(error.MovedNicClient, copy.device(device));
    try t.expectError(error.MovedNicClient, copy.afterDeviceReset(2, 0));
    try t.expectError(error.NicAlreadyInitialized, client.initReusable(&mcu, 2));
    try client.afterDeviceReset(2, 0);
    var invalid = device;
    invalid.omac_index = 4;
    try t.expectError(error.InvalidDeviceRecord, client.device(invalid));
    try t.expectEqual(@as(u16, 0), client.used_sequences);
    try t.expectEqual(@as(usize, 0), replay.count);
    mcu.busy = true;
    try t.expectError(error.McuBusy, client.device(device));
    try t.expectEqual(@as(usize, 0), replay.count);
}
test "NIC transport timeout malformed matching CID or rejection poison until confirmed reset" {
    for (0..4) |failure| {
        var replay: Replay = .{};
        replay.no_response = failure == 0;
        replay.fail_submit = failure == 1;
        replay.wrong_cid = failure == 2;
        replay.negative_status = failure == 3;
        var mcu: m.Mcu = undefined;
        mcu.init(replay.channel());
        var client: n.Client = .{};
        try client.initReusable(&mcu, 1);
        const expected = switch (failure) {
            0 => error.NicTimeout,
            1 => error.InjectedIO,
            2 => error.UnexpectedNicResponse,
            else => error.FirmwareRejected,
        };
        try t.expectError(expected, client.device(device));
        try t.expect(mcu.stopped and !mcu.busy);
        try t.expectError(error.McuStopped, client.device(device));
        try t.expectError(error.McuStopped, client.afterDeviceReset(2, 0));
        if (failure == 0) try t.expectEqual(@as(usize, 3000), replay.delays);
        mcu.init(replay.channel()); // test models separately proved hardware reset
        try client.afterDeviceReset(2, 0);
    }
}
test "NIC key submission consumes real ACK and volatile-clears owned host key copies on success and failure" {
    for ([_]bool{ false, true }) |fail| {
        var replay: Replay = .{ .negative_status = fail };
        var mcu: m.Mcu = undefined;
        mcu.init(replay.channel());
        var client: n.Client = .{};
        try client.initReusable(&mcu, 1);
        const key: [16]u8 = @splat(0x42);
        const options = n.CcmpKey{ .bss_index = 1, .omac_index = 2, .wlan_index = 7, .key_id = 0, .install = true, .bytes = &key };
        if (fail) try t.expectError(error.FirmwareRejected, client.ccmp(options)) else try t.expectEqual(@as(?u32, 0), (try client.ccmp(options)).status);
        for (client.payload) |b| try t.expectEqual(@as(u8, 0), b);
        for (mcu.tx) |b| try t.expectEqual(@as(u8, 0), b);
        for (key) |b| try t.expectEqual(@as(u8, 0x42), b); // immutable caller input owned separately
    }
}
test "NIC EFUSE query matches source24byte aligned request and echoedblock facts" {
    var output: [128]u8 = @splat(0xaa);
    const body = try n.encodeEfuseRead(0x55b, &output);
    try t.expectEqual(@as(usize, 24), body.len);
    try t.expectEqual(@as(u32, 0x550), w.le32(body));
    var packet: [128]u8 = undefined;
    const query = try n.encodeRequest(.efuse_read, 2, body, &packet);
    try t.expectEqual(@as(u8, 0), query[38]);
    try t.expectEqual(@as(u8, 1), query[41]);
    var event: [60]u8 = undefined;
    header(&event, 0xed, 2);
    event[32] = 1;
    w.put32(event[36..], 0x550);
    w.put32(event[40..], 0x1234);
    @memset(event[44..60], 0x42);
    const facts = try n.decodeEfuse(&event, 2, 0x55b);
    try t.expectEqual(@as(u32, 0x550), facts.address);
    try t.expectEqual(@as(u32, 0x1234), facts.validity);
    try t.expectEqual(@as(u8, 0x42), facts.data[11]);
    w.put32(event[36..], 0x560);
    try t.expectError(error.InvalidEepromResponse, n.decodeEfuse(&event, 2, 0x55b));
    @memset(&output, 0xaa);
    try t.expectError(error.InvalidEepromOffset, n.encodeEfuseRead(0xa00, &output));
    try canary(&output);
}
test "NIC actual EFUSE mode MAC enable RX path and RTS methods await source replies" {
    var replay: Replay = .{};
    var mcu: m.Mcu = undefined;
    mcu.init(replay.channel());
    var client: n.Client = .{};
    try client.initReusable(&mcu, 1);
    const facts = try client.readEfuse(0x55b);
    try t.expectEqual(@as(u32, 0x550), facts.address);
    try t.expectEqual(@as(u32, 0x1234), facts.validity);
    try t.expectEqual(@as(?u32, null), (try client.useEfuse()).status);
    try t.expectEqual(@as(?u32, null), (try client.macEnable(true)).status);
    try t.expectEqual(@as(?u32, null), (try client.rxPath(.{ .band = .ghz5, .number = 36, .antenna_mask = 3, .passive = true })).status);
    try t.expectEqual(@as(?u32, null), (try client.rtsThreshold(0x92b)).status);
    try t.expectEqual(@as(usize, 5), replay.count);
    try t.expectError(error.InvalidRtsThreshold, client.rtsThreshold(0x10000));
    try t.expectEqual(@as(usize, 5), replay.count);
    var output: [76]u8 = undefined;
    const encoded = try n.encodeRxPath(.{ .band = .ghz5, .number = 36, .antenna_mask = 3, .passive = true }, &output);
    try t.expectEqual(@as(u8, 3), encoded[4]);
    try t.expectEqual(@as(u8, 0), encoded[5]);
}
const RegisterReplay = struct {
    entries: [64]struct { address: u32 = 0xffffffff, value: u32 = 0 } = @splat(.{}),
    active: bool = false,
    writes: usize = 0,
    clears: usize = 0,
    last_index: u32 = 0,
    busy: bool = false,
    fail_at: ?usize = null,
    no_store: bool = false,
    delay_count: usize = 0,
    fn cast(context: *anyopaque) *RegisterReplay {
        return @ptrCast(@alignCast(context));
    }
    fn entry(self: *RegisterReplay, address_: u32) *@typeInfo(@FieldType(RegisterReplay, "entries")).array.child {
        for (&self.entries) |*e| if (e.address == address_) return e;
        for (&self.entries) |*e| if (e.address == 0xffffffff) {
            e.address = address_;
            return e;
        };
        unreachable;
    }
    fn begin(context: *anyopaque) !void {
        const self = cast(context);
        if (self.active) return error.ReentrantRegisters;
        self.active = true;
    }
    fn end(context: *anyopaque) void {
        cast(context).active = false;
    }
    fn read(context: *anyopaque, address_: u32) !u32 {
        const self = cast(context);
        if (address_ == 0x34230 and self.busy) return 1 << 31;
        return self.entry(address_).value;
    }
    fn write(context: *anyopaque, address_: u32, value: u32) !void {
        const self = cast(context);
        if (self.fail_at == self.writes) return error.InjectedIO;
        self.writes += 1;
        if (address_ == 0x34230) {
            self.clears += 1;
            self.last_index = value & 0x3ff;
        }
        if (!self.no_store) self.entry(address_).value = value;
    }
    fn fence(_: *anyopaque) void {}
    fn delay(context: *anyopaque, us: u32) !void {
        try t.expectEqual(@as(u32, 1), us);
        cast(context).delay_count += 1;
    }
    fn provider(self: *RegisterReplay) @import("registers.zig").Mmio {
        return .{ .context = self, .span = 0x100000, .begin = begin, .end = end, .read32 = read, .write32 = write, .fence = fence };
    }
};
test "NIC source global MDP WTBL and both MAC bands preserve unrelated bits and raw80211" {
    var replay: RegisterReplay = .{};
    replay.entry(0xf000).value = 1 << 19;
    replay.entry(0xf004).value = 0x90000007;
    var regs = try @import("registers.zig").Registers.init(replay.provider());
    try @import("nic_registers.zig").initialize(&regs, .{ .context = &replay, .delayUs = RegisterReplay.delay });
    try t.expectEqual(@as(u32, 0x90003007), replay.entry(0xf004).value);
    try t.expectEqual(@as(u32, 1 << 15), replay.entry(0xf000).value);
    try t.expectEqual(@as(usize, 20), replay.clears);
    try t.expectEqual(@as(u32, 19), replay.last_index);
    for ([_]u32{ 0x210f4, 0xa10f4 }) |address_| try t.expectEqual(@as(u32, 0x6003f), replay.entry(address_).value);
    for ([_]u32{ 0x21e00, 0xa1e00 }) |address_| try t.expectEqual(@as(u32, 0x3000), replay.entry(address_).value);
    for ([_]u32{ 0x23408, 0xa3408 }) |address_| try t.expectEqual(@as(u32, 0x03000000), replay.entry(address_).value);
    try t.expect(!replay.active);
}
test "NIC global MAC no-op IO failure and stuck WTBL are bounded and cannot publish initialized driver" {
    for (0..3) |failure| {
        var replay: RegisterReplay = .{};
        replay.no_store = failure == 0;
        replay.fail_at = if (failure == 1) 1 else null;
        replay.busy = failure == 2;
        var driver = @import("driver.zig").Driver.init(try @import("registers.zig").Registers.init(replay.provider()), .{ .context = &replay, .delayUs = RegisterReplay.delay });
        try t.expectError(error.InvalidDriverState, driver.initMac());
        driver.state = .firmware_ready;
        const expected = switch (failure) {
            0 => error.MacRegisterVerificationFailed,
            1 => error.InjectedIO,
            else => error.WtblTimeout,
        };
        try t.expectError(expected, driver.initMac());
        try t.expectEqual(@import("driver.zig").State.failed, driver.state);
        try t.expect(!driver.snapshot().mac_initialized);
        if (failure == 2) try t.expectEqual(@as(usize, 5000), replay.delay_count);
        try t.expect(!replay.active);
    }
}
test "NIC key and request codec aliases fail before zeroing borrowed input or output" {
    var bytes: [256]u8 = @splat(0x42);
    const expected = bytes;
    try t.expectError(error.OverlappingNicBuffers, n.encodeCcmp(.{ .bss_index = 1, .omac_index = 2, .wlan_index = 7, .key_id = 0, .install = true, .bytes = bytes[20..36] }, &bytes));
    try t.expectEqualSlices(u8, &expected, &bytes);
    try t.expectError(error.OverlappingNicBuffers, n.encodeRequest(.device, 1, bytes[0..16], &bytes));
    try t.expectEqualSlices(u8, &expected, &bytes);
}
test "NIC overlapping control owners and keys in retained scratch reject without IO or secret mutation" {
    var replay: Replay = .{};
    var mcu: m.Mcu = undefined;
    mcu.init(replay.channel());
    @memset(&mcu.tx, 0x42);
    const alignment: usize = @alignOf(n.Client);
    const inside = (@intFromPtr(&mcu.tx) + alignment - 1) & ~(alignment - 1);
    const alias: *n.Client = @ptrFromInt(inside);
    try t.expectError(error.OverlappingNicOwner, alias.initReusable(&mcu, 1));
    for (mcu.tx) |b| try t.expectEqual(@as(u8, 0x42), b);
    var client: n.Client = .{};
    try client.initReusable(&mcu, 1);
    @memset(&client.payload, 0x42);
    try t.expectError(error.KeyStorageAliasesOwner, client.ccmp(.{ .bss_index = 1, .omac_index = 2, .wlan_index = 7, .key_id = 0, .install = true, .bytes = client.payload[0..16] }));
    for (client.payload) |b| try t.expectEqual(@as(u8, 0x42), b);
    try t.expectEqual(@as(usize, 0), replay.count);
}
const RoutedEvent = struct {
    mcu: *m.Mcu,
    calls: usize = 0,
    copy: [12]u8 = undefined,
    fn other(context: *anyopaque, bytes: []const u8) !void {
        const self: *RoutedEvent = @ptrCast(@alignCast(context));
        try t.expect(self.mcu.busy);
        try t.expectEqual(@import("mac.zig").PacketKind.tx_free, (try @import("mac.zig").packet(bytes)).kind);
        try t.expectEqual(@as(usize, 12), bytes.len);
        @memcpy(&self.copy, bytes);
        self.calls += 1;
    }
};
test "NIC command demux routes real TXFREE before matching ACK without retaining reused MCU RX bytes" {
    var replay: Replay = .{ .non_event_once = true };
    var mcu: m.Mcu = undefined;
    mcu.init(replay.channel());
    var client: n.Client = .{};
    try client.initReusable(&mcu, 1);
    var routed: RoutedEvent = .{ .mcu = &mcu };
    client.events = .{ .context = &routed, .other = RoutedEvent.other };
    try t.expectEqual(@as(?u32, 0), (try client.device(device)).status);
    try t.expectEqual(@as(usize, 1), routed.calls);
    try t.expectEqual(@as(u32, 7 << 16), w.le32(routed.copy[8..]));
    try t.expectEqual(@as(u8, 7), mcu.rx[3] >> 3); // now overwritten by actual ACK
    try t.expect(!mcu.busy and !mcu.stopped);
}
test "NIC GET_TXPWR is source CE SET command with eight zero request bytes no extended CID or fake ACK" {
    var output: [100]u8 = @splat(0x55);
    const request = try n.encodeRequest(.tx_power, 3, &@as([8]u8, @splat(0)), &output);
    try t.expectEqual(@as(usize, 72), request.len);
    try t.expectEqualSlices(u8, &.{ 0, 0x80, 0xd0, 0xa0, 1, 3, 0, 0, 0, 0, 0, 0 }, request[34..46]);
    try t.expect(std.mem.allEqual(u8, request[64..72], 0));
    const before = output;
    try t.expectError(error.InvalidNicPayload, n.encodeRequest(.tx_power, 3, &.{1}, &output));
    try t.expectEqualSlices(u8, &before, &output);
    try t.expectError(error.InvalidNicRequest, n.decodeResponse(&ack(3, 0xd0, 0), 3, .tx_power));
}
test "NIC GET_TXPWR copies bound factory tables after unsolicited and stale events but poisons malformed response" {
    var replay: Replay = .{ .stale_once = true, .non_event_once = true };
    var mcu: m.Mcu = undefined;
    mcu.init(replay.channel());
    var client: n.Client = .{};
    try client.initReusable(&mcu, 1);
    var routed: PowerEvents = .{ .mcu = &mcu };
    client.events = .{ .context = &routed, .other = PowerEvents.other };
    const found = try client.txPowerInfo();
    try t.expectEqual(@as(u8, 6), found.channel);
    try t.expectEqual(@as(i32, 1500), try found.rateCeiling(0));
    try t.expectError(error.PowerUnavailable, found.rateCeiling(160));
    @memset(&mcu.rx, 0);
    try t.expectEqual(@as(i32, 1500), try found.rateCeiling(0));
    try t.expectEqual(@as(usize, 1), routed.frees);
    try t.expectEqual(@as(usize, 1), routed.stale);
    try t.expectEqual(@as(u32, 7 << 16), w.le32(routed.copy[8..]));
    try t.expect(!mcu.stopped and !mcu.busy);
    replay.bad_power = true;
    try t.expectError(error.InvalidPowerReport, client.txPowerInfo());
    try t.expect(mcu.stopped and !mcu.busy);
    try t.expectError(error.McuStopped, client.txPowerInfo());
}
const PowerEvents = struct {
    mcu: *m.Mcu,
    frees: usize = 0,
    stale: usize = 0,
    copy: [12]u8 = undefined,
    fn other(context: *anyopaque, bytes: []const u8) !void {
        const self: *PowerEvents = @ptrCast(@alignCast(context));
        try t.expect(self.mcu.busy);
        const packet = try @import("mac.zig").packet(bytes);
        switch (packet.kind) {
            .tx_free => {
                try t.expectEqual(@as(usize, 12), bytes.len);
                @memcpy(&self.copy, bytes);
                self.frees += 1;
            },
            .event => {
                try t.expectEqual(@as(usize, 44), bytes.len);
                try t.expectEqual(@as(u8, 1), bytes[28]);
                try t.expect(bytes[29] != self.mcu.seq);
                try t.expectEqual(@as(u8, 1), bytes[36]);
                self.stale += 1;
            },
            else => return error.UnexpectedFixturePacket,
        }
    }
};
