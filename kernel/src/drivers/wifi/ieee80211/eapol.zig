//! RSN EAPOL-Key descriptor-v2 (HMAC-SHA1-128/CCMP) validation. Input starts
//! with the EAPOL version and excludes Ethernet/LLC headers and any padding.
const std = @import("std");
const wpa2 = @import("wpa2.zig");
const Hmac = std.crypto.auth.hmac.HmacSha1;
pub const max_frame_bytes = 2048;
pub const mic_offset = 81;
pub const fixed_length = 99;
pub const Error = error{ TruncatedKey, InvalidKey, UnsupportedKey, InvalidMic, ReplayDetected, UnauthenticatedKey, ReplayCounterExhausted, NonceMismatch, ExchangeComplete, BufferOverlap };
pub const Message = enum { message1, message2, message3, message4 };
pub const Key = struct {
    wire: []const u8,
    information: u16,
    replay_counter: u64,
    nonce: [32]u8,
    mic: [16]u8,
    data: []const u8,
    pub fn hasMic(self: Key) bool {
        return self.information & 0x100 != 0;
    }
    pub fn message(self: Key) Error!Message {
        if (self.information != 0x13ca and !std.mem.allEqual(u8, self.wire[65..73], 0)) return error.InvalidKey;
        return switch (self.information) {
            0x008a => if (!self.hasMic() and !std.mem.allEqual(u8, &self.nonce, 0)) .message1 else error.InvalidKey,
            0x010a => if (!std.mem.allEqual(u8, &self.nonce, 0)) .message2 else error.InvalidKey,
            0x13ca => if (!std.mem.allEqual(u8, &self.nonce, 0) and self.data.len >= 24 and self.data.len % 8 == 0) .message3 else error.InvalidKey,
            0x030a => if (std.mem.allEqual(u8, &self.nonce, 0) and self.data.len == 0) .message4 else error.InvalidKey,
            else => error.UnsupportedKey,
        };
    }
};
pub fn parse(bytes: []const u8) Error!Key {
    if (bytes.len < fixed_length) return error.TruncatedKey;
    if (bytes.len > max_frame_bytes or bytes[0] < 1 or bytes[0] > 3 or bytes[1] != 3) return error.UnsupportedKey;
    const length = std.mem.readInt(u16, bytes[2..4], .big);
    if (@as(usize, length) != bytes.len - 4) return error.InvalidKey;
    if (bytes[4] != 2) return error.UnsupportedKey;
    const information = std.mem.readInt(u16, bytes[5..7], .big);
    // RSN pairwise descriptor v2 only. Reject key index, errors, requests,
    // SMK and reserved flags rather than interpreting them as handshake proof.
    if (information & 7 != 2 or information & 8 == 0 or information & 0xec30 != 0) return error.UnsupportedKey;
    // AP M1/M3 carry the CCMP key length; RSN station M2/M4 reserve it as zero.
    const expected_key_length: u16 = if (information & 0x80 != 0) 16 else 0;
    if (std.mem.readInt(u16, bytes[7..9], .big) != expected_key_length or !std.mem.allEqual(u8, bytes[49..65], 0) or !std.mem.allEqual(u8, bytes[73..81], 0)) return error.InvalidKey;
    const data_length = std.mem.readInt(u16, bytes[97..99], .big);
    if (@as(usize, data_length) != bytes.len - fixed_length) return error.InvalidKey;
    var key: Key = .{ .wire = bytes, .information = information, .replay_counter = std.mem.readInt(u64, bytes[9..17], .big), .nonce = bytes[17..49].*, .mic = bytes[81..97].*, .data = bytes[99..] };
    if (!key.hasMic() and !std.mem.allEqual(u8, &key.mic, 0)) return error.InvalidKey;
    _ = try key.message();
    return key;
}
/// The caller owns and wipes KCK. Hash the exact EAPOL frame, replacing only
/// the 16 wire MIC bytes with zeros. The source buffer is never modified.
pub fn calculateMic(bytes: []const u8, kck: *const [16]u8, output: *[16]u8) Error!void {
    const key = try parse(bytes);
    if (!key.hasMic()) return error.UnauthenticatedKey;
    const destination = @intFromPtr(output);
    const destination_end = @addWithOverflow(destination, 16);
    for ([_][]const u8{ bytes, kck }) |source| {
        const base = @intFromPtr(source.ptr);
        const end = @addWithOverflow(base, source.len);
        if (destination_end[1] != 0 or end[1] != 0 or (destination < end[0] and base < destination_end[0])) return error.BufferOverlap;
    }
    var context = Hmac.init(kck);
    defer wpa2.clear(std.mem.asBytes(&context));
    var digest: [20]u8 = undefined;
    defer wpa2.clear(&digest);
    context.update(bytes[0..mic_offset]);
    context.update(&@as([16]u8, @splat(0)));
    context.update(bytes[mic_offset + 16 ..]);
    context.final(&digest);
    output.* = digest[0..16].*;
}
pub fn verifyMic(bytes: []const u8, kck: *const [16]u8) Error!void {
    const key = try parse(bytes);
    var expected: [16]u8 = undefined;
    defer wpa2.clear(&expected);
    try calculateMic(bytes, kck, &expected);
    if (!std.crypto.timing_safe.eql([16]u8, expected, key.mic)) return error.InvalidMic;
}

/// Per association/AP receive direction. Replays/retransmissions fail closed;
/// this helper deliberately does not reinstall keys or implement retransmits.
/// The association owner must reset only when starting a new pinned exchange.
pub const ReplayGuard = struct {
    last: ?u64 = null,
    anonce: ?[32]u8 = null,
    complete: bool = false,
    fn check(self: *const ReplayGuard, counter: u64) Error!void {
        if (self.last) |value| {
            if (value == std.math.maxInt(u64)) return error.ReplayCounterExhausted;
            if (counter <= value) return error.ReplayDetected;
        }
    }
    /// First unauthenticated M1 only. No authenticity/connection claim follows.
    pub fn acceptInitial(self: *ReplayGuard, bytes: []const u8) Error!Key {
        if (self.last != null) return error.ReplayDetected;
        const key = try parse(bytes);
        if (try key.message() != .message1) return error.InvalidKey;
        self.last = key.replay_counter;
        self.anonce = key.nonce;
        return key;
    }
    /// Strictly newer authenticated M3. Bad MIC/shape/counter never mutates the
    /// ledger. This proves a MIC only, not GTK unwrap or driver installation.
    pub fn acceptAuthenticated(self: *ReplayGuard, bytes: []const u8, kck: *const [16]u8) Error!Key {
        if (self.complete) return error.ExchangeComplete;
        const key = try parse(bytes);
        if (try key.message() != .message3 or self.last == null) return error.InvalidKey;
        try self.check(key.replay_counter);
        if (self.anonce == null or !std.mem.eql(u8, &key.nonce, &self.anonce.?)) return error.NonceMismatch;
        try verifyMic(bytes, kck);
        self.last = key.replay_counter;
        self.complete = true;
        return key;
    }
};
