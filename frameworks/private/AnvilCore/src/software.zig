//! Synchronous, allocation-free CPU fill/copy provider. Its storage, provider
//! context, command lists and imported pixel buffers are caller-owned borrows.
const std = @import("std");
const anvil = @import("anvil");

pub const Access = enum { read_only, read_write };
pub const Image = struct {
    pixels: []volatile u32,
    width: u32,
    height: u32,
    stride: u32,
    format: anvil.Format,
    access: Access = .read_write,

    pub fn validate(self: Image) !void {
        _ = try validateImage(self);
    }

    pub fn extent(self: Image) anvil.Extent {
        return .{ .width = self.width, .height = self.height };
    }
};

pub const max_texture_extent: anvil.Extent = .{ .width = 16384, .height = 16384 };

// Shared by every Software(N) instantiation. Never recycle a slot identity, even
// when a device is destroyed, so foreign/stale tokens cannot become valid again.
var next_identity = std.atomic.Value(u32).init(1);

fn allocateIdentity() !u32 {
    var candidate = next_identity.load(.monotonic);
    while (true) {
        if (candidate == std.math.maxInt(u32)) return error.ResourceIdentityExhausted;
        if (next_identity.cmpxchgWeak(candidate, candidate + 1, .monotonic, .monotonic)) |observed| {
            candidate = observed;
        } else return candidate;
    }
}

const Span = struct {
    start: usize,
    end: usize,

    fn overlaps(self: Span, other: Span) bool {
        return self.start < other.end and other.start < self.end;
    }
};

fn byteSpan(address: usize, count: usize, element_size: usize) !Span {
    const bytes = std.math.mul(usize, count, element_size) catch return error.Overflow;
    const end = std.math.add(usize, address, bytes) catch return error.Overflow;
    return .{ .start = address, .end = end };
}

fn validateImage(image: Image) !Span {
    try (anvil.Extent{ .width = image.width, .height = image.height }).validate();
    if (image.width > max_texture_extent.width or image.height > max_texture_extent.height) return error.OutOfBounds;
    if (image.stride < image.width) return error.InvalidStride;
    const last_row = std.math.mul(usize, image.height - 1, image.stride) catch return error.Overflow;
    const pixels = std.math.add(usize, last_row, image.width) catch return error.Overflow;
    if (image.pixels.len < pixels) return error.BufferTooSmall;
    // Validate the caller's entire supplied slice before retaining the used
    // prefix; this also catches forged overflowing slices without dereferencing.
    _ = try byteSpan(@intFromPtr(image.pixels.ptr), image.pixels.len, @sizeOf(u32));
    return byteSpan(@intFromPtr(image.pixels.ptr), pixels, @sizeOf(u32));
}

const Slot = struct {
    identity: u32 = 0,
    generation: u32 = 1,
    retired: bool = false,
    image: ?Image = null,
    span: Span = .{ .start = 0, .end = 0 },

    fn texture(self: Slot) anvil.Texture {
        return .{ .token = (@as(u64, self.identity) << 32) | self.generation };
    }
};

