//! Modern VirtIO Ethernet, with two polling split queues and owned bounce RAM.
//! No offloads, merged receive buffers, hash reporting or control queue.
//! Callers serialize access; no caller buffer is exposed to device DMA.
const std = @import("std");
const memory = @import("memory_init");
const transport = @import("transport.zig");
const ring = @import("queue.zig");
const io = @import("io.zig");

pub const max_frame: usize = 1514;
pub const min_frame: usize = 14;
pub const header_size: usize = 12;
const feature_mac: u64 = 1 << 5;
const feature_status: u64 = 1 << 16;
const rx_capacity: u16 = 8;
const buffer_size: usize = 2048;
const tx_offset: usize = rx_capacity * buffer_size;
const dma_size: usize = tx_offset + buffer_size;

pub const Net = struct {
    device: transport.Transport,
    rx: ring.Queue,
    tx: ring.Queue,
    dma_ticket: memory.heap_api.Ticket,
    dma_base: u64,
    rx_count: u16,
    mac: [6]u8,
    status_available: bool,
    live: bool = true,
    busy: bool = false,
    released: bool = false,

    pub fn init(device: transport.Transport) !Net {
        if (device.device_id != transport.net_id) return error.WrongVirtioDevice;
        const offered = try device.begin(feature_mac | feature_status);
        var rx: ?ring.Queue = null;
        var tx: ?ring.Queue = null;
        var dma_ticket: ?memory.heap_api.Ticket = null;
        // Even partially configured rings may already expose physical RAM.
        // A failed reset retains all such leases instead of recycling them.
        errdefer {
            if (device.reset()) |_| {
                if (tx) |*queue| queue.releaseAfterReset() catch @panic("VirtIO net TX rollback");
                if (rx) |*queue| queue.releaseAfterReset() catch @panic("VirtIO net RX rollback");
                if (dma_ticket) |ticket| memory.freeKernel(ticket) catch @panic("VirtIO net buffer rollback");
            } else |_| {}
        }
        if (offered & feature_mac == 0) return error.NetworkMacUnsupported;
        const status_available = offered & feature_status != 0;
        const mac = try readMac(device);
        if (status_available) _ = try readStatus(device);
        dma_ticket = try memory.allocateKernel(dma_size, 4096);
        const block = try memory.resolveKernel(dma_ticket.?);
        if (block.range.length < dma_size or block.range.base % 4096 != 0) return error.InvalidNetworkBuffers;
        rx = try ring.Queue.init(device, 0);
        tx = try ring.Queue.init(device, 1);
        const rx_count: u16 = @min(rx.?.size, rx_capacity);
        if (rx_count < 2) return error.QueueTooSmall;
        for (0..rx_count) |index| {
            const id: u16 = @intCast(index);
            const address = block.range.base + index * buffer_size;
            const bytes: [*]volatile u8 = @ptrFromInt(address);
            try prepareReceiveHeader(bytes[0..buffer_size]);
            try rx.?.descriptor(id, address, buffer_size, ring.device_write, 0);
            try rx.?.submit(device, id);
        }
        try device.ready();
        device.notify(rx.?.notify_address, 0);
        return .{
            .device = device,
            .rx = rx.?,
            .tx = tx.?,
            .dma_ticket = dma_ticket.?,
            .dma_base = block.range.base,
            .rx_count = rx_count,
            .mac = mac,
            .status_available = status_available,
        };
    }

    /// Reset completion is required before freeing any ring or packet buffer.
    /// A failed reset leaves the stopped instance and all DMA leases intact.
    pub fn deinit(self: *Net) !void {
        if (self.busy) return error.NetworkBusy;
        if (self.released) return error.NetworkDeviceStopped;
        self.live = false;
        try self.device.reset();
        if (self.tx.base != 0) try self.tx.releaseAfterReset();
        if (self.rx.base != 0) try self.rx.releaseAfterReset();
        if (self.dma_base != 0) {
            try memory.freeKernel(self.dma_ticket);
            self.dma_base = 0;
        }
        self.released = true;
    }

    /// Link status is read atomically with the transport configuration
    /// generation. Without STATUS, VirtIO specifies an assumed active link.
    pub fn linkUp(self: *const Net) !bool {
        if (!self.live) return error.NetworkDeviceStopped;
        return !self.status_available or (try readStatus(self.device)) & 1 != 0;
    }

    /// Completion means the device consumed this frame, not peer delivery.
    /// Protocol/timeout failures stop new requests and retain DMA ownership.
    pub fn send(self: *Net, frame: []const u8) !void {
        if (!self.live) return error.NetworkDeviceStopped;
        if (self.busy) return error.NetworkBusy;
        try frameBounds(frame.len);
        if (!try self.linkUp()) return error.NetworkLinkDown;
        self.busy = true;
        defer self.busy = false;
        errdefer self.live = false;
        try self.checkStatus();
        const bytes: [*]volatile u8 = @ptrFromInt(self.dma_base + tx_offset);
        const length = try prepareTransmit(frame, bytes[0..buffer_size]);
        try self.tx.descriptor(0, self.dma_base + tx_offset, length, 0, 0);
        try self.tx.submit(self.device, 0);
        for (0..transport.poll_limit) |_| {
            if (try self.tx.take()) |used| {
                try validateTransmit(used);
                self.device.acknowledge();
                return;
            }
            try self.checkStatus();
            io.relax();
        }
        return error.NetworkTransmitTimeout;
    }

    /// Nonblocking: null means no completed frame. Each successful frame is
    /// copied before its receive descriptor is reposted. OutputTooSmall drops
    /// and reposts that frame without modifying output or stopping the device.
    pub fn receive(self: *Net, output: []u8) !?usize {
        if (!self.live) return error.NetworkDeviceStopped;
        if (self.busy) return error.NetworkBusy;
        self.busy = true;
        defer self.busy = false;
        return self.receiveOnce(output) catch |err| {
            if (err != error.OutputTooSmall) self.live = false;
            return err;
        };
    }

    fn receiveOnce(self: *Net, output: []u8) !?usize {
        try self.checkStatus();
        const used = (try self.rx.take()) orelse {
            self.device.acknowledge();
            return null;
        };
        _ = try validateReceiveCompletion(used, self.rx_count);
        const bytes: [*]const volatile u8 = @ptrFromInt(self.dma_base + @as(u64, used.id) * buffer_size);
        const length = copyPacket(bytes[0..buffer_size], used, self.rx_count, output) catch |err| {
            if (err == error.OutputTooSmall) {
                try self.repost(@intCast(used.id));
                self.device.acknowledge();
            }
            return err;
        };
        try self.repost(@intCast(used.id));
        self.device.acknowledge();
        return length;
    }

    fn checkStatus(self: *const Net) !void {
        if (self.device.status() & (64 | 128) != 0) return error.DeviceNeedsReset;
    }

    fn repost(self: *Net, id: u16) !void {
        if (id >= self.rx_count) return error.InvalidNetworkCompletion;
        const bytes: [*]volatile u8 = @ptrFromInt(self.dma_base + @as(u64, id) * buffer_size);
        try prepareReceiveHeader(bytes[0..buffer_size]);
        try self.rx.submit(self.device, id);
    }
};

