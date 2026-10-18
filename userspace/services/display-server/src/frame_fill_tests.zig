const std = @import("std");
const ui = @import("axisui");
const frame_fill = @import("frame_fill.zig");
const width = 32;
const height = 24;
const stride = 37;
const sentinel: u32 = 0x9acdef01;
const storage_len = 2 + stride * height;
const backdrop_colors = [_]u32{ 0x123456, 0x987654, 0x294877, 0x102e42, 0x6688aa, 0x187f93, 0xdca073, 0x564a66, 0x113f75, 0x9277a8, 0x6d435c, 0x637f8b };
const backdrop: ui.Backdrop = .{ .colors = &backdrop_colors, .width = width, .height = height, .stride = 4 };

fn initialize(storage: *[storage_len]u32, masks: ui.PixelMasks, with_backdrop: bool) !ui.Surface {
    @memset(storage, sentinel);
    var surface = try ui.Surface.init(storage[1 .. storage.len - 1], width, height, stride, masks);
    for (0..height) |y| for (0..width) |x| {
        surface.putPixel(@intCast(x), @intCast(y), surface.encode(ui.Color.rgb(@intCast(x * 5), @intCast(y * 7), @intCast(40 + x + y))));
    };
    if (with_backdrop) try surface.setBackdrop(&backdrop, .{ .x = 0, .y = 0 });
    return surface;
}
fn inside(frame: ui.Rect, x: usize, y: usize, border: u32) bool {
    return @as(i64, @intCast(x)) >= @as(i64, frame.x) + border and
        @as(i64, @intCast(y)) >= @as(i64, frame.y) + border and
        @as(i64, @intCast(x)) < @as(i64, frame.x) + frame.width - border and
        @as(i64, @intCast(y)) < @as(i64, frame.y) + frame.height - border;
}
// Independent reference: the former full-frame frost followed by inner frost,
// expressed per visible pixel instead of reproducing the optimized four strips.
fn oldFill(surface: *ui.Surface, frame: ui.Rect, border: u32) void {
    const b = @min(border, @min(frame.width / 2, frame.height / 2));
    for (0..height) |y| for (0..width) |x| {
        if (!inside(frame, x, y, 0)) continue;
        surface.materialRect(@intCast(x), @intCast(y), 1, 1, .{ .tint = ui.Color.rgb(36, 40, 51), .opacity = if (inside(frame, x, y, b)) 100 else 130 });
    };
}
fn opaqueInner(surface: *ui.Surface, frame: ui.Rect, border: u32) void {
    const b = @min(border, @min(frame.width / 2, frame.height / 2));
    for (0..height) |y| for (0..width) |x| {
        if (inside(frame, x, y, b)) surface.putPixel(@intCast(x), @intCast(y), surface.encode(ui.Color.rgb(@intCast(160 + x), @intCast(80 + y), @intCast(50 + x + y))));
    };
}
fn guards(storage: *const [storage_len]u32) !void {
    try std.testing.expectEqual(sentinel, storage[0]);
    try std.testing.expectEqual(sentinel, storage[storage.len - 1]);
    for (0..height) |y| for (width..stride) |x| try std.testing.expectEqual(sentinel, storage[1 + y * stride + x]);
}

test "cached rim frost and opaque inner exactly match former full frost for clipped frames" {
    for ([_]ui.PixelMasks{
        .{ .red = 0xff0000, .green = 0xff00, .blue = 0xff },
        .{ .red = 0xff, .green = 0xff00, .blue = 0xff0000 },
    }) |masks| for ([_]bool{ false, true }) |with_backdrop| for ([_]u32{ 0, 2 }) |border| {
        for ([_]ui.Rect{
            .{ .x = 3, .y = 4, .width = 25, .height = 18 },
            .{ .x = 0, .y = 0, .width = width, .height = height },
            .{ .x = -7, .y = 3, .width = 24, .height = 17 },
            .{ .x = 5, .y = -8, .width = 23, .height = 21 },
            .{ .x = 20, .y = 15, .width = 25, .height = 18 },
            .{ .x = -3, .y = -3, .width = 40, .height = 35 },
            .{ .x = 40, .y = 32, .width = 20, .height = 16 },
        }) |frame| {
            var expected: [storage_len]u32 = undefined;
            var actual: [storage_len]u32 = undefined;
            var old_surface = try initialize(&expected, masks, with_backdrop);
            var new_surface = try initialize(&actual, masks, with_backdrop);
            const initial = actual;
            oldFill(&old_surface, frame, border);
            frame_fill.fill(&new_surface, frame, border, true);
            // The optimization must actually skip covered work, not merely
            // reproduce the final image by repainting the full body again.
            for (0..height) |y| for (0..width) |x| {
                if (inside(frame, x, y, border)) try std.testing.expectEqual(initial[1 + y * stride + x], actual[1 + y * stride + x]);
            };
            opaqueInner(&old_surface, frame, border);
            opaqueInner(&new_surface, frame, border);
            try std.testing.expectEqualSlices(u32, &expected, &actual);
            try guards(&actual);
        }
    };
}

test "uncached frames retain complete outer and inner frost until opaque content exists" {
    for ([_]bool{ false, true }) |with_backdrop| for ([_]u32{ 0, 2 }) |border| {
        for ([_]ui.Rect{
            .{ .x = 3, .y = 4, .width = 25, .height = 18 },
            .{ .x = -7, .y = -4, .width = 44, .height = 31 },
            .{ .x = 29, .y = 20, .width = 20, .height = 15 },
        }) |frame| {
            var expected: [storage_len]u32 = undefined;
            var actual: [storage_len]u32 = undefined;
            const masks: ui.PixelMasks = .{ .red = 0xff0000, .green = 0xff00, .blue = 0xff };
            var old_surface = try initialize(&expected, masks, with_backdrop);
            var new_surface = try initialize(&actual, masks, with_backdrop);
            oldFill(&old_surface, frame, border);
            frame_fill.fill(&new_surface, frame, border, false);
            try std.testing.expectEqualSlices(u32, &expected, &actual);
            try guards(&actual);
        }
    };
}

test "empty oversized and degenerate frame input stays bounded" {
    var pixels: [storage_len]u32 = undefined;
    const masks: ui.PixelMasks = .{ .red = 0xff0000, .green = 0xff00, .blue = 0xff };
    var surface = try initialize(&pixels, masks, true);
    const initial = pixels;
    frame_fill.fill(&surface, .{ .x = 0, .y = 0, .width = 0, .height = height }, 2, true);
    frame_fill.fill(&surface, .{ .x = 0, .y = 0, .width = width, .height = 0 }, 2, false);
    try std.testing.expectEqualSlices(u32, &initial, &pixels);
    frame_fill.fill(&surface, .{ .x = std.math.maxInt(i32), .y = std.math.maxInt(i32), .width = std.math.maxInt(u32), .height = std.math.maxInt(u32) }, 2, false);
    try std.testing.expectEqualSlices(u32, &initial, &pixels);
    frame_fill.fill(&surface, .{ .x = 4, .y = 5, .width = 1, .height = 1 }, std.math.maxInt(u32), false);
    try guards(&pixels);
}
