//! Original procedural wallpaper: integer row spans, no assets or allocation.
const ui = @import("axisui");
const Color = ui.Color;
pub const charcoal = Color.rgb(35, 37, 47);
const rose = Color.rgb(151, 100, 123);
const blue = Color.rgb(108, 146, 179);
const strengths = [_]u8{ 8, 18, 32, 49, 70, 96 };
pub const max_fills_per_row = 15;

pub fn render(surface: *ui.Surface) !void {
    try surface.validate();
    const width = surface.width;
    const height = surface.height;
    for (0..surface.height) |row| {
        const y: u32 = @intCast(row);
        const shade: u8 = @intCast(y * 5 / height);
        const base = Color.rgb(charcoal.r - shade, charcoal.g - shade, charcoal.b - shade);
        surface.fillRect(0, @intCast(row), surface.width, 1, surface.encode(base));

        // Nested parabolic spans make broad curved planes with restrained edge
        // falloff. Their moving centers tilt the rose and blue forms diagonally.
        for (strengths, 0..) |strength, layer| {
            const inset: u32 = @intCast(layer);
            shape(surface, y, width * 15 / 100 + y * width / (height * 9), height * 66 / 100, width * (59 - inset * 3) / 100, height * (94 - inset * 5) / 100, mix(base, rose, strength));
        }
        for (strengths, 0..) |strength, layer| {
            const inset: u32 = @intCast(layer);
            shape(surface, y, width * 86 / 100 - y * width / (height * 12), height * 28 / 100, width * (49 - inset * 3) / 100, height * (86 - inset * 5) / 100, mix(base, blue, strength));
        }
        // Two quiet straight accents echo the curved planes without noise or
        // per-pixel commands. All row writes remain clipped by the Surface.
        span(surface, y, width * 30 / 100 + y * width / (height * 5), width * 30 / 100 + y * width / (height * 5) + @max(1, width / 48), mix(base, rose, 25));
        span(surface, y, width * 72 / 100 - y * width / (height * 8), width * 72 / 100 - y * width / (height * 8) + @max(1, width / 160), mix(base, blue, 42));
    }
}

fn mix(base: Color, accent: Color, strength: u8) Color {
    const inverse: u32 = 255 - @as(u32, strength);
    return Color.rgb(
        @intCast((@as(u32, base.r) * inverse + @as(u32, accent.r) * strength + 127) / 255),
        @intCast((@as(u32, base.g) * inverse + @as(u32, accent.g) * strength + 127) / 255),
        @intCast((@as(u32, base.b) * inverse + @as(u32, accent.b) * strength + 127) / 255),
    );
}

fn shape(surface: *ui.Surface, y: i64, cx: i64, cy: i64, rx: i64, ry: i64, color: Color) void {
    if (rx == 0 or ry == 0) return;
    const dy = y - cy;
    if (@abs(dy) >= @as(u64, @intCast(ry))) return;
    // Surface dimensions are validated <=16384; every product fits signed64.
    const squared_radius = ry * ry;
    const half = @divTrunc(rx * (squared_radius - dy * dy), squared_radius);
    span(surface, y, cx - half, cx + half, color);
}

fn span(surface: *ui.Surface, y: i64, left: i64, right: i64, color: Color) void {
    const start = @max(0, left);
    const end = @min(@as(i64, surface.width), right);
    if (end <= start) return;
    surface.fillRect(@intCast(start), @intCast(y), @intCast(end - start), 1, surface.encode(color));
}
