const std = @import("std");
const ui = @import("root.zig");
const masks: ui.PixelMasks = .{ .red = 0xff0000, .green = 0xff00, .blue = 0xff };

test "backdrop performs actual horizontal and vertical blur without modifying source" {
    var source_pixels: [64 * 64]u32 = @splat(0);
    for (32..64) |y| for (32..64) |x| {
        source_pixels[y * 64 + x] = 0xffffff;
    };
    const original = source_pixels;
    const source = try ui.Surface.init(&source_pixels, 64, 64, 64, masks);
    var colors: [64]u32 = undefined;
    var scratch: [64]u32 = undefined;
    const backdrop = try ui.Backdrop.build(&source, &colors, &scratch);
    try std.testing.expectEqual(@as(usize, 18), try ui.Backdrop.requiredLen(71, 13));
    try std.testing.expectEqual(@as(u32, 0x535353), colors[4 * 8 + 4]);
    try std.testing.expectEqualDeep(ui.Color.rgb(0, 0, 0), backdrop.sample(-100, -100));
    try std.testing.expectEqualDeep(ui.Color.rgb(255, 255, 255), backdrop.sample(100, 100));
    const before = backdrop.sample(31, 32);
    const after = backdrop.sample(32, 32);
    try std.testing.expect(before.r > 0 and after.r < 255 and after.r > before.r and after.r - before.r < 10);
    try std.testing.expectEqualSlices(u32, &original, &source_pixels);
}

test "backdrop decode honors BGR reduced and scattered masks and preserves uniform color" {
    var pixels: [9 * 11]u32 = @splat(0xaa332211);
    var source = try ui.Surface.init(&pixels, 9, 11, 9, .{ .red = 0xff, .green = 0xff00, .blue = 0xff0000, .reserved = 0xff000000 });
    var colors: [4]u32 = undefined;
    var scratch: [4]u32 = undefined;
    var backdrop = try ui.Backdrop.build(&source, &colors, &scratch);
    for (colors) |value| try std.testing.expectEqual(@as(u32, 0x112233), value);
    try std.testing.expectEqualDeep(ui.Color.rgb(17, 34, 51), backdrop.sample(4, 5));
    source.masks = .{ .red = 0xf800, .green = 0x7e0, .blue = 0x1f };
    @memset(&pixels, 0xf800);
    backdrop = try ui.Backdrop.build(&source, &colors, &scratch);
    try std.testing.expectEqualDeep(ui.Color.rgb(255, 0, 0), backdrop.sample(8, 10));
    source.masks = .{ .red = 0b10001, .green = 0b100010, .blue = 0b1000100 };
    @memset(&pixels, 0b10000 | 0b10 | 0b1000100);
    backdrop = try ui.Backdrop.build(&source, &colors, &scratch);
    try std.testing.expectEqualDeep(ui.Color.rgb(170, 85, 255), backdrop.sample(0, 0));
}

