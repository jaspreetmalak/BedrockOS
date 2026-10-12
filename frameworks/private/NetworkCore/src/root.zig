//! Trusted, bounded connected IPv4/UDP stack. Callers serialize every operation.
const std = @import("std");
pub const networkkit = @import("networkkit");
pub const wifi = @import("wifi.zig");
pub const wifi_test_radio = @import("wifi_test_radio.zig");
pub const IPv4 = networkkit.IPv4;
pub const Endpoint = networkkit.Endpoint;
pub const max_datagram = networkkit.max_datagram;
pub const max_frame = 1514;
pub const endpoint_capacity = 8;
pub const queue_capacity = 4;
pub const Error = error{ NotInitialized, AlreadyInitialized, InvalidConfiguration, InvalidEndpoint, EndpointCapacity, PortExhausted, InvalidEndpointIdentity, StaleEndpoint, MessageTooLarge, BufferTooSmall, WouldBlock, NetworkUnavailable, MalformedPacket };
pub const Transport = struct { context: *anyopaque, send: *const fn (*anyopaque, []const u8) anyerror!void };
pub const Config = struct {
    mac: [6]u8,
    address: IPv4 = .{ .bytes = .{ 10, 0, 2, 15 } },
    prefix: u8 = 24,
    gateway: IPv4 = .{ .bytes = .{ 10, 0, 2, 2 } },
};
pub const Counters = struct { received: u64 = 0, transmitted: u64 = 0, malformed: u64 = 0, unmatched: u64 = 0, queue_full: u64 = 0, arp_requests: u64 = 0 };
const Datagram = struct { length: usize = 0, bytes: [max_datagram]u8 = @splat(0) };
const Slot = struct {
    generation: u32 = 1,
    retired: bool = false,
    live: bool = false,
    peer: Endpoint = undefined,
    port: u16 = 0,
    head: usize = 0,
    count: usize = 0,
    messages: [queue_capacity]Datagram = @splat(.{}),
};
const Neighbor = struct { valid: bool = false, address: IPv4 = .{ .bytes = @splat(0) }, mac: [6]u8 = @splat(0) };

