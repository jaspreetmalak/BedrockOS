const ui = @import("axisui");
pub const row_height: u32 = 28;
pub const sidebar_width: u32 = 148;
pub const body_top: u32 = 40;
pub const header_height: u32 = 28;
pub const footer_height: u32 = 24;
pub const minimum_width: u32 = 316;
pub const minimum_height: u32 = 204;
pub const split_minimum_width: u32 = 640;
pub const window_header_height: u32 = 32;
/// A location field may live in the opted-in caption accessory or in the
/// navigation row below it. It must never straddle the trusted caption edge.
pub const WindowGeometry = struct {
    content: Geometry,
    path: ui.Rect,
    pub fn init(width: u32, height: u32, split: bool, path: ui.Rect) !WindowGeometry {
        if (height <= window_header_height or path.x < 0 or path.y < 0 or path.width == 0 or path.height == 0 or
            @as(u64, @intCast(path.x)) + path.width > width) return error.InvalidViewport;
        const bottom = @as(u64, @intCast(path.y)) + path.height;
        if (bottom > window_header_height and (path.y < window_header_height or bottom > window_header_height + body_top)) return error.InvalidViewport;
        return .{ .content = try Geometry.initMode(width, height - window_header_height, split), .path = path };
    }

    pub fn navigationPath(width: u32) error{InvalidViewport}!ui.Rect {
        if (width < minimum_width or width > ui.max_surface_dimension) return error.InvalidViewport;
        const trailing: u32 = if (width >= split_minimum_width) 116 else 64;
        return .{ .x = 128, .y = window_header_height + 4, .width = width - 128 - trailing, .height = 32 };
    }
};
// Existing action values remain compatible with the host's source contract.
pub const Action = enum { up, new_file, new_folder, copy, move, remove, rename, refresh, open, back, forward, split, paste, nullify, more };
pub const Shortcut = enum { home, documents, downloads, desktop };
pub const MenuKind = enum { file, directory, background, more };
const file_actions = [_]Action{ .open, .copy, .move, .paste, .rename, .remove, .nullify, .refresh };
const directory_actions = [_]Action{ .open, .copy, .move, .paste, .rename, .remove, .refresh };
const background_actions = [_]Action{ .new_folder, .new_file, .paste, .refresh, .split };
const more_actions = [_]Action{ .new_folder, .new_file, .copy, .move, .paste, .rename, .remove, .nullify, .refresh, .split };
pub fn menuActions(kind: MenuKind) []const Action {
    return switch (kind) {
        .file => &file_actions,
        .directory => &directory_actions,
        .background => &background_actions,
        .more => &more_actions,
    };
}
pub const menu_width: u32 = 208;
pub const menu_row_height: u32 = 28;
pub const MenuGeometry = struct {
    rect: ui.Rect,
    kind: MenuKind,
    row_height: u32,
    pub fn init(width: u32, height: u32, kind: MenuKind, anchor: ui.Point) !MenuGeometry {
        _ = try Geometry.init(width, height);
        const count: u32 = @intCast(menuActions(kind).len);
        const item_height = @min(menu_row_height, (height - 8) / count);
        const menu_height = count * item_height + 8;
        return .{ .kind = kind, .row_height = item_height, .rect = .{ .x = @intCast(@import("std").math.clamp(@as(i64, anchor.x), 0, width - menu_width)), .y = @intCast(@import("std").math.clamp(@as(i64, anchor.y), 0, height - menu_height)), .width = menu_width, .height = menu_height } };
    }
    pub fn item(self: MenuGeometry, index: usize) ui.Rect {
        if (index >= menuActions(self.kind).len) return .{ .x = 0, .y = 0, .width = 0, .height = 0 };
        return .{ .x = self.rect.x + 4, .y = self.rect.y + 4 + @as(i32, @intCast(index * self.row_height)), .width = menu_width - 8, .height = self.row_height };
    }
    pub fn itemAt(self: MenuGeometry, point: ui.Point) ?usize {
        for (0..menuActions(self.kind).len) |index| if (self.item(index).contains(point)) return index;
        return null;
    }
    pub fn actionIndex(self: MenuGeometry, action: Action) ?usize {
        for (menuActions(self.kind), 0..) |candidate, index| if (candidate == action) return index;
        return null;
    }
};
pub fn shortcutPath(shortcut: Shortcut) []const u8 {
    return switch (shortcut) {
        .home => "/container",
        .documents => "/container/Documents",
        .downloads => "/container/Downloads",
        .desktop => "/container/Desktop",
    };
}
pub const Geometry = struct {
    width: u32,
    height: u32,
    split: bool,
    pane_width: u32,
    pane_height: u32,
    visible_rows: usize,
    pub fn init(width: u32, height: u32) !Geometry {
        return initMode(width, height, false);
    }
    pub fn initMode(width: u32, height: u32, requested_split: bool) !Geometry {
        if (width < minimum_width or height < minimum_height or width > ui.max_surface_dimension or height > ui.max_surface_dimension) return error.InvalidViewport;
        const split = requested_split and width >= split_minimum_width;
        const height_available = height - body_top - footer_height;
        return .{ .width = width, .height = height, .split = split, .pane_width = if (split) (width - sidebar_width - 1) / 2 else width - sidebar_width, .pane_height = height_available, .visible_rows = (height_available - header_height) / row_height };
    }
    pub fn canSplit(self: Geometry) bool {
        return self.width >= split_minimum_width;
    }
    pub fn pane(self: Geometry, index: usize) ui.Rect {
        if (index >= (if (self.split) @as(usize, 2) else 1)) return .{ .x = 0, .y = 0, .width = 0, .height = 0 };
        return .{ .x = @intCast(sidebar_width + index * (self.pane_width + 1)), .y = body_top, .width = self.pane_width, .height = self.pane_height };
    }
    pub fn list(self: Geometry, index: usize) ui.Rect {
        const rect = self.pane(index);
        if (rect.width == 0) return rect;
        return .{ .x = rect.x + 8, .y = rect.y + header_height, .width = rect.width - 16, .height = @intCast(self.visible_rows * row_height) };
    }
    pub fn row(self: Geometry, index: usize, visible_index: usize) ui.Rect {
        const rect = self.list(index);
        if (visible_index >= self.visible_rows or rect.width == 0) return .{ .x = 0, .y = 0, .width = 0, .height = 0 };
        return .{ .x = rect.x, .y = rect.y + @as(i32, @intCast(visible_index * row_height)), .width = rect.width, .height = row_height };
    }
    pub fn sidebar(self: Geometry, shortcut: Shortcut) ui.Rect {
        const count = @typeInfo(Shortcut).@"enum".field_values.len;
        const gap = 4;
        const item_height = @min(32, (self.height - footer_height - 72 - 8 - gap * (count - 1)) / count);
        return .{ .x = 8, .y = @intCast(72 + @as(u32, @backingInt(shortcut)) * (item_height + gap)), .width = 132, .height = item_height };
    }
    pub fn confirm(self: Geometry) ui.Rect {
        return .{ .x = @intCast(self.width - 140), .y = 4, .width = 64, .height = 32 };
    }
    pub fn cancel(self: Geometry) ui.Rect {
        return .{ .x = @intCast(self.width - 72), .y = 4, .width = 60, .height = 32 };
    }
    pub fn button(self: Geometry, action: Action) ui.Rect {
        switch (action) {
            .back => return .{ .x = 12, .y = 4, .width = 32, .height = 32 },
            .forward => return .{ .x = 48, .y = 4, .width = 32, .height = 32 },
            .up => return .{ .x = 84, .y = 4, .width = 32, .height = 32 },
            .split => if (self.canSplit()) return .{ .x = @intCast(self.width - 112), .y = 4, .width = 48, .height = 32 },
            .more => return .{ .x = @intCast(self.width - 60), .y = 4, .width = 48, .height = 32 },
            else => {},
        }
        return .{ .x = 0, .y = 0, .width = 0, .height = 0 };
    }
    pub fn actionAt(self: Geometry, point: ui.Point) ?Action {
        inline for (@typeInfo(Action).@"enum".field_values) |value| {
            const action: Action = @fromBackingInt(@intCast(value));
            if (self.button(action).contains(point)) return action;
        }
        return null;
    }
    pub fn shortcutAt(self: Geometry, point: ui.Point) ?Shortcut {
        inline for (@typeInfo(Shortcut).@"enum".field_values) |value| {
            const shortcut: Shortcut = @fromBackingInt(@intCast(value));
            if (self.sidebar(shortcut).contains(point)) return shortcut;
        }
        return null;
    }
    pub fn paneAt(self: Geometry, point: ui.Point) ?usize {
        for (0..if (self.split) @as(usize, 2) else 1) |i| if (self.pane(i).contains(point)) return i;
        return null;
    }
};
