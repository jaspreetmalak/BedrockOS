// The numeric IEEE P802.11i/D7.0 I.7.4 MPDU1 vector below is transcribed
// from FreeBSD releng/14.3 tools/regression/net80211/ccmp/test_ccmp.c.
// No FreeBSD implementation is copied. Attribution/license for the excerpt:
// Copyright (c) 2004 Sam Leffler, Errno Consulting. All rights reserved.
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:
// 1. Redistributions of source code must retain the above copyright notice,
//    this list of conditions and the following disclaimer.
// 2. Redistributions in binary form must reproduce the above copyright
//    notice, this list of conditions and the following disclaimer in the
//    documentation and/or other materials provided with the distribution.
// 3. The name of the author may not be used to endorse or promote products
//    derived from this software without specific prior written permission.
// THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR IMPLIED
// WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF
// MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.
// IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
// SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
// PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS;
// OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY,
// WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR
// OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF
// ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
const std = @import("std");
const t = std.testing;
const cc = @import("ccmp.zig");
const ap: [6]u8 = .{ 2, 0x10, 0x20, 0x30, 0x40, 0x50 };
const sta: [6]u8 = .{ 2, 0x90, 1, 2, 3, 4 };
const source: [6]u8 = .{ 2, 0x44, 1, 2, 3, 4 };
const broadcast: [6]u8 = @splat(0xff);
const pairwise: [16]u8 = @splat(0x31);
const gtk: [16]u8 = @splat(0x82);
fn hex(comptime length: usize, input: *const [length * 2:0]u8) [length]u8 {
    var result: [length]u8 = undefined;
    _ = std.fmt.hexToBytes(&result, input) catch unreachable;
    return result;
}
fn config() cc.Config {
    return .{ .peer = ap, .station = sta, .epoch = 1, .pairwise = &pairwise, .group = .{ .id = 1, .key = &gtk } };
}
fn ethernet(destination: [6]u8, sender: [6]u8) [23]u8 {
    var result: [23]u8 = undefined;
    @memcpy(result[0..6], &destination);
    @memcpy(result[6..12], &sender);
    result[12] = 0x08;
    result[13] = 0x00;
    @memcpy(result[14..], "a payload");
    return result;
}
const Frame = struct {
    bytes: [cc.max_frame]u8 = undefined,
    length: usize = 0,
    fn slice(self: *const Frame) []const u8 {
        return self.bytes[0..self.length];
    }
};
fn receiveFrame(group: bool, pn: u64) !Frame {
    const eth = ethernet(if (group) broadcast else sta, source);
    var plain: [64]u8 = undefined;
    const length = try cc.encodeEthernet(&eth, &plain);
    var frame: Frame = .{};
    frame.length = try cc.seal(if (group) &gtk else &pairwise, .{ .direction = .from_ds, .receiver = if (group) broadcast else sta, .transmitter = ap, .address3 = source }, pn, if (group) 1 else 0, plain[0..length], &frame.bytes);
    return frame;
}
test "CCMP IEEE non-QoS golden vector includes exact nonce AAD IV ciphertext MIC" {
    const key = hex(16, "c97c1f67ce371185514a8a19f2bdd52f");
    const raw_header = hex(24, "0848c32c0fd2e128a57c5030f1844408abaea5b8fcba8033");
    const plain = hex(20, "f8ba1a55d02f85ae967bb62fb6cda8eb7e78a050");
    const expected = hex(60, "0848c32c0fd2e128a57c5030f1844408abaea5b8fcba80330ce70020769703b5f3d0a2fe9a3dbf2342a643e43246e80c3c04d0197845ce0b16f97623");
    const header = try cc.parseHeader(&raw_header);
    try t.expectEqualSlices(u8, &hex(13, "005030f1844408b5039776e70c"), &try cc.nonce(header, 0xb5039776e70c));
    try t.expectEqualSlices(u8, &hex(22, "08400fd2e128a57c5030f1844408abaea5b8fcba0000"), &try cc.aad(header));
    var output: [64]u8 = @splat(0x66);
    const length = try cc.seal(&key, header, 0xb5039776e70c, 0, &plain, &output);
    try t.expectEqualSlices(u8, &expected, output[0..length]);
    try t.expect(std.mem.allEqual(u8, output[length..], 0x66));
    // Deliberately unaligned MPDU input and output.
    var unaligned: [61]u8 = undefined;
    @memcpy(unaligned[1..], &expected);
    var opened: [21]u8 = @splat(0x77);
    const result = try cc.open(&key, unaligned[1..], opened[1..]);
    try t.expectEqual(@as(u64, 0xb5039776e70c), result.pn);
    try t.expectEqualSlices(u8, &plain, opened[1..]);
    try t.expectEqual(@as(u8, 0x77), opened[0]);
}
test "CCMP header mutations authenticate fixed fields but mask specified mutable fields" {
    const original = try receiveFrame(false, 9);
    var output: [64]u8 = @splat(0x57);
    for ([_]usize{ 4, 10, 16, 24, 25, 28, 29, 30, 31, 32, original.length - 1 }) |position| {
        var changed = original;
        changed.bytes[position] ^= 2;
        try t.expectError(error.AuthenticationFailed, cc.open(&pairwise, changed.slice(), &output));
        try t.expect(std.mem.allEqual(u8, &output, 0x57));
    }
    var mutable = original;
    mutable.bytes[1] |= 0x38; // Retry, Power Management, More Data.
    mutable.bytes[2] ^= 0xff; // Duration is not AAD.
    mutable.bytes[22] ^= 0xf0; // Sequence number is not AAD, fragment remains0.
    mutable.bytes[23] ^= 0xff;
    const good = try cc.open(&pairwise, mutable.slice(), &output);
    try t.expectEqual(original.length - 40, good.length);
    const packet = try cc.parsePacket(original.slice());
    try t.expectEqualSlices(u8, &try cc.aad(packet.header), &try cc.aad(good.header));
}
test "CCMP profile rejects truncated extended fragmented unprotected and invalid IV forms" {
    const original = try receiveFrame(false, 1);
    for (0..40) |length| try t.expectError(error.InvalidLength, cc.parsePacket(original.bytes[0..length]));
    for ([_]struct { offset: usize, bits: u8 }{ .{ .offset = 0, .bits = 0x80 }, .{ .offset = 0, .bits = 0x40 }, .{ .offset = 0, .bits = 1 }, .{ .offset = 1, .bits = 4 }, .{ .offset = 1, .bits = 0x80 }, .{ .offset = 1, .bits = 1 }, .{ .offset = 22, .bits = 1 }, .{ .offset = 1, .bits = 0x40 } }) |change| {
        var frame = original;
        frame.bytes[change.offset] ^= change.bits;
        try t.expectError(error.UnsupportedHeader, cc.parsePacket(frame.slice()));
    }
    for ([_]usize{ 26, 27 }) |position| {
        var frame = original;
        frame.bytes[position] ^= 1;
        try t.expectError(error.InvalidCcmpHeader, cc.parsePacket(frame.slice()));
    }
    var frame = original;
    frame.bytes[24] = 0;
    try t.expectError(error.InvalidPacketNumber, cc.parsePacket(frame.slice()));
    const header = try cc.parseHeader(original.slice());
    try t.expectError(error.InvalidPacketNumber, cc.nonce(header, 0));
    try t.expectError(error.InvalidPacketNumber, cc.nonce(header, cc.max_pn + 1));
    var invalid = header;
    invalid.transmitter = broadcast;
    try t.expectError(error.InvalidAddress, cc.aad(invalid));
}
test "CCMP pure preflight capacity and alias failures preserve outputs" {
    var frame = try receiveFrame(false, 1);
    var out: [64]u8 = @splat(0xe1);
    const header = try cc.parseHeader(frame.slice());
    try t.expectError(error.BufferTooSmall, cc.seal(&pairwise, header, 1, 0, "payload", out[0..10]));
    try t.expect(std.mem.allEqual(u8, &out, 0xe1));
    try t.expectError(error.BufferTooSmall, cc.open(&pairwise, frame.slice(), out[0..1]));
    try t.expect(std.mem.allEqual(u8, &out, 0xe1));
    const saved = frame;
    try t.expectError(error.BufferOverlap, cc.open(&pairwise, frame.slice(), frame.bytes[0..64]));
    try t.expectEqualSlices(u8, saved.slice(), frame.slice());
    try t.expectError(error.BufferOverlap, cc.seal(&pairwise, header, 1, 0, out[0..3], &out));
    var key_output: [64]u8 = @splat(0x31);
    try t.expectError(error.BufferOverlap, cc.seal(key_output[0..16], header, 1, 0, "x", &key_output));
    try t.expect(std.mem.allEqual(u8, &key_output, 0x31));
    var huge: [cc.max_payload + 1]u8 = undefined;
    try t.expectError(error.InvalidLength, cc.seal(&pairwise, header, 1, 0, &huge, &frame.bytes));
}
test "CCMP bridge maps three address Ethernet II without EAPOL or legacy SNAP shortcuts" {
    var eth = ethernet(source, sta);
    var plain: [64]u8 = undefined;
    const n = try cc.encodeEthernet(&eth, &plain);
    try t.expectEqualSlices(u8, &.{ 0xaa, 0xaa, 3, 0, 0, 0, 8, 0 }, plain[0..8]);
    var restored: [64]u8 = undefined;
    const header: cc.DataHeader = .{ .direction = .to_ds, .receiver = ap, .transmitter = sta, .address3 = source };
    const length = try cc.decodeEthernet(header, plain[0..n], &restored);
    try t.expectEqualSlices(u8, &eth, restored[0..length]);
    for ([_]u16{ 0x500, 0x888e, 0x80f3, 0x8137 }) |protocol| {
        std.mem.writeInt(u16, eth[12..14], protocol, .big);
        try t.expectError(error.UnsupportedProtocol, cc.encodeEthernet(&eth, &plain));
        std.mem.writeInt(u16, plain[6..8], protocol, .big);
        try t.expectError(error.UnsupportedProtocol, cc.decodeEthernet(header, plain[0..n], &restored));
    }
    plain[0] = 0;
    try t.expectError(error.InvalidSnap, cc.decodeEthernet(header, plain[0..n], &restored));
    var direct = header;
    direct.direction = .direct;
    try t.expectError(error.UnsupportedHeader, cc.decodeEthernet(direct, plain[0..n], &restored));
}
test "CCMP station TX pins source and consumes nonreused PN only after preflight" {
    var session: cc.Station = .{};
    try session.init(config());
    defer session.clear() catch unreachable;
    var output: [cc.max_frame]u8 = @splat(0x57);
    var eth = ethernet(broadcast, sta);
    try t.expectError(error.BufferTooSmall, session.sealEthernet(&eth, 1, output[0..10]));
    try t.expectEqual(@as(u64, 0), session.tx_pn);
    eth[6] ^= 2;
    try t.expectError(error.PeerMismatch, session.sealEthernet(&eth, 1, &output));
    try t.expectEqual(@as(u64, 0), session.tx_pn);
    eth = ethernet(broadcast, sta);
    for (1..4) |pn| {
        const length = try session.sealEthernet(&eth, @intCast(pn), &output);
        const packet = try cc.parsePacket(output[0..length]);
        try t.expectEqual(@as(u64, @intCast(pn)), packet.pn);
        try t.expectEqual(cc.Direction.to_ds, packet.header.direction);
        try t.expectEqualSlices(u8, &ap, &packet.header.receiver);
        try t.expectEqualSlices(u8, &sta, &packet.header.transmitter);
        try t.expectEqualSlices(u8, &broadcast, &packet.header.address3);
        try t.expectEqual(@as(u2, 0), packet.key_id);
    }
    session.tx_pn = cc.max_pn - 1; // Trusted unit-only exhaustion boundary.
    const last = try session.sealEthernet(&eth, 0, &output);
    try t.expectEqual(cc.max_pn, (try cc.parsePacket(output[0..last])).pn);
    const before = output;
    try t.expectError(error.PacketNumberExhausted, session.sealEthernet(&eth, 0, &output));
    try t.expectEqualSlices(u8, &before, &output);
}
test "CCMP station authenticates before RX replay commit or output publication" {
    var session: cc.Station = .{};
    try session.init(config());
    defer session.clear() catch unreachable;
    const frame = try receiveFrame(false, 9);
    var forged = frame;
    forged.bytes[31] ^= 0x80; // unauthenticated very high PN cannot poison state.
    var output: [64]u8 = @splat(0xa5);
    try t.expectError(error.AuthenticationFailed, session.openEthernet(forged.slice(), &output));
    try t.expectEqual(@as(u64, 0), session.history[session.pairwise_ledger].rx_pn);
    try t.expect(std.mem.allEqual(u8, &output, 0xa5));
    try t.expectError(error.BufferTooSmall, session.openEthernet(frame.slice(), output[0..1]));
    try t.expectEqual(@as(u64, 0), session.history[session.pairwise_ledger].rx_pn);
    const length = try session.openEthernet(frame.slice(), &output);
    try t.expectEqualSlices(u8, &ethernet(sta, source), output[0..length]);
    try t.expectEqual(@as(u64, 9), session.history[session.pairwise_ledger].rx_pn);
    try t.expectError(error.ReplayDetected, session.openEthernet(frame.slice(), &output));
    const older = try receiveFrame(false, 8);
    try t.expectError(error.ReplayDetected, session.openEthernet(older.slice(), &output));
    const newer = try receiveFrame(false, 10);
    _ = try session.openEthernet(newer.slice(), &output);
}
test "CCMP separate group ledger and pinned receiver peer key ID fail closed" {
    var options = config();
    options.group.?.rx_pn = 100;
    var session: cc.Station = .{};
    try session.init(options);
    defer session.clear() catch unreachable;
    var output: [64]u8 = @splat(0xa5);
    const group = try receiveFrame(true, 101);
    const old = try receiveFrame(true, 100);
    try t.expectError(error.ReplayDetected, session.openEthernet(old.slice(), &output));
    _ = try session.openEthernet(group.slice(), &output);
    const pair = try receiveFrame(false, 1);
    _ = try session.openEthernet(pair.slice(), &output);
    try t.expectEqual(@as(u64, 101), session.history[session.group_ledger].rx_pn);
    try t.expectEqual(@as(u64, 1), session.history[session.pairwise_ledger].rx_pn);
    var bad = try receiveFrame(false, 2);
    bad.bytes[27] |= 0x40;
    try t.expectError(error.KeyMismatch, session.openEthernet(bad.slice(), &output));
    bad = try receiveFrame(false, 2);
    bad.bytes[4] ^= 2;
    try t.expectError(error.PeerMismatch, session.openEthernet(bad.slice(), &output));
    bad = try receiveFrame(false, 2);
    bad.bytes[10] ^= 2;
    try t.expectError(error.PeerMismatch, session.openEthernet(bad.slice(), &output));
    bad = try receiveFrame(false, 2);
    bad.bytes[1] ^= 3; // ToDS is not an AP data delivery.
    try t.expectError(error.PeerMismatch, session.openEthernet(bad.slice(), &output));
    const wrong_group = try receiveFrame(true, 102);
    var plain: [64]u8 = undefined;
    const decoded = try cc.open(&gtk, wrong_group.slice(), &plain);
    var wrong: Frame = .{};
    wrong.length = try cc.seal(&pairwise, decoded.header, 102, 1, plain[0..decoded.length], &wrong.bytes);
    try t.expectError(error.AuthenticationFailed, session.openEthernet(wrong.slice(), &output));
    try t.expectEqual(@as(u64, 101), session.history[session.group_ledger].rx_pn);
}
test "CCMP authenticated unsupported SNAP or protected EAPOL does not consume RX" {
    var session: cc.Station = .{};
    try session.init(config());
    defer session.clear() catch unreachable;
    const header: cc.DataHeader = .{ .direction = .from_ds, .receiver = sta, .transmitter = ap, .address3 = source };
    var plain = [_]u8{ 0xaa, 0xaa, 3, 0, 0, 0, 0x88, 0x8e, 2, 3, 0, 0 };
    var frame: Frame = .{};
    frame.length = try cc.seal(&pairwise, header, 1, 0, &plain, &frame.bytes);
    var output: [64]u8 = @splat(0x9d);
    try t.expectError(error.UnsupportedProtocol, session.openEthernet(frame.slice(), &output));
    try t.expect(std.mem.allEqual(u8, &output, 0x9d));
    try t.expectEqual(@as(u64, 0), session.history[session.pairwise_ledger].rx_pn);
    plain[0] = 0;
    frame.length = try cc.seal(&pairwise, header, 1, 0, &plain, &frame.bytes);
    try t.expectError(error.InvalidSnap, session.openEthernet(frame.slice(), &output));
    const good = try receiveFrame(false, 1);
    _ = try session.openEthernet(good.slice(), &output);
}
test "CCMP key clear and new epochs retain TX history and repeated GTK replay ledger" {
    var session: cc.Station = .{};
    try session.init(config());
    var output: [cc.max_frame]u8 = undefined;
    const eth = ethernet(broadcast, sta);
    _ = try session.sealEthernet(&eth, 0, &output);
    const group = try receiveFrame(true, 7);
    _ = try session.openEthernet(group.slice(), &output);
    try session.clear();
    try t.expect(std.mem.allEqual(u8, &session.pairwise_key, 0));
    try t.expect(std.mem.allEqual(u8, &session.group_key, 0));
    try t.expectError(error.NotInitialized, session.sealEthernet(&eth, 0, &output));
    try t.expectError(error.StaleEpoch, session.init(config()));
    var options = config();
    options.epoch = 2;
    try t.expectError(error.KeyReuse, session.init(options));
    const replacement: [16]u8 = @splat(0x42);
    options.pairwise = &replacement;
    try session.init(options);
    try t.expectEqual(@as(u64, 7), session.history[session.group_ledger].rx_pn);
    try t.expectError(error.ReplayDetected, session.openEthernet(group.slice(), &output));
    const length = try session.sealEthernet(&eth, 0, &output);
    try t.expectEqual(@as(u64, 2), (try cc.parsePacket(output[0..length])).pn);
    try session.clear();
    options.epoch = 3;
    options.pairwise = &pairwise;
    try t.expectError(error.KeyReuse, session.init(options)); // A->B->A cannot reset.
    options.pairwise = &replacement;
    try t.expectError(error.KeyReuse, session.init(options));
}
test "CCMP copied owner cannot emit duplicate nonce or clear actual keys" {
    var session: cc.Station = .{};
    try session.init(config());
    defer session.clear() catch unreachable;
    var copied = session;
    var output: [cc.max_frame]u8 = @splat(0x55);
    const eth = ethernet(broadcast, sta);
    try t.expectError(error.InvalidOwner, copied.sealEthernet(&eth, 0, &output));
    try t.expect(std.mem.allEqual(u8, &output, 0x55));
    try t.expect(std.mem.allEqual(u8, &copied.pairwise_key, 0));
    try t.expect(std.mem.allEqual(u8, &copied.group_key, 0));
    try t.expectError(error.InvalidOwner, copied.clear());
    try t.expectError(error.InvalidOwner, copied.init(config()));
    try t.expect(session.active);
    try t.expectEqualSlices(u8, &pairwise, &session.pairwise_key);
    _ = try session.sealEthernet(&eth, 0, &output);
    try t.expectEqual(@as(u64, 1), session.tx_pn);
    const frame = try receiveFrame(false, 1);
    try t.expectError(error.BufferOverlap, session.openEthernet(frame.slice(), std.mem.asBytes(&session)));
    try t.expect(session.active);
    try t.expectEqual(@as(u64, 0), session.history[session.pairwise_ledger].rx_pn);
}
test "CCMP initialization key epoch ledger capacity and maximum frame bounds" {
    var session: cc.Station = .{};
    var options = config();
    options.epoch = 0;
    try t.expectError(error.StaleEpoch, session.init(options));
    options = config();
    options.pairwise_rx_pn = cc.max_pn + 1;
    try t.expectError(error.InvalidPacketNumber, session.init(options));
    options = config();
    options.pairwise = &@as([16]u8, @splat(0));
    try t.expectError(error.InvalidKey, session.init(options));
    options = config();
    options.group.?.key = &pairwise;
    try t.expectError(error.KeyReuse, session.init(options));
    options = config();
    options.pairwise = &session.pairwise_key;
    try t.expectError(error.BufferOverlap, session.init(options));
    try t.expect(!session.active and session.epoch == 0 and session.history_count == 0);
    for (1..cc.max_key_history + 1) |epoch| {
        var key: [16]u8 = @splat(@intCast(epoch));
        options = .{ .peer = ap, .station = sta, .epoch = @intCast(epoch), .pairwise = &key };
        try session.init(options);
        try t.expectError(error.AlreadyInitialized, session.init(options));
        try session.clear();
    }
    const last_key: [16]u8 = @splat(0xf0);
    options = .{ .peer = ap, .station = sta, .epoch = 17, .pairwise = &last_key };
    try t.expectError(error.KeyHistoryCapacity, session.init(options));
    try t.expectEqual(@as(u64, 16), session.epoch);
    const header: cc.DataHeader = .{ .direction = .from_ds, .receiver = sta, .transmitter = ap, .address3 = source };
    var frame: [cc.max_frame]u8 = undefined;
    const payload: [cc.max_payload]u8 = @splat(0x71);
    const length = try cc.seal(&pairwise, header, 1, 0, &payload, &frame);
    try t.expectEqual(@as(usize, cc.max_frame), length);
    var decoded: [cc.max_payload]u8 = undefined;
    _ = try cc.open(&pairwise, &frame, &decoded);
    try t.expectEqualSlices(u8, &payload, &decoded);
    var oversized: [cc.max_frame + 1]u8 = undefined;
    try t.expectError(error.InvalidLength, cc.parsePacket(&oversized));
}
