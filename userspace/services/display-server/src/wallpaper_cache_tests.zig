const std = @import("std");
const ui = @import("axisui");
const wallpaper = @import("wallpaper_cache.zig");
const rgb: ui.PixelMasks = .{ .red = 0xff0000, .green = 0xff00, .blue = 0xff };
const sentinel: u32 = 0x9acdef01;

fn seed(surface: *ui.Surface) void {
    const columns = @min(surface.width, wallpaper.max_columns);
    for (0..surface.height) |y| for (0..columns) |column| {
        const id: u32 = @intCast((y * columns + column) % 2571);
        const color = ui.Color.rgb(@truncate(id >> 8), @truncate(id), @truncate(id *% 71));
        const left: u32 = @intCast(column * surface.width / columns);
        const right: u32 = @intCast((column + 1) * surface.width / columns);
        surface.fillRect(left, @intCast(y), right - left, 1, surface.encode(color));
    };
}
fn guards(pixels: []const u32, width: u32, height: u32, stride: u32) !void {
    try std.testing.expectEqual(sentinel, pixels[0]);
    try std.testing.expectEqual(sentinel, pixels[pixels.len - 1]);
    for (0..height) |y| for (width..stride) |x| try std.testing.expectEqual(sentinel, pixels[1 + y * stride + x]);
}

test "lossless span cache preserves every RGB and BGR wallpaper pixel across distinct strides" {
    const cache = try std.testing.allocator.create(wallpaper.Cache);
    defer std.testing.allocator.destroy(cache);
    const hash = try std.testing.allocator.create([wallpaper.hash_capacity]u16);
    defer std.testing.allocator.destroy(hash);
    for ([_]ui.PixelMasks{ rgb, .{ .red = 0xff, .green = 0xff00, .blue = 0xff0000 } }) |masks| {
        for ([_]struct { width: u32, height: u32 }{
            .{ .width = 800, .height = 600 }, .{ .width = 1280, .height = 800 },
            .{ .width = 137, .height = 19 },  .{ .width = 13, .height = 9 },
            .{ .width = 1, .height = 1 },
        }) |size| {
            const source_stride = size.width + 7;
            const target_stride = size.width + 11;
            const source_pixels = try std.testing.allocator.alloc(u32, 2 + @as(usize, source_stride) * size.height);
            defer std.testing.allocator.free(source_pixels);
            const target_pixels = try std.testing.allocator.alloc(u32, 2 + @as(usize, target_stride) * size.height);
            defer std.testing.allocator.free(target_pixels);
            @memset(source_pixels, sentinel);
            @memset(target_pixels, sentinel);
            var source = try ui.Surface.init(source_pixels[1 .. source_pixels.len - 1], size.width, size.height, source_stride, masks);
            var target = try ui.Surface.init(target_pixels[1 .. target_pixels.len - 1], size.width, size.height, target_stride, masks);
            target.legacy_text = true;
            target.backdrop_origin = .{ .x = 12, .y = -8 };
            seed(&source);
            const before = std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(source_pixels));
            try cache.build(&source, hash);
            try std.testing.expect(cache.valid);
            try std.testing.expectEqual(@as(u16, @intCast(@min(2571, @as(usize, size.height) * @min(size.width, wallpaper.max_columns)))), cache.palette_count);
            try std.testing.expectEqual(before, std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(source_pixels)));
            try cache.paint(&target);
            for (0..size.height) |y| for (0..size.width) |x| try std.testing.expectEqual(source_pixels[1 + y * source_stride + x], target_pixels[1 + y * target_stride + x]);
            try guards(source_pixels, size.width, size.height, source_stride);
            try guards(target_pixels, size.width, size.height, target_stride);
            try std.testing.expect(target.legacy_text and target.backdrop == null and target.commands == null);
            try std.testing.expectEqualDeep(ui.Point{ .x = 12, .y = -8 }, target.backdrop_origin);
            try std.testing.expectEqual(size.width, target.width);
            try std.testing.expectEqual(size.height, target.height);
            try std.testing.expectEqual(target_stride, target.stride);
        }
    }
    try std.testing.expect(@sizeOf(wallpaper.Cache) <= 225000);
}

