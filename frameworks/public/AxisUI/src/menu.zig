//! Borrowed native menu definitions, bounded geometry and caller-owned input.
//! Command IDs are app-owned data; dispatch never grants resource authority.
const std = @import("std");
const input = @import("input.zig");
const types = @import("types.zig");
const Surface = @import("surface.zig").Surface;
const font = @import("font.zig");
const materials = @import("materials.zig");
const icons = @import("icons.zig");

pub const max_groups = 8;
pub const max_items = 32;
pub const max_total_items = 128;
pub const max_label_bytes = 48;
pub const max_shortcut_bytes = 20;
pub const bar_height: u32 = 28;
pub const row_height: u32 = 26;
pub const separator_height: u32 = 9;
pub const popup_padding: u32 = 6;

pub const Item = struct {
    command: u32 = 0,
    label: []const u8 = "",
    /// Display hint only. The application owns shortcut dispatch and permissions.
    shortcut: []const u8 = "",
    enabled: bool = true,
    checked: bool = false,
    separator: bool = false,

    pub fn divider() Item {
        return .{ .separator = true, .enabled = false };
    }
};
pub const Group = struct { label: []const u8, items: []const Item };
pub const Model = struct {
    groups: []const Group,

    pub fn init(groups: []const Group) error{InvalidMenu}!Model {
        const model: Model = .{ .groups = groups };
        try model.validate();
        return model;
    }

    pub fn validate(self: Model) error{InvalidMenu}!void {
        if (self.groups.len == 0 or self.groups.len > max_groups) return error.InvalidMenu;
        var count: usize = 0;
        for (self.groups, 0..) |group, group_index| {
            if (!labelValid(group.label, max_label_bytes, false) or group.items.len == 0 or group.items.len > max_items)
                return error.InvalidMenu;
            count += group.items.len;
            if (count > max_total_items) return error.InvalidMenu;
            for (group.items, 0..) |item, item_index| {
                if (item.separator) {
                    if (item.command != 0 or item.label.len != 0 or item.shortcut.len != 0 or item.checked)
                        return error.InvalidMenu;
                    continue;
                }
                if (item.command == 0 or !labelValid(item.label, max_label_bytes, false) or
                    !labelValid(item.shortcut, max_shortcut_bytes, true)) return error.InvalidMenu;
                // A command may appear in multiple menus, but a single group
                // must not have two indistinguishable command targets.
                for (self.groups[group_index].items[0..item_index]) |earlier| {
                    if (!earlier.separator and earlier.command == item.command) return error.InvalidMenu;
                }
            }
        }
    }
};

fn labelValid(bytes: []const u8, limit: usize, allow_empty: bool) bool {
    if ((!allow_empty and bytes.len == 0) or bytes.len > limit) return false;
    for (bytes) |byte| if (byte < 32 or byte > 126) return false;
    return true;
}
fn measure(bytes: []const u8) u32 {
    return (font.measure(bytes, 1) catch unreachable).width;
}
fn selectable(item: Item) bool {
    return item.enabled and !item.separator;
}
fn itemHeight(item: Item) u32 {
    return if (item.separator) separator_height else row_height;
}

pub const Target = union(enum) {
    group: u8,
    item: struct { group: u8, row: u8 },
    dismiss: void,
};
pub const Popup = struct { rect: input.Rect, first: u8, visible: u8 };

/// An app-owned strip below its title/navigation area. Padding controls label
/// placement independently of the full-width background and trailing controls.
pub const BarOptions = struct {
    top: u32 = 0,
    height: u32 = 40,
    left: u16 = 12,
    right: u16 = 12,
    padding_top: u16 = 8,
    padding_bottom: u16 = 4,
};

