const std = @import("std");
const core = @import("root.zig");
const local_mac = [6]u8{ 2, 0, 0, 0, 0, 15 };
const remote_mac = [6]u8{ 2, 0, 0, 0, 0, 2 };
const remote: core.Endpoint = .{ .address = .{ .bytes = .{ 10, 0, 2, 2 } }, .port = 32123 };
const Capture = struct {
    frame: [core.max_frame]u8 = @splat(0),
    length: usize = 0,
    fail: bool = false,
    fn transmit(context: *anyopaque, bytes: []const u8) !void {
        const self: *Capture = @ptrCast(@alignCast(context));
        if (self.fail) return error.WouldBlock;
        @memcpy(self.frame[0..bytes.len], bytes);
        self.length = bytes.len;
    }
};
fn init(stack: *core.Stack, capture: *Capture) !u64 {
    try stack.init(.{ .mac = local_mac }, .{ .context = capture, .send = Capture.transmit });
    return stack.open(remote);
}
fn put(bytes: []u8, value: u16) void {
    bytes[0] = @truncate(value >> 8);
    bytes[1] = @truncate(value);
}
fn checksum(bytes: []const u8, initial: u32) u16 {
    var total = initial;
    for (0..(bytes.len + 1) / 2) |index| total += (@as(u32, bytes[index * 2]) << 8) | (if (index * 2 + 1 < bytes.len) @as(u32, bytes[index * 2 + 1]) else 0);
    while (total > 65535) total = (total & 65535) + (total >> 16);
    return ~@as(u16, @intCast(total));
}
fn arp() [60]u8 {
    var frame: [60]u8 = @splat(0);
    @memcpy(frame[0..6], &local_mac);
    @memcpy(frame[6..12], &remote_mac);
    put(frame[12..14], 0x0806);
    put(frame[14..16], 1);
    put(frame[16..18], 0x0800);
    frame[18] = 6;
    frame[19] = 4;
    put(frame[20..22], 2);
    @memcpy(frame[22..28], &remote_mac);
    @memcpy(frame[28..32], &remote.address.bytes);
    @memcpy(frame[32..38], &local_mac);
    frame[38..42].* = .{ 10, 0, 2, 15 };
    return frame;
}
fn incoming(capture: *Capture) []u8 {
    @memcpy(capture.frame[0..6], &local_mac);
    @memcpy(capture.frame[6..12], &remote_mac);
    capture.frame[26..30].* = remote.address.bytes;
    capture.frame[30..34].* = .{ 10, 0, 2, 15 };
    const a = capture.frame[34];
    const b = capture.frame[35];
    capture.frame[34..36].* = capture.frame[36..38].*;
    capture.frame[36] = a;
    capture.frame[37] = b;
    repair(&capture.frame);
    return capture.frame[0..capture.length];
}
fn repair(frame: []u8) void {
    frame[24..26].* = .{ 0, 0 };
    put(frame[24..26], checksum(frame[14..34], 0));
    const length = (@as(usize, frame[38]) << 8) | frame[39];
    frame[40..42].* = .{ 0, 0 };
    const pseudo: u32 = @as(u32, 0xffff - checksum(frame[26..34], 0)) + 17 + @as(u32, @intCast(length));
    const value = checksum(frame[34..][0..length], pseudo);
    put(frame[40..42], if (value == 0) 65535 else value);
}
test "ARP resolution precedes checksummed connected UDP including odd and empty data" {
    var stack: core.Stack = .{};
    var capture: Capture = .{};
    const id = try init(&stack, &capture);
    try std.testing.expectError(error.WouldBlock, stack.send(id, "odd"));
    try std.testing.expectEqual(@as(u8, 6), capture.frame[13]);
    stack.ingest(&arp());
    try std.testing.expectEqual(@as(usize, 3), try stack.send(id, "odd"));
    try std.testing.expectEqual(@as(u16, 0), checksum(capture.frame[14..34], 0));
    stack.ingest(incoming(&capture));
    var output: [256]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 3), try stack.receive(id, &output));
    try std.testing.expectEqualStrings("odd", output[0..3]);
    try std.testing.expectEqual(@as(usize, 0), try stack.send(id, ""));
    stack.ingest(incoming(&capture));
    try std.testing.expectEqual(@as(usize, 0), try stack.receive(id, &.{}));
    try std.testing.expectError(error.WouldBlock, stack.receive(id, &output));
}
test "short receive and transmit rejection preserve endpoint and datagram" {
    var stack: core.Stack = .{};
    var capture: Capture = .{};
    const id = try init(&stack, &capture);
    stack.ingest(&arp());
    _ = try stack.send(id, "keep");
    stack.ingest(incoming(&capture));
    var short = [_]u8{ 0x55, 0x55 };
    try std.testing.expectError(error.BufferTooSmall, stack.receive(id, &short));
    try std.testing.expectEqual(@as(?usize, 4), try stack.peek(id));
    try std.testing.expectEqualSlices(u8, &.{ 0x55, 0x55 }, &short);
    var large: [257]u8 = @splat(1);
    try std.testing.expectError(error.MessageTooLarge, stack.send(id, &large));
    capture.fail = true;
    try std.testing.expectError(error.WouldBlock, stack.send(id, "new"));
    var output: [256]u8 = undefined;
    _ = try stack.receive(id, &output);
    try std.testing.expectEqualStrings("keep", output[0..4]);
}
test "malformed checksums options fragments lengths and tuple mismatch are isolated drops" {
    var stack: core.Stack = .{};
    var capture: Capture = .{};
    const id = try init(&stack, &capture);
    stack.ingest(&arp());
    _ = try stack.send(id, "proof");
    _ = incoming(&capture);
    const original = capture.frame;
    for (0..8) |case| {
        capture.frame = original;
        switch (case) {
            0 => capture.frame[24] ^= 1,
            1 => capture.frame[42] ^= 1,
            2 => {
                capture.frame[14] = 0x46;
                repair(&capture.frame);
            },
            3 => {
                capture.frame[20] |= 0x20;
                repair(&capture.frame);
            },
            4 => {
                capture.frame[16..18].* = .{ 0xff, 0xff };
            },
            5 => {
                capture.frame[34..36].* = .{ 0, 1 };
                repair(&capture.frame);
            },
            6 => {
                capture.frame[26] = 224;
                repair(&capture.frame);
            },
            7 => {
                capture.frame[22] = 0;
                repair(&capture.frame);
            },
            else => unreachable,
        }
        stack.ingest(capture.frame[0..capture.length]);
        try std.testing.expectEqual(@as(?usize, null), try stack.peek(id));
    }
    for (0..42) |length| stack.ingest(original[0..length]);
    try std.testing.expect(stack.counters.malformed > 0);
    try std.testing.expect(stack.counters.unmatched > 0);
}
test "bounded FIFO drops newest and close clears storage while generations and ports never revive" {
    var stack: core.Stack = .{};
    var capture: Capture = .{};
    const id = try init(&stack, &capture);
    stack.ingest(&arp());
    for (0..5) |index| {
        const data = [_]u8{@intCast(index)};
        _ = try stack.send(id, &data);
        stack.ingest(incoming(&capture));
    }
    try std.testing.expectEqual(@as(u64, 1), stack.counters.queue_full);
    var output: [1]u8 = undefined;
    for (0..4) |index| {
        _ = try stack.receive(id, &output);
        try std.testing.expectEqual(@as(u8, @intCast(index)), output[0]);
    }
    _ = try stack.send(id, "secret");
    stack.ingest(incoming(&capture));
    const old_port = stack.slots[0].port;
    try stack.close(id);
    for (stack.slots[0].messages) |message| for (message.bytes) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    const replacement = try stack.open(remote);
    try std.testing.expect(id != replacement);
    try std.testing.expect(stack.slots[0].port > old_port);
    stack.ingest(capture.frame[0..capture.length]);
    try std.testing.expectEqual(@as(?usize, null), try stack.peek(replacement));
    try std.testing.expectError(error.StaleEndpoint, stack.close(id));
}
test "capacity configuration destination and port exhaustion reject before allocation" {
    var stack: core.Stack = .{};
    var capture: Capture = .{};
    const id = try init(&stack, &capture);
    const before = stack.next_port;
    for ([_][4]u8{ .{ 0, 0, 0, 0 }, .{ 127, 0, 0, 1 }, .{ 224, 0, 0, 1 }, .{ 255, 255, 255, 255 }, .{ 10, 0, 2, 255 }, .{ 10, 0, 2, 0 } }) |address|
        try std.testing.expectError(error.InvalidEndpoint, stack.open(.{ .address = .{ .bytes = address }, .port = 1 }));
    try std.testing.expectEqual(before, stack.next_port);
    for (1..core.endpoint_capacity) |_| _ = try stack.open(remote);
    try std.testing.expectError(error.EndpointCapacity, stack.open(remote));
    try stack.close(id);
    stack.next_port = 65536;
    try std.testing.expectError(error.PortExhausted, stack.open(remote));
    try std.testing.expectError(error.InvalidEndpointIdentity, stack.close(0));
    var rejected: core.Stack = .{};
    try std.testing.expectError(error.InvalidConfiguration, rejected.init(.{ .mac = @splat(0) }, .{ .context = &capture, .send = Capture.transmit }));
    try std.testing.expect(!rejected.initialized);
}

