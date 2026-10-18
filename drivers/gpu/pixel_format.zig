//! Convert logical RGB8 pixels into the validated firmware channel masks.
const std = @import("std");

pub const Channel = struct {
    mask: u32,
    maximum: u64,
    shift: u5,
    contiguous: bool,

    pub fn init(mask: u32) Channel {
        const shift: u5 = if (mask == 0) 0 else @intCast(@ctz(mask));
        const maximum = (@as(u64, 1) << @as(u6, @intCast(@popCount(mask)))) - 1;
        return .{ .mask = mask, .maximum = maximum, .shift = shift, .contiguous = @as(u64, mask >> shift) == maximum };
    }

    pub fn encode(self: Channel, component: u8) u32 {
        var scaled = (@as(u64, component) * self.maximum + 127) / 255;
        if (self.contiguous) return @as(u32, @intCast(scaled)) << self.shift;
        var output: u32 = 0;
        var remaining = self.mask;
        while (remaining != 0) {
            const bit: u5 = @intCast(@ctz(remaining));
            if (scaled & 1 != 0) output |= @as(u32, 1) << bit;
            scaled >>= 1;
            remaining &= remaining - 1;
        }
        return output;
    }
};

pub const Format = struct {
    red: Channel,
    green: Channel,
    blue: Channel,

    pub fn init(red: u32, green: u32, blue: u32) Format {
        return .{ .red = Channel.init(red), .green = Channel.init(green), .blue = Channel.init(blue) };
    }

    pub fn encode(self: Format, rgb: u32) u32 {
        return self.red.encode(@truncate(rgb >> 16)) | self.green.encode(@truncate(rgb >> 8)) | self.blue.encode(@truncate(rgb));
    }
};

test "RGB and BGR scanout preserve eight-bit channel values" {
    const rgb = Format.init(0xff0000, 0xff00, 0xff);
    const bgr = Format.init(0xff, 0xff00, 0xff0000);
    try std.testing.expectEqual(@as(u32, 0xd495ad), rgb.encode(0xd495ad));
    try std.testing.expectEqual(@as(u32, 0xad95d4), bgr.encode(0xd495ad));
    for (0..256) |component| {
        const value: u8 = @intCast(component);
        try std.testing.expectEqual(@as(u32, value) << 16, rgb.red.encode(value));
    }
}

test "sparse and wide firmware masks scale without overflow or leaking bits" {
    const sparse = Channel.init(0x55);
    try std.testing.expectEqual(@as(u32, 0x40), sparse.encode(128));
    try std.testing.expectEqual(@as(u32, 0x55), sparse.encode(255));
    const wide = Format.init(0xfffffffc, 1, 2);
    try std.testing.expectEqual(@as(u32, 0xffffffff), wide.encode(0xffffff));
    try std.testing.expectEqual(@as(u32, 0), wide.encode(0));
    try std.testing.expectEqual(@as(u32, @intCast(((@as(u64, 128) * 0x3fffffff + 127) / 255) << 2)), wide.encode(0x800000));
    try std.testing.expectEqual(@as(u32, 0xffffffff), Channel.init(0xffffffff).encode(255));
    try std.testing.expectEqual(@as(u32, 0), Channel.init(0).encode(255));
    for (0..256) |component| try std.testing.expectEqual(@as(u32, 0), sparse.encode(@intCast(component)) & ~@as(u32, 0x55));
}
