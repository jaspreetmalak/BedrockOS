//! Original RFC 3394 AES-128 key wrap. WPA2 KEK is 16 bytes. Integrity is
//! checked before publishing plaintext; no alternate IV or RFC 5649 padding.
const std = @import("std");
const secrets = @import("wpa2.zig");
const Aes = std.crypto.core.aes.Aes128;
comptime {
    if (std.options.side_channels_mitigations == .none) @compileError("WPA2 key wrap requires Zig AES side-channel mitigations");
}
pub const max_plaintext = 512;
pub const Error = error{ InvalidLength, BufferTooSmall, BufferOverlap, IntegrityFailure };
fn separate(output: []u8, input: []const u8) Error!void {
    if (input.len == 0 or output.len == 0) return;
    const a = @intFromPtr(output.ptr);
    const b = @intFromPtr(input.ptr);
    const end_a = @addWithOverflow(a, output.len);
    const end_b = @addWithOverflow(b, input.len);
    if (end_a[1] != 0 or end_b[1] != 0 or (a < end_b[0] and b < end_a[0])) return error.BufferOverlap;
}
pub fn unwrap(kek: *const [16]u8, ciphertext: []const u8, output: []u8) Error!usize {
    if (ciphertext.len < 24 or ciphertext.len > max_plaintext + 8 or ciphertext.len % 8 != 0) return error.InvalidLength;
    const length = ciphertext.len - 8;
    if (output.len < length) return error.BufferTooSmall;
    try separate(output, ciphertext);
    try separate(output, kek);
    var plaintext: [max_plaintext]u8 = undefined;
    defer secrets.clear(&plaintext);
    @memcpy(plaintext[0..length], ciphertext[8..]);
    var context = Aes.initDec(kek.*);
    defer secrets.clear(std.mem.asBytes(&context));
    var block: [16]u8 = undefined;
    defer secrets.clear(&block);
    var decrypted: [16]u8 = undefined;
    defer secrets.clear(&decrypted);
    var a = std.mem.readInt(u64, ciphertext[0..8], .big);
    const n = length / 8;
    var j: usize = 6;
    while (j != 0) {
        j -= 1;
        var i = n;
        while (i != 0) : (i -= 1) {
            std.mem.writeInt(u64, block[0..8], a ^ @as(u64, @intCast(n * j + i)), .big);
            @memcpy(block[8..16], plaintext[(i - 1) * 8 ..][0..8]);
            context.decrypt(&decrypted, &block);
            a = std.mem.readInt(u64, decrypted[0..8], .big);
            @memcpy(plaintext[(i - 1) * 8 ..][0..8], decrypted[8..16]);
        }
    }
    var integrity: [8]u8 = undefined;
    defer secrets.clear(&integrity);
    std.mem.writeInt(u64, &integrity, a, .big);
    if (!std.crypto.timing_safe.eql([8]u8, integrity, @splat(0xa6))) return error.IntegrityFailure;
    @memcpy(output[0..length], plaintext[0..length]);
    return length;
}
/// Included for bounded outgoing protocol use and independent published vectors.
pub fn wrap(kek: *const [16]u8, plaintext: []const u8, output: []u8) Error!usize {
    if (plaintext.len < 16 or plaintext.len > max_plaintext or plaintext.len % 8 != 0) return error.InvalidLength;
    if (output.len < plaintext.len + 8) return error.BufferTooSmall;
    try separate(output, plaintext);
    try separate(output, kek);
    var scratch: [max_plaintext]u8 = undefined;
    defer secrets.clear(&scratch);
    @memcpy(scratch[0..plaintext.len], plaintext);
    var context = Aes.initEnc(kek.*);
    defer secrets.clear(std.mem.asBytes(&context));
    var block: [16]u8 = undefined;
    defer secrets.clear(&block);
    var encrypted: [16]u8 = undefined;
    defer secrets.clear(&encrypted);
    var a: u64 = 0xa6a6_a6a6_a6a6_a6a6;
    const n = plaintext.len / 8;
    for (0..6) |j| for (1..n + 1) |i| {
        std.mem.writeInt(u64, block[0..8], a, .big);
        @memcpy(block[8..16], scratch[(i - 1) * 8 ..][0..8]);
        context.encrypt(&encrypted, &block);
        a = std.mem.readInt(u64, encrypted[0..8], .big) ^ @as(u64, @intCast(n * j + i));
        @memcpy(scratch[(i - 1) * 8 ..][0..8], encrypted[8..16]);
    };
    std.mem.writeInt(u64, output[0..8], a, .big);
    @memcpy(output[8..][0..plaintext.len], scratch[0..plaintext.len]);
    return plaintext.len + 8;
}
