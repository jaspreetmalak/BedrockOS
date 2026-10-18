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
    /// Optional gray8 coverage over the receiver's existing background. Packed
    /// RGB remains standard 0x00RRGGBB; this never exposes framebuffer reads.
    blendPixel: ?*const fn (*anyopaque, u32, u32, u32, u8) void = null,
    /// Optional rounded-material edge coverage. The receiver selects its own
    /// immutable backdrop; the client never receives a sample or pixel grant.
    materialPixel: ?*const fn (*anyopaque, u32, u32, types.Material, u8) void = null,
};

/// A borrowed 32-bit scanout surface; no allocation or physical-address lookup.
pub const Surface = struct {
    pixels: []volatile u32,
    width: u32,
    height: u32,
    stride: u32,
    masks: types.PixelMasks,
    /// Explicit compatibility mode for historical 5x7 diagnostic/OCR callers.
    /// Native GUI surfaces and command overlays default to Axis Sans.
    legacy_text: bool = false,
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
    pub fn blendPixel(self: *Surface, x: u32, y: u32, color: types.Color, coverage: u8) void {
        if (x >= self.width or y >= self.height or coverage == 0) return;
        if (coverage == 255) {
            self.putPixel(x, y, self.encode(color));
            return;
        }
        if (self.commands) |sink| {
            if (sink.blendPixel) |callback| callback(sink.context, x, y, self.encode(color), coverage) else if (coverage >= 128) self.putPixel(x, y, self.encode(color));
            return;
        }
        const old = self.decode(self.pixels[@as(usize, y) * self.stride + x]);
        const inverse: u32 = 255 - @as(u32, coverage);
        const mixed = types.Color.rgb(
            @intCast((@as(u32, color.r) * coverage + @as(u32, old.r) * inverse + 127) / 255),
            @intCast((@as(u32, color.g) * coverage + @as(u32, old.g) * inverse + 127) / 255),
            @intCast((@as(u32, color.b) * coverage + @as(u32, old.b) * inverse + 127) / 255),
        );
        self.putPixel(x, y, self.encode(mixed));
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

    /// Coverage compositing uses the frozen backdrop for the material color,
    /// then the existing destination solely for the geometric edge. Repaint a
    /// frame's base before its overlays; the blur cache itself never feeds back.
    pub fn materialPixel(self: *Surface, x: u32, y: u32, material: types.Material, coverage: u8) void {
        if (x >= self.width or y >= self.height or coverage == 0) return;
        if (coverage == 255) {
            self.materialRect(x, y, 1, 1, material);
            return;
        }
        if (self.commands) |sink| {
            if (sink.materialPixel) |callback| callback(sink.context, x, y, material, coverage) else self.blendPixel(x, y, material.tint, coverage);
            return;
        }
        const color = if (self.backdrop) |backdrop|
            materials.blend(backdrop.sample(@as(i64, x) + self.backdrop_origin.x, @as(i64, y) + self.backdrop_origin.y), material)
        else
            material.tint;
        self.blendPixel(x, y, color, coverage);
    }

    /// Antialiased rounded primitives use signed placement and preserve stride
    /// padding. As with fillRect, callers validate and exclusively borrow first.
    pub fn roundedRect(self: *Surface, x: i32, y: i32, width: u32, height: u32, corner_radius: u32, color: types.Color) void {
        const area = self.visible(x, y, width, height);
        if (area.left >= area.right or area.top >= area.bottom) return;
        const pixel = self.encode(color);
        var row = area.top;
        while (row < area.bottom) : (row += 1) {
            var run: ?u32 = null;
            var column = area.left;
            while (column <= area.right) : (column += 1) {
                const coverage = if (column < area.right) materials.roundedCoverage(width, height, corner_radius, @as(i64, column) - x, @as(i64, row) - y) else 0;
                if (coverage == 255) {
                    if (run == null) run = column;
                } else {
                    if (run) |first| self.fillRect(first, row, column - first, 1, pixel);
                    run = null;
                    if (coverage != 0) self.blendPixel(column, row, color, coverage);
                }
            }
        }
    }

    pub fn roundedMaterialRect(self: *Surface, x: i32, y: i32, width: u32, height: u32, corner_radius: u32, material: types.Material) void {
        const area = self.visible(x, y, width, height);
        if (area.left >= area.right or area.top >= area.bottom) return;
        var row = area.top;
        while (row < area.bottom) : (row += 1) {
            var run: ?u32 = null;
            var column = area.left;
            while (column <= area.right) : (column += 1) {
                const coverage = if (column < area.right) materials.roundedCoverage(width, height, corner_radius, @as(i64, column) - x, @as(i64, row) - y) else 0;
                if (coverage == 255) {
                    if (run == null) run = column;
                } else {
                    if (run) |first| self.materialRect(first, row, column - first, 1, material);
                    run = null;
                    if (coverage != 0) self.materialPixel(column, row, material, coverage);
                }
            }
        }
    }

    /// An inward outline. Inner/outer coverage subtraction prevents jagged
    /// corners; opacity permits quiet glass highlights without bright boxes.
    pub fn roundedBorder(self: *Surface, x: i32, y: i32, width: u32, height: u32, corner_radius: u32, color: types.Color, line_width: u32, opacity: u8) void {
        if (line_width == 0 or opacity == 0) return;
        const area = self.visible(x, y, width, height);
        const inset_x = @min(line_width, width / 2);
        const inset_y = @min(line_width, height / 2);
        const inner_width: u32 = @intCast(width - @min(width, @as(u64, line_width) * 2));
        const inner_height: u32 = @intCast(height - @min(height, @as(u64, line_width) * 2));
        const outer_radius = @min(corner_radius, @min(width, height) / 2);
        const inner_radius = outer_radius -| line_width;
        const inner_x = @as(i64, x) + inset_x;
        const inner_y = @as(i64, y) + inset_y;
        var row = area.top;
        while (row < area.bottom) : (row += 1) {
            // The inner circle's horizontal/vertical central strips are fully
            // covered. They are also inside the outer shape, so subtracting
            // coverage would produce zero. Visit only the remaining edge spans.
            var skip_start = area.right;
            var skip_end = area.right;
            const local_inner_y = @as(i64, row) - inner_y;
            if (inner_width != 0 and local_inner_y >= 0 and local_inner_y < inner_height) {
                const margin: u32 = if (local_inner_y >= inner_radius and local_inner_y < inner_height - inner_radius) 0 else inner_radius;
                skip_start = @intCast(@min(@as(i64, area.right), @max(@as(i64, area.left), inner_x + margin)));
                skip_end = @intCast(@min(@as(i64, area.right), @max(@as(i64, area.left), inner_x + inner_width - margin)));
            }
            var column = area.left;
            while (column < area.right) {
                if (column == skip_start and skip_end > skip_start) {
                    column = skip_end;
                    continue;
                }
                const local_x = @as(i64, column) - x;
                const local_y = @as(i64, row) - y;
                const outer = materials.roundedCoverage(width, height, outer_radius, local_x, local_y);
                const inner = materials.roundedCoverage(inner_width, inner_height, inner_radius, local_x - inset_x, local_y - inset_y);
                const coverage: u8 = @intCast((@as(u32, outer -| inner) * opacity + 127) / 255);
                self.blendPixel(column, row, color, coverage);
                column += 1;
            }
        }
    }

    const Visible = struct { left: u32, top: u32, right: u32, bottom: u32 };
    fn visible(self: *const Surface, x: i32, y: i32, width: u32, height: u32) Visible {
        return .{
            .left = @intCast(@min(self.width, @max(@as(i64, 0), x))),
            .top = @intCast(@min(self.height, @max(@as(i64, 0), y))),
            .right = @intCast(@min(self.width, @max(@as(i64, 0), @as(i64, x) + width))),
            .bottom = @intCast(@min(self.height, @max(@as(i64, 0), @as(i64, y) + height))),
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
