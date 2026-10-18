//! Private cursor save-under layer. Full scene paints invalidate this cache,
//! dim the clean scene, then paint the cursor. Pointer-only paints reuse it.
const std = @import("std");
const ui = @import("axisui");

pub const width: u32 = 6;
pub const height: u32 = 18;
pub const Damage = struct { old: ?ui.Rect = null, new: ?ui.Rect = null };

const Identity = struct {
    address: usize,
    width: u32,
    height: u32,
    stride: u32,
    masks: ui.PixelMasks,

    fn of(surface: *const ui.Surface) Identity {
        return .{ .address = @intFromPtr(surface.pixels.ptr), .width = surface.width, .height = surface.height, .stride = surface.stride, .masks = surface.masks };
    }
};

pub const Layer = struct {
    background: [width * height]u32 = undefined,
    saved: ?ui.Rect = null,
    identity: ?Identity = null,

    /// Call before rebuilding any scene pixels. Never restore a saved patch
    /// over newly rendered content, even when the allocation stayed the same.
    pub fn invalidate(self: *Layer) void {
        self.saved = null;
        self.identity = null;
    }

    /// The background must already have the requested global dim applied.
    /// Restore before saving, including overlapping moves, to avoid trails.
    /// Returned rectangles stay separate so long jumps have bounded damage.
    pub fn paint(self: *Layer, surface: *ui.Surface, point: ui.Point, dim: u8) ui.Error!Damage {
        try validate(surface);
        const identity = Identity.of(surface);
        if (self.identity == null or !std.meta.eql(self.identity.?, identity)) self.invalidate();
        var damage: Damage = .{ .old = self.saved };
        if (self.saved) |rect| self.transfer(surface, rect, false);
        self.saved = clipped(surface, point);
        self.identity = identity;
        if (self.saved) |rect| self.transfer(surface, rect, true);
        drawValidated(surface, point, dim);
        damage.new = self.saved;
        return damage;
    }

    fn transfer(self: *Layer, surface: *ui.Surface, rect: ui.Rect, save: bool) void {
        for (0..rect.height) |row| for (0..rect.width) |column| {
            const scene_index = (@as(usize, @intCast(rect.y)) + row) * surface.stride + @as(usize, @intCast(rect.x)) + column;
            const saved_index = row * width + column;
            if (save) self.background[saved_index] = surface.pixels[scene_index] else surface.pixels[scene_index] = self.background[saved_index];
        };
    }
};

fn validate(surface: *const ui.Surface) ui.Error!void {
    try surface.validate();
    // Save-under reads are exclusive to the compositor's owned pixel surface.
    if (surface.commands != null) return error.InvalidSurface;
}

fn clipped(surface: *const ui.Surface, point: ui.Point) ?ui.Rect {
    const left = @max(@as(i64, 0), point.x);
    const top = @max(@as(i64, 0), point.y);
    const right = @min(@as(i64, surface.width), @as(i64, point.x) + width);
    const bottom = @min(@as(i64, surface.height), @as(i64, point.y) + height);
    if (left >= right or top >= bottom) return null;
    return .{ .x = @intCast(left), .y = @intCast(top), .width = @intCast(right - left), .height = @intCast(bottom - top) };
}

fn scaled(color: ui.Color, dim: u8) ui.Color {
    return ui.Color.rgb(
        @intCast(@as(u32, color.r) * dim / 255),
        @intCast(@as(u32, color.g) * dim / 255),
        @intCast(@as(u32, color.b) * dim / 255),
    );
}

fn drawValidated(surface: *ui.Surface, point: ui.Point, dim: u8) void {
    const ink = surface.encode(scaled(ui.Color.rgb(222, 232, 241), dim));
    const outline = surface.encode(scaled(ui.Color.rgb(8, 12, 18), dim));
    for (0..height) |row| {
        const row_width: usize = if (row < 12) row / 2 + 1 else 3;
        for (0..row_width) |column| {
            const x = @as(i64, point.x) + @as(i64, @intCast(column));
            const y = @as(i64, point.y) + @as(i64, @intCast(row));
            if (x < 0 or y < 0 or x >= surface.width or y >= surface.height) continue;
            surface.putPixel(@intCast(x), @intCast(y), if (column == 0 or column + 1 == row_width or row == 17) outline else ink);
        }
    }
}

