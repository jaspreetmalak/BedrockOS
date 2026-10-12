//! Original 16-pixel native navigation shapes. Placement is caller-owned; every
//! emitted run is clipped to the surface for pixel and command backends alike.
const surface_module = @import("surface.zig");
const Surface = surface_module.Surface;
const Error = surface_module.Error;
const Color = @import("types.zig").Color;
const Point = @import("input.zig").Point;
pub const size: u32 = 16;
pub const Icon = enum { folder, document, home, chevron_left, chevron_right, chevron_up, chevron_down };

fn horizontal(rows: *[16]u16, y: usize, first: usize, last: usize) void {
    for (first..last + 1) |x| rows[y] |= @as(u16, 1) << @intCast(15 - x);
}
fn vertical(rows: *[16]u16, x: usize, first: usize, last: usize) void {
    for (first..last + 1) |y| horizontal(rows, y, x, x);
}
pub fn pattern(icon: Icon) [16]u16 {
    return patterns[@backingInt(icon)];
}
const patterns = blk: {
    var values: [7][16]u16 = @splat(@splat(0));
    const folder = &values[@backingInt(Icon.folder)];
    horizontal(folder, 2, 2, 6);
    horizontal(folder, 3, 2, 13);
    horizontal(folder, 5, 1, 14);
    horizontal(folder, 13, 1, 14);
    vertical(folder, 2, 2, 5);
    vertical(folder, 13, 3, 5);
    vertical(folder, 1, 5, 13);
    vertical(folder, 14, 5, 13);
    const document = &values[@backingInt(Icon.document)];
    horizontal(document, 1, 4, 9);
    horizontal(document, 14, 4, 12);
    vertical(document, 4, 1, 14);
    vertical(document, 12, 4, 14);
    vertical(document, 9, 1, 4);
    horizontal(document, 2, 10, 10);
    horizontal(document, 3, 11, 11);
    horizontal(document, 4, 9, 12);
    horizontal(document, 7, 6, 10);
    horizontal(document, 10, 6, 10);
    const home = &values[@backingInt(Icon.home)];
    for (0..6) |step| {
        horizontal(home, 2 + step, 7 - step, 7 - step);
        horizontal(home, 2 + step, 7 + step, 7 + step);
    }
    vertical(home, 3, 7, 13);
    vertical(home, 11, 7, 13);
    horizontal(home, 13, 3, 11);
    vertical(home, 6, 10, 13);
    vertical(home, 8, 10, 13);
    horizontal(home, 10, 6, 8);
    for (0..5) |step| {
        horizontal(&values[@backingInt(Icon.chevron_left)], 3 + step, 10 - step, 10 - step);
        horizontal(&values[@backingInt(Icon.chevron_left)], 11 - step, 10 - step, 10 - step);
        horizontal(&values[@backingInt(Icon.chevron_right)], 3 + step, 5 + step, 5 + step);
        horizontal(&values[@backingInt(Icon.chevron_right)], 11 - step, 5 + step, 5 + step);
        horizontal(&values[@backingInt(Icon.chevron_up)], 9 - step, 3 + step, 3 + step);
        horizontal(&values[@backingInt(Icon.chevron_up)], 9 - step, 11 - step, 11 - step);
        horizontal(&values[@backingInt(Icon.chevron_down)], 5 + step, 3 + step, 3 + step);
        horizontal(&values[@backingInt(Icon.chevron_down)], 5 + step, 11 - step, 11 - step);
    }
    break :blk values;
};

/// Validates before paint. Scale 1..16; signed placement can clip at any edge.
/// Direct calls do not inherit a declarative ancestor's rounded clip.
pub fn draw(surface: *Surface, icon: Icon, point: Point, color: Color, scale: u8) Error!void {
    try surface.validate();
    if (scale == 0 or scale > 16) return error.InvalidScale;
    const pixel = surface.encode(color);
    const rows = pattern(icon);
    for (rows, 0..) |bits, row| {
        var first: u32 = 0;
        while (first < size) {
            if (bits & (@as(u16, 1) << @intCast(15 - first)) == 0) {
                first += 1;
                continue;
            }
            var end = first + 1;
            while (end < size and bits & (@as(u16, 1) << @intCast(15 - end)) != 0) end += 1;
            const left = @max(@as(i64, 0), @as(i64, point.x) + first * scale);
            const top = @max(@as(i64, 0), @as(i64, point.y) + @as(i64, @intCast(row)) * scale);
            const right = @min(@as(i64, surface.width), @as(i64, point.x) + end * scale);
            const bottom = @min(@as(i64, surface.height), @as(i64, point.y) + (@as(i64, @intCast(row)) + 1) * scale);
            if (right > left and bottom > top)
                surface.fillRect(@intCast(left), @intCast(top), @intCast(right - left), @intCast(bottom - top), pixel);
            first = end;
        }
    }
}