test "backdrop validation rejects undersized overlapping and malformed storage before writes" {
    var pixels: [16 * 16]u32 align(@alignOf(ui.Backdrop)) = @splat(0x123456);
    var source = try ui.Surface.init(&pixels, 16, 16, 16, masks);
    var colors: [4]u32 = @splat(0x87654321);
    var scratch: [4]u32 = @splat(0xabcdef01);
    try std.testing.expectError(error.InvalidBackdropStorage, ui.Backdrop.build(&source, colors[0..3], &scratch));
    try std.testing.expectError(error.AliasedBackdrop, ui.Backdrop.build(&source, &colors, &colors));
    try std.testing.expectError(error.AliasedBackdrop, ui.Backdrop.build(&source, pixels[0..4], &scratch));
    try std.testing.expectError(error.AliasedBackdrop, ui.Backdrop.build(&source, &colors, pixels[0..4]));
    const metadata_storage: [*]u32 = @ptrCast(&source);
    try std.testing.expectError(error.AliasedBackdrop, ui.Backdrop.build(&source, metadata_storage[0..4], &scratch));
    const embedded: *const ui.Backdrop = @ptrCast(@alignCast(pixels[0..].ptr));
    // Reject descriptor feedback before reading its deliberately invalid fields.
    try std.testing.expectError(error.AliasedBackdrop, source.setBackdrop(embedded, .{ .x = 0, .y = 0 }));
    for (colors) |value| try std.testing.expectEqual(@as(u32, 0x87654321), value);
    for (scratch) |value| try std.testing.expectEqual(@as(u32, 0xabcdef01), value);
    for (pixels) |value| try std.testing.expectEqual(@as(u32, 0x123456), value);
    var bad: ui.Backdrop = .{ .colors = &colors, .width = 16, .height = 16, .stride = 1 };
    try std.testing.expectError(error.InvalidBackdrop, source.setBackdrop(&bad, .{ .x = 4, .y = 5 }));
    try std.testing.expect(source.backdrop == null and source.backdrop_origin.x == 0);
    bad = .{ .colors = &colors, .width = 17, .height = 16, .stride = 3 };
    try std.testing.expectError(error.InvalidBackdrop, source.setBackdrop(&bad, .{ .x = 0, .y = 0 }));
    bad = .{ .colors = pixels[0..4], .width = 16, .height = 16, .stride = 2 };
    try std.testing.expectError(error.AliasedBackdrop, source.setBackdrop(&bad, .{ .x = 0, .y = 0 }));
    try std.testing.expectError(error.InvalidBackdrop, ui.Backdrop.requiredLen(0, 16));
    try std.testing.expectError(error.InvalidBackdrop, ui.Backdrop.requiredLen(16385, 16));
}

test "material opacity endpoints frozen redraw origin and missing-backdrop fallback are exact" {
    const backdrop_colors = [_]u32{ 0x123456, 0xabcdef };
    const backdrop: ui.Backdrop = .{ .colors = &backdrop_colors, .width = 16, .height = 8, .stride = 2 };
    var pixels: [8 * 8]u32 = @splat(0);
    var surface = try ui.Surface.init(&pixels, 8, 8, 8, masks);
    try surface.setBackdrop(&backdrop, .{ .x = 8, .y = 0 });
    const tint = ui.Color.rgb(20, 30, 40);
    surface.materialRect(0, 0, 8, 8, .{ .tint = tint, .opacity = 0 });
    try std.testing.expectEqual(surface.encode(backdrop.sample(8, 0)), pixels[0]);
    surface.materialRect(0, 0, 8, 8, .{ .tint = tint, .opacity = 255 });
    for (pixels) |pixel| try std.testing.expectEqual(@as(u32, 0x141e28), pixel);
    const material: ui.Material = .{ .tint = tint, .opacity = 170 };
    surface.materialRect(0, 0, 8, 8, material);
    const first = pixels;
    @memset(&pixels, 0xffffff);
    surface.materialRect(0, 0, 8, 8, material);
    try std.testing.expectEqualSlices(u32, &first, &pixels);
    try std.testing.expectEqual(@as(u32, 0x626970), surface.encode(ui.materials.blend(ui.Color.rgb(255, 255, 255), material)));
    try surface.setBackdrop(null, .{ .x = 0, .y = 0 });
    surface.materialRect(0, 0, 8, 8, .{ .tint = tint, .opacity = 0 });
    for (pixels) |pixel| try std.testing.expectEqual(@as(u32, 0x141e28), pixel);
}

