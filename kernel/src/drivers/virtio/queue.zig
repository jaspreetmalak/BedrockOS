//! Split rings and request buffers occupy one checked, contiguous owned page.
//! No indirect descriptors, packed rings or event-index feature is negotiated.
const std = @import("std");
const memory = @import("memory_init");
const transport = @import("transport.zig");
const io = @import("io.zig");
pub const capacity: u16 = 64;
pub const descriptor_offset: u64 = 0;
pub const available_offset: u64 = 0x400;
pub const used_offset: u64 = 0x800;
pub const buffer_offset: u64 = 0xc00;
pub const next: u16 = 1;
pub const device_write: u16 = 2;
pub const Used = struct { id: u32, length: u32 };

pub const Queue = struct {
    ticket: memory.heap_api.Ticket,
    base: u64,
    size: u16,
    index: u16,
    notify_address: u64,
    published: u16 = 0,
    consumed: u16 = 0,
    outstanding: u16 = 0,
    busy: [capacity]bool = @splat(false),

    pub fn init(device: transport.Transport, index: u16) !Queue {
        const maximum = try device.queueMaximum(index);
        var size: u16 = capacity;
        while (size > maximum) size >>= 1;
        if (size < 4) return error.QueueTooSmall;
        const ticket = try memory.allocateKernel(4096, 4096);
        const block = memory.resolveKernel(ticket) catch |err| {
            memory.freeKernel(ticket) catch @panic("VirtIO queue lease rollback");
            return err;
        };
        const base = block.range.base;
        // AVAIL_F_NO_INTERRUPT. The driver owns all completion polling.
        io.write(u16, base + available_offset, 1);
        const notification = device.configureQueue(index, size, base, base + available_offset, base + used_offset) catch |err| {
            // Configuration may already have exposed the queue. A reset must
            // complete before any physical address can be recycled.
            device.reset() catch return error.DeviceResetTimeout;
            try memory.freeKernel(ticket);
            return err;
        };
        return .{ .ticket = ticket, .base = base, .size = size, .index = index, .notify_address = notification };
    }

    /// Call only after successful whole-device reset has revoked DMA access.
    pub fn releaseAfterReset(self: *Queue) !void {
        try memory.freeKernel(self.ticket);
        self.base = 0;
    }

    pub fn descriptor(self: *Queue, id: u16, address: u64, length: u32, flags: u16, successor: u16) !void {
        if (id >= self.size or self.busy[id] or (flags & next != 0 and successor >= self.size)) return error.InvalidQueueDescriptor;
        const location = self.base + descriptor_offset + @as(u64, id) * 16;
        io.write(u64, location, address);
        io.write(u32, location + 8, length);
        io.write(u16, location + 12, flags);
        io.write(u16, location + 14, successor);
    }

    pub fn submit(self: *Queue, device: transport.Transport, head: u16) !void {
        if (head >= self.size or self.busy[head] or self.outstanding == self.size) return error.InvalidQueueDescriptor;
        self.busy[head] = true;
        self.outstanding += 1;
        const slot = self.published & (self.size - 1);
        io.write(u16, self.base + available_offset + 4 + @as(u64, slot) * 2, head);
        io.fence();
        self.published +%= 1;
        io.write(u16, self.base + available_offset + 2, self.published);
        device.notify(self.notify_address, self.index);
    }

    pub fn take(self: *Queue) !?Used {
        const actual = io.read(u16, self.base + used_offset + 2);
        const pending = actual -% self.consumed;
        if (pending == 0) return null;
        if (pending > self.outstanding or pending > self.size) return error.InvalidUsedRing;
        io.fence();
        const slot = self.consumed & (self.size - 1);
        const address = self.base + used_offset + 4 + @as(u64, slot) * 8;
        const result: Used = .{ .id = io.read(u32, address), .length = io.read(u32, address + 4) };
        if (result.id >= self.size or !self.busy[result.id]) return error.InvalidUsedRing;
        self.busy[result.id] = false;
        self.outstanding -= 1;
        self.consumed +%= 1;
        return result;
    }
};

comptime {
    if (capacity & (capacity - 1) != 0 or capacity * 16 > available_offset or
        available_offset + 6 + capacity * 2 > used_offset or
        used_offset + 6 + capacity * 8 > buffer_offset or buffer_offset + capacity * 8 > 4096)
        @compileError("VirtIO split ring page layout overlaps");
}

test "used indices wrap and reject completions outside live descriptors" {
    var backing: [4096]u8 align(4096) = @splat(0);
    var queue: Queue = undefined;
    queue.base = @intFromPtr(&backing);
    queue.size = 4;
    queue.consumed = 0xffff;
    queue.outstanding = 1;
    queue.busy = @splat(false);
    queue.busy[2] = true;
    io.write(u16, queue.base + used_offset + 2, 0);
    io.write(u32, queue.base + used_offset + 4 + 3 * 8, 2);
    io.write(u32, queue.base + used_offset + 8 + 3 * 8, 8);
    const used = (try queue.take()).?;
    try std.testing.expectEqual(@as(u32, 2), used.id);
    try std.testing.expectEqual(@as(u16, 0), queue.consumed);
    try std.testing.expectEqual(@as(u16, 0), queue.outstanding);
    io.write(u16, queue.base + used_offset + 2, 1);
    try std.testing.expectError(error.InvalidUsedRing, queue.take());
}
