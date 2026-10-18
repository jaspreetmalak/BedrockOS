//! Essential boot display backend. It borrows a validated, supervisor-mapped
//! firmware framebuffer; it neither discovers a physical GPU nor grants access.
const std = @import("std");
const protocol = @import("boot_protocol");
const anvil = @import("anvil");
const core = @import("anvil_core");
const pixel_format = @import("pixel_format.zig");

/// Keep at a stable address after initialize. CPU submissions are synchronous:
/// source imports may be released only after their completion fence is checked.
pub const Driver = struct {
    framebuffer: protocol.Framebuffer = .{},
    software: core.Software(2) = .{},
    target: ?anvil.Texture = null,
    queue: ?anvil.Queue = null,
    sequence: u64 = 0,
    initialized: bool = false,

    pub fn initialize(self: *Driver, framebuffer: protocol.Framebuffer) !void {
        if (self.initialized) return error.AlreadyInitialized;
        try framebuffer.validate();
        if (framebuffer.base == 0 or framebuffer.width > anvil.max_texture_dimension or
            framebuffer.height > anvil.max_texture_dimension) return error.UnsupportedFramebuffer;
        const count = std.math.mul(usize, framebuffer.pixels_per_scanline, framebuffer.height) catch return error.Overflow;
        const format: ?anvil.Format = if (framebuffer.red_mask == 0xff0000 and framebuffer.green_mask == 0xff00 and framebuffer.blue_mask == 0xff)
            .xrgb8888
        else if (framebuffer.red_mask == 0xff and framebuffer.green_mask == 0xff00 and framebuffer.blue_mask == 0xff0000)
            .xbgr8888
        else
            null;
        if (format) |native| {
            const pixels: [*]volatile u32 = @ptrFromInt(framebuffer.base);
            const target = try self.software.importImage(.{
                .pixels = pixels[0..count],
                .width = framebuffer.width,
                .height = framebuffer.height,
                .stride = framebuffer.pixels_per_scanline,
                .format = native,
            });
            errdefer self.software.release(target) catch unreachable;
            self.queue = try anvil.Queue.init(self.software.provider());
            self.target = target;
        }
        self.framebuffer = framebuffer;
        self.initialized = true;
    }

    /// Only a trusted broker may pass a source view, after checking its grant,
    /// mapping and lease. This adapter adds no surface or driver permissions.
    pub fn present(self: *Driver, source: core.Image, rect: anvil.Rect, destination: anvil.Point) !anvil.Fence {
        if (!self.initialized) return error.NotInitialized;
        if (self.sequence == std.math.maxInt(u64)) return error.SequenceExhausted;
        try source.validate();
        if (!try rect.fits(.{ .width = source.width, .height = source.height })) return error.OutOfBounds;
        const target_rect: anvil.Rect = .{ .x = destination.x, .y = destination.y, .width = rect.width, .height = rect.height };
        if (!try target_rect.fits(.{ .width = self.framebuffer.width, .height = self.framebuffer.height })) return error.OutOfBounds;
        const source_begin = @intFromPtr(source.pixels.ptr);
        const source_end = source_begin + source.pixels.len * @sizeOf(u32); // Image.validate checked the complete span.
        const target_end = self.framebuffer.base + @as(u64, self.framebuffer.pixels_per_scanline) * self.framebuffer.height * @sizeOf(u32);
        if (source_begin < target_end and self.framebuffer.base < source_end) return error.AliasedImage;
        const sequence = self.sequence + 1;
        if (self.target) |target| {
            var borrowed = source;
            borrowed.access = .read_only;
            const texture = try self.software.importImage(borrowed);
            defer self.software.release(texture) catch unreachable;
            const command = [_]anvil.Command{.{ .copy = .{
                .source = texture,
                .target = target,
                .source_rect = rect,
                .destination = destination,
            } }};
            const queue = &self.queue.?;
            const fence = try queue.submit(sequence, &command);
            self.sequence = fence.sequence;
            // This exact backend is synchronous. This is not a safe release
            // strategy for a future asynchronous or DMA-backed implementation.
            if (!try queue.isComplete(fence)) @panic("synchronous Anvil backend returned an incomplete fence");
            return fence;
        }
        // Preserve uncommon, validated firmware masks as a software fallback.
        // The driver owns channel encoding; it does not label this GPU work.
        const format = pixel_format.Format.init(self.framebuffer.red_mask, self.framebuffer.green_mask, self.framebuffer.blue_mask);
        const target: [*]volatile u32 = @ptrFromInt(self.framebuffer.base);
        for (0..rect.height) |y| for (0..rect.width) |x| {
            const raw = source.pixels[(rect.y + y) * source.stride + rect.x + x];
            const rgb = if (source.format == .xrgb8888) raw else ((raw & 0xff) << 16) | (raw & 0xff00) | ((raw >> 16) & 0xff);
            target[(destination.y + y) * self.framebuffer.pixels_per_scanline + destination.x + x] = format.encode(rgb);
        };
        self.sequence = sequence;
        return .{ .sequence = sequence };
    }
};

test {
    _ = @import("framebuffer_tests.zig");
}
