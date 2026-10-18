//! Checked scanout coordinates. Authority and surface leases are validated by
//! the display syscall before passing its authenticated ownership facts here.
const std = @import("std");

pub const Size = struct { width: u32, height: u32 };
pub const Display = struct { width: u32, height: u32, stride: u64 };
pub const Request = struct { x: i32, y: i32, width: u32, height: u32 };
pub const Context = struct { window_runtime: bool, source_owned: bool };
pub const Error = error{InvalidGeometry};
pub const Region = struct {
    source_offset: usize,
    target_offset: usize,
    source_stride: usize,
    target_stride: usize,
    width: usize,
    height: usize,
};

/// Only a service-owned, full-monitor scene in the window runtime accepts a
/// source ROI. Its source and scanout coordinates are identical. Every other
/// source keeps the legacy whole-surface copy at a destination origin.
pub fn resolve(display: Display, source: Size, request: Request, context: Context) Error!Region {
    if (display.width == 0 or display.height == 0 or display.stride < display.width or
        source.width == 0 or source.height == 0 or request.width == 0 or request.height == 0 or
        request.x < 0 or request.y < 0) return error.InvalidGeometry;
    const x: u64 = @intCast(request.x);
    const y: u64 = @intCast(request.y);
    const right = std.math.add(u64, x, request.width) catch return error.InvalidGeometry;
    const bottom = std.math.add(u64, y, request.height) catch return error.InvalidGeometry;
    if (right > display.width or bottom > display.height) return error.InvalidGeometry;
    const roi = context.window_runtime and context.source_owned and source.width == display.width and source.height == display.height;
    if (!roi and (request.width != source.width or request.height != source.height)) return error.InvalidGeometry;
    const source_x = if (roi) x else 0;
    const source_y = if (roi) y else 0;
    const source_pixels = try pixels(source.width, source.height);
    const target_pixels = try pixels(display.stride, display.height);
    const source_offset = try offset(source_y, source.width, source_x);
    const target_offset = try offset(y, display.stride, x);
    try bounded(source_offset, source.width, request.width, request.height, source_pixels);
    try bounded(target_offset, display.stride, request.width, request.height, target_pixels);
    return .{
        .source_offset = @intCast(source_offset),
        .target_offset = @intCast(target_offset),
        .source_stride = source.width,
        .target_stride = @intCast(display.stride),
        .width = request.width,
        .height = request.height,
    };
}

fn pixels(stride: u64, height: u32) Error!u64 {
    const length = std.math.mul(u64, stride, height) catch return error.InvalidGeometry;
    const bytes = std.math.mul(u64, length, @sizeOf(u32)) catch return error.InvalidGeometry;
    if (bytes > std.math.maxInt(usize)) return error.InvalidGeometry;
    return length;
}
fn offset(y: u64, stride: u64, x: u64) Error!u64 {
    return std.math.add(u64, std.math.mul(u64, y, stride) catch return error.InvalidGeometry, x) catch return error.InvalidGeometry;
}
fn bounded(start: u64, stride: u64, width: u32, height: u32, length: u64) Error!void {
    const last_row = try offset(height - 1, stride, start);
    const end = std.math.add(u64, last_row, width) catch return error.InvalidGeometry;
    if (end > length) return error.InvalidGeometry;
}

/// Call only with a region returned by resolve and those validated backings.
/// The channel order is selected once outside the pixel loop. Raw pointer
/// arithmetic is safe because resolve checked both complete byte spans first.
pub fn copyNative(region: Region, source: [*]const volatile u32, target: [*]volatile u32, comptime bgr: bool) void {
    for (0..region.height) |row| {
        @setRuntimeSafety(false);
        const source_row = source + region.source_offset + row * region.source_stride;
        const target_row = target + region.target_offset + row * region.target_stride;
        for (0..region.width) |column| {
            const pixel = source_row[column];
            target_row[column] = if (bgr) ((pixel & 0xff) << 16) | (pixel & 0xff00) | ((pixel >> 16) & 0xff) else pixel & 0xffffff;
        }
    }
}

test "partial scanout requires an owned full-monitor window scene" {
    const t = std.testing;
    const display: Display = .{ .width = 8, .height = 6, .stride = 10 };
    const source: Size = .{ .width = 8, .height = 6 };
    const request: Request = .{ .x = 3, .y = 2, .width = 2, .height = 3 };
    const roi = try resolve(display, source, request, .{ .window_runtime = true, .source_owned = true });
    try t.expectEqual(@as(usize, 19), roi.source_offset);
    try t.expectEqual(@as(usize, 23), roi.target_offset);
    try t.expectEqual(@as(usize, 8), roi.source_stride);
    try t.expectEqual(@as(usize, 10), roi.target_stride);
    for ([_]Context{
        .{ .window_runtime = false, .source_owned = false },
        .{ .window_runtime = false, .source_owned = true },
        .{ .window_runtime = true, .source_owned = false },
    }) |context| try t.expectError(error.InvalidGeometry, resolve(display, source, request, context));
    try t.expectError(error.InvalidGeometry, resolve(display, .{ .width = 7, .height = 6 }, request, .{ .window_runtime = true, .source_owned = true }));
}

