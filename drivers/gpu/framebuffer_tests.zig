const std = @import("std");
const t = std.testing;
const protocol = @import("boot_protocol");
const core = @import("anvil_core");
const Driver = @import("framebuffer.zig").Driver;
const Format = @import("pixel_format.zig").Format;
const sentinel: u32 = 0x9abcdef0;

fn framebuffer(pixels: []u32, width: u32, height: u32, stride: u32, red: u32, green: u32, blue: u32) protocol.Framebuffer {
    return .{ .base = @intFromPtr(pixels.ptr), .size = pixels.len * 4, .width = width, .height = height, .pixels_per_scanline = stride, .format = 1, .red_mask = red, .green_mask = green, .blue_mask = blue };
}

test "Anvil framebuffer copies only requested RGB or BGR pixels and releases source imports" {
    for ([_]bool{ false, true }) |bgr| {
        var backing: [2 + 15 * 16]u32 = @splat(sentinel);
        var source: [2 + 10 * 12]u32 = undefined;
        for (&source, 0..) |*pixel, i| pixel.* = 0xff000000 | @as(u32, @intCast(i * 10137));
        const original = source;
        var driver: Driver = .{};
        try driver.initialize(framebuffer(backing[1 .. backing.len - 1], 12, 16, 15, if (bgr) 0xff else 0xff0000, 0xff00, if (bgr) 0xff0000 else 0xff));
        try t.expectEqual(.software, driver.queue.?.device.acceleration);
        const image: core.Image = .{ .pixels = source[1 .. source.len - 1], .width = 8, .height = 12, .stride = 10, .format = .xrgb8888, .access = .read_only };
        // Capacity is exactly framebuffer + one temporary source. Repetition
        // proves each completed import is retired without retaining a texture.
        for (1..101) |sequence| {
            const fence = try driver.present(image, .{ .x = 2, .y = 3, .width = 3, .height = 4 }, .{ .x = 4, .y = 5 });
            try t.expectEqual(@as(u64, sequence), fence.sequence);
            try t.expectEqual(fence.sequence, (try driver.queue.?.completed()).sequence);
        }
        for (0..16) |y| for (0..15) |x| {
            var expected = sentinel;
            if (y >= 5 and y < 9 and x >= 4 and x < 7) {
                const rgb = source[1 + (y - 5 + 3) * 10 + x - 4 + 2] & 0xffffff;
                expected = if (bgr) ((rgb & 0xff) << 16) | (rgb & 0xff00) | ((rgb >> 16) & 0xff) else rgb;
            }
            try t.expectEqual(expected, backing[1 + y * 15 + x]);
        };
        try t.expectEqual(sentinel, backing[0]);
        try t.expectEqual(sentinel, backing[backing.len - 1]);
        try t.expectEqualSlices(u32, &original, &source);
    }
}

test "Anvil framebuffer failures do not write pixels or advance a fence" {
    var backing: [10 * 12]u32 = @splat(sentinel);
    var source: [10 * 12]u32 = @splat(0x112233);
    const image: core.Image = .{ .pixels = &source, .width = 8, .height = 12, .stride = 10, .format = .xrgb8888 };
    var driver: Driver = .{};
    try t.expectError(error.NotInitialized, driver.present(image, .{ .x = 0, .y = 0, .width = 1, .height = 1 }, .{ .x = 0, .y = 0 }));
    const display = framebuffer(&backing, 8, 12, 10, 0xff0000, 0xff00, 0xff);
    try driver.initialize(display);
    try t.expectError(error.AlreadyInitialized, driver.initialize(display));
    try t.expectError(error.OutOfBounds, driver.present(image, .{ .x = 7, .y = 0, .width = 2, .height = 1 }, .{ .x = 0, .y = 0 }));
    try t.expectError(error.OutOfBounds, driver.present(image, .{ .x = 0, .y = 0, .width = 2, .height = 1 }, .{ .x = 7, .y = 0 }));
    try t.expectError(error.Overflow, driver.present(image, .{ .x = std.math.maxInt(u32), .y = 0, .width = 2, .height = 1 }, .{ .x = 0, .y = 0 }));
    try t.expectError(error.EmptyExtent, driver.present(image, .{ .x = 0, .y = 0, .width = 0, .height = 1 }, .{ .x = 0, .y = 0 }));
    var short = image;
    short.pixels = source[0..4];
    try t.expectError(error.BufferTooSmall, driver.present(short, .{ .x = 0, .y = 0, .width = 1, .height = 1 }, .{ .x = 0, .y = 0 }));
    var alias = image;
    alias.pixels = &backing;
    try t.expectError(error.AliasedImage, driver.present(alias, .{ .x = 0, .y = 0, .width = 1, .height = 1 }, .{ .x = 0, .y = 0 }));
    try t.expectEqual(@as(u64, 0), driver.sequence);
    for (backing) |pixel| try t.expectEqual(sentinel, pixel);
    driver.sequence = std.math.maxInt(u64);
    try t.expectError(error.SequenceExhausted, driver.present(image, .{ .x = 0, .y = 0, .width = 1, .height = 1 }, .{ .x = 0, .y = 0 }));
    for (backing) |pixel| try t.expectEqual(sentinel, pixel);
}

test "uncommon firmware masks keep exact bounded software conversion" {
    var backing: [2 + 10 * 12]u32 = @splat(sentinel);
    var source: [10 * 12]u32 = @splat(0xff3355aa); // xbgr8888 -> RGB aa5533
    var driver: Driver = .{};
    try driver.initialize(framebuffer(backing[1 .. backing.len - 1], 8, 12, 10, 0xf800, 0x7e0, 0x1f));
    try t.expect(driver.queue == null and driver.target == null);
    const fence = try driver.present(.{ .pixels = &source, .width = 8, .height = 12, .stride = 10, .format = .xbgr8888 }, .{ .x = 1, .y = 2, .width = 3, .height = 4 }, .{ .x = 2, .y = 3 });
    try t.expectEqual(@as(u64, 1), fence.sequence);
    const expected = Format.init(0xf800, 0x7e0, 0x1f).encode(0xaa5533);
    for (0..12) |y| for (0..10) |x| {
        try t.expectEqual(if (x >= 2 and x < 5 and y >= 3 and y < 7) expected else sentinel, backing[1 + y * 10 + x]);
    };
    try t.expectEqual(sentinel, backing[0]);
    try t.expectEqual(sentinel, backing[backing.len - 1]);
}
