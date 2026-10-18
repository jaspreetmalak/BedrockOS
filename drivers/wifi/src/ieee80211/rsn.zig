//! Original bounded RSNE decoder; suite numbers are wire-format facts.
const std = @import("std");
const wifi = @import("networkkit").wifi;
pub const Error = error{ TruncatedRsn, InvalidRsn, SecurityContradiction };
pub const max_suites = 16;

const Cursor = struct {
    bytes: []const u8,
    at: usize = 0,
    fn take(self: *Cursor, count: usize) Error![]const u8 {
        if (count > self.bytes.len - self.at) return error.TruncatedRsn;
        const result = self.bytes[self.at..][0..count];
        self.at += count;
        return result;
    }
    fn integer(self: *Cursor) Error!u16 {
        return std.mem.readInt(u16, (try self.take(2))[0..2], .little);
    }
};
fn suite(bytes: []const u8, kind: u8) bool {
    return std.mem.eql(u8, bytes[0..3], &.{ 0, 0x0f, 0xac }) and bytes[3] == kind;
}

/// Body only (without IE ID/length). Missing/legacy fields are unsupported;
/// malformed lengths fail. Only CCMP-128 + PSK or SAE are classified personal.
/// Mixed PSK/SAE is classified WPA3 so callers never silently downgrade it.
pub fn classify(body: []const u8, privacy: bool) Error!wifi.Security {
    if (!privacy) return error.SecurityContradiction;
    if (body.len > 255) return error.InvalidRsn;
    var cursor: Cursor = .{ .bytes = body };
    if (try cursor.integer() != 1) return error.InvalidRsn;
    var supported = suite(try cursor.take(4), 4);
    const pairwise = try cursor.integer();
    if (pairwise == 0 or pairwise > max_suites) return error.InvalidRsn;
    for (0..pairwise) |_| if (!suite(try cursor.take(4), 4)) {
        supported = false;
    };
    const akms = try cursor.integer();
    if (akms == 0 or akms > max_suites) return error.InvalidRsn;
    var psk = false;
    var sae = false;
    for (0..akms) |_| {
        const value = try cursor.take(4);
        if (suite(value, 2)) psk = true else if (suite(value, 8)) sae = true else supported = false;
    }
    var capabilities: u16 = 0;
    if (cursor.at != body.len) capabilities = try cursor.integer();
    // MFPR requires MFPC. Unsupported preauthentication/key-index semantics
    // are never used to turn a protected network into an open network.
    if (capabilities & (1 << 6) != 0 and capabilities & (1 << 7) == 0) return error.InvalidRsn;
    if (capabilities & 0xff02 != 0) supported = false; // No pairwise or unsupported extended capabilities.
    if (cursor.at != body.len) {
        const pmkids = try cursor.integer();
        if (pmkids > 16) return error.InvalidRsn;
        _ = try cursor.take(@as(usize, pmkids) * 16);
    }
    if (cursor.at != body.len) {
        // BIP-CMAC-128 is the sole recognized group-management cipher.
        if (!suite(try cursor.take(4), 6)) supported = false;
        if (capabilities & (1 << 7) == 0) return error.InvalidRsn;
    }
    if (cursor.at != body.len) return error.InvalidRsn;
    if (!supported) return .unsupported;
    if (sae) return if (capabilities & (1 << 7) != 0) .wpa3_personal else .unsupported;
    // This WPA2 helper has no protected-management-frame implementation.
    if (psk and capabilities & (1 << 6) == 0) return .wpa2_personal;
    return .unsupported;
}
