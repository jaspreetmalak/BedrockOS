const std = @import("std");
const ui = @import("axisui");
const wallpaper = @import("wallpaper.zig");

// Independent reference keeps the original per-span formulas and evaluation
// order, including truncation before squaring each normalized axis.
fn reference(surface: *ui.Surface) !void {
    try surface.validate();
    const columns = @min(surface.width, 128);
    for (0..surface.height) |row| {
        const y: i64 = @intCast(row * 1024 / surface.height);
        const shade: u8 = @intCast(row * 5 / surface.height);
        const base = ui.Color.rgb(27 - shade, 30 - shade, 40 - shade);
        for (0..columns) |column| {
            const left: u32 = @intCast(column * surface.width / columns);
            const right: u32 = @intCast((column + 1) * surface.width / columns);
            const x: i64 = @intCast((@as(u64, left) + right) * 512 / surface.width);
            const warm = referenceField(x, y, 180, 750, 950, 900) * 112 / 1024;
            const cool = referenceField(x, y, 930, 190, 860, 800) * 122 / 1024;
            const light = referenceField(x, y, 480, 480, 900, 900) * 12 / 1024;
            const color = ui.Color.rgb(
                referenceChannel(base.r, 116, 71, warm, cool, light),
                referenceChannel(base.g, 75, 111, warm, cool, light),
                referenceChannel(base.b, 93, 142, warm, cool, light),
            );
            surface.fillRect(left, @intCast(row), right - left, 1, surface.encode(color));
        }
    }
}

fn referenceField(x: i64, y: i64, cx: i64, cy: i64, rx: i64, ry: i64) u32 {
    const dx = @divTrunc((x - cx) * 1024, rx);
    const dy = @divTrunc((y - cy) * 1024, ry);
    const distance = @divTrunc(dx * dx + dy * dy, 1024);
    const remaining = @max(0, 1024 - distance);
    return @intCast(@divTrunc(remaining * remaining, 1024));
}

fn referenceChannel(base: u8, warm: u8, cool: u8, warm_strength: u32, cool_strength: u32, light: u32) u8 {
    const value = @as(u32, base) + (@as(u32, warm) - base) * warm_strength / 255 +
        (@as(u32, cool) - base) * cool_strength / 255 + light;
    return @intCast(value);
}

const formats = [_]ui.PixelMasks{
    .{ .red = 0xff0000, .green = 0xff00, .blue = 0xff },
    .{ .red = 0xff, .green = 0xff00, .blue = 0xff0000, .reserved = 0xff000000 },
    .{ .red = 0xf800, .green = 0x7e0, .blue = 0x1f },
};
const guard: u32 = 0x91eda5b3;

fn compare(width: u32, height: u32, padding: u32, masks: ui.PixelMasks) !void {
    const t = std.testing;
    const stride = width + padding;
    const count = @as(usize, stride) * height;
    const actual = try t.allocator.alloc(u32, count + 2);
    defer t.allocator.free(actual);
    const expected = try t.allocator.alloc(u32, count + 2);
    defer t.allocator.free(expected);
    @memset(actual, guard);
    @memset(expected, guard);
    var surface = try ui.Surface.init(actual[1 .. count + 1], width, height, stride, masks);
    var original = try ui.Surface.init(expected[1 .. count + 1], width, height, stride, masks);
    try wallpaper.render(&surface);
    try reference(&original);
    try t.expectEqualSlices(u32, expected, actual);
    try t.expectEqual(guard, actual[0]);
    try t.expectEqual(guard, actual[count + 1]);
    for (0..height) |row| for (width..stride) |column| try t.expectEqual(guard, actual[1 + row * stride + column]);
}

test "wallpaper hoisted row terms preserve every tiny and odd geometry pixel and padding" {
    const sizes = [_][2]u32{ .{ 1, 1 }, .{ 1, 19 }, .{ 3, 7 }, .{ 17, 11 }, .{ 127, 31 }, .{ 129, 37 }, .{ 257, 65 } };
    for (sizes) |size| for (formats) |masks| for ([_]u32{ 0, 1, 3 }) |padding| try compare(size[0], size[1], padding, masks);
}

test "wallpaper hoisted row terms exactly preserve both reference desktops with pixel masks and guards" {
    for ([_][2]u32{ .{ 800, 600 }, .{ 1280, 800 } }) |size| for (formats) |masks| try compare(size[0], size[1], 3, masks);
}

test "wallpaper rejects malformed surfaces before changing pixels" {
    const t = std.testing;
    var pixels: [32]u32 = @splat(guard);
    var surface = try ui.Surface.init(&pixels, 7, 4, 8, formats[0]);
    surface.stride = 6;
    try t.expectError(error.InvalidSurface, wallpaper.render(&surface));
    for (pixels) |pixel| try t.expectEqual(guard, pixel);
}
