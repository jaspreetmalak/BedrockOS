//! Bounded, single-owner input and hit-testing primitives. Events carry data,
//! never device or filesystem authority. No global queue or allocation.
const std = @import("std");
const Surface = @import("surface.zig").Surface;
const Color = @import("types.zig").Color;

pub const Kind = enum(u8) { pointer_move = 1, pointer_down = 2, pointer_up = 3, key_down = 4, key_up = 5, text = 6, wheel = 7, redraw = 8 };
pub const Button = enum(u16) { left = 1, middle = 2, right = 3 };
pub const modifiers = struct {
    pub const shift: u8 = 1;
    pub const control: u8 = 2;
    pub const alt: u8 = 4;
    pub const super: u8 = 8;
    /// Host-supplied metadata on the second client pointer release.
    pub const double_click: u8 = 16;
};
pub const Key = enum(u16) {
    backspace = 8,
    tab = 9,
    enter = 13,
    escape = 27,
    delete = 127,
    left = 0x100,
    right = 0x101,
    up = 0x102,
    down = 0x103,
    home = 0x104,
    end = 0x105,
    page_up = 0x106,
    page_down = 0x107,
    f2 = 0x108,
    f5 = 0x109,
    f4 = 0x10a,
    f11 = 0x10b,
};

/// Wire bits: kind[0:8], modifiers[8:16], code[16:32], signed x[32:48],
/// signed y[48:64]. Text carries a codepoint in code; the initial font is ASCII.
/// Wheel code is a signed i16 row delta. Pointer coordinates are client-local.
/// Redraw comes from the window host; code1 cancels an obsolete pointer gesture
/// after geometry/visibility changes, while code0 preserves it on focus repaint.
pub const Event = struct {
    kind: Kind,
    modifiers: u8 = 0,
    code: u16 = 0,
    x: i16 = 0,
    y: i16 = 0,

    pub fn encode(self: Event) u64 {
        return @as(u64, @backingInt(self.kind)) | (@as(u64, self.modifiers) << 8) |
            (@as(u64, self.code) << 16) | (@as(u64, @as(u16, @bitCast(self.x))) << 32) |
            (@as(u64, @as(u16, @bitCast(self.y))) << 48);
    }
    pub fn decode(raw: u64) error{InvalidEvent}!Event {
        const kind: u8 = @truncate(raw);
        if (kind < 1 or kind > 8) return error.InvalidEvent;
        const mods: u8 = @truncate(raw >> 8);
        if (mods & ~@as(u8, 31) != 0) return error.InvalidEvent;
        return .{ .kind = @fromBackingInt(@intCast(kind)), .modifiers = mods, .code = @truncate(raw >> 16), .x = @bitCast(@as(u16, @truncate(raw >> 32))), .y = @bitCast(@as(u16, @truncate(raw >> 48))) };
    }
};

/// Caller serializes producer/consumer access. Full queues reject the new
/// event; pointer-up and key-up are never silently discarded or overwritten.
pub fn Queue(comptime capacity: usize) type {
    if (capacity == 0) @compileError("Input queue capacity must be nonzero");
    return struct {
        const Self = @This();
        records: [capacity]u64 = undefined,
        head: usize = 0,
        len: usize = 0,
        pub fn push(self: *Self, event: Event) error{ QueueFull, InvalidEvent }!void {
            _ = try Event.decode(event.encode());
            if (self.len == capacity) return error.QueueFull;
            self.records[(self.head + self.len) % capacity] = event.encode();
            self.len += 1;
        }
        pub fn pop(self: *Self) ?Event {
            if (self.len == 0) return null;
            const result = Event.decode(self.records[self.head]) catch unreachable;
            self.head = (self.head + 1) % capacity;
            self.len -= 1;
            return result;
        }
        pub fn clear(self: *Self) void {
            self.head = 0;
            self.len = 0;
        }
    };
}

pub const Point = struct { x: i32, y: i32 };
pub const Rect = struct {
    x: i32,
    y: i32,
    width: u32,
    height: u32,
    pub fn contains(self: Rect, point: Point) bool {
        const dx = @as(i64, point.x) - self.x;
        const dy = @as(i64, point.y) - self.y;
        return dx >= 0 and dy >= 0 and dx < self.width and dy < self.height;
    }
};

