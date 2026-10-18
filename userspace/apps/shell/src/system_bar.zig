//! Trusted desktop presentation only. Commands are caller-owned policy; this
//! module has no clock syscall, app-launch authority or hardware controls.
const std = @import("std");
const ui = @import("axisui");
pub const height: u32 = 36;
pub const commands = struct {
    pub const controls: u32 = 1;
    pub const files: u32 = 2;
    pub const notes: u32 = 3;
    pub const workspace_first: u32 = 10;
    pub const floating: u32 = 20;
    pub const tiled: u32 = 21;
    pub const dim_first: u32 = 30;
};
pub const Clock = struct { available: bool = false, seconds: i64 = 0 };
pub const Date = struct { year: u16, month: u8, day: u8, weekday: u8, hour: u8, minute: u8 };
const items = [_]ui.menu.Item{
    .{ .command = 1, .label = "Control Center" },
    .{ .command = 2, .label = "Open Files", .shortcut = "Super+E" },
    .{ .command = 3, .label = "Open Notes", .shortcut = "Super+N" },
    ui.menu.Item.divider(),
    .{ .command = 10, .label = "Workspace 1", .shortcut = "Super+1" },
    .{ .command = 11, .label = "Workspace 2", .shortcut = "Super+2" },
    .{ .command = 12, .label = "Workspace 3", .shortcut = "Super+3" },
    .{ .command = 13, .label = "Workspace 4", .shortcut = "Super+4" },
};
const groups = [_]ui.menu.Group{.{ .label = "Bedrock", .items = &items }};
pub const default_model: ui.menu.Model = .{ .groups = &groups };
pub const max_status_items = 8;
pub const max_status_label_bytes = 24;
pub const StatusItem = struct {
    label: []const u8 = "",
    icon: ?ui.Icon = null,
    /// Zero denotes a display-only readout. Nonzero IDs belong to the host.
    command: u32 = 0,
    enabled: bool = true,
};
/// Trusted OS developers can replace or extend the leading dropdown's borrowed
/// definition. The caller remains responsible for authorizing command dispatch;
/// this configuration is not an untrusted app registration or IPC interface.
pub const Config = struct {
    menu: ui.menu.Model = default_model,
    status_items: []const StatusItem = &.{},
};

fn validateStatusItems(items_value: []const StatusItem) error{InvalidMenu}!void {
    if (items_value.len > max_status_items) return error.InvalidMenu;
    for (items_value) |item| {
        if ((item.label.len == 0 and item.icon == null) or item.label.len > max_status_label_bytes) return error.InvalidMenu;
        for (item.label) |byte| if (byte < 32 or byte > 126) return error.InvalidMenu;
    }
}
/// Shared status geometry lies after the existing app/workspace/layout strip
/// and before clock/Control Center. Overflow labels clip by whole glyphs;
/// completely hidden items never acquire an invisible input target.
pub fn statusRectWithConfig(width: u32, index: usize, config: Config) error{InvalidMenu}!?ui.Rect {
    try validateStatusItems(config.status_items);
    if (width > ui.max_surface_dimension) return error.InvalidMenu;
    return statusRect(width, index, config);
}
fn statusRect(width: u32, index: usize, config: Config) ?ui.Rect {
    if (index >= config.status_items.len) return null;
    const end = width -| 162;
    var x: u32 = 488;
    for (config.status_items, 0..) |item, item_index| {
        const label_width = (ui.font.measure(item.label, 1) catch unreachable).width;
        const icon_width: u32 = if (item.icon != null) 16 else 0;
        const gap: u32 = if (item.icon != null and item.label.len != 0) 6 else 0;
        const wanted = 16 + icon_width + gap + label_width;
        const minimum: u32 = if (item.icon != null) 32 else 24;
        const available = end -| x;
        if (available < minimum) return null;
        const actual = @min(wanted, available);
        if (item_index == index) return .{ .x = @intCast(x), .y = 4, .width = actual, .height = 28 };
        x += actual + 6;
    }
    return null;
}
fn statusAt(width: u32, config: Config, point: ui.Point) ?u8 {
    for (config.status_items, 0..) |_, index| {
        if (statusRect(width, index, config)) |rect| if (roundedHit(rect, 8, point)) return @intCast(index);
    }
    return null;
}

