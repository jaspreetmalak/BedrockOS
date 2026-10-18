const std = @import("std");
const t = std.testing;
const management = @import("management.zig");
const rsn = @import("rsn.zig");
const wpa2 = @import("wpa2.zig");
const eapol = @import("eapol.zig");
const Mac = [6]u8;
const ap: Mac = .{ 2, 0x10, 0x20, 0x30, 0x40, 0x50 };
const rsn_psk = [_]u8{ 1, 0, 0, 15, 172, 4, 1, 0, 0, 15, 172, 4, 1, 0, 0, 15, 172, 2, 0, 0 };
const Frame = struct {
    bytes: [4096]u8 = @splat(0),
    len: usize = 36,
    fn init(privacy: bool, probe: bool) Frame {
        var value: Frame = .{};
        value.bytes[0] = if (probe) 0x50 else 0x80;
        @memset(value.bytes[4..10], 0xff);
        @memcpy(value.bytes[10..16], &ap);
        @memcpy(value.bytes[16..22], &ap);
        value.bytes[32] = 100;
        value.bytes[34] = if (privacy) 0x11 else 1;
        return value;
    }
    fn ie(self: *Frame, id: u8, body: []const u8) void {
        self.bytes[self.len] = id;
        self.bytes[self.len + 1] = @intCast(body.len);
        @memcpy(self.bytes[self.len + 2 ..][0..body.len], body);
        self.len += 2 + body.len;
    }
    fn slice(self: *const Frame) []const u8 {
        return self.bytes[0..self.len];
    }
};
fn discovery(privacy: bool) Frame {
    var frame = Frame.init(privacy, false);
    frame.ie(0, "Bedrock");
    frame.ie(3, &.{6});
    return frame;
}
fn hex(comptime length: usize, value: *const [length * 2:0]u8) [length]u8 {
    var result: [length]u8 = undefined;
    _ = std.fmt.hexToBytes(&result, value) catch unreachable;
    return result;
}

