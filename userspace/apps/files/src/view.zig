//! Compact native browser; borrowed views live only through synchronous render.
const std = @import("std");
const ui = @import("axisui");
const api = @import("provider.zig");
const Model = @import("model.zig").Model;
const layout = @import("layout.zig");
const path_edit = @import("path_editor.zig");
const View = ui.View;
const Color = ui.Color;
pub const colors = struct {
    pub const background = Color.rgb(36, 40, 51);
    pub const panel = Color.rgb(45, 49, 63);
    pub const sidebar = Color.rgb(42, 46, 59);
    pub const toolbar = Color.rgb(42, 46, 59);
    pub const text = Color.rgb(233, 235, 243);
    pub const muted = Color.rgb(173, 179, 195);
    pub const accent = Color.rgb(202, 186, 214);
    pub const selected = Color.rgb(63, 60, 78);
    pub const hover = Color.rgb(57, 59, 75);
    pub const border = Color.rgb(79, 83, 101);
    pub const folder = Color.rgb(211, 196, 174);
    pub const document = Color.rgb(185, 198, 219);
    pub const drop = Color.rgb(52, 68, 72);
    pub const error_color = Color.rgb(255, 160, 150);
};
pub const materials = struct {
    pub const client: ui.Material = .{ .tint = colors.background, .opacity = 100 };
    pub const navigation: ui.Material = .{ .tint = colors.toolbar, .opacity = 112 };
    pub const sidebar: ui.Material = .{ .tint = colors.sidebar, .opacity = 130 };
    pub const columns: ui.Material = .{ .tint = colors.toolbar, .opacity = 80 };
    pub const location: ui.Material = .{ .tint = colors.panel, .opacity = 132 };
    pub const footer: ui.Material = .{ .tint = colors.toolbar, .opacity = 96 };
    pub const menu: ui.Material = .{ .tint = colors.panel, .opacity = 170 };
};
pub const Workspace = struct {
    axisui: ui.Workspace,
    rows: [2][api.max_entries + 1]View,
    row_children: [2][api.max_entries][3]View,
    sizes: [2][api.max_entries][24]u8,
    breadcrumb: [api.max_path_bytes * 3 + 16]u8,
    edit_label: [api.max_name_bytes + 32]u8,
    footer: [192]u8,
    preview_text: [1100]u8,
    menu_rows: [10]View,
};
fn text(bytes: []const u8, width: ?u16, height: u16, color: Color, legacy: bool) View {
    var result = ui.Text(bytes);
    result.style = comptime ui.Text("").foreground(colors.text).style;
    result.style.width = width;
    result.style.height = height;
    result.style.foreground_color = color;
    if (!legacy) result.style.text_vertical_alignment = .center;
    return result;
}
fn blank(width: ?u16, height: ?u16) View {
    var result = comptime ui.Spacer().flex(0);
    result.style.width = width;
    result.style.height = height;
    return result;
}
fn button(name: []const u8, action: layout.Action, geometry: layout.Geometry, model: *const Model, legacy: bool) View {
    const rect = geometry.button(action);
    var result = text(name, @intCast(rect.width), 32, colors.text, legacy);
    result = result.smoothCorners();
    result.style.alignment = .center;
    result.style.radius = 4;
    if (model.pressed_action == action) result.style.background_color = colors.selected else if (model.hovered_action == action) result.style.background_color = colors.hover;
    if ((action == .back and !model.canBack() and !model.preview_open) or (action == .up and !model.canUp() and !model.preview_open) or (action == .forward and !model.canForward()) or (action == .paste and model.clipboard == null)) result.style.foreground_color = colors.muted;
    if (model.preview_open and (action == .more or action == .split or action == .forward)) result.style.foreground_color = colors.muted;
    if (action == .split and model.split) result.style.foreground_color = colors.accent;
    return result;
}
fn basename(path: []const u8) []const u8 {
    if (std.mem.eql(u8, path, "/container")) return "Home";
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return path;
    return path[slash + 1 ..];
}
fn location(workspace: *Workspace, model: *const Model, columns: usize) []const u8 {
    if (model.edit != .none) {
        const prefix: []const u8 = switch (model.edit) {
            .new_file => "New file: ",
            .new_folder => "New folder: ",
            .rename => "Rename: ",
            .none => unreachable,
        };
        const visible = @max(1, columns -| (prefix.len + 1));
        const start = model.edit_cursor -| (visible - 1);
        const end = @min(model.edit_len, start + visible);
        @memcpy(workspace.edit_label[0..prefix.len], prefix);
        const before = model.edit_cursor - start;
        @memcpy(workspace.edit_label[prefix.len .. prefix.len + before], model.editText()[start..model.edit_cursor]);
        workspace.edit_label[prefix.len + before] = '|';
        const tail = end - model.edit_cursor;
        @memcpy(workspace.edit_label[prefix.len + before + 1 .. prefix.len + before + 1 + tail], model.editText()[model.edit_cursor..end]);
        return workspace.edit_label[0 .. prefix.len + before + 1 + tail];
    }
    const path = model.panes[model.focus].directory();
    var position: usize = 0;
    var suffix = path;
    if (std.mem.eql(u8, path, "/container") or std.mem.startsWith(u8, path, "/container/")) {
        @memcpy(workspace.breadcrumb[0..4], "Home");
        position = 4;
        suffix = path[10..];
    }
    for (suffix) |byte| {
        if (byte == '/') {
            @memcpy(workspace.breadcrumb[position .. position + 3], " / ");
            position += 3;
        } else {
            workspace.breadcrumb[position] = byte;
            position += 1;
        }
    }
    return workspace.breadcrumb[0..position];
}
fn help(action: layout.Action) []const u8 {
    return switch (action) {
        .back => "Back  /  Alt+Left",
        .forward => "Forward  /  Alt+Right",
        .up => "Parent folder  /  Alt+Up",
        .new_folder => "Create a folder in this location",
        .new_file => "Create an empty file in this location",
        .copy => "Copy selected item  /  Ctrl+C, then Paste",
        .move => "Cut selected item  /  Ctrl+X, then Paste",
        .paste => "Paste into this folder  /  Ctrl+V",
        .rename => "Rename selected item  /  F2",
        .remove => "Delete selected item  /  Delete",
        .refresh => "Refresh folder  /  F5",
        .open => "Open folder or text preview  /  Enter",
        .split => "Toggle a second folder view",
        .more => "File actions",
        .nullify => "Overwrite stored file bytes and delete in Bedrock",
    };
}
pub fn renderWithWorkspace(surface: *ui.Surface, workspace: *Workspace, model: *const Model) !void {
    return renderBody(surface, workspace, model, false);
}
/// Render the translated body and a client-owned location field.
/// Title/control chrome remains under the compositor's authority.
pub fn renderWindowWithWorkspace(surface: *ui.Surface, workspace: *Workspace, model: *const Model, path: ui.Rect) !void {
    _ = try layout.WindowGeometry.init(surface.width, surface.height, model.split, path);
    try surface.validate();
    var body_overlay: Overlay = .{ .parent = surface, .origin = .{ .x = 0, .y = layout.window_header_height } };
    var body = try ui.Surface.initCommands(surface.width, surface.height - layout.window_header_height, body_overlay.sink());
    try renderBody(&body, workspace, model, true);
    if (path.y >= layout.window_header_height and model.edit != .none) return;

    var field_overlay: Overlay = .{ .parent = surface, .origin = .{ .x = path.x, .y = path.y } };
    var field = try ui.Surface.initCommands(path.width, path.height, field_overlay.sink());
    // Reset the location base before coverage blending. Its rectangle belongs
    // to the client; title and window controls remain untouched.
    field.materialRect(0, 0, path.width, path.height, materials.navigation);
    var background = ui.Text("").frame(@intCast(path.width), @intCast(path.height)).cornerRadius(4).smoothCorners().material(materials.location);
    background.style.border_color = if (model.path_editing) colors.accent else colors.border;
    background.style.border_width = 1;
    try ui.renderWithWorkspace(&field, &workspace.axisui, background);

    const width = path.width -| 12;
    if (width == 0) return;
    var text_overlay: Overlay = .{ .parent = surface, .origin = .{ .x = path.x + 6, .y = path.y + @as(i32, @intCast((path.height -| ui.font.line_height) / 2)) } };
    var text_surface = try ui.Surface.initCommands(width, @min(path.height, ui.font.line_height), text_overlay.sink());
    const bytes = model.headerPath();
    const start = if (model.path_editing) model.path_editor.visibleStart(width) else 0;
    var end = start;
    while (end < bytes.len and path_edit.measured(bytes[start .. end + 1]) <= width) : (end += 1) {}
    if (model.path_editing) {
        const selected = model.path_editor.selection();
        const first = @max(start, selected.start);
        const last = @min(end, selected.end);
        if (first < last) {
            const x = path_edit.measured(bytes[start..first]);
            text_surface.fillRect(x, 0, path_edit.measured(bytes[first..last]), text_surface.height, text_surface.encode(colors.selected));
        }
    }
    // Keep selection and caret geometry stable while giving glyph coverage the
    // full field clip: descenders may extend beyond a nominal line box.
    if (surface.legacy_text) {
        try ui.font.paint(&text_surface, bytes[start..end], 0, 0, colors.text, 1);
    } else {
        var glyph_overlay: Overlay = .{ .parent = surface, .origin = .{ .x = path.x + 6, .y = path.y } };
        var glyph_surface = try ui.Surface.initCommands(width, path.height, glyph_overlay.sink());
        try ui.font.paint(&glyph_surface, bytes[start..end], 0, try ui.font.controlOriginY(0, path.height, 1), colors.text, 1);
    }
    if (model.path_editing) {
        const x = @min(width - 1, path_edit.measured(bytes[start..model.path_editor.cursor]));
        text_surface.fillRect(x, 1, 1, text_surface.height -| 2, text_surface.encode(colors.accent));
    }
}
/// Repaint the existing guarded context-menu overlay after a caller-owned app
/// toolbar. It uses the same body geometry and cannot paint service caption
/// pixels. Input stays in Model's existing matched context-menu controller.
pub fn renderWindowMenuWithWorkspace(surface: *ui.Surface, workspace: *Workspace, model: *const Model) !void {
    if (!model.initialized) return error.NotInitialized;
    if (surface.height <= layout.window_header_height) return error.InvalidViewport;
    _ = try layout.Geometry.initMode(surface.width, surface.height - layout.window_header_height, model.split);
    try surface.validate();
    const menu = model.menu orelse return;
    var overlay: Overlay = .{ .parent = surface, .origin = .{ .x = 0, .y = layout.window_header_height } };
    var body = try ui.Surface.initCommands(surface.width, surface.height - layout.window_header_height, overlay.sink());
    body.legacy_text = surface.legacy_text;
    try renderMenu(&body, workspace, model, menu.kind, menu.anchor);
}
fn renderBody(surface: *ui.Surface, workspace: *Workspace, model: *const Model, header_location: bool) !void {
    if (!model.initialized) return error.NotInitialized;
    const geometry = try layout.Geometry.initMode(surface.width, surface.height, model.split);
    const compact_edit = model.edit != .none and !geometry.canSplit();
    const leading_width: u32 = if (compact_edit) 12 else 128;
    const trailing_width: u32 = if (model.edit != .none) 144 else if (geometry.canSplit()) 116 else 64;
    const crumb_width = surface.width - leading_width - trailing_width;
    const location_text = if (header_location and model.edit == .none) "" else location(workspace, model, (crumb_width - 16) / ui.font.advance);
    // Fixed offered width keeps a long breadcrumb from moving action hit areas.
    var crumb = text(location_text, @intCast(crumb_width), 32, if (model.edit != .none) colors.accent else colors.text, surface.legacy_text);
    crumb = crumb.smoothCorners();
    crumb.style.inset = 8;
    crumb = crumb.material(materials.location);
    crumb.style.radius = 4;
    if (header_location and model.edit == .none) crumb = blank(@intCast(crumb_width), 32);
    var nav_items: [13]View = undefined;
    var nav_count: usize = 0;
    if (compact_edit) {
        nav_items[0] = blank(12, null);
        nav_items[1] = crumb;
        nav_count = 2;
    } else {
        const nav_prefix = [_]View{ blank(12, null), button("<", .back, geometry, model, surface.legacy_text), blank(4, null), button(">", .forward, geometry, model, surface.legacy_text), blank(4, null), button("^", .up, geometry, model, surface.legacy_text), blank(12, null), crumb };
        @memcpy(nav_items[0..nav_prefix.len], &nav_prefix);
        nav_count = nav_prefix.len;
    }
    nav_items[nav_count] = blank(4, null);
    nav_count += 1;
    if (model.edit != .none) {
        nav_items[nav_count] = text(if (model.edit == .rename) "Save" else "Create", 64, 32, colors.text, surface.legacy_text);
        nav_items[nav_count].style.alignment = .center;
        nav_items[nav_count].style.radius = 4;
        nav_items[nav_count] = nav_items[nav_count].smoothCorners();
        nav_items[nav_count].style.background_color = if (model.pressed_edit == .confirm) colors.selected else colors.hover;
        nav_count += 1;
        nav_items[nav_count] = blank(4, null);
        nav_count += 1;
        nav_items[nav_count] = text("Cancel", 60, 32, colors.muted, surface.legacy_text);
        nav_items[nav_count].style.alignment = .center;
        nav_items[nav_count].style.radius = 4;
        nav_items[nav_count] = nav_items[nav_count].smoothCorners();
        if (model.pressed_edit == .cancel) nav_items[nav_count].style.background_color = colors.selected;
        nav_count += 1;
    } else {
        if (geometry.canSplit()) {
            nav_items[nav_count] = button(if (geometry.split) "Single" else "Split", .split, geometry, model, surface.legacy_text);
            nav_count += 1;
            nav_items[nav_count] = blank(4, null);
            nav_count += 1;
        }
        nav_items[nav_count] = button("More", .more, geometry, model, surface.legacy_text);
        nav_count += 1;
    }
    nav_items[nav_count] = blank(12, null);
    nav_count += 1;
    var nav = ui.HStack(nav_items[0..nav_count]);
    nav.style = comptime ui.HStack(&.{}).frame(null, 40).@"align"(.center).material(materials.navigation).style;
    var sidebar_children: [6]View = undefined;
    var shortcut_children: [4][2]View = undefined;
    sidebar_children[0] = text("Places", null, 20, colors.muted, surface.legacy_text);
    const shortcut_names = [_][]const u8{ "Home", "Documents", "Downloads", "Desktop" };
    for (shortcut_names, 0..) |name, index| {
        const shortcut: layout.Shortcut = @fromBackingInt(@intCast(index));
        const bounds = geometry.sidebar(shortcut);
        const label_height = if (surface.legacy_text) @min(bounds.height, ui.font.line_height) else bounds.height;
        shortcut_children[index] = .{ blank(32, 16), text(name, null, @intCast(label_height), colors.text, surface.legacy_text) };
        shortcut_children[index][1].style.flex_weight = 1;
        var item = ui.HStack(&shortcut_children[index]);
        item.style = comptime ui.HStack(&.{}).frame(null, 32).@"align"(.center).cornerRadius(6).smoothCorners().style;
        item.style.height = @intCast(bounds.height);
        const path = layout.shortcutPath(shortcut);
        if (std.mem.eql(u8, path, model.panes[model.focus].directory()) or model.pressed_shortcut == shortcut) item.style.background_color = colors.selected;
        if (model.drag) |drag| if (drag.moving and geometry.sidebar(shortcut).contains(model.pointer)) {
            item.style.background_color = colors.drop;
        };
        sidebar_children[index + 1] = item;
    }
    sidebar_children[5] = comptime ui.Spacer();
    var sidebar = ui.VStack(&sidebar_children);
    sidebar.style = comptime ui.VStack(&.{}).frame(148, null).padding(8).gap(4).material(materials.sidebar).style;
    sidebar.style.height = @intCast(geometry.pane_height);
    var column_children: [2][4]View = undefined;
    var row_margins: [2][3]View = undefined;
    var pane_children: [2][2]View = undefined;
    var pane_views: [2]View = undefined;
    const pane_count: usize = if (geometry.split) 2 else 1;
    for (0..pane_count) |pane_index| {
        const pane = &model.panes[pane_index];
        const list_rect = geometry.list(pane_index);
        column_children[pane_index] = .{ blank(8, 28), text(if (geometry.split) basename(pane.directory()) else "Name", null, 28, if (model.focus == pane_index) colors.text else colors.muted, surface.legacy_text), text("Size", 64, 28, colors.muted, surface.legacy_text), blank(8, 28) };
        column_children[pane_index][1].style.flex_weight = 1;
        column_children[pane_index][1].style.inset = @intCast(@min(8, (28 -| ui.font.line_height) / 2));
        column_children[pane_index][2].style.alignment = .end;
        column_children[pane_index][2].style.inset = column_children[pane_index][1].style.inset;
        var column = ui.HStack(&column_children[pane_index]);
        column.style = comptime ui.HStack(&.{}).frame(null, 28).material(materials.columns).style;
        const visible = @min(geometry.visible_rows, pane.count - @min(pane.scroll, pane.count));
        for (0..visible) |row| {
            const index = pane.scroll + row;
            const entry = &pane.entries[index];
            const units = [_][]const u8{ "B", "KB", "MB", "GB", "TB", "PB", "EB" };
            var number = entry.size;
            var unit: usize = 0;
            while (number >= 1024 and unit + 1 < units.len) : (unit += 1) number /= 1024;
            const size_text = if (entry.kind == .directory) "--" else try std.fmt.bufPrint(&workspace.sizes[pane_index][row], "{d} {s}", .{ number, units[unit] });
            workspace.row_children[pane_index][row] = .{ blank(24, 28), text(entry.bytes(), @intCast(list_rect.width - 88), 28, colors.text, surface.legacy_text), text(size_text, 64, 28, colors.muted, surface.legacy_text) };
            workspace.row_children[pane_index][row][1].style.inset = column_children[pane_index][1].style.inset;
            workspace.row_children[pane_index][row][2].style.alignment = .end;
            workspace.row_children[pane_index][row][2].style.inset = column_children[pane_index][1].style.inset;
            var item = ui.HStack(&workspace.row_children[pane_index][row]);
            item.style = comptime ui.HStack(&.{}).frame(null, 28).cornerRadius(8).smoothCorners().style;
            if (pane.selected == index) item.style.background_color = colors.selected;
            if (model.drag) |drag| if (drag.moving and entry.kind == .directory and geometry.row(pane_index, row).contains(model.pointer) and (drag.pane != pane_index or drag.index != index)) {
                item.style.background_color = colors.drop;
            };
            workspace.rows[pane_index][row] = item;
        }
        if (visible == 0) workspace.rows[pane_index][0] = text("This folder is empty", null, 28, colors.muted, surface.legacy_text);
        const used = if (visible == 0) @as(usize, 1) else visible;
        workspace.rows[pane_index][used] = comptime ui.Spacer();
        var rows = ui.VStack(workspace.rows[pane_index][0 .. used + 1]);
        rows.style = comptime ui.VStack(&.{}).padding(8).@"align"(.stretch).style;
        // Top/bottom padding would shift row hits. Horizontal margins are instead
        // supplied as explicit spacers around the unpadded row stack.
        rows.style.inset = 0;
        rows.style.height = @intCast(geometry.pane_height - 28);
        rows.style.width = @intCast(list_rect.width);
        row_margins[pane_index] = .{ blank(8, null), rows, blank(8, null) };
        var row_content = ui.HStack(&row_margins[pane_index]);
        row_content.style.height = @intCast(geometry.pane_height - 28);
        pane_children[pane_index] = .{ column, row_content };
        pane_views[pane_index] = ui.VStack(&pane_children[pane_index]);
        pane_views[pane_index].style.width = @intCast(geometry.pane_width);
        pane_views[pane_index].style.height = @intCast(geometry.pane_height);
    }
    // Rows occupy pane width; text insets leave a complete font line. Icon and
    // selection hit coordinates follow Geometry, with row edges inset explicitly.
    var panes = ui.HStack(pane_views[0..pane_count]);
    panes.style = comptime ui.HStack(&.{}).gap(1).style;
    panes.style.width = @intCast(surface.width - layout.sidebar_width);
    panes.style.height = @intCast(geometry.pane_height);
    var preview_children: [4]View = undefined;
    var content = panes;
    if (model.preview_open) {
        const columns = (surface.width - layout.sidebar_width - 24) / ui.font.advance;
        var count: usize = 0;
        var column: usize = 0;
        for (model.previewText()) |byte| {
            if (byte == '\r') continue;
            if (byte == '\n') {
                workspace.preview_text[count] = '\n';
                count += 1;
                column = 0;
                continue;
            }
            if (column == columns) {
                workspace.preview_text[count] = '\n';
                count += 1;
                column = 0;
            }
            workspace.preview_text[count] = if (byte == '\t') ' ' else byte;
            count += 1;
            column += 1;
        }
        preview_children = .{ text(model.preview_name[0..model.preview_name_len], null, 24, colors.text, surface.legacy_text), text("Read-only preview  /  Escape closes", null, 16, colors.muted, surface.legacy_text), text(if (count == 0) "Empty file" else workspace.preview_text[0..count], null, @intCast(geometry.pane_height - 72), colors.text, surface.legacy_text), comptime ui.Spacer() };
        if (!surface.legacy_text) preview_children[2].style.text_vertical_alignment = .start;
        content = ui.VStack(&preview_children);
        content.style = comptime ui.VStack(&.{}).padding(12).gap(4).style;
        content.style.width = @intCast(surface.width - layout.sidebar_width);
        content.style.height = @intCast(geometry.pane_height);
    } else {
        const bytes: [*]volatile u8 = @ptrCast(&workspace.preview_text);
        for (0..workspace.preview_text.len) |i| bytes[i] = 0;
    }
    const body_children = [_]View{ sidebar, content };
    var body = ui.HStack(&body_children);
    body.style.height = @intCast(geometry.pane_height);
    const menu_hover: ?layout.Action = if (model.menu) |menu| (if (menu.hovered) |index| layout.menuActions(menu.kind)[index] else null) else null;
    const status = if (model.status_error or model.status_notice or model.edit != .none) model.statusText() else if (menu_hover orelse model.hovered_action) |action| help(action) else try std.fmt.bufPrint(&workspace.footer, "{d} {s}{s}{s}", .{ model.panes[model.focus].count, if (model.panes[model.focus].count == 1) "item" else "items", if (model.panes[model.focus].truncated) " / first 32" else "", if (model.clipboard != null) " / clipboard ready" else "" });
    var footer = text(status, null, 24, if (model.status_error) colors.error_color else colors.muted, surface.legacy_text);
    footer.style.inset = @intCast(@min(7, (24 -| ui.font.line_height) / 2));
    footer = footer.material(materials.footer);
    const root_children = [_]View{ nav, body, footer };
    var root = ui.VStack(&root_children);
    root = root.material(materials.client);
    try ui.renderWithWorkspace(surface, &workspace.axisui, root);
    for (0..4) |index| {
        const shortcut: layout.Shortcut = @fromBackingInt(@intCast(index));
        const rect = geometry.sidebar(shortcut);
        try ui.drawIcon(surface, if (shortcut == .home) .home else .folder, .{ .x = rect.x + 8, .y = rect.y + @as(i32, @intCast((rect.height - 16) / 2)) }, if (shortcut == .home) colors.accent else colors.folder, 1);
    }
    if (!model.preview_open) for (0..pane_count) |pane_index| {
        const pane = &model.panes[pane_index];
        const visible = @min(geometry.visible_rows, pane.count - @min(pane.scroll, pane.count));
        for (0..visible) |row| {
            const rect = geometry.row(pane_index, row);
            const entry = &pane.entries[pane.scroll + row];
            try ui.drawIcon(surface, if (entry.kind == .directory) .folder else .document, .{ .x = rect.x + 4, .y = rect.y + 6 }, if (entry.kind == .directory) colors.folder else colors.document, 1);
        }
    };
    if (model.menu) |menu| try renderMenu(surface, workspace, model, menu.kind, menu.anchor);
}

