//! Shared native caption geometry. No pixels, input authority or app state.
const std = @import("std");
pub const height: u32 = 32;
pub const minimum_width: u32 = 316;
pub const control_width: u32 = 46;
pub const Control = enum { minimize, maximize, close };
pub const Rect = struct {
    x: i32,
    y: i32,
    width: u32,
    height: u32,
    pub fn contains(self: Rect, x: i32, y: i32) bool {
        return x >= self.x and y >= self.y and @as(i64, x) < @as(i64, self.x) + self.width and @as(i64, y) < @as(i64, self.y) + self.height;
    }
};
pub const Layout = struct {
    title: Rect,
    accessory: Rect,
    minimize: Rect,
    maximize: Rect,
    close: Rect,
    pub fn control(self: Layout, which: Control) Rect {
        return switch (which) {
            .minimize => self.minimize,
            .maximize => self.maximize,
            .close => self.close,
        };
    }
};
/// Rectangles are relative to the frame's inner origin. An opted-in client
/// receives this origin as source0 and reserves its first 32 rows for caption.
pub fn layout(inner_width: u32) error{InvalidHeaderGeometry}!Layout {
    return layoutMode(inner_width, false);
}
pub fn layoutMode(inner_width: u32, tabs_only: bool) error{InvalidHeaderGeometry}!Layout {
    if (inner_width < minimum_width or inner_width > 16384) return error.InvalidHeaderGeometry;
    return .{
        .title = .{ .x = 12, .y = 0, .width = if (tabs_only) 0 else 84, .height = height },
        .accessory = .{ .x = if (tabs_only) 8 else 104, .y = 4, .width = inner_width - (if (tabs_only) @as(u32, 154) else 250), .height = 24 },
        .minimize = .{ .x = @intCast(inner_width - 3 * control_width), .y = 0, .width = control_width, .height = height },
        .maximize = .{ .x = @intCast(inner_width - 2 * control_width), .y = 0, .width = control_width, .height = height },
        .close = .{ .x = @intCast(inner_width - control_width), .y = 0, .width = control_width, .height = height },
    };
}
test "caption title accessory and controls remain disjoint at minimum and reference widths" {
    const t = std.testing;
    for ([_]u32{ 316, 396, 636, 1276, 1280 }) |width| {
        const h = try layout(width);
        try t.expect(h.title.x + @as(i32, @intCast(h.title.width)) <= h.accessory.x);
        try t.expect(h.accessory.x + @as(i32, @intCast(h.accessory.width)) < h.minimize.x);
        try t.expect(h.minimize.x + control_width == h.maximize.x and h.maximize.x + control_width == h.close.x);
        try t.expect(h.close.x + control_width == @as(i32, @intCast(width)));
        for ([_]Control{ .minimize, .maximize, .close }) |which| {
            const rect = h.control(which);
            try t.expectEqual(@as(i32, 0), rect.y);
            try t.expectEqual(height, rect.height);
            try t.expect(rect.contains(rect.x, 0) and rect.contains(rect.x + control_width - 1, height - 1));
            try t.expect(!rect.contains(rect.x + control_width, height - 1));
            try t.expect(!rect.contains(rect.x, height));
        }
        try t.expect(!h.accessory.contains(h.close.x, h.close.y));
    }
    try t.expectEqual(@as(u32, 66), (try layout(316)).accessory.width);
    try t.expectError(error.InvalidHeaderGeometry, layout(315));
}

test "tabs-only captions delegate the left strip while preserving protected full-height controls" {
    const t = std.testing;
    for ([_]u32{ 316, 396, 636, 1280 }) |width| {
        const normal = try layout(width);
        const tabs = try layoutMode(width, true);
        try t.expectEqual(@as(u32, 0), tabs.title.width);
        try t.expectEqual(@as(i32, 8), tabs.accessory.x);
        try t.expectEqual(@as(u32, 24), tabs.accessory.height);
        try t.expectEqual(width - 154, tabs.accessory.width);
        try t.expectEqual(tabs.minimize.x - 8, tabs.accessory.x + @as(i32, @intCast(tabs.accessory.width)));
        try t.expectEqualDeep(normal.minimize, tabs.minimize);
        try t.expectEqualDeep(normal.maximize, tabs.maximize);
        try t.expectEqualDeep(normal.close, tabs.close);
        try t.expect(!tabs.accessory.contains(tabs.minimize.x, tabs.minimize.y));
    }
}
