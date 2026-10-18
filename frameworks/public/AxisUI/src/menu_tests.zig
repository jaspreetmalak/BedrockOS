const std = @import("std");
const menu = @import("menu.zig");
const input = @import("input.zig");
const Surface = @import("surface.zig").Surface;
const Color = @import("types.zig").Color;

const file_items = [_]menu.Item{
    .{ .command = 1, .label = "Open", .shortcut = "Ctrl+O" },
    menu.Item.divider(),
    .{ .command = 2, .label = "Unavailable", .enabled = false },
    .{ .command = 3, .label = "Show hidden files", .checked = true },
};
const edit_items = [_]menu.Item{
    .{ .command = 4, .label = "Copy", .shortcut = "Ctrl+C" },
    .{ .command = 5, .label = "Paste", .shortcut = "Ctrl+V" },
};
const groups = [_]menu.Group{
    .{ .label = "File", .items = &file_items },
    .{ .label = "Edit", .items = &edit_items },
};
fn layout(width: u32, height: u32) !menu.Layout {
    return menu.Layout.init(.{ .groups = &groups }, .{ .x = 0, .y = 32, .width = width, .height = menu.bar_height }, .{ .x = 0, .y = 0, .width = width, .height = height });
}
fn pointer(kind: input.Kind, rect: input.Rect) input.Event {
    return .{ .kind = kind, .code = @backingInt(input.Button.left), .x = @intCast(rect.x + 10), .y = @intCast(rect.y + 10) };
}
fn key(code: input.Key) input.Event {
    return .{ .kind = .key_down, .code = @backingInt(code) };
}

test "menus validate bounded printable definitions without granting command authority" {
    _ = try menu.Model.init(&groups);
    const duplicate = [_]menu.Item{ .{ .command = 1, .label = "A" }, .{ .command = 1, .label = "B" } };
    const duplicate_group = [_]menu.Group{.{ .label = "File", .items = &duplicate }};
    try std.testing.expectError(error.InvalidMenu, menu.Model.init(&duplicate_group));
    const bad = [_]menu.Item{.{ .command = 0, .label = "Open" }};
    const bad_group = [_]menu.Group{.{ .label = "File", .items = &bad }};
    try std.testing.expectError(error.InvalidMenu, menu.Model.init(&bad_group));
    const lines = [_]menu.Group{.{ .label = "File\nEdit", .items = &file_items }};
    try std.testing.expectError(error.InvalidMenu, menu.Model.init(&lines));
    const malformed_divider = [_]menu.Item{.{ .command = 10, .separator = true }};
    const divider_group = [_]menu.Group{.{ .label = "File", .items = &malformed_divider }};
    try std.testing.expectError(error.InvalidMenu, menu.Model.init(&divider_group));
    var too_many: [menu.max_groups + 1]menu.Group = undefined;
    for (&too_many) |*group| group.* = groups[0];
    try std.testing.expectError(error.InvalidMenu, menu.Model.init(&too_many));
}

test "menu commands require matched press release and disabled rows never invoke" {
    const geometry = try layout(316, 236);
    var state: menu.State = .{};
    const group_rect = geometry.groupRect(0).?;
    const opening = state.handle(geometry, pointer(.pointer_down, group_rect));
    try std.testing.expect(opening.consumed and opening.changed);
    try std.testing.expect(state.handle(geometry, pointer(.pointer_up, group_rect)).command == null);
    const first = geometry.rowRect(&state, 0).?;
    try std.testing.expect(state.handle(geometry, pointer(.pointer_up, first)).command == null);
    _ = state.handle(geometry, pointer(.pointer_down, first));
    const elsewhere = geometry.rowRect(&state, 3).?;
    try std.testing.expect(state.handle(geometry, pointer(.pointer_up, elsewhere)).command == null);
    try std.testing.expect(state.open_group == null);
    try std.testing.expect(state.open(geometry, 0));
    const disabled = geometry.rowRect(&state, 2).?;
    _ = state.handle(geometry, pointer(.pointer_down, disabled));
    try std.testing.expect(state.handle(geometry, pointer(.pointer_up, disabled)).command == null);
    const checked = geometry.rowRect(&state, 3).?;
    _ = state.handle(geometry, pointer(.pointer_down, checked));
    try std.testing.expectEqual(@as(?u32, 3), state.handle(geometry, pointer(.pointer_up, checked)).command);
    try std.testing.expect(state.open_group == null);
}

