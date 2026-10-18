//! Borrowed native tabs for an app-owned strip, including title accessories.
//! Stable IDs identify gestures; applications own tab lifetime and contents.
const std = @import("std");
const input = @import("input.zig");
const types = @import("types.zig");
const Surface = @import("surface.zig").Surface;
const Error = @import("surface.zig").Error;
const font = @import("font.zig");
const icons = @import("icons.zig");

pub const max_items: usize = 32;
pub const max_label_bytes: usize = 96;
pub const Item = struct {
    /// Nonzero and unique. Do not reuse an ID while a gesture is in flight.
    id: u32,
    label: []const u8,
    closable: bool = true,
    icon: ?icons.Icon = null,
};

pub const Target = union(enum) { tab: u32, close: u32, add: void, previous: void, next: void };

/// At least one tab and the add button remain visible at 48px. At narrow
/// widths wheel navigation reaches every tab; wider overflowing bars also
/// expose previous/next arrows. Hidden tabs have no invisible hit targets.
pub const Layout = struct {
    bounds: input.Rect,
    items: []const Item,
    active: usize,
    first: usize,
    visible: usize,
    tab_width: u32,
    arrows: bool,

    pub fn init(bounds: input.Rect, items: []const Item, active: usize) error{InvalidTabs}!Layout {
        if (bounds.x < 0 or bounds.y < 0 or bounds.width < 48 or bounds.height < 20 or
            bounds.width > 16384 or bounds.height > 16384 or
            @as(i64, bounds.x) + bounds.width > 16384 or @as(i64, bounds.y) + bounds.height > 16384 or
            items.len == 0 or items.len > max_items or active >= items.len) return error.InvalidTabs;
        for (items, 0..) |item, i| {
            if (item.id == 0 or item.label.len == 0 or item.label.len > max_label_bytes) return error.InvalidTabs;
            for (item.label) |byte| if (byte < 32 or byte > 126) return error.InvalidTabs;
            for (items[0..i]) |earlier| if (earlier.id == item.id) return error.InvalidTabs;
        }
        const available = bounds.width - 24;
        const arrows = available < items.len * 72 and available >= 112;
        const tabs_width = available - @as(u32, if (arrows) 40 else 0);
        const visible = @min(items.len, @max(1, tabs_width / 72));
        const first = @min(active -| ((visible - 1) / 2), items.len - visible);
        return .{ .bounds = bounds, .items = items, .active = active, .first = first, .visible = visible, .tab_width = @min(160, tabs_width / @as(u32, @intCast(visible))), .arrows = arrows };
    }

    pub fn tabRect(self: Layout, index: usize) ?input.Rect {
        if (index < self.first or index >= self.first + self.visible) return null;
        return .{ .x = self.bounds.x + @as(i32, @intCast((index - self.first) * self.tab_width)), .y = self.bounds.y, .width = self.tab_width, .height = self.bounds.height };
    }
    pub fn closeRect(self: Layout, index: usize) ?input.Rect {
        const rect = self.tabRect(index) orelse return null;
        return closeAt(rect, self.items[index]);
    }
    pub fn addRect(self: Layout) input.Rect {
        const offset = if (self.arrows) self.bounds.width - 24 else @as(u32, @intCast(self.visible)) * self.tab_width;
        return .{ .x = self.bounds.x + @as(i32, @intCast(offset)), .y = self.bounds.y, .width = 24, .height = self.bounds.height };
    }
    pub fn previousRect(self: Layout) ?input.Rect {
        if (!self.arrows) return null;
        return .{ .x = self.addRect().x - 40, .y = self.bounds.y, .width = 20, .height = self.bounds.height };
    }
    pub fn nextRect(self: Layout) ?input.Rect {
        if (!self.arrows) return null;
        return .{ .x = self.addRect().x - 20, .y = self.bounds.y, .width = 20, .height = self.bounds.height };
    }
    pub fn hit(self: Layout, point: input.Point) ?Target {
        if (!self.bounds.contains(point)) return null;
        if (self.addRect().contains(point)) return .add;
        if (self.previousRect()) |rect| if (rect.contains(point)) return .previous;
        if (self.nextRect()) |rect| if (rect.contains(point)) return .next;
        for (self.first..self.first + self.visible) |index| {
            if (self.closeRect(index)) |rect| if (rect.contains(point)) return .{ .close = self.items[index].id };
            if (self.tabRect(index).?.contains(point)) return .{ .tab = self.items[index].id };
        }
        return null;
    }
    fn indexOf(self: Layout, id: u32) ?usize {
        for (self.items, 0..) |item, index| if (item.id == id) return index;
        return null;
    }
};