/// Menu geometry is client-local. Bounds clip both the bar and its popups;
/// pass the whole client or screen as bounds, and any owned strip as bar.
pub const Layout = struct {
    model: Model,
    bar: input.Rect,
    bounds: input.Rect,
    background: ?input.Rect = null,

    pub fn init(model: Model, bar: input.Rect, bounds: input.Rect) error{InvalidMenu}!Layout {
        try model.validate();
        if (bounds.width < 32 or bounds.height < font.line_height or bounds.width > 16384 or bounds.height > 16384 or
            bounds.x < 0 or bounds.y < 0 or @as(i64, bounds.x) + bounds.width > 16384 or
            @as(i64, bounds.y) + bounds.height > 16384 or bar.width == 0 or bar.height < font.line_height or
            bar.x < bounds.x or bar.y < bounds.y or @as(i64, bar.x) + bar.width > @as(i64, bounds.x) + bounds.width or
            @as(i64, bar.y) + bar.height > @as(i64, bounds.y) + bounds.height) return error.InvalidMenu;
        return .{ .model = model, .bar = bar, .bounds = bounds };
    }

    pub fn initBar(model: Model, bounds: input.Rect, options: BarOptions) error{InvalidMenu}!Layout {
        _ = try init(model, bounds, bounds);
        const horizontal = @as(u32, options.left) + options.right;
        const vertical = @as(u32, options.padding_top) + options.padding_bottom;
        if (@as(u64, options.top) + options.height > bounds.height or
            horizontal >= bounds.width or vertical >= options.height) return error.InvalidMenu;
        const strip: input.Rect = .{ .x = bounds.x, .y = @intCast(@as(i64, bounds.y) + options.top), .width = bounds.width, .height = options.height };
        var result = try init(model, .{
            .x = @intCast(@as(i64, strip.x) + options.left),
            .y = @intCast(@as(i64, strip.y) + options.padding_top),
            .width = strip.width - horizontal,
            .height = strip.height - vertical,
        }, bounds);
        result.background = strip;
        return result;
    }

    /// Labels stop at the right edge; clipped or hidden labels never create
    /// invisible input targets beyond the declared bar.
    pub fn groupRect(self: Layout, group_index: usize) ?input.Rect {
        if (group_index >= self.model.groups.len) return null;
        var offset: u32 = 4;
        for (self.model.groups, 0..) |group, index| {
            if (offset >= self.bar.width) return null;
            const width = @min(measure(group.label) + 20, self.bar.width - offset);
            if (index == group_index) {
                if (width < 20) return null;
                return .{ .x = self.bar.x + @as(i32, @intCast(offset)), .y = self.bar.y, .width = width, .height = self.bar.height };
            }
            offset += width;
        }
        return null;
    }

    pub fn popup(self: Layout, state: *const State) ?Popup {
        const group_index = state.open_group orelse return null;
        if (group_index >= self.model.groups.len) return null;
        const anchor = self.groupRect(group_index) orelse return null;
        const items = self.model.groups[group_index].items;
        const first: u8 = @intCast(@min(state.first_row, items.len - 1));
        var wanted_width: u32 = 168;
        var wanted_height: u32 = popup_padding * 2;
        for (items[first..]) |item| {
            wanted_width = @max(wanted_width, measure(item.label) + measure(item.shortcut) + 64);
            wanted_height += itemHeight(item);
        }
        const width = @min(wanted_width, self.bounds.width);
        const below = @as(i64, self.bar.y) + self.bar.height;
        const bounds_bottom = @as(i64, self.bounds.y) + self.bounds.height;
        // Prefer the space below the bar. On a very short client, clamp to the
        // complete bounds instead of producing truncated clickable rows.
        const available: u32 = @intCast(@max(0, bounds_bottom - below));
        const height = @min(wanted_height, if (available >= row_height + popup_padding * 2) available else self.bounds.height);
        if (height < popup_padding * 2 + separator_height) return null;
        const x: i32 = @intCast(@max(self.bounds.x, @min(@as(i64, anchor.x), @as(i64, self.bounds.x) + self.bounds.width - width)));
        const y: i32 = @intCast(@max(self.bounds.y, @min(below, bounds_bottom - height)));
        var used: u32 = popup_padding * 2;
        var visible: u8 = 0;
        for (items[first..]) |item| {
            const h = itemHeight(item);
            if (used + h > height) break;
            used += h;
            visible += 1;
        }
        if (visible == 0) return null;
        return .{ .rect = .{ .x = x, .y = y, .width = width, .height = used }, .first = first, .visible = visible };
    }

    pub fn rowRect(self: Layout, state: *const State, row_index: usize) ?input.Rect {
        const menu = self.popup(state) orelse return null;
        if (row_index < menu.first or row_index >= @as(usize, menu.first) + menu.visible) return null;
        const items = self.model.groups[state.open_group.?].items;
        var offset: u32 = popup_padding;
        for (items[menu.first..row_index]) |item| offset += itemHeight(item);
        return .{ .x = menu.rect.x + @as(i32, popup_padding), .y = menu.rect.y + @as(i32, @intCast(offset)), .width = menu.rect.width - popup_padding * 2, .height = itemHeight(items[row_index]) };
    }

    pub fn hit(self: Layout, state: *const State, point: input.Point) ?Target {
        if (!self.bounds.contains(point)) return null;
        // The popup may cover a bar in short clients, so its rows take priority.
        if (self.popup(state)) |menu| {
            if (materials.roundedContains(menu.rect.width, menu.rect.height, 6, @as(i64, point.x) - menu.rect.x, @as(i64, point.y) - menu.rect.y)) {
                for (menu.first..@as(usize, menu.first) + menu.visible) |row| {
                    if (self.rowRect(state, row).?.contains(point)) return .{ .item = .{ .group = state.open_group.?, .row = @intCast(row) } };
                }
                return .dismiss;
            }
        }
        for (0..self.model.groups.len) |index| {
            if (self.groupRect(index)) |rect| if (rect.contains(point)) return .{ .group = @intCast(index) };
        }
        return null;
    }
};