test "legacy whole-surface scanout keeps its source origin and destination placement" {
    const t = std.testing;
    for ([_]Context{
        .{ .window_runtime = false, .source_owned = false },
        .{ .window_runtime = false, .source_owned = true },
        .{ .window_runtime = true, .source_owned = false },
        .{ .window_runtime = true, .source_owned = true },
    }) |context| {
        const region = try resolve(.{ .width = 8, .height = 6, .stride = 10 }, .{ .width = 3, .height = 2 }, .{ .x = 4, .y = 3, .width = 3, .height = 2 }, context);
        try t.expectEqual(@as(usize, 0), region.source_offset);
        try t.expectEqual(@as(usize, 34), region.target_offset);
        try t.expectEqual(@as(usize, 3), region.source_stride);
    }
    const source: [3 * 2]u32 = .{ 0xff112233, 0xff445566, 0xff778899, 0xffaabbcc, 0xffddeeff, 0xff102030 };
    var target: [10 * 6]u32 = @splat(0xdeadbeef);
    const region = try resolve(.{ .width = 8, .height = 6, .stride = 10 }, .{ .width = 3, .height = 2 }, .{ .x = 4, .y = 3, .width = 3, .height = 2 }, .{ .window_runtime = true, .source_owned = false });
    copyNative(region, &source, &target, false);
    for (0..6) |y| for (0..10) |x| {
        const expected = if (y >= 3 and y < 5 and x >= 4 and x < 7) source[(y - 3) * 3 + x - 4] & 0xffffff else 0xdeadbeef;
        try t.expectEqual(@as(u32, expected), target[y * 10 + x]);
    };
}

test "scanout rejects empty negative outside and overflowing regions before copying" {
    const t = std.testing;
    const display: Display = .{ .width = 8, .height = 6, .stride = 10 };
    const source: Size = .{ .width = 8, .height = 6 };
    const context: Context = .{ .window_runtime = true, .source_owned = true };
    for ([_]Request{
        .{ .x = 0, .y = 0, .width = 0, .height = 1 },
        .{ .x = 0, .y = 0, .width = 1, .height = 0 },
        .{ .x = -1, .y = 0, .width = 1, .height = 1 },
        .{ .x = 0, .y = -1, .width = 1, .height = 1 },
        .{ .x = 8, .y = 0, .width = 1, .height = 1 },
        .{ .x = 0, .y = 6, .width = 1, .height = 1 },
        .{ .x = 7, .y = 5, .width = 2, .height = 1 },
        .{ .x = 7, .y = 5, .width = 1, .height = 2 },
        .{ .x = std.math.maxInt(i32), .y = 0, .width = std.math.maxInt(u32), .height = 1 },
        .{ .x = 0, .y = std.math.maxInt(i32), .width = 1, .height = std.math.maxInt(u32) },
    }) |request| try t.expectError(error.InvalidGeometry, resolve(display, source, request, context));
    const request: Request = .{ .x = 0, .y = 0, .width = 8, .height = 6 };
    try t.expectError(error.InvalidGeometry, resolve(.{ .width = 8, .height = 6, .stride = 7 }, source, request, context));
    try t.expectError(error.InvalidGeometry, resolve(.{ .width = 8, .height = 6, .stride = std.math.maxInt(u64) }, source, request, context));
    try t.expectError(error.InvalidGeometry, resolve(.{ .width = 8, .height = 6, .stride = std.math.maxInt(u64) / 8 }, source, request, context));
    try t.expectError(error.InvalidGeometry, resolve(display, .{ .width = 0, .height = 6 }, request, context));
    _ = try resolve(display, source, .{ .x = 7, .y = 5, .width = 1, .height = 1 }, context);
}

test "native ROI scanout preserves source stride target padding guards and outside pixels" {
    const t = std.testing;
    const sentinel: u32 = 0x9abcdef0;
    var source: [5 * 4]u32 = undefined;
    for (&source, 0..) |*pixel, index| pixel.* = 0xff000000 | @as(u32, @intCast(index)) << 16 | 0x5080;
    const source_before = source;
    const region = try resolve(.{ .width = 5, .height = 4, .stride = 8 }, .{ .width = 5, .height = 4 }, .{ .x = 2, .y = 1, .width = 2, .height = 2 }, .{ .window_runtime = true, .source_owned = true });
    inline for (.{ false, true }) |bgr| {
        var target: [2 + 8 * 4]u32 = @splat(sentinel);
        copyNative(region, &source, @ptrCast(&target[1]), bgr);
        try t.expectEqual(sentinel, target[0]);
        try t.expectEqual(sentinel, target[target.len - 1]);
        for (0..4) |y| for (0..8) |x| {
            const expected = if (x >= 2 and x < 4 and y >= 1 and y < 3) blk: {
                const pixel = source[y * 5 + x];
                break :blk if (bgr) ((pixel & 0xff) << 16) | (pixel & 0xff00) | ((pixel >> 16) & 0xff) else pixel & 0xffffff;
            } else sentinel;
            try t.expectEqual(expected, target[1 + y * 8 + x]);
        };
    }
    try t.expectEqualSlices(u32, &source_before, &source);
}