fn prepareReceiveHeader(buffer: []volatile u8) !void {
    if (buffer.len < header_size) return error.InvalidNetworkBuffers;
    // VirtIO1.3 section5.1.6.3.2 defines num_buffers=1 without MRG_RXBUF.
    // QEMU10.1 receive_header() copies only the10-byte prefix; its unmerged
    // receive path assigns the count locally without copying it to guest RAM:
    // https://github.com/qemu/qemu/blob/v10.1.0/hw/net/virtio-net.c
    // Initialize this known, kernel-private field before EVERY submission.
    // An explicit invalid device-written count still fails copyPacket(); used
    // length and a single posted descriptor independently bound each packet.
    buffer[10] = 1;
    buffer[11] = 0;
}

fn frameBounds(length: usize) !void {
    if (length < min_frame or length > max_frame) return error.InvalidEthernetFrame;
}

fn prepareTransmit(frame: []const u8, output: []volatile u8) !u32 {
    try frameBounds(frame.len);
    if (output.len < header_size + frame.len) return error.InvalidNetworkBuffers;
    // Every optional/offload field, including TX num_buffers, is zero.
    for (0..header_size) |index| output[index] = 0;
    for (frame, 0..) |byte, index| output[header_size + index] = byte;
    return @intCast(header_size + frame.len);
}