pub const Stack = struct {
    config: Config = undefined,
    transport: Transport = undefined,
    initialized: bool = false,
    next_port: u32 = 49152,
    slots: [endpoint_capacity]Slot = @splat(.{}),
    neighbors: [4]Neighbor = @splat(.{}),
    neighbor_cursor: usize = 0,
    counters: Counters = .{},

    pub fn init(self: *Stack, config: Config, transport: Transport) Error!void {
        if (self.initialized) return error.AlreadyInitialized;
        if (!unicastMac(config.mac) or config.prefix == 0 or config.prefix > 30 or !unicast(config.address) or !unicast(config.gateway) or config.address.eql(config.gateway))
            return error.InvalidConfiguration;
        const mask = prefixMask(config.prefix);
        if (ipNumber(config.address) & mask != ipNumber(config.gateway) & mask or
            ipNumber(config.address) & ~mask == 0 or ipNumber(config.address) & ~mask == ~mask or
            ipNumber(config.gateway) & ~mask == 0 or ipNumber(config.gateway) & ~mask == ~mask)
            return error.InvalidConfiguration;
        self.config = config;
        self.transport = transport;
        self.initialized = true;
    }

    pub fn open(self: *Stack, peer: Endpoint) !u64 {
        try self.ready();
        try peer.validate();
        if (!unicast(peer.address) or peer.address.eql(self.config.address)) return error.InvalidEndpoint;
        const mask = prefixMask(self.config.prefix);
        if (ipNumber(peer.address) & mask == ipNumber(self.config.address) & mask and
            (ipNumber(peer.address) & ~mask == 0 or ipNumber(peer.address) & ~mask == ~mask)) return error.InvalidEndpoint;
        if (self.next_port > 65535) return error.PortExhausted;
        for (&self.slots, 0..) |*slot, index| {
            if (slot.live or slot.retired) continue;
            slot.peer = peer;
            slot.port = @intCast(self.next_port);
            self.next_port += 1; // Never reuse a local tuple within this boot.
            slot.live = true;
            return (@as(u64, slot.generation) << 32) | (index + 1);
        }
        return error.EndpointCapacity;
    }

    pub fn send(self: *Stack, id: u64, bytes: []const u8) !usize {
        const index = try self.slotIndex(id);
        if (bytes.len > max_datagram) return error.MessageTooLarge;
        const slot = &self.slots[index];
        const next_hop = self.route(slot.peer.address);
        const mac = self.lookupNeighbor(next_hop) orelse {
            try self.sendArp(next_hop, null);
            self.counters.arp_requests +|= 1;
            return error.WouldBlock;
        };
        var frame: [max_frame]u8 = @splat(0);
        ethernet(&frame, mac, self.config.mac, 0x0800);
        const size = encodeUdp(frame[14..], self.config.address, slot.peer.address, slot.port, slot.peer.port, bytes);
        try self.transport.send(self.transport.context, frame[0..@max(60, 14 + size)]);
        self.counters.transmitted +|= 1;
        return bytes.len;
    }

    pub fn peek(self: *const Stack, id: u64) Error!?usize {
        const slot = &self.slots[try self.slotIndex(id)];
        return if (slot.count == 0) null else slot.messages[slot.head].length;
    }
    /// Short buffers never consume a datagram; empty datagrams return zero.
    pub fn receive(self: *Stack, id: u64, output: []u8) Error!usize {
        const slot = &self.slots[try self.slotIndex(id)];
        if (output.len > max_datagram) return error.MessageTooLarge;
        if (slot.count == 0) return error.WouldBlock;
        const message = &slot.messages[slot.head];
        if (output.len < message.length) return error.BufferTooSmall;
        const length = message.length;
        @memcpy(output[0..length], message.bytes[0..length]);
        wipe(&message.bytes);
        message.length = 0;
        slot.head = (slot.head + 1) % queue_capacity;
        slot.count -= 1;
        return length;
    }
    pub fn close(self: *Stack, id: u64) Error!void {
        const slot = &self.slots[try self.slotIndex(id)];
        for (&slot.messages) |*message| wipe(&message.bytes);
        const generation = slot.generation;
        slot.* = if (generation == std.math.maxInt(u32)) .{ .generation = generation, .retired = true } else .{ .generation = generation + 1 };
    }
    pub fn liveCount(self: *const Stack) usize {
        var count: usize = 0;
        for (self.slots) |slot| count += @intFromBool(slot.live);
        return count;
    }
    /// Network input is untrusted. Invalid/unsupported/full traffic is dropped.
    pub fn ingest(self: *Stack, frame: []const u8) void {
        if (!self.initialized) return;
        self.parse(frame) catch {
            self.counters.malformed +|= 1;
        };
    }
    fn parse(self: *Stack, frame: []const u8) !void {
        if (frame.len < 14 or frame.len > max_frame or !unicastMac(frame[6..12].*)) return error.MalformedPacket;
        const destination = frame[0..6].*;
        const protocol = get16(frame[12..14]);
        if (protocol == 0x0806) {
            if (!std.mem.eql(u8, &destination, &self.config.mac) and !std.mem.eql(u8, &destination, &broadcast)) return error.MalformedPacket;
            return self.arp(frame);
        }
        if (protocol != 0x0800 or !std.mem.eql(u8, &destination, &self.config.mac)) return error.MalformedPacket;
        const packet = try decodeUdp(frame[14..]);
        if (!packet.destination.eql(self.config.address)) return error.MalformedPacket;
        for (&self.slots) |*slot| {
            if (!slot.live or slot.port != packet.destination_port or slot.peer.port != packet.source_port or !slot.peer.address.eql(packet.source)) continue;
            if (slot.count == queue_capacity) {
                self.counters.queue_full +|= 1;
                return;
            }
            const message = &slot.messages[(slot.head + slot.count) % queue_capacity];
            @memcpy(message.bytes[0..packet.bytes.len], packet.bytes);
            message.length = packet.bytes.len;
            slot.count += 1;
            self.counters.received +|= 1;
            return;
        }
        self.counters.unmatched +|= 1;
    }
    fn arp(self: *Stack, frame: []const u8) !void {
        if (frame.len < 42) return error.MalformedPacket;
        const bytes = frame[14..42];
        const op = get16(bytes[6..8]);
        if (get16(bytes[0..2]) != 1 or get16(bytes[2..4]) != 0x0800 or bytes[4] != 6 or bytes[5] != 4 or (op != 1 and op != 2)) return error.MalformedPacket;
        const sender_mac = bytes[8..14].*;
        const sender: IPv4 = .{ .bytes = bytes[14..18].* };
        const target: IPv4 = .{ .bytes = bytes[24..28].* };
        if (!std.mem.eql(u8, &sender_mac, frame[6..12]) or !unicastMac(sender_mac) or !unicast(sender) or !target.eql(self.config.address)) return error.MalformedPacket;
        if (op == 2 and !std.mem.eql(u8, bytes[18..24], &self.config.mac)) return error.MalformedPacket;
        var wanted = sender.eql(self.config.gateway);
        for (self.slots) |slot| if (slot.live and self.route(slot.peer.address).eql(sender)) {
            wanted = true;
        };
        if (!wanted) return;
        const neighbor = self.lookupNeighbor(sender);
        if (neighbor == null) {
            self.neighbors[self.neighbor_cursor] = .{ .valid = true, .address = sender, .mac = sender_mac };
            self.neighbor_cursor = (self.neighbor_cursor + 1) % self.neighbors.len;
        } else for (&self.neighbors) |*record| if (record.valid and record.address.eql(sender)) {
            record.mac = sender_mac;
        };
        if (op == 1) self.sendArp(sender, sender_mac) catch {};
    }
    fn sendArp(self: *Stack, target: IPv4, target_mac: ?[6]u8) !void {
        var frame: [60]u8 = @splat(0);
        ethernet(&frame, target_mac orelse broadcast, self.config.mac, 0x0806);
        const bytes = frame[14..42];
        put16(bytes[0..2], 1);
        put16(bytes[2..4], 0x0800);
        bytes[4] = 6;
        bytes[5] = 4;
        put16(bytes[6..8], if (target_mac != null) 2 else 1);
        @memcpy(bytes[8..14], &self.config.mac);
        @memcpy(bytes[14..18], &self.config.address.bytes);
        if (target_mac) |mac| @memcpy(bytes[18..24], &mac);
        @memcpy(bytes[24..28], &target.bytes);
        try self.transport.send(self.transport.context, &frame);
    }
    fn route(self: *const Stack, peer: IPv4) IPv4 {
        const mask = prefixMask(self.config.prefix);
        return if (ipNumber(peer) & mask == ipNumber(self.config.address) & mask) peer else self.config.gateway;
    }
    fn lookupNeighbor(self: *const Stack, address: IPv4) ?[6]u8 {
        for (self.neighbors) |neighbor| if (neighbor.valid and neighbor.address.eql(address)) return neighbor.mac;
        return null;
    }
    fn ready(self: *const Stack) Error!void {
        if (!self.initialized) return error.NotInitialized;
    }
    fn slotIndex(self: *const Stack, id: u64) Error!usize {
        try self.ready();
        const position: u32 = @truncate(id);
        const generation: u32 = @intCast(id >> 32);
        if (position == 0 or position > self.slots.len or generation == 0) return error.InvalidEndpointIdentity;
        const index = position - 1;
        const slot = &self.slots[index];
        if (!slot.live or slot.retired or slot.generation != generation) return error.StaleEndpoint;
        return index;
    }
};
const broadcast: [6]u8 = @splat(255);
fn unicastMac(mac: [6]u8) bool {
    return mac[0] & 1 == 0 and !std.mem.eql(u8, &mac, &@as([6]u8, @splat(0)));
}
fn unicast(ip: IPv4) bool {
    return ip.bytes[0] != 0 and ip.bytes[0] != 127 and ip.bytes[0] < 224;
}
fn ipNumber(ip: IPv4) u32 {
    return (@as(u32, ip.bytes[0]) << 24) | (@as(u32, ip.bytes[1]) << 16) | (@as(u32, ip.bytes[2]) << 8) | ip.bytes[3];
}
fn prefixMask(prefix: u8) u32 {
    return @as(u32, std.math.maxInt(u32)) << @as(u5, @intCast(32 - @as(u32, prefix)));
}
fn ethernet(output: []u8, destination: [6]u8, source: [6]u8, protocol: u16) void {
    @memcpy(output[0..6], &destination);
    @memcpy(output[6..12], &source);
    put16(output[12..14], protocol);
}
fn get16(bytes: []const u8) u16 {
    return (@as(u16, bytes[0]) << 8) | bytes[1];
}
fn put16(bytes: []u8, number: u16) void {
    bytes[0] = @truncate(number >> 8);
    bytes[1] = @truncate(number);
}
fn sum(bytes: []const u8) u32 {
    var result: u32 = 0;
    var index: usize = 0;
    while (index + 1 < bytes.len) : (index += 2) result += get16(bytes[index..][0..2]);
    if (index < bytes.len) result += @as(u32, bytes[index]) << 8;
    return result;
}
fn finishSum(value: u32) u16 {
    var result = value;
    while (result >> 16 != 0) result = (result & 0xffff) + (result >> 16);
    return ~@as(u16, @intCast(result));
}
fn udpSum(source: IPv4, destination: IPv4, bytes: []const u8) u16 {
    return finishSum(sum(&source.bytes) + sum(&destination.bytes) + 17 + @as(u32, @intCast(bytes.len)) + sum(bytes));
}
fn encodeUdp(output: []u8, source: IPv4, destination: IPv4, source_port: u16, destination_port: u16, payload: []const u8) usize {
    const length = 28 + payload.len;
    @memset(output[0..length], 0);
    output[0] = 0x45;
    put16(output[2..4], @intCast(length));
    put16(output[6..8], 0x4000);
    output[8] = 64;
    output[9] = 17;
    @memcpy(output[12..16], &source.bytes);
    @memcpy(output[16..20], &destination.bytes);
    put16(output[10..12], finishSum(sum(output[0..20])));
    const udp = output[20..length];
    put16(udp[0..2], source_port);
    put16(udp[2..4], destination_port);
    put16(udp[4..6], @intCast(udp.len));
    @memcpy(udp[8..], payload);
    const checksum = udpSum(source, destination, udp);
    put16(udp[6..8], if (checksum == 0) 0xffff else checksum);
    return length;
}
const Packet = struct { source: IPv4, destination: IPv4, source_port: u16, destination_port: u16, bytes: []const u8 };
fn decodeUdp(bytes: []const u8) Error!Packet {
    if (bytes.len < 28 or bytes[0] != 0x45 or bytes[8] == 0 or bytes[9] != 17 or get16(bytes[6..8]) & 0xbfff != 0 or finishSum(sum(bytes[0..20])) != 0) return error.MalformedPacket;
    const length = get16(bytes[2..4]);
    if (length < 28 or length > bytes.len) return error.MalformedPacket;
    const source: IPv4 = .{ .bytes = bytes[12..16].* };
    const destination: IPv4 = .{ .bytes = bytes[16..20].* };
    if (!unicast(source) or !unicast(destination)) return error.MalformedPacket;
    const udp = bytes[20..length];
    if (get16(udp[4..6]) != udp.len or udp.len - 8 > max_datagram or get16(udp[0..2]) == 0 or get16(udp[2..4]) == 0 or
        (get16(udp[6..8]) != 0 and udpSum(source, destination, udp) != 0)) return error.MalformedPacket;
    return .{ .source = source, .destination = destination, .source_port = get16(udp[0..2]), .destination_port = get16(udp[2..4]), .bytes = udp[8..] };
}
fn wipe(bytes: []u8) void {
    const destination: [*]volatile u8 = @ptrCast(bytes.ptr);
    for (0..bytes.len) |index| destination[index] = 0;
}

test {
    _ = @import("tests.zig");
    _ = wifi;
}

test "RFC1071 checksum vector and RFC768 zero encoding are independent golden values" {
    try std.testing.expectEqual(@as(u16, 0x220d), finishSum(sum(&.{ 0x00, 0x01, 0xf2, 0x03, 0xf4, 0xf5, 0xf6, 0xf7 })));
    var bytes: [30]u8 = undefined;
    _ = encodeUdp(&bytes, .{ .bytes = .{ 10, 0, 2, 15 } }, .{ .bytes = .{ 10, 0, 2, 2 } }, 49152, 32123, &.{ 0xaa, 0x4d });
    // This literal pseudo-header + UDP sum folds to0xffff before complement.
    // Computed zero is transmitted as0xffff, rather than the absent-checksum0.
    try std.testing.expectEqualSlices(u8, &.{ 0xc0, 0x00, 0x7d, 0x7b, 0x00, 0x0a, 0xff, 0xff, 0xaa, 0x4d }, bytes[20..30]);
}