test "menu keyboard navigation skips separators and disabled rows with cancellation" {
    const geometry = try layout(316, 236);
    var state: menu.State = .{};
    try std.testing.expect(state.open(geometry, 0));
    _ = state.handle(geometry, key(.down));
    try std.testing.expectEqual(@as(?u8, 0), state.selected_row);
    _ = state.handle(geometry, key(.down));
    try std.testing.expectEqual(@as(?u8, 3), state.selected_row);
    _ = state.handle(geometry, key(.up));
    try std.testing.expectEqual(@as(?u8, 0), state.selected_row);
    _ = state.handle(geometry, key(.right));
    try std.testing.expectEqual(@as(?u8, 1), state.open_group);
    _ = state.handle(geometry, key(.end));
    try std.testing.expectEqual(@as(?u8, 1), state.selected_row);
    try std.testing.expectEqual(@as(?u32, 5), state.handle(geometry, key(.enter)).command);
    try std.testing.expect(state.open_group == null);
    try std.testing.expect(state.open(geometry, 0));
    _ = state.handle(geometry, key(.escape));
    try std.testing.expect(state.open_group == null);
    try std.testing.expect(state.open(geometry, 0));
    _ = state.handle(geometry, .{ .kind = .redraw, .code = 1 });
    try std.testing.expect(state.open_group == null and state.pressed == null);
}

test "outside press dismisses menu and captures its release" {
    const geometry = try layout(316, 236);
    var state: menu.State = .{};
    try std.testing.expect(state.open(geometry, 0));
    const press = state.handle(geometry, .{ .kind = .pointer_down, .code = 1, .x = 315, .y = 235 });
    try std.testing.expect(press.consumed and press.changed);
    const release = state.handle(geometry, .{ .kind = .pointer_up, .code = 1, .x = 315, .y = 235 });
    try std.testing.expect(release.consumed and release.command == null);
}

test "other pointer buttons dismiss modal menus without activating content beneath" {
    const geometry = try layout(316, 236);
    var state: menu.State = .{};
    try std.testing.expect(state.open(geometry, 0));
    const press = state.handle(geometry, .{ .kind = .pointer_down, .code = 3, .x = 300, .y = 200 });
    try std.testing.expect(press.consumed and press.changed and state.open_group == null);
    const release = state.handle(geometry, .{ .kind = .pointer_up, .code = 3, .x = 300, .y = 200 });
    try std.testing.expect(release.consumed and release.command == null and state.pressed == null);
}

test "short popups scroll keyboard selection and retain bounded complete rows" {
    var many: [menu.max_items]menu.Item = undefined;
    for (&many, 0..) |*item, index| item.* = .{ .command = @intCast(index + 1), .label = "An available item" };
    const one = [_]menu.Group{.{ .label = "Menu", .items = &many }};
    const geometry = try menu.Layout.init(.{ .groups = &one }, .{ .x = 0, .y = 32, .width = 316, .height = 28 }, .{ .x = 0, .y = 0, .width = 316, .height = 160 });
    var state: menu.State = .{};
    try std.testing.expect(state.open(geometry, 0));
    _ = state.handle(geometry, key(.end));
    try std.testing.expectEqual(@as(?u8, 31), state.selected_row);
    try std.testing.expect(geometry.rowRect(&state, 31) != null);
    const popup = geometry.popup(&state).?;
    try std.testing.expect(@as(i64, popup.rect.y) + popup.rect.height <= 160);
    const row = geometry.rowRect(&state, 31).?;
    try std.testing.expectEqual(@as(u32, 26), row.height);
    _ = state.handle(geometry, .{ .kind = .wheel, .code = @bitCast(@as(i16, -30)) });
    try std.testing.expectEqual(@as(u8, 0), state.first_row);
    try std.testing.expect(state.selected_row == null);
}

