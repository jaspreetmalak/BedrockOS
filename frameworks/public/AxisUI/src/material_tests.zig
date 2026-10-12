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
    var commands = try ui.Surface.initCommands(16, 16, .{ .context = &receiver, .fillRect = Receiver.fill, .materialRect = Receiver.material });
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