/// Each instance is one serialized queue. Once provider() or importImage() is
/// called, keep it at the same address and do not copy or reset it while borrowed.
/// The kernel/owner must first authorize and map every image; a token adds no grant.
pub fn Software(comptime capacity: usize) type {
    if (capacity == 0 or capacity > 65536) @compileError("Anvil CPU resource capacity must be 1...65536");
    return struct {
        const Self = @This();
        slots: [capacity]Slot = @splat(.{}),
        home: usize = 0,
        last_submitted: u64 = 0,
        last_completed: u64 = 0,

        fn checkHome(self: *const Self) !void {
            if (self.home != 0 and self.home != @intFromPtr(self)) return error.MovedDevice;
        }

        pub fn importImage(self: *Self, image: Image) !anvil.Texture {
            try self.checkHome();
            const span = try validateImage(image);
            const metadata = try byteSpan(@intFromPtr(self), 1, @sizeOf(Self));
            if (span.overlaps(metadata)) return error.AliasedImage;
            var free: ?*Slot = null;
            for (&self.slots) |*slot| {
                if (slot.image != null) {
                    if (span.overlaps(slot.span)) return error.AliasedImage;
                } else if (!slot.retired and free == null) free = slot;
            }
            const slot = free orelse return error.TextureCapacity;
            if (slot.identity == 0) slot.identity = try allocateIdentity();
            const used_pixels = (span.end - span.start) / @sizeOf(u32);
            var imported = image;
            imported.pixels = image.pixels[0..used_pixels];
            slot.image = imported;
            slot.span = span;
            self.home = @intFromPtr(self);
            return slot.texture();
        }

        pub fn release(self: *Self, texture: anvil.Texture) !void {
            try self.checkHome();
            const slot = try self.resolve(texture);
            slot.image = null;
            slot.span = .{ .start = 0, .end = 0 };
            if (slot.generation == std.math.maxInt(u32)) {
                slot.retired = true;
            } else slot.generation += 1;
        }

        /// Context remains borrowed until all users of this Provider are gone.
        pub fn provider(self: *Self) anvil.Provider {
            if (self.home == 0) self.home = @intFromPtr(self);
            return .{ .context = self, .info = info, .submit = submit, .completed = completed };
        }

        fn resolve(self: *Self, texture: anvil.Texture) !*Slot {
            try texture.validate();
            for (&self.slots) |*slot| {
                if (slot.image != null and slot.texture().token == texture.token) return slot;
            }
            return error.InvalidTexture;
        }

        fn info(context: *anyopaque) !anvil.DeviceInfo {
            const self: *Self = @ptrCast(@alignCast(context));
            try self.checkHome();
            return .{
                .name = "Anvil CPU 2D",
                .acceleration = .software,
                .capabilities = .{ .fill = true, .copy = true },
                .max_texture_extent = max_texture_extent,
                .formats = .{ .xrgb8888 = true, .xbgr8888 = true },
            };
        }

        fn validate(self: *Self, commands: []const anvil.Command) !void {
            try anvil.validateCommands(commands);
            const command_span = try byteSpan(@intFromPtr(commands.ptr), commands.len, @sizeOf(anvil.Command));
            for (&self.slots) |*slot| {
                if (slot.image != null and command_span.overlaps(slot.span)) return error.AliasedCommandStorage;
            }
            for (commands) |command| switch (command) {
                .fill => |fill| {
                    const target = (try self.resolve(fill.target)).image.?;
                    if (target.access != .read_write) return error.ReadOnlyTexture;
                    if (!try fill.rect.fits(.{ .width = target.width, .height = target.height })) return error.OutOfBounds;
                },
                .copy => |copy| {
                    const source = (try self.resolve(copy.source)).image.?;
                    const target = (try self.resolve(copy.target)).image.?;
                    if (target.access != .read_write) return error.ReadOnlyTexture;
                    if (!try copy.source_rect.fits(.{ .width = source.width, .height = source.height }) or
                        !try copy.destinationRect().fits(.{ .width = target.width, .height = target.height })) return error.OutOfBounds;
                },
            };
        }

        fn submit(context: *anyopaque, sequence: u64, commands: []const anvil.Command) !anvil.Fence {
            const self: *Self = @ptrCast(@alignCast(context));
            try self.checkHome();
            if (sequence == 0 or sequence <= self.last_submitted) return error.InvalidSequence;
            // No stores to images or fence state occur before whole-batch
            // validation. Callers serialize imports, releases and submissions.
            try self.validate(commands);
            for (commands) |command| switch (command) {
                .fill => |fill| {
                    const target = (self.resolve(fill.target) catch unreachable).image.?;
                    fillPixels(target, fill.rect, fill.color);
                },
                .copy => |copy| {
                    const source = (self.resolve(copy.source) catch unreachable).image.?;
                    const target = (self.resolve(copy.target) catch unreachable).image.?;
                    copyPixels(source, target, copy);
                },
            };
            self.last_submitted = sequence;
            self.last_completed = sequence;
            return .{ .sequence = sequence };
        }

        fn completed(context: *anyopaque) !anvil.Fence {
            const self: *Self = @ptrCast(@alignCast(context));
            try self.checkHome();
            return .{ .sequence = self.last_completed };
        }
    };
}