test "narrow menu bars clip labels and never hit hidden groups" {
    const geometry = try menu.Layout.init(.{ .groups = &groups }, .{ .x = 0, .y = 0, .width = 42, .height = 28 }, .{ .x = 0, .y = 0, .width = 316, .height = 236 });
    const state: menu.State = .{};
    try std.testing.expect(geometry.groupRect(0) != null);
    try std.testing.expect(geometry.groupRect(1) == null);
    try std.testing.expect(geometry.hit(&state, .{ .x = 43, .y = 10 }) == null);
    try std.testing.expectError(error.InvalidMenu, menu.Layout.init(.{ .groups = &groups }, .{ .x = 10, .y = 0, .width = 316, .height = 28 }, .{ .x = 0, .y = 0, .width = 316, .height = 236 }));
}

test "menu painting preserves outer guards stride and rounded popup corners" {
    const stride = 322;
    var storage: [stride * 236 + 2]u32 = @splat(0x304052);
    var surface = try Surface.init(storage[1 .. storage.len - 1], 316, 236, stride, .{ .red = 0xff0000, .green = 0xff00, .blue = 0xff });
    const geometry = try layout(316, 236);
    var state: menu.State = .{};
    try std.testing.expect(state.open(geometry, 0));
    const popup = geometry.popup(&state).?.rect;
    const corner = storage[1 + @as(usize, @intCast(popup.y)) * stride + @as(usize, @intCast(popup.x))];
    try menu.draw(&surface, geometry, &state, .{});
    try std.testing.expectEqual(corner, storage[1 + @as(usize, @intCast(popup.y)) * stride + @as(usize, @intCast(popup.x))]);
    try std.testing.expectEqual(@as(u32, 0x304052), storage[0]);
    try std.testing.expectEqual(@as(u32, 0x304052), storage[storage.len - 1]);
    for (0..236) |row| for (316..stride) |column| try std.testing.expectEqual(@as(u32, 0x304052), storage[1 + row * stride + column]);
}

test "menu drawing matches pixel and command backends including gray coverage" {
    const Recorder = struct {
        surface: *Surface,
        fn fill(context: *anyopaque, x: u32, y: u32, width: u32, height: u32, pixel: u32) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.surface.fillRect(x, y, width, height, pixel);
        }
        fn blend(context: *anyopaque, x: u32, y: u32, pixel: u32, coverage: u8) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.surface.blendPixel(x, y, self.surface.decode(pixel), coverage);
        }
    };
    var left: [316 * 236]u32 = @splat(0x202A3A);
    var right = left;
    var direct = try Surface.init(&left, 316, 236, 316, .{ .red = 0xff0000, .green = 0xff00, .blue = 0xff });
    var receiver = try Surface.init(&right, 316, 236, 316, direct.masks);
    var recorder: Recorder = .{ .surface = &receiver };
    var commands = try Surface.initCommands(316, 236, .{ .context = &recorder, .fillRect = Recorder.fill, .blendPixel = Recorder.blend });
    const geometry = try layout(316, 236);
    var state: menu.State = .{};
    try std.testing.expect(state.open(geometry, 0));
    _ = state.handle(geometry, key(.down));
    const solid = menu.Theme{
        .bar_material = .{ .tint = Color.rgb(24, 29, 39), .opacity = 255 },
        .popup_material = .{ .tint = Color.rgb(29, 35, 47), .opacity = 255 },
        .selected_material = .{ .tint = Color.rgb(83, 64, 80), .opacity = 255 },
    };
    try menu.draw(&direct, geometry, &state, solid);
    try menu.draw(&commands, geometry, &state, solid);
    try std.testing.expectEqualSlices(u32, &left, &right);
}