test "beacon and probe response decode binary hidden and received channel" {
    var frame = discovery(false);
    var bss = try management.parse(frame.slice(), 6, -42);
    try t.expectEqual(.open, bss.security);
    try t.expectEqualSlices(u8, "Bedrock", try bss.ssid.slice());
    try t.expectEqual(ap, bss.bssid);
    try t.expectEqual(@as(u16, 6), bss.channel);
    frame = Frame.init(false, true);
    frame.ie(0, &.{ 'A', 0, 0xff });
    bss = try management.parse(frame.slice(), 11, -70);
    try t.expectEqualSlices(u8, &.{ 'A', 0, 0xff }, try bss.ssid.slice());
    frame = Frame.init(false, false);
    frame.ie(0, &.{ 0, 0, 0 });
    frame.ie(3, &.{1});
    bss = try management.parse(frame.slice(), null, -80);
    try t.expectEqual(@as(u8, 0), bss.ssid.len);
    frame = Frame.init(false, false);
    frame.ie(0, &.{});
    frame.ie(3, &.{1});
    bss = try management.parse(frame.slice(), null, -80);
    try t.expectEqual(@as(u8, 0), bss.ssid.len);
}
test "management header rejects foreign source fragments and invalid metadata" {
    var frame = discovery(false);
    for (0..36) |cut| try t.expectError(error.TruncatedFrame, management.parse(frame.slice()[0..cut], 6, -42));
    frame.bytes[10] = 4;
    try t.expectError(error.InvalidFrame, management.parse(frame.slice(), 6, -42));
    frame = discovery(false);
    frame.bytes[1] = 0x40;
    try t.expectError(error.UnsupportedFrame, management.parse(frame.slice(), 6, -42));
    frame.bytes[1] = 4;
    try t.expectError(error.UnsupportedFrame, management.parse(frame.slice(), 6, -42));
    frame.bytes[1] = 0;
    frame.bytes[22] = 1;
    try t.expectError(error.UnsupportedFrame, management.parse(frame.slice(), 6, -42));
    frame.bytes[22] = 0;
    try t.expectError(error.InvalidBss, management.parse(frame.slice(), 6, 1));
    frame.bytes[4] = 0;
    try t.expectError(error.InvalidFrame, management.parse(frame.slice(), 6, -42));
}
test "IE bounds duplicates and channel contradictions fail closed" {
    var frame = discovery(false);
    frame.ie(0, "other");
    try t.expectError(error.DuplicateElement, management.parse(frame.slice(), 6, -42));
    frame = discovery(false);
    frame.ie(48, &rsn_psk);
    try t.expectError(error.SecurityContradiction, management.parse(frame.slice(), 6, -42));
    frame = discovery(true);
    frame.ie(48, &rsn_psk);
    frame.ie(48, &rsn_psk);
    try t.expectError(error.DuplicateElement, management.parse(frame.slice(), 6, -42));
    frame = discovery(false);
    try t.expectError(error.ChannelContradiction, management.parse(frame.slice(), 11, -42));
    var ht: [22]u8 = @splat(0);
    ht[0] = 11;
    frame.ie(61, &ht);
    try t.expectError(error.ChannelContradiction, management.parse(frame.slice(), null, -42));
    frame = discovery(false);
    frame.ie(99, &.{ 1, 2, 3 });
    try t.expectError(error.TruncatedFrame, management.parse(frame.slice()[0 .. frame.len - 1], 6, -42));
    frame = discovery(false);
    for (0..255) |_| frame.ie(99, &.{});
    try t.expectError(error.TooManyElements, management.parse(frame.slice(), 6, -42));
}
test "protected legacy and unknown suites cannot become open" {
    var frame = discovery(true);
    try t.expectEqual(.unsupported, (try management.parse(frame.slice(), 6, -42)).security);
    frame.ie(48, &rsn_psk);
    try t.expectEqual(.wpa2_personal, (try management.parse(frame.slice(), 6, -42)).security);
    frame.ie(221, &.{ 0, 0x50, 0xf2, 1 });
    try t.expectEqual(.unsupported, (try management.parse(frame.slice(), 6, -42)).security);
    frame = discovery(false);
    frame.ie(221, &.{ 0, 0x50, 0xf2, 1 });
    try t.expectEqual(.unsupported, (try management.parse(frame.slice(), 6, -42)).security);
    frame = discovery(false);
    frame.ie(244, &.{0});
    try t.expectError(error.SecurityContradiction, management.parse(frame.slice(), 6, -42));
    frame = discovery(true);
    frame.ie(48, &rsn_psk);
    frame.ie(244, &.{0});
    try t.expectEqual(.unsupported, (try management.parse(frame.slice(), 6, -42)).security);
    var body = rsn_psk;
    body[17] = 1;
    try t.expectEqual(.unsupported, try rsn.classify(&body, true));
    body = rsn_psk;
    body[5] = 2;
    try t.expectEqual(.unsupported, try rsn.classify(&body, true));
}
test "RSN optional fields SAE transition and malformed lengths are bounded" {
    for (0..18) |cut| try t.expectError(error.TruncatedRsn, rsn.classify(rsn_psk[0..cut], true));
    try t.expectEqual(.wpa2_personal, try rsn.classify(rsn_psk[0..18], true));
    var body = rsn_psk;
    body[17] = 8;
    body[18] = 0xc0;
    try t.expectEqual(.wpa3_personal, try rsn.classify(&body, true));
    body[18] = 0;
    try t.expectEqual(.unsupported, try rsn.classify(&body, true));
    body[18] = 0x40;
    try t.expectError(error.InvalidRsn, rsn.classify(&body, true));
    var mixed: [24]u8 = @splat(0);
    @memcpy(mixed[0..18], rsn_psk[0..18]);
    mixed[12] = 2;
    @memcpy(mixed[18..22], &@as([4]u8, .{ 0, 15, 172, 8 }));
    mixed[22] = 0x80;
    try t.expectEqual(.wpa3_personal, try rsn.classify(&mixed, true));
    var optional: [26]u8 = @splat(0);
    @memcpy(optional[0..20], &rsn_psk);
    optional[18] = 0x80;
    @memcpy(optional[22..26], &@as([4]u8, .{ 0, 15, 172, 6 }));
    try t.expectEqual(.wpa2_personal, try rsn.classify(&optional, true));
    optional[20] = 17;
    try t.expectError(error.InvalidRsn, rsn.classify(&optional, true));
    body = rsn_psk;
    body[6] = 17;
    try t.expectError(error.InvalidRsn, rsn.classify(&body, true));
}
test "HMAC SHA1 matches independently published RFC2202 vector" {
    var output: [20]u8 = undefined;
    wpa2.hmacSha1(&@as([20]u8, @splat(0x0b)), "Hi There", &output);
    try t.expectEqual(hex(20, "b617318655057264e28bc0b6fb378c8ef146be00"), output);
}
test "PMK matches pinned hostap password IEEE and RFC6070 prefix" {
    var output: [32]u8 = undefined;
    try wpa2.derivePmk("password", "IEEE", &output);
    try t.expectEqual(hex(32, "f42c6fc52df0ebef9ebb4b90b38a5f902e83fe1b135a70e23aed762e9710a12e"), output);
    try wpa2.derivePmk("ThisIsAPassword", "ThisIsASSID", &output);
    try t.expectEqual(hex(32, "0dc0d6eb90555ed6419756b9a15ec3e3209b63df707dd508d14581f8982721af"), output);
    try wpa2.derivePmk("password", "salt", &output);
    try t.expectEqualSlices(u8, &hex(20, "4b007901b765489abead49d926f721d065a429c1"), output[0..20]);
    output = @splat(0xa5);
    try t.expectError(error.InvalidPassphrase, wpa2.derivePmk("short", "IEEE", &output));
    try t.expect(std.mem.allEqual(u8, &output, 0xa5));
    try t.expectError(error.InvalidSsid, wpa2.derivePmk("password", "", &output));
    output = @splat('a');
    try t.expectError(error.BufferOverlap, wpa2.derivePmk(output[0..8], "IEEE", &output));
    try t.expect(std.mem.allEqual(u8, &output, 'a'));
}
test "PRF matches pinned published hostap vector and rejects counter wrap" {
    var output: [64]u8 = undefined;
    try wpa2.prfSha1(&@as([20]u8, @splat(0x0b)), "prefix", "Hi There", &output);
    try t.expectEqual(hex(64, "bcd4c650b30b9684951829e0d75f9d54b862175ed9f00606e17d8da35402ffee75df78c3d31e0f889f012120c0862beb67753e7439ae242edb8373698356cf5a"), output);
    var too_long: [5121]u8 = @splat(0xa5);
    try t.expectError(error.OutputTooLong, wpa2.prfSha1("key", "label", "data", &too_long));
    try t.expect(std.mem.allEqual(u8, &too_long, 0xa5));
    output = @splat(0xa5);
    try t.expectError(error.BufferOverlap, wpa2.prfSha1(output[0..16], "prefix", "data", &output));
    try t.expect(std.mem.allEqual(u8, &output, 0xa5));
}
test "CCMP PTK ordering is symmetric and invalid peers never modify output" {
    const station: Mac = .{ 2, 0x90, 1, 2, 3, 4 };
    const pmk: [32]u8 = @splat(0x11);
    const anonce: [32]u8 = @splat(0x22);
    const snonce: [32]u8 = @splat(0x33);
    var a: [48]u8 = undefined;
    var b: [48]u8 = undefined;
    try wpa2.derivePtk(&pmk, ap, station, anonce, snonce, &a);
    try wpa2.derivePtk(&pmk, station, ap, snonce, anonce, &b);
    try t.expectEqual(a, b);
    b = @splat(0xa5);
    try t.expectError(error.InvalidPeer, wpa2.derivePtk(&pmk, ap, ap, anonce, snonce, &b));
    try t.expectError(error.InvalidNonce, wpa2.derivePtk(&pmk, ap, station, anonce, anonce, &b));
    try t.expect(std.mem.allEqual(u8, &b, 0xa5));
    wpa2.clear(&a);
    try t.expect(std.mem.allEqual(u8, &a, 0));
}