pub fn layout(width: u32, screen_height: u32) !ui.menu.Layout {
    return layoutWithConfig(width, screen_height, .{});
}
pub fn layoutWithConfig(width: u32, screen_height: u32, config: Config) !ui.menu.Layout {
    try validateStatusItems(config.status_items);
    if (width < 86 or screen_height < height) return error.InvalidMenu;
    return ui.menu.Layout.init(config.menu, .{ .x = 6, .y = 0, .width = 80, .height = height }, .{ .x = 0, .y = 0, .width = width, .height = screen_height });
}
pub fn controlsRect(width: u32) ui.Rect {
    const x = width -| 42;
    return .{ .x = @intCast(@min(x, ui.max_surface_dimension)), .y = 4, .width = @min(28, width - x), .height = 28 };
}
pub fn panelRect(width: u32, screen_height: u32) ui.Rect {
    const x = width -| 316;
    return .{ .x = @intCast(@min(x, ui.max_surface_dimension)), .y = 44, .width = @min(308, width - x), .height = @min(300, screen_height -| 44) };
}
fn buttonRect(panel: ui.Rect, command: u32) ?ui.Rect {
    var x: u32 = 0;
    var y: u32 = 0;
    var width: u32 = 0;
    var button_height: u32 = 0;
    if (command == 20 or command == 21) {
        x = if (command == 20) 14 else 156;
        y = 96;
        width = 136;
        button_height = 30;
    } else if (command >= 10 and command <= 13) {
        x = 14 + (command - 10) * 70;
        y = 151;
        width = 62;
        button_height = 28;
    } else if (command >= 30 and command <= 33) {
        x = 14 + (command - 30) * 70;
        y = 222;
        width = 62;
        button_height = 28;
    } else return null;
    if (x + width > panel.width or y + button_height > panel.height) return null;
    return .{ .x = panel.x + @as(i32, @intCast(x)), .y = panel.y + @as(i32, @intCast(y)), .width = width, .height = button_height };
}
fn roundedHit(rect: ui.Rect, radius: u32, point: ui.Point) bool {
    return ui.materials.roundedContains(rect.width, rect.height, radius, @as(i64, point.x) - rect.x, @as(i64, point.y) - rect.y);
}
fn panelAction(panel: ui.Rect, point: ui.Point) ?u32 {
    for ([_]u32{ 20, 21, 10, 11, 12, 13, 30, 31, 32, 33 }) |command| {
        if (buttonRect(panel, command)) |rect| if (roundedHit(rect, 9, point)) return command;
    }
    return null;
}
pub const State = struct {
    menu: ui.menu.State = .{},
    panel_open: bool = false,
    pressed: ?u32 = null,
    dismiss_release: bool = false,
    status_hover: ?u8 = null,
    status_pressed: ?struct { index: u8, command: u32 } = null,
    dim: u8 = 255,

    pub fn close(self: *State) void {
        self.menu.close();
        self.panel_open = false;
        self.pressed = null;
        self.dismiss_release = false;
        self.status_hover = null;
        self.status_pressed = null;
    }
    pub fn handle(self: *State, width: u32, screen_height: u32, event: ui.Event) !ui.menu.Result {
        return self.handleWithConfig(width, screen_height, event, .{});
    }
    pub fn handleWithConfig(self: *State, width: u32, screen_height: u32, event: ui.Event, config: Config) !ui.menu.Result {
        const menu_layout = try layoutWithConfig(width, screen_height, config);
        var result: ui.menu.Result = .{};
        const point: ui.Point = .{ .x = event.x, .y = event.y };
        const on_controls = roundedHit(controlsRect(width), 10, point);
        if (event.kind == .redraw and event.code == 1) {
            result.consumed = self.panel_open or self.menu.open_group != null or self.pressed != null or self.dismiss_release or self.status_pressed != null;
            result.changed = result.consumed;
            self.close();
            return result;
        }
        if (self.dismiss_release) {
            result.consumed = true;
            if (event.kind == .pointer_up) {
                self.dismiss_release = false;
                result.changed = true;
            }
            return result;
        }
        if (event.kind == .key_down and event.code == @backingInt(ui.input.Key.escape) and (self.panel_open or self.pressed != null or self.status_pressed != null)) {
            self.close();
            return .{ .consumed = true, .changed = true };
        }
        if (event.kind == .pointer_down and event.code == @backingInt(ui.input.Button.left) and on_controls) {
            self.menu.close();
            self.status_pressed = null;
            self.status_hover = null;
            self.pressed = 1;
            return .{ .consumed = true, .changed = true };
        }
        if (event.kind == .pointer_up and event.code == @backingInt(ui.input.Button.left) and self.pressed == 1) {
            self.pressed = null;
            if (on_controls) self.panel_open = !self.panel_open;
            return .{ .consumed = true, .changed = true };
        }
        if (self.panel_open) {
            result.consumed = true;
            const panel = panelRect(width, screen_height);
            switch (event.kind) {
                .pointer_down => {
                    if (!roundedHit(panel, 20, point)) {
                        self.close();
                        self.dismiss_release = true;
                    } else self.pressed = if (event.code == @backingInt(ui.input.Button.left)) panelAction(panel, point) else null;
                    result.changed = true;
                },
                .pointer_up => {
                    if (event.code == @backingInt(ui.input.Button.left)) {
                        const hit = panelAction(panel, point);
                        if (self.pressed != null and self.pressed == hit) {
                            result.command = hit;
                            if (hit.? >= 30 and hit.? <= 33) self.dim = levels[hit.? - 30];
                        }
                        result.changed = self.pressed != null;
                        self.pressed = null;
                    }
                },
                else => {},
            }
            return result;
        }
        // An open modal dropdown owns its outside dismissal before a status
        // item can activate, matching the panel's no-clickthrough behavior.
        if (self.menu.open_group != null or self.menu.pressed != null) return self.menu.handle(menu_layout, event);
        const status_index = statusAt(width, config, point);
        if (self.status_pressed) |press| {
            if (event.kind == .pointer_up and event.code == @backingInt(ui.input.Button.left)) {
                if (status_index == press.index and press.index < config.status_items.len) {
                    const item = config.status_items[press.index];
                    if (item.enabled and item.command != 0 and item.command == press.command) result.command = item.command;
                }
                self.status_pressed = null;
                return .{ .consumed = true, .changed = true, .command = result.command };
            }
            if (event.kind == .pointer_down) {
                self.status_pressed = null;
                self.dismiss_release = true;
                return .{ .consumed = true, .changed = true };
            }
            if (event.kind == .pointer_move) {
                const changed = self.status_hover != status_index;
                self.status_hover = status_index;
                return .{ .consumed = true, .changed = changed };
            }
        }
        if (event.kind == .pointer_move) {
            result.changed = self.status_hover != status_index;
            self.status_hover = status_index;
            result.consumed = status_index != null;
        }
        if (event.kind == .pointer_down and status_index != null) {
            if (event.code == @backingInt(ui.input.Button.left)) {
                const index = status_index.?;
                self.status_hover = index;
                self.status_pressed = .{ .index = index, .command = config.status_items[index].command };
            } else self.dismiss_release = true;
            return .{ .consumed = true, .changed = true };
        }
        if (result.changed or result.consumed) return result;
        return self.menu.handle(menu_layout, event);
    }
};

