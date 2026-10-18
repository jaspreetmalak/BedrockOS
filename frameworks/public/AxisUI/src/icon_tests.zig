const std = @import("std");
const icons = @import("icons.zig");
const Surface = @import("surface.zig").Surface;
const Color = @import("types.zig").Color;
const rgb = @import("types.zig").PixelMasks{ .red = 0xff0000, .green = 0xff00, .blue = 0xff };

test "every native vector icon has real grayscale edges and remains inside its design box" {
    for (std.meta.tags(icons.Icon)) |icon| {
        var ink: usize = 0;
        var gray: usize = 0;
        for (0..16) |y| for (0..16) |x| {
            const alpha = icons.coverage(icon, @intCast(x), @intCast(y), 1);
            ink += @intFromBool(alpha != 0);
            gray += @intFromBool(alpha != 0 and alpha != 255);
        };
        try std.testing.expect(ink > 8);
        try std.testing.expect(gray > 8);
        try std.testing.expectEqual(@as(u8, 0), icons.coverage(icon, 16, 8, 1));
        try std.testing.expectEqual(@as(u8, 0), icons.coverage(icon, 8, 16, 1));
        try std.testing.expectEqual(@as(u8, 0), icons.coverage(icon, std.math.maxInt(u32), 8, 16));
        try std.testing.expectEqual(@as(u8, 0), icons.coverage(icon, 8, 8, 0));
        try std.testing.expectEqual(@as(u8, 0), icons.coverage(icon, 8, 8, 17));
    }
}

test "vector paths scale smoothly instead of replicating hard pixels" {
    for ([_]icons.Icon{ .close, .folder, .clock, .wifi }) |icon| {
        var differs = false;
        var gray: usize = 0;
        for (0..32) |y| for (0..32) |x| {
            const alpha = icons.coverage(icon, @intCast(x), @intCast(y), 2);
            differs = differs or alpha != icons.coverage(icon, @intCast(x / 2), @intCast(y / 2), 1);
            gray += @intFromBool(alpha != 0 and alpha != 255);
        };
        try std.testing.expect(differs and gray > 20);
    }
}

test "native control strokes retain opaque centers without boxed button borders" {
    for ([_]icons.Icon{ .minimize, .maximize, .restore, .close, .check }) |icon| {
        var solid_pixels: usize = 0;
        for (0..16) |y| for (0..16) |x| {
            solid_pixels += @intFromBool(icons.coverage(icon, @intCast(x), @intCast(y), 1) == 255);
        };
        try std.testing.expect(solid_pixels >= 8);
        try std.testing.expectEqual(@as(u8, 0), icons.coverage(icon, 0, 0, 1));
        try std.testing.expectEqual(@as(u8, 0), icons.coverage(icon, 15, 15, 1));
    }
}

test "signed clipping equals cropping the same vector and preserves every guard pixel" {
    const sentinel: u32 = 0xdeadbeef;
    const background: u32 = 0x18212c;
    var full: [32 * 32]u32 = @splat(background);
    var source = try Surface.init(&full, 32, 32, 32, rgb);
    try icons.draw(&source, .clock, .{ .x = 0, .y = 0 }, Color.rgb(217, 221, 232), 2);
    var guarded: [2 + 23 * 20]u32 = @splat(sentinel);
    var cropped = try Surface.init(guarded[1 .. guarded.len - 1], 19, 20, 23, rgb);
    cropped.fillRect(0, 0, 19, 20, background);
    try icons.draw(&cropped, .clock, .{ .x = -7, .y = -5 }, Color.rgb(217, 221, 232), 2);
    for (0..20) |y| {
        for (0..19) |x| try std.testing.expectEqual(full[(y + 5) * 32 + x + 7], guarded[1 + y * 23 + x]);
        for (19..23) |x| try std.testing.expectEqual(sentinel, guarded[1 + y * 23 + x]);
    }
    try std.testing.expectEqual(sentinel, guarded[0]);
    try std.testing.expectEqual(sentinel, guarded[guarded.len - 1]);
    const before = guarded;
    try icons.draw(&cropped, .speaker, .{ .x = std.math.minInt(i32), .y = std.math.maxInt(i32) }, Color.rgb(1, 2, 3), 16);
    try std.testing.expectError(error.InvalidScale, icons.draw(&cropped, .close, .{ .x = 0, .y = 0 }, Color.rgb(1, 2, 3), 17));
    try std.testing.expectEqualSlices(u32, &before, &guarded);
}

test "legacy diagnostics preserve the original seven binary navigation patterns" {
    for ([_]icons.Icon{ .folder, .document, .home, .chevron_left, .chevron_right, .chevron_up, .chevron_down }) |icon| {
        var pixels: [16 * 16]u32 = @splat(0);
        var surface = try Surface.init(&pixels, 16, 16, 16, rgb);
        surface.legacy_text = true;
        try icons.draw(&surface, icon, .{ .x = 0, .y = 0 }, Color.rgb(230, 235, 244), 1);
        const rows = icons.pattern(icon);
        for (0..16) |y| for (0..16) |x| {
            const expected: u32 = if (rows[y] & (@as(u16, 1) << @intCast(15 - x)) != 0) 0xe6ebf4 else 0;
            try std.testing.expectEqual(expected, pixels[y * 16 + x]);
        };
    }
}
