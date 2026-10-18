const std = @import("std");
const bar = @import("system_bar.zig");
const ui = @import("axisui");
fn pointer(kind: ui.input.Kind, x: i16, y: i16) ui.Event {
    return .{ .kind = kind, .code = @backingInt(ui.input.Button.left), .x = x, .y = y };
}
fn open(state: *bar.State) !void {
    _ = try state.handle(800, 600, pointer(.pointer_down, 775, 18));
    _ = try state.handle(800, 600, pointer(.pointer_up, 775, 18));
    try std.testing.expect(state.panel_open);
}
test "system calendar handles epoch, negative epochs, leap cycles and valid year bounds" {
    try std.testing.expectEqualDeep(bar.Date{ .year = 1970, .month = 1, .day = 1, .weekday = 4, .hour = 0, .minute = 0 }, bar.calendar(0).?);
    try std.testing.expectEqualDeep(bar.Date{ .year = 1969, .month = 12, .day = 31, .weekday = 3, .hour = 23, .minute = 59 }, bar.calendar(-1).?);
    try std.testing.expectEqualDeep(bar.Date{ .year = 2000, .month = 2, .day = 29, .weekday = 2, .hour = 0, .minute = 0 }, bar.calendar(951782400).?);
    try std.testing.expectEqual(@as(u16, 1), bar.calendar(-62135596800).?.year);
    try std.testing.expectEqual(@as(u16, 10000), bar.calendar(253433923199).?.year);
    try std.testing.expectEqual(@as(u8, 12), bar.calendar(253433923199).?.month);
    try std.testing.expectEqual(@as(u8, 31), bar.calendar(253433923199).?.day);
    try std.testing.expect(bar.calendar(-62135596801) == null);
    try std.testing.expect(bar.calendar(253433923200) == null);
    try std.testing.expect(bar.calendar(std.math.minInt(i64)) == null);
    try std.testing.expect(bar.calendar(std.math.maxInt(i64)) == null);
}
test "system panel commands require matching press release and dismissal drains release" {
    var state: bar.State = .{};
    const stray = try state.handle(800, 600, pointer(.pointer_up, 775, 18));
    try std.testing.expect(!stray.consumed and !state.panel_open);
    try open(&state);
    const panel = bar.panelRect(800, 600);
    const x: i16 = @intCast(panel.x + 25);
    const y: i16 = @intCast(panel.y + 108);
    try std.testing.expect((try state.handle(800, 600, pointer(.pointer_up, x, y))).command == null);
    _ = try state.handle(800, 600, pointer(.pointer_down, x, y));
    const mismatched = try state.handle(800, 600, pointer(.pointer_up, @intCast(panel.x + 175), y));
    try std.testing.expect(mismatched.consumed and mismatched.command == null);
    _ = try state.handle(800, 600, pointer(.pointer_down, x, y));
    try std.testing.expectEqual(@as(?u32, 20), (try state.handle(800, 600, pointer(.pointer_up, x, y))).command);
    const dismissed = try state.handle(800, 600, pointer(.pointer_down, 100, 200));
    try std.testing.expect(dismissed.consumed and !state.panel_open and state.dismiss_release);
    const release = try state.handle(800, 600, pointer(.pointer_up, x, y));
    try std.testing.expect(release.consumed and release.command == null and !state.dismiss_release);
}
test "system panel routes workspace and real software dim preferences with escape cancellation" {
    var state: bar.State = .{};
    try open(&state);
    const panel = bar.panelRect(800, 600);
    for (0..4) |index| {
        const x: i16 = @intCast(panel.x + 30 + @as(i32, @intCast(index)) * 70);
        const y: i16 = @intCast(panel.y + 165);
        _ = try state.handle(800, 600, pointer(.pointer_down, x, y));
        try std.testing.expectEqual(@as(?u32, @as(u32, @intCast(index)) + 10), (try state.handle(800, 600, pointer(.pointer_up, x, y))).command);
    }
    _ = try state.handle(800, 600, pointer(.pointer_down, @intCast(panel.x + 30), @intCast(panel.y + 236)));
    try std.testing.expectEqual(@as(?u32, 30), (try state.handle(800, 600, pointer(.pointer_up, @intCast(panel.x + 30), @intCast(panel.y + 236)))).command);
    try std.testing.expectEqual(@as(u8, 64), state.dim);
    _ = try state.handle(800, 600, pointer(.pointer_down, @intCast(panel.x + 175), @intCast(panel.y + 108)));
    const result = try state.handle(800, 600, .{ .kind = .key_down, .code = @backingInt(ui.input.Key.escape) });
    try std.testing.expect(result.consumed and result.changed and !state.panel_open);
    try std.testing.expectEqual(@as(u8, 64), state.dim);
    try std.testing.expect((try state.handle(800, 600, pointer(.pointer_up, @intCast(panel.x + 175), @intCast(panel.y + 108)))).command == null);
}
test "Bedrock system menu emits bounded independent launch commands" {
    var state: bar.State = .{};
    _ = try state.handle(800, 600, pointer(.pointer_down, 30, 18));
    _ = try state.handle(800, 600, pointer(.pointer_up, 30, 18));
    try std.testing.expect(state.menu.open_group != null);
    const menu_layout = try bar.layout(800, 600);
    const row = menu_layout.rowRect(&state.menu, 1).?;
    const x: i16 = @intCast(row.x + 35);
    const y: i16 = @intCast(row.y + 13);
    _ = try state.handle(800, 600, pointer(.pointer_down, x, y));
    try std.testing.expectEqual(@as(?u32, 2), (try state.handle(800, 600, pointer(.pointer_up, x, y))).command);
    try std.testing.expect(state.menu.open_group == null);
    try std.testing.expectError(error.InvalidMenu, bar.layout(40, 600));
    try std.testing.expectError(error.InvalidMenu, bar.layout(800, 20));
}