fn validateTransmit(used: ring.Used) !void {
    // TX descriptors are entirely device-readable: no bytes can be written.
    if (used.id != 0 or used.length != 0) return error.InvalidNetworkCompletion;
}

fn validateReceiveCompletion(used: ring.Used, rx_count: u16) !usize {
    if (rx_count < 2 or rx_count > rx_capacity or used.id >= rx_count or
        used.length < header_size + min_frame or used.length > header_size + max_frame)
        return error.InvalidNetworkCompletion;
    return used.length - header_size;
}

fn copyPacket(buffer: []const volatile u8, used: ring.Used, rx_count: u16, output: []u8) !usize {
    const length = try validateReceiveCompletion(used, rx_count);
    if (used.length > buffer.len) return error.InvalidNetworkBuffers;
    var header: [header_size]u8 = undefined;
    for (&header, 0..) |*byte, index| byte.* = buffer[index];
    // No GUEST_CSUM/GSO/MRG_RXBUF/HASH feature is negotiated. The modern
    // header still includes num_buffers, and a receive must use exactly one.
    if (header[0] != 0 or header[1] != 0 or std.mem.readInt(u16, header[10..12], .little) != 1)
        return error.InvalidNetworkHeader;
    if (output.len < length) return error.OutputTooSmall;
    for (0..length) |index| output[index] = buffer[header_size + index];
    return length;
}

fn readMac(device: transport.Transport) ![6]u8 {
    for (0..8) |_| {
        const before = device.generation();
        var mac: [6]u8 = undefined;
        for (&mac, 0..) |*byte, offset| byte.* = try device.configRead(u8, offset);
        if (device.generation() != before) continue;
        var any: u8 = 0;
        for (mac) |byte| any |= byte;
        if (any == 0 or mac[0] & 1 != 0) return error.InvalidNetworkMac;
        return mac;
    }
    return error.UnstableNetworkConfiguration;
}

fn readStatus(device: transport.Transport) !u16 {
    for (0..8) |_| {
        const before = device.generation();
        const status = try device.configRead(u16, 6);
        if (device.generation() == before) return status;
    }
    return error.UnstableNetworkConfiguration;
}

comptime {
    if (header_size != 12 or header_size + max_frame > buffer_size or
        tx_offset % buffer_size != 0 or dma_size > 5 * 4096)
        @compileError("VirtIO network buffers exceed owned DMA allocation");
}

test "network transmit validates Ethernet bounds before touching bounce memory" {
    var frame: [max_frame]u8 = @splat(0x56);
    var bounce: [buffer_size + 2]u8 = @splat(0xa5);
    const destination: []volatile u8 = bounce[1 .. bounce.len - 1];
    try std.testing.expectError(error.InvalidEthernetFrame, prepareTransmit(frame[0..13], destination));
    try std.testing.expectEqual(@as(u8, 0xa5), bounce[1]);
    try std.testing.expectError(error.InvalidEthernetFrame, frameBounds(max_frame + 1));
    try std.testing.expectError(error.InvalidNetworkBuffers, prepareTransmit(&frame, destination[0 .. header_size + max_frame - 1]));
    try std.testing.expectEqual(@as(u8, 0xa5), bounce[1]);
    try std.testing.expectEqual(@as(u32, header_size + max_frame), try prepareTransmit(&frame, destination));
    try std.testing.expectEqualSlices(u8, &@as([header_size]u8, @splat(0)), bounce[1..][0..header_size]);
    try std.testing.expectEqualSlices(u8, &frame, bounce[1 + header_size ..][0..max_frame]);
    try std.testing.expectEqual(@as(u8, 0xa5), bounce[0]);
    try std.testing.expectEqual(@as(u8, 0xa5), bounce[bounce.len - 1]);
    try std.testing.expectEqual(@as(u8, 0xa5), bounce[1 + header_size + max_frame]);
}