pub const Result = struct { consumed: bool = false, changed: bool = false, command: ?u32 = null };
pub const State = struct {
    open_group: ?u8 = null,
    selected_row: ?u8 = null,
    first_row: u8 = 0,
    pressed: ?Target = null,

    pub fn close(self: *State) void {
        self.* = .{};
    }
    pub fn open(self: *State, layout: Layout, group_index: usize) bool {
        if (layout.groupRect(group_index) == null) return false;
        self.* = .{ .open_group = @intCast(group_index) };
        return true;
    }

    /// A returned command requires a matched press/release, or Enter on an
    /// enabled keyboard selection. Pointer-up alone never invokes a command.
    /// Feed all events while open so outside presses and redraw code1 cancel.
    pub fn handle(self: *State, layout: Layout, event: input.Event) Result {
        if (self.open_group) |group| if (group >= layout.model.groups.len) self.close();
        if (self.open_group) |group| {
            const count = layout.model.groups[group].items.len;
            if (self.selected_row) |row| if (row >= count) {
                self.selected_row = null;
            };
            if (self.pressed) |pressed| if (pressed == .item and
                (pressed.item.group != group or pressed.item.row >= count))
            {
                self.pressed = null;
            };
        }
        const before = self.*;
        var result: Result = .{};
        const point: input.Point = .{ .x = event.x, .y = event.y };
        switch (event.kind) {
            .redraw => if (event.code == 1) {
                result.consumed = self.open_group != null or self.pressed != null;
                self.close();
            },
            .pointer_down => if (event.code == @backingInt(input.Button.left)) {
                if (layout.hit(self, point)) |target| {
                    result.consumed = true;
                    switch (target) {
                        .group => |group| {
                            if (self.open_group == group) self.close() else _ = self.open(layout, group);
                            self.pressed = .{ .group = group };
                        },
                        .item => |item| {
                            self.selected_row = if (selectable(layout.model.groups[item.group].items[item.row])) item.row else null;
                            self.pressed = if (self.selected_row != null) target else .dismiss;
                        },
                        .dismiss => self.pressed = .dismiss,
                    }
                } else if (self.open_group != null) {
                    self.close();
                    self.pressed = .dismiss;
                    result.consumed = true;
                }
            } else if (self.open_group != null) {
                // Other buttons dismiss a modal menu too; do not open a
                // context menu or start a body gesture through its popup.
                self.close();
                self.pressed = .dismiss;
                result.consumed = true;
            },
            .pointer_up => if (event.code == @backingInt(input.Button.left)) {
                if (self.pressed) |pressed| {
                    result.consumed = true;
                    const target = layout.hit(self, point);
                    if (pressed == .item) {
                        const item = pressed.item;
                        if (target != null and target.? == .item and target.?.item.group == item.group and target.?.item.row == item.row) {
                            const value = layout.model.groups[item.group].items[item.row];
                            if (selectable(value)) result.command = value.command;
                        }
                        self.close();
                    } else self.pressed = null;
                } else result.consumed = self.open_group != null;
            } else if (self.pressed != null and self.pressed.? == .dismiss) {
                self.pressed = null;
                result.consumed = true;
            } else {
                result.consumed = self.open_group != null;
            },
            .pointer_move => if (self.open_group != null) {
                result.consumed = true;
                if (layout.hit(self, point)) |target| switch (target) {
                    .group => |group| if (group != self.open_group.?) {
                        // Switching a menu invalidates an earlier row press.
                        _ = self.open(layout, group);
                    },
                    .item => |item| self.selected_row = if (selectable(layout.model.groups[item.group].items[item.row])) item.row else null,
                    .dismiss => self.selected_row = null,
                } else self.selected_row = null;
            },
            .wheel => if (self.open_group != null) {
                result.consumed = true;
                self.pressed = null;
                self.selected_row = null;
                const delta: i16 = @bitCast(event.code);
                const count = layout.model.groups[self.open_group.?].items.len;
                self.first_row = @intCast(@max(0, @min(@as(i32, self.first_row) + delta, @as(i32, @intCast(count - 1)))));
            },
            .key_down => if (self.open_group != null) {
                result.consumed = true;
                self.pressed = null;
                switch (event.code) {
                    @backingInt(input.Key.escape), @backingInt(input.Key.tab) => self.close(),
                    @backingInt(input.Key.left), @backingInt(input.Key.right) => {
                        const count = layout.model.groups.len;
                        const direction: usize = if (event.code == @backingInt(input.Key.right)) 1 else count - 1;
                        var index = (@as(usize, self.open_group.?) + direction) % count;
                        for (0..count) |_| {
                            if (self.open(layout, index)) break;
                            index = (index + direction) % count;
                        }
                    },
                    @backingInt(input.Key.down), @backingInt(input.Key.up) => self.selectNext(layout, event.code == @backingInt(input.Key.down)),
                    @backingInt(input.Key.home), @backingInt(input.Key.end) => {
                        self.selected_row = null;
                        self.selectNext(layout, event.code == @backingInt(input.Key.home));
                    },
                    @backingInt(input.Key.enter) => if (self.selected_row) |row| {
                        const item = layout.model.groups[self.open_group.?].items[row];
                        if (selectable(item)) {
                            result.command = item.command;
                            self.close();
                        }
                    },
                    else => {},
                }
            },
            .key_up, .text => result.consumed = self.open_group != null,
        }
        result.changed = !sameState(before, self.*);
        return result;
    }

    fn selectNext(self: *State, layout: Layout, forward: bool) void {
        const items = layout.model.groups[self.open_group.?].items;
        var index: usize = if (self.selected_row) |row| row else if (forward) items.len - 1 else 0;
        for (0..items.len) |_| {
            index = (index + if (forward) @as(usize, 1) else items.len - 1) % items.len;
            if (selectable(items[index])) {
                self.selected_row = @intCast(index);
                self.ensureVisible(layout);
                return;
            }
        }
        self.selected_row = null;
    }
    fn ensureVisible(self: *State, layout: Layout) void {
        const selected = self.selected_row orelse return;
        if (selected < self.first_row) self.first_row = selected;
        while (layout.rowRect(self, selected) == null and self.first_row < selected) self.first_row += 1;
    }
};