fn swapRedBlue(color: u32) u32 {
    return ((color & 0xff) << 16) | (color & 0x00ff00) | ((color >> 16) & 0xff);
}

fn fillPixels(target: Image, rect: anvil.Rect, canonical: u32) void {
    @setRuntimeSafety(false); // Entire image, stride and rectangle checked above.
    const encoded = if (target.format == .xbgr8888) swapRedBlue(canonical) else canonical;
    var row: usize = 0;
    while (row < rect.height) : (row += 1) {
        const start = (@as(usize, rect.y) + row) * target.stride + rect.x;
        var column: usize = 0;
        while (column < rect.width) : (column += 1) target.pixels[start + column] = encoded;
    }
}

fn copyPixels(source: Image, target: Image, copy: anvil.Copy) void {
    const backwards = copy.source.token == copy.target.token and
        (@as(u64, copy.destination.y) * target.stride + copy.destination.x >
            @as(u64, copy.source_rect.y) * source.stride + copy.source_rect.x);
    if (source.format == target.format) {
        copyRows(source, target, copy, backwards, false);
    } else copyRows(source, target, copy, backwards, true);
}

fn copyRows(source: Image, target: Image, copy: anvil.Copy, backwards: bool, comptime swap: bool) void {
    @setRuntimeSafety(false); // Whole batch is validated before entering here.
    var row: usize = 0;
    while (row < copy.source_rect.height) : (row += 1) {
        const y = if (backwards) copy.source_rect.height - 1 - row else row;
        const source_start = (@as(usize, copy.source_rect.y) + y) * source.stride + copy.source_rect.x;
        const target_start = (@as(usize, copy.destination.y) + y) * target.stride + copy.destination.x;
        if (backwards) {
            var column: usize = copy.source_rect.width;
            while (column != 0) {
                column -= 1;
                const pixel = source.pixels[source_start + column];
                target.pixels[target_start + column] = if (swap) swapRedBlue(pixel) else pixel & 0x00ff_ffff;
            }
        } else {
            var column: usize = 0;
            while (column < copy.source_rect.width) : (column += 1) {
                const pixel = source.pixels[source_start + column];
                target.pixels[target_start + column] = if (swap) swapRedBlue(pixel) else pixel & 0x00ff_ffff;
            }
        }
    }
}

test "global resource identity exhaustion never wraps or partially imports" {
    const saved = next_identity.load(.monotonic);
    defer next_identity.store(saved, .monotonic);
    next_identity.store(std.math.maxInt(u32) - 1, .monotonic);
    try std.testing.expectEqual(std.math.maxInt(u32) - 1, try allocateIdentity());
    try std.testing.expectError(error.ResourceIdentityExhausted, allocateIdentity());
    var pixels: [1]u32 = .{0x123456};
    var device: Software(1) = .{};
    try std.testing.expectError(error.ResourceIdentityExhausted, device.importImage(.{
        .pixels = &pixels,
        .width = 1,
        .height = 1,
        .stride = 1,
        .format = .xrgb8888,
    }));
    try std.testing.expectEqual(@as(u32, 0), device.slots[0].identity);
    try std.testing.expect(device.slots[0].image == null);
    try std.testing.expectEqual(@as(usize, 0), device.home);
    try std.testing.expectEqual(@as(u32, 0x123456), pixels[0]);
    try std.testing.expectEqual(std.math.maxInt(u32), next_identity.load(.monotonic));
}
