//! Frozen, caller-owned RGB backdrop:8px downsample and24px separable box blur.
const surface_module = @import("surface.zig");
const Surface = surface_module.Surface;
const Error = surface_module.Error;
const Color = @import("types.zig").Color;
pub const Material = @import("types.zig").Material;
pub const step: u32 = 8;
pub const radius: u32 = 24;
const grid_radius: i64 = radius / step;

pub const Backdrop = struct {
    /// Standard0x00RRGGBB values, independent of the source/destination masks.
    /// Width/height are full-resolution extents; stride is sampled-grid columns.
    colors: []const u32,
    width: u32,
    height: u32,
    stride: u32,

    pub fn requiredLen(width: u32, height: u32) Error!usize {
        if (width == 0 or height == 0 or width > surface_module.max_surface_dimension or height > surface_module.max_surface_dimension)
            return error.InvalidBackdrop;
        return @as(usize, columns(width)) * columns(height);
    }
    pub fn validate(self: *const Backdrop) Error!void {
        _ = try requiredLen(self.width, self.height);
        if (self.stride < columns(self.width)) return error.InvalidBackdrop;
        const needed = @as(u64, self.stride) * columns(self.height);
        if (needed > self.colors.len) return error.InvalidBackdrop;
        _ = try byteRange(self.colors.ptr, @intCast(needed));
    }
    /// Source must be readable pixels, with exclusive access during capture.
    /// Both buffers are independent of each other, scanout and source metadata.
    /// All geometry/storage checks precede writes. Returned colors stay borrowed.
    pub fn build(source: *const Surface, colors: []u32, scratch: []u32) Error!Backdrop {
        try source.validate();
        if (source.commands != null) return error.BackdropUnavailable;
        const needed = try requiredLen(source.width, source.height);
        if (colors.len < needed or scratch.len < needed) return error.InvalidBackdropStorage;
        const color_range = try byteRange(colors.ptr, colors.len);
        const scratch_range = try byteRange(scratch.ptr, scratch.len);
        const pixels = try byteRange(source.pixels.ptr, @as(usize, source.stride) * source.height);
        const source_address = @intFromPtr(source);
        const metadata_end = @addWithOverflow(source_address, @sizeOf(Surface));
        if (metadata_end[1] != 0) return error.InvalidBackdropStorage;
        const metadata: Range = .{ .start = source_address, .end = metadata_end[0] };
        if (overlap(color_range, scratch_range) or overlap(color_range, pixels) or overlap(scratch_range, pixels) or
            overlap(color_range, metadata) or overlap(scratch_range, metadata)) return error.AliasedBackdrop;
        const w = columns(source.width);
        const h = columns(source.height);
        for (0..h) |row| for (0..w) |column| {
            const x: u32 = @intCast(column * step);
            const y: u32 = @intCast(row * step);
            const end_x = @min(x + step, source.width);
            const end_y = @min(y + step, source.height);
            var red: u32 = 0;
            var green: u32 = 0;
            var blue: u32 = 0;
            for (y..end_y) |sy| for (x..end_x) |sx| {
                const color = source.decode(source.pixels[sy * source.stride + sx]);
                red += color.r;
                green += color.g;
                blue += color.b;
            };
            const count = (end_x - x) * (end_y - y);
            colors[row * w + column] = pack(Color.rgb(@intCast((red + count / 2) / count), @intCast((green + count / 2) / count), @intCast((blue + count / 2) / count)));
        };
        // Edge replication keeps uniform backgrounds constant and bounds reads.
        for (0..h) |row| for (0..w) |column| {
            var sum: [3]u32 = @splat(0);
            var offset: i64 = -grid_radius;
            while (offset <= grid_radius) : (offset += 1) {
                const sx: usize = @intCast(@min(@max(@as(i64, @intCast(column)) + offset, 0), w - 1));
                const color = unpack(colors[row * w + sx]);
                sum[0] += color.r;
                sum[1] += color.g;
                sum[2] += color.b;
            }
            scratch[row * w + column] = averaged(sum);
        };
        for (0..h) |row| for (0..w) |column| {
            var sum: [3]u32 = @splat(0);
            var offset: i64 = -grid_radius;
            while (offset <= grid_radius) : (offset += 1) {
                const sy: usize = @intCast(@min(@max(@as(i64, @intCast(row)) + offset, 0), h - 1));
                const color = unpack(scratch[sy * w + column]);
                sum[0] += color.r;
                sum[1] += color.g;
                sum[2] += color.b;
            }
            colors[row * w + column] = averaged(sum);
        };
        return .{ .colors = colors[0..needed], .width = source.width, .height = source.height, .stride = w };
    }
    /// Call only on a validated immutable descriptor. Coordinates are global
    /// source pixels; out-of-range positions clamp to the nearest source edge.
    pub fn sample(self: *const Backdrop, x: i64, y: i64) Color {
        const horizontal = coordinate(x, self.width);
        const vertical = coordinate(y, self.height);
        const first = self.colors[vertical.first * self.stride + horizontal.first];
        const second = self.colors[vertical.first * self.stride + horizontal.second];
        const third = self.colors[vertical.second * self.stride + horizontal.first];
        const fourth = self.colors[vertical.second * self.stride + horizontal.second];
        if (first == second and first == third and first == fourth) return unpack(first);
        const a = unpack(first);
        const b = unpack(second);
        const c = unpack(third);
        const d = unpack(fourth);
        return Color.rgb(interpolate(a.r, b.r, c.r, d.r, horizontal.fraction, vertical.fraction), interpolate(a.g, b.g, c.g, d.g, horizontal.fraction, vertical.fraction), interpolate(a.b, b.b, c.b, d.b, horizontal.fraction, vertical.fraction));
    }
};
fn columns(extent: u32) u32 {
    return (extent + step - 1) / step;
}
fn averaged(sum: [3]u32) u32 {
    const count = @as(u32, @intCast(2 * grid_radius + 1));
    return pack(Color.rgb(@intCast((sum[0] + count / 2) / count), @intCast((sum[1] + count / 2) / count), @intCast((sum[2] + count / 2) / count)));
}
const Coordinate = struct { first: usize, second: usize, fraction: u32 };
fn coordinate(value: i64, extent: u32) Coordinate {
    const clamped: u32 = @intCast(@min(@max(value, 0), extent - 1));
    // Grid samples are centered at3.5,11.5,...; use half-pixel integer units.
    const position = clamped * 2 -| (step - 1);
    const first = @min(position / (step * 2), columns(extent) - 1);
    return .{ .first = first, .second = @min(first + 1, columns(extent) - 1), .fraction = position % (step * 2) };
}
fn interpolate(a: u8, b: u8, c: u8, d: u8, x: u32, y: u32) u8 {
    const denominator = step * 2;
    const top = @as(u32, a) * (denominator - x) + @as(u32, b) * x;
    const bottom = @as(u32, c) * (denominator - x) + @as(u32, d) * x;
    return @intCast((top * (denominator - y) + bottom * y + denominator * denominator / 2) / (denominator * denominator));
}
pub fn blend(backdrop: Color, material: Material) Color {
    if (material.opacity == 0) return backdrop;
    if (material.opacity == 255) return material.tint;
    const inverse: u32 = 255 - @as(u32, material.opacity);
    return Color.rgb(@intCast((@as(u32, backdrop.r) * inverse + @as(u32, material.tint.r) * material.opacity + 127) / 255), @intCast((@as(u32, backdrop.g) * inverse + @as(u32, material.tint.g) * material.opacity + 127) / 255), @intCast((@as(u32, backdrop.b) * inverse + @as(u32, material.tint.b) * material.opacity + 127) / 255));
}
fn pack(color: Color) u32 {
    return @as(u32, color.r) << 16 | @as(u32, color.g) << 8 | color.b;
}
fn unpack(value: u32) Color {
    return Color.rgb(@truncate(value >> 16), @truncate(value >> 8), @truncate(value));
}
pub const Range = struct { start: usize, end: usize };
pub fn byteRange(pointer: anytype, count: usize) Error!Range {
    const start = @intFromPtr(pointer);
    if (start == 0 and count != 0) return error.InvalidBackdropStorage;
    const bytes = @mulWithOverflow(count, @sizeOf(u32));
    const end = @addWithOverflow(start, bytes[0]);
    if (bytes[1] != 0 or end[1] != 0) return error.InvalidBackdropStorage;
    return .{ .start = start, .end = end[0] };
}
pub fn overlap(a: Range, b: Range) bool {
    return a.start < b.end and b.start < a.end;
}
