//! WPA2-PSK/CCMP primitives, implemented from the specified byte layout using
//! the installed Zig standard-library HMAC-SHA1/PBKDF2 implementations.
const std = @import("std");
const Hmac = std.crypto.auth.hmac.HmacSha1;
pub const Error = error{ InvalidPassphrase, InvalidSsid, InvalidPeer, InvalidNonce, OutputTooLong, BufferOverlap };
pub const pmk_length = 32;
pub const ptk_length = 48; // CCMP: KCK16 + KEK16 + TK16. Not TKIP's 64 bytes.
pub fn clear(bytes: []u8) void {
    const output: [*]volatile u8 = bytes.ptr;
    for (0..bytes.len) |index| output[index] = 0;
}
fn clearObject(pointer: anytype) void {
    clear(std.mem.asBytes(pointer));
}
fn independent(output: []u8, input: []const u8) Error!void {
    if (output.len == 0 or input.len == 0) return;
    const start = @intFromPtr(output.ptr);
    const other = @intFromPtr(input.ptr);
    const end = @addWithOverflow(start, output.len);
    const limit = @addWithOverflow(other, input.len);
    if (end[1] != 0 or limit[1] != 0 or (start < limit[0] and other < end[0])) return error.BufferOverlap;
}

pub fn hmacSha1(key: []const u8, message: []const u8, output: *[20]u8) void {
    var context = Hmac.init(key);
    defer clearObject(&context);
    context.update(message);
    context.final(output);
}
/// Borrowed passphrase/SSID; caller owns their lifetime and wiping. Only the
/// resulting PMK is returned. Printable 8..63-byte personal passphrases only.
pub fn derivePmk(passphrase: []const u8, ssid: []const u8, output: *[32]u8) Error!void {
    if (passphrase.len < 8 or passphrase.len > 63) return error.InvalidPassphrase;
    for (passphrase) |byte| if (byte < 0x20 or byte > 0x7e) return error.InvalidPassphrase;
    if (ssid.len == 0 or ssid.len > 32) return error.InvalidSsid;
    try independent(output, passphrase);
    try independent(output, ssid);
    std.crypto.pwhash.pbkdf2(output, passphrase, ssid, 4096, Hmac) catch unreachable;
}

/// IEEE SHA1 PRF: label || NUL || data || one-byte counter, starting at zero.
/// A bounded caller-provided output prevents counter wrap; no heap is used.
pub fn prfSha1(key: []const u8, label: []const u8, data: []const u8, output: []u8) Error!void {
    if (output.len > 256 * 20) return error.OutputTooLong;
    try independent(output, key);
    try independent(output, label);
    try independent(output, data);
    var digest: [20]u8 = undefined;
    defer clear(&digest);
    var at: usize = 0;
    var counter: u16 = 0;
    while (at < output.len) : (counter += 1) {
        var context = Hmac.init(key);
        defer clearObject(&context);
        context.update(label);
        context.update(&.{0});
        context.update(data);
        context.update(&.{@intCast(counter)});
        context.final(&digest);
        const count = @min(output.len - at, digest.len);
        @memcpy(output[at..][0..count], digest[0..count]);
        at += count;
    }
}
fn peerValid(mac: [6]u8) bool {
    return mac[0] & 1 == 0 and !std.mem.allEqual(u8, &mac, 0);
}
/// PSK + CCMP-128 only. Driver must supply fresh cryptographically random
/// SNonce and verify the AP's ANonce; this helper does not generate randomness.
pub fn derivePtk(pmk: *const [32]u8, ap: [6]u8, station: [6]u8, anonce: [32]u8, snonce: [32]u8, output: *[48]u8) Error!void {
    if (!peerValid(ap) or !peerValid(station) or std.mem.eql(u8, &ap, &station)) return error.InvalidPeer;
    if (std.mem.allEqual(u8, &anonce, 0) or std.mem.allEqual(u8, &snonce, 0) or std.mem.eql(u8, &anonce, &snonce)) return error.InvalidNonce;
    var data: [76]u8 = undefined;
    defer clear(&data);
    const ap_first = std.mem.order(u8, &ap, &station) == .lt;
    @memcpy(data[0..6], if (ap_first) &ap else &station);
    @memcpy(data[6..12], if (ap_first) &station else &ap);
    const a_first = std.mem.order(u8, &anonce, &snonce) == .lt;
    @memcpy(data[12..44], if (a_first) &anonce else &snonce);
    @memcpy(data[44..76], if (a_first) &snonce else &anonce);
    try prfSha1(pmk, "Pairwise key expansion", &data, output);
}
