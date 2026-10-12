//! Small evdev-to-UI bridge. Encoded event bits match AxisUI's source contract;
//! the driver depends on no framework and grants no physical device authority.
const std = @import("std");
const input = @import("input.zig");
const queue_capacity = 32;
pub const Decoder = struct {
    width: i32,
    height: i32,
    x: i32 = 0,
    y: i32 = 0,
    moved: bool = false,
    shift_left: bool = false,
    shift_right: bool = false,
    control_left: bool = false,
    control_right: bool = false,
    alt_left: bool = false,
    alt_right: bool = false,
    super_left: bool = false,
    super_right: bool = false,
    caps_lock: bool = false,
    pending: [queue_capacity]u64 = undefined,
    head: usize = 0,
    count: usize = 0,

    pub fn init(width: u32, height: u32) !Decoder {
        if (width == 0 or height == 0 or width > 32768 or height > 32768) return error.InvalidInputViewport;
        return .{ .width = @intCast(width), .height = @intCast(height) };
    }

    pub fn pop(self: *Decoder) ?u64 {
        if (self.count == 0) return null;
        const event = self.pending[self.head];
        self.head = (self.head + 1) % queue_capacity;
        self.count -= 1;
        return event;
    }

    /// Each raw event emits at most two UI events. An overflow is explicit;
    /// callers should drain events between feed calls instead of dropping keys.
    pub fn feed(self: *Decoder, event: input.Event, x_axis: input.Axis, y_axis: input.Axis) !void {
        if (self.count > queue_capacity - 2) return error.InputQueueFull;
        switch (event.event_type) {
            0 => if (event.code == 0 and self.moved) {
                self.push(1, 0);
                self.moved = false;
            },
            2 => switch (event.code) {
                0 => {
                    self.x = clamp(@as(i64, self.x) + event.value, self.width);
                    self.moved = true;
                },
                1 => {
                    self.y = clamp(@as(i64, self.y) + event.value, self.height);
                    self.moved = true;
                },
                8 => self.push(7, @bitCast(@as(i16, @intCast(std.math.clamp(event.value, -32768, 32767))))),
                else => {},
            },
            3 => switch (event.code) {
                0 => {
                    self.x = try absolute(event.value, x_axis, self.width);
                    self.moved = true;
                },
                1 => {
                    self.y = try absolute(event.value, y_axis, self.height);
                    self.moved = true;
                },
                else => {},
            },
            1 => try self.key(event.code, event.value),
            else => {},
        }
    }

    fn modifiers(self: *const Decoder) u8 {
        return @as(u8, @intFromBool(self.shift_left or self.shift_right)) |
            (@as(u8, @intFromBool(self.control_left or self.control_right)) << 1) |
            (@as(u8, @intFromBool(self.alt_left or self.alt_right)) << 2) |
            (@as(u8, @intFromBool(self.super_left or self.super_right)) << 3);
    }

    fn push(self: *Decoder, kind: u8, code: u16) void {
        const encoded = @as(u64, kind) | (@as(u64, self.modifiers()) << 8) | (@as(u64, code) << 16) |
            (@as(u64, @as(u16, @bitCast(@as(i16, @intCast(self.x))))) << 32) |
            (@as(u64, @as(u16, @bitCast(@as(i16, @intCast(self.y))))) << 48);
        self.pending[(self.head + self.count) % queue_capacity] = encoded;
        self.count += 1;
    }

    fn key(self: *Decoder, code: u16, value: i32) !void {
        if (value < 0 or value > 2) return; // Ignore malformed/unknown values.
        const down = value != 0;
        switch (code) {
            42 => {
                self.shift_left = down;
                return;
            },
            54 => {
                self.shift_right = down;
                return;
            },
            29 => {
                self.control_left = down;
                return;
            },
            97 => {
                self.control_right = down;
                return;
            },
            56 => {
                self.alt_left = down;
                return;
            },
            100 => {
                self.alt_right = down;
                return;
            },
            125 => {
                self.super_left = down;
                return;
            },
            126 => {
                self.super_right = down;
                return;
            },
            58 => {
                if (value == 1) self.caps_lock = !self.caps_lock;
                return;
            },
            0x110, 0x111, 0x112 => {
                self.push(if (down) 2 else 3, switch (code) {
                    0x110 => 1,
                    0x112 => 2,
                    else => 3,
                });
                return;
            },
            else => {},
        }
        const base = keyCode(code) orelse return;
        self.push(if (down) 4 else 5, base);
        if (!down or self.control_left or self.control_right or self.alt_left or self.alt_right or self.super_left or self.super_right) return;
        if (base < 32 or base > 126) return;
        const shifted = self.shift_left or self.shift_right;
        var character = base;
        if (base >= 'a' and base <= 'z') {
            if (shifted != self.caps_lock) character -= 'a' - 'A';
        } else if (shifted) character = shiftPunctuation(base);
        self.push(6, character);
    }
};

