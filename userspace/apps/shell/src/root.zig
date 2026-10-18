//! Compact native desktop backdrop and working Files launch presentation.
//! The trusted host owns launch/focus/window policy; this package paints only.
pub const axisui = @import("axisui");
pub const system_bar = @import("system_bar.zig");
test {
    _ = system_bar;
}
const Color = axisui.Color;
const View = axisui.View;
const wallpaper = @import("wallpaper.zig");
pub const bar_height: u32 = 36;
pub const palette = struct {
    pub const desktop = wallpaper.charcoal;
    pub const bar = Color.rgb(32, 34, 44);
    pub const button = Color.rgb(51, 53, 65);
    pub const text = Color.rgb(228, 223, 213);
    pub const rose = Color.rgb(212, 149, 173);
    pub const blue = Color.rgb(139, 174, 192);
    pub const line = Color.rgb(56, 59, 72);
};

/// The host uses this same rectangle for its actual Files launch action.
/// Clamping makes a clipped launch chip noninteractive on a tiny surface.
pub fn launchRect(width: u32, height: u32) axisui.Rect {
    const left = @min(width, 94);
    return .{ .x = @intCast(left), .y = 0, .width = @min(width - left, 72), .height = @min(height, bar_height) };
}

/// Host convenience; small-stack callers retain Workspace outside their stack.
pub fn render(surface: *axisui.Surface, architecture: []const u8) !void {
    var scratch: axisui.Workspace = undefined;
    return renderWithWorkspace(surface, &scratch, architecture);
}

/// Rows and views use caller-owned storage, with no image assets or allocation.
/// Borrowed child slices stay live through synchronous declarative rendering.
pub fn renderWithWorkspace(surface: *axisui.Surface, scratch: *axisui.Workspace, architecture: []const u8) !void {
    try surface.validate();
    _ = try axisui.font.measure(architecture, 1);
    try renderWallpaper(surface);
    try renderBarWithWorkspace(surface, scratch, architecture);
}

/// Paint only the procedural backdrop. The host can snapshot and blur this
/// immutable wallpaper before attaching it to a Surface and drawing chrome.
pub fn renderWallpaper(surface: *axisui.Surface) !void {
    try wallpaper.render(surface);
}

/// Paint only the compact bar, sampling an attached immutable backdrop.
/// Without a backdrop the material has AxisUI's solid-tint fallback.
pub fn renderBarWithWorkspace(surface: *axisui.Surface, scratch: *axisui.Workspace, architecture: []const u8) !void {
    try surface.validate();
    _ = try axisui.font.measure(architecture, 1);
    var architecture_label = axisui.Text(architecture);
    architecture_label.style = comptime axisui.Text("").foreground(palette.blue).style;
    const items = [_]View{
        comptime axisui.Text("Bedrock").frame(76, 28).@"align"(.center).foreground(palette.text),
        comptime axisui.Text("Files").frame(72, 28).@"align"(.center)
            .background(palette.button).foreground(palette.rose).cornerRadius(6),
        comptime axisui.Spacer().flex(1),
        architecture_label,
    };
    var bar = axisui.HStack(&items);
    bar.style = comptime axisui.HStack(&.{}).frame(null, 36).padding(4).gap(14)
        .@"align"(.center).material(.{ .tint = palette.bar, .opacity = 170 }).border(palette.line, 1).style;
    try axisui.renderWithWorkspace(surface, scratch, bar);
}

