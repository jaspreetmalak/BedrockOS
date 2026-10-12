const std = @import("std");
const p = @import("radio_policy.zig");
const r = @import("regulatory/root.zig");
const mt = @import("mediatek/root.zig");
const fw = mt.regulatory;
const wire = @import("mediatek/wire.zig");
fn cap(channel: u16) r.ChannelCap {
    return .{ .band = .ghz2, .channel = channel, .center_khz = r.centerKhz(.ghz2, channel) catch unreachable, .available_rx = true, .calibrated = true, .max_conducted_power_mbm = 1900, .antenna_gain_mbi = 300 };
}
fn canary(output: []const u8) !void {
    for (output) |b| try std.testing.expectEqual(@as(u8, 0xaa), b);
}
fn clcBytes() [26]u8 {
    var bytes: [26]u8 = @splat(0);
    wire.put32(&bytes, bytes.len);
    bytes[5] = 1;
    bytes[6] = 1;
    @memcpy(bytes[16..20], &[_]u8{ 'U', 'S', 0x11, 0x22 });
    wire.put16(bytes[20..], 4);
    @memcpy(bytes[22..], &[_]u8{ 1, 2, 3, 4 });
    return bytes;
}
const power = [_]fw.PowerChannel{.{ .band = .ghz2, .number = 1, .board_ceiling_mbm = 1800, .rates = @splat(36) }};
const board: fw.Board = .{ .encapsulation = 0, .acpi_conf = 0, .mtcl_conf = 0, .power_type = .default, .clc_event_supported = true };
const Capture = struct {
    count: usize = 0,
    commands: [4]u8 = @splat(0),
    domain_flags: u32 = 0,
    fail_at: usize = 0,
    authority: ?*p.Authority = null,
    denied_reentry: usize = 0,
    fn send(context: *anyopaque, queue: mt.mcu.Queue, packet: []const u8) !void {
        const self: *Capture = @ptrCast(@alignCast(context));
        if (queue != .wm or packet.len < mt.mcu.tx_header_size or self.count >= self.commands.len) return error.UnexpectedPacket;
        self.commands[self.count] = packet[36];
        self.count += 1;
        if (packet[36] == fw.domain_command) self.domain_flags = wire.le32(packet[mt.mcu.tx_header_size + 16 ..]);
        if (self.authority) |authority| {
            _ = authority.select(.{ 'G', 'B' }, .indoor) catch |err| {
                if (err != error.PolicyBusy) return err;
                self.denied_reentry += 1;
                if (self.fail_at == self.count) return error.DmaTimeout;
                return;
            };
            return error.ReentrantPolicyChanged;
        }
        if (self.fail_at == self.count) return error.DmaTimeout;
    }
    fn receive(_: *anyopaque, _: []u8) !?usize {
        return null;
    }
    fn delay(_: *anyopaque, _: u32) !void {}
    fn channel(self: *Capture) mt.mcu.Channel {
        return .{ .context = self, .submit = send, .receive = receive, .delayUs = delay };
    }
};