test "material rounded ancestor clipping preserves scanline padding and rejects ambiguous styles" {
    const sentinel: u32 = 0x51abf00d;
    var pixels: [2 + 20 * 16]u32 = @splat(sentinel);
    var surface = try ui.Surface.init(pixels[1 .. pixels.len - 1], 16, 16, 20, masks);
    const colors: [4]u32 = @splat(0x406080);
    const backdrop: ui.Backdrop = .{ .colors = &colors, .width = 16, .height = 16, .stride = 2 };
    try surface.setBackdrop(&backdrop, .{ .x = 0, .y = 0 });
    var workspace: ui.Workspace = undefined;
    const material: ui.Material = .{ .tint = ui.Color.rgb(10, 20, 30), .opacity = 128 };
    const children = [_]ui.View{ui.Spacer().frame(100, 100).material(material)};
    try ui.renderWithWorkspace(&surface, &workspace, ui.ZStack(&children).padding(2).cornerRadius(5));
    try std.testing.expectEqual(sentinel, pixels[0]);
    try std.testing.expectEqual(sentinel, pixels[pixels.len - 1]);
    try std.testing.expectEqual(sentinel, pixels[1]);
    try std.testing.expect(pixels[1 + 8 * 20 + 8] != sentinel);
    for (0..16) |y| for (16..20) |x| try std.testing.expectEqual(sentinel, pixels[1 + y * 20 + x]);
    var invalid = ui.Spacer().background(ui.Color.rgb(255, 0, 0));
    invalid.style.background_material = material;
    const before = pixels;
    try std.testing.expectError(error.InvalidMaterial, ui.renderWithWorkspace(&surface, &workspace, invalid));
    try std.testing.expectEqualSlices(u32, &before, &pixels);
    try std.testing.expect(ui.Spacer().material(material).background(ui.Color.rgb(0, 0, 0)).style.background_material == null);
}

test "material command callback matches clipped pixel backdrop and fallback stays solid" {
    const Receiver = struct {
        surface: *ui.Surface,
        material_calls: usize = 0,
        fill_calls: usize = 0,
        invalid: bool = false,
        fn fill(context: *anyopaque, x: u32, y: u32, w: u32, h: u32, value: u32) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.fill_calls += 1;
            self.surface.fillRect(x, y, w, h, value);
        }
        fn material(context: *anyopaque, x: u32, y: u32, w: u32, h: u32, value: ui.Material) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.material_calls += 1;
            if (w == 0 or h == 0 or x >= self.surface.width or y >= self.surface.height or
                w > self.surface.width - x or h > self.surface.height - y) self.invalid = true;
            self.surface.materialRect(x, y, w, h, value);
        }
        fn blend(context: *anyopaque, x: u32, y: u32, value: u32, alpha: u8) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.surface.blendPixel(x, y, self.surface.decode(value), alpha);
        }
    };
    const colors = [_]u32{ 0x002040, 0x406080, 0x80a0c0, 0xc0e0ff };
    const backdrop: ui.Backdrop = .{ .colors = &colors, .width = 16, .height = 16, .stride = 2 };
    var direct: [16 * 16]u32 = @splat(0x111111);
    var submitted = direct;
    var native = try ui.Surface.init(&direct, 16, 16, 16, masks);
    var received = try ui.Surface.init(&submitted, 16, 16, 16, masks);
    try native.setBackdrop(&backdrop, .{ .x = 2, .y = -3 });
    try received.setBackdrop(&backdrop, .{ .x = 2, .y = -3 });
    var receiver: Receiver = .{ .surface = &received };
    var commands = try ui.Surface.initCommands(16, 16, .{ .context = &receiver, .fillRect = Receiver.fill, .materialRect = Receiver.material, .blendPixel = Receiver.blend });
    var workspace: ui.Workspace = undefined;
    const children = [_]ui.View{ui.Text("a").material(.{ .tint = ui.Color.rgb(10, 20, 30), .opacity = 170 }).frame(30, 30).cornerRadius(5)};
    const view = ui.ZStack(&children).padding(2).cornerRadius(6);
    try ui.renderWithWorkspace(&native, &workspace, view);
    try ui.renderWithWorkspace(&commands, &workspace, view);
    try std.testing.expectEqualSlices(u32, &direct, &submitted);
    try std.testing.expect(receiver.material_calls > 0 and receiver.material_calls <= 16 and !receiver.invalid);
    commands.commands.?.materialRect = null;
    receiver.material_calls = 0;
    try ui.renderWithWorkspace(&commands, &workspace, ui.Spacer().material(.{ .tint = ui.Color.rgb(7, 8, 9), .opacity = 0 }));
    for (submitted) |pixel| try std.testing.expectEqual(@as(u32, 0x070809), pixel);
    try std.testing.expectEqual(@as(usize, 0), receiver.material_calls);
    var output: [4]u32 = @splat(0x12345678);
    var scratch: [4]u32 = undefined;
    try std.testing.expectError(error.BackdropUnavailable, ui.Backdrop.build(&commands, &output, &scratch));
    for (output) |value| try std.testing.expectEqual(@as(u32, 0x12345678), value);
}