/// Local calendar seconds are supplied by the host after applying its timezone
/// policy. Gregorian 400-year cycles avoid iteration and handle negative epochs.
pub fn calendar(seconds: i64) ?Date {
    if (seconds < -62135596800 or seconds >= 253433923200) return null;
    const days = @divFloor(seconds, 86400);
    const within = @mod(seconds, 86400);
    const shifted = days + 719468;
    const era = @divFloor(shifted, 146097);
    const day_of_era = shifted - era * 146097;
    const year_of_era = @divTrunc(day_of_era - @divTrunc(day_of_era, 1460) + @divTrunc(day_of_era, 36524) - @divTrunc(day_of_era, 146096), 365);
    const day_of_year = day_of_era - (365 * year_of_era + @divTrunc(year_of_era, 4) - @divTrunc(year_of_era, 100));
    const month_march = @divTrunc(5 * day_of_year + 2, 153);
    const month = month_march + @as(i64, if (month_march < 10) 3 else -9);
    const year = year_of_era + era * 400 + @intFromBool(month <= 2);
    return .{ .year = @intCast(year), .month = @intCast(month), .day = @intCast(day_of_year - @divTrunc(153 * month_march + 2, 5) + 1), .weekday = @intCast(@mod(days + 4, 7)), .hour = @intCast(@divTrunc(within, 3600)), .minute = @intCast(@divTrunc(@mod(within, 3600), 60)) };
}
const ink = ui.Color.rgb(222, 227, 238);
const quiet = ui.Color.rgb(158, 168, 187);
const rose = ui.Color.rgb(219, 172, 194);
const levels = [_]u8{ 64, 128, 192, 255 };
fn text(surface: *ui.Surface, bytes: []const u8, x: i32, y: i32, color: ui.Color) !void {
    try ui.font.paint(surface, bytes, x, y, color, 1);
}
fn button(surface: *ui.Surface, state: *const State, panel: ui.Rect, command: u32, label: []const u8, selected: bool) !void {
    const rect = buttonRect(panel, command) orelse return;
    surface.roundedMaterialRect(rect.x, rect.y, rect.width, rect.height, 9, if (selected or state.pressed == command) .{ .tint = ui.Color.rgb(91, 67, 87), .opacity = 125 } else ui.materials.glass.control);
    surface.roundedBorder(rect.x, rect.y, rect.width, rect.height, 9, ui.materials.glass.edge, 1, if (selected) 55 else 20);
    const measured = try ui.font.measure(label, 1);
    try text(surface, label, rect.x + @as(i32, @intCast((rect.width - @min(rect.width, measured.width)) / 2)), try ui.font.controlOriginY(rect.y, rect.height, 1), if (selected) rose else ink);
}