const masks: ui.PixelMasks = .{ .red = 0xff0000, .green = 0xff00, .blue = 0xff };

fn pattern(pixels: []u32) void {
    for (pixels, 0..) |*pixel, i| {
        const value: u32 = @intCast(i);
        pixel.* = (value & 255) << 16 | ((value * 37) & 255) << 8 | ((value * 73) & 255);
    }
}

fn legacyDim(surface: *ui.Surface, dim: u8) void {
    for (0..surface.height) |row| for (0..surface.width) |column| {
        const index = row * surface.stride + column;
        const pixel = surface.pixels[index];
        const red = ((pixel >> 16) & 255) * @as(u32, dim) / 255;
        const green = ((pixel >> 8) & 255) * @as(u32, dim) / 255;
        const blue = (pixel & 255) * @as(u32, dim) / 255;
        surface.pixels[index] = red << 16 | green << 8 | blue;
    };
}

test "bounded cursor damage restores overlapping moves and distant jumps without trails" {
    const t = std.testing;
    var actual: [48 * 40]u32 = undefined;
    pattern(&actual);
    const background = actual;
    var expected = background;
    var surface = try ui.Surface.init(&actual, 48, 40, 48, masks);
    var reference = try ui.Surface.init(&expected, 48, 40, 48, masks);
    var layer: Layer = .{};
    const positions = [_]ui.Point{
        .{ .x = 4, .y = 3 },                                       .{ .x = 5, .y = 4 },   .{ .x = 3, .y = 2 },
        .{ .x = 42, .y = 22 },                                     .{ .x = -2, .y = -3 }, .{ .x = 47, .y = 39 },
        .{ .x = std.math.minInt(i32), .y = std.math.maxInt(i32) },
    };
    var previous: ?ui.Rect = null;
    for (positions) |point| {
        expected = background;
        try ui.drawCursor(&reference, point, ui.Color.rgb(222, 232, 241));
        const damage = try layer.paint(&surface, point, 255);
        try t.expectEqualDeep(previous, damage.old);
        try t.expectEqualDeep(clipped(&surface, point), damage.new);
        for ([_]?ui.Rect{ damage.old, damage.new }) |maybe| if (maybe) |rect| {
            try t.expect(rect.width <= 6 and rect.height <= 18);
            try t.expect(rect.x >= 0 and rect.y >= 0);
            try t.expect(@as(u64, @intCast(rect.x)) + rect.width <= surface.width);
            try t.expect(@as(u64, @intCast(rect.y)) + rect.height <= surface.height);
        };
        try t.expectEqualSlices(u32, &expected, &actual);
        previous = damage.new;
    }
    try t.expectEqualSlices(u32, &background, &actual);
}

test "cursor clipping preserves guards and stride padding at every edge" {
    const t = std.testing;
    var memory: [1 + 9 * 22 + 1]u32 = @splat(0xdeadbeef);
    var surface = try ui.Surface.init(memory[1 .. memory.len - 1], 7, 22, 9, masks);
    var layer: Layer = .{};
    const positions = [_]ui.Point{
        .{ .x = -5, .y = -17 },                                    .{ .x = 6, .y = 21 },  .{ .x = -6, .y = 0 },
        .{ .x = 7, .y = 0 },                                       .{ .x = 0, .y = -18 }, .{ .x = 0, .y = 22 },
        .{ .x = std.math.maxInt(i32), .y = std.math.minInt(i32) },
    };
    for (positions) |point| {
        _ = try layer.paint(&surface, point, 255);
        try t.expectEqual(@as(u32, 0xdeadbeef), memory[0]);
        try t.expectEqual(@as(u32, 0xdeadbeef), memory[memory.len - 1]);
        for (0..22) |row| for (7..9) |column| try t.expectEqual(@as(u32, 0xdeadbeef), memory[1 + row * 9 + column]);
    }
    for (memory) |pixel| try t.expectEqual(@as(u32, 0xdeadbeef), pixel);
}