pub const Result = struct {
    select: ?usize = null,
    close: ?usize = null,
    add: bool = false,
    /// Move the source to this final index; the application owns its records.
    reorder: ?struct { from: usize, to: usize } = null,
    /// Release point is client-local, for an application/window host to place
    /// a new real window. A tab widget itself never creates a window.
    detach: ?struct { index: usize, x: i32, y: i32 } = null,
    dragging: bool = false,
    consumed: bool = false,
    changed: bool = false,
};
pub const State = struct {
    hovered: ?Target = null,
    pressed: ?Target = null,
    pressed_button: u16 = 0,
    origin: input.Point = .{ .x = 0, .y = 0 },
    pointer: input.Point = .{ .x = 0, .y = 0 },
    drag_offset: i32 = 0,
    dragging: bool = false,
    insertion: ?usize = null,

    pub fn cancel(self: *State) void {
        self.* = .{};
    }
    pub fn isDragging(self: *const State) bool {
        return self.dragging;
    }
    pub fn draggedId(self: *const State) ?u32 {
        if (!self.dragging) return null;
        const pressed = self.pressed orelse return null;
        return if (pressed == .tab) pressed.tab else null;
    }
    pub fn handle(self: *State, layout: Layout, event: input.Event) Result {
        const before = self.*;
        var result: Result = .{};
        const point: input.Point = .{ .x = event.x, .y = event.y };
        const target = layout.hit(point);
        switch (event.kind) {
            .pointer_move => {
                self.pointer = point;
                self.hovered = target;
                result.consumed = target != null or self.pressed != null;
                if (self.pressed_button == @backingInt(input.Button.left)) if (self.pressed) |pressed| if (pressed == .tab) {
                    if (layout.indexOf(pressed.tab)) |source| {
                        const distance_x = @abs(@as(i64, point.x) - self.origin.x);
                        const distance_y = @abs(@as(i64, point.y) - self.origin.y);
                        if (!self.dragging and (distance_x >= 6 or distance_y >= 6)) {
                            self.dragging = true;
                            result.select = source;
                        }
                        if (self.dragging) {
                            self.insertion = source;
                            // Vertical tear gestures never reorder the strip.
                            if (point.y >= layout.bounds.y and @as(i64, point.y) < @as(i64, layout.bounds.y) + layout.bounds.height and distance_y <= 16) {
                                const destination = dragDestination(layout, source, point.x);
                                if (destination != source) {
                                    self.insertion = destination;
                                    result.reorder = .{ .from = source, .to = destination };
                                }
                            }
                        }
                    } else self.cancel();
                };
            },
            .pointer_down => if (event.code == @backingInt(input.Button.left) or event.code == @backingInt(input.Button.middle)) {
                self.dragging = false;
                self.insertion = null;
                self.origin = point;
                self.pointer = point;
                self.pressed = if (event.code == @backingInt(input.Button.middle)) middleTarget(layout, target) else target;
                self.pressed_button = if (self.pressed != null) event.code else 0;
                if (self.pressed) |pressed| if (pressed == .tab) {
                    const index = layout.indexOf(pressed.tab).?;
                    self.drag_offset = point.x - layout.tabRect(index).?.x;
                };
                self.hovered = target;
                result.consumed = self.pressed != null;
            },
            .pointer_up => if (self.pressed_button != 0 and event.code == self.pressed_button) {
                if (self.pressed) |pressed| {
                    result.consumed = true;
                    const release = if (event.code == @backingInt(input.Button.middle)) middleTarget(layout, target) else target;
                    if (self.dragging and pressed == .tab) {
                        if (verticalDistance(layout.bounds, point.y) > 16) if (layout.indexOf(pressed.tab)) |index| {
                            result.detach = .{ .index = index, .x = point.x, .y = point.y };
                        };
                    } else if (sameTarget(pressed, release)) switch (pressed) {
                        .tab => |id| result.select = layout.indexOf(id),
                        .close => |id| result.close = layout.indexOf(id),
                        .add => result.add = true,
                        .previous => result.select = (layout.active + layout.items.len - 1) % layout.items.len,
                        .next => result.select = (layout.active + 1) % layout.items.len,
                    };
                }
                self.pressed = null;
                self.pressed_button = 0;
                self.dragging = false;
                self.insertion = null;
                self.hovered = target;
            },
            .wheel => if (layout.bounds.contains(point)) {
                self.pressed = null;
                self.pressed_button = 0;
                self.dragging = false;
                self.insertion = null;
                self.hovered = null;
                result.consumed = true;
                const delta: i16 = @bitCast(event.code);
                if (delta != 0 and layout.items.len > 1) {
                    const count: i32 = @intCast(layout.items.len);
                    result.select = @intCast(@mod(@as(i32, @intCast(layout.active)) + delta, count));
                }
            },
            .key_down => if (event.code == @backingInt(input.Key.escape) and self.pressed != null) {
                result.consumed = true;
                self.cancel();
            },
            .redraw => if (event.code == 1) {
                result.consumed = self.pressed != null;
                self.cancel();
            },
            else => {},
        }
        result.changed = !sameTarget(before.hovered, self.hovered) or !sameTarget(before.pressed, self.pressed) or
            before.pressed_button != self.pressed_button or
            before.dragging != self.dragging or before.insertion != self.insertion or
            (self.dragging and (before.pointer.x != self.pointer.x or before.pointer.y != self.pointer.y)) or
            result.select != null or result.close != null or result.add or result.reorder != null or result.detach != null;
        result.dragging = self.dragging;
        return result;
    }
};