test "rounded coverage is symmetric half-open radius-clamped and defined for extreme geometry" {
    const coverage = ui.materials.roundedCoverage;
    try std.testing.expectEqual(@as(u8, 0), coverage(0, 20, 8, 0, 0));
    try std.testing.expectEqual(@as(u8, 0), coverage(20, 20, 8, -1, 10));
    try std.testing.expectEqual(@as(u8, 0), coverage(20, 20, 8, 20, 10));
    try std.testing.expectEqual(@as(u8, 255), coverage(20, 20, 0, 0, 0));
    try std.testing.expectEqual(@as(u8, 0), coverage(20, 20, 8, 0, 0));
    try std.testing.expectEqual(@as(u8, 255), coverage(20, 20, 8, 10, 0));
    var partial: usize = 0;
    for (0..13) |y| for (0..17) |x| {
        const alpha = coverage(17, 13, 6, @intCast(x), @intCast(y));
        try std.testing.expectEqual(alpha, coverage(17, 13, 6, @intCast(16 - x), @intCast(y)));
        try std.testing.expectEqual(alpha, coverage(17, 13, 6, @intCast(x), @intCast(12 - y)));
        try std.testing.expectEqual(alpha, coverage(17, 13, std.math.maxInt(u32), @intCast(x), @intCast(y)));
        try std.testing.expectEqual(alpha >= 128, ui.materials.roundedContains(17, 13, 6, @intCast(x), @intCast(y)));
        partial += @intFromBool(alpha != 0 and alpha != 255);
    };
    try std.testing.expect(partial >= 8);
    const huge = std.math.maxInt(u32);
    try std.testing.expectEqual(@as(u8, 0), coverage(huge, huge, huge, 0, 0));
    try std.testing.expectEqual(@as(u8, 255), coverage(huge, huge, huge, huge / 2, 0));
    try std.testing.expectEqual(@as(u8, 0), coverage(huge, huge, huge, std.math.maxInt(i64), 0));
}

