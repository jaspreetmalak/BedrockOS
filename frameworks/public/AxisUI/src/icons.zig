//! Original native vector icons. Integer distance coverage keeps curved strokes
//! smooth at every supported scale; diagnostic bit patterns remain explicit.
const surface_module = @import("surface.zig");
const Surface = surface_module.Surface;
const Error = surface_module.Error;
const Color = @import("types.zig").Color;
const Point = @import("input.zig").Point;
pub const size: u32 = 16;
pub const Icon = enum {
    folder,
    document,
    home,
    chevron_left,
    chevron_right,
    chevron_up,
    chevron_down,
    control_center,
    clock,
    wifi,
    speaker,
    brightness,
    minimize,
    maximize,
    restore,
    close,
    check,
};

fn horizontal(rows: *[16]u16, y: usize, first: usize, last: usize) void {
    for (first..last + 1) |x| rows[y] |= @as(u16, 1) << @intCast(15 - x);
}
fn vertical(rows: *[16]u16, x: usize, first: usize, last: usize) void {
    for (first..last + 1) |y| horizontal(rows, y, x, x);
}
pub fn pattern(icon: Icon) [16]u16 {
    if (@backingInt(icon) < patterns.len) return patterns[@backingInt(icon)];
    var rows: [16]u16 = @splat(0);
    for (0..16) |y| for (0..16) |x| {
        if (coverage(icon, @intCast(x), @intCast(y), 1) >= 128) horizontal(&rows, y, x, x);
    };
    return rows;
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

/// Validates before paint. Scale 1..16; signed placement clips at every edge.
/// Gray8 command callbacks preserve the same coverage without pixel reads.
/// Direct calls do not inherit a declarative ancestor's rounded clip.
pub fn draw(surface: *Surface, icon: Icon, point: Point, color: Color, scale: u8) Error!void {
    try surface.validate();
    if (scale == 0 or scale > 16) return error.InvalidScale;
    if (surface.legacy_text) return drawLegacy(surface, icon, point, color, scale);
    const extent = size * scale;
    const left: u32 = @intCast(@min(extent, @max(0, -@as(i64, point.x))));
    const top: u32 = @intCast(@min(extent, @max(0, -@as(i64, point.y))));
    const right: u32 = @intCast(@min(extent, @max(0, @as(i64, surface.width) - point.x)));
    const bottom: u32 = @intCast(@min(extent, @max(0, @as(i64, surface.height) - point.y)));
    if (left >= right or top >= bottom) return;
    const pixel = surface.encode(color);
    for (top..bottom) |row| {
        var run: ?u32 = null;
        var column = left;
        while (column <= right) : (column += 1) {
            const alpha = if (column < right) coverage(icon, column, @intCast(row), scale) else 0;
            if (alpha == 255) {
                if (run == null) run = column;
            } else {
                if (run) |first| surface.fillRect(@intCast(@as(i64, point.x) + first), @intCast(@as(i64, point.y) + @as(i64, @intCast(row))), column - first, 1, pixel);
                run = null;
                if (alpha != 0) surface.blendPixel(@intCast(@as(i64, point.x) + column), @intCast(@as(i64, point.y) + @as(i64, @intCast(row))), color, alpha);
            }
        }
    }
}

fn drawLegacy(surface: *Surface, icon: Icon, point: Point, color: Color, scale: u8) void {
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

// Path coordinates are quarter pixels in a 16-by-16 design box. Painting uses
// Q8 fixed-point distances. Each stroke is a union of rounded capsules; circles
// and circular arcs use the same edge coverage. No allocation, floating-point
// instructions, sampling grid or enlarged intermediate image is needed.
const Vector = struct { x: i64, y: i64 };
fn v(x: i32, y: i32) Vector {
    return .{ .x = @as(i64, x) * 64, .y = @as(i64, y) * 64 };
}
fn square(value: i64) u64 {
    return @intCast(value * value);
}
fn root(value: u64) i64 {
    if (value == 0) return 0;
    var result: u64 = 0;
    const leading: u6 = @intCast((63 - @clz(value)) & ~@as(u7, 1));
    var bit: u64 = @as(u64, 1) << leading;
    var remainder = value;
    while (bit != 0) : (bit >>= 2) {
        if (remainder >= result + bit) {
            remainder -= result + bit;
            result = (result >> 1) + bit;
        } else result >>= 1;
    }
    return @intCast(result);
}
fn edge(distance: i64, radius: i64) u8 {
    const amount: u32 = @intCast(@max(0, @min(256, radius + 128 - distance)));
    return @intCast((amount * 255 + 128) / 256);
}
const Stroke = struct {
    point: Vector,
    scale: u8,
    alpha: u8 = 0,
    const radius: i64 = 160; // 1.25 pixel strokes, with one destination pixel AA.
    fn scaled(self: Stroke, point: Vector) Vector {
        return .{ .x = point.x * self.scale, .y = point.y * self.scale };
    }
    fn line(self: *Stroke, first: Vector, last: Vector) void {
        if (self.alpha == 255) return;
        const a = self.scaled(first);
        const b = self.scaled(last);
        const limit = radius * self.scale + 128;
        if (self.point.x <= @min(a.x, b.x) - limit or self.point.x >= @max(a.x, b.x) + limit or
            self.point.y <= @min(a.y, b.y) - limit or self.point.y >= @max(a.y, b.y) + limit) return;
        const dx = b.x - a.x;
        const dy = b.y - a.y;
        const length = dx * dx + dy * dy;
        const projection = @min(length, @max(0, (self.point.x - a.x) * dx + (self.point.y - a.y) * dy));
        const nearest: Vector = if (length == 0) a else .{
            .x = a.x + @divTrunc(dx * projection, length),
            .y = a.y + @divTrunc(dy * projection, length),
        };
        const distance_squared = square(self.point.x - nearest.x) + square(self.point.y - nearest.y);
        if (distance_squared >= square(limit)) return;
        self.alpha = @max(self.alpha, edge(root(distance_squared), radius * self.scale));
    }
    fn lines(self: *Stroke, points: []const Vector) void {
        for (points[0 .. points.len - 1], points[1..]) |a, b| self.line(a, b);
    }
    fn circle(self: *Stroke, center: Vector, r: i64) void {
        if (self.alpha == 255) return;
        const c = self.scaled(center);
        const distance_squared = square(self.point.x - c.x) + square(self.point.y - c.y);
        const limit = radius * self.scale + 128;
        const inner = @max(0, r * self.scale - limit);
        if (distance_squared < square(inner) or distance_squared > square(r * self.scale + limit)) return;
        const distance = root(distance_squared);
        self.alpha = @max(self.alpha, edge(@intCast(@abs(distance - r * self.scale)), radius * self.scale));
    }
    fn disk(self: *Stroke, center: Vector) void {
        if (self.alpha == 255) return;
        const c = self.scaled(center);
        const distance_squared = square(self.point.x - c.x) + square(self.point.y - c.y);
        if (distance_squared >= square(radius * self.scale + 128)) return;
        self.alpha = @max(self.alpha, edge(root(distance_squared), radius * self.scale));
    }
    fn arc(self: *Stroke, center: Vector, r: i64, direction: enum { top, right }) void {
        const c = self.scaled(center);
        const dx = self.point.x - c.x;
        const dy = self.point.y - c.y;
        const within = switch (direction) {
            .top => -dy >= @abs(dx),
            .right => dx >= @abs(dy),
        };
        if (within) self.circle(center, r);
        // Endpoint coordinates use an original fixed-point approximation of
        // sqrt(1/2); the capsules finish the arcs with smooth rounded caps.
        const diagonal = @divTrunc(r * 181, 256);
        switch (direction) {
            .top => {
                self.disk(.{ .x = center.x - diagonal, .y = center.y - diagonal });
                self.disk(.{ .x = center.x + diagonal, .y = center.y - diagonal });
            },
            .right => {
                self.disk(.{ .x = center.x + diagonal, .y = center.y - diagonal });
                self.disk(.{ .x = center.x + diagonal, .y = center.y + diagonal });
            },
        }
    }
};

/// Original vector edge coverage, relative to the 16*scale square. Invalid or
/// out-of-range requests have zero coverage. Scale changes the paths and stroke
/// width, rather than replicating a bitmap or blurring enlarged pixels.
pub fn coverage(icon: Icon, x: u32, y: u32, scale: u8) u8 {
    if (scale == 0 or scale > 16 or x >= size * scale or y >= size * scale) return 0;
    var stroke: Stroke = .{ .point = .{ .x = @as(i64, x) * 256 + 128, .y = @as(i64, y) * 256 + 128 }, .scale = scale };
    switch (icon) {
        .folder => stroke.lines(&.{ v(10, 22), v(10, 14), v(26, 14), v(33, 22), v(54, 22), v(54, 50), v(10, 50), v(10, 22), v(54, 22) }),
        .document => {
            stroke.lines(&.{ v(18, 10), v(38, 10), v(50, 22), v(50, 54), v(18, 54), v(18, 10) });
            stroke.lines(&.{ v(38, 10), v(38, 22), v(50, 22) });
            stroke.line(v(26, 34), v(42, 34));
            stroke.line(v(26, 44), v(42, 44));
        },
        .home => {
            stroke.lines(&.{ v(10, 29), v(32, 10), v(54, 29) });
            stroke.lines(&.{ v(18, 26), v(18, 50), v(46, 50), v(46, 26) });
            stroke.lines(&.{ v(26, 50), v(26, 38), v(38, 38), v(38, 50) });
        },
        .chevron_left => stroke.lines(&.{ v(40, 14), v(22, 32), v(40, 50) }),
        .chevron_right => stroke.lines(&.{ v(24, 14), v(42, 32), v(24, 50) }),
        .chevron_up => stroke.lines(&.{ v(14, 40), v(32, 22), v(50, 40) }),
        .chevron_down => stroke.lines(&.{ v(14, 24), v(32, 42), v(50, 24) }),
        .control_center => {
            for ([_]Vector{ v(22, 16), v(42, 32), v(27, 48) }) |center| {
                stroke.line(.{ .x = 640, .y = center.y }, .{ .x = center.x - 640, .y = center.y });
                stroke.line(.{ .x = center.x + 640, .y = center.y }, .{ .x = 3456, .y = center.y });
                stroke.circle(center, 384);
            }
        },
        .clock => {
            stroke.circle(v(32, 32), 1408);
            stroke.lines(&.{ v(32, 18), v(32, 32), v(41, 37) });
        },
        .wifi => {
            stroke.arc(v(32, 52), 2304, .top);
            stroke.arc(v(32, 52), 1536, .top);
            stroke.arc(v(32, 52), 768, .top);
            stroke.disk(v(32, 52));
        },
        .speaker => {
            stroke.lines(&.{ v(10, 24), v(20, 24), v(32, 14), v(32, 50), v(20, 40), v(10, 40), v(10, 24) });
            stroke.arc(v(32, 32), 832, .right);
            stroke.arc(v(32, 32), 1408, .right);
        },
        .brightness => {
            stroke.circle(v(32, 32), 704);
            stroke.line(v(32, 8), v(32, 13));
            stroke.line(v(32, 51), v(32, 56));
            stroke.line(v(8, 32), v(13, 32));
            stroke.line(v(51, 32), v(56, 32));
            stroke.line(v(15, 15), v(19, 19));
            stroke.line(v(45, 45), v(49, 49));
            stroke.line(v(15, 49), v(19, 45));
            stroke.line(v(45, 19), v(49, 15));
        },
        .minimize => stroke.line(v(14, 38), v(50, 38)),
        .maximize => stroke.lines(&.{ v(14, 14), v(50, 14), v(50, 50), v(14, 50), v(14, 14) }),
        .restore => {
            stroke.lines(&.{ v(22, 22), v(22, 10), v(54, 10), v(54, 42), v(42, 42) });
            stroke.lines(&.{ v(10, 22), v(42, 22), v(42, 54), v(10, 54), v(10, 22) });
        },
        .close => {
            stroke.line(v(18, 18), v(46, 46));
            stroke.line(v(46, 18), v(18, 46));
        },
        .check => stroke.lines(&.{ v(18, 34), v(26, 42), v(50, 18) }),
    }
    return stroke.alpha;
}

test {
    _ = @import("icon_tests.zig");
}