test "compact desktop covers reference scanout without touching stride padding or guards" {
    const std = @import("std");
    const sentinel: u32 = 0xa5b6c7d8;
    for ([_]struct { width: u32, height: u32 }{
        .{ .width = 800, .height = 600 }, .{ .width = 1280, .height = 800 },
    }) |size| {
        const stride = size.width + 7;
        const count: usize = @as(usize, stride) * size.height;
        const pixels = try std.testing.allocator.alloc(u32, count + 2);
        defer std.testing.allocator.free(pixels);
        @memset(pixels, sentinel);
        var surface = try axisui.Surface.init(pixels[1 .. count + 1], size.width, size.height, stride, .{ .red = 0xff0000, .green = 0xff00, .blue = 0xff, .reserved = 0xff000000 });
        var scratch: axisui.Workspace = undefined;
        try renderWithWorkspace(&surface, &scratch, "ARM64");
        try std.testing.expectEqual(sentinel, pixels[0]);
        try std.testing.expectEqual(sentinel, pixels[count + 1]);
        for (0..size.height) |y| {
            const start = 1 + y * stride;
            for (0..size.width) |x| try std.testing.expect(pixels[start + x] != sentinel);
            for (size.width..stride) |x| try std.testing.expectEqual(sentinel, pixels[start + x]);
        }
        // Work area stays quiet and the launch action is the visible rose chip.
        try std.testing.expectEqual(surface.encode(palette.bar), pixels[1 + 12 * stride + size.width / 2]);
        const launch = launchRect(size.width, size.height);
        try std.testing.expect(launch.contains(.{ .x = 100, .y = 20 }));
        try std.testing.expect(!launch.contains(.{ .x = 80, .y = 20 }));
        try std.testing.expect(!launch.contains(.{ .x = 100, .y = 36 }));
        var ink: usize = 0;
        for (0..bar_height) |y| for (94..166) |x| {
            const pixel = pixels[1 + y * stride + x];
            // At least half-covered rose text over the opaque launch button.
            // Supersampled strokes need not contain an entirely opaque pixel.
            for (128..256) |coverage| {
                const inverse = 255 - coverage;
                const expected = Color.rgb(
                    @intCast((@as(u32, palette.rose.r) * coverage + @as(u32, palette.button.r) * inverse + 127) / 255),
                    @intCast((@as(u32, palette.rose.g) * coverage + @as(u32, palette.button.g) * inverse + 127) / 255),
                    @intCast((@as(u32, palette.rose.b) * coverage + @as(u32, palette.button.b) * inverse + 127) / 255),
                );
                if (pixel == surface.encode(expected)) {
                    ink += 1;
                    break;
                }
            }
        };
        try std.testing.expect(ink > 35);
        try std.testing.expect(pixels[1 + 100 * stride + 100] != pixels[1 + (size.height - 1) * stride + size.width - 1]);
        const clipped = launchRect(60, 10);
        try std.testing.expectEqual(@as(u32, 0), clipped.width);
        try std.testing.expect(!clipped.contains(.{ .x = 60, .y = 0 }));
    }
}

test "desktop architecture label comes from caller and bad geometry never paints" {
    const std = @import("std");
    const count = 800 * 600;
    const first = try std.testing.allocator.alloc(u32, count);
    defer std.testing.allocator.free(first);
    const second = try std.testing.allocator.alloc(u32, count);
    defer std.testing.allocator.free(second);
    const masks: axisui.PixelMasks = .{ .red = 0xff0000, .green = 0xff00, .blue = 0xff };
    var a = try axisui.Surface.init(first, 800, 600, 800, masks);
    var b = try axisui.Surface.init(second, 800, 600, 800, masks);
    var scratch: axisui.Workspace = undefined;
    try renderWithWorkspace(&a, &scratch, "ARM64");
    try renderWithWorkspace(&b, &scratch, "RV64");
    try std.testing.expect(!std.mem.eql(u32, first, second));
    @memset(first, 0x12345678);
    a.stride = 799;
    try std.testing.expectError(error.InvalidSurface, renderWithWorkspace(&a, &scratch, "ARM64"));
    for (first) |pixel| try std.testing.expectEqual(@as(u32, 0x12345678), pixel);
}