test "signed antialiased solid and glass primitives preserve padding and command parity" {
    const Receiver = struct {
        surface: *ui.Surface,
        invalid: bool = false,
        partial_materials: usize = 0,
        fn fill(context: *anyopaque, x: u32, y: u32, w: u32, h: u32, value: u32) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (x >= self.surface.width or y >= self.surface.height or w == 0 or h == 0 or w > self.surface.width - x or h > self.surface.height - y) self.invalid = true;
            self.surface.fillRect(x, y, w, h, value);
        }
        fn blend(context: *anyopaque, x: u32, y: u32, value: u32, alpha: u8) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (x >= self.surface.width or y >= self.surface.height) self.invalid = true;
            self.surface.blendPixel(x, y, self.surface.decode(value), alpha);
        }
        fn material(context: *anyopaque, x: u32, y: u32, w: u32, h: u32, value: ui.Material) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (x >= self.surface.width or y >= self.surface.height or w == 0 or h == 0 or w > self.surface.width - x or h > self.surface.height - y) self.invalid = true;
            self.surface.materialRect(x, y, w, h, value);
        }
        fn materialPixel(context: *anyopaque, x: u32, y: u32, value: ui.Material, alpha: u8) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.partial_materials += 1;
            if (x >= self.surface.width or y >= self.surface.height or alpha == 0 or alpha == 255) self.invalid = true;
            self.surface.materialPixel(x, y, value, alpha);
        }
    };
    const guard: u32 = 0x51abf00d;
    var pixels: [2 + 23 * 19]u32 = @splat(guard);
    var submitted = pixels;
    var native = try ui.Surface.init(pixels[1 .. pixels.len - 1], 19, 19, 23, masks);
    var received = try ui.Surface.init(submitted[1 .. submitted.len - 1], 19, 19, 23, masks);
    const colors = [_]u32{ 0x204060, 0x406080, 0x6080a0, 0x80a0c0, 0xa0c0e0, 0xc0e0ff, 0x406080, 0x6080a0, 0x80a0c0 };
    const backdrop: ui.Backdrop = .{ .colors = &colors, .width = 19, .height = 19, .stride = 3 };
    try native.setBackdrop(&backdrop, .{ .x = -2, .y = 3 });
    try received.setBackdrop(&backdrop, .{ .x = -2, .y = 3 });
    var receiver: Receiver = .{ .surface = &received };
    var commands = try ui.Surface.initCommands(19, 19, .{ .context = &receiver, .fillRect = Receiver.fill, .blendPixel = Receiver.blend, .materialRect = Receiver.material, .materialPixel = Receiver.materialPixel });
    for (&[_]*ui.Surface{ &native, &commands }) |surface| {
        surface.roundedRect(-5, 3, 19, 13, 6, ui.Color.rgb(30, 60, 90));
        surface.roundedMaterialRect(4, -3, 19, 21, 8, ui.materials.glass.sidebar);
        surface.roundedBorder(4, -3, 19, 21, 8, ui.materials.glass.edge, 1, ui.materials.glass.edge_opacity);
        const before = if (surface.commands == null) pixels else submitted;
        surface.roundedRect(std.math.minInt(i32), std.math.minInt(i32), 1, 1, 1, ui.Color.rgb(255, 0, 0));
        surface.roundedMaterialRect(std.math.maxInt(i32), 0, std.math.maxInt(u32), 20, 5, ui.materials.glass.window);
        try std.testing.expectEqualSlices(u32, &before, if (surface.commands == null) &pixels else &submitted);
    }
    try std.testing.expectEqualSlices(u32, &pixels, &submitted);
    try std.testing.expect(!receiver.invalid and receiver.partial_materials > 0);
    try std.testing.expectEqual(guard, pixels[0]);
    try std.testing.expectEqual(guard, pixels[pixels.len - 1]);
    for (0..19) |y| for (19..23) |x| try std.testing.expectEqual(guard, pixels[1 + y * 23 + x]);
    native.fillRect(0, 0, 19, 19, 0x102030);
    received.fillRect(0, 0, 19, 19, 0x102030);
    var workspace: ui.Workspace = undefined;
    const children = [_]ui.View{ui.Text("Glass").frame(32, 32).material(ui.materials.glass.control).cornerRadius(9).smoothCorners()};
    const view = ui.ZStack(&children).padding(1).cornerRadius(8).smoothCorners().border(ui.Color.rgb(80, 90, 110), 1);
    try ui.renderWithWorkspace(&native, &workspace, view);
    try ui.renderWithWorkspace(&commands, &workspace, view);
    try std.testing.expectEqualSlices(u32, &pixels, &submitted);
    try std.testing.expect(!receiver.invalid);
    try std.testing.expectEqual(@as(u32, 0x102030), pixels[1]);
    // Old receivers can still paint; an absent covered-material callback uses
    // the tint and blend callback instead of reading an unauthorized backdrop.
    commands.commands.?.materialPixel = null;
    @memset(submitted[1 .. submitted.len - 1], 0);
    commands.materialPixel(0, 0, .{ .tint = ui.Color.rgb(200, 100, 50), .opacity = 0 }, 128);
    try std.testing.expectEqual(@as(u32, 0x643219), submitted[1]);
}

