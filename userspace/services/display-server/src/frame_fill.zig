//! Frost behind service-owned frames. A complete opaque cached viewport and
//! caption cover the inner frame, so only its exposed rim needs material paint.
const ui = @import("axisui");
const outer: ui.Material = .{ .tint = ui.Color.rgb(36, 40, 51), .opacity = 130 };
const inner: ui.Material = .{ .tint = ui.Color.rgb(36, 40, 51), .opacity = 100 };

/// The caller validates and exclusively borrows the surface before composing.
/// cache_valid promises that subsequent opaque content covers the whole inset.
pub fn fill(surface: *ui.Surface, frame: ui.Rect, border: u32, cache_valid: bool) void {
    if (frame.width == 0 or frame.height == 0) return;
    const b = @min(border, @min(frame.width / 2, frame.height / 2));
    const x: i64 = frame.x;
    const y: i64 = frame.y;
    const inner_width = frame.width - b * 2;
    const inner_height = frame.height - b * 2;
    if (!cache_valid) {
        paint(surface, x, y, frame.width, frame.height, outer);
        paint(surface, x + b, y + b, inner_width, inner_height, inner);
    } else if (b != 0) {
        paint(surface, x, y, frame.width, b, outer);
        paint(surface, x, y + frame.height - b, frame.width, b, outer);
        paint(surface, x, y + b, b, inner_height, outer);
        paint(surface, x + frame.width - b, y + b, b, inner_height, outer);
    }
}

fn paint(surface: *ui.Surface, x: i64, y: i64, width: u32, height: u32, material: ui.Material) void {
    const left = @max(0, x);
    const top = @max(0, y);
    const right = @min(@as(i64, surface.width), x + width);
    const bottom = @min(@as(i64, surface.height), y + height);
    if (left >= right or top >= bottom) return;
    surface.materialRect(@intCast(left), @intCast(top), @intCast(right - left), @intCast(bottom - top), material);
}
