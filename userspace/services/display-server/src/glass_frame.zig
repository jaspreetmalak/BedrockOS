//! Service-owned window silhouette, applied after all permitted client pixels.
//! The small corner snapshot contains scene pixels only inside the compositor.
const ui = @import("axisui");

pub const radius: u32 = 8;
pub const caption: ui.Material = .{ .tint = ui.Color.rgb(42, 46, 59), .opacity = 112 };

pub const Corners = struct {
    pixels: [4][radius * radius]u32 = undefined,
    frame: ui.Rect,

    pub fn capture(self: *Corners, surface: *const ui.Surface, frame: ui.Rect) void {
        self.frame = frame;
        for (0..4) |corner| for (0..radius) |y| for (0..radius) |x| {
            const point = self.cornerPoint(corner, x, y);
            if (inside(surface, point.x, point.y)) self.pixels[corner][y * radius + x] = surface.pixels[@as(usize, @intCast(point.y)) * surface.stride + @as(usize, @intCast(point.x))];
        };
    }

    /// Opaque producer pixels cannot turn a rounded window into a square one.
    /// Full-coverage interiors are left untouched; edges blend with the saved
    /// underlying scene, including earlier windows and the soft shadow.
    pub fn finish(self: *const Corners, surface: *ui.Surface) void {
        for (0..4) |corner| for (0..radius) |y| for (0..radius) |x| {
            const point = self.cornerPoint(corner, x, y);
            if (!inside(surface, point.x, point.y)) continue;
            const coverage = ui.materials.roundedCoverage(self.frame.width, self.frame.height, radius, point.x - self.frame.x, point.y - self.frame.y);
            if (coverage == 255) continue;
            const index = @as(usize, @intCast(point.y)) * surface.stride + @as(usize, @intCast(point.x));
            const painted = surface.decode(surface.pixels[index]);
            surface.pixels[index] = self.pixels[corner][y * radius + x];
            surface.blendPixel(@intCast(point.x), @intCast(point.y), painted, coverage);
        };
    }

    fn cornerPoint(self: *const Corners, corner: usize, x: usize, y: usize) struct { x: i64, y: i64 } {
        return .{
            .x = @as(i64, self.frame.x) + @as(i64, @intCast(x)) + if (corner & 1 != 0) @as(i64, self.frame.width) - radius else 0,
            .y = @as(i64, self.frame.y) + @as(i64, @intCast(y)) + if (corner & 2 != 0) @as(i64, self.frame.height) - radius else 0,
        };
    }
};

/// A quiet quadratic falloff around an offset rounded frame. Only the outside
/// strips and corner rows are visited; no extra surface or allocation is used.
pub fn shadow(surface: *ui.Surface, frame: ui.Rect) void {
    const spread: i64 = 24;
    const left = @max(@as(i64, 0), @as(i64, frame.x) - spread);
    const right = @min(@as(i64, surface.width), @as(i64, frame.x) + frame.width + spread);
    const top = @max(@as(i64, 0), @as(i64, frame.y) - spread + 6);
    const bottom = @min(@as(i64, surface.height), @as(i64, frame.y) + frame.height + spread + 6);
    var y: i64 = top;
    while (y < bottom) : (y += 1) {
        const strip = y >= @as(i64, frame.y) + radius and y < @as(i64, frame.y) + frame.height - radius;
        var x: i64 = left;
        while (x < right) : (x += 1) {
            if (strip and x >= frame.x and x < @as(i64, frame.x) + frame.width) {
                x = @as(i64, frame.x) + frame.width - 1;
                continue;
            }
            const dx = @max(@as(i64, 0), @max(@as(i64, frame.x) + radius - x, x - (@as(i64, frame.x) + frame.width - radius - 1)));
            const dy = @max(@as(i64, 0), @max(@as(i64, frame.y) + 6 + radius - y, y - (@as(i64, frame.y) + 6 + frame.height - radius - 1)));
            const distance = dx * dx + dy * dy;
            const outer: i64 = (radius + spread) * (radius + spread);
            if (distance >= outer) continue;
            const remaining: u64 = @intCast(outer - @max(@as(i64, radius * radius), distance));
            const range: u64 = @intCast(outer - radius * radius);
            const opacity: u8 = @intCast((remaining * remaining * 52 + range * range / 2) / (range * range));
            surface.blendPixel(@intCast(x), @intCast(y), ui.Color.rgb(5, 7, 13), opacity);
        }
    }
}

fn inside(surface: *const ui.Surface, x: i64, y: i64) bool {
    return x >= 0 and y >= 0 and x < surface.width and y < surface.height;
}

test "producer paint cannot escape rounded service corners or overwrite neighboring pixels" {
    const t = @import("std").testing;
    var pixels: [64 * 48]u32 = @splat(0x243348);
    var surface = try ui.Surface.init(&pixels, 60, 48, 64, .{ .red = 0xff0000, .green = 0xff00, .blue = 0xff });
    const frame: ui.Rect = .{ .x = 4, .y = 5, .width = 44, .height = 36 };
    var saved: Corners = undefined;
    saved.capture(&surface, frame);
    surface.fillRect(4, 5, 44, 36, 0xf0e0d0);
    saved.finish(&surface);
    try t.expectEqual(@as(u32, 0x243348), pixels[5 * 64 + 4]);
    try t.expectEqual(@as(u32, 0xf0e0d0), pixels[20 * 64 + 20]);
    try t.expectEqual(@as(u32, 0x243348), pixels[5 * 64 + 3]);
    try t.expectEqual(@as(u32, 0x243348), pixels[20 * 64 + 63]);
    var partial: usize = 0;
    for (5..41) |y| for (4..48) |x| if (pixels[y * 64 + x] != 0x243348 and pixels[y * 64 + x] != 0xf0e0d0) {
        partial += 1;
    };
    try t.expect(partial > 0);
}

test "offscreen rounded frames and shadows preserve stride guards" {
    const t = @import("std").testing;
    var pixels: [56 * 48]u32 = @splat(0x243348);
    var surface = try ui.Surface.init(&pixels, 48, 48, 56, .{ .red = 0xff0000, .green = 0xff00, .blue = 0xff });
    const frame: ui.Rect = .{ .x = -5, .y = -4, .width = 40, .height = 36 };
    shadow(&surface, frame);
    var saved: Corners = undefined;
    saved.capture(&surface, frame);
    surface.fillRect(0, 0, 35, 32, 0xf0e0d0);
    saved.finish(&surface);
    for (0..48) |y| for (48..56) |x| try t.expectEqual(@as(u32, 0x243348), pixels[y * 56 + x]);
}