test "smooth declarative glass has shared geometry and frozen blur does not accumulate" {
    var source_pixels: [24 * 24]u32 = undefined;
    for (0..24) |y| for (0..24) |x| {
        source_pixels[y * 24 + x] = if (x < 12) 0x203050 else 0x80a0c0;
    };
    const original = source_pixels;
    const source = try ui.Surface.init(&source_pixels, 24, 24, 24, masks);
    var colors: [9]u32 = undefined;
    var scratch: [9]u32 = undefined;
    const backdrop = try ui.Backdrop.build(&source, &colors, &scratch);
    const first_cache = colors;
    var pixels: [24 * 24]u32 = @splat(0x102030);
    var primitive_pixels = pixels;
    var surface = try ui.Surface.init(&pixels, 24, 24, 24, masks);
    var primitive = try ui.Surface.init(&primitive_pixels, 24, 24, 24, masks);
    try surface.setBackdrop(&backdrop, .{ .x = 0, .y = 0 });
    try primitive.setBackdrop(&backdrop, .{ .x = 0, .y = 0 });
    var workspace: ui.Workspace = undefined;
    const view = ui.Spacer().material(ui.materials.glass.window).cornerRadius(8).smoothCorners();
    try ui.renderWithWorkspace(&surface, &workspace, view);
    primitive.roundedMaterialRect(0, 0, 24, 24, 8, ui.materials.glass.window);
    try std.testing.expectEqualSlices(u32, &pixels, &primitive_pixels);
    try std.testing.expectEqual(@as(u32, 0x102030), pixels[0]);
    const first_frame = pixels;
    for (0..3) |_| {
        _ = try ui.Backdrop.build(&source, &colors, &scratch);
        @memset(&pixels, 0x102030); // The caller repaints the base before overlays.
        try ui.renderWithWorkspace(&surface, &workspace, view);
        try std.testing.expectEqualSlices(u32, &first_frame, &pixels);
        try std.testing.expectEqualSlices(u32, &first_cache, &colors);
    }
    try std.testing.expectEqualSlices(u32, &original, &source_pixels);
    const children = [_]ui.View{ui.Spacer().frame(60, 60).background(ui.Color.rgb(255, 255, 255))};
    @memset(&pixels, 0);
    try ui.renderWithWorkspace(&surface, &workspace, ui.ZStack(&children).cornerRadius(8).smoothCorners());
    for (0..24) |y| for (0..24) |x| {
        const alpha: u32 = ui.materials.roundedCoverage(24, 24, 8, @intCast(x), @intCast(y));
        try std.testing.expectEqual(alpha * 0x010101, pixels[y * 24 + x]);
    };
}