test "app menu bar paints its full solid strip and separator including reserved trailing space" {
    const width = 360;
    const height = 160;
    const stride = 366;
    const untouched = 0x634157;
    var pixels: [stride * height + 2]u32 = @splat(untouched);
    var surface = try Surface.init(pixels[1 .. pixels.len - 1], width, height, stride, .{ .red = 0xff0000, .green = 0xff00, .blue = 0xff });
    const geometry = try menu.Layout.initBar(.{ .groups = &groups }, .{ .x = 16, .y = 8, .width = 320, .height = 144 }, .{
        .top = 24,
        .height = 40,
        .left = 18,
        .right = 100,
        .padding_top = 10,
        .padding_bottom = 6,
    });
    const theme: menu.Theme = .{
        .bar_color = Color.rgb(27, 32, 43),
        .bar_separator = Color.rgb(86, 91, 102),
        .bar_material = .{ .tint = Color.rgb(255, 0, 0), .opacity = 0 },
    };
    try menu.drawBackground(&surface, geometry, theme);
    const strip = geometry.background.?;
    try std.testing.expectEqual(@as(u32, 320), strip.width);
    try std.testing.expectEqual(@as(u32, 202), geometry.bar.width);
    for (0..height) |row| for (0..stride) |column| {
        const inside = column >= 16 and column < 336 and row >= 32 and row < 72;
        const expected = if (!inside) untouched else if (row == 71) surface.encode(theme.bar_separator.?) else surface.encode(theme.bar_color.?);
        try std.testing.expectEqual(expected, pixels[1 + row * stride + column]);
    };
    try std.testing.expectEqual(@as(u32, untouched), pixels[0]);
    try std.testing.expectEqual(@as(u32, untouched), pixels[pixels.len - 1]);
}

test "app menu padding and placement move visible and clickable labels independently of the strip" {
    const bounds: input.Rect = .{ .x = 12, .y = 6, .width = 360, .height = 220 };
    const first = try menu.Layout.initBar(.{ .groups = &groups }, bounds, .{ .top = 16, .right = 100 });
    const shifted = try menu.Layout.initBar(.{ .groups = &groups }, bounds, .{
        .top = 36,
        .height = 42,
        .left = 24,
        .right = 80,
        .padding_top = 14,
        .padding_bottom = 4,
    });
    const a = first.groupRect(0).?;
    const b = shifted.groupRect(0).?;
    try std.testing.expectEqual(@as(i32, 28), a.x);
    try std.testing.expectEqual(@as(i32, 30), a.y);
    try std.testing.expectEqual(@as(i32, 40), b.x);
    try std.testing.expectEqual(@as(i32, 56), b.y);
    try std.testing.expectEqual(@as(u32, 24), b.height);
    try std.testing.expectEqual(bounds.x, shifted.background.?.x);
    try std.testing.expectEqual(bounds.width, shifted.background.?.width);
    const state: menu.State = .{};
    try std.testing.expect(shifted.hit(&state, .{ .x = a.x + 1, .y = a.y + 1 }) == null);
    const target = shifted.hit(&state, .{ .x = b.x + 1, .y = b.y + 1 }).?;
    try std.testing.expect(target == .group and target.group == 0);
    try std.testing.expect(shifted.hit(&state, .{ .x = bounds.x + @as(i32, @intCast(bounds.width)) - 1, .y = b.y + 1 }) == null);
}

test "split menu painting preserves native trailing controls and their reserved hit area" {
    const width = 400;
    const height = 180;
    var pixels: [width * height]u32 = @splat(0x263349);
    var surface = try Surface.init(&pixels, width, height, width, .{ .red = 0xff0000, .green = 0xff00, .blue = 0xff });
    const geometry = try menu.Layout.initBar(.{ .groups = &groups }, .{ .x = 0, .y = 0, .width = width, .height = height }, .{ .top = 32, .right = 136 });
    const controls: input.Rect = .{ .x = 272, .y = 36, .width = 116, .height = 28 };
    const theme: menu.Theme = .{ .bar_color = Color.rgb(31, 34, 41), .bar_separator = Color.rgb(65, 69, 77) };
    const control_pixel = surface.encode(Color.rgb(21, 142, 183));
    try menu.drawBackground(&surface, geometry, theme);
    surface.fillRect(@intCast(controls.x), @intCast(controls.y), controls.width, controls.height, control_pixel);
    var state: menu.State = .{};
    try menu.drawContents(&surface, geometry, &state, theme);
    try std.testing.expect(state.open(geometry, 0));
    _ = state.handle(geometry, key(.down));
    try menu.drawContents(&surface, geometry, &state, theme);
    for (36..64) |row| for (272..388) |column| try std.testing.expectEqual(control_pixel, pixels[row * width + column]);
    const point: input.Point = .{ .x = controls.x + 10, .y = controls.y + 10 };
    try std.testing.expect(geometry.hit(&state, point) == null);
    const dismissal = state.handle(geometry, pointer(.pointer_down, controls));
    try std.testing.expect(dismissal.consumed and dismissal.command == null and state.open_group == null);
    try std.testing.expect(!state.handle(geometry, pointer(.pointer_down, controls)).consumed);
}

