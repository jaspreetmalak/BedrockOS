// SPDX-License-Identifier: ISC
// Copyright (C) 2020 MediaTek Inc.
// Copyright (C) 2026 Bedrock contributors
// Derived from Linux v6.18 mt7921/mcu.c and mt76_connac_mcu.{c,h}.
// See PROVENANCE.json and LICENSE for immutable source attribution.
//! Actual MCU control protocols. Facts and command responses are not calibration,
//! legal TX permission, physical link proof or general radio readiness.
const w = @import("wire.zig");
const std = @import("std");
const mac = @import("mac.zig");
const regulatory = @import("regulatory.zig");
const Mcu = @import("mcu.zig").Mcu;
pub const Band = mac.Band;
pub const device_size = 16;
pub const bss_size = 44;
pub const station_size = 120;
pub const channel_size = 76;
pub const key_size = 88;
pub const Request = enum { capabilities, device, bss, station, channel, key, efuse_read, efuse_mode, mac_enable, rx_path, rts, tx_power };
pub const ResponseProof = struct { sequence: u8, command: u8, status: ?u32 };
pub const Phy = struct {
    raw: [12]u8,
    nss: u8,
    antenna_mask: u8,
    max_bandwidth_code: u8,
    has_2ghz: bool,
    has_5ghz: bool,
};
pub const Capabilities = struct {
    address: [6]u8,
    phy: Phy,
    has_6ghz: bool = false,
    chip_capability: ?u64 = null,
};
const Event = struct { bytes: []const u8, body: []const u8, eid: u8, ext_eid: u8, sequence: u8, unsolicited: bool };
fn event(bytes: []const u8) !Event {
    const packet = try mac.packet(bytes);
    if (packet.kind != .event or packet.bytes.len < 36) return error.InvalidNicEvent;
    const b = packet.bytes;
    const len = w.le16(b[24..]);
    if (len < 12 or len > b.len - 24 or b.len - 24 - len > 3) return error.InvalidNicEvent;
    return .{ .bytes = b, .body = b[36 .. 24 + len], .eid = b[28], .ext_eid = b[32], .sequence = b[29], .unsolicited = b[30] & 4 != 0 };
}
fn addressValid(address: [6]u8) bool {
    var nonzero: u8 = 0;
    for (address) |b| nonzero |= b;
    return address[0] & 1 == 0 and nonzero != 0;
}
fn overlap(a: []const u8, b: []const u8) bool {
    if (a.len == 0 or b.len == 0) return false;
    const aa = @intFromPtr(a.ptr);
    const bb = @intFromPtr(b.ptr);
    return if (aa <= bb) bb - aa < a.len else aa - bb < b.len;
}
fn storage(pointer: *const anyopaque, size: usize) []const u8 {
    const bytes: [*]const u8 = @ptrCast(pointer);
    return bytes[0..size];
}
pub fn decodeCapabilities(bytes: []const u8, sequence: u8) !Capabilities {
    if (sequence == 0 or sequence > 15) return error.InvalidNicSequence;
    const e = try event(bytes);
    if (e.sequence != sequence) return error.StaleNicResponse;
    // mt7921_mcu_rx_event explicitly routes legacy EID0x06 to pending replies.
    if (e.eid != 6 or e.unsolicited or e.body.len < 4) return error.InvalidNicCapabilities;
    const count = w.le16(e.body);
    if (count == 0 or count > 64) return error.InvalidNicCapabilities;
    var result: Capabilities = undefined;
    result.has_6ghz = false;
    result.chip_capability = null;
    var have_mac = false;
    var have_phy = false;
    var have_6g = false;
    var have_chip = false;
    var pos: usize = 4;
    for (0..count) |_| {
        if (e.body.len - pos < 8) return error.TruncatedNicCapability;
        const tag = w.le32(e.body[pos..]);
        const size = w.le32(e.body[pos + 4 ..]);
        pos += 8;
        if (size > e.body.len - pos) return error.TruncatedNicCapability;
        const body = e.body[pos..][0..size];
        switch (tag) {
            7 => {
                if (have_mac or size != 6 or !addressValid(body[0..6].*)) return error.InvalidNicMac;
                result.address = body[0..6].*;
                have_mac = true;
            },
            8 => {
                if (have_phy or size != 12 or body[4] == 0 or body[4] > 8 or body[10] & 3 == 0) return error.InvalidNicPhy;
                // Preserve unknown bandwidth/capability codes as firmware facts;
                // only nss/path get normalized. No power or calibration inferred.
                result.phy = .{ .raw = body[0..12].*, .nss = body[4], .antenna_mask = @intCast((@as(u16, 1) << @intCast(body[4])) - 1), .max_bandwidth_code = body[3], .has_2ghz = body[10] & 1 != 0, .has_5ghz = body[10] & 2 != 0 };
                have_phy = true;
            },
            0x18 => {
                if (have_6g or size != 1 or body[0] > 1) return error.InvalidNicBand;
                result.has_6ghz = body[0] != 0;
                have_6g = true;
            },
            0x20 => {
                if (have_chip or size != 8) return error.InvalidNicChipCapability;
                result.chip_capability = @as(u64, w.le32(body)) | @as(u64, w.le32(body[4..])) << 32;
                have_chip = true;
            },
            else => {},
        }
        pos += size;
    }
    if (pos != e.body.len or !have_mac or !have_phy) return error.IncompleteNicCapabilities;
    return result;
}
fn cid(request: Request) u8 {
    return switch (request) {
        .capabilities => 0x8a,
        .device => 1,
        .bss => 2,
        .station, .key => 3,
        .channel => 0x08,
        .efuse_read => 0x01,
        .efuse_mode => 0x21,
        .mac_enable => 0x46,
        .rx_path => 0x4e,
        .rts => 0x3e,
        .tx_power => 0xd0,
    };
}
fn unifiedRequest(request: Request) bool {
    return switch (request) {
        .device, .bss, .station, .key => true,
        else => false,
    };
}
pub fn decodeResponse(bytes: []const u8, sequence: u8, request: Request) !ResponseProof {
    if (sequence == 0 or sequence > 15) return error.InvalidNicSequence;
    const e = try event(bytes);
    if (e.sequence != sequence) return error.StaleNicResponse;
    if (e.unsolicited) return error.UnsolicitedNicResponse;
    if (!unifiedRequest(request) and request != .capabilities and request != .efuse_read and request != .tx_power) {
        // Pinned MT7921 strips a matched legacy reply without interpreting any
        // outcome payload. Do not invent a status code or RF/PLL success proof.
        if (e.bytes[30] & 2 != 0 or (e.eid != 1 and !(e.eid == 0xed and e.ext_eid == 0))) return error.UnexpectedNicResponse;
        return .{ .sequence = sequence, .command = cid(request), .status = null };
    }
    if (request == .capabilities or request == .efuse_read or request == .tx_power) return error.InvalidNicRequest;
    if (e.eid != 1 or e.body.len != 8 or e.body[0] != cid(request)) return error.UnexpectedNicResponse;
    const status = w.le32(e.body[4..]);
    if (status != 0) return error.FirmwareRejected;
    return .{ .sequence = sequence, .command = cid(request), .status = status };
}
pub fn encodeRequest(request: Request, sequence: u8, payload: []const u8, output: []u8) ![]const u8 {
    if (sequence == 0 or sequence > 15) return error.InvalidNicSequence;
    if (payload.len > 4096 or (request == .capabilities and payload.len != 0) or (request == .tx_power and (payload.len != 8 or !std.mem.allEqual(u8, payload, 0)))) return error.InvalidNicPayload;
    const unified = unifiedRequest(request);
    const header: usize = if (unified) 48 else 64;
    if (output.len < header + payload.len) return error.OutputTooSmall;
    const b = output[0 .. header + payload.len];
    if (overlap(payload, b)) return error.OverlappingNicBuffers;
    @memset(b, 0);
    w.put32(b, @as(u32, @intCast(b.len)) | (2 << 23) | (0x20 << 25));
    w.put32(b[4..], (1 << 31) | (1 << 16));
    w.put16(b[32..], @intCast(b.len - 32));
    b[37] = 0xa0;
    b[39] = sequence;
    if (unified) {
        w.put16(b[34..], cid(request));
        b[43] = 7; // ACK | UNIFIED | SET, exactly MCU_CMD_UNI_EXT_ACK.
    } else {
        w.put16(b[34..], 0x8000);
        const ce = request == .capabilities or request == .tx_power;
        b[36] = if (!ce) 0xed else cid(request);
        b[38] = if (request == .efuse_read) 0 else 1; // GET_NIC_CAPAB is CE_CMD.
        if (!ce) {
            b[41] = cid(request);
            b[43] = 1; // ext_cid_ack
        }
    }
    @memcpy(b[header..], payload);
    return b;
}
fn indices(bss: u8, omac: u8, wcid: u16) !void {
    if (bss >= 4 or omac >= 4 or wcid >= 20) return error.InvalidNicIndex;
}
fn tlv(b: []u8, tag: u16, len: u16) void {
    w.put16(b, tag);
    w.put16(b[2..], len);
}
pub const Device = struct { omac_index: u8, band_index: u8 = 0, link_index: u8 = 0, address: [6]u8, enabled: bool };
pub fn encodeDevice(device: Device, output: []u8) ![]const u8 {
    if (device.omac_index >= 4 or device.band_index != 0 or device.link_index != 0 or !addressValid(device.address)) return error.InvalidDeviceRecord;
    if (output.len < device_size) return error.OutputTooSmall;
    const b = output[0..device_size];
    @memset(b, 0);
    b[0] = device.omac_index;
    tlv(b[4..], 0, 12);
    b[8] = @intFromBool(device.enabled);
    @memcpy(b[10..16], &device.address);
    return b;
}
pub const Bss = struct {
    bss_index: u8,
    omac_index: u8,
    wmm_index: u8,
    wlan_index: u16,
    band: Band,
    bssid: [6]u8,
    connected: bool,
    beacon_interval: u16,
    dtim_period: u8,
    basic_rates: u16,
    qos: bool = false,
};
pub fn encodeBss(options: Bss, output: []u8) ![]const u8 {
    try indices(options.bss_index, options.omac_index, options.wlan_index);
    if (options.band == .ghz6 or options.wmm_index >= 4 or !addressValid(options.bssid) or options.beacon_interval == 0 or options.dtim_period == 0 or options.qos) return error.InvalidBssRecord;
    const allowed: u16 = if (options.band == .ghz2) 0x0fff else 0x00ff;
    if (options.basic_rates == 0 or options.basic_rates & ~allowed != 0) return error.InvalidLegacyRates;
    if (output.len < bss_size) return error.OutputTooSmall;
    const b = output[0..bss_size];
    @memset(b, 0);
    b[0] = options.bss_index;
    const basic = b[4..36];
    tlv(basic, 0, 32);
    basic[4] = 1; // source station BSS remains active even when disconnected.
    basic[5] = options.omac_index;
    basic[6] = options.omac_index;
    w.put32(basic[8..], 0x10001); // CONNECTION_INFRA_STA
    basic[12] = @intFromBool(!options.connected);
    basic[13] = options.wmm_index;
    @memcpy(basic[14..20], &options.bssid);
    w.put16(basic[20..], options.wlan_index);
    w.put16(basic[22..], options.beacon_interval);
    basic[24] = options.dtim_period;
    basic[25] = if (options.band == .ghz2) 6 else 1; // B/G or A, no HT claims.
    w.put16(basic[26..], options.wlan_index);
    w.put16(basic[28..], if (options.band == .ghz2) 3 else 8); // PHY type bitmap
    tlv(b[36..], 15, 8); // QBSS qos=false for initial non-QoS raw profile.
    return b;
}
pub const PeerState = enum(u8) { none = 0, authenticated = 2, associated = 3, authorized = 4 };
pub const Station = struct {
    bss_index: u8,
    omac_index: u8,
    wlan_index: u16,
    peer: [6]u8,
    aid: u16,
    band: Band,
    supported_rates: u16,
    basic_rates: u16,
    rcpi: u8,
    state: PeerState,
    enabled: bool = true,
    secured: bool = false,
    newly: bool = true,
};
fn staHeader(b: []u8, bss: u8, omac: u8, wcid: u16, count: u16) void {
    b[0] = bss;
    b[1] = @intCast(wcid);
    w.put16(b[2..], count);
    b[4] = 1;
    b[5] = omac;
}
pub fn encodeStation(options: Station, output: []u8) ![]const u8 {
    try indices(options.bss_index, options.omac_index, options.wlan_index);
    if (!addressValid(options.peer) or options.aid > 2007 or options.band == .ghz6 or (options.secured and options.state != .authorized)) return error.InvalidStationRecord;
    const mask: u16 = if (options.band == .ghz2) 0x0fff else 0x00ff;
    if (options.enabled and (options.state == .none or options.supported_rates == 0 or options.supported_rates & ~mask != 0 or options.basic_rates == 0 or options.basic_rates & ~options.supported_rates != 0)) return error.InvalidLegacyRates;
    const size: usize = if (options.enabled) station_size else 40;
    if (output.len < size) return error.OutputTooSmall;
    const b = output[0..size];
    @memset(b, 0);
    staHeader(b, options.bss_index, options.omac_index, options.wlan_index, if (options.enabled) 5 else 2);
    const basic = b[8..28];
    tlv(basic, 0, 20);
    w.put32(basic[4..], 0x10001);
    basic[8] = if (!options.enabled) 0 else if (options.secured) 2 else 1;
    w.put16(basic[10..], options.aid);
    @memcpy(basic[12..18], &options.peer);
    w.put16(basic[18..], 1 | (if (options.newly) @as(u16, 2) else 0));
    const wt_offset: usize = if (options.enabled) 68 else 28;
    if (options.enabled) {
        tlv(b[28..], 0x15, 12); // PHY, actual basic rates/RCPI; no AMPDU/HT.
        w.put16(b[32..], options.basic_rates);
        b[34] = if (options.band == .ghz2) 3 else 8;
        b[37] = options.rcpi;
        tlv(b[40..], 1, 16); // legacy RA, MCS bitmap remains zero.
        const rates = if (options.band == .ghz2) (options.supported_rates & 15) | ((options.supported_rates >> 4) << 6) else options.supported_rates << 6;
        w.put16(b[44..], rates);
        tlv(b[56..], 7, 12);
        b[64] = @backingInt(options.state);
    }
    const wt = b[wt_offset..];
    tlv(wt, 13, if (options.enabled) 52 else 12);
    wt[4] = @intCast(options.wlan_index);
    wt[5] = 1; // WTBL_RESET_AND_SET
    w.put16(wt[6..], if (options.enabled) 3 else 0);
    if (options.enabled) {
        tlv(wt[12..], 0, 20);
        @memcpy(wt[16..22], &options.peer);
        wt[22] = options.omac_index;
        w.put16(wt[28..], options.aid);
        tlv(wt[32..], 1, 12);
        wt[37] = 1; // rca1: station, not AP
        wt[38] = 1;
        wt[39] = 1;
        tlv(wt[44..], 6, 8);
        wt[48] = 1; // to_ds
        wt[50] = 1; // no_rx_trans: preserve raw80211 for software CCMP.
    }
    return b;
}
pub const Channel20 = struct { band: Band, number: u8, antenna_mask: u8, passive: bool };
pub fn encodeChannel(options: Channel20, output: []u8) ![]const u8 {
    if (!regulatory.channelValid(options.band, options.number) or options.antenna_mask == 0 or options.antenna_mask & ~@as(u8, 3) != 0) return error.InvalidNicChannel;
    if (output.len < channel_size) return error.OutputTooSmall;
    const b = output[0..channel_size];
    @memset(b, 0);
    b[0] = options.number;
    b[1] = options.number;
    const streams: u8 = @popCount(options.antenna_mask);
    b[3] = streams;
    b[4] = streams; // CHANNEL_SWITCH takes count, SET_RX_PATH takes a mask.
    b[5] = if (options.passive) 5 else 0; // CH_SWITCH_DFS vs NORMAL
    b[10] = @backingInt(options.band) - 1;
    return b;
}
pub fn encodeRxPath(options: Channel20, output: []u8) ![]const u8 {
    const b = try encodeChannel(options, output);
    output[4] = options.antenna_mask;
    output[5] = 0; // SET_RX_PATH always CH_SWITCH_NORMAL in the pinned source.
    return b;
}
pub const EepromBlock = struct { address: u32, validity: u32, data: [16]u8 };
pub fn encodeEfuseRead(offset: u32, output: []u8) ![]const u8 {
    if (offset > 0x9ff) return error.InvalidEepromOffset;
    if (output.len < 24) return error.OutputTooSmall;
    const b = output[0..24];
    @memset(b, 0);
    w.put32(b, offset & ~@as(u32, 15));
    return b;
}
pub fn decodeEfuse(bytes: []const u8, sequence: u8, offset: u32) !EepromBlock {
    if (sequence == 0 or sequence > 15 or offset > 0x9ff) return error.InvalidEepromOffset;
    const e = try event(bytes);
    if (e.sequence != sequence) return error.StaleNicResponse;
    if (e.unsolicited or e.bytes[30] & 2 != 0 or (e.eid != 1 and !(e.eid == 0xed and e.ext_eid == 1)) or e.body.len != 24 or w.le32(e.body) != offset & ~@as(u32, 15)) return error.InvalidEepromResponse;
    // Preserve the source's validity word as a fact; it is not a calibration or
    // certification assertion. Trusted board policy must interpret it explicitly.
    return .{ .address = w.le32(e.body), .validity = w.le32(e.body[4..]), .data = e.body[8..24].* };
}
pub fn encodeRlm(bss_index: u8, options: Channel20, output: []u8) ![]const u8 {
    if (bss_index >= 4 or options.band == .ghz6 or !regulatory.channelValid(options.band, options.number) or options.antenna_mask == 0 or options.antenna_mask & ~@as(u8, 3) != 0) return error.InvalidNicChannel;
    if (output.len < 20) return error.OutputTooSmall;
    const b = output[0..20];
    @memset(b, 0);
    b[0] = bss_index;
    tlv(b[4..], 2, 16);
    b[8] = options.number;
    b[9] = options.number;
    b[12] = @popCount(options.antenna_mask);
    b[13] = options.antenna_mask;
    b[14] = 1; // short_st, with ht_op_info0 and20MHz bw0.
    b[17] = @backingInt(options.band) - 1;
    return b;
}
pub const CcmpKey = struct { bss_index: u8, omac_index: u8, wlan_index: u16, key_id: u8, install: bool, bytes: []const u8 };
pub fn encodeCcmp(options: CcmpKey, output: []u8) ![]const u8 {
    try indices(options.bss_index, options.omac_index, options.wlan_index);
    if (options.key_id > 3 or options.bytes.len != (if (options.install) @as(usize, 16) else 0)) return error.InvalidCcmpKey;
    if (output.len < key_size) return error.OutputTooSmall;
    const b = output[0..key_size];
    if (overlap(options.bytes, b)) return error.OverlappingNicBuffers;
    @memset(b, 0);
    staHeader(b, options.bss_index, options.omac_index, options.wlan_index, 1);
    // Source allocates the full80-byte sec record, retaining zero unused slot.
    tlv(b[8..], 17, if (options.install) 44 else 8);
    b[12] = @intFromBool(!options.install); // mac80211 SET_KEY=0, DISABLE_KEY=1
    if (options.install) {
        b[13] = 1;
        b[16] = 5; // MCU_CIPHER_AES_CCMP
        b[17] = 36;
        b[18] = options.key_id;
        b[19] = 16;
        @memcpy(b[20..36], options.bytes);
    }
    return b;
}
fn wipe(bytes: []u8) void {
    for (bytes) |*byte| @as(*volatile u8, byte).* = 0;
}
/// Called with one bounded borrowed packet while the shared MCU remains busy.
/// Consume/copy it synchronously; no slice may survive reuse of Mcu.rx.
pub const Events = struct { context: *anyopaque, other: *const fn (*anyopaque, []const u8) anyerror!void };
pub const CorrelationPolicy = enum {
    /// Non-reused sequence namespace; can exhaust after15/history requests.
    bounded_history,
    /// Source-compatible4bit reuse. Caller proves serialized, initially drained
    /// RX; each successful call consumes its response. Not an anti-replay nonce.
    serialized_drained,
};
pub const Client = struct {
    owner_address: usize = 0,
    mcu: *Mcu = undefined,
    device_epoch: u64 = 0,
    used_sequences: u16 = 0,
    correlation_policy: CorrelationPolicy = .bounded_history,
    events: ?Events = null,
    payload: [256]u8 = undefined,
    /// Zero-owner client initialized once, with actual retained shared-MCU
    /// history. Caller proves serialized/drained RX and keeps all hooks alive.
    pub fn init(self: *Client, mcu: *Mcu, epoch: u64, prior_sequences: u16) !void {
        if (overlap(storage(self, @sizeOf(Client)), storage(mcu, @sizeOf(Mcu)))) return error.OverlappingNicOwner;
        if (self.owner_address != 0) return error.NicAlreadyInitialized;
        if (epoch == 0 or prior_sequences & 1 != 0) return error.InvalidNicEpoch;
        if (mcu.busy) return error.McuBusy;
        if (mcu.stopped) return error.McuStopped;
        self.owner_address = @intFromPtr(self);
        self.mcu = mcu;
        self.device_epoch = epoch;
        self.used_sequences = prior_sequences;
    }
    /// Explicit trust contract: no other consumer/pending command, initially
    /// drained response queue, trusted firmware and serialized shared MCU.
    /// Firmware provides only4bit correlation; duplicate stale replies cannot
    /// be cryptographically distinguished across source-compatible wrap.
    pub fn initReusable(self: *Client, mcu: *Mcu, epoch: u64) !void {
        try self.init(mcu, epoch, 0);
        self.correlation_policy = .serialized_drained;
    }
    fn check(self: *const Client) !void {
        if (self.owner_address == 0) return error.NicUninitialized;
        if (self.owner_address != @intFromPtr(self)) return error.MovedNicClient;
        if (overlap(storage(self, @sizeOf(Client)), storage(self.mcu, @sizeOf(Mcu)))) return error.OverlappingNicOwner;
        if (self.mcu.busy) return error.McuBusy;
        if (self.mcu.stopped) return error.McuStopped;
    }
    pub fn afterDeviceReset(self: *Client, epoch: u64, prior_sequences: u16) !void {
        try self.check();
        if (epoch <= self.device_epoch or prior_sequences & 1 != 0) return error.StaleNicEpoch;
        self.device_epoch = epoch;
        self.used_sequences = prior_sequences;
    }
    fn next(self: *Client) !u8 {
        if (self.mcu.seq > 15) return error.InvalidNicSequence;
        if (self.correlation_policy == .serialized_drained) {
            self.mcu.seq = if (self.mcu.seq == 15) 1 else self.mcu.seq + 1;
            self.used_sequences |= @as(u16, 1) << @intCast(self.mcu.seq);
            return self.mcu.seq;
        }
        for (0..15) |_| {
            self.mcu.seq = if (self.mcu.seq == 15) 1 else self.mcu.seq + 1;
            const bit = @as(u16, 1) << @intCast(self.mcu.seq);
            if (self.used_sequences & bit == 0) {
                self.used_sequences |= bit;
                return self.mcu.seq;
            }
        }
        return error.NicSequenceExhausted;
    }
    fn request(self: *Client, request_kind: Request, payload: []const u8) !struct { raw: []const u8, proof: ?ResponseProof } {
        try self.check();
        const sequence = try self.next();
        const packet = try encodeRequest(request_kind, sequence, payload, &self.mcu.tx);
        self.mcu.busy = true;
        defer self.mcu.busy = false;
        errdefer self.mcu.stopped = true;
        try self.mcu.channel.submit(self.mcu.channel.context, .wm, packet);
        for (0..3000) |_| {
            if (try self.mcu.channel.receive(self.mcu.channel.context, &self.mcu.rx)) |size| {
                if (size > self.mcu.rx.len) return error.InvalidNicEvent;
                const raw = self.mcu.rx[0..size];
                const received_packet = try mac.packet(raw);
                if (received_packet.kind != .event) {
                    if (self.events) |hooks| {
                        try hooks.other(hooks.context, received_packet.bytes);
                    } else return error.UnexpectedNicPacket;
                    continue;
                }
                const e = try event(raw);
                if (e.sequence == sequence and !e.unsolicited) {
                    if (request_kind == .capabilities) {
                        _ = try decodeCapabilities(raw, sequence);
                        return .{ .raw = raw, .proof = null };
                    }
                    if (request_kind == .efuse_read) {
                        _ = try decodeEfuse(raw, sequence, w.le32(payload));
                        return .{ .raw = raw, .proof = null };
                    }
                    if (request_kind == .tx_power) {
                        _ = try @import("board.zig").decodeTxPowerInfo(raw, sequence);
                        return .{ .raw = raw, .proof = null };
                    }
                    return .{ .raw = raw, .proof = try decodeResponse(raw, sequence, request_kind) };
                }
                if (self.events) |hooks| try hooks.other(hooks.context, raw);
            }
            try self.mcu.channel.delayUs(self.mcu.channel.context, 1000);
        }
        return error.NicTimeout;
    }
    pub fn capabilities(self: *Client) !Capabilities {
        const received = try self.request(.capabilities, &.{});
        return decodeCapabilities(received.raw, received.raw[29]);
    }
    pub fn txPowerInfo(self: *Client) !@import("board.zig").PowerReport {
        try self.check();
        const payload = try @import("board.zig").encodeTxPowerQuery(&self.payload);
        const received = try self.request(.tx_power, payload);
        return @import("board.zig").decodeTxPowerInfo(received.raw, received.raw[29]);
    }
    pub fn device(self: *Client, options: Device) !ResponseProof {
        try self.check();
        return (try self.request(.device, try encodeDevice(options, &self.payload))).proof.?;
    }
    pub fn bss(self: *Client, options: Bss) !ResponseProof {
        try self.check();
        return (try self.request(.bss, try encodeBss(options, &self.payload))).proof.?;
    }
    pub fn station(self: *Client, options: Station) !ResponseProof {
        try self.check();
        return (try self.request(.station, try encodeStation(options, &self.payload))).proof.?;
    }
    pub fn channel(self: *Client, options: Channel20) !ResponseProof {
        try self.check();
        return (try self.request(.channel, try encodeChannel(options, &self.payload))).proof.?;
    }
    pub fn rlm(self: *Client, bss_index: u8, options: Channel20) !ResponseProof {
        try self.check();
        return (try self.request(.bss, try encodeRlm(bss_index, options, &self.payload))).proof.?;
    }
    pub fn rxPath(self: *Client, options: Channel20) !ResponseProof {
        try self.check();
        return (try self.request(.rx_path, try encodeRxPath(options, &self.payload))).proof.?;
    }
    pub fn readEfuse(self: *Client, offset: u32) !EepromBlock {
        try self.check();
        const received = try self.request(.efuse_read, try encodeEfuseRead(offset, &self.payload));
        return decodeEfuse(received.raw, received.raw[29], offset);
    }
    pub fn useEfuse(self: *Client) !ResponseProof {
        // EE_MODE_EFUSE=0, EE_FORMAT_WHOLE=1, no fabricated EEPROM payload.
        return (try self.request(.efuse_mode, &.{ 0, 1, 0, 0 })).proof.?;
    }
    pub fn macEnable(self: *Client, enabled: bool) !ResponseProof {
        return (try self.request(.mac_enable, &.{ @intFromBool(enabled), 0, 0, 0 })).proof.?;
    }
    pub fn rtsThreshold(self: *Client, threshold: u32) !ResponseProof {
        try self.check();
        if (threshold > 0xffff) return error.InvalidRtsThreshold;
        @memset(self.payload[0..12], 0);
        self.payload[0] = 1;
        w.put32(self.payload[4..], threshold);
        w.put32(self.payload[8..], 2);
        return (try self.request(.rts, self.payload[0..12])).proof.?;
    }
    pub fn ccmp(self: *Client, options: CcmpKey) !ResponseProof {
        try self.check();
        if (overlap(options.bytes, storage(self, @sizeOf(Client))) or overlap(options.bytes, storage(self.mcu, @sizeOf(Mcu)))) return error.KeyStorageAliasesOwner;
        // Source channel copies commands into separately owned DMA storage.
        // Clear our host-owned secret copies even when DMA/control times out.
        defer wipe(&self.payload);
        defer wipe(&self.mcu.tx);
        return (try self.request(.key, try encodeCcmp(options, &self.payload))).proof.?;
    }
};