test "rounded border interior skipping matches full pixel reference for signed and degenerate geometry" {
    const Case = struct { x: i32, y: i32, w: u32, h: u32, r: u32, thickness: u32, opacity: u8 = 137 };
    const cases = [_]Case{
        .{ .x = 3, .y = 4, .w = 21, .h = 17, .r = 6, .thickness = 1, .opacity = 42 },
        .{ .x = -9, .y = -5, .w = 36, .h = 29, .r = 12, .thickness = 2, .opacity = 220 },
        .{ .x = 25, .y = 22, .w = 18, .h = 20, .r = 100, .thickness = 1, .opacity = 255 },
        .{ .x = 0, .y = 0, .w = 31, .h = 27, .r = 0, .thickness = 1 },
        .{ .x = 1, .y = 2, .w = 1, .h = 1, .r = 99, .thickness = 1 },
        .{ .x = 2, .y = 3, .w = 3, .h = 7, .r = 3, .thickness = 1 },
        .{ .x = 3, .y = 4, .w = 21, .h = 17, .r = 3, .thickness = 9 },
        .{ .x = -5, .y = 0, .w = 40, .h = 11, .r = 90, .thickness = 40 },
        .{ .x = 3, .y = 4, .w = 0, .h = 17, .r = 6, .thickness = 1 },
        .{ .x = 3, .y = 4, .w = 21, .h = 0, .r = 6, .thickness = 1 },
        .{ .x = -3, .y = 4, .w = 40, .h = 19, .r = 8, .thickness = 0 },
        .{ .x = -3, .y = 4, .w = 40, .h = 19, .r = 8, .thickness = std.math.maxInt(u32) },
        .{ .x = 3, .y = -4, .w = 21, .h = 33, .r = 6, .thickness = 1, .opacity = 0 },
        .{ .x = std.math.minInt(i32), .y = std.math.minInt(i32), .w = std.math.maxInt(u32), .h = std.math.maxInt(u32), .r = std.math.maxInt(u32), .thickness = 1 },
        .{ .x = std.math.minInt(i32), .y = 3, .w = std.math.maxInt(u32), .h = 17, .r = std.math.maxInt(u32), .thickness = 1 },
        .{ .x = std.math.maxInt(i32), .y = 3, .w = std.math.maxInt(u32), .h = 17, .r = std.math.maxInt(u32), .thickness = 1 },
        .{ .x = -9, .y = -12, .w = 5, .h = 5, .r = 8, .thickness = 2 },
    };
    const guard: u32 = 0x51abf00d;
    const color = ui.Color.rgb(188, 207, 231);
    for (cases) |rect| {
        var pixels: [2 + 37 * 27]u32 = @splat(guard);
        for (0..27) |row| for (0..31) |column| {
            pixels[1 + row * 37 + column] = @as(u32, @intCast(column * 5)) << 16 | @as(u32, @intCast(row * 7)) << 8 | @as(u32, @intCast((row + column) * 3));
        };
        var reference_pixels = pixels;
        var surface = try ui.Surface.init(pixels[1 .. pixels.len - 1], 31, 27, 37, masks);
        var reference = try ui.Surface.init(reference_pixels[1 .. reference_pixels.len - 1], 31, 27, 37, masks);
        surface.roundedBorder(rect.x, rect.y, rect.w, rect.h, rect.r, color, rect.thickness, rect.opacity);
        const outer_radius = @min(rect.r, @min(rect.w, rect.h) / 2);
        const inner_w: u32 = @intCast(rect.w - @min(rect.w, @as(u64, rect.thickness) * 2));
        const inner_h: u32 = @intCast(rect.h - @min(rect.h, @as(u64, rect.thickness) * 2));
        const inner_x = @as(i64, rect.x) + @min(rect.thickness, rect.w / 2);
        const inner_y = @as(i64, rect.y) + @min(rect.thickness, rect.h / 2);
        // Independent reference scans every destination pixel. It does not use
        // the optimized skip spans or the roundedBorder implementation.
        for (0..27) |row| for (0..31) |column| {
            const px: i64 = @intCast(column);
            const py: i64 = @intCast(row);
            const outer = ui.materials.roundedCoverage(rect.w, rect.h, outer_radius, px - rect.x, py - rect.y);
            const inner = ui.materials.roundedCoverage(inner_w, inner_h, outer_radius -| rect.thickness, px - inner_x, py - inner_y);
            const alpha: u8 = @intCast((@as(u32, outer -| inner) * rect.opacity + 127) / 255);
            reference.blendPixel(@intCast(column), @intCast(row), color, alpha);
        };
        try std.testing.expectEqualSlices(u32, &reference_pixels, &pixels);
        try std.testing.expectEqual(guard, pixels[0]);
        try std.testing.expectEqual(guard, pixels[pixels.len - 1]);
        for (0..27) |row| for (31..37) |column| try std.testing.expectEqual(guard, pixels[1 + row * 37 + column]);
    }
}

