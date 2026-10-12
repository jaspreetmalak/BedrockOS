//! Writable 512-byte VirtIO block requests with an explicit flush operation.
//! One synchronous request at a time; caller buffers never become DMA targets.
const std = @import("std");
const transport = @import("transport.zig");
const ring = @import("queue.zig");
const io = @import("io.zig");
const feature_readonly: u64 = 1 << 5;
const feature_flush: u64 = 1 << 9;
const header_offset: u64 = ring.buffer_offset;
const status_offset: u64 = ring.buffer_offset + 0x20;
const data_offset: u64 = ring.buffer_offset + 0x100;

pub const Block = struct {
    device: transport.Transport,
    queue: ring.Queue,
    sector_count: u64,
    live: bool = true,
    busy: bool = false,

    pub fn init(device: transport.Transport) !Block {
        if (device.device_id != transport.block_id) return error.WrongVirtioDevice;
        const offered = try device.begin(feature_flush);
        errdefer device.reset() catch {};
        if (offered & feature_readonly != 0) return error.ReadOnlyBlockDevice;
        if (offered & feature_flush == 0) return error.FlushUnsupported;
        const sectors = try capacity(device);
        var queue = try ring.Queue.init(device, 0);
        errdefer {
            if (device.reset()) |_| queue.releaseAfterReset() catch @panic("VirtIO block initialization rollback") else |_| {}
        }
        try device.ready();
        return .{ .device = device, .queue = queue, .sector_count = sectors };
    }

    /// Successful reset revokes every DMA address before the owned ring frees.
    pub fn deinit(self: *Block) !void {
        if (self.busy) return error.BlockBusy;
        try self.device.reset();
        self.live = false;
        try self.queue.releaseAfterReset();
    }

    pub fn read(self: *Block, sector: u64, output: *[512]u8) !void {
        try self.transfer(0, sector, null);
        const bytes: [*]const volatile u8 = @ptrFromInt(self.queue.base + data_offset);
        for (output, 0..) |*byte, i| byte.* = bytes[i];
    }

    pub fn write(self: *Block, sector: u64, input: *const [512]u8) !void {
        try self.transfer(1, sector, input);
    }

    pub fn flush(self: *Block) !void {
        try self.transfer(4, 0, null);
    }

    /// GET_ID is used to identify the dedicated data disk independently of
    /// firmware ESPs or transport enumeration order. QEMU pads its serial to20.
    pub fn getId(self: *Block) ![20]u8 {
        try self.transfer(8, 0, null);
        var id: [20]u8 = undefined;
        const source: [*]const volatile u8 = @ptrFromInt(self.queue.base + data_offset);
        for (&id, 0..) |*byte, index| byte.* = source[index];
        return id;
    }

    pub fn readBlocks(self: *Block, start: u64, output: []u8) !void {
        try bounds(self.sector_count, start, output.len);
        for (0..output.len / 512) |index| {
            const chunk: *[512]u8 = @ptrCast(output[index * 512 ..][0..512].ptr);
            try self.read(start + index, chunk);
        }
    }

    pub fn writeBlocks(self: *Block, start: u64, input: []const u8) !void {
        try bounds(self.sector_count, start, input.len);
        for (0..input.len / 512) |index| {
            const chunk: *const [512]u8 = @ptrCast(input[index * 512 ..][0..512].ptr);
            try self.write(start + index, chunk);
        }
    }

    fn transfer(self: *Block, operation: u32, sector: u64, input: ?*const [512]u8) !void {
        if (!self.live) return error.BlockDeviceStopped;
        if (self.busy) return error.BlockBusy;
        if ((operation == 0 or operation == 1) and sector >= self.sector_count) return error.OutOfBounds;
        self.busy = true;
        defer self.busy = false;
        // On any device/protocol failure, retain the lease until explicit reset
        // succeeds. A timeout is never permission to recycle DMA-visible RAM.
        errdefer self.live = false;
        const base = self.queue.base;
        io.write(u32, base + header_offset, operation);
        io.write(u32, base + header_offset + 4, 0);
        io.write(u64, base + header_offset + 8, sector);
        io.write(u8, base + status_offset, 0xff);
        if (input) |bytes| {
            const destination: [*]volatile u8 = @ptrFromInt(base + data_offset);
            for (bytes, 0..) |byte, i| destination[i] = byte;
        }
        const flush_request = operation == 4;
        const data_length: u32 = if (operation == 8) 20 else 512;
        const device_output = operation == 0 or operation == 8;
        try self.queue.descriptor(0, base + header_offset, 16, ring.next, if (flush_request) 2 else 1);
        if (!flush_request) try self.queue.descriptor(1, base + data_offset, data_length, ring.next | (if (device_output) ring.device_write else 0), 2);
        try self.queue.descriptor(2, base + status_offset, 1, ring.device_write, 0);
        try self.queue.submit(self.device, 0);
        for (0..transport.poll_limit) |_| {
            if (try self.queue.take()) |used| {
                if (used.id != 0 or used.length != (if (device_output) data_length + 1 else 1)) return error.InvalidBlockCompletion;
                io.fence();
                self.device.acknowledge();
                switch (io.read(u8, base + status_offset)) {
                    0 => return,
                    1 => return error.BlockIoError,
                    2 => return error.BlockRequestUnsupported,
                    else => return error.InvalidBlockStatus,
                }
            }
            if (self.device.status() & (64 | 128) != 0) return error.DeviceNeedsReset;
            io.relax();
        }
        return error.BlockRequestTimeout;
    }
};

fn capacity(device: transport.Transport) !u64 {
    for (0..8) |_| {
        const before = device.generation();
        const low = try device.configRead(u32, 0);
        const high = try device.configRead(u32, 4);
        if (device.generation() != before) continue;
        const result = @as(u64, low) | (@as(u64, high) << 32);
        if (result == 0 or result > std.math.maxInt(u64) / 512) return error.InvalidBlockCapacity;
        return result;
    }
    return error.UnstableBlockConfiguration;
}

fn bounds(sectors: u64, start: u64, bytes: usize) !void {
    if (bytes % 512 != 0) return error.InvalidBufferLength;
    const end = @addWithOverflow(start, @as(u64, @intCast(bytes / 512)));
    if (end[1] != 0 or start > sectors or end[0] > sectors) return error.OutOfBounds;
}

comptime {
    if (header_offset % 8 != 0 or data_offset + 512 > 4096) @compileError("VirtIO block bounce buffer exceeds owned page");
}

test "block buffer and capacity checks reject overflow before device access" {
    try bounds(10, 10, 0);
    try bounds(10, 8, 1024);
    try std.testing.expectError(error.OutOfBounds, bounds(10, 9, 1024));
    try std.testing.expectError(error.InvalidBufferLength, bounds(10, 0, 513));
    try std.testing.expectError(error.OutOfBounds, bounds(std.math.maxInt(u64), std.math.maxInt(u64), 512));
}