test "wallpaper is genuinely varied with intermediate rose and blue tones" {
    const std = @import("std");
    const width = 800;
    const height = 600;
    const pixels = try std.testing.allocator.alloc(u32, width * height);
    defer std.testing.allocator.free(pixels);
    var surface = try axisui.Surface.init(pixels, width, height, width, .{ .red = 0xff0000, .green = 0xff00, .blue = 0xff });
    try renderWallpaper(&surface);
    var tones: [128]u32 = undefined;
    var tone_count: usize = 0;
    var rose_pixels: usize = 0;
    var blue_pixels: usize = 0;
    for (0..height) |y| for (0..width) |x| {
        const pixel = pixels[y * width + x];
        const red: u8 = @truncate(pixel >> 16);
        const green: u8 = @truncate(pixel >> 8);
        const blue: u8 = @truncate(pixel);
        // Muted intermediates rather than flat charcoal or full accent colors.
        if (red > 50 and red > green + 8 and blue > green) rose_pixels += 1;
        if (blue > 65 and blue > red + 12 and green > red) blue_pixels += 1;
        if (x % 31 == 0 and y % 29 == 0 and tone_count < tones.len) {
            var seen = false;
            for (tones[0..tone_count]) |prior| if (prior == pixel) {
                seen = true;
                break;
            };
            if (!seen) {
                tones[tone_count] = pixel;
                tone_count += 1;
            }
        }
    };
    try std.testing.expect(tone_count >= 30);
    try std.testing.expect(rose_pixels > width * height / 20);
    try std.testing.expect(blue_pixels > width * height / 20);
}

test "wallpaper light fields have restrained contrast and no hard plane edges" {
    const std = @import("std");
    for ([_]struct { width: u32, height: u32 }{
        .{ .width = 800, .height = 600 }, .{ .width = 1280, .height = 800 },
    }) |size| {
        const pixels = try std.testing.allocator.alloc(u32, @as(usize, size.width) * size.height);
        defer std.testing.allocator.free(pixels);
        var surface = try axisui.Surface.init(pixels, size.width, size.height, size.width, .{ .red = 0xff0000, .green = 0xff00, .blue = 0xff });
        try renderWallpaper(&surface);
        for (0..size.height) |y| for (0..size.width) |x| {
            const offset = y * size.width + x;
            const current = surface.decode(pixels[offset]);
            for ([_]u8{ current.r, current.g, current.b }) |value| try std.testing.expect(value < 100);
            if (x != 0) {
                const prior = surface.decode(pixels[offset - 1]);
                try std.testing.expect(@abs(@as(i16, current.r) - prior.r) <= 3);
                try std.testing.expect(@abs(@as(i16, current.g) - prior.g) <= 3);
                try std.testing.expect(@abs(@as(i16, current.b) - prior.b) <= 3);
            }
            if (y != 0) {
                const prior = surface.decode(pixels[offset - size.width]);
                try std.testing.expect(@abs(@as(i16, current.r) - prior.r) <= 3);
                try std.testing.expect(@abs(@as(i16, current.g) - prior.g) <= 3);
                try std.testing.expect(@abs(@as(i16, current.b) - prior.b) <= 3);
            }
        };
    }
}

test "bar-only rendering leaves wallpaper and padding outside36pixels unchanged" {
    const std = @import("std");
    const width = 800;
    const height = 80;
    const stride = width + 3;
    const sentinel: u32 = 0x12345678;
    const pixels = try std.testing.allocator.alloc(u32, stride * height + 2);
    defer std.testing.allocator.free(pixels);
    @memset(pixels, sentinel);
    var surface = try axisui.Surface.init(pixels[1 .. pixels.len - 1], width, height, stride, .{ .red = 0xff0000, .green = 0xff00, .blue = 0xff });
    var scratch: axisui.Workspace = undefined;
    try renderBarWithWorkspace(&surface, &scratch, "x86_64");
    try std.testing.expectEqual(sentinel, pixels[0]);
    try std.testing.expectEqual(sentinel, pixels[pixels.len - 1]);
    for (0..height) |y| for (0..stride) |x| {
        if (y >= bar_height or x >= width) try std.testing.expectEqual(sentinel, pixels[1 + y * stride + x]);
    };
    try std.testing.expectEqual(surface.encode(palette.bar), pixels[1 + 12 * stride + 400]);
}