/// Later rectangles paint above earlier ones. Zero-area records never hit.
pub fn HitMap(comptime capacity: usize) type {
    return struct {
        const Self = @This();
        const Item = struct { id: u64, rect: Rect };
        items: [capacity]Item = undefined,
        len: usize = 0,
        pub fn clear(self: *Self) void {
            self.len = 0;
        }
        pub fn add(self: *Self, id: u64, rect: Rect) error{HitCapacity}!void {
            if (self.len == capacity) return error.HitCapacity;
            self.items[self.len] = .{ .id = id, .rect = rect };
            self.len += 1;
        }
        pub fn hit(self: *const Self, point: Point) ?u64 {
            var n = self.len;
            while (n != 0) {
                n -= 1;
                if (self.items[n].rect.contains(point)) return self.items[n].id;
            }
            return null;
        }
    };
}

/// Draw an integer-only 12x18 cursor after rendering. Revalidate before writing;
/// negative/outside coordinates clip and scanline padding is left untouched.
pub fn drawCursor(surface: *Surface, point: Point, color: Color) !void {
    try surface.validate();
    const ink = surface.encode(color);
    const outline = surface.encode(Color.rgb(8, 12, 18));
    for (0..18) |row| {
        const width: usize = if (row < 12) row / 2 + 1 else 3;
        for (0..width) |column| {
            const x = @as(i64, point.x) + @as(i64, @intCast(column));
            const y = @as(i64, point.y) + @as(i64, @intCast(row));
            if (x < 0 or y < 0 or x >= surface.width or y >= surface.height) continue;
            surface.putPixel(@intCast(x), @intCast(y), if (column == 0 or column + 1 == width or row == 17) outline else ink);
        }
    }
}

test "input wire roundtrip and invalid records" {
    const e: Event = .{ .kind = .pointer_move, .modifiers = modifiers.shift, .code = 12, .x = -123, .y = 32000 };
    try std.testing.expectEqualDeep(e, try Event.decode(e.encode()));
    try std.testing.expectError(error.InvalidEvent, Event.decode(0));
    try std.testing.expectError(error.InvalidEvent, Event.decode(1 | (32 << 8)));
    const repaint: Event = .{ .kind = .redraw, .code = 1 };
    try std.testing.expectEqualDeep(repaint, try Event.decode(repaint.encode()));
    try std.testing.expectError(error.InvalidEvent, Event.decode(9));
}
test "bounded queue preserves ordering over wrap and full rejection" {
    var q: Queue(2) = .{};
    try q.push(.{ .kind = .pointer_down });
    try q.push(.{ .kind = .pointer_up });
    try std.testing.expectError(error.QueueFull, q.push(.{ .kind = .text }));
    try std.testing.expectEqual(Kind.pointer_down, q.pop().?.kind);
    try q.push(.{ .kind = .text, .code = 'a' });
    try std.testing.expectEqual(Kind.pointer_up, q.pop().?.kind);
    try std.testing.expectEqual(@as(u16, 'a'), q.pop().?.code);
    try std.testing.expect(q.pop() == null);
}
test "hit maps use half-open bounds and later-layer priority without overflow" {
    var map: HitMap(2) = .{};
    try map.add(1, .{ .x = -4, .y = 0, .width = 10, .height = 10 });
    try map.add(2, .{ .x = 0, .y = 0, .width = 4, .height = 4 });
    try std.testing.expectEqual(@as(?u64, 2), map.hit(.{ .x = 0, .y = 0 }));
    try std.testing.expectEqual(@as(?u64, 1), map.hit(.{ .x = 4, .y = 0 }));
    try std.testing.expect(map.hit(.{ .x = 6, .y = 0 }) == null);
    const extreme: Rect = .{ .x = std.math.maxInt(i32), .y = std.math.minInt(i32), .width = std.math.maxInt(u32), .height = 1 };
    try std.testing.expect(extreme.contains(.{ .x = std.math.maxInt(i32), .y = std.math.minInt(i32) }));
}
test "cursor drawing clips and preserves stride padding and outer guards" {
    var memory: [50]u32 = @splat(0x12345678);
    var surface = try Surface.init(memory[1..49], 6, 6, 8, .{ .red = 0xff0000, .green = 0xff00, .blue = 0xff });
    try drawCursor(&surface, .{ .x = -2, .y = -1 }, Color.rgb(220, 240, 255));
    try drawCursor(&surface, .{ .x = 5, .y = 5 }, Color.rgb(220, 240, 255));
    try std.testing.expectEqual(@as(u32, 0x12345678), memory[0]);
    try std.testing.expectEqual(@as(u32, 0x12345678), memory[49]);
    for (0..6) |row| for (6..8) |col| try std.testing.expectEqual(@as(u32, 0x12345678), memory[1 + row * 8 + col]);
}