fn verticalDistance(bounds: input.Rect, y: i32) i64 {
    if (y < bounds.y) return @as(i64, bounds.y) - y;
    return @max(0, @as(i64, y) - (@as(i64, bounds.y) + bounds.height - 1));
}

fn dragDestination(layout: Layout, source: usize, x: i32) usize {
    var destination = source;
    for (layout.first..layout.first + layout.visible) |index| {
        const rect = layout.tabRect(index).?;
        const midpoint = @as(i64, rect.x) + rect.width / 2;
        if (index < source and x < midpoint) destination = @min(destination, index);
        if (index > source and x >= midpoint) destination = @max(destination, index);
    }
    // Continued edge movement advances one hidden neighbor at a time. The
    // application keeps the stable dragged ID active after applying a move.
    if (layout.arrows) {
        if (x < layout.bounds.x + 12 and layout.first != 0) destination = layout.first - 1;
        if (x >= layout.nextRect().?.x and layout.first + layout.visible < layout.items.len) destination = layout.first + layout.visible;
    }
    return destination;
}

fn middleTarget(layout: Layout, target: ?Target) ?Target {
    const value = target orelse return null;
    const id = switch (value) {
        .tab => |id| id,
        .close => |id| id,
        else => return null,
    };
    const index = layout.indexOf(id) orelse return null;
    return if (layout.items[index].closable) .{ .close = id } else null;
}

fn sameTarget(a: ?Target, b: ?Target) bool {
    if (a == null or b == null) return a == null and b == null;
    if (std.meta.activeTag(a.?) != std.meta.activeTag(b.?)) return false;
    return switch (a.?) {
        .tab => |id| id == b.?.tab,
        .close => |id| id == b.?.close,
        .add, .previous, .next => true,
    };
}

pub const Theme = struct {
    background: types.Color = types.Color.rgb(20, 21, 26),
    active: types.Color = types.Color.rgb(39, 43, 54),
    hovered: types.Color = types.Color.rgb(48, 52, 63),
    text: types.Color = types.Color.rgb(219, 224, 234),
    inactive_text: types.Color = types.Color.rgb(158, 166, 182),
    icon: types.Color = types.Color.rgb(211, 182, 138),
    insertion: types.Color = types.Color.rgb(180, 190, 211),
    corner_radius: u8 = 4,
};