/// Repaint app-owned trailing controls after a custom menu background. Their
/// shared layout still drives hit testing; this never paints trusted captions.
pub fn renderWindowActionsWithWorkspace(surface: *ui.Surface, workspace: *Workspace, model: *const Model) !void {
    if (model.edit != .none) return;
    const geometry = try layout.Geometry.initMode(surface.width, surface.height - layout.window_header_height, model.split);
    for ([_]layout.Action{ .split, .more }) |action| {
        const rect = geometry.button(action);
        if (rect.width == 0 or rect.height == 0) continue;
        var overlay: Overlay = .{ .parent = surface, .origin = .{ .x = rect.x, .y = rect.y + layout.window_header_height } };
        var clipped = try ui.Surface.initCommands(rect.width, rect.height, overlay.sink());
        const label = if (action == .more) "More" else if (model.split) "Single" else "Split";
        try ui.renderWithWorkspace(&clipped, &workspace.axisui, button(label, action, geometry, model, false));
    }
}

pub fn menuLabel(action: layout.Action) []const u8 {
    return switch (action) {
        .open => "Open",
        .new_folder => "New folder",
        .new_file => "New file",
        .copy => "Copy",
        .move => "Cut",
        .paste => "Paste",
        .rename => "Rename",
        .remove => "Delete",
        .nullify => "Nullify (zero + delete)",
        .refresh => "Refresh",
        .split => "Split view",
        else => "",
    };
}
// The overlay is a clipped command surface, including for pixel-backed hosts.
// This keeps the same view tree usable without granting the client scanout.
const Overlay = struct {
    parent: *ui.Surface,
    origin: ui.Point,
    fn sink(self: *Overlay) ui.CommandSink {
        return .{ .context = self, .fillRect = fill, .materialRect = material, .materialPixel = materialPixel, .blendPixel = blend };
    }
    fn fill(context: *anyopaque, x: u32, y: u32, width: u32, height: u32, pixel: u32) void {
        const self: *Overlay = @ptrCast(@alignCast(context));
        const color = Color.rgb(@intCast((pixel >> 16) & 255), @intCast((pixel >> 8) & 255), @intCast(pixel & 255));
        self.parent.fillRect(@as(u32, @intCast(self.origin.x)) + x, @as(u32, @intCast(self.origin.y)) + y, width, height, self.parent.encode(color));
    }
    fn material(context: *anyopaque, x: u32, y: u32, width: u32, height: u32, value: ui.Material) void {
        const self: *Overlay = @ptrCast(@alignCast(context));
        self.parent.materialRect(@as(u32, @intCast(self.origin.x)) + x, @as(u32, @intCast(self.origin.y)) + y, width, height, value);
    }
    fn blend(context: *anyopaque, x: u32, y: u32, pixel: u32, coverage: u8) void {
        const self: *Overlay = @ptrCast(@alignCast(context));
        const color = Color.rgb(@intCast((pixel >> 16) & 255), @intCast((pixel >> 8) & 255), @intCast(pixel & 255));
        self.parent.blendPixel(@as(u32, @intCast(self.origin.x)) + x, @as(u32, @intCast(self.origin.y)) + y, color, coverage);
    }
    fn materialPixel(context: *anyopaque, x: u32, y: u32, value: ui.Material, coverage: u8) void {
        const self: *Overlay = @ptrCast(@alignCast(context));
        self.parent.materialPixel(@as(u32, @intCast(self.origin.x)) + x, @as(u32, @intCast(self.origin.y)) + y, value, coverage);
    }
};
fn renderMenu(surface: *ui.Surface, workspace: *Workspace, model: *const Model, kind: layout.MenuKind, anchor: ui.Point) !void {
    const bounds = try layout.MenuGeometry.init(surface.width, surface.height, kind, anchor);
    const actions = layout.menuActions(kind);
    for (actions, 0..) |action, i| {
        const enabled = model.menuEnabled(action);
        var row = text(if (action == .split and model.split) "Single view" else menuLabel(action), null, @intCast(bounds.row_height), if (!enabled) colors.muted else if (action == .nullify) colors.error_color else colors.text, surface.legacy_text);
        row.style.inset = @intCast(@min(if (bounds.row_height < layout.menu_row_height) @as(u32, 4) else 8, (bounds.row_height -| ui.font.line_height) / 2));
        row.style.radius = 4;
        row = row.smoothCorners();
        if (enabled and model.menu.?.pressed == i) row.style.background_color = colors.selected else if (enabled and model.menu.?.hovered == i) row.style.background_color = colors.hover;
        workspace.menu_rows[i] = row;
    }
    var popup = ui.VStack(workspace.menu_rows[0..actions.len]);
    popup.style = comptime ui.VStack(&.{}).padding(4).cornerRadius(6).smoothCorners().border(colors.border, 1).material(materials.menu).style;
    var overlay: Overlay = .{ .parent = surface, .origin = .{ .x = bounds.rect.x, .y = bounds.rect.y } };
    var clipped = try ui.Surface.initCommands(bounds.rect.width, bounds.rect.height, overlay.sink());
    clipped.legacy_text = surface.legacy_text;
    try ui.renderWithWorkspace(&clipped, &workspace.axisui, popup);
}