test "trusted system menu configuration dispatches arbitrary caller command and preserves clock controls and bounds" {
    const custom_items = [_]ui.menu.Item{
        .{ .command = 700, .label = "Inspect desktop" },
        .{ .command = 701, .label = "Unavailable action", .enabled = false },
    };
    const custom_groups = [_]ui.menu.Group{.{ .label = "Tools", .items = &custom_items }};
    const config: bar.Config = .{ .menu = .{ .groups = &custom_groups } };
    var state: bar.State = .{};
    _ = try state.handleWithConfig(800, 600, pointer(.pointer_down, 30, 18), config);
    _ = try state.handleWithConfig(800, 600, pointer(.pointer_up, 30, 18), config);
    const geometry = try bar.layoutWithConfig(800, 600, config);
    const row = geometry.rowRect(&state.menu, 0).?;
    const x: i16 = @intCast(row.x + 35);
    const y: i16 = @intCast(row.y + 13);
    _ = try state.handleWithConfig(800, 600, pointer(.pointer_down, x, y), config);
    try std.testing.expectEqual(@as(?u32, 700), (try state.handleWithConfig(800, 600, pointer(.pointer_up, x, y), config)).command);
    try std.testing.expect(state.menu.open_group == null);
    _ = try state.handleWithConfig(800, 600, pointer(.pointer_down, 775, 18), config);
    _ = try state.handleWithConfig(800, 600, pointer(.pointer_up, 775, 18), config);
    try std.testing.expect(state.panel_open);
    const baseline = try std.testing.allocator.alloc(u32, 800 * 600);
    defer std.testing.allocator.free(baseline);
    const configured = try std.testing.allocator.alloc(u32, 800 * 600);
    defer std.testing.allocator.free(configured);
    @memset(baseline, 0x17202b);
    @memset(configured, 0x17202b);
    var ordinary = try ui.Surface.init(baseline, 800, 600, 800, .{ .red = 0xff0000, .green = 0xff00, .blue = 0xff });
    var custom = try ui.Surface.init(configured, 800, 600, 800, ordinary.masks);
    var defaults: bar.State = .{ .panel_open = true };
    const clock: bar.Clock = .{ .available = true, .seconds = 1725148800 };
    try bar.draw(&ordinary, &defaults, clock, 1, false);
    try bar.drawWithConfig(&custom, &state, clock, 1, false, config);
    // Only the trusted leading dropdown definition changes. Actual time,
    // Control Center and the caller-owned app strip preserve their pixels.
    for (0..600) |scanline| for (86..800) |column| {
        try std.testing.expectEqual(baseline[scanline * 800 + column], configured[scanline * 800 + column]);
    };
    try std.testing.expectError(error.InvalidMenu, bar.layoutWithConfig(40, 600, config));
    const invalid: bar.Config = .{ .menu = .{ .groups = &.{} } };
    try std.testing.expectError(error.InvalidMenu, bar.layoutWithConfig(800, 600, invalid));
    var extended: [bar.default_model.groups[0].items.len + 1]ui.menu.Item = undefined;
    @memcpy(extended[0 .. extended.len - 1], bar.default_model.groups[0].items);
    extended[extended.len - 1] = custom_items[0];
    const extended_groups = [_]ui.menu.Group{.{ .label = "Bedrock", .items = &extended }};
    _ = try bar.layoutWithConfig(800, 600, .{ .menu = .{ .groups = &extended_groups } });
}
test "system overlays preserve stride guards and leave app launcher strip owned by the caller" {
    const sentinel: u32 = 0xa5b6c7d8;
    const background: u32 = 0x17202b;
    const stride = 803;
    const backing = try std.testing.allocator.alloc(u32, 2 + stride * 600);
    defer std.testing.allocator.free(backing);
    @memset(backing, sentinel);
    var surface = try ui.Surface.init(backing[1 .. backing.len - 1], 800, 600, stride, .{ .red = 0xff0000, .green = 0xff00, .blue = 0xff });
    surface.fillRect(0, 0, 800, 600, background);
    var state: bar.State = .{ .panel_open = true };
    try bar.draw(&surface, &state, .{ .available = true, .seconds = 1725148800 }, 2, true);
    try std.testing.expectEqual(sentinel, backing[0]);
    try std.testing.expectEqual(sentinel, backing[backing.len - 1]);
    for (0..600) |row| for (800..stride) |column| try std.testing.expectEqual(sentinel, backing[1 + row * stride + column]);
    for (0..36) |row| for (94..600) |column| try std.testing.expectEqual(background, backing[1 + row * stride + column]);
    try std.testing.expectEqual(background, backing[1 + 44 * stride + 484]);
    try std.testing.expect(backing[1 + 100 * stride + 600] != background);
    const before = backing[1 + 300 * stride + 100];
    state.close();
    try bar.draw(&surface, &state, .{}, 0, false);
    try std.testing.expectEqual(before, backing[1 + 300 * stride + 100]);
}

