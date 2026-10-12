const types = @import("types.zig");
const materials = @import("materials.zig");
const Point = @import("input.zig").Point;
pub const Error = error{
    InvalidSurface,
    SurfaceTooLarge,
    InvalidPixelMasks,
    LayoutOverflow,
    InvalidScale,
    TooManyNodes,
    GraphTooDeep,
    CyclicGraph,
    InvalidMaterial,
    InvalidBackdrop,
    InvalidBackdropStorage,
    BackdropUnavailable,
    AliasedBackdrop,
};

pub const max_surface_dimension: u32 = 16384;
/// Commands carry bounded client coordinates and standard 0x00RRGGBB pixels.
/// The receiver owns window/surface authority and rechecks every command.
/// A failing receiver records failure in context; callbacks never unwind paint.
pub const CommandSink = struct {
    context: *anyopaque,
    fillRect: *const fn (*anyopaque, u32, u32, u32, u32, u32) void,
    materialRect: ?*const fn (*anyopaque, u32, u32, u32, u32, types.Material) void = null,
};

/// A borrowed 32-bit scanout surface; no allocation or physical-address lookup.
pub const Surface = struct {
    pixels: []volatile u32,
    width: u32,
    height: u32,
    stride: u32,
    masks: types.PixelMasks,
    commands: ?CommandSink = null,
    backdrop: ?*const materials.Backdrop = null,
    backdrop_origin: Point = .{ .x = 0, .y = 0 },

    pub fn init(pixels: []volatile u32, width: u32, height: u32, stride: u32, masks: types.PixelMasks) Error!Surface {
        if (width == 0 or height == 0 or stride < width or @intFromPtr(pixels.ptr) % @alignOf(u32) != 0)
            return error.InvalidSurface;
        if (width > max_surface_dimension or height > max_surface_dimension) return error.SurfaceTooLarge;
        const required = @as(u64, stride) * height;
        if (required > pixels.len) return error.InvalidSurface;
        const required_bytes = required * @sizeOf(u32);
        if (required_bytes > ~@as(usize, 0)) return error.InvalidSurface;
        const address_end = @addWithOverflow(@intFromPtr(pixels.ptr), @as(usize, @intCast(required_bytes)));
        if (address_end[1] != 0) return error.InvalidSurface;
        if (masks.red == 0 or masks.green == 0 or masks.blue == 0 or
            masks.red & masks.green != 0 or masks.red & masks.blue != 0 or masks.green & masks.blue != 0 or
            masks.reserved & (masks.red | masks.green | masks.blue) != 0)
            return error.InvalidPixelMasks;
        return .{ .pixels = pixels, .width = width, .height = height, .stride = stride, .masks = masks };
    }

    pub fn initCommands(width: u32, height: u32, sink: CommandSink) Error!Surface {
        if (width == 0 or height == 0) return error.InvalidSurface;
        if (width > max_surface_dimension or height > max_surface_dimension) return error.SurfaceTooLarge;
        return .{ .pixels = &.{}, .width = width, .height = height, .stride = width, .masks = .{ .red = 0xff0000, .green = 0xff00, .blue = 0xff }, .commands = sink };
    }

    pub fn validate(self: *const Surface) Error!void {
        if (self.commands) |sink| {
            _ = try initCommands(self.width, self.height, sink);
            if (self.pixels.len != 0 or self.stride != self.width or self.masks.red != 0xff0000 or
                self.masks.green != 0xff00 or self.masks.blue != 0xff or self.masks.reserved != 0)
                return error.InvalidSurface;
        } else _ = try init(self.pixels, self.width, self.height, self.stride, self.masks);
        if (self.backdrop) |backdrop| {
            if (self.commands == null and materials.overlap(try materials.byteRange(self.pixels.ptr, @as(usize, self.stride) * self.height), try materials.byteRange(backdrop, @sizeOf(materials.Backdrop) / @sizeOf(u32)))) return error.AliasedBackdrop;
            try backdrop.validate();
            if (self.commands == null and materials.overlap(try materials.byteRange(self.pixels.ptr, @as(usize, self.stride) * self.height), try materials.byteRange(backdrop.colors.ptr, @as(usize, backdrop.stride) * ((backdrop.height + materials.step - 1) / materials.step))))
                return error.AliasedBackdrop;
        }
    }

    pub fn setBackdrop(self: *Surface, backdrop: ?*const materials.Backdrop, origin: Point) Error!void {
        var candidate = self.*;
        candidate.backdrop = backdrop;
        candidate.backdrop_origin = origin;
        try candidate.validate();
        self.backdrop = backdrop;
        self.backdrop_origin = origin;
    }

    /// Painting uses a validated, exclusively borrowed Surface. These helpers
    /// additionally clip each write; they do not grant accessibility/authority.
    pub fn putPixel(self: *Surface, x: u32, y: u32, pixel: u32) void {
        if (x >= self.width or y >= self.height) return;
        if (self.commands) |sink| sink.fillRect(sink.context, x, y, 1, 1, pixel) else self.pixels[@as(usize, y) * self.stride + x] = pixel;
    }
    pub fn fillRect(self: *Surface, x: u32, y: u32, width: u32, height: u32, pixel: u32) void {
        if (x >= self.width or y >= self.height) return;
        const w = @min(width, self.width - x);
        const h = @min(height, self.height - y);
        if (w == 0 or h == 0) return;
        if (self.commands) |sink| sink.fillRect(sink.context, x, y, w, h, pixel) else for (y..y + h) |row| for (x..x + w) |column| {
            self.pixels[row * self.stride + column] = pixel;
        };
    }
    /// Like fillRect, call after validating exclusive surface/backdrop access.
    /// A command receiver supplies its own frozen backdrop and window authority.
    pub fn materialRect(self: *Surface, x: u32, y: u32, width: u32, height: u32, material: types.Material) void {
        if (x >= self.width or y >= self.height) return;
        const w = @min(width, self.width - x);
        const h = @min(height, self.height - y);
        if (w == 0 or h == 0) return;
        if (self.commands) |sink| {
            if (sink.materialRect) |callback| callback(sink.context, x, y, w, h, material) else self.fillRect(x, y, w, h, self.encode(material.tint));
            return;
        }
        const backdrop = self.backdrop orelse {
            self.fillRect(x, y, w, h, self.encode(material.tint));
            return;
        };
        if (material.opacity == 255) {
            self.fillRect(x, y, w, h, self.encode(material.tint));
            return;
        }
        for (y..y + h) |row| for (x..x + w) |column| {
            const sampled = backdrop.sample(@as(i64, @intCast(column)) + self.backdrop_origin.x, @as(i64, @intCast(row)) + self.backdrop_origin.y);
            self.pixels[row * self.stride + column] = self.encode(materials.blend(sampled, material));
        };
    }

    /// Scale each 8-bit channel to its mask's precision, then scatter its bits.
    /// Unused and reserved bits remain zero; contiguous byte masks are not assumed.
    pub fn encode(self: Surface, color: types.Color) u32 {
        if (self.masks.red == 0xff0000 and self.masks.green == 0xff00 and self.masks.blue == 0xff)
            return @as(u32, color.r) << 16 | @as(u32, color.g) << 8 | color.b;
        if (self.masks.red == 0xff and self.masks.green == 0xff00 and self.masks.blue == 0xff0000)
            return @as(u32, color.b) << 16 | @as(u32, color.g) << 8 | color.r;
        return channel(color.r, self.masks.red) | channel(color.g, self.masks.green) | channel(color.b, self.masks.blue);
    }
    pub fn decode(self: Surface, pixel: u32) types.Color {
        if (self.masks.red == 0xff0000 and self.masks.green == 0xff00 and self.masks.blue == 0xff)
            return types.Color.rgb(@truncate(pixel >> 16), @truncate(pixel >> 8), @truncate(pixel));
        if (self.masks.red == 0xff and self.masks.green == 0xff00 and self.masks.blue == 0xff0000)
            return types.Color.rgb(@truncate(pixel), @truncate(pixel >> 8), @truncate(pixel >> 16));
        return types.Color.rgb(decodeChannel(pixel, self.masks.red), decodeChannel(pixel, self.masks.green), decodeChannel(pixel, self.masks.blue));
    }
};
fn decodeChannel(pixel: u32, mask: u32) u8 {
    var value: u64 = 0;
    var position: u6 = 0;
    for (0..32) |bit| {
        const flag = @as(u32, 1) << @as(u5, @intCast(bit));
        if (mask & flag == 0) continue;
        if (pixel & flag != 0) value |= @as(u64, 1) << position;
        position += 1;
    }
    const maximum = (@as(u64, 1) << position) - 1;
    return @intCast((value * 255 + maximum / 2) / maximum);
}

fn channel(component: u8, mask: u32) u32 {
    const bits: u6 = @intCast(@popCount(mask));
    const maximum = (@as(u64, 1) << bits) - 1;
    var scaled = (@as(u64, component) * maximum + 127) / 255;
    var encoded: u32 = 0;
    for (0..32) |position| {
        const bit = @as(u32, 1) << @as(u5, @intCast(position));
        if (mask & bit == 0) continue;
        if (scaled & 1 != 0) encoded |= bit;
        scaled >>= 1;
    }
    return encoded;
}
