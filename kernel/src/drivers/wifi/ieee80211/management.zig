//! Strict Beacon/Probe Response decoding. Input begins at frame control and
//! excludes radiotap/hardware metadata and FCS; the driver supplies channel/RSSI.
const std = @import("std");
const wifi = @import("networkkit").wifi;
const rsn = @import("rsn.zig");
pub const max_frame_bytes = 4096;
pub const max_information_elements = 256;
pub const Error = rsn.Error || error{ TruncatedFrame, InvalidFrame, UnsupportedFrame, TooManyElements, DuplicateElement, InvalidElement, MissingSsid, MissingChannel, ChannelContradiction, InvalidBss };
fn le16(bytes: []const u8) u16 {
    return std.mem.readInt(u16, bytes[0..2], .little);
}
fn macValid(bytes: []const u8) bool {
    return bytes[0] & 1 == 0 and !std.mem.allEqual(u8, bytes, 0);
}
fn selectChannel(selected: *?u16, candidate: u16) Error!void {
    if (candidate == 0 or candidate > 233) return error.InvalidElement;
    if (selected.*) |prior| {
        if (prior != candidate) return error.ChannelContradiction;
    } else selected.* = candidate;
}

pub fn parse(frame: []const u8, receive_channel: ?u16, signal_dbm: i16) Error!wifi.Bss {
    if (frame.len < 36) return error.TruncatedFrame;
    if (frame.len > max_frame_bytes) return error.InvalidFrame;
    const control = le16(frame);
    // PV0 management Beacon(8)/Probe Response(5), no DS, fragmentation,
    // protection or HT-control extension. Retry/power/more-data are harmless.
    if (control & 0x000f != 0 or (control & 0x00f0 != 0x0080 and control & 0x00f0 != 0x0050)) return error.UnsupportedFrame;
    if (control & 0xc700 != 0 or le16(frame[22..]) & 0x000f != 0) return error.UnsupportedFrame;
    const source = frame[10..16];
    const bssid = frame[16..22];
    if (!macValid(source) or !std.mem.eql(u8, source, bssid)) return error.InvalidFrame;
    if (control & 0x00f0 == 0x0080 and !std.mem.allEqual(u8, frame[4..10], 0xff)) return error.InvalidFrame;
    if (!std.mem.allEqual(u8, frame[4..10], 0xff) and !macValid(frame[4..10])) return error.InvalidFrame;
    const capabilities = le16(frame[34..]);
    if (capabilities & 3 != 1 or le16(frame[32..]) == 0) return error.UnsupportedFrame; // Infrastructure ESS only.
    const privacy = capabilities & 0x10 != 0;
    var ssid: ?wifi.Ssid = null;
    var channel: ?u16 = null;
    var rsne: ?[]const u8 = null;
    var legacy_security = false;
    var extended_security = false;
    var dsss_seen = false;
    var ht_seen = false;
    var count: usize = 0;
    var at: usize = 36;
    while (at < frame.len) {
        if (frame.len - at < 2) return error.TruncatedFrame;
        count += 1;
        if (count > max_information_elements) return error.TooManyElements;
        const id = frame[at];
        const length: usize = frame[at + 1];
        at += 2;
        if (length > frame.len - at) return error.TruncatedFrame;
        const body = frame[at..][0..length];
        at += length;
        switch (id) {
            0 => {
                if (ssid != null) return error.DuplicateElement;
                if (length > 32) return error.InvalidElement;
                var result: wifi.Ssid = .{};
                // All-zero SSIDs are a common hidden-network representation.
                if (!std.mem.allEqual(u8, body, 0)) {
                    result.len = @intCast(length);
                    @memcpy(result.bytes[0..length], body);
                }
                ssid = result;
            },
            3 => {
                if (dsss_seen) return error.DuplicateElement;
                dsss_seen = true;
                if (length != 1) return error.InvalidElement;
                try selectChannel(&channel, body[0]);
            },
            61 => {
                if (ht_seen) return error.DuplicateElement;
                ht_seen = true;
                if (length != 22) return error.InvalidElement;
                try selectChannel(&channel, body[0]);
            },
            48 => {
                if (rsne != null) return error.DuplicateElement;
                rsne = body;
            },
            221 => {
                if (length >= 4 and std.mem.eql(u8, body[0..4], &.{ 0, 0x50, 0xf2, 1 })) legacy_security = true;
            },
            244 => {
                if (extended_security) return error.DuplicateElement;
                if (length == 0 or @as(usize, body[0] & 15) + 1 != length) return error.InvalidElement;
                extended_security = true;
            },
            else => {},
        }
    }
    if (receive_channel) |value| try selectChannel(&channel, value);
    if (extended_security and (rsne == null or !privacy)) return error.SecurityContradiction;
    const security: wifi.Security = if (rsne) |body| try rsn.classify(body, privacy) else if (privacy or legacy_security) .unsupported else .open;
    const result: wifi.Bss = .{ .ssid = ssid orelse return error.MissingSsid, .bssid = bssid[0..6].*, .channel = channel orelse return error.MissingChannel, .signal_dbm = signal_dbm, .security = if (legacy_security or extended_security) .unsupported else security };
    result.validate() catch return error.InvalidBss;
    return result;
}