test "country authority defaults to passive world and copies hardware constraints" {
    var source = [_]r.ChannelCap{cap(1)};
    var authority: p.Authority = .{};
    try authority.init(1, &source);
    const world = try authority.snapshot();
    const passive = try authority.decision(world.generation, .{ .band = .ghz2, .channel = 1 });
    try std.testing.expect(passive.allow_passive_scan and !passive.allow_initiate_tx and !world.firmware_submitted);
    source[0].max_conducted_power_mbm = 5000;
    const generation = try authority.select(.{ 'U', 'S' }, .indoor);
    const selected = try authority.decision(generation, .{ .band = .ghz2, .channel = 1 });
    try std.testing.expect(selected.allow_initiate_tx);
    try std.testing.expectEqual(@as(?i32, 1900), selected.max_conducted_power_mbm);
    try std.testing.expectError(error.StalePolicyGeneration, authority.decision(world.generation, .{ .band = .ghz2, .channel = 1 }));
    try std.testing.expectError(error.UnknownCountry, authority.select(.{ 'Z', 'Z' }, .indoor));
    try std.testing.expectEqual(generation, (try authority.snapshot()).generation);
}
test "world active scan and country-forbidden channels reject before output writes" {
    var authority: p.Authority = .{};
    try authority.init(1, &.{ cap(1), cap(13) });
    var output: [mt.scan.request_size]u8 = @splat(0xaa);
    const ch1 = [_]mt.scan.Channel{.{ .band = .ghz2, .number = 1 }};
    var request: mt.scan.Options = .{ .sequence = 1, .active = true, .channels = &ch1 };
    try std.testing.expectError(error.TransmissionDenied, authority.encodeScan(1, request, &output));
    try canary(&output);
    request.active = false;
    _ = try authority.encodeScan(1, request, &output);
    try std.testing.expectEqual(@as(u8, 0), output[2]);
    const generation = try authority.select(.{ 'U', 'S' }, .indoor);
    request.active = true;
    request.channels = &.{ .{ .band = .ghz2, .number = 1 }, .{ .band = .ghz2, .number = 13 } };
    @memset(&output, 0xaa);
    try std.testing.expectError(error.ChannelDenied, authority.encodeScan(generation, request, &output));
    try canary(&output);
}
test "TX candidates require current country and proven calibrated power" {
    var authority: p.Authority = .{};
    try authority.init(1, &.{cap(1)});
    var frame: [24]u8 = @splat(0);
    frame[4] = 2;
    var output: [64]u8 = @splat(0xaa);
    const channel: r.Request = .{ .band = .ghz2, .channel = 1 };
    try std.testing.expectError(error.TransmissionDenied, authority.encodeTransmit(1, channel, &frame, 0x1000, .{ .token = 1, .wlan_index = 0, .fixed_rate = 0 }, &output));
    try canary(&output);
    const generation = try authority.select(.{ 'U', 'S' }, .indoor);
    _ = try authority.encodeTransmit(generation, channel, &frame, 0x1000, .{ .token = 1, .wlan_index = 0, .fixed_rate = 0 }, &output);
    var uncertain = cap(1);
    uncertain.antenna_gain_mbi = null;
    var second: p.Authority = .{};
    try second.init(1, &.{uncertain});
    const other = try second.select(.{ 'U', 'S' }, .indoor);
    @memset(&output, 0xaa);
    try std.testing.expectError(error.TransmissionDenied, second.encodeTransmit(other, channel, &frame, 0x1000, .{ .token = 1, .wlan_index = 0, .fixed_rate = 0 }, &output));
    try canary(&output);
}
test "real firmware policy framing uses selected ceilings and rejects reentrant region changes" {
    var authority: p.Authority = .{};
    try authority.init(1, &.{cap(1)});
    const generation = try authority.select(.{ 'U', 'S' }, .indoor);
    var capture: Capture = .{ .authority = &authority };
    var mcu: mt.Mcu = undefined;
    mcu.init(capture.channel());
    const bytes = clcBytes();
    const clc = try fw.Clc.parse(&bytes, 0);
    try authority.submit(generation, &mcu, .{ .clc = clc, .board = board, .power = &power });
    try std.testing.expectEqual(@as(usize, 3), capture.count);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x5c, 0x0f, 0x5d }, capture.commands[0..3]);
    try std.testing.expectEqual(@as(usize, 3), capture.denied_reentry);
    try std.testing.expect(capture.domain_flags & 2 == 0);
    try std.testing.expect((try authority.snapshot()).firmware_submitted);
    try std.testing.expectError(error.PolicyNeedsQuiescence, authority.select(.{ 'G', 'B' }, .indoor));
    try authority.invalidateAfterQuiescence(1, generation);
    try std.testing.expectError(error.PolicyUnavailable, authority.snapshot());
    try std.testing.expect((try authority.select(.{ 'G', 'B' }, .indoor)) > generation);
}
test "unproven or excessive rate-power data performs no MCU work" {
    var cap_without_power = cap(1);
    cap_without_power.max_conducted_power_mbm = null;
    var authority: p.Authority = .{};
    try authority.init(1, &.{cap_without_power});
    const generation = try authority.select(.{ 'U', 'S' }, .indoor);
    var capture: Capture = .{};
    var mcu: mt.Mcu = undefined;
    mcu.init(capture.channel());
    const bytes = clcBytes();
    const clc = try fw.Clc.parse(&bytes, 0);
    try std.testing.expectError(error.MissingPowerCalibration, authority.submit(generation, &mcu, .{ .clc = clc, .board = board, .power = &power }));
    try std.testing.expectEqual(@as(usize, 0), capture.count);
    var other: p.Authority = .{};
    try other.init(1, &.{cap(1)});
    const selected = try other.select(.{ 'U', 'S' }, .indoor);
    var excessive = power;
    excessive[0].rates[160] = 37; // actual board ceiling is36 half-dBm
    try std.testing.expectError(error.RatePowerExceedsPolicy, other.submit(selected, &mcu, .{ .clc = clc, .board = board, .power = &excessive }));
    try std.testing.expectEqual(@as(usize, 0), capture.count);
    try std.testing.expectEqual(@as(u64, 0), other.firmware.highest_generation);
}
test "partial firmware submission quarantines candidates until a newer actual reset epoch" {
    var authority: p.Authority = .{};
    try authority.init(1, &.{cap(1)});
    const generation = try authority.select(.{ 'U', 'S' }, .indoor);
    var capture: Capture = .{ .fail_at = 2 };
    var mcu: mt.Mcu = undefined;
    mcu.init(capture.channel());
    const bytes = clcBytes();
    const clc = try fw.Clc.parse(&bytes, 0);
    try std.testing.expectError(error.DmaTimeout, authority.submit(generation, &mcu, .{ .clc = clc, .board = board, .power = &power }));
    try std.testing.expectError(error.DeviceResetRequired, authority.decision(generation, .{ .band = .ghz2, .channel = 1 }));
    try std.testing.expectError(error.DeviceResetRequired, authority.select(.{ 'G', 'B' }, .indoor));
    try std.testing.expectError(error.StaleDeviceEpoch, authority.afterDeviceReset(1, &.{cap(1)}));
    try authority.afterDeviceReset(2, &.{cap(1)});
    const fresh = try authority.snapshot();
    try std.testing.expect(fresh.generation > generation and fresh.device_epoch == 2 and !fresh.firmware_submitted);
    try std.testing.expect(!(try authority.decision(fresh.generation, .{ .band = .ghz2, .channel = 1 })).allow_initiate_tx);
}
test "policy owner copies and exhausted generations cannot create fresh authority" {
    var authority: p.Authority = .{};
    try authority.init(1, &.{cap(1)});
    var copy = authority;
    try std.testing.expectError(error.MovedPolicyAuthority, copy.snapshot());
    try std.testing.expectError(error.MovedPolicyAuthority, copy.select(.{ 'U', 'S' }, .indoor));
    try std.testing.expectError(error.PolicyAlreadyInitialized, authority.init(1, &.{cap(1)}));
    authority.generation = std.math.maxInt(u64);
    try std.testing.expectError(error.PolicyGenerationExhausted, authority.select(.{ 'U', 'S' }, .indoor));
    try std.testing.expectError(error.PolicyUnavailable, authority.snapshot());
}
test "self-staged capability aliases reject without clobbering validated records" {
    var authority: p.Authority = .{};
    authority.caps[0] = cap(1);
    try std.testing.expectError(error.AliasedCapabilities, authority.init(1, authority.caps[0..1]));
    try std.testing.expectEqual(@as(usize, 0), authority.owner_address);
    try std.testing.expectEqual(@as(u16, 1), authority.caps[0].channel);
    try authority.init(1, &.{cap(1)});
    try std.testing.expectError(error.AliasedCapabilities, authority.afterDeviceReset(2, authority.caps[0..1]));
    try std.testing.expectEqual(@as(u16, 1), authority.caps[0].channel);
    try std.testing.expectError(error.PolicyUnavailable, authority.snapshot());
    try authority.afterDeviceReset(2, &.{cap(1)}); // Retry the incomplete same reset, no epoch reuse.
    try std.testing.expectEqual(@as(u64, 2), (try authority.snapshot()).device_epoch);
}
test "new physical reset with invalid replacement retires every pre-reset permission" {
    var authority: p.Authority = .{};
    try authority.init(1, &.{cap(1)});
    const old = try authority.select(.{ 'U', 'S' }, .indoor);
    var malformed = cap(1);
    malformed.center_khz += 1;
    try std.testing.expectError(error.InvalidCapabilities, authority.afterDeviceReset(2, &.{malformed}));
    try std.testing.expectError(error.DeviceResetRequired, authority.select(.{ 'U', 'S' }, .indoor));
    try std.testing.expectError(error.PolicyUnavailable, authority.decision(old, .{ .band = .ghz2, .channel = 1 }));
    var output: [mt.scan.request_size]u8 = @splat(0xaa);
    try std.testing.expectError(error.PolicyUnavailable, authority.encodeScan(old, .{ .sequence = 1, .channels = &.{.{ .band = .ghz2, .number = 1 }} }, &output));
    try canary(&output);
    try authority.afterDeviceReset(2, &.{cap(1)});
    try std.testing.expect((try authority.snapshot()).generation > old);
    authority.generation = std.math.maxInt(u64);
    try std.testing.expectError(error.PolicyGenerationExhausted, authority.afterDeviceReset(3, &.{cap(1)}));
    try std.testing.expectError(error.PolicyUnavailable, authority.snapshot());
}
test "scan/TX output cannot overwrite retained authority or its own validated inputs" {
    var authority: p.Authority = .{};
    try authority.init(1, &.{cap(1)});
    const generation = try authority.select(.{ 'U', 'S' }, .indoor);
    const owned = std.mem.asBytes(&authority.caps[0]);
    try std.testing.expectError(error.AliasedOutput, authority.encodeScan(generation, .{ .sequence = 1, .channels = &.{.{ .band = .ghz2, .number = 1 }} }, owned));
    try std.testing.expectEqual(@as(u16, 1), authority.caps[0].channel);
    var packet: [mt.scan.request_size]u8 align(@alignOf(mt.scan.Channel)) = @splat(0xaa);
    const channels: *[1]mt.scan.Channel = @ptrCast(@alignCast(&packet));
    channels.* = .{.{ .band = .ghz2, .number = 1 }};
    try std.testing.expectError(error.AliasedOutput, authority.encodeScan(generation, .{ .sequence = 1, .channels = channels }, &packet));
    try std.testing.expectEqual(@as(u8, 1), channels[0].number);
    var frame: [64]u8 = @splat(0);
    frame[4] = 2;
    try std.testing.expectError(error.AliasedOutput, authority.encodeTransmit(generation, .{ .band = .ghz2, .channel = 1 }, frame[0..24], 0x1000, .{ .token = 1, .wlan_index = 0, .fixed_rate = 0 }, &frame));
    try std.testing.expectEqual(@as(u8, 2), frame[4]);
}
