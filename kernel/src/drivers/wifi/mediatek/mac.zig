// SPDX-License-Identifier: ISC
// Copyright (C) 2020, 2022 MediaTek Inc.
// Copyright (C) 2026 Bedrock contributors
// Derived from Linux v6.18 mt7921/mac.c, mt7921/mt7921.h,
// mt76_connac{,2_mac}.h and mt76_connac_mac.c; see PROVENANCE.json and LICENSE.
const w = @import("wire.zig");
const dma = @import("dma.zig");
pub const PacketKind = enum { normal, event, tx_free, tx_status, other };
pub const Packet = struct { bytes: []const u8, kind: PacketKind, hardware_type: u8 };
pub fn packet(input: []const u8) !Packet {
    if (input.len < 4) return error.TruncatedRxDescriptor;
    const d0 = w.le32(input);
    const size = d0 & 0xffff;
    const kind: u8 = @intCast(d0 >> 27);
    if (size < 4 or size > input.len or input.len - size > 3) return error.InvalidRxLength;
    const flag = (d0 >> 16) & 15;
    return .{ .bytes = input[0..size], .hardware_type = kind, .kind = switch (kind) {
        2, 8 => .normal,
        7 => if (flag == 1) .normal else if (flag == 0) .event else .other,
        6 => .tx_free,
        0 => .tx_status,
        else => .other,
    } };
}
pub const Band = enum(u8) { ghz2 = 1, ghz5 = 2, ghz6 = 3 };
pub const Management = struct { frame: []const u8, bssid: [6]u8, channel: u16, band: Band, signal_dbm: ?i16 };
pub fn management(input: []const u8, antenna_mask: u8) !Management {
    if (antenna_mask == 0 or antenna_mask & 0xf0 != 0) return error.InvalidAntennaMask;
    const p = try packet(input);
    if (p.kind != .normal) return error.WrongRxPacket;
    const b = p.bytes;
    if (b.len < 24) return error.TruncatedRxDescriptor;
    const d1 = w.le32(b[4..]);
    const d2 = w.le32(b[8..]);
    const d3 = w.le32(b[12..]);
    const d4 = w.le32(b[16..]);
    if (d1 & ((1 << 25) | (1 << 26) | (1 << 27) | (1 << 28)) != 0 or d2 & ((1 << 23) | (1 << 24) | (1 << 25) | (1 << 27)) != 0 or d3 & (1 << 30) != 0) return error.BadRxFrame;
    if (d2 & (1 << 13) != 0) return error.HeaderTranslated;
    if (d4 & 3 != 0) return error.UnsupportedAggregation;
    if (d1 & (1 << 15) != 0 and d1 & (1 << 13) == 0) return error.InvalidRxGroups;
    var offset: usize = 24;
    if (d1 & (1 << 14) != 0) offset = try advance(b.len, offset, 16);
    if (d1 & (1 << 11) != 0) offset = try advance(b.len, offset, 16);
    if (d1 & (1 << 12) != 0) offset = try advance(b.len, offset, 8);
    var signal: ?i16 = null;
    if (d1 & (1 << 13) != 0) {
        const start = offset;
        offset = try advance(b.len, offset, 8);
        var rcpi = w.le32(b[start + 4 ..]);
        if (d1 & (1 << 15) != 0) {
            offset = try advance(b.len, offset, 24);
            const monitor = offset;
            offset = try advance(b.len, offset, 48);
            rcpi = w.le32(b[monitor..]);
        }
        for (0..4) |i| if (antenna_mask & (@as(u8, 1) << @intCast(i)) != 0) {
            const raw: u8 = @truncate(rcpi >> @as(u5, @intCast(i * 8)));
            const value = @divFloor(@as(i16, raw) - 220, 2);
            if (value < 0 and (signal == null or value > signal.?)) signal = value;
        };
    }
    offset = try advance(b.len, offset, @as(usize, (d2 >> 14) & 3) * 2);
    if (b.len - offset < 36) return error.TruncatedManagementFrame;
    const frame = b[offset..];
    const fc = w.le16(frame);
    const subtype = (fc >> 4) & 15;
    if (fc & 3 != 0 or fc & 12 != 0 or (subtype != 8 and subtype != 5) or fc & 0xc700 != 0) return error.UnsupportedManagementFrame;
    if (w.le16(frame[22..]) & 15 != 0) return error.FragmentedManagementFrame;
    const encoded = (d3 >> 8) & 0xff;
    if (encoded == 0) return error.InvalidRxChannel;
    const channel: u16 = if (encoded > 180) @intCast((encoded - 181) * 4 + 1) else @intCast(encoded);
    const band: Band = if (encoded > 180) .ghz6 else if (encoded > 14) .ghz5 else .ghz2;
    if (channel > 233 or (band == .ghz5 and channel > 177)) return error.InvalidRxChannel;
    return .{ .frame = frame, .bssid = frame[16..22].*, .channel = channel, .band = band, .signal_dbm = signal };
}
fn advance(total: usize, offset: usize, count: usize) !usize {
    if (offset > total or count > total - offset) return error.TruncatedRxDescriptor;
    return offset + count;
}
pub const TxOptions = struct {
    token: u16,
    wlan_index: u16,
    own_mac: u8 = 0,
    queue: u8 = 0x10,
    /// MT76 encoded PHY rate selected from the qualified channel/rate policy.
    fixed_rate: u16,
    no_ack: bool = false,
    preserve_sequence: bool = true,
};
/// Encode one unencrypted, nonaggregated three-address management/data frame as
/// 32-byte TXWI +32-byte hardware TXP. Payload remains separately DMA-owned.
/// WFDMA descriptor completion does NOT release payload; wait for TX_FREE.
pub fn transmit(frame: []const u8, payload_address: u64, options: TxOptions, output: []u8) ![]const u8 {
    if (frame.len < 24 or frame.len > 4095 or output.len < 64) return error.InvalidTxFrame;
    try dma.range32(payload_address, frame.len);
    if (options.token >= 0x8000 or options.wlan_index >= 20 or options.own_mac >= 4 or options.queue > 0x10 or options.fixed_rate >= 0x4000) return error.InvalidTxOptions;
    const fc = w.le16(frame);
    const frame_type: u32 = (fc >> 2) & 3;
    const subtype: u32 = (fc >> 4) & 15;
    if (fc & 3 != 0 or (frame_type != 0 and frame_type != 2) or fc & 0xc400 != 0 or frame_type == 2 and subtype & 8 != 0) return error.UnsupportedTxFrame;
    const ds = (fc >> 8) & 3;
    // One ToDS bit retains the standard 24-byte station->AP header. MediaTek
    // consumes the original FC/address fields from the separate DMA payload;
    // TXWI HDR_INFO is therefore still 12 halfwords, as in the ISC upstream
    // write_txwi_80211 path. FromDS/WDS transmission is outside this station port.
    if ((frame_type == 0 and ds != 0) or (frame_type == 2 and ds >= 2)) return error.UnsupportedTxFrame;
    const sequence = w.le16(frame[22..]);
    if (sequence & 15 != 0) return error.UnsupportedTxFrame;
    const multicast = frame[4] & 1 != 0;
    const out = output[0..64];
    @memset(out, 0);
    w.put32(out, @as(u32, @intCast(frame.len + 32)) | @as(u32, options.queue) << 25);
    w.put32(out[4..], (1 << 31) | @as(u32, options.wlan_index) | @as(u32, options.own_mac) << 24 | (2 << 16) | (12 << 11));
    w.put32(out[8..], (1 << 31) | (1 << 13) | frame_type << 4 | subtype | (if (multicast) @as(u32, 1 << 10) else 0));
    const count: u32 = if (frame_type == 0 and subtype == 8) 31 else 15;
    var d3: u32 = (count << 11) | (1 << 28) | (if (options.no_ack or multicast) @as(u32, 1) else 0);
    if (options.preserve_sequence) d3 |= (1 << 31) | @as(u32, sequence >> 4) << 16;
    w.put32(out[12..], d3);
    w.put32(out[24..], 4 | @as(u32, options.fixed_rate) << 16);
    w.put32(out[28..], frame_type << 20 | subtype << 16);
    w.put16(out[32..], options.token | 0x8000);
    w.put32(out[40..], @intCast(payload_address));
    w.put16(out[44..], @as(u16, @intCast(frame.len)) | 0x8000);
    return out;
}
pub const Free = struct { token: u16, status: u8, attempts: u16 };
pub const Freed = struct { count: usize = 0, entries: [32]Free = undefined };
/// Checked TX_FREE walker; pair words increase source length, never token count.
/// The caller resolves tokens in its live ownership ledger before any release.
pub fn transmitFree(input: []const u8) !Freed {
    const p = try packet(input);
    if (p.kind != .tx_free or p.bytes.len < 8) return error.WrongRxPacket;
    const b = p.bytes;
    const wanted = w.le16(b[2..]) & 0x3ff;
    if (wanted > 32) return error.TooManyTxCompletions;
    var result: Freed = .{};
    var offset: usize = 8;
    while (result.count < wanted) {
        const end = try advance(b.len, offset, 4);
        const info = w.le32(b[offset..]);
        offset = end;
        if (info & (1 << 31) != 0) continue;
        const token: u16 = @intCast((info >> 16) & 0x7fff);
        for (result.entries[0..result.count]) |e| if (e.token == token) return error.DuplicateTxCompletion;
        result.entries[result.count] = .{ .token = token, .status = @intCast((info >> 13) & 3), .attempts = @intCast(info & 0x1fff) };
        result.count += 1;
    }
    if (offset != b.len) return error.InvalidTxCompletionLength;
    return result;
}