test "ARP validates sender shape and off-subnet UDP uses the configured gateway" {
    var stack: core.Stack = .{};
    var capture: Capture = .{};
    const id = try init(&stack, &capture);
    var malformed = arp();
    malformed[22] ^= 2;
    stack.ingest(&malformed);
    try std.testing.expectError(error.WouldBlock, stack.send(id, "unresolved"));
    malformed = arp();
    malformed[18] = 5;
    stack.ingest(&malformed);
    try std.testing.expectError(error.WouldBlock, stack.send(id, "unresolved"));
    stack.ingest(&arp());
    const external = try stack.open(.{ .address = .{ .bytes = .{ 1, 1, 1, 1 } }, .port = 123 });
    _ = try stack.send(external, "route");
    try std.testing.expectEqualSlices(u8, &remote_mac, capture.frame[0..6]);
    try std.testing.expectEqualSlices(u8, &.{ 1, 1, 1, 1 }, capture.frame[30..34]);
}

test "endpoint generation exhaustion retires its slot and stale identity cannot close another" {
    var stack: core.Stack = .{};
    var capture: Capture = .{};
    const original = try init(&stack, &capture);
    stack.slots[0].generation = std.math.maxInt(u32);
    const last = (@as(u64, std.math.maxInt(u32)) << 32) | 1;
    try stack.close(last);
    try std.testing.expect(stack.slots[0].retired);
    const replacement = try stack.open(remote);
    try std.testing.expectEqual(@as(u64, 2), replacement & 0xffff_ffff);
    try std.testing.expectError(error.StaleEndpoint, stack.close(original));
    try std.testing.expectEqual(@as(usize, 1), stack.liveCount());
}