test "network completions reject unposted IDs and malformed used lengths" {
    try std.testing.expectEqual(@as(usize, min_frame), try validateReceiveCompletion(.{ .id = 1, .length = header_size + min_frame }, 2));
    try std.testing.expectError(error.InvalidNetworkCompletion, validateReceiveCompletion(.{ .id = 2, .length = 26 }, 2));
    try std.testing.expectError(error.InvalidNetworkCompletion, validateReceiveCompletion(.{ .id = std.math.maxInt(u32), .length = 26 }, 8));
    try std.testing.expectError(error.InvalidNetworkCompletion, validateReceiveCompletion(.{ .id = 0, .length = 25 }, 2));
    try std.testing.expectError(error.InvalidNetworkCompletion, validateReceiveCompletion(.{ .id = 0, .length = 1527 }, 2));
    try std.testing.expectError(error.InvalidNetworkCompletion, validateReceiveCompletion(.{ .id = 0, .length = 26 }, 0));
    try std.testing.expectError(error.InvalidNetworkCompletion, validateReceiveCompletion(.{ .id = 0, .length = 26 }, 9));
    try validateTransmit(.{ .id = 0, .length = 0 });
    try std.testing.expectError(error.InvalidNetworkCompletion, validateTransmit(.{ .id = 1, .length = 0 }));
    try std.testing.expectError(error.InvalidNetworkCompletion, validateTransmit(.{ .id = 0, .length = 1 }));
}

test "receive strips the modern header and preserves output canaries" {
    var packet: [header_size + max_frame]u8 = @splat(0);
    try prepareReceiveHeader(&packet);
    try std.testing.expectEqual(@as(u8, 1), packet[10]);
    try std.testing.expectEqual(@as(u8, 0), packet[11]);
    for (packet[header_size..], 0..) |*byte, index| byte.* = @truncate(index);
    var output: [max_frame + 2]u8 = @splat(0xa5);
    const length = try copyPacket(&packet, .{ .id = 7, .length = packet.len }, 8, output[1 .. output.len - 1]);
    try std.testing.expectEqual(max_frame, length);
    try std.testing.expectEqualSlices(u8, packet[header_size..], output[1 .. output.len - 1]);
    try std.testing.expectEqual(@as(u8, 0xa5), output[0]);
    try std.testing.expectEqual(@as(u8, 0xa5), output[output.len - 1]);
}

test "receive rejects malformed headers and short output before copying any bytes" {
    var packet: [26]u8 = @splat(0);
    try std.testing.expectError(error.InvalidNetworkBuffers, prepareReceiveHeader(packet[0 .. header_size - 1]));
    try std.testing.expectEqual(@as(u8, 0), packet[10]);
    try prepareReceiveHeader(&packet);
    var output: [min_frame]u8 = @splat(0xa5);
    const used: ring.Used = .{ .id = 0, .length = packet.len };
    const cases = [_]struct { offset: usize, value: u8 }{
        .{ .offset = 0, .value = 1 },
        .{ .offset = 0, .value = 2 },
        .{ .offset = 1, .value = 1 },
        .{ .offset = 10, .value = 0 },
        .{ .offset = 10, .value = 2 },
        .{ .offset = 11, .value = 1 },
    };
    for (cases) |case| {
        const original = packet[case.offset];
        packet[case.offset] = case.value;
        try std.testing.expectError(error.InvalidNetworkHeader, copyPacket(&packet, used, 2, &output));
        try std.testing.expectEqualSlices(u8, &@as([min_frame]u8, @splat(0xa5)), &output);
        packet[case.offset] = original;
    }
    try std.testing.expectError(error.OutputTooSmall, copyPacket(&packet, used, 2, output[0 .. min_frame - 1]));
    try std.testing.expectError(error.OutputTooSmall, copyPacket(&packet, used, 2, output[0..0]));
    try std.testing.expectError(error.InvalidNetworkBuffers, copyPacket(packet[0 .. packet.len - 1], used, 2, &output));
    try std.testing.expectEqualSlices(u8, &@as([min_frame]u8, @splat(0xa5)), &output);
}

test "stopped network entry points reject calls before touching device registers" {
    var net: Net = undefined;
    net.live = false;
    var frame: [min_frame]u8 = @splat(0);
    try std.testing.expectError(error.NetworkDeviceStopped, net.send(&frame));
    try std.testing.expectError(error.NetworkDeviceStopped, net.receive(&frame));
    try std.testing.expectError(error.NetworkDeviceStopped, net.linkUp());
}