test "bulk rounded ancestor interiors preserve nested fill and border pixel coverage" {
    const Case = struct { parent_radius: u16, inset: u16, child_w: u16, child_h: u16, child_radius: u16, border: u8 };
    const cases = [_]Case{
        .{ .parent_radius = 0, .inset = 0, .child_w = 60, .child_h = 60, .child_radius = 0, .border = 1 },
        .{ .parent_radius = 13, .inset = 0, .child_w = 60, .child_h = 60, .child_radius = 9, .border = 1 },
        .{ .parent_radius = 13, .inset = 2, .child_w = 60, .child_h = 60, .child_radius = 20, .border = 2 },
        .{ .parent_radius = 4, .inset = 3, .child_w = 18, .child_h = 20, .child_radius = 9, .border = 4 },
        .{ .parent_radius = 13, .inset = 10, .child_w = 8, .child_h = 6, .child_radius = 0, .border = 1 },
        .{ .parent_radius = 13, .inset = 10, .child_w = 4, .child_h = 3, .child_radius = 40, .border = 8 },
    };
    const guard: u32 = 0x51abf00d;
    const base: u32 = 0x162638;
    const background = ui.Color.rgb(49, 65, 83);
    const edge = ui.Color.rgb(181, 195, 214);
    var workspace: ui.Workspace = undefined;
    for (cases) |item| {
        var pixels: [2 + 41 * 29]u32 = @splat(guard);
        for (0..29) |row| @memset(pixels[1 + row * 41 .. 1 + row * 41 + 37], base);
        var reference_pixels = pixels;
        var surface = try ui.Surface.init(pixels[1 .. pixels.len - 1], 37, 29, 41, masks);
        var reference = try ui.Surface.init(reference_pixels[1 .. reference_pixels.len - 1], 37, 29, 41, masks);
        const children = [_]ui.View{ui.Spacer().frame(item.child_w, item.child_h).material(.{ .tint = background, .opacity = 0 }).cornerRadius(item.child_radius).smoothCorners().border(edge, item.border)};
        try ui.renderWithWorkspace(&surface, &workspace, ui.ZStack(&children).padding(item.inset).cornerRadius(item.parent_radius).smoothCorners());
        const child_radius = @min(item.child_radius, @min(item.child_w, item.child_h) / 2);
        const inner_w: u32 = item.child_w - @min(@as(u32, item.child_w), @as(u32, item.border) * 2);
        const inner_h: u32 = item.child_h - @min(@as(u32, item.child_h), @as(u32, item.border) * 2);
        const inner_x: i64 = item.inset + @min(@as(u32, item.border), item.child_w / 2);
        const inner_y: i64 = item.inset + @min(@as(u32, item.border), item.child_h / 2);
        for (0..29) |row| for (0..37) |column| {
            const x: i64 = @intCast(column);
            const y: i64 = @intCast(row);
            if (x < item.inset or y < item.inset or x >= 37 - item.inset or y >= 29 - item.inset) continue;
            const parent_alpha = ui.materials.roundedCoverage(37, 29, item.parent_radius, x, y);
            const child_alpha = ui.materials.roundedCoverage(item.child_w, item.child_h, child_radius, x - item.inset, y - item.inset);
            const alpha = @min(parent_alpha, child_alpha);
            reference.blendPixel(@intCast(column), @intCast(row), background, alpha);
            const inner_alpha = ui.materials.roundedCoverage(inner_w, inner_h, child_radius -| item.border, x - inner_x, y - inner_y);
            reference.blendPixel(@intCast(column), @intCast(row), edge, @min(alpha, child_alpha -| inner_alpha));
        };
        try std.testing.expectEqualSlices(u32, &reference_pixels, &pixels);
    }
    const Receiver = struct {
        material_calls: usize = 0,
        fill_calls: usize = 0,
        invalid: bool = false,
        fn fill(context: *anyopaque, _: u32, _: u32, _: u32, _: u32, _: u32) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.fill_calls += 1;
        }
        fn material(context: *anyopaque, x: u32, y: u32, w: u32, h: u32, _: ui.Material) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.material_calls += 1;
            if (x != 10 or y != 10 or w != 8 or h != 6) self.invalid = true;
        }
    };
    var receiver: Receiver = .{};
    var commands = try ui.Surface.initCommands(37, 29, .{ .context = &receiver, .fillRect = Receiver.fill, .materialRect = Receiver.material });
    const children = [_]ui.View{ui.Spacer().frame(8, 6).material(ui.materials.glass.window)};
    try ui.renderWithWorkspace(&commands, &workspace, ui.ZStack(&children).padding(10).cornerRadius(13).smoothCorners());
    try std.testing.expectEqual(@as(usize, 1), receiver.material_calls);
    try std.testing.expectEqual(@as(usize, 0), receiver.fill_calls);
    try std.testing.expect(!receiver.invalid);
}