test "every dim level matches original cursor then RGB dim with no double dim or trails" {
    const t = std.testing;
    var actual: [32 * 28]u32 = undefined;
    var expected: [actual.len]u32 = undefined;
    var background: [actual.len]u32 = undefined;
    pattern(&background);
    var surface = try ui.Surface.init(&actual, 32, 28, 32, masks);
    var reference = try ui.Surface.init(&expected, 32, 28, 32, masks);
    var layer: Layer = .{};
    const positions = [_]ui.Point{ .{ .x = 4, .y = 3 }, .{ .x = 5, .y = 4 }, .{ .x = -2, .y = -3 }, .{ .x = 31, .y = 27 }, .{ .x = 32, .y = 28 } };
    for (0..256) |level| {
        const dim: u8 = @intCast(level);
        actual = background;
        layer.invalidate();
        legacyDim(&surface, dim);
        for (positions) |point| {
            expected = background;
            try ui.drawCursor(&reference, point, ui.Color.rgb(222, 232, 241));
            legacyDim(&reference, dim);
            _ = try layer.paint(&surface, point, dim);
            try t.expectEqualSlices(u32, &expected, &actual);
        }
    }
}

test "full scene invalidation and changed surface identity never restore stale pixels" {
    const t = std.testing;
    var first: [24 * 24]u32 = @splat(0x112233);
    var second: [24 * 24]u32 = @splat(0x778899);
    var surface = try ui.Surface.init(&first, 24, 24, 24, masks);
    var layer: Layer = .{};
    _ = try layer.paint(&surface, .{ .x = 2, .y = 2 }, 255);
    @memset(&first, 0x445566);
    layer.invalidate();
    const fresh = try layer.paint(&surface, .{ .x = 16, .y = 3 }, 255);
    try t.expect(fresh.old == null);
    try t.expectEqual(@as(u32, 0x445566), first[2 * 24 + 2]);
    surface = try ui.Surface.init(&second, 24, 24, 24, masks);
    const changed = try layer.paint(&surface, .{ .x = 1, .y = 1 }, 255);
    try t.expect(changed.old == null);
    _ = try layer.paint(&surface, .{ .x = 24, .y = 24 }, 255);
    for (second) |pixel| try t.expectEqual(@as(u32, 0x778899), pixel);
    // Reinterpreting the same allocation must also discard the old save-under.
    _ = try layer.paint(&surface, .{ .x = 2, .y = 2 }, 255);
    @memset(&second, 0xaabbcc);
    surface = try ui.Surface.init(&second, 12, 24, 24, masks);
    const resized = try layer.paint(&surface, .{ .x = 12, .y = 24 }, 255);
    try t.expect(resized.old == null and resized.new == null);
    for (second) |pixel| try t.expectEqual(@as(u32, 0xaabbcc), pixel);
}

test "invalid cursor surface fails before restoring cached background" {
    const t = std.testing;
    var pixels: [24 * 24]u32 = @splat(0x123456);
    var surface = try ui.Surface.init(&pixels, 24, 24, 24, masks);
    var layer: Layer = .{};
    _ = try layer.paint(&surface, .{ .x = 3, .y = 2 }, 255);
    const painted = pixels;
    const saved = layer.saved;
    surface.stride = 23;
    try t.expectError(error.InvalidSurface, layer.paint(&surface, .{ .x = 10, .y = 3 }, 255));
    try t.expectEqualSlices(u32, &painted, &pixels);
    try t.expectEqualDeep(saved, layer.saved);
}