test "IPv4 UDP permits an absent checksum while rejecting an incorrect nonzero checksum" {
    var stack: core.Stack = .{};
    var capture: Capture = .{};
    const id = try init(&stack, &capture);
    stack.ingest(&arp());
    _ = try stack.send(id, "optional checksum");
    try std.testing.expect(capture.frame[40] != 0 or capture.frame[41] != 0);
    const packet = incoming(&capture);
    capture.frame[40..42].* = .{ 0, 0 };
    stack.ingest(packet);
    var output: [256]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 17), try stack.receive(id, &output));
    try std.testing.expectEqualStrings("optional checksum", output[0..17]);
    capture.frame[40..42].* = .{ 0, 1 };
    stack.ingest(packet);
    try std.testing.expectEqual(@as(?usize, null), try stack.peek(id));
    try std.testing.expectEqual(@as(u64, 1), stack.counters.malformed);
}

test "wrong unicast peer and local Ethernet or IPv4 destination never enter a connected queue" {
    var stack: core.Stack = .{};
    var capture: Capture = .{};
    const id = try init(&stack, &capture);
    stack.ingest(&arp());
    _ = try stack.send(id, "tuple");
    _ = incoming(&capture);
    const original = capture.frame;
    for (0..3) |case| {
        capture.frame = original;
        switch (case) {
            0 => capture.frame[29] = 3,
            1 => capture.frame[5] = 14,
            2 => capture.frame[33] = 14,
            else => unreachable,
        }
        repair(&capture.frame);
        stack.ingest(capture.frame[0..capture.length]);
        try std.testing.expectEqual(@as(?usize, null), try stack.peek(id));
    }
    try std.testing.expectEqual(@as(u64, 1), stack.counters.unmatched);
    try std.testing.expectEqual(@as(u64, 2), stack.counters.malformed);
}
