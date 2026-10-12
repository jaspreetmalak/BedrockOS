//! VirtIO evdev receive/status queues. Polling returns copied events and
//! immediately republishes each receive descriptor; no DMA buffer escapes.
const std = @import("std");
const transport = @import("transport.zig");
const ring = @import("queue.zig");
const io = @import("io.zig");
pub const Event = extern struct { event_type: u16, code: u16, value: i32 };
pub const Axis = struct { minimum: i32 = 0, maximum: i32 = 32767 };

pub const Input = struct {
    device: transport.Transport,
    events: ring.Queue,
    status: ring.Queue,
    abs_x: Axis = .{},
    abs_y: Axis = .{},
    live: bool = true,

    pub fn init(device: transport.Transport) !Input {
        if (device.device_id != transport.input_id) return error.WrongVirtioDevice;
        _ = try device.begin(0);
        errdefer device.reset() catch {};
        // Query supported event families as required by device initialization.
        // Unknown families remain harmless raw events that the decoder ignores.
        for ([_]u8{ 0, 1, 2, 3 }) |event_type| {
            try device.configSelect(0x11, event_type);
            const length = try device.configRead(u8, 2);
            if (length > 128) return error.InvalidInputConfiguration;
            for (0..length) |index| _ = try device.configRead(u8, 8 + index);
        }
        const x = try axis(device, 0);
        const y = try axis(device, 1);
        var events = try ring.Queue.init(device, 0);
        errdefer {
            if (device.reset()) |_| events.releaseAfterReset() catch @panic("VirtIO input event rollback") else |_| {}
        }
        var status = try ring.Queue.init(device, 1);
        errdefer {
            if (device.reset()) |_| status.releaseAfterReset() catch @panic("VirtIO input status rollback") else |_| {}
        }
        for (0..events.size) |index| {
            const id: u16 = @intCast(index);
            try events.descriptor(id, events.base + ring.buffer_offset + index * @sizeOf(Event), @sizeOf(Event), ring.device_write, 0);
            try events.submit(device, id);
        }
        try device.ready();
        device.notify(events.notify_address, 0);
        return .{ .device = device, .events = events, .status = status, .abs_x = x, .abs_y = y };
    }

    pub fn deinit(self: *Input) !void {
        try self.device.reset();
        self.live = false;
        try self.status.releaseAfterReset();
        try self.events.releaseAfterReset();
    }

    pub fn poll(self: *Input) !?Event {
        if (!self.live) return error.InputDeviceStopped;
        errdefer self.live = false;
        if (self.device.status() & (64 | 128) != 0) return error.DeviceNeedsReset;
        const used = (try self.events.take()) orelse return null;
        if (used.length != @sizeOf(Event)) return error.InvalidInputCompletion;
        const address = self.events.base + ring.buffer_offset + @as(u64, used.id) * @sizeOf(Event);
        const event: Event = .{ .event_type = io.read(u16, address), .code = io.read(u16, address + 2), .value = @bitCast(io.read(u32, address + 4)) };
        try self.events.submit(self.device, @intCast(used.id));
        self.device.acknowledge();
        return event;
    }
};

fn axis(device: transport.Transport, code: u8) !Axis {
    try device.configSelect(0x12, code);
    const length = try device.configRead(u8, 2);
    if (length == 0) return .{};
    if (length < 20 or length > 128) return error.InvalidInputConfiguration;
    const minimum: i32 = @bitCast(try device.configRead(u32, 8));
    const maximum: i32 = @bitCast(try device.configRead(u32, 12));
    if (minimum >= maximum) return error.InvalidInputAxis;
    return .{ .minimum = minimum, .maximum = maximum };
}

comptime {
    if (@sizeOf(Event) != 8 or @offsetOf(Event, "value") != 4) @compileError("VirtIO input event wire layout changed");
}

test "input event ABI is eight little-endian bytes" {
    const bytes = [_]u8{ 2, 0, 1, 0, 0xff, 0xff, 0xff, 0xff };
    try std.testing.expectEqual(@as(u16, 2), std.mem.readInt(u16, bytes[0..2], .little));
    try std.testing.expectEqual(@as(i32, -1), @as(i32, @bitCast(std.mem.readInt(u32, bytes[4..8], .little))));
}
