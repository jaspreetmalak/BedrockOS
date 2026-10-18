// SPDX-License-Identifier: ISC
// Copyright (C) 2026 Bedrock contributors
const std = @import("std");
const t = std.testing;
const r = @import("regulatory.zig");
const m = @import("mcu.zig");
const w = @import("wire.zig");
const caps = r.DeviceCapabilities{ .channels = &.{
    .{ .band = .ghz2, .number = 1, .max_power_mbm = 2000 },
    .{ .band = .ghz5, .number = 36, .max_power_mbm = 2300 },
    .{ .band = .ghz6, .number = 5, .max_power_mbm = 1800 },
} };
const limits = [_]r.ChannelLimit{
    .{ .band = .ghz2, .number = 1, .max_power_mbm = 1900 },
    .{ .band = .ghz5, .number = 36, .max_power_mbm = 1800, .dfs = true },
};
const powers = [_]r.PowerChannel{
    .{ .band = .ghz2, .number = 1, .board_ceiling_mbm = 1700, .rates = @splat(30) },
    .{ .band = .ghz5, .number = 36, .board_ceiling_mbm = 1600, .rates = @splat(31) },
};
const board = r.Board{ .encapsulation = 0, .acpi_conf = 0x12, .mtcl_conf = 0x34, .power_type = .lpi, .clc_event_supported = true };
fn domain() r.Domain {
    return .{ .country = .{ 'U', 'S' }, .environment = .indoor, .channels = &limits };
}
fn clcFixture() [94]u8 {
    var b: [94]u8 = @splat(0);
    for (0..3) |i| {
        const block = b[i * 26 ..][0..26];
        w.put32(block, 26);
        block[4] = if (i == 2) 1 else 0;
        block[5] = 1;
        block[6] = 255; // vendor count saturates; traversal uses actual extents
        block[7] = if (i == 1) 1 else 0;
        @memcpy(block[16..20], &[_]u8{ 'U', 'S', 0x11, 0x22 });
        w.put16(block[20..], 4);
        @memcpy(block[22..26], &[_]u8{ @intCast(i + 1), 2, 3, 4 });
    }
    w.put32(b[78..], 16);
    b[82] = 3; // newer unknown index must remain opaque, never old channel data
    b[83] = 7;
    return b;
}
fn plan(clc: r.Clc) r.Plan {
    return .{ .device_epoch = 1, .generation = 1, .domain = domain(), .capabilities = caps, .clc = clc, .board = board, .power = &powers };
}
fn canary(bytes: []const u8) !void {
    for (bytes) |b| try t.expectEqual(@as(u8, 0xaa), b);
}