fn clamp(value: i64, size: i32) i32 {
    return @intCast(std.math.clamp(value, 0, @as(i64, size) - 1));
}
fn absolute(value: i32, axis: input.Axis, size: i32) !i32 {
    const span = @as(i64, axis.maximum) - axis.minimum;
    if (span <= 0) return error.InvalidInputAxis;
    const offset = std.math.clamp(@as(i64, value) - axis.minimum, 0, span);
    return @intCast(@divTrunc(offset * (@as(i64, size) - 1), span));
}

fn keyCode(code: u16) ?u16 {
    const numbers = "1234567890-=";
    const top = "qwertyuiop[]";
    const middle = "asdfghjkl;'`";
    const bottom = "zxcvbnm,./";
    if (code >= 2 and code <= 13) return numbers[code - 2];
    if (code >= 16 and code <= 27) return top[code - 16];
    if (code >= 30 and code <= 41) return middle[code - 30];
    if (code >= 44 and code <= 53) return bottom[code - 44];
    return switch (code) {
        1 => 27,
        14 => 8,
        15 => 9,
        28 => 13,
        43 => '\\',
        57 => ' ',
        105 => 0x100,
        106 => 0x101,
        103 => 0x102,
        108 => 0x103,
        102 => 0x104,
        107 => 0x105,
        104 => 0x106,
        109 => 0x107,
        60 => 0x108,
        63 => 0x109,
        62 => 0x10a,
        87 => 0x10b,
        111 => 127,
        else => null,
    };
}
fn shiftPunctuation(character: u16) u16 {
    const plain = "1234567890-=[];'`,./\\";
    const shifted = "!@#$%^&*()_+{}:\"~<>?|";
    for (plain, shifted) |before, after| if (character == before) return after;
    return character;
}

test "absolute and relative pointer events clamp to viewport and finish at SYN" {
    var decoder = try Decoder.init(800, 600);
    try decoder.feed(.{ .event_type = 3, .code = 0, .value = 32767 }, .{}, .{});
    try decoder.feed(.{ .event_type = 3, .code = 1, .value = 16384 }, .{}, .{});
    try std.testing.expectEqual(@as(?u64, null), decoder.pop());
    try decoder.feed(.{ .event_type = 0, .code = 0, .value = 0 }, .{}, .{});
    const event = decoder.pop().?;
    try std.testing.expectEqual(@as(u64, 1), event & 255);
    try std.testing.expectEqual(@as(u64, 799), (event >> 32) & 0xffff);
    try std.testing.expectEqual(@as(u64, 299), event >> 48);
    try decoder.feed(.{ .event_type = 2, .code = 0, .value = std.math.minInt(i32) }, .{}, .{});
    try std.testing.expectEqual(@as(i32, 0), decoder.x);
}

test "keyboard emits separate key/text events and tracks modifiers and button identity" {
    var decoder = try Decoder.init(100, 100);
    try decoder.feed(.{ .event_type = 1, .code = 42, .value = 1 }, .{}, .{});
    try decoder.feed(.{ .event_type = 1, .code = 30, .value = 1 }, .{}, .{});
    const key = decoder.pop().?;
    try std.testing.expectEqual(@as(u64, 4 | (1 << 8) | ('a' << 16)), key);
    try std.testing.expectEqual(@as(u64, 6 | (1 << 8) | ('A' << 16)), decoder.pop().?);
    try decoder.feed(.{ .event_type = 1, .code = 0x111, .value = 0 }, .{}, .{});
    try std.testing.expectEqual(@as(u64, 3 | (1 << 8) | (3 << 16)), decoder.pop().?);
    try decoder.feed(.{ .event_type = 1, .code = 62, .value = 1 }, .{}, .{});
    try std.testing.expectEqual(@as(u64, 4 | (1 << 8) | (0x10a << 16)), decoder.pop().?);
    try decoder.feed(.{ .event_type = 1, .code = 87, .value = 1 }, .{}, .{});
    try std.testing.expectEqual(@as(u64, 4 | (1 << 8) | (0x10b << 16)), decoder.pop().?);
}

test "unknown events are ignored and full decoded queue fails explicitly" {
    var decoder = try Decoder.init(10, 10);
    try decoder.feed(.{ .event_type = 0xffff, .code = 0, .value = 0 }, .{}, .{});
    try std.testing.expectEqual(@as(?u64, null), decoder.pop());
    for (0..16) |_| try decoder.feed(.{ .event_type = 1, .code = 30, .value = 1 }, .{}, .{});
    try std.testing.expectError(error.InputQueueFull, decoder.feed(.{ .event_type = 1, .code = 30, .value = 1 }, .{}, .{}));
    try std.testing.expectError(error.InvalidInputViewport, Decoder.init(32769, 100));
    try std.testing.expectError(error.InvalidInputAxis, absolute(1, .{ .minimum = 5, .maximum = 5 }, 100));
}