fn statusPointer(kind: ui.input.Kind, rect: ui.Rect) ui.Event {
    return pointer(kind, @intCast(rect.x + @as(i32, @intCast(rect.width / 2))), @intCast(rect.y + 14));
}

test "trusted status items require a matching enabled command and display-only readouts never dispatch" {
    var status = [_]bar.StatusItem{
        .{ .icon = .wifi, .command = 700 },
        .{ .label = "42%" },
        .{ .icon = .speaker, .command = 701, .enabled = false },
    };
    const config: bar.Config = .{ .status_items = &status };
    var state: bar.State = .{};
    const first = (try bar.statusRectWithConfig(800, 0, config)).?;
    const readout = (try bar.statusRectWithConfig(800, 1, config)).?;
    const disabled = (try bar.statusRectWithConfig(800, 2, config)).?;
    try std.testing.expect((try state.handleWithConfig(800, 600, statusPointer(.pointer_up, first), config)).command == null);
    _ = try state.handleWithConfig(800, 600, statusPointer(.pointer_down, first), config);
    const mismatch = try state.handleWithConfig(800, 600, statusPointer(.pointer_up, disabled), config);
    try std.testing.expect(mismatch.consumed and mismatch.command == null and state.status_pressed == null);
    _ = try state.handleWithConfig(800, 600, statusPointer(.pointer_down, first), config);
    try std.testing.expectEqual(@as(?u32, 700), (try state.handleWithConfig(800, 600, statusPointer(.pointer_up, first), config)).command);
    for ([_]ui.Rect{ readout, disabled }) |rect| {
        _ = try state.handleWithConfig(800, 600, statusPointer(.pointer_down, rect), config);
        const result = try state.handleWithConfig(800, 600, statusPointer(.pointer_up, rect), config);
        try std.testing.expect(result.consumed and result.command == null);
    }
    _ = try state.handleWithConfig(800, 600, statusPointer(.pointer_down, first), config);
    status[0].command = 702;
    try std.testing.expect((try state.handleWithConfig(800, 600, statusPointer(.pointer_up, first), config)).command == null);
    _ = try state.handleWithConfig(800, 600, statusPointer(.pointer_down, first), config);
    status[0].enabled = false;
    try std.testing.expect((try state.handleWithConfig(800, 600, statusPointer(.pointer_up, first), config)).command == null);
}