fn sameState(a: State, b: State) bool {
    if (a.open_group != b.open_group or a.selected_row != b.selected_row or a.first_row != b.first_row) return false;
    if (a.pressed == null or b.pressed == null) return a.pressed == null and b.pressed == null;
    if (std.meta.activeTag(a.pressed.?) != std.meta.activeTag(b.pressed.?)) return false;
    return switch (a.pressed.?) {
        .group => |group| group == b.pressed.?.group,
        .item => |item| item.group == b.pressed.?.item.group and item.row == b.pressed.?.item.row,
        .dismiss => true,
    };
}

pub const Theme = struct {
    bar_material: types.Material = .{ .tint = types.Color.rgb(24, 29, 39), .opacity = 72 },
    /// A solid color overrides the material for Windows-style opaque strips.
    bar_color: ?types.Color = null,
    bar_separator: ?types.Color = null,
    popup_material: types.Material = .{ .tint = types.Color.rgb(29, 35, 47), .opacity = 142 },
    selected_material: types.Material = .{ .tint = types.Color.rgb(83, 64, 80), .opacity = 122 },
    text: types.Color = types.Color.rgb(225, 230, 239),
    disabled: types.Color = types.Color.rgb(120, 130, 147),
    shortcut: types.Color = types.Color.rgb(156, 168, 188),
    accent: types.Color = types.Color.rgb(220, 174, 195),
};

/// Caller redraws the underlying frame first, then the bar, then the popup
/// after other app content. Frozen wallpaper material never samples another app.
pub fn draw(surface: *Surface, layout: Layout, state: *const State, theme: Theme) @import("surface.zig").Error!void {
    try drawBackground(surface, layout, theme);
    try drawContents(surface, layout, state, theme);
}