test "regulatory domain golden12byte header grouped channels and20MHz restrictions" {
    const channels = [_]r.ChannelLimit{
        .{ .band = .ghz6, .number = 5, .max_power_mbm = 1600, .no_ir = true, .indoor_only = true },
        limits[1],
        limits[0],
    };
    var out: [r.domain_size]u8 = undefined;
    var d = domain();
    d.channels = &channels;
    const packet = try r.encodeDomain(d, caps, &out);
    try t.expectEqualSlices(u8, &.{ 'U', 'S', 0, 0, 1, 1, 1, 0, 1, 1, 1, 0 }, packet[0..12]);
    try t.expectEqual(@as(usize, 36), packet.len);
    try t.expectEqual(@as(u16, 1), w.le16(packet[12..]));
    try t.expectEqual(@as(u32, 0x801b0), w.le32(packet[16..]));
    try t.expectEqual(@as(u16, 36), w.le16(packet[20..]));
    try t.expectEqual(@as(u32, 0x801ba), w.le32(packet[24..]));
    try t.expectEqual(@as(u16, 5), w.le16(packet[28..]));
    try t.expectEqual(@as(u32, 0x803b2), w.le32(packet[32..]));
}
test "regulatory invalid domain capability and environment requests preserve output" {
    var out: [r.domain_size]u8 = @splat(0xaa);
    var d = domain();
    d.country = .{ 'u', 's' };
    try t.expectError(error.InvalidChannelDomain, r.encodeDomain(d, caps, &out));
    d = domain();
    const high = [_]r.ChannelLimit{.{ .band = .ghz2, .number = 1, .max_power_mbm = 2001 }};
    d.channels = &high;
    try t.expectError(error.PowerExceedsDevice, r.encodeDomain(d, caps, &out));
    const missing = [_]r.ChannelLimit{.{ .band = .ghz2, .number = 2, .max_power_mbm = 1000 }};
    d.channels = &missing;
    try t.expectError(error.UnsupportedDeviceChannel, r.encodeDomain(d, caps, &out));
    const duplicate = [_]r.ChannelLimit{ limits[0], limits[0] };
    d.channels = &duplicate;
    try t.expectError(error.DuplicatePolicyChannel, r.encodeDomain(d, caps, &out));
    const indoor = [_]r.ChannelLimit{.{ .band = .ghz2, .number = 1, .max_power_mbm = 1000, .indoor_only = true }};
    d.channels = &indoor;
    d.environment = .outdoor;
    try t.expectError(error.IndoorChannelInitiation, r.encodeDomain(d, caps, &out));
    d = domain();
    d.country = .{ '0', '0' };
    try t.expectError(error.RestrictedChannelInitiation, r.encodeDomain(d, caps, &out));
    d = domain();
    const six = [_]r.ChannelLimit{.{ .band = .ghz6, .number = 5, .max_power_mbm = 1000 }};
    d.channels = &six;
    try t.expectError(error.RestrictedChannelInitiation, r.encodeDomain(d, caps, &out));
    try canary(&out);
    try t.expectError(error.OutputTooSmall, r.encodeDomain(domain(), caps, out[0..27]));
    try canary(&out);
}
test "regulatory power golden44byte header162byte SKU and signed entries" {
    var out: [r.power_size]u8 = undefined;
    const packet = try r.encodePowerBatch(domain(), caps, powers[1..], true, &out);
    try t.expectEqual(@as(usize, 206), packet.len);
    try t.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 1, 2, 1, 0, 'U', 'S', 0, 0 }, packet[0..12]);
    for (packet[12..44]) |b| try t.expectEqual(@as(u8, 0), b);
    try t.expectEqual(@as(u8, 36), packet[44]);
    for (packet[45..206]) |b| try t.expectEqual(@as(u8, 31), b);
    var negative_limits = [_]r.ChannelLimit{.{ .band = .ghz2, .number = 1, .max_power_mbm = -51 }};
    var d = domain();
    d.channels = &negative_limits;
    const negative = [_]r.PowerChannel{.{ .band = .ghz2, .number = 1, .board_ceiling_mbm = 1000, .rates = @splat(-2) }};
    const signed = try r.encodePowerBatch(d, caps, &negative, false, &out);
    try t.expectEqual(@as(u8, 0xfe), signed[45]);
    var invalid = negative;
    invalid[0].rates[160] = -1;
    try t.expectError(error.RatePowerExceedsPolicy, r.encodePowerBatch(d, caps, &invalid, false, &out));
}
test "regulatory power rejects widening mixed bands duplicates and short outputs atomically" {
    var out: [r.power_size]u8 = @splat(0xaa);
    var invalid = powers;
    invalid[0].rates[160] = 35;
    try t.expectError(error.RatePowerExceedsPolicy, r.encodePowerBatch(domain(), caps, invalid[0..1], false, &out));
    try t.expectError(error.MixedPowerBands, r.encodePowerBatch(domain(), caps, &powers, false, &out));
    const duplicate = [_]r.PowerChannel{ powers[0], powers[0] };
    try t.expectError(error.DuplicatePowerChannel, r.encodePowerBatch(domain(), caps, &duplicate, false, &out));
    try t.expectError(error.OutputTooSmall, r.encodePowerBatch(domain(), caps, powers[0..1], false, out[0..205]));
    try canary(&out);
}
test "regulatory CLC selects real encapsulation country and preserves unknown blocks opaque" {
    const bytes = clcFixture();
    const clc = try r.Clc.parse(&bytes, 0);
    try t.expectEqual(@as(usize, 1), clc.skipped_blocks);
    var iterator = clc.rules(.{ 'U', 'S' });
    const power = iterator.next().?;
    try t.expectEqual(@as(u8, 0), power.index);
    try t.expectEqual(@as(u8, 1), power.data[0]);
    try t.expectEqual(@as(u8, 1), iterator.next().?.index);
    try t.expectEqual(@as(?r.ClcRule, null), iterator.next());
    var missing = clc.rules(.{ 'C', 'A' });
    try t.expectEqual(@as(?r.ClcRule, null), missing.next());
    const other = try r.Clc.parse(&bytes, 1);
    var alternate = other.rules(.{ 'U', 'S' });
    try t.expectEqual(@as(u8, 2), alternate.next().?.data[0]);
}
test "regulatory CLC command golden76byte header and borrowed authentic payload" {
    const bytes = clcFixture();
    const clc = try r.Clc.parse(&bytes, 0);
    var iterator = clc.rules(.{ 'U', 'S' });
    const rule = iterator.next().?;
    var out: [4096]u8 = undefined;
    const packet = try r.encodeClc(rule, .indoor, board, &out);
    try t.expectEqual(@as(usize, 80), packet.len);
    try t.expectEqualSlices(u8, &.{ 1, 0, 80, 0, 0, 1, 0x12, 1, 'U', 'S', 0x11, 0x22, 2, 0x34 }, packet[0..14]);
    for (packet[14..76]) |b| try t.expectEqual(@as(u8, 0), b);
    try t.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, packet[76..]);
}
test "regulatory CLC malformed lengths duplicates unsupported version and country fail before writes" {
    var bytes = clcFixture();
    w.put32(&bytes, 0);
    try t.expectError(error.InvalidClc, r.Clc.parse(&bytes, 0));
    bytes = clcFixture();
    w.put16(bytes[20..], 5);
    try t.expectError(error.InvalidClc, r.Clc.parse(&bytes, 0));
    bytes = clcFixture();
    bytes[5] = 2;
    try t.expectError(error.UnsupportedClcVersion, r.Clc.parse(&bytes, 0));
    bytes = clcFixture();
    bytes[33] = 0;
    try t.expectError(error.DuplicateClcBlock, r.Clc.parse(&bytes, 0));
    bytes = clcFixture();
    try t.expectError(error.InvalidClc, r.Clc.parse(bytes[0..93], 0));
    var out: [4096]u8 = @splat(0xaa);
    try t.expectError(error.InvalidClcRule, r.encodeClc(.{ .index = 3, .country = .{ 'U', 'S' }, .kind = .{ 1, 2 }, .data = &.{1} }, .indoor, board, &out));
    try canary(&out);
}
const Replay = struct {
    commands: [32]u8 = undefined,
    counts: [32]u8 = undefined,
    last: [32]bool = undefined,
    sent: usize = 0,
    fail_at: ?usize = null,
    fn submit(context: *anyopaque, queue: m.Queue, bytes: []const u8) !void {
        const self: *Replay = @ptrCast(@alignCast(context));
        try t.expectEqual(m.Queue.wm, queue);
        try t.expect(bytes.len >= 64);
        try t.expectEqual(@as(u8, 1), bytes[38]);
        if (self.fail_at == self.sent) return error.InjectedIO;
        self.commands[self.sent] = bytes[36];
        self.counts[self.sent] = bytes[68];
        self.last[self.sent] = bytes[70] == 1;
        self.sent += 1;
    }
    fn receive(_: *anyopaque, _: []u8) !?usize {
        return error.UnexpectedReceive;
    }
    fn delay(_: *anyopaque, _: u32) !void {
        return error.UnexpectedDelay;
    }
    fn channel(self: *Replay) m.Channel {
        return .{ .context = self, .submit = submit, .receive = receive, .delayUs = delay };
    }
};
test "regulatory session submits CLC domain then per-band SKU without claiming firmware acknowledgement" {
    const bytes = clcFixture();
    const clc = try r.Clc.parse(&bytes, 0);
    var replay: Replay = .{};
    var mcu: m.Mcu = undefined;
    mcu.init(replay.channel());
    var session: r.Session = .{};
    try session.init(1);
    try session.submit(&mcu, plan(clc));
    try t.expectEqualSlices(u8, &.{ 0x5c, 0x5c, 0x0f, 0x5d, 0x5d }, replay.commands[0..replay.sent]);
    try t.expect(!replay.last[3] and replay.last[4]);
    try t.expect(session.isSubmitted(1, 1));
    try t.expect(!session.isSubmitted(2, 1) and !session.isSubmitted(1, 2));
    try t.expectError(error.StalePolicyGeneration, session.submit(&mcu, plan(clc)));
    try t.expectEqual(@as(usize, 5), replay.sent);
    try session.invalidate();
    try t.expect(!session.isSubmitted(1, 1));
    try t.expectError(error.StalePolicyGeneration, session.submit(&mcu, plan(clc)));
}
test "regulatory session preflights all malformed policy CLC and rate entries with zero IO or generation issuance" {
    var bytes = clcFixture();
    const clc = try r.Clc.parse(&bytes, 0);
    var replay: Replay = .{};
    var mcu: m.Mcu = undefined;
    mcu.init(replay.channel());
    var session: r.Session = .{};
    try session.init(1);
    var p = plan(clc);
    var bad_power = powers;
    bad_power[1].rates[160] = 33;
    p.power = &bad_power;
    try t.expectError(error.RatePowerExceedsPolicy, session.submit(&mcu, p));
    p = plan(clc);
    p.power = powers[0..1];
    try t.expectError(error.IncompleteRatePower, session.submit(&mcu, p));
    p = plan(clc);
    p.domain.country = .{ 'C', 'A' };
    try t.expectError(error.CountryMissingClc, session.submit(&mcu, p));
    p = plan(clc);
    p.board.encapsulation = 1;
    try t.expectError(error.ClcEncapsulationMismatch, session.submit(&mcu, p));
    p = plan(clc);
    w.put16(bytes[20..], 0xffff); // stale/mutated borrowed vendor storage
    try t.expectError(error.InvalidClc, session.submit(&mcu, p));
    try t.expectEqual(@as(usize, 0), replay.sent);
    try t.expectEqual(@as(u64, 0), session.highest_generation);
    try t.expectEqual(r.Stage.idle, session.stage);
}
test "regulatory partial IO failure revokes submission and requires newer real reset epoch" {
    const bytes = clcFixture();
    const clc = try r.Clc.parse(&bytes, 0);
    for (0..5) |fail_at| {
        var replay: Replay = .{ .fail_at = fail_at };
        var mcu: m.Mcu = undefined;
        mcu.init(replay.channel());
        var session: r.Session = .{};
        try session.init(1);
        try t.expectError(error.InjectedIO, session.submit(&mcu, plan(clc)));
        try t.expectEqual(r.Stage.failed, session.stage);
        try t.expect(!session.isSubmitted(1, 1));
        var p = plan(clc);
        p.generation = 2;
        try t.expectError(error.RegulatoryResetRequired, session.submit(&mcu, p));
        try t.expectEqual(fail_at, replay.sent);
        try t.expectError(error.StaleDeviceEpoch, session.afterDeviceReset(1));
        try session.afterDeviceReset(2);
        try t.expectError(error.StaleDeviceEpoch, session.submit(&mcu, p));
        p.device_epoch = 2;
        p.generation = 1;
        try t.expectError(error.StalePolicyGeneration, session.submit(&mcu, p));
        p.generation = 2;
        replay.fail_at = null;
        mcu.init(replay.channel()); // model independently confirmed hardware reset
        try session.submit(&mcu, p);
        try t.expect(session.isSubmitted(2, 2));
    }
}
test "regulatory per-band eight-channel batches bound full policy and final flag" {
    var many_caps: [9]r.ChannelCapability = undefined;
    var many_limits: [9]r.ChannelLimit = undefined;
    var many_power: [9]r.PowerChannel = undefined;
    for (0..9) |i| {
        const number: u8 = @intCast(i + 1);
        many_caps[i] = .{ .band = .ghz2, .number = number, .max_power_mbm = 2000 };
        many_limits[i] = .{ .band = .ghz2, .number = number, .max_power_mbm = 1900 };
        many_power[i] = .{ .band = .ghz2, .number = number, .board_ceiling_mbm = 1800, .rates = @splat(30) };
    }
    const bytes = clcFixture();
    var p = plan(try r.Clc.parse(&bytes, 0));
    p.capabilities.channels = &many_caps;
    p.domain.channels = &many_limits;
    p.power = &many_power;
    var replay: Replay = .{};
    var mcu: m.Mcu = undefined;
    mcu.init(replay.channel());
    var session: r.Session = .{};
    try session.init(1);
    try session.submit(&mcu, p);
    try t.expectEqualSlices(u8, &.{ 0x5c, 0x5c, 0x0f, 0x5d, 0x5d }, replay.commands[0..5]);
    try t.expectEqual(@as(u8, 8), replay.counts[3]);
    try t.expectEqual(@as(u8, 1), replay.counts[4]);
    try t.expect(!replay.last[3] and replay.last[4]);
}
test "regulatory session pins owner rejects reinitialization and copied replay without IO" {
    const bytes = clcFixture();
    const clc = try r.Clc.parse(&bytes, 0);
    var replay: Replay = .{};
    var mcu: m.Mcu = undefined;
    mcu.init(replay.channel());
    var session: r.Session = .{};
    try t.expectError(error.SessionUninitialized, session.submit(&mcu, plan(clc)));
    try session.init(1);
    try session.submit(&mcu, plan(clc));
    var copy = session;
    try t.expect(!copy.isSubmitted(1, 1));
    var p = plan(clc);
    p.generation = 2;
    try t.expectError(error.MovedSession, copy.submit(&mcu, p));
    try t.expectError(error.MovedSession, copy.invalidate());
    try t.expectError(error.MovedSession, copy.afterDeviceReset(2));
    try t.expectError(error.SessionAlreadyInitialized, copy.init(2));
    try t.expectError(error.SessionAlreadyInitialized, session.init(2));
    try t.expectEqual(@as(u64, 1), session.highest_generation);
    try t.expectEqual(@as(usize, 5), replay.sent);
    try session.invalidate();
    try t.expect(!session.isSubmitted(1, 1) and !copy.isSubmitted(1, 1));
}