fn keyFrame(information: u16, counter: u64) [123]u8 {
    var bytes: [123]u8 = @splat(0);
    bytes[0] = 2;
    bytes[1] = 3;
    std.mem.writeInt(u16, bytes[2..4], 119, .big);
    bytes[4] = 2;
    std.mem.writeInt(u16, bytes[5..7], information, .big);
    std.mem.writeInt(u16, bytes[7..9], 16, .big);
    std.mem.writeInt(u64, bytes[9..17], counter, .big);
    @memset(bytes[17..49], 0x44);
    std.mem.writeInt(u16, bytes[97..99], 24, .big);
    @memset(bytes[99..], 0x55);
    return bytes;
}
fn firstFrame(counter: u64) [99]u8 {
    const bytes = keyFrame(0x8a, counter);
    var first = bytes[0..99].*;
    std.mem.writeInt(u16, first[2..4], 95, .big);
    std.mem.writeInt(u16, first[97..99], 0, .big);
    return first;
}
fn sign(bytes: []u8, kck: *const [16]u8) !void {
    var mic: [16]u8 = undefined;
    try eapol.calculateMic(bytes, kck, &mic);
    @memcpy(bytes[81..97], &mic);
}
test "EAPOL descriptor sizes versions lengths flags and MIC presence are strict" {
    const first = firstFrame(0);
    const key = try eapol.parse(&first);
    try t.expectEqual(.message1, try key.message());
    for (0..99) |cut| try t.expectError(error.TruncatedKey, eapol.parse(first[0..cut]));
    var bad = first;
    bad[4] = 254;
    try t.expectError(error.UnsupportedKey, eapol.parse(&bad));
    bad = first;
    bad[6] |= 1;
    try t.expectError(error.UnsupportedKey, eapol.parse(&bad));
    bad = first;
    bad[2] = 1;
    try t.expectError(error.InvalidKey, eapol.parse(&bad));
    bad = first;
    bad[81] = 1;
    try t.expectError(error.InvalidKey, eapol.parse(&bad));
    bad = first;
    bad[65] = 1;
    try t.expectError(error.InvalidKey, eapol.parse(&bad));
    var third = keyFrame(0x13ca, 1);
    third[98] = 23;
    try t.expectError(error.InvalidKey, eapol.parse(&third));
    var second = keyFrame(0x010a, 1);
    try t.expectError(error.InvalidKey, eapol.parse(&second));
    std.mem.writeInt(u16, second[7..9], 0, .big);
    try t.expectEqual(.message2, try (try eapol.parse(&second)).message());
    var fourth = first;
    std.mem.writeInt(u16, fourth[5..7], 0x030a, .big);
    std.mem.writeInt(u16, fourth[7..9], 0, .big);
    @memset(fourth[17..49], 0);
    try t.expectEqual(.message4, try (try eapol.parse(&fourth)).message());
}
test "EAPOL MIC preserves source and rejects changed data key and MIC" {
    const kck: [16]u8 = @splat(0x77);
    var third = keyFrame(0x13ca, 2);
    try sign(&third, &kck);
    const before = third;
    try eapol.verifyMic(&third, &kck);
    try t.expectEqual(before, third);
    const alias: *[16]u8 = @ptrCast(&third[81]);
    try t.expectError(error.BufferOverlap, eapol.calculateMic(&third, &kck, alias));
    try t.expectEqual(before, third);
    third[122] ^= 1;
    try t.expectError(error.InvalidMic, eapol.verifyMic(&third, &kck));
    third = before;
    third[81] ^= 1;
    try t.expectError(error.InvalidMic, eapol.verifyMic(&third, &kck));
    try t.expectError(error.InvalidMic, eapol.verifyMic(&before, &@as([16]u8, @splat(0x76))));
    try t.expectError(error.UnauthenticatedKey, eapol.verifyMic(&firstFrame(1), &kck));
}
test "replay ledger commits only valid new pinned exchange once" {
    const kck: [16]u8 = @splat(0x77);
    var guard: eapol.ReplayGuard = .{};
    const first = firstFrame(10);
    _ = try guard.acceptInitial(&first);
    try t.expectError(error.ReplayDetected, guard.acceptInitial(&first));
    var third = keyFrame(0x13ca, 10);
    try sign(&third, &kck);
    try t.expectError(error.ReplayDetected, guard.acceptAuthenticated(&third, &kck));
    third = keyFrame(0x13ca, 11);
    try t.expectError(error.InvalidMic, guard.acceptAuthenticated(&third, &kck));
    try t.expectEqual(@as(?u64, 10), guard.last);
    third[17] ^= 1;
    try sign(&third, &kck);
    try t.expectError(error.NonceMismatch, guard.acceptAuthenticated(&third, &kck));
    third = keyFrame(0x13ca, 11);
    try sign(&third, &kck);
    _ = try guard.acceptAuthenticated(&third, &kck);
    try t.expectEqual(@as(?u64, 11), guard.last);
    third = keyFrame(0x13ca, 12);
    try sign(&third, &kck);
    try t.expectError(error.ExchangeComplete, guard.acceptAuthenticated(&third, &kck));
    guard = .{};
    _ = try guard.acceptInitial(&firstFrame(std.math.maxInt(u64)));
    try t.expectError(error.ReplayCounterExhausted, guard.acceptAuthenticated(&third, &kck));
}
