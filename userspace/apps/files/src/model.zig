//! The controller owns copied names and paths. A host retains this model and
//! serializes dispatch/render. Provider failures become visible status text.
const std = @import("std");
const ui = @import("axisui");
const api = @import("provider.zig");
const layout = @import("layout.zig");
pub const Pane = struct {
    path: [api.max_path_bytes]u8 = undefined,
    path_len: usize = 0,
    entries: [api.max_entries]api.Entry = undefined,
    count: usize = 0,
    selected: ?usize = null,
    scroll: usize = 0,
    truncated: bool = false,
    pub fn directory(self: *const Pane) []const u8 {
        return self.path[0..self.path_len];
    }
};
pub const Edit = enum { none, new_file, new_folder, rename };
pub const EditButton = enum { confirm, cancel };
pub const Menu = struct {
    kind: layout.MenuKind,
    anchor: ui.Point,
    hovered: ?usize = null,
    pressed: ?usize = null,
};
fn wipe(bytes: []u8) void {
    const target: [*]volatile u8 = @ptrCast(bytes.ptr);
    for (0..bytes.len) |i| target[i] = 0;
}
const Drag = struct { pane: usize, index: usize, origin: ui.Point, moving: bool = false, copy_intent: bool = false };
const Location = struct { bytes: [api.max_path_bytes]u8 = undefined, len: usize = 0 };
pub const history_capacity = 8;
pub const History = struct {
    locations: [history_capacity]Location = undefined,
    count: usize = 0,
    position: usize = 0,
    fn record(self: *History, path: []const u8) void {
        if (self.count != 0 and std.mem.eql(u8, self.locations[self.position].bytes[0..self.locations[self.position].len], path)) return;
        self.count = if (self.count == 0) 0 else self.position + 1;
        if (self.count == history_capacity) {
            std.mem.copyForwards(Location, self.locations[0 .. history_capacity - 1], self.locations[1..history_capacity]);
            self.count -= 1;
        }
        @memcpy(self.locations[self.count].bytes[0..path.len], path);
        self.locations[self.count].len = path.len;
        self.position = self.count;
        self.count += 1;
    }
};
pub const Clipboard = struct {
    source: [api.max_path_bytes]u8 = undefined,
    source_len: usize = 0,
    name: [api.max_name_bytes]u8 = undefined,
    name_len: usize = 0,
    cut: bool = false,
};
pub const Model = struct {
    provider: ?api.Provider = null,
    panes: [2]Pane = .{ .{}, .{} },
    focus: usize = 0,
    split: bool = false,
    histories: [2]History = .{ .{}, .{} },
    clipboard: ?Clipboard = null,
    revision: u64 = 0,
    pointer: ui.Point = .{ .x = 0, .y = 0 },
    drag: ?Drag = null,
    pressed_action: ?layout.Action = null,
    pressed_shortcut: ?layout.Shortcut = null,
    hovered_action: ?layout.Action = null,
    menu: ?Menu = null,
    edit: Edit = .none,
    pressed_edit: ?EditButton = null,
    edit_text: [api.max_name_bytes]u8 = undefined,
    edit_len: usize = 0,
    edit_cursor: usize = 0,
    status: [160]u8 = undefined,
    status_len: usize = 0,
    status_error: bool = false,
    status_notice: bool = false,
    // Persistent transactional listing scratch avoids deep 4-KiB stack frames.
    listing_scratch: [api.max_entries]api.Entry = undefined,
    path_scratch: [2][api.max_path_bytes]u8 = undefined,
    initialized: bool = false,
    preview_open: bool = false,
    preview: [512]u8 = undefined,
    preview_len: usize = 0,
    preview_name: [api.max_name_bytes]u8 = undefined,
    preview_name_len: usize = 0,
    preview_path: [api.max_path_bytes]u8 = undefined,
    preview_path_len: usize = 0,

    pub fn init(self: *Model, provider: api.Provider, left: []const u8, right: []const u8) !void {
        try api.validatePath(left);
        try api.validatePath(right);
        self.provider = provider;
        self.focus = 0;
        self.split = false;
        self.clipboard = null;
        self.revision = 0;
        self.drag = null;
        self.pressed_action = null;
        self.pressed_shortcut = null;
        self.hovered_action = null;
        self.menu = null;
        self.edit = .none;
        self.pressed_edit = null;
        self.edit_len = 0;
        self.edit_cursor = 0;
        self.status_len = 0;
        self.pointer = .{ .x = 0, .y = 0 };
        self.initialized = true;
        self.preview_open = false;
        self.preview_len = 0;
        self.preview_name_len = 0;
        self.preview_path_len = 0;
        wipe(&self.preview);
        wipe(&self.preview_name);
        wipe(&self.preview_path);
        for (&self.panes, &self.histories, [_][]const u8{ left, right }) |*pane, *history, path| {
            @memcpy(pane.path[0..path.len], path);
            pane.path_len = path.len;
            pane.count = 0;
            pane.selected = null;
            pane.scroll = 0;
            pane.truncated = false;
            history.count = 0;
            history.record(path);
        }
        self.setStatus("Ready", false);
        self.reload(0) catch |err| self.fail(err);
        self.reload(1) catch |err| self.fail(err);
    }
    pub fn statusText(self: *const Model) []const u8 {
        return self.status[0..self.status_len];
    }
    pub fn editText(self: *const Model) []const u8 {
        return self.edit_text[0..self.edit_len];
    }
    pub fn previewText(self: *const Model) []const u8 {
        return self.preview[0..self.preview_len];
    }
    pub fn closePreview(self: *Model) void {
        self.preview_open = false;
        self.setStatus("Preview closed", false);
    }
    fn changed(self: *Model) void {
        self.revision +|= 1;
    }
    fn setStatus(self: *Model, text: []const u8, failed: bool) void {
        self.status_len = @min(text.len, self.status.len);
        @memcpy(self.status[0..self.status_len], text[0..self.status_len]);
        self.status_error = failed;
        self.status_notice = false;
        self.changed();
    }
    fn fail(self: *Model, err: anyerror) void {
        const message: []const u8 = switch (err) {
            error.PermissionDenied => "You don't have permission for this action.",
            error.ReadOnly => "This item is read-only.",
            error.AlreadyExists => "An item with this name already exists.",
            error.NotFound => "The item is no longer available.",
            error.NoSelection => "Select an item first.",
            error.ClipboardEmpty => "Copy or Cut an item before Paste.",
            error.SamePath => "This item is already in that folder.",
            error.NoHistory => "No more folders in this direction.",
            error.FinishEditing => "Save or cancel the name first.",
            error.DirectoryNotEmpty => "This folder still contains items.",
            error.NotDirectory => "Choose a folder for this action.",
            error.InvalidName => "Choose a name without slashes or control characters.",
            error.NameTooLong => "Names can have at most 96 characters.",
            error.UnsupportedCharacter => "Only ASCII characters are supported for now.",
            error.InvalidPath, error.PathTooLong => "This folder location is not available.",
            error.InvalidListing, error.InvalidEntry => "Could not read this folder's information.",
            error.InvalidRead => "Could not read this file's contents.",
            error.FileTooLarge => "This file is too large for this storage.",
            error.Capacity, error.FileCapacity, error.NodeCapacity, error.OutOfMemory => "There is not enough space for this action.",
            error.Unsupported => "This action is not available.",
            else => "Could not complete this action. Storage may need recovery.",
        };
        self.setStatus(message, true);
    }
    pub fn reload(self: *Model, index: usize) !void {
        if (!self.initialized or index >= 2) return error.NotInitialized;
        self.dismissMenu();
        const provider = self.provider.?;
        var cursor: usize = 0;
        var count: usize = 0;
        var truncated = false;
        while (true) {
            const before = cursor;
            const entry = try provider.list(provider.context, self.panes[index].directory(), &cursor) orelse break;
            if (cursor <= before or entry.name_len > api.max_name_bytes) return error.InvalidListing;
            try api.validateName(entry.bytes());
            for (self.listing_scratch[0..count]) |*previous| if (std.mem.eql(u8, previous.bytes(), entry.bytes())) return error.InvalidListing;
            if (count == api.max_entries) {
                truncated = true;
                break;
            }
            self.listing_scratch[count] = entry;
            count += 1;
        }
        const pane = &self.panes[index];
        @memcpy(pane.entries[0..count], self.listing_scratch[0..count]);
        pane.count = count;
        pane.selected = null;
        pane.scroll = 0;
        pane.truncated = truncated;
        self.drag = null;
        self.pressed_action = null;
        self.pressed_shortcut = null;
        self.changed();
    }
    fn join(self: *Model, scratch: usize, directory: []const u8, name: []const u8) ![]const u8 {
        try api.validateName(name);
        const separator: usize = if (directory.len == 1) 0 else 1;
        const total = directory.len + separator + name.len;
        if (total > api.max_path_bytes) return error.PathTooLong;
        const output = &self.path_scratch[scratch];
        @memcpy(output[0..directory.len], directory);
        if (separator != 0) output[directory.len] = '/';
        @memcpy(output[directory.len + separator .. total], name);
        return output[0..total];
    }
    fn selected(self: *const Model, pane: usize) !*const api.Entry {
        const index = self.panes[pane].selected orelse return error.NoSelection;
        if (index >= self.panes[pane].count) return error.NoSelection;
        return &self.panes[pane].entries[index];
    }
    pub fn dismissMenu(self: *Model) void {
        if (self.menu != null) {
            self.menu = null;
            self.hovered_action = null;
            self.changed();
        }
    }
    fn openMenu(self: *Model, kind: layout.MenuKind, anchor: ui.Point) void {
        self.drag = null;
        self.pressed_action = null;
        self.pressed_shortcut = null;
        self.pressed_edit = null;
        self.hovered_action = null;
        self.menu = .{ .kind = kind, .anchor = anchor };
        self.changed();
    }
    pub fn menuEnabled(self: *const Model, action_value: layout.Action) bool {
        if (!self.initialized or self.edit != .none or self.preview_open) return false;
        const provider = self.provider.?;
        const entry = self.selected(self.focus) catch null;
        const writable_directory = std.mem.eql(u8, self.panes[self.focus].directory(), "/container") or std.mem.startsWith(u8, self.panes[self.focus].directory(), "/container/");
        return switch (action_value) {
            .open => if (entry) |value| value.kind == .directory or provider.read != null or provider.open != null else false,
            .new_folder => writable_directory and provider.mkdir != null,
            .new_file => writable_directory and provider.create != null,
            .copy => entry != null and provider.copy != null,
            .move, .rename => if (entry) |value| !value.read_only and provider.move != null else false,
            .remove => if (entry) |value| !value.read_only and provider.remove != null else false,
            .nullify => if (entry) |value| value.kind == .file and !value.read_only and provider.nullify != null else false,
            .paste => writable_directory and if (self.clipboard) |clip| (if (clip.cut) provider.move != null else provider.copy != null) else false,
            .refresh, .split => true,
            else => false,
        };
    }
    fn clearRetainedFile(self: *Model, path: []const u8) void {
        if (std.mem.eql(u8, path, self.preview_path[0..self.preview_path_len])) {
            wipe(&self.preview);
            wipe(&self.preview_name);
            wipe(&self.preview_path);
            self.preview_len = 0;
            self.preview_name_len = 0;
            self.preview_path_len = 0;
            self.preview_open = false;
        }
        if (self.clipboard) |*clip| {
            if (std.mem.eql(u8, path, clip.source[0..clip.source_len])) {
                wipe(&clip.source);
                wipe(&clip.name);
                self.clipboard = null;
            }
        }
    }
    fn nullifySelected(self: *Model) !void {
        const entry = try self.selected(self.focus);
        if (entry.kind != .file) return error.Unsupported;
        if (entry.read_only) return error.ReadOnly;
        const provider = self.provider.?;
        const callback = provider.nullify orelse return error.Unsupported;
        const path = try self.join(0, self.panes[self.focus].directory(), entry.bytes());
        callback(provider.context, path) catch {
            // An I/O failure may follow a committed deletion. Do not retry or
            // retain an app preview of a potentially nullified file.
            self.clearRetainedFile(path);
            self.refreshBoth();
            self.setStatus("Nullify incomplete: storage may need recovery.", true);
            return;
        };
        self.clearRetainedFile(path);
        self.refreshBoth();
        self.setStatus("File nullified in Bedrock", false);
        self.status_notice = true;
    }
    fn handleMenu(self: *Model, event: ui.Event, geometry: layout.Geometry) !bool {
        const menu = if (self.menu) |*value| value else return false;
        const bounds = try layout.MenuGeometry.init(geometry.width, geometry.height, menu.kind, menu.anchor);
        const point: ui.Point = .{ .x = event.x, .y = event.y };
        switch (event.kind) {
            .pointer_move => {
                self.pointer = point;
                const index = bounds.itemAt(point);
                if (menu.hovered != index) {
                    menu.hovered = index;
                    self.changed();
                }
            },
            .pointer_down => {
                if (event.code != @backingInt(ui.input.Button.left)) {
                    self.dismissMenu();
                    return false;
                }
                if (!bounds.rect.contains(point)) {
                    self.dismissMenu();
                    return true;
                }
                const index = bounds.itemAt(point);
                menu.pressed = if (index) |i| (if (self.menuEnabled(layout.menuActions(menu.kind)[i])) i else null) else null;
                self.changed();
            },
            .pointer_up => {
                if (event.code != @backingInt(ui.input.Button.left)) return true;
                const pressed = menu.pressed;
                menu.pressed = null;
                const index = bounds.itemAt(point);
                if (pressed != null and pressed == index) {
                    const action_value = layout.menuActions(menu.kind)[pressed.?];
                    const enabled = self.menuEnabled(action_value);
                    self.dismissMenu();
                    if (enabled) {
                        if (action_value == .nullify) try self.nullifySelected() else try self.perform(action_value);
                    }
                } else if (!bounds.rect.contains(point)) self.dismissMenu();
                self.changed();
            },
            .key_down, .text, .wheel => {
                // Keyboard navigation, refresh and scrolling invalidate the
                // targeted listing; no keyboard shortcut invokes Nullify.
                self.dismissMenu();
                if (event.kind == .key_down and event.code == @backingInt(ui.input.Key.escape)) return true;
                return false;
            },
            .key_up => {},
            .redraw => unreachable,
        }
        return true;
    }
    fn refreshBoth(self: *Model) void {
        self.reload(0) catch |err| self.fail(err);
        self.reload(1) catch |err| self.fail(err);
    }
    fn transfer(self: *Model, source_pane: usize, destination_pane: usize, directory: []const u8, copy: bool) !void {
        const entry = try self.selected(source_pane);
        if (!copy and entry.read_only) return error.ReadOnly;
        const source = try self.join(0, self.panes[source_pane].directory(), entry.bytes());
        const destination = try self.join(1, directory, entry.bytes());
        if (std.mem.eql(u8, source, destination)) return error.SamePath;
        const provider = self.provider.?;
        if (copy) {
            const callback = provider.copy orelse return error.Unsupported;
            try callback(provider.context, source, destination);
        } else {
            const callback = provider.move orelse return error.Unsupported;
            try callback(provider.context, source, destination);
        }
        _ = destination_pane;
        self.setStatus(if (copy) "Copied" else "Moved", false);
        self.refreshBoth();
    }
    fn beginEdit(self: *Model, edit: Edit) !void {
        self.pressed_edit = null;
        self.edit = edit;
        self.edit_len = 0;
        self.edit_cursor = 0;
        if (edit == .rename) {
            const entry = self.selected(self.focus) catch |err| {
                self.edit = .none;
                return err;
            };
            if (entry.read_only) {
                self.edit = .none;
                return error.ReadOnly;
            }
            @memcpy(self.edit_text[0..entry.name_len], entry.bytes());
            self.edit_len = entry.name_len;
        }
        self.edit_cursor = self.edit_len;
        self.setStatus("Type an ASCII name; Enter confirms, Escape cancels", false);
    }
    fn commitEdit(self: *Model) !void {
        try api.validateName(self.editText());
        const target = try self.join(1, self.panes[self.focus].directory(), self.editText());
        const provider = self.provider.?;
        switch (self.edit) {
            .new_file => {
                const cb = provider.create orelse return error.Unsupported;
                try cb(provider.context, target);
            },
            .new_folder => {
                const cb = provider.mkdir orelse return error.Unsupported;
                try cb(provider.context, target);
            },
            .rename => {
                const entry = try self.selected(self.focus);
                if (entry.read_only) return error.ReadOnly;
                const source = try self.join(0, self.panes[self.focus].directory(), entry.bytes());
                const cb = provider.move orelse return error.Unsupported;
                if (std.mem.eql(u8, source, target)) {
                    self.edit = .none;
                    self.setStatus("Name unchanged", false);
                    return;
                }
                try cb(provider.context, source, target);
            },
            .none => return,
        }
        self.edit = .none;
        self.setStatus("Saved", false);
        self.refreshBoth();
    }
    pub fn action(self: *Model, action_value: layout.Action) void {
        if (!self.initialized) return;
        self.dismissMenu();
        self.drag = null;
        self.pressed_action = null;
        self.pressed_shortcut = null;
        self.perform(action_value) catch |err| self.fail(err);
    }
    pub fn shortcut(self: *Model, target: layout.Shortcut) void {
        if (!self.initialized) return;
        self.dismissMenu();
        if (self.edit != .none) {
            self.fail(error.FinishEditing);
            return;
        }
        self.preview_open = false;
        self.navigate(self.focus, layout.shortcutPath(target)) catch |err| self.fail(err);
    }
    fn captureClipboard(self: *Model, cut: bool) !void {
        const entry = try self.selected(self.focus);
        if (cut and entry.read_only) return error.ReadOnly;
        const source = try self.join(0, self.panes[self.focus].directory(), entry.bytes());
        self.clipboard = .{ .cut = cut, .source_len = source.len, .name_len = entry.name_len };
        @memcpy(self.clipboard.?.source[0..source.len], source);
        @memcpy(self.clipboard.?.name[0..entry.name_len], entry.bytes());
        self.setStatus(if (cut) "Cut: navigate to a folder and Paste" else "Copied: navigate to a folder and Paste", false);
    }
    fn paste(self: *Model) !void {
        const clip = if (self.clipboard) |*value| value else return error.ClipboardEmpty;
        const source = clip.source[0..clip.source_len];
        const destination = try self.join(1, self.panes[self.focus].directory(), clip.name[0..clip.name_len]);
        if (std.mem.eql(u8, source, destination)) return error.SamePath;
        const provider = self.provider.?;
        if (clip.cut) {
            const cb = provider.move orelse return error.Unsupported;
            try cb(provider.context, source, destination);
            self.clipboard = null;
        } else {
            const cb = provider.copy orelse return error.Unsupported;
            try cb(provider.context, source, destination);
        }
        self.setStatus("Pasted", false);
        self.refreshBoth();
    }
    pub fn canBack(self: *const Model) bool {
        return self.histories[self.focus].position != 0;
    }
    pub fn canUp(self: *const Model) bool {
        if (!self.initialized) return false;
        const path = self.panes[self.focus].directory();
        return path.len > 1 and !std.mem.eql(u8, path, "/container") and !std.mem.eql(u8, path, "/bundle");
    }
    pub fn canForward(self: *const Model) bool {
        const history = &self.histories[self.focus];
        return history.position + 1 < history.count;
    }
    fn traverseHistory(self: *Model, forward: bool) !void {
        const history = &self.histories[self.focus];
        if (forward and !self.canForward() or !forward and !self.canBack()) return error.NoHistory;
        const target = if (forward) history.position + 1 else history.position - 1;
        const location = &history.locations[target];
        try self.visit(self.focus, location.bytes[0..location.len], false);
        history.position = target;
    }
    fn perform(self: *Model, action_value: layout.Action) !void {
        if (self.edit != .none) return error.FinishEditing;
        switch (action_value) {
            // Destructive Nullify is available only through a matched menu
            // press/release, never an ordinary shortcut or programmatic action.
            .nullify => return error.Unsupported,
            .more => self.openMenu(.more, .{ .x = 0, .y = 36 }),
            .open => try self.openSelected(),
            .new_file => try self.beginEdit(.new_file),
            .new_folder => try self.beginEdit(.new_folder),
            .rename => try self.beginEdit(.rename),
            .refresh => self.refreshBoth(),
            .copy, .move => try self.captureClipboard(action_value == .move),
            .paste => try self.paste(),
            .back => try self.traverseHistory(false),
            .forward => try self.traverseHistory(true),
            .split => {
                self.split = !self.split;
                if (!self.split) self.focus = 0;
                self.setStatus(if (self.split) "Split view" else "Single view", false);
            },
            .remove => {
                const entry = try self.selected(self.focus);
                if (entry.read_only) return error.ReadOnly;
                const path = try self.join(0, self.panes[self.focus].directory(), entry.bytes());
                const provider = self.provider.?;
                const cb = provider.remove orelse return error.Unsupported;
                try cb(provider.context, path);
                self.setStatus("Removed", false);
                self.refreshBoth();
            },
            .up => {
                if (self.preview_open) {
                    self.closePreview();
                    return;
                }
                if (!self.canUp()) return;
                const path = self.panes[self.focus].directory();
                const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse unreachable;
                try self.navigate(self.focus, path[0..@max(slash, 1)]);
            },
        }
    }
    pub fn navigate(self: *Model, pane_index: usize, path: []const u8) !void {
        self.dismissMenu();
        try self.visit(pane_index, path, true);
    }
    fn visit(self: *Model, pane_index: usize, path: []const u8, record_history: bool) !void {
        if (!self.initialized or pane_index >= 2) return error.NotInitialized;
        try api.validatePath(path);
        // Stage path in scratch; list succeeds before committing the new directory.
        const pane = &self.panes[pane_index];
        var saved: [api.max_path_bytes]u8 = undefined;
        const saved_len = pane.path_len;
        @memcpy(saved[0..saved_len], pane.directory());
        std.mem.copyForwards(u8, pane.path[0..path.len], path);
        pane.path_len = path.len;
        self.reload(pane_index) catch |err| {
            @memcpy(pane.path[0..saved_len], saved[0..saved_len]);
            pane.path_len = saved_len;
            return err;
        };
        if (record_history) self.histories[pane_index].record(pane.directory());
        self.drag = null;
        self.edit = .none;
        self.setStatus("Directory opened", false);
    }
    fn openSelected(self: *Model) !void {
        const entry = try self.selected(self.focus);
        const path = try self.join(0, self.panes[self.focus].directory(), entry.bytes());
        if (entry.kind == .directory) try self.navigate(self.focus, path) else {
            const provider = self.provider.?;
            if (provider.read) |read| {
                const length = try read(provider.context, path, 0, &self.preview);
                if (length > self.preview.len) return error.InvalidRead;
                for (self.preview[0..length]) |*byte| {
                    if ((byte.* < 32 and byte.* != '\n' and byte.* != '\r' and byte.* != '\t') or byte.* > 126) byte.* = '?';
                }
                self.preview_len = length;
                @memcpy(self.preview_name[0..entry.name_len], entry.bytes());
                self.preview_name_len = entry.name_len;
                @memcpy(self.preview_path[0..path.len], path);
                self.preview_path_len = path.len;
                self.preview_open = true;
                self.setStatus("Read-only preview / first 512 bytes / Escape or Up closes", false);
                return;
            }
            const cb = provider.open orelse return error.Unsupported;
            try cb(provider.context, path);
            self.setStatus("Opened", false);
        }
    }
    fn rowAt(self: *const Model, geometry: layout.Geometry, pane_index: usize, point: ui.Point) ?usize {
        const rect = geometry.list(pane_index);
        if (!rect.contains(point)) return null;
        const index = self.panes[pane_index].scroll + @as(usize, @intCast(point.y - rect.y)) / layout.row_height;
        return if (index < self.panes[pane_index].count) index else null;
    }
    fn moveSelection(self: *Model, amount: i32, geometry: layout.Geometry) void {
        const pane = &self.panes[self.focus];
        if (pane.count == 0) return;
        const current: i64 = @intCast(pane.selected orelse 0);
        const index: usize = @intCast(std.math.clamp(current + amount, 0, @as(i64, @intCast(pane.count - 1))));
        pane.selected = index;
        if (index < pane.scroll) pane.scroll = index;
        if (index >= pane.scroll + geometry.visible_rows) pane.scroll = index + 1 - geometry.visible_rows;
        self.changed();
    }
    fn keyboard(self: *Model, event: ui.Event, geometry: layout.Geometry) !void {
        if (event.kind == .key_down or event.kind == .text) {
            self.drag = null;
            self.pressed_action = null;
            self.pressed_shortcut = null;
            self.pressed_edit = null;
        }
        if (event.kind == .text) {
            if (self.edit == .none) return;
            if (event.modifiers & (ui.input.modifiers.control | ui.input.modifiers.alt | ui.input.modifiers.super) != 0) return;
            if (event.code < 32 or event.code > 126) return error.UnsupportedCharacter;
            if (event.code == '/' or event.code == '\\') return error.InvalidName;
            if (self.edit_len == api.max_name_bytes) return error.NameTooLong;
            std.mem.copyBackwards(u8, self.edit_text[self.edit_cursor + 1 .. self.edit_len + 1], self.edit_text[self.edit_cursor..self.edit_len]);
            self.edit_text[self.edit_cursor] = @intCast(event.code);
            self.edit_len += 1;
            self.edit_cursor += 1;
            self.changed();
            return;
        }
        if (event.kind != .key_down) return;
        if (self.edit != .none) {
            switch (event.code) {
                @backingInt(ui.input.Key.f5) => self.changed(),
                @backingInt(ui.input.Key.escape) => {
                    self.edit = .none;
                    self.setStatus("Cancelled", false);
                },
                @backingInt(ui.input.Key.enter) => try self.commitEdit(),
                @backingInt(ui.input.Key.left) => {
                    self.edit_cursor -|= 1;
                    self.changed();
                },
                @backingInt(ui.input.Key.right) => {
                    self.edit_cursor = @min(self.edit_cursor + 1, self.edit_len);
                    self.changed();
                },
                @backingInt(ui.input.Key.home) => {
                    self.edit_cursor = 0;
                    self.changed();
                },
                @backingInt(ui.input.Key.end) => {
                    self.edit_cursor = self.edit_len;
                    self.changed();
                },
                @backingInt(ui.input.Key.backspace) => if (self.edit_cursor != 0) {
                    std.mem.copyForwards(u8, self.edit_text[self.edit_cursor - 1 .. self.edit_len - 1], self.edit_text[self.edit_cursor..self.edit_len]);
                    self.edit_cursor -= 1;
                    self.edit_len -= 1;
                    self.changed();
                },
                @backingInt(ui.input.Key.delete) => if (self.edit_cursor < self.edit_len) {
                    std.mem.copyForwards(u8, self.edit_text[self.edit_cursor .. self.edit_len - 1], self.edit_text[self.edit_cursor + 1 .. self.edit_len]);
                    self.edit_len -= 1;
                    self.changed();
                },
                else => {},
            }
            return;
        }
        if (event.modifiers & ui.input.modifiers.control != 0) {
            switch (event.code) {
                'c', 'C' => try self.perform(.copy),
                'x', 'X' => try self.perform(.move),
                'v', 'V' => try self.perform(.paste),
                else => {},
            }
            return;
        }
        if (event.modifiers & ui.input.modifiers.alt != 0) {
            switch (event.code) {
                @backingInt(ui.input.Key.left) => try self.perform(.back),
                @backingInt(ui.input.Key.right) => try self.perform(.forward),
                @backingInt(ui.input.Key.up) => try self.perform(.up),
                else => {},
            }
            return;
        }
        switch (event.code) {
            @backingInt(ui.input.Key.tab) => {
                if (self.split) self.focus = 1 - self.focus;
                self.changed();
            },
            @backingInt(ui.input.Key.up) => self.moveSelection(-1, geometry),
            @backingInt(ui.input.Key.down) => self.moveSelection(1, geometry),
            @backingInt(ui.input.Key.page_up) => self.moveSelection(-@as(i32, @intCast(geometry.visible_rows)), geometry),
            @backingInt(ui.input.Key.page_down) => self.moveSelection(@intCast(geometry.visible_rows), geometry),
            @backingInt(ui.input.Key.home) => self.moveSelection(-@as(i32, api.max_entries), geometry),
            @backingInt(ui.input.Key.end) => self.moveSelection(api.max_entries, geometry),
            @backingInt(ui.input.Key.enter) => try self.openSelected(),
            @backingInt(ui.input.Key.backspace) => try self.perform(.up),
            @backingInt(ui.input.Key.delete) => try self.perform(.remove),
            @backingInt(ui.input.Key.f2) => try self.perform(.rename),
            @backingInt(ui.input.Key.f5) => try self.perform(.refresh),
            else => {},
        }
    }
    pub fn dispatch(self: *Model, event: ui.Event, width: u32, height: u32) !void {
        if (!self.initialized) return error.NotInitialized;
        const geometry = try layout.Geometry.initMode(width, height, self.split);
        self.handle(event, geometry) catch |err| self.fail(err);
    }
    fn handle(self: *Model, event: ui.Event, geometry: layout.Geometry) !void {
        if (event.kind == .redraw) {
            if (event.code == 1) {
                self.dismissMenu();
                self.drag = null;
                self.pressed_action = null;
                self.pressed_shortcut = null;
                self.pressed_edit = null;
            }
            self.changed();
            return;
        }
        const point: ui.Point = .{ .x = event.x, .y = event.y };
        if (try self.handleMenu(event, geometry)) return;
        if (self.preview_open) {
            if (event.kind == .key_down and event.code == @backingInt(ui.input.Key.f5)) self.changed();
            if (event.kind == .key_down and event.code == @backingInt(ui.input.Key.escape)) self.closePreview();
            if (event.kind == .pointer_up and event.code == @backingInt(ui.input.Button.left)) {
                if (geometry.actionAt(point) == .up or geometry.actionAt(point) == .back) self.closePreview();
                if (geometry.shortcutAt(point)) |target| self.shortcut(target);
            }
            return;
        }
        switch (event.kind) {
            .pointer_move => {
                const previous = self.pointer;
                self.pointer = point;
                const hovered = geometry.actionAt(point);
                if (self.hovered_action != hovered) {
                    self.hovered_action = hovered;
                    self.changed();
                }
                if (self.drag) |*drag| {
                    const was_moving = drag.moving;
                    const dx = @abs(@as(i64, point.x) - drag.origin.x);
                    const dy = @abs(@as(i64, point.y) - drag.origin.y);
                    if (dx >= 4 or dy >= 4) drag.moving = true;
                    var new_visual = was_moving != drag.moving or geometry.paneAt(previous) != geometry.paneAt(point) or geometry.shortcutAt(previous) != geometry.shortcutAt(point);
                    for (0..2) |pane| if (self.rowAt(geometry, pane, previous) != self.rowAt(geometry, pane, point)) {
                        new_visual = true;
                    };
                    if (new_visual) self.changed();
                }
            },
            .pointer_down => {
                if (event.code == @backingInt(ui.input.Button.right)) {
                    if (self.edit != .none) return;
                    const pane = geometry.paneAt(point) orelse return;
                    self.focus = pane;
                    const index = self.rowAt(geometry, pane, point);
                    self.panes[pane].selected = index;
                    const kind: layout.MenuKind = if (index) |i| (if (self.panes[pane].entries[i].kind == .file) .file else .directory) else .background;
                    self.openMenu(kind, point);
                    return;
                }
                if (event.code != @backingInt(ui.input.Button.left)) return;
                self.pointer = point;
                self.drag = null;
                self.pressed_action = null;
                self.pressed_shortcut = null;
                if (self.edit != .none) {
                    self.pressed_edit = if (geometry.confirm().contains(point)) .confirm else if (geometry.cancel().contains(point)) .cancel else null;
                    self.changed();
                    return;
                }
                if (geometry.actionAt(point)) |button| {
                    self.pressed_action = button;
                    self.changed();
                    return;
                }
                if (geometry.shortcutAt(point)) |target| {
                    self.pressed_shortcut = target;
                    self.changed();
                    return;
                }
                if (geometry.paneAt(point)) |pane| {
                    self.focus = pane;
                    if (self.rowAt(geometry, pane, point)) |index| {
                        self.panes[pane].selected = index;
                        self.drag = .{ .pane = pane, .index = index, .origin = point, .copy_intent = event.modifiers & ui.input.modifiers.control != 0 };
                    } else self.panes[pane].selected = null;
                    self.changed();
                }
            },
            .pointer_up => {
                if (event.code != @backingInt(ui.input.Button.left)) return;
                self.pointer = point;
                if (self.edit != .none) {
                    const pressed = self.pressed_edit;
                    self.pressed_edit = null;
                    self.changed();
                    if (pressed == .confirm and geometry.confirm().contains(point)) try self.commitEdit();
                    if (pressed == .cancel and geometry.cancel().contains(point)) {
                        self.edit = .none;
                        self.setStatus("Cancelled", false);
                    }
                    return;
                }
                const button = self.pressed_action;
                self.pressed_action = null;
                const shortcut_pressed = self.pressed_shortcut;
                self.pressed_shortcut = null;
                const drag = self.drag;
                self.drag = null;
                self.changed();
                if (button) |pressed| {
                    if (geometry.actionAt(point) == pressed) {
                        if (pressed == .more) {
                            const rect = geometry.button(.more);
                            self.openMenu(.more, .{ .x = rect.x, .y = rect.y + @as(i32, @intCast(rect.height)) });
                        } else try self.perform(pressed);
                    }
                    return;
                }
                if (shortcut_pressed) |pressed| {
                    if (geometry.shortcutAt(point) == pressed) self.shortcut(pressed);
                    return;
                }
                if (drag) |active| {
                    if (active.index >= self.panes[active.pane].count) return;
                    if (!active.moving) {
                        if (event.modifiers & ui.input.modifiers.double_click != 0 and self.rowAt(geometry, active.pane, point) == active.index) {
                            self.focus = active.pane;
                            self.panes[active.pane].selected = active.index;
                            try self.openSelected();
                        }
                        return;
                    }
                    self.panes[active.pane].selected = active.index;
                    if (geometry.shortcutAt(point)) |target| {
                        const directory = layout.shortcutPath(target);
                        if (std.mem.eql(u8, directory, self.panes[active.pane].directory())) return;
                        try self.transfer(active.pane, active.pane, directory, active.copy_intent or event.modifiers & ui.input.modifiers.control != 0);
                        return;
                    }
                    const destination = geometry.paneAt(point) orelse return;
                    var directory = self.panes[destination].directory();
                    var folder: [api.max_path_bytes]u8 = undefined;
                    if (self.rowAt(geometry, destination, point)) |row| {
                        const target = &self.panes[destination].entries[row];
                        if (target.kind != .directory or destination == active.pane and row == active.index) return;
                        {
                            const joined = try self.join(1, directory, target.bytes());
                            @memcpy(folder[0..joined.len], joined);
                            directory = folder[0..joined.len];
                        }
                    } else if (destination == active.pane) return;
                    try self.transfer(active.pane, destination, directory, active.copy_intent or event.modifiers & ui.input.modifiers.control != 0);
                }
            },
            .key_down, .key_up, .text => try self.keyboard(event, geometry),
            .wheel => {
                const pane_index = geometry.paneAt(point) orelse return;
                const pane = &self.panes[pane_index];
                const delta: i16 = @bitCast(event.code);
                const maximum = pane.count - @min(pane.count, geometry.visible_rows);
                pane.scroll = @intCast(std.math.clamp(@as(i64, @intCast(pane.scroll)) + delta, 0, @as(i64, @intCast(maximum))));
                self.changed();
            },
            .redraw => unreachable,
        }
    }
};
