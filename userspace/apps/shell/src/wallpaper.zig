//! Original continuous light fields: bounded integer spans, no assets or heap.
const ui = @import("axisui");
const Color = ui.Color;
pub const charcoal = Color.rgb(27, 30, 40);
const rose = Color.rgb(116, 75, 93);
const blue = Color.rgb(71, 111, 142);
pub const max_fills_per_row = 128;
const fields = [_]struct { cx: i64, cy: i64, rx: i64, ry: i64 }{
    .{ .cx = 180, .cy = 750, .rx = 950, .ry = 900 },
    .{ .cx = 930, .cy = 190, .rx = 860, .ry = 800 },
    .{ .cx = 480, .cy = 480, .rx = 900, .ry = 900 },
};

pub fn render(surface: *ui.Surface) !void {
    try surface.validate();
    const columns = @min(surface.width, max_fills_per_row);
    for (0..surface.height) |row| {
        const y: i64 = @intCast(row * 1024 / surface.height);
        const shade: u8 = @intCast(row * 5 / surface.height);
        const base = Color.rgb(charcoal.r - shade, charcoal.g - shade, charcoal.b - shade);
        // Only retain three row terms. Apps share the native 16KiB stack
        // budget, so a full column table cannot live in this call chain.
        var y_squared: [fields.len]i64 = undefined;
        inline for (fields, 0..) |geometry, i| {
            const dy = @divTrunc((y - geometry.cy) * 1024, geometry.ry);
            y_squared[i] = dy * dy;
        }
        for (0..columns) |column| {
            const left: u32 = @intCast(column * surface.width / columns);
            const right: u32 = @intCast((column + 1) * surface.width / columns);
            const x: i64 = @intCast((@as(u64, left) + right) * 512 / surface.width);
            const warm = field(x, 0, y_squared[0]) * 112 / 1024;
            const cool = field(x, 1, y_squared[1]) * 122 / 1024;
            const light = field(x, 2, y_squared[2]) * 12 / 1024;
            const color = Color.rgb(
                channel(base.r, rose.r, blue.r, warm, cool, light),
                channel(base.g, rose.g, blue.g, warm, cool, light),
                channel(base.b, rose.b, blue.b, warm, cool, light),
            );
            surface.fillRect(left, @intCast(row), right - left, 1, surface.encode(color));
        }
    }
}

/// Squared falloff has zero slope at the light field's outer edge. Positions
/// are normalized to 1024, so both tiny and reference surfaces share the same
/// composition without a sharp ellipse outline or fixed-resolution asset.
fn field(x: i64, comptime index: usize, y_squared: i64) u32 {
    const geometry = fields[index];
    const dx = @divTrunc((x - geometry.cx) * 1024, geometry.rx);
    const distance = @divTrunc(dx * dx + y_squared, 1024);
    const remaining = @max(0, 1024 - distance);
    return @intCast(@divTrunc(remaining * remaining, 1024));
}

fn channel(base: u8, warm: u8, cool: u8, warm_strength: u32, cool_strength: u32, light: u32) u8 {
    const value = @as(u32, base) + (@as(u32, warm) - base) * warm_strength / 255 +
        (@as(u32, cool) - base) * cool_strength / 255 + light;
    return @intCast(value);
}