test "palette exhaustion or a nonflat span invalidates cache without changing source or painting" {
    const cache = try std.testing.allocator.create(wallpaper.Cache);
    defer std.testing.allocator.destroy(cache);
    const hash = try std.testing.allocator.create([wallpaper.hash_capacity]u16);
    defer std.testing.allocator.destroy(hash);
    var pixels: [128 * 33]u32 = undefined;
    for (&pixels, 0..) |*pixel, id| pixel.* = @intCast(id);
    var source = try ui.Surface.init(&pixels, 128, 32, 128, rgb);
    const before = pixels;
    try cache.build(&source, hash);
    try std.testing.expect(cache.valid and cache.palette_count == wallpaper.palette_capacity);
    try cache.paint(&source);
    try std.testing.expectEqualSlices(u32, &before, &pixels);
    source = try ui.Surface.init(&pixels, 128, 33, 128, rgb);
    try std.testing.expectError(error.PaletteCapacity, cache.build(&source, hash));
    try std.testing.expect(!cache.valid);
    try std.testing.expectEqualSlices(u32, &before, &pixels);
    try std.testing.expectError(error.CacheUnavailable, cache.paint(&source));
    try std.testing.expectEqualSlices(u32, &before, &pixels);
    // A later successful build makes the same persistent storage reusable.
    @memset(&pixels, 0x182f46);
    try cache.build(&source, hash);
    try std.testing.expect(cache.valid and cache.palette_count == 1);
    var nonflat: [256]u32 = @splat(0x182f46);
    nonflat[1] = 0x314a65;
    source = try ui.Surface.init(&nonflat, 256, 1, 256, rgb);
    try std.testing.expectError(error.NonuniformSpan, cache.build(&source, hash));
    try std.testing.expect(!cache.valid);
    try std.testing.expectEqual(@as(u32, 0x314a65), nonflat[1]);
}

test "cache rejects incompatible geometry formats and commands before paint" {
    const cache = try std.testing.allocator.create(wallpaper.Cache);
    defer std.testing.allocator.destroy(cache);
    const hash = try std.testing.allocator.create([wallpaper.hash_capacity]u16);
    defer std.testing.allocator.destroy(hash);
    var pixels: [1281]u32 = @splat(0x182f46);
    var source = try ui.Surface.init(&pixels, 16, 16, 16, rgb);
    try cache.build(&source, hash);
    var target = source;
    target.width = 15;
    const before = pixels;
    try std.testing.expectError(error.CacheMismatch, cache.paint(&target));
    target = source;
    target.masks = .{ .red = 0xff, .green = 0xff00, .blue = 0xff0000 };
    try std.testing.expectError(error.CacheMismatch, cache.paint(&target));
    target = source;
    target.masks.reserved = 0xff000000;
    try std.testing.expectError(error.CacheMismatch, cache.paint(&target));
    target = source;
    target.stride = 15;
    try std.testing.expectError(error.InvalidSurface, cache.paint(&target));
    const Receiver = struct {
        fn fill(_: *anyopaque, _: u32, _: u32, _: u32, _: u32, _: u32) void {
            @panic("wallpaper cache must never emit commands");
        }
    };
    var context: u8 = 0;
    target = try ui.Surface.initCommands(16, 16, .{ .context = &context, .fillRect = Receiver.fill });
    try std.testing.expectError(error.BackdropUnavailable, cache.paint(&target));
    try std.testing.expectError(error.BackdropUnavailable, cache.build(&target, hash));
    try std.testing.expect(!cache.valid);
    source = try ui.Surface.init(&pixels, 1281, 1, 1281, rgb);
    try std.testing.expectError(error.InvalidWallpaperDimensions, cache.build(&source, hash));
    try std.testing.expectEqualSlices(u32, &before, &pixels);
}