pub fn draw(surface: *Surface, layout: Layout, state: *const State, theme: Theme) Error!void {
    try surface.validate();
    const checked = Layout.init(layout.bounds, layout.items, layout.active) catch return error.InvalidSurface;
    if (layout.first != checked.first or layout.visible != checked.visible or layout.tab_width != checked.tab_width or
        layout.arrows != checked.arrows) return error.InvalidSurface;
    // A tab strip cannot paint the title, caption controls, or adjacent client.
    if (layout.bounds.x < 0 or layout.bounds.y < 0 or
        @as(i64, layout.bounds.x) + layout.bounds.width > surface.width or
        @as(i64, layout.bounds.y) + layout.bounds.height > surface.height) return error.InvalidSurface;
    surface.fillRect(@intCast(layout.bounds.x), @intCast(layout.bounds.y), layout.bounds.width, layout.bounds.height, surface.encode(theme.background));
    const dragged = if (state.draggedId()) |id| layout.indexOf(id) else null;
    for (layout.first..layout.first + layout.visible) |index| {
        if (dragged == index) continue;
        const rect = layout.tabRect(index).?;
        try drawTab(surface, rect, layout.items[index], index == layout.active, state, theme);
    }
    if (dragged) |index| {
        const end = if (layout.previousRect()) |rect| rect.x else layout.addRect().x;
        const left = std.math.clamp(@as(i64, state.pointer.x) - state.drag_offset, layout.bounds.x, @as(i64, end) - layout.tab_width);
        const rect: input.Rect = .{ .x = @intCast(left), .y = layout.bounds.y, .width = layout.tab_width, .height = layout.bounds.height };
        try drawTab(surface, rect, layout.items[index], true, state, theme);
        surface.roundedBorder(rect.x, rect.y, rect.width, rect.height, theme.corner_radius, theme.insertion, 1, 64);
        if (state.insertion) |destination| if (layout.tabRect(destination)) |marker| {
            surface.fillRect(@intCast(marker.x), @intCast(marker.y + 2), 2, marker.height - 4, surface.encode(theme.insertion));
        };
    }
    const add = layout.addRect();
    drawControl(surface, add, .add, state, theme);
    const plus_x: u32 = @intCast(add.x + 7);
    const plus_y: u32 = @intCast(add.y + @as(i32, @intCast(add.height / 2)));
    surface.fillRect(plus_x, plus_y, 10, 1, surface.encode(theme.text));
    surface.fillRect(plus_x + 5, plus_y - 5, 1, 11, surface.encode(theme.text));
    if (layout.previousRect()) |rect| {
        drawControl(surface, rect, .previous, state, theme);
        try icons.draw(surface, .chevron_left, .{ .x = rect.x + 2, .y = rect.y + @as(i32, @intCast((rect.height - 16) / 2)) }, theme.inactive_text, 1);
    }
    if (layout.nextRect()) |rect| {
        drawControl(surface, rect, .next, state, theme);
        try icons.draw(surface, .chevron_right, .{ .x = rect.x + 2, .y = rect.y + @as(i32, @intCast((rect.height - 16) / 2)) }, theme.inactive_text, 1);
    }
}

fn closeAt(rect: input.Rect, item: Item) ?input.Rect {
    if (!item.closable or rect.width < 24) return null;
    return .{ .x = rect.x + @as(i32, @intCast(rect.width)) - 20, .y = rect.y + @as(i32, @intCast((rect.height - 16) / 2)), .width = 16, .height = 16 };
}
fn drawTab(surface: *Surface, rect: input.Rect, item: Item, active: bool, state: *const State, theme: Theme) Error!void {
    if (active or sameTarget(state.hovered, .{ .tab = item.id })) surface.roundedRect(rect.x, rect.y, rect.width, rect.height, theme.corner_radius, if (active) theme.active else theme.hovered);
    const ink = if (active) theme.text else theme.inactive_text;
    var label_x = rect.x + 8;
    const close = closeAt(rect, item);
    const label_right = if (close) |button| button.x - 4 else rect.x + @as(i32, @intCast(rect.width)) - 6;
    if (item.icon) |icon| {
        if (rect.width >= 40) {
            try icons.draw(surface, icon, .{ .x = rect.x + 4, .y = rect.y + @as(i32, @intCast((rect.height - 16) / 2)) }, theme.icon, 1);
            label_x = rect.x + 26;
        }
    }
    if (label_right > label_x) text(surface, item.label, label_x, try font.controlOriginY(rect.y, rect.height, 1), ink, .{ .x = label_x, .y = rect.y, .width = @intCast(label_right - label_x), .height = rect.height });
    if (close) |button| {
        if (!state.dragging and sameTarget(state.hovered, .{ .close = item.id })) surface.roundedRect(button.x, button.y, button.width, button.height, 3, theme.hovered);
        try icons.draw(surface, .close, .{ .x = button.x, .y = button.y }, ink, 1);
    }
}
fn drawControl(surface: *Surface, rect: input.Rect, target: Target, state: *const State, theme: Theme) void {
    if (sameTarget(state.hovered, target)) surface.roundedRect(rect.x, rect.y, rect.width, rect.height, theme.corner_radius, theme.hovered);
}
fn text(surface: *Surface, bytes: []const u8, x: i32, y: i32, color: types.Color, clip: input.Rect) void {
    var pen = x;
    for (bytes) |byte| {
        const advance = font.glyphAdvance(byte);
        if (pen >= @as(i64, clip.x) + clip.width) break;
        for (0..font.coverage_height) |row| for (0..advance) |column| {
            const px = @as(i64, pen) + @as(i64, @intCast(column));
            const py = @as(i64, y) + @as(i64, @intCast(row));
            if (px < clip.x or py < clip.y or px >= @as(i64, clip.x) + clip.width or py >= @as(i64, clip.y) + clip.height) continue;
            surface.blendPixel(@intCast(px), @intCast(py), color, font.coverage(byte, @intCast(column), @intCast(row), 1));
        };
        pen += @intCast(advance);
    }
}
