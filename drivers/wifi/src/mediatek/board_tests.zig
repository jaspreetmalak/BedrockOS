// SPDX-License-Identifier: ISC
// Copyright (C) 2026 Bedrock contributors
//! Synthetic decoder/MCU fixtures only. No radio is accessed or qualified.
const std = @import("std");
const t = std.testing;
const board = @import("board.zig");
const nic = @import("nic.zig");
const mt = @import("regulatory.zig");
const common = @import("../regulatory/types.zig");
const id: board.Identity = .{ .vendor = 0x14c3, .device = 0x0616, .subsystem_vendor = 0x1028, .subsystem_device = 0x1234, .revision = 1 };
fn put(comptime T: type, bytes: []u8, offset: usize, value: T) void {
    std.mem.writeInt(T, bytes[offset..][0..@sizeOf(T)], value, .little);
}
fn checksum(bytes: []u8) void {
    @memset(bytes[40..72], 0);
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
    @memcpy(bytes[40..72], &hash);
}
fn fixture() [board.header_size + 2 * board.record_size]u8 {
    var bytes: [board.header_size + 2 * board.record_size]u8 = @splat(0);
    @memcpy(bytes[0..8], board.magic);
    put(u16, &bytes, 8, 1);
    put(u16, &bytes, 10, 128);
    put(u32, &bytes, 12, bytes.len);
    put(u16, &bytes, 16, 2);
    put(u16, &bytes, 18, 192);
    put(u16, &bytes, 20, id.vendor);
    put(u16, &bytes, 22, id.device);
    put(u16, &bytes, 24, id.subsystem_vendor);
    put(u16, &bytes, 26, id.subsystem_device);
    bytes[28] = id.revision;
    bytes[29] = 3;
    bytes[30] = 1;
    bytes[31] = 1;
    bytes[33] = 0xff;
    bytes[34] = 1;
    bytes[35] = 15;
    @memcpy(bytes[36..38], "US");
    bytes[38] = 1;
    put(u32, &bytes, 104, 0x550);
    put(u32, &bytes, 108, 1);
    @memset(bytes[112..128], 0x21);
    for (0..2) |index| {
        const offset = 128 + index * 192;
        bytes[offset] = @intCast(index + 1);
        bytes[offset + 1] = if (index == 0) 6 else 36;
        put(u16, &bytes, offset + 2, 7);
        put(i32, &bytes, offset + 4, 300);
        put(i32, &bytes, offset + 8, 2000);
        put(i32, &bytes, offset + 12, 1500);
        put(u32, &bytes, offset + 16, 20000);
        @memset(bytes[offset + 20 ..][0..161], 30);
    }
    checksum(&bytes);
    return bytes;
}
fn caps() nic.Capabilities {
    return .{ .address = .{ 2, 1, 2, 3, 4, 5 }, .phy = .{ .raw = @splat(0), .nss = 2, .antenna_mask = 3, .max_bandwidth_code = 0, .has_2ghz = true, .has_5ghz = true }, .chip_capability = 1 };
}
fn efuse() nic.EepromBlock {
    return .{ .address = 0x550, .validity = 1, .data = @splat(0x21) };
}
fn report(sequence: u8) [36 + board.power_body_size]u8 {
    var bytes: [36 + board.power_body_size]u8 = @splat(0);
    put(u32, &bytes, 0, (7 << 27) | @as(u32, bytes.len));
    put(u16, &bytes, 24, bytes.len - 24);
    bytes[28] = 0xd0;
    bytes[29] = sequence;
    put(u16, &bytes, 38, 494);
    bytes[40] = 6;
    for (0..3) |i| {
        bytes[44 + i * 162] = 6;
        @memset(bytes[45 + i * 162 ..][0..161], @intCast(40 - i * 5));
    }
    return bytes;
}
test "board unaligned atomic decode preserves exact explicit hardware facts without digest gate" {
    const raw = fixture();
    var unaligned: [raw.len + 1]u8 = undefined;
    @memcpy(unaligned[1..], &raw);
    try board.validate(unaligned[1..]);
    var profile: board.Profile = .{};
    try board.decode(unaligned[1..], &profile);
    try t.expectEqualDeep(id, profile.identity);
    try t.expectEqual(@as(usize, 2), profile.count);
    try t.expectEqual(@as(i32, 1500), profile.channels[0].ceiling());
    try t.expectEqualDeep(efuse(), profile.efuse);
    try t.expect(std.mem.allEqual(u8, &profile.provenance, 0));
    try profile.verify(id, caps(), efuse());
    var changed = raw;
    changed[128 + 20] ^= 1;
    try t.expectError(error.ProfileIntegrity, board.decode(&changed, &profile));
    try t.expectEqualDeep(id, profile.identity);
    try t.expectEqual(@as(usize, 2), profile.count);
    var metadata = raw;
    metadata[35] ^= 1;
    try t.expectError(error.ProfileIntegrity, board.validate(&metadata));
}
test "board geometry version reserved identity and hardware declarations fail closed" {
    const raw = fixture();
    for (0..128) |len| try t.expectError(error.InvalidProfile, board.validate(raw[0..len]));
    var changed = raw;
    put(u16, &changed, 16, 65);
    try t.expectError(error.InvalidProfile, board.validate(&changed));
    changed = raw;
    changed[8] = 2;
    try t.expectError(error.UnsupportedProfile, board.validate(&changed));
    changed = raw;
    changed[39] = 1;
    checksum(&changed);
    try t.expectError(error.InvalidProfile, board.validate(&changed));
    changed = raw;
    changed[35] = 0x80;
    checksum(&changed);
    try t.expectError(error.InvalidPlatformFlags, board.validate(&changed));
    changed = raw;
    changed[20] = 0;
    checksum(&changed);
    try t.expectError(error.InvalidIdentity, board.validate(&changed));
    changed = raw;
    changed[30] = 0;
    checksum(&changed);
    try t.expectError(error.InvalidProfile, board.validate(&changed));
    changed = raw;
    changed[35] = 1;
    checksum(&changed);
    var profile: board.Profile = .{};
    try board.decode(&changed, &profile);
    try t.expectError(error.HardwareAssumptionsMissing, profile.verify(id, caps(), efuse()));
    var huge: [board.max_profile_size + 1]u8 = undefined;
    try t.expectError(error.ProfileTooLarge, board.validate(&huge));
}
test "board never joins partial rules or invents calibration rate SAR or wider band proof" {
    const raw = fixture();
    var changed = raw;
    changed[128] = 3;
    checksum(&changed);
    try t.expectError(error.InvalidChannel, board.validate(&changed));
    changed = raw;
    changed[129] = 15;
    checksum(&changed);
    try t.expectError(error.InvalidChannel, board.validate(&changed));
    changed = raw;
    changed[320] = 1;
    changed[321] = 6;
    checksum(&changed);
    try t.expectError(error.DuplicateChannel, board.validate(&changed));
    changed = raw;
    put(u16, &changed, 130, 3);
    checksum(&changed);
    try t.expectError(error.MissingBoardFacts, board.validate(&changed));
    changed = raw;
    put(u32, &changed, 144, 40000);
    checksum(&changed);
    try t.expectError(error.InvalidChannel, board.validate(&changed));
    changed = raw;
    put(i32, &changed, 140, 1499);
    checksum(&changed);
    try t.expectError(error.InvalidPower, board.validate(&changed));
    changed = raw;
    changed[148] = 31;
    checksum(&changed);
    try t.expectError(error.InvalidPower, board.validate(&changed));
    changed = raw;
    put(i32, &changed, 132, 20001);
    checksum(&changed);
    try t.expectError(error.InvalidGain, board.validate(&changed));
    changed = raw;
    changed[309] = 1;
    checksum(&changed);
    try t.expectError(error.InvalidProfile, board.validate(&changed));
}
test "board exact PCI subsystem revision PHY EFUSE and CLC matching preflight capability writes" {
    const raw = fixture();
    var profile: board.Profile = .{};
    try board.decode(&raw, &profile);
    var actual = id;
    actual.subsystem_device += 1;
    try t.expectError(error.DeviceMismatch, profile.verify(actual, caps(), efuse()));
    actual = id;
    actual.revision += 1;
    try t.expectError(error.DeviceMismatch, profile.verify(actual, caps(), efuse()));
    var phy = caps();
    phy.phy.antenna_mask = 1;
    try t.expectError(error.PhyMismatch, profile.verify(id, phy, efuse()));
    phy = caps();
    phy.phy.has_5ghz = false;
    try t.expectError(error.PhyMismatch, profile.verify(id, phy, efuse()));
    phy = caps();
    phy.chip_capability = null;
    try t.expectError(error.PhyMismatch, profile.verify(id, phy, efuse()));
    var factory = efuse();
    factory.data[0] ^= 1;
    try t.expectError(error.EfuseMismatch, profile.verify(id, caps(), factory));
    factory = efuse();
    factory.validity = 0;
    try t.expectError(error.EfuseMismatch, profile.verify(id, caps(), factory));
    var output: [2]common.ChannelCap = @splat(.{ .band = .ghz2, .channel = 1, .center_khz = 2412000 });
    var powers: [2]mt.PowerChannel = @splat(.{ .band = .ghz2, .number = 1, .board_ceiling_mbm = 0, .rates = @splat(0) });
    const before = output;
    const before_power = powers;
    try t.expectError(error.DeviceMismatch, profile.buildCapabilities(actual, caps(), efuse(), &output, &powers));
    try t.expectEqualDeep(before, output);
    try t.expectEqualDeep(before_power, powers);
    try t.expectError(error.BufferTooSmall, profile.buildCapabilities(id, caps(), efuse(), output[0..1], &powers));
    try t.expectEqualDeep(before, output);
    try t.expectEqual(@as(usize, 2), try profile.buildCapabilities(id, caps(), efuse(), &output, &powers));
    try t.expect(output[0].calibrated and output[0].available_rx);
    try t.expectEqual(@as(?i32, 1500), output[0].max_conducted_power_mbm);
    try t.expectEqual(@as(?i32, 300), output[0].antenna_gain_mbi);
    try t.expectEqual(@as(i32, 1500), powers[0].board_ceiling_mbm);
    try t.expectError(error.BufferOverlap, board.decode(std.mem.asBytes(&profile), &profile));
}
test "board signed negative conducted ceilings floor without power widening" {
    var raw = fixture();
    for (0..2) |i| {
        const offset = 128 + i * 192;
        put(i32, &raw, offset + 8, -1200);
        put(i32, &raw, offset + 12, -1251);
        @memset(raw[offset + 20 ..][0..161], @bitCast(@as(i8, -26)));
    }
    checksum(&raw);
    var profile: board.Profile = .{};
    try board.decode(&raw, &profile);
    try t.expectEqual(@as(i32, -1251), profile.channels[0].ceiling());
    try t.expectEqual(@as(i8, -26), profile.channels[0].rates[0]);
}
test "factory power decoder binds actual MCU sequence EID sizes channel and signed tables" {
    const bytes = report(4);
    const found = try board.decodeTxPowerInfo(&bytes, 4);
    try t.expectEqual(@as(u8, 6), found.channel);
    try t.expectEqual(@as(i32, 1500), try found.rateCeiling(0));
    var unaligned: [bytes.len + 1]u8 = undefined;
    @memcpy(unaligned[1..], &bytes);
    try t.expectEqualDeep(found, try board.decodeTxPowerInfo(unaligned[1..], 4));
    try t.expectError(error.StalePowerResponse, board.decodeTxPowerInfo(&bytes, 5));
    var bad = bytes;
    bad[28] = 1;
    try t.expectError(error.UnsupportedPowerReport, board.decodeTxPowerInfo(&bad, 4));
    bad = bytes;
    bad[30] = 4;
    try t.expectError(error.UnsupportedPowerReport, board.decodeTxPowerInfo(&bad, 4));
    bad = bytes;
    bad[38] = 0;
    try t.expectError(error.InvalidPowerReport, board.decodeTxPowerInfo(&bad, 4));
    bad = bytes;
    bad[45 + 162] = @bitCast(@as(i8, -3));
    const negative = try board.decodeTxPowerInfo(&bad, 4);
    try t.expectEqual(@as(i32, -150), try negative.rateCeiling(0));
    bad = bytes;
    bad[45 + 162] = 127;
    const na = try board.decodeTxPowerInfo(&bad, 4);
    try t.expectError(error.PowerUnavailable, na.rateCeiling(0));
    bad = bytes;
    bad[44 + 162] = 0;
    const no_channel = try board.decodeTxPowerInfo(&bad, 4);
    try t.expectError(error.InvalidPowerChannel, no_channel.rateCeiling(0));
    bad = bytes;
    bad[40] = 0;
    const unassigned = try board.decodeTxPowerInfo(&bad, 4);
    try t.expectError(error.InvalidPowerChannel, unassigned.rateCeiling(0));
    try t.expectError(error.InvalidPowerReport, board.decodeTxPowerInfo(bytes[0 .. bytes.len - 1], 4));
    try t.expectError(error.InvalidPowerReport, found.rateCeiling(161));
}
test "factory power intersection can only tighten trusted board SAR and N A never becomes maximum" {
    var bytes = report(4);
    var found = try board.decodeTxPowerInfo(&bytes, 4);
    const input: mt.PowerChannel = .{ .band = .ghz2, .number = 6, .board_ceiling_mbm = 1800, .rates = @splat(35) };
    var output = input;
    try found.intersect(input, &output);
    try t.expect(std.mem.allEqual(i8, &output.rates, 30));
    bytes[45 + 162] = 127;
    found = try board.decodeTxPowerInfo(&bytes, 4);
    try found.intersect(input, &output);
    try t.expectEqual(@as(i8, 35), output.rates[0]);
    const before = output;
    var invalid = input;
    invalid.number = 11;
    try t.expectError(error.InvalidPowerChannel, found.intersect(invalid, &output));
    try t.expectEqualDeep(before, output);
    invalid = input;
    invalid.board_ceiling_mbm = -6401;
    try t.expectError(error.InvalidPower, found.intersect(invalid, &output));
    try t.expectEqualDeep(before, output);
    var query: [9]u8 = @splat(0x55);
    try t.expectError(error.BufferTooSmall, board.encodeTxPowerQuery(query[0..7]));
    try t.expect(std.mem.allEqual(u8, &query, 0x55));
    try t.expectEqualSlices(u8, &@as([8]u8, @splat(0)), try board.encodeTxPowerQuery(&query));
    try t.expectEqual(@as(u8, 0x55), query[8]);
}
// Standalone PIC probes force the native parser and runtime matching methods.
export fn bedrock_board_check(bytes: [*]const u8, len: usize, profile: *board.Profile, actual: *const board.Identity, capabilities: *const nic.Capabilities, factory: *const nic.EepromBlock, caps_out: [*]common.ChannelCap, powers: [*]mt.PowerChannel, count: usize) callconv(.c) usize {
    board.decode(bytes[0..len], profile) catch return 0;
    return profile.buildCapabilities(actual.*, capabilities.*, factory.*, caps_out[0..count], powers[0..count]) catch 0;
}
export fn bedrock_power_report_check(bytes: [*]const u8, len: usize, sequence: u8, input: *const mt.PowerChannel, output: *mt.PowerChannel) callconv(.c) bool {
    const found = board.decodeTxPowerInfo(bytes[0..len], sequence) catch return false;
    found.intersect(input.*, output) catch return false;
    return true;
}