test "short receive output reposts the consumed descriptor and remains live" {
    var registers: [64]u8 align(8) = @splat(0);
    registers[20] = 15;
    var notification: u16 = 0;
    var isr: u8 = 0;
    var queue_bytes: [4096]u8 align(4096) = @splat(0);
    var packets: [dma_size]u8 align(4096) = @splat(0);
    try prepareReceiveHeader(packets[buffer_size..][0..buffer_size]);
    @memset(packets[buffer_size + header_size ..][0..min_frame], 0x56);
    var net: Net = .{
        .device = .{
            .kind = .pci,
            .device_id = transport.net_id,
            .common = @intFromPtr(&registers),
            .isr = @intFromPtr(&isr),
            .config = 0,
            .config_length = 0,
        },
        .rx = .{
            .ticket = undefined,
            .base = @intFromPtr(&queue_bytes),
            .size = 4,
            .index = 0,
            .notify_address = @intFromPtr(&notification),
            .published = 1,
            .outstanding = 1,
        },
        .tx = undefined,
        .dma_ticket = undefined,
        .dma_base = @intFromPtr(&packets),
        .rx_count = 2,
        .mac = .{ 0x52, 0x54, 0, 0x12, 0x34, 0x56 },
        .status_available = false,
    };
    net.rx.busy[1] = true;
    io.write(u16, net.rx.base + ring.used_offset + 2, 1);
    io.write(u32, net.rx.base + ring.used_offset + 4, 1);
    io.write(u32, net.rx.base + ring.used_offset + 8, header_size + min_frame);
    var output: [min_frame - 1]u8 = @splat(0xa5);
    try std.testing.expectError(error.OutputTooSmall, net.receive(&output));
    try std.testing.expect(net.live);
    try std.testing.expect(!net.busy);
    try std.testing.expect(net.rx.busy[1]);
    try std.testing.expectEqual(@as(u16, 1), net.rx.outstanding);
    try std.testing.expectEqual(@as(u16, 1), net.rx.consumed);
    try std.testing.expectEqual(@as(u16, 2), net.rx.published);
    try std.testing.expectEqual(@as(u8, 1), packets[buffer_size + 10]);
    try std.testing.expectEqual(@as(u8, 0), packets[buffer_size + 11]);
    try std.testing.expectEqual(@as(u16, 1), io.read(u16, net.rx.base + ring.available_offset + 4 + 2));
    try std.testing.expectEqualSlices(u8, &@as([min_frame - 1]u8, @splat(0xa5)), &output);
    try std.testing.expectEqual(@as(?usize, null), try net.receive(&output));

    // The next real completion uses the reposted buffer, not stale metadata.
    io.write(u16, net.rx.base + ring.used_offset + 2, 2);
    io.write(u32, net.rx.base + ring.used_offset + 4 + 8, 1);
    io.write(u32, net.rx.base + ring.used_offset + 8 + 8, header_size + min_frame);
    var full: [min_frame]u8 = undefined;
    try std.testing.expectEqual(@as(?usize, min_frame), try net.receive(&full));
    try std.testing.expectEqualSlices(u8, &@as([min_frame]u8, @splat(0x56)), &full);
    try std.testing.expect(net.rx.busy[1]);
    try std.testing.expectEqual(@as(u8, 1), packets[buffer_size + 10]);

    // Invalid protocol metadata stops the driver without releasing DMA RAM.
    packets[buffer_size + 10] = 2;
    io.write(u16, net.rx.base + ring.used_offset + 2, 3);
    io.write(u32, net.rx.base + ring.used_offset + 4 + 16, 1);
    io.write(u32, net.rx.base + ring.used_offset + 8 + 16, header_size + min_frame);
    try std.testing.expectError(error.InvalidNetworkHeader, net.receive(&full));
    try std.testing.expect(!net.live);
    try std.testing.expectEqual(@intFromPtr(&packets), net.dma_base);
    try std.testing.expectEqual(@intFromPtr(&queue_bytes), net.rx.base);
    net.device.common = 0;
    try std.testing.expectError(error.NetworkDeviceStopped, net.receive(&full));
}