test "invalid menu strip options and bounds are rejected before paint" {
    var pixels: [160 * 120]u32 = @splat(0x495165);
    const before = pixels;
    var surface = try Surface.init(&pixels, 160, 120, 160, .{ .red = 0xff0000, .green = 0xff00, .blue = 0xff });
    const bounds: input.Rect = .{ .x = 0, .y = 0, .width = 160, .height = 120 };
    const state: menu.State = .{};
    for ([_]menu.BarOptions{
        .{ .top = 110 },
        .{ .top = std.math.maxInt(u32), .height = std.math.maxInt(u32) },
        .{ .height = 0 },
        .{ .height = 18, .padding_top = 0, .padding_bottom = 0 },
        .{ .left = 80, .right = 80 },
        .{ .left = std.math.maxInt(u16), .right = std.math.maxInt(u16) },
        .{ .padding_top = 20, .padding_bottom = 20 },
        .{ .padding_top = std.math.maxInt(u16), .padding_bottom = std.math.maxInt(u16) },
    }) |options| {
        if (menu.Layout.initBar(.{ .groups = &groups }, bounds, options)) |geometry| {
            try menu.draw(&surface, geometry, &state, .{});
            return error.InvalidMenuWasAccepted;
        } else |err| try std.testing.expectEqual(error.InvalidMenu, err);
        try std.testing.expectEqualSlices(u32, &before, &pixels);
    }
    for ([_]input.Rect{
        .{ .x = -1, .y = 0, .width = 160, .height = 120 },
        .{ .x = 0, .y = -1, .width = 160, .height = 120 },
        .{ .x = 0, .y = 0, .width = 31, .height = 120 },
        .{ .x = 0, .y = 0, .width = std.math.maxInt(u32), .height = 120 },
        .{ .x = std.math.maxInt(i32), .y = 0, .width = 160, .height = 120 },
    }) |invalid_bounds| try std.testing.expectError(error.InvalidMenu, menu.Layout.initBar(.{ .groups = &groups }, invalid_bounds, .{}));
    var invalid_background = try menu.Layout.initBar(.{ .groups = &groups }, bounds, .{});
    invalid_background.background.?.x = -1;
    try std.testing.expectError(error.InvalidSurface, menu.drawBackground(&surface, invalid_background, .{}));
    try std.testing.expectEqualSlices(u32, &before, &pixels);
}

test "legacy menu layout retains its original bar and draw matches split painting" {
    const width = 316;
    const height = 180;
    var combined: [width * height]u32 = @splat(0x263149);
    var separated = combined;
    var left = try Surface.init(&combined, width, height, width, .{ .red = 0xff0000, .green = 0xff00, .blue = 0xff });
    var right = try Surface.init(&separated, width, height, width, left.masks);
    const original_bar: input.Rect = .{ .x = 10, .y = 32, .width = 220, .height = 28 };
    const geometry = try menu.Layout.init(.{ .groups = &groups }, original_bar, .{ .x = 0, .y = 0, .width = width, .height = height });
    try std.testing.expect(geometry.background == null);
    try std.testing.expectEqualDeep(original_bar, geometry.bar);
    var state: menu.State = .{};
    try std.testing.expect(state.open(geometry, 0));
    _ = state.handle(geometry, key(.down));
    try menu.draw(&left, geometry, &state, .{});
    try menu.drawBackground(&right, geometry, .{});
    try menu.drawContents(&right, geometry, &state, .{});
    try std.testing.expectEqualSlices(u32, &combined, &separated);
    try std.testing.expectEqual(@as(u32, 0x263149), combined[40 * width + 240]);
}