test "procedural wallpaper emits bounded row spans on command and tiny surfaces" {
    const std = @import("std");
    const Sink = struct {
        rows: [32]u8 = @splat(0),
        pixels: [64 * 32]u32 = @splat(0),
        valid: bool = true,
        fn fill(ctx: *anyopaque, x: u32, y: u32, width: u32, height: u32, pixel: u32) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (y >= 32 or x >= 64 or width == 0 or width > 64 - x or height != 1) {
                self.valid = false;
                return;
            }
            self.rows[y] += 1;
            for (x..x + width) |column| self.pixels[@as(usize, y) * 64 + column] = pixel;
        }
    };
    var sink = Sink{};
    var command_surface = try axisui.Surface.initCommands(64, 32, .{ .context = &sink, .fillRect = &Sink.fill });
    try renderWallpaper(&command_surface);
    try std.testing.expect(sink.valid);
    for (sink.rows) |count| try std.testing.expect(count > 0 and count <= wallpaper.max_fills_per_row);
    var native_pixels: [64 * 32]u32 = undefined;
    var native = try axisui.Surface.init(&native_pixels, 64, 32, 64, .{ .red = 0xff0000, .green = 0xff00, .blue = 0xff });
    try renderWallpaper(&native);
    try std.testing.expectEqualSlices(u32, &native_pixels, &sink.pixels);
    var tiny = [_]u32{ 0x12345678, 0, 0x12345678 };
    var surface = try axisui.Surface.init(tiny[1..2], 1, 1, 1, .{ .red = 0xff0000, .green = 0xff00, .blue = 0xff });
    try renderWallpaper(&surface);
    try std.testing.expectEqual(@as(u32, 0x12345678), tiny[0]);
    try std.testing.expectEqual(@as(u32, 0x12345678), tiny[2]);
    surface.width = 2;
    const original = tiny[1];
    try std.testing.expectError(error.InvalidSurface, renderWallpaper(&surface));
    try std.testing.expectEqual(original, tiny[1]);
}

test "bar samples genuine immutable wallpaper backdrop with guarded cache storage" {
    const std = @import("std");
    const width = 800;
    const height = 80;
    const pixels = try std.testing.allocator.alloc(u32, width * height);
    defer std.testing.allocator.free(pixels);
    var surface = try axisui.Surface.init(pixels, width, height, width, .{ .red = 0xff0000, .green = 0xff00, .blue = 0xff });
    try renderWallpaper(&surface);
    const below_bar = pixels[60 * width + 300];
    const required = try axisui.Backdrop.requiredLen(width, height);
    const colors = try std.testing.allocator.alloc(u32, required + 2);
    defer std.testing.allocator.free(colors);
    const blur_scratch = try std.testing.allocator.alloc(u32, required + 2);
    defer std.testing.allocator.free(blur_scratch);
    const sentinel: u32 = 0xa5b6c7d8;
    @memset(colors, sentinel);
    @memset(blur_scratch, sentinel);
    var backdrop = try axisui.Backdrop.build(&surface, colors[1 .. required + 1], blur_scratch[1 .. required + 1]);
    try surface.setBackdrop(&backdrop, .{ .x = 0, .y = 0 });
    var workspace: axisui.Workspace = undefined;
    try renderBarWithWorkspace(&surface, &workspace, "ARM64");
    const left = pixels[7 * width + 250];
    const right = pixels[7 * width + 650];
    try std.testing.expect(left != right);
    try std.testing.expect(left != surface.encode(palette.bar));
    try std.testing.expect(right != surface.encode(palette.bar));
    try std.testing.expectEqual(below_bar, pixels[60 * width + 300]);
    try std.testing.expectEqual(sentinel, colors[0]);
    try std.testing.expectEqual(sentinel, colors[required + 1]);
    try std.testing.expectEqual(sentinel, blur_scratch[0]);
    try std.testing.expectEqual(sentinel, blur_scratch[required + 1]);
}