/// Split painting lets apps place native trailing controls on the strip before
/// painting the menu labels/popups, without covering either set of controls.
pub fn drawBackground(surface: *Surface, layout: Layout, theme: Theme) @import("surface.zig").Error!void {
    try surface.validate();
    const bar = layout.background orelse layout.bar;
    if (bar.x < layout.bounds.x or bar.y < layout.bounds.y or bar.width == 0 or bar.height == 0 or
        @as(i64, bar.x) + bar.width > @as(i64, layout.bounds.x) + layout.bounds.width or
        @as(i64, bar.y) + bar.height > @as(i64, layout.bounds.y) + layout.bounds.height) return error.InvalidSurface;
    if (theme.bar_color) |color| surface.fillRect(@intCast(bar.x), @intCast(bar.y), bar.width, bar.height, surface.encode(color)) else surface.materialRect(@intCast(bar.x), @intCast(bar.y), bar.width, bar.height, theme.bar_material);
    if (theme.bar_separator) |color| surface.fillRect(@intCast(bar.x), @intCast(@as(i64, bar.y) + bar.height - 1), bar.width, 1, surface.encode(color));
}

pub fn drawContents(surface: *Surface, layout: Layout, state: *const State, theme: Theme) @import("surface.zig").Error!void {
    try surface.validate();
    for (layout.model.groups, 0..) |group, index| {
        const rect = layout.groupRect(index) orelse continue;
        if (state.open_group == @as(u8, @intCast(index))) surface.roundedMaterialRect(rect.x + 2, rect.y + 3, rect.width - 4, rect.height - 6, 4, theme.selected_material);
        text(surface, group.label, rect.x + 10, try font.controlOriginY(rect.y, rect.height, 1), theme.text, rect);
    }
    const menu = layout.popup(state) orelse return;
    surface.roundedMaterialRect(menu.rect.x, menu.rect.y, menu.rect.width, menu.rect.height, 6, theme.popup_material);
    surface.roundedBorder(menu.rect.x, menu.rect.y, menu.rect.width, menu.rect.height, 6, theme.text, 1, 26);
    const items = layout.model.groups[state.open_group.?].items;
    for (menu.first..@as(usize, menu.first) + menu.visible) |row| {
        const item = items[row];
        const rect = layout.rowRect(state, row).?;
        if (item.separator) {
            surface.roundedBorder(rect.x + 9, rect.y + 4, rect.width -| 18, 1, 0, theme.disabled, 1, 45);
            continue;
        }
        if (state.selected_row == @as(u8, @intCast(row))) surface.roundedMaterialRect(rect.x, rect.y, rect.width, rect.height, 4, theme.selected_material);
        const ink = if (item.enabled) theme.text else theme.disabled;
        const y = try font.controlOriginY(rect.y, rect.height, 1);
        const icon_y = rect.y + @as(i32, @intCast((rect.height - icons.size) / 2));
        if (item.checked) try icons.draw(surface, .check, .{ .x = rect.x + 2, .y = icon_y }, if (item.enabled) theme.accent else theme.disabled, 1);
        const shortcut_width = measure(item.shortcut);
        const label_width = rect.width -| (shortcut_width + 42);
        const label_clip: input.Rect = .{ .x = rect.x + 22, .y = rect.y, .width = label_width, .height = rect.height };
        text(surface, item.label, label_clip.x, y, ink, label_clip);
        if (item.shortcut.len != 0 and shortcut_width + 12 <= rect.width) {
            const shortcut_x = rect.x + @as(i32, @intCast(rect.width - shortcut_width - 10));
            text(surface, item.shortcut, shortcut_x, y, if (item.enabled) theme.shortcut else theme.disabled, rect);
        }
    }
}

/// Paint a proportional label through an explicit clip, including command
/// surfaces. No temporary frame-sized surface or stack workspace is needed.
fn text(surface: *Surface, bytes: []const u8, x: i32, y: i32, color: types.Color, clip: input.Rect) void {
    var pen: i64 = x;
    for (bytes) |byte| {
        const width = font.glyphAdvance(byte);
        if (pen >= @as(i64, clip.x) + clip.width) break;
        for (0..font.line_height) |row| for (0..width) |column| {
            const px = pen + @as(i64, @intCast(column));
            const py = @as(i64, y) + @as(i64, @intCast(row));
            if (px < 0 or py < 0 or px >= surface.width or py >= surface.height or
                px < clip.x or py < clip.y or px >= @as(i64, clip.x) + clip.width or py >= @as(i64, clip.y) + clip.height) continue;
            surface.blendPixel(@intCast(px), @intCast(py), color, font.coverage(byte, @intCast(column), @intCast(row), 1));
        };
        pen += width;
    }
}