test "status dismissal follows system modal layers and cancellation drains obsolete gestures" {
    const status = [_]bar.StatusItem{.{ .icon = .wifi, .command = 700 }};
    const config: bar.Config = .{ .status_items = &status };
    const rect = (try bar.statusRectWithConfig(800, 0, config)).?;
    var state: bar.State = .{};
    _ = try state.handleWithConfig(800, 600, pointer(.pointer_down, 30, 18), config);
    _ = try state.handleWithConfig(800, 600, pointer(.pointer_up, 30, 18), config);
    try std.testing.expect(state.menu.open_group != null);
    _ = try state.handleWithConfig(800, 600, statusPointer(.pointer_down, rect), config);
    const outside = try state.handleWithConfig(800, 600, statusPointer(.pointer_up, rect), config);
    try std.testing.expect(outside.consumed and outside.command == null and state.menu.open_group == null);
    try open(&state);
    _ = try state.handleWithConfig(800, 600, statusPointer(.pointer_down, rect), config);
    try std.testing.expect((try state.handleWithConfig(800, 600, statusPointer(.pointer_up, rect), config)).command == null);
    try std.testing.expect(!state.panel_open);
    _ = try state.handleWithConfig(800, 600, statusPointer(.pointer_down, rect), config);
    const cancelled = try state.handleWithConfig(800, 600, .{ .kind = .redraw, .code = 1 }, config);
    try std.testing.expect(cancelled.consumed and state.status_pressed == null);
    try std.testing.expect((try state.handleWithConfig(800, 600, statusPointer(.pointer_up, rect), config)).command == null);
}

test "status geometry bounds overflow and rendering leaves other bar regions and pixel guards unchanged" {
    var status: [bar.max_status_items]bar.StatusItem = @splat(.{ .icon = .wifi, .command = 700 });
    const config: bar.Config = .{ .status_items = &status };
    for (0..4) |index| {
        const rect = (try bar.statusRectWithConfig(800, index, config)).?;
        try std.testing.expect(rect.x >= 488 and @as(i64, rect.x) + rect.width <= 638 and rect.y == 4 and rect.height == 28);
    }
    try std.testing.expect(try bar.statusRectWithConfig(800, 4, config) == null);
    try std.testing.expect(try bar.statusRectWithConfig(600, 0, config) == null);
    var too_many: [bar.max_status_items + 1]bar.StatusItem = @splat(status[0]);
    try std.testing.expectError(error.InvalidMenu, bar.layoutWithConfig(800, 600, .{ .status_items = &too_many }));
    const invalid = [_]bar.StatusItem{.{ .label = "Invalid\nlabel" }};
    try std.testing.expectError(error.InvalidMenu, bar.layoutWithConfig(800, 600, .{ .status_items = &invalid }));
    status[0] = .{ .label = "WWWWWWWWWWWWWWWWWWWWWWWW", .icon = .wifi, .command = 700 };
    const clipped = (try bar.statusRectWithConfig(800, 0, config)).?;
    try std.testing.expectEqual(@as(u32, 150), clipped.width);
    try std.testing.expect(try bar.statusRectWithConfig(800, 1, config) == null);
    const sentinel: u32 = 0xa5b6c7d8;
    const stride = 803;
    const ordinary = try std.testing.allocator.alloc(u32, 2 + stride * 600);
    defer std.testing.allocator.free(ordinary);
    const configured = try std.testing.allocator.alloc(u32, ordinary.len);
    defer std.testing.allocator.free(configured);
    @memset(ordinary, sentinel);
    @memset(configured, sentinel);
    var baseline = try ui.Surface.init(ordinary[1 .. ordinary.len - 1], 800, 600, stride, .{ .red = 0xff0000, .green = 0xff00, .blue = 0xff });
    var custom = try ui.Surface.init(configured[1 .. configured.len - 1], 800, 600, stride, baseline.masks);
    baseline.fillRect(0, 0, 800, 600, 0x17202b);
    custom.fillRect(0, 0, 800, 600, 0x17202b);
    var normal_state: bar.State = .{};
    var custom_state: bar.State = .{};
    try bar.draw(&baseline, &normal_state, .{ .available = true, .seconds = 1725148800 }, 1, false);
    try bar.drawWithConfig(&custom, &custom_state, .{ .available = true, .seconds = 1725148800 }, 1, false, config);
    var changed: usize = 0;
    for (0..600) |row| for (0..stride) |column| {
        const index = 1 + row * stride + column;
        if (column < 488 or column >= 638 or row < 4 or row >= 32) {
            try std.testing.expectEqual(ordinary[index], configured[index]);
        } else if (ordinary[index] != configured[index]) changed += 1;
    };
    try std.testing.expect(changed > 50);
    try std.testing.expectEqual(sentinel, configured[0]);
    try std.testing.expectEqual(sentinel, configured[configured.len - 1]);
}