/// Draw after the existing launch/workspace strip. The caller has attached a
/// private immutable wallpaper backdrop; overlays never sample client pixels.
pub fn draw(surface: *ui.Surface, state: *State, clock: Clock, workspace: u32, tiled: bool) !void {
    return drawWithConfig(surface, state, clock, workspace, tiled, .{});
}
pub fn drawWithConfig(surface: *ui.Surface, state: *State, clock: Clock, workspace: u32, tiled: bool, config: Config) !void {
    try surface.validate();
    const menu_layout = try layoutWithConfig(surface.width, surface.height, config);
    try ui.menu.draw(surface, menu_layout, &state.menu, .{ .bar_material = .{ .tint = ui.materials.glass.sidebar.tint, .opacity = 108 } });
    for (config.status_items, 0..) |item, index| {
        const rect = statusRect(surface.width, index, config) orelse continue;
        const selected = (if (state.status_pressed) |press| press.index == index else false) or state.status_hover == @as(u8, @intCast(index));
        if (selected and item.enabled and item.command != 0) surface.roundedMaterialRect(rect.x, rect.y, rect.width, rect.height, 8, ui.materials.glass.control);
        const color = if (item.enabled) ink else quiet;
        var label_x = rect.x + 8;
        if (item.icon) |icon| {
            try ui.icons.draw(surface, icon, .{ .x = label_x, .y = rect.y + @as(i32, @intCast((rect.height - ui.icons.size) / 2)) }, color, 1);
            label_x += 16 + @as(i32, if (item.label.len != 0) 6 else 0);
        }
        const available: u32 = @intCast(@max(0, @as(i64, rect.x) + rect.width - 8 - label_x));
        var end: usize = 0;
        while (end < item.label.len and (ui.font.measure(item.label[0 .. end + 1], 1) catch unreachable).width <= available) : (end += 1) {}
        try text(surface, item.label[0..end], label_x, try ui.font.controlOriginY(rect.y, rect.height, 1), color);
    }
    const right_x = surface.width -| 154;
    surface.materialRect(right_x, 0, surface.width - right_x, height, .{ .tint = ui.materials.glass.sidebar.tint, .opacity = 108 });
    const controls = controlsRect(surface.width);
    const bar_text_y = try ui.font.controlOriginY(0, height, 1);
    const bar_icon_y: i32 = @intCast((height - ui.icons.size) / 2);
    if (state.panel_open or state.pressed == 1) surface.roundedMaterialRect(controls.x, controls.y, controls.width, controls.height, 10, ui.materials.glass.control);
    try ui.icons.draw(surface, .control_center, .{ .x = controls.x + 6, .y = bar_icon_y }, ink, 1);
    const date = if (clock.available) calendar(clock.seconds) else null;
    var time_buffer: [16]u8 = undefined;
    const time = if (date) |value| try std.fmt.bufPrint(&time_buffer, "{d:0>2}:{d:0>2}", .{ value.hour, value.minute }) else "--:--";
    const time_x: i32 = @intCast(surface.width -| 123);
    try ui.icons.draw(surface, .clock, .{ .x = time_x, .y = bar_icon_y }, quiet, 1);
    try text(surface, time, time_x + 22, bar_text_y, ink);
    if (!state.panel_open) return;
    const panel = panelRect(surface.width, surface.height);
    if (panel.width < 300 or panel.height < 300) return;
    surface.roundedMaterialRect(panel.x, panel.y, panel.width, panel.height, 20, .{ .tint = ui.Color.rgb(35, 39, 53), .opacity = 136 });
    surface.roundedBorder(panel.x, panel.y, panel.width, panel.height, 20, ui.materials.glass.edge, 1, 35);
    try text(surface, "Control Center", panel.x + 16, panel.y + 16, ink);
    var date_buffer: [48]u8 = undefined;
    const weekdays = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
    const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    const date_label = if (date) |value| try std.fmt.bufPrint(&date_buffer, "{s}, {s} {d}, {d}", .{ weekdays[value.weekday], months[value.month - 1], value.day, value.year }) else "Time unavailable";
    try text(surface, date_label, panel.x + 16, panel.y + 39, quiet);
    try text(surface, "Window layout", panel.x + 16, panel.y + 73, quiet);
    try button(surface, state, panel, 20, "Floating", !tiled);
    try button(surface, state, panel, 21, "Tiled", tiled);
    try text(surface, "Workspaces", panel.x + 16, panel.y + 131, quiet);
    for (0..4) |index| {
        const label = [_]u8{@as(u8, @intCast(index)) + '1'};
        try button(surface, state, panel, @as(u32, @intCast(index)) + 10, &label, workspace == index);
    }
    try ui.icons.draw(surface, .brightness, .{ .x = panel.x + 14, .y = panel.y + 193 + @as(i32, @intCast((22 - ui.icons.size) / 2)) }, quiet, 1);
    try text(surface, "Display dimming", panel.x + 38, try ui.font.controlOriginY(panel.y + 193, 22, 1), quiet);
    const level_labels = [_][]const u8{ "25%", "50%", "75%", "100%" };
    for (level_labels, 0..) |label, index| try button(surface, state, panel, @as(u32, @intCast(index)) + 30, label, state.dim == levels[index]);
    try text(surface, "Software dimming", panel.x + 16, panel.y + 269, quiet);
}

test {
    _ = @import("system_bar_tests.zig");
}
