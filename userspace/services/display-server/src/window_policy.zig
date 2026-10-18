//! PID-owned, bounded native window policy. The adapter owns mappings/scanout.
const std = @import("std");
const ui = @import("axisui");
const windows = @import("window_server");
const abi = @import("bedrock64");
const wire = @import("userspace_runtime").window_wire;

pub const capacity = 6;
pub const shell_index = capacity;
pub const notes_app: u64 = 108;
pub const Error = error{ InvalidPeer, InvalidMessage, StaleFrame, InvalidFrame, ConfigurationExhausted, RegistryFull };
pub const Peer = struct {
    app: u64 = 0,
    pid: u64 = 0,
    configuration: ?wire.Config = null,
    cache_valid: bool = false,
    counter: u32 = 0,
    window_id: u16 = 0,
};
const Connection = struct { app: u64 = 0, pid: u64 = 0, last_id: ?u16 = null };
fn initialPeers() [capacity + 1]Peer {
    var peers: [capacity + 1]Peer = @splat(.{});
    peers[shell_index].app = abi.display.shell;
    return peers;
}
pub const Entry = struct {
    window: windows.Window,
    workspace: u8 = 0,
    title: [16]u8 = @splat(0),
    tile_geometry: ?ui.Rect = null,
    launch_after_close: bool = false,
    previous_click: ui.Point = .{ .x = 0, .y = 0 },
    previous_click_tick: u64 = 0,
    previous_click_valid: bool = false,
};
pub const State = struct { code: u64, app: u64 = 0, aux: u64 = 0 };
pub const Routed = struct { index: usize, event: ui.Event };
pub const Change = struct {
    configure: u8 = 0,
    close: u8 = 0,
    redraw: u8 = 0,
    routed: ?Routed = null,
    /// The cursor moved; scene contents may still be reused when compose is false.
    cursor: bool = false,
    compose: bool = false,
    status: bool = false,
    states: [4]?State = @splat(null),
    fn report(self: *Change, state: State) void {
        for (&self.states) |*slot| if (slot.* == null) {
            slot.* = state;
            return;
        };
    }
};
const Edges = packed struct { left: bool = false, right: bool = false, top: bool = false, bottom: bool = false };
const Resize = struct { index: usize, pointer: ui.Point, geometry: ui.Rect, edges: Edges };

pub fn bit(i: usize) u8 {
    return @as(u8, 1) << @as(u3, @intCast(i));
}
fn shortcutBit(code: u16) u8 {
    return if (code >= '1' and code <= '4') bit(code - '1') else if (code == 't' or code == 'T') 16 else if (code == @backingInt(ui.input.Key.tab)) 32 else 0;
}
pub fn zero(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != 0) return false;
    return true;
}
pub fn titleValid(bytes: []const u8) bool {
    var ended = false;
    for (bytes) |byte| {
        if (byte == 0) {
            ended = true;
            continue;
        }
        if (ended or byte < 32 or byte > 126) return false;
    }
    return bytes.len == 16 and bytes[0] != 0;
}
pub fn queueInput(queue: anytype, event: ui.Event) void {
    if (event.kind == .pointer_move and queue.len != 0) {
        const last = (queue.head + queue.len - 1) % queue.records.len;
        const prior = ui.Event.decode(queue.records[last]) catch unreachable;
        if (prior.kind == .pointer_move and prior.modifiers == event.modifiers) {
            queue.records[last] = event.encode();
            return;
        }
    }
    if (queue.len == queue.records.len) {
        queue.clear();
        queue.push(.{ .kind = .redraw, .code = 1 }) catch unreachable;
    }
    queue.push(event) catch unreachable;
}

pub const Policy = struct {
    screen_width: u32,
    screen_height: u32,
    entries: [capacity]Entry,
    peers: [capacity + 1]Peer = initialPeers(),
    connections: [capacity]Connection = @splat(.{}),
    z_order: [capacity]usize = .{ 0, 1, 2, 3, 4, 5 },
    focused: ?usize = null,
    workspace: u8 = 0,
    tiled: [4]bool = @splat(false),
    configure_sequence: u32 = 0,
    launch_requests: [2]u64 = @splat(0),
    launch_pending: [2]bool = @splat(false),
    closed_counts: [2]u64 = @splat(0),
    cursor: ui.Point = .{ .x = 0, .y = 0 },
    shell_capture: bool = false,
    shell_workspace_press: ?u8 = null,
    resizing: ?Resize = null,
    pointer_press: ui.Point = .{ .x = 0, .y = 0 },
    pointer_moved: bool = false,
    shortcut_down: u8 = 0,

    pub fn init(width: u32, height: u32) !Policy {
        if (width > 1280 or height > 800) return error.InvalidDesktopGeometry;
        var window = try windows.Window.init(width, height);
        window.close();
        return .{ .screen_width = width, .screen_height = height, .entries = @splat(.{ .window = window }) };
    }
    pub fn appIndex(app: u64) Error!usize {
        return switch (app) {
            abi.display.files => 0,
            notes_app => 1,
            else => error.InvalidPeer,
        };
    }
    pub fn slotForApp(self: *const Policy, app: u64) ?usize {
        for (self.peers, 0..) |peer, i| if (peer.app == app and peer.pid != 0) return i;
        for (self.peers, 0..) |peer, i| if (peer.app == app) return i;
        return null;
    }
    pub fn appPid(self: *const Policy, app: u64) u64 {
        for (self.connections) |connection| if (connection.app == app) return connection.pid;
        return 0;
    }
    pub fn slotForWindow(self: *const Policy, app: u64, pid: u64, id: u16) ?usize {
        for (self.peers, 0..) |peer, i| if (peer.app == app and peer.pid == pid and pid != 0 and peer.window_id == id) return i;
        return null;
    }
    pub fn boundWindow(self: *const Policy, app: u64, pid: u64, id: u16) Error!usize {
        return self.slotForWindow(app, pid, id) orelse error.InvalidPeer;
    }
    pub fn boundPeer(self: *const Policy, app: u64, pid: u64) Error!usize {
        if (app == 0 or pid == 0) return error.InvalidPeer;
        for (self.peers, 0..) |peer, i| if (peer.app == app and peer.pid == pid) return i;
        return error.InvalidPeer;
    }
    pub fn visible(self: *const Policy, i: usize) bool {
        return i < capacity and self.peers[i].pid != 0 and self.entries[i].workspace == self.workspace and
            self.entries[i].window.visible and !self.entries[i].window.closed;
    }
    pub fn focusedPid(self: *const Policy) u64 {
        return if (self.focused) |i| self.peers[i].pid else 0;
    }
    pub fn helloShell(self: *Policy, app: u64, pid: u64) Error!bool {
        if (app != abi.display.shell or pid == 0 or (self.peers[shell_index].pid != 0 and self.peers[shell_index].pid != pid)) return error.InvalidPeer;
        if (self.peers[shell_index].pid == pid) return false;
        self.peers[shell_index] = .{ .app = app, .pid = pid };
        try self.configure(shell_index);
        return true;
    }
    pub fn createSlot(self: *const Policy, message: *const abi.ServiceMessage) Error!usize {
        if (message.kind != 9 or message.peer_app == 0 or message.peer_app == abi.display.shell or message.peer_app == abi.display.server or
            message.peer_pid == 0 or message.flags & ~(abi.display.header_content | abi.display.header_tabs | abi.display.window_id_mask) != 0 or message.surface != 0 or message.sequence == 0 or !titleValid(&message.payload) or
            (message.flags & abi.display.header_tabs != 0 and message.flags & abi.display.header_content == 0) or
            ((message.width == 0) != (message.height == 0))) return error.InvalidMessage;
        const id = wire.windowId(message.flags);
        if (id != 0 and message.peer_app != abi.display.files) return error.InvalidPeer;
        var connection_found = false;
        for (self.connections) |connection| {
            if (connection.pid == message.peer_pid and connection.app != message.peer_app) return error.InvalidPeer;
            if (connection.app == message.peer_app and connection.pid != 0) {
                if (connection.pid != message.peer_pid) return error.InvalidPeer;
                connection_found = true;
                if (self.slotForWindow(message.peer_app, message.peer_pid, id)) |i| {
                    if (self.entries[i].window.closed) return error.InvalidPeer;
                    return i;
                }
                if (connection.last_id) |last| if (id <= last) return error.InvalidPeer;
            }
        }
        if (!connection_found and id != 0) return error.InvalidPeer;
        var available: ?usize = null;
        var count: usize = 0;
        for (self.peers[0..capacity], 0..) |peer, i| {
            if (peer.app == message.peer_app and peer.pid != 0) count += 1;
            if (peer.pid == 0 and available == null) available = i;
        }
        if (count >= (if (message.peer_app == abi.display.files) @as(usize, 4) else 1)) return error.RegistryFull;
        return available orelse error.RegistryFull;
    }
    pub fn create(self: *Policy, message: *const abi.ServiceMessage) Error!Change {
        const i = try self.createSlot(message);
        const id = wire.windowId(message.flags);
        var change: Change = .{ .compose = true, .status = true };
        if (self.peers[i].pid == 0) {
            var window = windows.Window.init(self.screen_width, self.screen_height) catch unreachable;
            window.modern_header = true;
            window.header_content = message.flags & abi.display.header_content != 0;
            window.header_tabs = message.flags & abi.display.header_tabs != 0;
            const is_notes = message.peer_app == notes_app;
            window.width = @min(self.screen_width - 96, if (is_notes) @as(u32, 600) else 720);
            window.height = @min(self.screen_height - (if (is_notes) @as(u32, 180) else 140), if (is_notes) @as(u32, 480) else 560);
            window.x = if (is_notes) @intCast(self.screen_width - window.width - 48) else 48;
            window.y = if (is_notes) 112 else 72;
            window.saved_geometry = window.frame();
            self.entries[i] = .{ .window = window, .workspace = self.workspace, .title = message.payload };
            self.peers[i] = .{ .app = message.peer_app, .pid = message.peer_pid, .window_id = id };
            const connection_slot = for (&self.connections) |*connection| {
                if (connection.app == message.peer_app and connection.pid == message.peer_pid) break connection;
            } else for (&self.connections) |*connection| {
                if (connection.pid == 0) break connection;
            } else return error.RegistryFull;
            connection_slot.* = .{ .app = message.peer_app, .pid = message.peer_pid, .last_id = id };
            if (appIndex(message.peer_app)) |a| self.launch_pending[a] = false else |_| {}
        } else {
            if (self.entries[i].window.closed) return error.InvalidPeer;
            self.entries[i].title = message.payload;
            self.entries[i].window.header_content = message.flags & abi.display.header_content != 0;
            self.entries[i].window.header_tabs = message.flags & abi.display.header_tabs != 0;
        }
        if (message.width != 0) self.resizeFrame(i, message.width, message.height);
        self.entries[i].window.open();
        self.entries[i].workspace = self.workspace;
        self.focus(i, &change);
        try self.configureChanged(i, &change);
        try self.retile(&change);
        return change;
    }
    pub fn configure(self: *Policy, i: usize) Error!void {
        if (i >= self.peers.len or self.peers[i].pid == 0) return error.InvalidPeer;
        if (self.configure_sequence == std.math.maxInt(u32)) return error.ConfigurationExhausted;
        self.configure_sequence += 1;
        var rect: ui.Rect = if (i == shell_index) .{ .x = 0, .y = 0, .width = self.screen_width, .height = self.screen_height } else self.entries[i].window.client();
        if (i != shell_index and !self.visible(i)) {
            rect.width = 0;
            rect.height = 0;
        }
        self.peers[i].configuration = .{ .sequence = self.configure_sequence, .width = rect.width, .height = rect.height, .screen_width = self.screen_width, .screen_height = self.screen_height, .origin_x = rect.x, .origin_y = rect.y, .header_content = i < capacity and self.entries[i].window.header_content, .header_tabs = i < capacity and self.entries[i].window.header_tabs, .window_id = self.peers[i].window_id };
        self.peers[i].cache_valid = false;
        self.peers[i].counter = 0;
        if (i < capacity) self.entries[i].previous_click_valid = false;
    }
    fn configureChanged(self: *Policy, i: usize, change: *Change) Error!void {
        try self.configure(i);
        change.configure |= bit(i);
        change.compose = true;
    }
    pub fn configurationMessage(self: *const Policy, i: usize) abi.ServiceMessage {
        const peer = self.peers[i];
        const cfg = peer.configuration.?;
        var message = wire.configure(cfg.sequence, cfg.width, cfg.height, cfg.screen_width, cfg.screen_height, cfg.origin_x, cfg.origin_y);
        message.flags = wire.flagsFor(peer.window_id, (if (cfg.header_content) abi.display.header_content else 0) | (if (cfg.header_tabs) abi.display.header_tabs else 0));
        message.peer_app = peer.app;
        message.peer_pid = peer.pid;
        return message;
    }
    pub fn frame(self: *const Policy, message: *const abi.ServiceMessage) Error!usize {
        const i = try self.boundWindow(message.peer_app, message.peer_pid, wire.windowId(message.flags));
        const peer = self.peers[i];
        const cfg = peer.configuration orelse return error.InvalidFrame;
        const epoch: u32 = @truncate(message.sequence >> 32);
        const counter: u32 = @truncate(message.sequence);
        if (message.kind != abi.display.frame or message.flags & ~abi.display.window_id_mask != 0 or message.surface == 0 or message.width != cfg.screen_width or
            message.height != cfg.screen_height or !zero(&message.payload)) return error.InvalidFrame;
        if (epoch != cfg.sequence or counter == 0 or counter <= peer.counter or cfg.width == 0 or (i < capacity and !self.visible(i))) return error.StaleFrame;
        return i;
    }
    pub fn commitFrame(self: *Policy, i: usize, sequence: u64) void {
        std.debug.assert(@as(u32, @truncate(sequence >> 32)) == self.peers[i].configuration.?.sequence);
        self.peers[i].counter = @truncate(sequence);
        self.peers[i].cache_valid = true;
    }
    pub fn closed(self: *Policy, app: u64, pid: u64) Error!Change {
        var change: Change = .{ .compose = true, .status = true };
        if (app == abi.display.shell) {
            _ = try self.boundWindow(app, pid, 0);
            self.peers[shell_index] = .{ .app = app };
            self.shell_capture = false;
            self.shell_workspace_press = null;
            return change;
        }
        const connection = for (&self.connections) |*value| {
            if (value.app == app and value.pid == pid and pid != 0) break value;
        } else return error.InvalidPeer;
        connection.* = .{};
        var launch_after = false;
        for (self.peers[0..capacity], 0..) |*peer, i| if (peer.app == app and peer.pid == pid) {
            launch_after = launch_after or self.entries[i].launch_after_close;
            self.entries[i].launch_after_close = false;
            self.entries[i].window.close();
            peer.* = .{ .app = app };
            if (self.resizing) |resize| if (resize.index == i) {
                self.resizing = null;
            };
            if (self.focused == i) self.focus(null, &change);
        };
        if (appIndex(app)) |a| {
            self.closed_counts[a] += 1;
            if (launch_after) self.requestLaunch(a);
        } else |_| {}
        self.fallbackFocus(&change);
        try self.retile(&change);
        change.report(.{ .code = 3, .app = app });
        return change;
    }
    pub fn retire(self: *Policy, app: u64, pid: u64, id: u16) Error!Change {
        if (app != abi.display.files) return error.InvalidPeer;
        const i = try self.boundWindow(app, pid, id);
        if (!self.entries[i].window.closed) return error.InvalidMessage;
        self.peers[i] = .{ .app = app };
        self.entries[i].window.close();
        self.entries[i].launch_after_close = false;
        if (self.resizing) |resize| if (resize.index == i) {
            self.resizing = null;
        };
        var change: Change = .{ .compose = true, .status = true };
        if (self.focused == i) self.focus(null, &change);
        self.fallbackFocus(&change);
        try self.retile(&change);
        change.report(.{ .code = 11, .app = if (self.focused) |focused| self.peers[focused].app else 0, .aux = self.focusedPid() });
        return change;
    }
    fn requestLaunch(self: *Policy, a: usize) void {
        if (self.launch_pending[a]) return;
        self.launch_requests[a] += 1;
        self.launch_pending[a] = true;
    }
    pub fn launch(self: *Policy, app: u64, pid: u64, target: u64) Error!Change {
        if (try self.boundPeer(app, pid) != shell_index) return error.InvalidPeer;
        const target_app = if (target == 1) abi.display.files else target;
        const a = try appIndex(target_app);
        var change: Change = .{};
        const i = selected: {
            var minimized: usize = capacity;
            while (minimized != 0) {
                minimized -= 1;
                const candidate = self.z_order[minimized];
                if (self.peers[candidate].app == target_app and self.peers[candidate].pid != 0 and self.entries[candidate].window.minimized and !self.entries[candidate].window.closed) break :selected candidate;
            }
            var n: usize = capacity;
            while (n != 0) {
                n -= 1;
                const candidate = self.z_order[n];
                if (self.peers[candidate].app == target_app and self.peers[candidate].pid != 0 and !self.entries[candidate].window.closed) break :selected candidate;
            }
            const fallback = self.slotForApp(target_app) orelse {
                if (self.appPid(target_app) == 0) self.requestLaunch(a);
                return change;
            };
            break :selected fallback;
        };
        if (self.peers[i].pid == 0 and self.appPid(target_app) == 0) {
            self.requestLaunch(a);
            return change;
        }
        if (self.peers[i].pid == 0) return change;
        if (self.entries[i].window.closed) {
            self.entries[i].launch_after_close = true;
            return change;
        }
        const restore = self.entries[i].window.minimized or self.entries[i].workspace != self.workspace;
        self.entries[i].window.open();
        self.entries[i].workspace = self.workspace;
        self.focus(i, &change);
        if (restore) {
            try self.configureChanged(i, &change);
            change.report(.{ .code = 7, .app = target_app });
        }
        change.redraw |= bit(i);
        change.compose = true;
        try self.retile(&change);
        return change;
    }
    pub fn request(self: *Policy, message: *const abi.ServiceMessage) Error!Change {
        const i = try self.boundWindow(message.peer_app, message.peer_pid, wire.windowId(message.flags));
        if (i >= capacity or message.flags & ~abi.display.window_id_mask != 0 or message.surface != 0 or message.sequence == 0) return error.InvalidMessage;
        if (message.kind == abi.display.retire_window) {
            if (message.width != 0 or message.height != 0 or !zero(&message.payload)) return error.InvalidMessage;
            return self.retire(message.peer_app, message.peer_pid, wire.windowId(message.flags));
        }
        if (self.entries[i].window.closed) return error.InvalidMessage;
        if (message.kind != abi.display.move_window and !zero(&message.payload)) return error.InvalidMessage;
        var change: Change = .{ .compose = true };
        switch (message.kind) {
            10 => {
                if (message.width == 0 or message.height == 0) return error.InvalidMessage;
                self.resizeFrame(i, message.width, message.height);
                try self.configureChanged(i, &change);
                try self.retile(&change);
                change.report(.{ .code = 8, .app = message.peer_app });
            },
            11 => {
                if (message.width != 0 or message.height != 0) return error.InvalidMessage;
                self.entries[i].window.open();
                self.entries[i].workspace = self.workspace;
                self.focus(i, &change);
                try self.configureChanged(i, &change);
                try self.retile(&change);
            },
            12 => {
                if (message.width != 0 or message.height != 0) return error.InvalidMessage;
                self.entries[i].window.close();
                self.peers[i].cache_valid = false;
                change.close |= bit(i);
                if (self.focused == i) self.focus(null, &change);
                self.fallbackFocus(&change);
                try self.retile(&change);
            },
            abi.display.move_window => {
                if (message.width != 0 or message.height != 0 or !zero(message.payload[8..])) return error.InvalidMessage;
                const x = std.mem.readInt(i32, message.payload[0..4], .little);
                const y = std.mem.readInt(i32, message.payload[4..8], .little);
                const window = &self.entries[i].window;
                if (window.mode != .floating or self.tiled[self.workspace]) return error.InvalidMessage;
                cancel(window);
                window.x = std.math.clamp(x, 0, @as(i32, @intCast(self.screen_width - window.width)));
                window.y = std.math.clamp(y, @as(i32, windows.Window.workarea_top), @as(i32, @intCast(self.screen_height - window.height - windows.Window.workarea_bottom)));
                window.saved_geometry = window.frame();
                try self.configureChanged(i, &change);
            },
            else => return error.InvalidMessage,
        }
        return change;
    }
    fn resizeFrame(self: *Policy, i: usize, width: u32, height: u32) void {
        const window = &self.entries[i].window;
        cancel(window);
        window.mode = .floating;
        window.width = std.math.clamp(width, 320, self.screen_width);
        window.height = std.math.clamp(height, 240, self.screen_height - windows.Window.workarea_top - windows.Window.workarea_bottom);
        window.x = std.math.clamp(window.x, 0, @as(i32, @intCast(self.screen_width - window.width)));
        window.y = std.math.clamp(window.y, @as(i32, windows.Window.workarea_top), @as(i32, @intCast(self.screen_height - window.height - windows.Window.workarea_bottom)));
        window.saved_geometry = window.frame();
    }
    fn focus(self: *Policy, selected: ?usize, change: *Change) void {
        const old = self.focused;
        // A press within the already focused client belongs to its current
        // gesture/menu. Sending cancellation here would dismiss a popup before
        // its item press, or clear the client's active drag.
        if (old == selected) return;
        self.focused = selected;
        for (&self.entries, 0..) |*entry, i| entry.window.focused = selected == i;
        if (selected) |i| {
            const position = std.mem.indexOfScalar(usize, &self.z_order, i) orelse unreachable;
            std.mem.copyForwards(usize, self.z_order[position .. capacity - 1], self.z_order[position + 1 .. capacity]);
            self.z_order[capacity - 1] = i;
            change.redraw |= bit(i);
        }
        if (old) |i| if (self.peers[i].pid != 0 and !self.entries[i].window.closed) {
            change.redraw |= bit(i);
        };
        if (old != selected) {
            change.compose = true;
            change.status = true;
            change.report(.{ .code = 11, .app = if (selected) |i| self.peers[i].app else 0, .aux = self.focusedPid() });
        }
    }
    fn fallbackFocus(self: *Policy, change: *Change) void {
        if (self.focused) |i| if (self.visible(i)) return;
        var n: usize = capacity;
        while (n != 0) {
            n -= 1;
            const i = self.z_order[n];
            if (self.visible(i)) {
                self.focus(i, change);
                return;
            }
        }
        self.focus(null, change);
    }
    fn cancelAll(self: *Policy, change: *Change) void {
        for (&self.entries, 0..) |*entry, i| {
            cancel(&entry.window);
            if (self.peers[i].pid != 0) change.redraw |= bit(i);
        }
        self.resizing = null;
        self.shell_capture = false;
        self.shell_workspace_press = null;
    }
    fn retile(self: *Policy, change: *Change) Error!void {
        if (!self.tiled[self.workspace]) return;
        var slots: [capacity]usize = undefined;
        var count: usize = 0;
        // Registry order gives each eligible window a stable column. Z-order
        // changes only which window paints on top when focus changes.
        for (0..capacity) |i| if (self.visible(i) and self.entries[i].window.mode == .floating) {
            slots[count] = i;
            count += 1;
        };
        if (count == 0) return;
        const available_height = self.screen_height - windows.Window.workarea_top - windows.Window.workarea_bottom;
        const columns = @min(count, self.screen_width / 320);
        const rows = @min((count + columns - 1) / columns, available_height / 240);
        for (slots[0..count], 0..) |i, ordinal| {
            // More windows than the physical minimum-size grid can hold keep
            // their floating geometry and remain fully usable above the grid.
            if (ordinal >= columns * rows) {
                if (self.entries[i].tile_geometry != null) {
                    self.restoreTileGeometry(i);
                    try self.configureChanged(i, change);
                }
                continue;
            }
            const column = ordinal % columns;
            const row = ordinal / columns;
            if (self.entries[i].tile_geometry == null) self.entries[i].tile_geometry = self.entries[i].window.saved_geometry;
            const left: u32 = @intCast(column * self.screen_width / columns);
            const right: u32 = @intCast((column + 1) * self.screen_width / columns);
            const top: u32 = windows.Window.workarea_top + @as(u32, @intCast(row * available_height / rows));
            const bottom: u32 = windows.Window.workarea_top + @as(u32, @intCast((row + 1) * available_height / rows));
            const rect: ui.Rect = .{ .x = @intCast(left), .y = @intCast(top), .width = right - left, .height = bottom - top };
            if (!std.meta.eql(self.entries[i].window.frame(), rect)) {
                cancel(&self.entries[i].window);
                setFrame(&self.entries[i].window, rect);
                try self.configureChanged(i, change);
            }
        }
    }
    pub fn switchWorkspace(self: *Policy, workspace: u8, move: bool) Error!Change {
        if (workspace >= 4) return error.InvalidMessage;
        var change: Change = .{};
        if (move) {
            const i = self.focused orelse return change;
            if (self.entries[i].workspace == workspace) return change;
            self.cancelAll(&change);
            self.entries[i].workspace = workspace;
            if (!self.tiled[workspace]) self.restoreTileGeometry(i);
            try self.configureChanged(i, &change);
            self.focus(null, &change);
            self.fallbackFocus(&change);
        } else {
            if (self.workspace == workspace) return change;
            self.cancelAll(&change);
            self.workspace = workspace;
            self.focus(null, &change);
            for (0..capacity) |i| if (self.peers[i].pid != 0) {
                try self.configureChanged(i, &change);
            };
            self.fallbackFocus(&change);
        }
        try self.retile(&change);
        change.compose = true;
        change.status = true;
        change.report(.{ .code = 9, .aux = self.workspace });
        return change;
    }
    pub fn setTiled(self: *Policy, enabled: bool) Error!Change {
        return if (self.tiled[self.workspace] == enabled) .{} else self.toggleTile();
    }
    /// Trusted system overlays cancel app captures before taking pointer input.
    pub fn cancelGestures(self: *Policy) Change {
        var change: Change = .{};
        // An intervening trusted overlay ends a click sequence as well as a
        // drag. Its next app click must not become an obsolete double-click.
        for (&self.entries) |*entry| entry.previous_click_valid = false;
        self.cancelAll(&change);
        return change;
    }
    fn toggleTile(self: *Policy) Error!Change {
        var change: Change = .{ .compose = true, .status = true };
        self.cancelAll(&change);
        self.tiled[self.workspace] = !self.tiled[self.workspace];
        if (self.tiled[self.workspace]) {
            for (&self.entries, 0..) |*entry, i| if (self.visible(i) and entry.window.mode == .floating) {
                entry.tile_geometry = entry.window.frame();
                entry.window.saved_geometry = entry.window.frame();
            };
            try self.retile(&change);
        } else {
            for (&self.entries, 0..) |*entry, i| if (self.peers[i].pid != 0 and entry.workspace == self.workspace and entry.tile_geometry != null) {
                self.restoreTileGeometry(i);
                try self.configureChanged(i, &change);
            };
        }
        change.report(.{ .code = 10, .aux = @intFromBool(self.tiled[self.workspace]) });
        return change;
    }
    fn restoreTileGeometry(self: *Policy, i: usize) void {
        const entry = &self.entries[i];
        const geometry = entry.tile_geometry orelse return;
        entry.window.saved_geometry = geometry;
        if (entry.window.mode == .floating) setFrame(&entry.window, geometry);
        entry.tile_geometry = null;
    }
    fn cycle(self: *Policy) Change {
        var change: Change = .{};
        self.cancelAll(&change);
        // Select the next eligible slot without depending on its app identity.
        const start = if (self.focused) |i| (i + 1) % capacity else 0;
        for (0..capacity) |n| {
            const i = (start + n) % capacity;
            if (self.visible(i)) {
                self.focus(i, &change);
                break;
            }
        }
        return change;
    }
    fn topAt(self: *const Policy, point: ui.Point) ?usize {
        var n: usize = capacity;
        while (n != 0) {
            n -= 1;
            const i = self.z_order[n];
            if (self.visible(i) and self.entries[i].window.frame().contains(point)) return i;
        }
        return null;
    }
    fn capture(self: *const Policy) ?usize {
        if (self.resizing) |resize| return resize.index;
        for (self.entries, 0..) |entry, i| if (self.visible(i) and (entry.window.capture or entry.window.drag != null or entry.window.pressed_control != null)) return i;
        return null;
    }
    /// Physical input bookkeeping also runs for events consumed by trusted
    /// overlays. It can repaint the cursor or clear release latches, but never
    /// routes client input, changes focus, launches an app or applies a command.
    pub fn observeInput(self: *Policy, event: ui.Event) Change {
        var change: Change = .{};
        const point: ui.Point = .{ .x = event.x, .y = event.y };
        const pointer = event.kind == .pointer_down or event.kind == .pointer_up or event.kind == .pointer_move;
        if (pointer) {
            change.cursor = !std.meta.eql(self.cursor, point);
            self.cursor = point;
        }
        if (event.kind == .key_up) {
            self.shortcut_down &= ~shortcutBit(event.code);
            for (&self.entries) |*entry| {
                if (event.code == windows.key.f11) entry.window.fullscreen_key_down = false;
                if (event.code == @backingInt(ui.input.Key.escape)) entry.window.escape_key_down = false;
            }
        }
        return change;
    }
    pub fn input(self: *Policy, event: ui.Event, tick: u64) Error!Change {
        // Preserve the window host's owned-release filtering even though the
        // physical observer clears all windows' key latches before routing.
        const owned_release = if (event.kind == .key_up and self.focused != null)
            ((event.code == windows.key.f11 and self.entries[self.focused.?].window.fullscreen_key_down) or
                (event.code == @backingInt(ui.input.Key.escape) and self.entries[self.focused.?].window.escape_key_down))
        else
            false;
        var change = self.observeInput(event);
        const point: ui.Point = .{ .x = event.x, .y = event.y };
        const pointer = event.kind == .pointer_down or event.kind == .pointer_up or event.kind == .pointer_move;
        if (event.kind == .pointer_down and event.code == 1) {
            self.pointer_press = point;
            self.pointer_moved = false;
        }
        if (event.kind == .pointer_move and (@abs(@as(i64, point.x) - self.pointer_press.x) >= 4 or @abs(@as(i64, point.y) - self.pointer_press.y) >= 4)) self.pointer_moved = true;
        const shortcut_bit = shortcutBit(event.code);
        if (owned_release) return change;
        if (event.kind == .text and event.modifiers & ui.input.modifiers.super != 0) return change;
        if (event.kind == .key_down and event.modifiers & ui.input.modifiers.super != 0 and shortcut_bit != 0) {
            if (self.shortcut_down & shortcut_bit != 0) return change;
            self.shortcut_down |= shortcut_bit;
            if (event.code >= '1' and event.code <= '4') return self.switchWorkspace(@intCast(event.code - '1'), event.modifiers & ui.input.modifiers.shift != 0);
            if (shortcut_bit == 16) return self.toggleTile();
            return self.cycle();
        }
        if (event.kind == .key_down and event.modifiers & ui.input.modifiers.super != 0 and (event.code == 'e' or event.code == 'E' or event.code == 'n' or event.code == 'N' or event.code == 13)) {
            if (self.peers[shell_index].pid != 0) change.routed = .{ .index = shell_index, .event = event };
            return change;
        }
        const captured = self.capture();
        const target = if (pointer) captured orelse self.topAt(point) else self.focused;
        const shell_pointer = pointer and captured == null and (self.shell_capture or target == null);
        const hover_owner: ?usize = if (shell_pointer) null else target;
        if (pointer) for (&self.entries, 0..) |*entry, n| if (n != hover_owner and entry.window.hovered != null) {
            entry.window.hovered = null;
            change.compose = true;
        };
        if (shell_pointer) {
            if (event.kind == .pointer_down and event.code == 1) {
                self.shell_capture = true;
                self.shell_workspace_press = barWorkspace(point);
                self.focus(null, &change);
            }
            if (event.kind == .pointer_up and event.code == 1) {
                self.shell_capture = false;
                if (self.shell_workspace_press) |ws| if (barWorkspace(point) == ws) {
                    self.shell_workspace_press = null;
                    var switched = try self.switchWorkspace(ws, false);
                    switched.cursor = change.cursor;
                    // A shell press may have changed focus before the release.
                    // Keep any physical-input repaint even for a no-op switch.
                    switched.compose = switched.compose or change.compose;
                    return switched;
                };
                self.shell_workspace_press = null;
            }
            if (self.peers[shell_index].pid != 0) change.routed = .{ .index = shell_index, .event = event };
            return change;
        }
        const i = target orelse return change;
        if (!self.visible(i)) return change;
        if (event.kind == .pointer_down and captured == null) self.focus(i, &change);
        const window = &self.entries[i].window;
        const before = window.*;
        if (self.resizing) |resize| {
            if (event.kind == .pointer_move) self.applyResize(resize, point);
            if (event.kind == .pointer_up and event.code == 1) self.resizing = null;
        } else if (event.kind == .pointer_down and event.code == 1 and captured == null and window.mode == .floating and !self.tiled[self.workspace] and edgeAt(window.*, point) != null) {
            self.resizing = .{ .index = i, .pointer = point, .geometry = window.frame(), .edges = edgeAt(window.*, point).? };
            cancel(window);
        } else {
            if (window.route(event)) |routed| {
                var local = routed;
                if (event.kind == .pointer_up and event.code == 1) {
                    const is_click = !self.pointer_moved and window.clientAt(point);
                    const entry = &self.entries[i];
                    if (is_click and entry.previous_click_valid and tick -% entry.previous_click_tick <= 50 and
                        @abs(@as(i64, point.x) - entry.previous_click.x) < 4 and @abs(@as(i64, point.y) - entry.previous_click.y) < 4)
                    {
                        local.modifiers |= ui.input.modifiers.double_click;
                        entry.previous_click_valid = false;
                    } else entry.previous_click_valid = is_click;
                    entry.previous_click_tick = tick;
                    entry.previous_click = point;
                }
                change.routed = .{ .index = i, .event = local };
            }
            if (self.tiled[self.workspace]) window.drag = null;
        }
        const geometry_changed = !std.meta.eql(before.frame(), window.frame()) or before.mode != window.mode;
        if ((geometry_changed or before.visible != window.visible) and !window.closed) {
            try self.configureChanged(i, &change);
            change.routed = null;
        }
        if (!before.closed and window.closed) {
            self.peers[i].cache_valid = false;
            change.close |= bit(i);
            change.routed = null;
        }
        if (!before.minimized and window.minimized) change.report(.{ .code = 2, .app = self.peers[i].app });
        if (before.mode != window.mode) change.report(.{ .code = if (before.mode == .fullscreen) 7 else switch (window.mode) {
            .maximized => 5,
            .fullscreen => 6,
            .floating => 7,
        }, .app = self.peers[i].app });
        if (geometry_changed and before.mode == window.mode and self.resizing != null) change.report(.{ .code = 8, .app = self.peers[i].app });
        if (!self.visible(i)) {
            self.focus(null, &change);
            self.fallbackFocus(&change);
        }
        if (before.visible != window.visible or before.mode != window.mode) try self.retile(&change);
        change.compose = change.compose or geometry_changed or before.visible != window.visible or before.focused != window.focused or before.hovered != window.hovered or before.pressed_control != window.pressed_control;
        return change;
    }
    fn applyResize(self: *Policy, resize: Resize, pointer: ui.Point) void {
        var left: i32 = resize.geometry.x;
        var top: i32 = resize.geometry.y;
        var right = left + @as(i32, @intCast(resize.geometry.width));
        var bottom = top + @as(i32, @intCast(resize.geometry.height));
        const dx = pointer.x - resize.pointer.x;
        const dy = pointer.y - resize.pointer.y;
        if (resize.edges.left) left = std.math.clamp(left + dx, 0, right - 320);
        if (resize.edges.right) right = std.math.clamp(right + dx, left + 320, @as(i32, @intCast(self.screen_width)));
        if (resize.edges.top) top = std.math.clamp(top + dy, @as(i32, windows.Window.workarea_top), bottom - 240);
        if (resize.edges.bottom) bottom = std.math.clamp(bottom + dy, top + 240, @as(i32, @intCast(self.screen_height - windows.Window.workarea_bottom)));
        const window = &self.entries[resize.index].window;
        setFrame(window, .{ .x = left, .y = top, .width = @intCast(right - left), .height = @intCast(bottom - top) });
        window.saved_geometry = window.frame();
    }
};
fn cancel(window: *windows.Window) void {
    window.capture = false;
    window.capture_button = 0;
    window.drag = null;
    window.pressed_control = null;
    window.hovered = null;
}
fn setFrame(window: *windows.Window, rect: ui.Rect) void {
    window.x = rect.x;
    window.y = rect.y;
    window.width = rect.width;
    window.height = rect.height;
}
fn edgeAt(window: windows.Window, point: ui.Point) ?Edges {
    if (!window.frame().contains(point)) return null;
    const right = window.x + @as(i32, @intCast(window.width));
    const bottom = window.y + @as(i32, @intCast(window.height));
    const edges: Edges = .{ .left = point.x < window.x + 6, .right = point.x >= right - 6, .top = point.y < window.y + 6, .bottom = point.y >= bottom - 6 };
    return if (edges.left or edges.right or edges.top or edges.bottom) edges else null;
}
fn barWorkspace(point: ui.Point) ?u8 {
    if (point.y < 0 or point.y >= 36 or point.x < 270 or point.x >= 390) return null;
    return @intCast(@divTrunc(point.x - 270, 30));
}
pub fn controlMessage(message: *const abi.ServiceMessage) Error!void {
    if (message.peer_pid == 0 or message.peer_app == 0 or message.flags != 0 or message.surface != 0 or message.width != 0 or message.height != 0 or !zero(&message.payload)) return error.InvalidMessage;
    switch (message.kind) {
        abi.display.heartbeat, abi.display.launch => if (message.sequence == 0) return error.InvalidMessage,
        abi.display.peer_closed => {},
        else => return error.InvalidMessage,
    }
}
pub fn copyViewport(destination: []volatile u32, source: []const volatile u32, cfg: wire.Config) Error!void {
    try bitmapBounds(destination.len, source.len, cfg);
    for (0..cfg.height) |y| for (0..cfg.width) |x| {
        const offset = y * @as(usize, cfg.screen_width) + x;
        destination[offset] = source[offset];
    };
}
pub fn blitViewport(destination: []volatile u32, source: []const volatile u32, cfg: wire.Config) Error!void {
    try bitmapBounds(destination.len, source.len, cfg);
    if (cfg.origin_x < 0 or cfg.origin_y < 0 or @as(u64, @intCast(cfg.origin_x)) + cfg.width > cfg.screen_width or @as(u64, @intCast(cfg.origin_y)) + cfg.height > cfg.screen_height) return error.InvalidFrame;
    const accessory = if (cfg.header_content) (windows.header.layoutMode(cfg.width, cfg.header_tabs) catch return error.InvalidFrame).accessory else null;
    for (0..cfg.height) |y| for (0..cfg.width) |x| {
        if (accessory) |rect| if (y < windows.header.height and !rect.contains(@intCast(x), @intCast(y))) continue;
        destination[(y + @as(usize, @intCast(cfg.origin_y))) * cfg.screen_width + x + @as(usize, @intCast(cfg.origin_x))] = source[y * @as(usize, cfg.screen_width) + x];
    };
}
fn bitmapBounds(destination_len: usize, source_len: usize, cfg: wire.Config) Error!void {
    if (cfg.screen_width == 0 or cfg.screen_width > 1280 or cfg.screen_height == 0 or cfg.screen_height > 800 or cfg.width == 0 or cfg.width > cfg.screen_width or cfg.height == 0 or cfg.height > cfg.screen_height) return error.InvalidFrame;
    const count = @as(usize, cfg.screen_width) * cfg.screen_height;
    if (destination_len < count or source_len < count) return error.InvalidFrame;
}

fn createMessage(app: u64, pid: u64) abi.ServiceMessage {
    var message: abi.ServiceMessage = .{ .kind = 9, .peer_app = app, .peer_pid = pid, .sequence = 1 };
    @memcpy(message.payload[0..4], "Test");
    return message;
}
fn frameMessage(policy: *const Policy, i: usize, counter: u32) abi.ServiceMessage {
    const peer = policy.peers[i];
    const cfg = peer.configuration.?;
    return .{ .kind = abi.display.frame, .flags = wire.flagsFor(peer.window_id, 0), .peer_app = peer.app, .peer_pid = peer.pid, .surface = 9, .sequence = (@as(u64, cfg.sequence) << 32) | counter, .width = cfg.screen_width, .height = cfg.screen_height };
}
fn click(policy: *Policy, i: usize, control: windows.Control) !Change {
    const rect = policy.entries[i].window.controlRect(control);
    _ = try policy.input(.{ .kind = .pointer_down, .code = 1, .x = @intCast(rect.x + 12), .y = @intCast(rect.y + 12) }, 1);
    return policy.input(.{ .kind = .pointer_up, .code = 1, .x = @intCast(rect.x + 12), .y = @intCast(rect.y + 12) }, 2);
}

test {
    _ = @import("cursor_layer.zig");
}

test "idle client pointer movement damages only the cursor and preserves routing" {
    const t = std.testing;
    var p = try Policy.init(1280, 800);
    _ = try p.create(&createMessage(abi.display.files, 10));
    const client = p.entries[0].window.client();
    var event: ui.Event = .{ .kind = .pointer_move, .x = @intCast(client.x + 30), .y = @intCast(client.y + 60) };
    const epoch = p.configure_sequence;
    const first = try p.input(event, 1);
    try t.expect(first.cursor and !first.compose and first.configure == 0 and first.redraw == 0 and !first.status);
    try t.expectEqual(@as(usize, 0), first.routed.?.index);
    const repeated = try p.input(event, 2);
    try t.expect(!repeated.cursor and !repeated.compose and repeated.configure == 0 and repeated.redraw == 0);
    event.x += 20;
    event.y += 10;
    const moved = try p.input(event, 3);
    try t.expect(moved.cursor and !moved.compose and moved.configure == 0 and moved.redraw == 0 and !moved.status);
    try t.expectEqual(@as(usize, 0), moved.routed.?.index);
    try t.expectEqual(epoch, p.configure_sequence);
}

test "caption hover transitions and geometry still compose while stable hover only moves cursor" {
    const t = std.testing;
    var p = try Policy.init(1280, 800);
    _ = try p.create(&createMessage(abi.display.files, 10));
    const close = p.entries[0].window.controlRect(.close);
    var event: ui.Event = .{ .kind = .pointer_move, .x = @intCast(close.x + 12), .y = @intCast(close.y + 12) };
    const entered = try p.input(event, 1);
    try t.expect(entered.cursor and entered.compose and entered.configure == 0);
    try t.expectEqual(@as(?windows.Control, .close), p.entries[0].window.hovered);
    event.x += 1;
    const within = try p.input(event, 2);
    try t.expect(within.cursor and !within.compose and within.configure == 0);
    const client = p.entries[0].window.client();
    const left = try p.input(.{ .kind = .pointer_move, .x = @intCast(client.x + 30), .y = @intCast(client.y + 60) }, 3);
    try t.expect(left.cursor and left.compose and p.entries[0].window.hovered == null);
    const frame = p.entries[0].window.frame();
    _ = try p.input(.{ .kind = .pointer_down, .code = 1, .x = @intCast(frame.x + @as(i32, @intCast(frame.width)) - 1), .y = @intCast(frame.y + @as(i32, @intCast(frame.height)) - 1) }, 4);
    const resized = try p.input(.{ .kind = .pointer_move, .x = @intCast(frame.x + @as(i32, @intCast(frame.width)) - 21), .y = @intCast(frame.y + @as(i32, @intCast(frame.height)) - 11) }, 5);
    try t.expect(resized.cursor and resized.compose and resized.configure == bit(0));
}

test "workspace pointer release retains cursor damage for unchanged and changed workspaces" {
    const t = std.testing;
    var p = try Policy.init(1280, 800);
    for ([_]u8{ 0, 1 }) |workspace| {
        const x: i16 = @intCast(280 + @as(u16, workspace) * 30);
        _ = try p.input(.{ .kind = .pointer_down, .code = 1, .x = x, .y = 12 }, 1);
        const released = try p.input(.{ .kind = .pointer_up, .code = 1, .x = x + 1, .y = 12 }, 2);
        try t.expect(released.cursor);
        try t.expectEqual(workspace != 0, released.compose);
        try t.expectEqual(workspace != 0, released.status);
        try t.expectEqual(workspace, p.workspace);
        try t.expectEqualDeep(ui.Point{ .x = x + 1, .y = 12 }, p.cursor);
        try t.expect(!p.shell_capture and p.shell_workspace_press == null);
    }
}

test "leaving caption controls for desktop clears hover before cursor-only shell routing" {
    const t = std.testing;
    var p = try Policy.init(1280, 800);
    _ = try p.helloShell(abi.display.shell, 20);
    _ = try p.create(&createMessage(abi.display.files, 10));
    const close = p.entries[0].window.controlRect(.close);
    _ = try p.input(.{ .kind = .pointer_move, .x = @intCast(close.x + 12), .y = @intCast(close.y + 12) }, 1);
    try t.expectEqual(@as(?windows.Control, .close), p.entries[0].window.hovered);
    const left = try p.input(.{ .kind = .pointer_move, .x = 1279, .y = 799 }, 2);
    try t.expect(left.cursor and left.compose and left.configure == 0 and left.redraw == 0);
    try t.expectEqual(@as(usize, shell_index), left.routed.?.index);
    try t.expect(p.entries[0].window.hovered == null);
    const moved = try p.input(.{ .kind = .pointer_move, .x = 1278, .y = 799 }, 3);
    try t.expect(moved.cursor and !moved.compose and moved.configure == 0 and moved.redraw == 0);
    try t.expectEqual(@as(usize, shell_index), moved.routed.?.index);
}

test "trusted overlay observation separates cursor damage and drains global shortcut release without client input" {
    const t = std.testing;
    var p = try Policy.init(1280, 800);
    _ = try p.create(&createMessage(abi.display.files, 10));
    _ = try p.create(&createMessage(notes_app, 11));
    _ = try p.input(.{ .kind = .key_down, .code = 't', .modifiers = ui.input.modifiers.super }, 1);
    try t.expect(p.tiled[0] and p.shortcut_down != 0);
    _ = p.cancelGestures();
    const focused = p.focused;
    const epoch = p.configure_sequence;
    const move = p.observeInput(.{ .kind = .pointer_move, .x = 1230, .y = 200 });
    try t.expect(move.cursor and !move.compose and move.routed == null and move.configure == 0 and move.close == 0 and !move.status);
    try t.expectEqualDeep(ui.Point{ .x = 1230, .y = 200 }, p.cursor);
    try t.expectEqual(focused, p.focused);
    try t.expectEqual(epoch, p.configure_sequence);
    const release = p.observeInput(.{ .kind = .key_up, .code = 't', .modifiers = ui.input.modifiers.super });
    try t.expect(release.routed == null and !release.cursor and !release.compose and release.configure == 0 and release.close == 0);
    try t.expectEqual(@as(u8, 0), p.shortcut_down);
    _ = try p.input(.{ .kind = .key_down, .code = 't', .modifiers = ui.input.modifiers.super }, 2);
    try t.expect(!p.tiled[0]);
}

test "consumed window key releases clear fullscreen and escape latches across a focus transfer" {
    const t = std.testing;
    var p = try Policy.init(1280, 800);
    _ = try p.helloShell(abi.display.shell, 20);
    _ = try p.create(&createMessage(abi.display.files, 10));
    _ = try p.input(.{ .kind = .key_down, .code = windows.key.f11 }, 1);
    _ = try p.input(.{ .kind = .key_down, .code = @backingInt(ui.input.Key.escape) }, 2);
    try t.expect(p.entries[0].window.fullscreen_key_down and p.entries[0].window.escape_key_down);
    _ = try p.create(&createMessage(notes_app, 11));
    try t.expectEqual(@as(?usize, 1), p.focused);
    const fullscreen_release = p.observeInput(.{ .kind = .key_up, .code = windows.key.f11 });
    const escape_release = p.observeInput(.{ .kind = .key_up, .code = @backingInt(ui.input.Key.escape) });
    try t.expect(fullscreen_release.routed == null and escape_release.routed == null);
    try t.expect(!p.entries[0].window.fullscreen_key_down and !p.entries[0].window.escape_key_down);
    _ = try p.launch(abi.display.shell, 20, abi.display.files);
    _ = try p.input(.{ .kind = .key_down, .code = windows.key.f11 }, 3);
    try t.expectEqual(windows.Mode.fullscreen, p.entries[0].window.mode);
    _ = try p.input(.{ .kind = .key_down, .code = @backingInt(ui.input.Key.escape) }, 4);
    try t.expectEqual(windows.Mode.floating, p.entries[0].window.mode);
}

test "trusted overlay cancellation invalidates a prior click and cancels a pending close control" {
    const t = std.testing;
    var p = try Policy.init(1280, 800);
    _ = try p.create(&createMessage(abi.display.files, 10));
    const client = p.entries[0].window.client();
    const down: ui.Event = .{ .kind = .pointer_down, .code = 1, .x = @intCast(client.x + 40), .y = @intCast(client.y + 80) };
    var up = down;
    up.kind = .pointer_up;
    _ = try p.input(down, 1);
    _ = try p.input(up, 2);
    try t.expect(p.entries[0].previous_click_valid);
    const cancelled = p.cancelGestures();
    try t.expect(cancelled.redraw & bit(0) != 0 and !p.entries[0].previous_click_valid);
    _ = try p.input(down, 3);
    const next_click = try p.input(up, 4);
    try t.expect(next_click.routed.?.event.modifiers & ui.input.modifiers.double_click == 0);
    const close = p.entries[0].window.controlRect(.close);
    const press: ui.Event = .{ .kind = .pointer_down, .code = 1, .x = @intCast(close.x + 12), .y = @intCast(close.y + 12) };
    _ = try p.input(press, 5);
    try t.expectEqual(@as(?windows.Control, .close), p.entries[0].window.pressed_control);
    _ = p.cancelGestures();
    var released = press;
    released.kind = .pointer_up;
    const terminal = try p.input(released, 6);
    try t.expect(terminal.close == 0 and !p.entries[0].window.closed and p.entries[0].window.pressed_control == null);
}

test "setting an explicit tiling preference is idempotent and restores floating geometry" {
    const t = std.testing;
    var p = try Policy.init(1280, 800);
    _ = try p.create(&createMessage(abi.display.files, 10));
    _ = try p.create(&createMessage(notes_app, 11));
    const floating = [_]ui.Rect{ p.entries[0].window.frame(), p.entries[1].window.frame() };
    _ = try p.setTiled(true);
    const epoch = p.configure_sequence;
    const again = try p.setTiled(true);
    try t.expect(again.configure == 0 and !again.compose and !again.status);
    try t.expectEqual(epoch, p.configure_sequence);
    _ = try p.setTiled(false);
    try t.expectEqualDeep(floating[0], p.entries[0].window.frame());
    try t.expectEqualDeep(floating[1], p.entries[1].window.frame());
}
test "bounded generic registry protects PID ownership and viewport epochs" {
    const t = std.testing;
    var p = try Policy.init(1280, 800);
    _ = try p.create(&createMessage(201, 10));
    _ = try p.create(&createMessage(202, 11));
    for (2..capacity) |i| _ = try p.create(&createMessage(201 + i, 10 + i));
    try t.expectError(error.RegistryFull, p.create(&createMessage(201 + capacity, 10 + capacity)));
    try t.expectError(error.InvalidPeer, p.create(&createMessage(201, 99)));
    var old = frameMessage(&p, 0, 1);
    p.commitFrame(try p.frame(&old), old.sequence);
    try t.expectError(error.StaleFrame, p.frame(&old));
    var resize: abi.ServiceMessage = .{ .kind = 10, .peer_app = 201, .peer_pid = 99, .sequence = 2, .width = 600, .height = 420 };
    try t.expectError(error.InvalidPeer, p.request(&resize));
    resize.peer_pid = 10;
    _ = try p.request(&resize);
    try t.expectError(error.StaleFrame, p.frame(&old));
    old = frameMessage(&p, 0, 1);
    old.width -= 1;
    try t.expectError(error.InvalidFrame, p.frame(&old));
    var malicious = createMessage(201, 10);
    malicious.payload[7] = 'X';
    try t.expectError(error.InvalidMessage, p.create(&malicious));
    _ = try p.closed(201, 10);
    _ = try p.create(&createMessage(201, 100));
    try t.expectError(error.InvalidPeer, p.closed(201, 10));
    try t.expectError(error.InvalidPeer, p.frame(&old));
}
test "topmost click focuses and captured outside release remains with its owner" {
    const t = std.testing;
    var p = try Policy.init(1280, 800);
    _ = try p.create(&createMessage(abi.display.files, 10));
    _ = try p.create(&createMessage(notes_app, 11));
    try t.expectEqual(@as(?usize, 1), p.focused);
    const notes_client = p.entries[1].window.client();
    const down = try p.input(.{ .kind = .pointer_down, .code = 1, .x = @intCast(notes_client.x + 30), .y = @intCast(notes_client.y + 30) }, 1);
    try t.expectEqual(@as(usize, 1), down.routed.?.index);
    const up = try p.input(.{ .kind = .pointer_up, .code = 1, .x = 60, .y = 110 }, 2);
    try t.expectEqual(@as(usize, 1), up.routed.?.index);
    try t.expect(!p.entries[1].window.capture);
    _ = try p.input(.{ .kind = .pointer_down, .code = 1, .x = 70, .y = 120 }, 3);
    try t.expectEqual(@as(?usize, 0), p.focused);
    try t.expectEqual(@as(usize, 0), p.z_order[capacity - 1]);
    const key_change = try p.input(.{ .kind = .text, .code = 'a' }, 4);
    try t.expectEqual(@as(usize, 0), key_change.routed.?.index);
}
test "interactive corner resizing clamps useful extents and rotates viewport epoch" {
    const t = std.testing;
    var p = try Policy.init(800, 600);
    _ = try p.create(&createMessage(abi.display.files, 10));
    const old = frameMessage(&p, 0, 1);
    const frame = p.entries[0].window.frame();
    _ = try p.input(.{ .kind = .pointer_down, .code = 1, .x = @intCast(frame.x + @as(i32, @intCast(frame.width)) - 1), .y = @intCast(frame.y + @as(i32, @intCast(frame.height)) - 1) }, 1);
    try t.expect(p.resizing != null);
    const resized = try p.input(.{ .kind = .pointer_move, .x = 100, .y = 100 }, 2);
    try t.expect(resized.configure & 1 != 0);
    try t.expectEqual(@as(u32, 320), p.entries[0].window.width);
    try t.expectEqual(@as(u32, 240), p.entries[0].window.height);
    try t.expectError(error.StaleFrame, p.frame(&old));
    _ = try p.input(.{ .kind = .pointer_up, .code = 1, .x = 799, .y = 599 }, 3);
    try t.expect(p.resizing == null);
    try t.expectEqualDeep(p.entries[0].window.frame(), p.entries[0].window.saved_geometry);
}
test "workspaces cancel capture hide old epochs and moving focus preserves ownership" {
    const t = std.testing;
    var p = try Policy.init(1280, 800);
    _ = try p.create(&createMessage(abi.display.files, 10));
    _ = try p.create(&createMessage(notes_app, 11));
    const old = frameMessage(&p, 1, 1);
    _ = try p.input(.{ .kind = .pointer_down, .code = 1, .x = 700, .y = 200 }, 1);
    _ = try p.input(.{ .kind = .key_down, .code = '2', .modifiers = ui.input.modifiers.super | ui.input.modifiers.shift }, 2);
    try t.expectEqual(@as(u8, 0), p.workspace);
    try t.expectEqual(@as(u8, 1), p.entries[1].workspace);
    try t.expect(!p.entries[1].window.capture);
    try t.expectEqual(@as(?usize, 0), p.focused);
    try t.expectError(error.StaleFrame, p.frame(&old));
    _ = try p.input(.{ .kind = .key_up, .code = '2' }, 3);
    _ = try p.input(.{ .kind = .key_down, .code = '2', .modifiers = ui.input.modifiers.super }, 4);
    try t.expectEqual(@as(u8, 1), p.workspace);
    try t.expectEqual(@as(?usize, 1), p.focused);
    try t.expectEqual(@as(u64, 11), p.focusedPid());
    try t.expectEqual(@as(u32, 0), p.peers[0].configuration.?.width);
    try t.expect(p.peers[1].configuration.?.width > 0);
}
test "tiling and independent minimize close crash restore retain the other app" {
    const t = std.testing;
    var p = try Policy.init(800, 600);
    _ = try p.helloShell(abi.display.shell, 20);
    _ = try p.create(&createMessage(abi.display.files, 10));
    _ = try p.create(&createMessage(notes_app, 11));
    const floating = p.entries[0].window.frame();
    _ = try p.input(.{ .kind = .key_down, .code = 't', .modifiers = ui.input.modifiers.super }, 1);
    try t.expect(p.tiled[0]);
    try t.expectEqual(@as(u32, 400), p.entries[0].window.width);
    try t.expectEqual(@as(u32, 400), p.entries[1].window.width);
    _ = try click(&p, 1, .minimize);
    try t.expectEqual(@as(u64, 11), p.peers[1].pid);
    try t.expectEqual(@as(u32, 800), p.entries[0].window.width);
    _ = try p.launch(abi.display.shell, 20, notes_app);
    try t.expectEqual(@as(u32, 400), p.entries[0].window.width);
    _ = try p.input(.{ .kind = .key_up, .code = 't' }, 3);
    _ = try p.input(.{ .kind = .key_down, .code = 't', .modifiers = ui.input.modifiers.super }, 4);
    try t.expectEqualDeep(floating, p.entries[0].window.frame());
    const files_epoch = p.peers[0].configuration.?.sequence;
    _ = try p.closed(notes_app, 11);
    try t.expectEqual(@as(u64, 10), p.peers[0].pid);
    try t.expectEqual(files_epoch, p.peers[0].configuration.?.sequence);
    try t.expectEqual(@as(u64, 1), p.closed_counts[1]);
    _ = try p.launch(abi.display.shell, 20, notes_app);
    _ = try p.launch(abi.display.shell, 20, notes_app);
    try t.expectEqual(@as(u64, 1), p.launch_requests[1]);
    _ = try p.create(&createMessage(notes_app, 12));
    try t.expectError(error.InvalidPeer, p.closed(notes_app, 11));
    try t.expectEqual(@as(u64, 10), p.peers[0].pid);
}
test "window focus close controls cannot address or configure another PID" {
    const t = std.testing;
    var p = try Policy.init(1280, 800);
    _ = try p.create(&createMessage(abi.display.files, 10));
    _ = try p.create(&createMessage(notes_app, 11));
    var close: abi.ServiceMessage = .{ .kind = 12, .peer_app = notes_app, .peer_pid = 10, .sequence = 1 };
    try t.expectError(error.InvalidPeer, p.request(&close));
    close.peer_pid = 11;
    const changed = try p.request(&close);
    try t.expectEqual(@as(u8, 2), changed.close);
    try t.expect(p.entries[1].window.closed);
    try t.expect(!p.entries[0].window.closed);
    try t.expectEqual(@as(?usize, 0), p.focused);
    try t.expectError(error.InvalidPeer, p.launch(abi.display.files, 10, notes_app));
}
test "all eight resize handles change the owning geometry and screen bounds" {
    const t = std.testing;
    for ([_][2]i32{ .{ -1, -1 }, .{ 0, -1 }, .{ 1, -1 }, .{ -1, 0 }, .{ 1, 0 }, .{ -1, 1 }, .{ 0, 1 }, .{ 1, 1 } }) |direction| {
        var p = try Policy.init(1280, 800);
        _ = try p.create(&createMessage(201, 10));
        const frame = p.entries[0].window.frame();
        const x = frame.x + if (direction[0] < 0) @as(i32, 1) else if (direction[0] > 0) @as(i32, @intCast(frame.width)) - 1 else @as(i32, @intCast(frame.width / 2));
        const y = frame.y + if (direction[1] < 0) @as(i32, 1) else if (direction[1] > 0) @as(i32, @intCast(frame.height)) - 1 else @as(i32, @intCast(frame.height / 2));
        const epoch = p.peers[0].configuration.?.sequence;
        _ = try p.input(.{ .kind = .pointer_down, .code = 1, .x = @intCast(x), .y = @intCast(y) }, 1);
        try t.expect(p.resizing != null);
        _ = try p.input(.{ .kind = .pointer_move, .x = @intCast(x + direction[0] * 20), .y = @intCast(y + direction[1] * 20) }, 2);
        try t.expect(p.peers[0].configuration.?.sequence > epoch);
        try t.expect(!std.meta.eql(frame, p.entries[0].window.frame()));
        const resized = p.entries[0].window.frame();
        try t.expect(resized.x >= 0 and resized.y >= windows.Window.workarea_top);
        try t.expect(@as(u32, @intCast(resized.x)) + resized.width <= 1280);
        try t.expect(@as(u32, @intCast(resized.y)) + resized.height <= 788);
    }
}
test "maximize fullscreen restore and Super Tab affect only the focused window" {
    const t = std.testing;
    var p = try Policy.init(1280, 800);
    _ = try p.create(&createMessage(abi.display.files, 10));
    _ = try p.create(&createMessage(notes_app, 11));
    const notes_frame = p.entries[1].window.frame();
    _ = try p.input(.{ .kind = .key_down, .code = 9, .modifiers = ui.input.modifiers.super }, 1);
    try t.expectEqual(@as(?usize, 0), p.focused);
    _ = try click(&p, 0, .maximize);
    try t.expectEqual(windows.Mode.maximized, p.entries[0].window.mode);
    try t.expectEqualDeep(notes_frame, p.entries[1].window.frame());
    _ = try p.input(.{ .kind = .key_down, .code = windows.key.f11 }, 3);
    try t.expectEqual(windows.Mode.fullscreen, p.entries[0].window.mode);
    const epoch = p.configure_sequence;
    _ = try p.input(.{ .kind = .key_down, .code = windows.key.f11 }, 4);
    try t.expectEqual(epoch, p.configure_sequence);
    _ = try p.input(.{ .kind = .key_up, .code = windows.key.f11 }, 5);
    _ = try p.input(.{ .kind = .key_down, .code = @backingInt(ui.input.Key.escape) }, 6);
    try t.expectEqual(windows.Mode.maximized, p.entries[0].window.mode);
    const route = try p.input(.{ .kind = .key_down, .code = 'n', .modifiers = ui.input.modifiers.super }, 7);
    // An absent Shell still consumes its global launch shortcut.
    try t.expect(route.routed == null);
    _ = try p.helloShell(abi.display.shell, 20);
    const shell_route = try p.input(.{ .kind = .key_down, .code = 'N', .modifiers = ui.input.modifiers.super }, 8);
    try t.expectEqual(shell_index, shell_route.routed.?.index);
}
test "viewport copies preserve stride padding and invalid coordinates never blit" {
    const t = std.testing;
    const source = try t.allocator.alloc(u32, 800 * 600);
    defer t.allocator.free(source);
    const destination = try t.allocator.alloc(u32, 800 * 600);
    defer t.allocator.free(destination);
    @memset(source, 0x00112233);
    @memset(destination, 0xaabbccdd);
    var cfg: wire.Config = .{ .sequence = 1, .width = 12, .height = 9, .screen_width = 800, .screen_height = 600, .origin_x = 100, .origin_y = 80 };
    try copyViewport(destination, source, cfg);
    try t.expectEqual(@as(u32, 0x00112233), destination[8 * 800 + 11]);
    try t.expectEqual(@as(u32, 0xaabbccdd), destination[8 * 800 + 12]);
    @memset(destination, 0xaabbccdd);
    try blitViewport(destination, source, cfg);
    try t.expectEqual(@as(u32, 0x00112233), destination[80 * 800 + 100]);
    try t.expectEqual(@as(u32, 0xaabbccdd), destination[80 * 800 + 99]);
    cfg.origin_x = 799;
    try t.expectError(error.InvalidFrame, blitViewport(destination, source, cfg));
}
test "double click expires by observed clock age even across consecutive compositor polls" {
    const t = std.testing;
    var p = try Policy.init(1280, 800);
    _ = try p.create(&createMessage(201, 10));
    const client = p.entries[0].window.client();
    const down: ui.Event = .{ .kind = .pointer_down, .code = 1, .x = @intCast(client.x + 20), .y = @intCast(client.y + 80) };
    var up = down;
    up.kind = .pointer_up;
    _ = try p.input(down, 100);
    _ = try p.input(up, 100);
    _ = try p.input(down, 151);
    const expired = try p.input(up, 151);
    try t.expect(expired.routed.?.event.modifiers & ui.input.modifiers.double_click == 0);
    _ = try p.input(down, 180);
    const paired = try p.input(up, 180);
    try t.expect(paired.routed.?.event.modifiers & ui.input.modifiers.double_click != 0);
}
test "focused client presses preserve menu and drag gestures without cancellation redraw" {
    const t = std.testing;
    var p = try Policy.init(1280, 800);
    _ = try p.create(&createMessage(201, 10));
    _ = try p.create(&createMessage(notes_app, 11));
    const client = p.entries[0].window.client();
    const press: ui.Event = .{ .kind = .pointer_down, .code = 1, .x = @intCast(client.x + 20), .y = @intCast(client.y + 80) };
    // An actual focus transfer cancels the old client's gesture.
    const focused = try p.input(press, 1);
    try t.expectEqual(@as(?usize, 0), p.focused);
    try t.expect(focused.redraw != 0);
    var release = press;
    release.kind = .pointer_up;
    _ = try p.input(release, 2);
    // The next press can select a popup item or start a drag. Its event must
    // reach Files without the code1 redraw that dismisses its menu/gesture.
    const matched = try p.input(press, 60);
    try t.expectEqual(@as(u8, 0), matched.redraw);
    try t.expectEqual(@as(usize, 0), matched.routed.?.index);
    try t.expectEqual(ui.input.Kind.pointer_down, matched.routed.?.event.kind);
    try t.expect(p.entries[0].window.capture);
    const moved = try p.input(.{ .kind = .pointer_move, .x = 1279, .y = 799 }, 61);
    try t.expectEqual(@as(u8, 0), moved.redraw);
    try t.expectEqual(@as(usize, 0), moved.routed.?.index);
    const released = try p.input(.{ .kind = .pointer_up, .code = 1, .x = 1279, .y = 799 }, 62);
    try t.expectEqual(@as(usize, 0), released.routed.?.index);
    try t.expect(!p.entries[0].window.capture);
}
test "tile columns and epochs stay stable through shell focus and cycling while floating z order changes" {
    const t = std.testing;
    var p = try Policy.init(1280, 800);
    _ = try p.helloShell(abi.display.shell, 20);
    _ = try p.create(&createMessage(abi.display.files, 10));
    _ = try p.create(&createMessage(notes_app, 11));
    const floating = [_]ui.Rect{ p.entries[0].window.frame(), p.entries[1].window.frame() };
    try t.expectEqual(@as(usize, 1), p.z_order[capacity - 1]);
    _ = try p.launch(abi.display.shell, 20, abi.display.files);
    try t.expectEqual(@as(usize, 0), p.z_order[capacity - 1]);
    _ = try p.input(.{ .kind = .key_down, .code = 't', .modifiers = ui.input.modifiers.super }, 1);
    const tiled = [_]ui.Rect{ p.entries[0].window.frame(), p.entries[1].window.frame() };
    const epochs = [_]u32{ p.peers[0].configuration.?.sequence, p.peers[1].configuration.?.sequence };
    try t.expectEqual(@as(i32, 0), tiled[0].x);
    try t.expectEqual(@as(i32, 640), tiled[1].x);
    const notes = try p.launch(abi.display.shell, 20, notes_app);
    try t.expectEqual(@as(?usize, 1), p.focused);
    try t.expectEqual(@as(usize, 1), p.z_order[capacity - 1]);
    try t.expectEqual(@as(u8, 0), notes.configure);
    const files = try p.launch(abi.display.shell, 20, abi.display.files);
    try t.expectEqual(@as(?usize, 0), p.focused);
    try t.expectEqual(@as(usize, 0), p.z_order[capacity - 1]);
    try t.expectEqual(@as(u8, 0), files.configure);
    const cycle = try p.input(.{ .kind = .key_down, .code = 9, .modifiers = ui.input.modifiers.super }, 2);
    try t.expectEqual(@as(?usize, 1), p.focused);
    try t.expectEqual(@as(u8, 0), cycle.configure);
    for (0..tiled.len) |i| {
        try t.expectEqualDeep(tiled[i], p.entries[i].window.frame());
        try t.expectEqual(epochs[i], p.peers[i].configuration.?.sequence);
    }
    _ = try p.input(.{ .kind = .key_up, .code = 't' }, 3);
    _ = try p.input(.{ .kind = .key_down, .code = 't', .modifiers = ui.input.modifiers.super }, 4);
    try t.expectEqualDeep(floating[0], p.entries[0].window.frame());
    try t.expectEqualDeep(floating[1], p.entries[1].window.frame());
    _ = try p.launch(abi.display.shell, 20, abi.display.files);
    try t.expectEqual(@as(usize, 0), p.z_order[capacity - 1]);
    try t.expectEqualDeep(floating[0], p.entries[0].window.frame());
    try t.expectEqualDeep(floating[1], p.entries[1].window.frame());
}
test "integrated caption configure exposes own center while server controls remain private" {
    const t = std.testing;
    var p = try Policy.init(800, 600);
    var create = createMessage(abi.display.files, 10);
    create.flags = abi.display.header_content;
    create.width = 320;
    create.height = 240;
    _ = try p.create(&create);
    const cfg = p.peers[0].configuration.?;
    try t.expect(cfg.header_content);
    try t.expectEqual(@as(u32, 316), cfg.width);
    try t.expectEqual(@as(u32, 236), cfg.height);
    try t.expectEqual(p.entries[0].window.title().y, cfg.origin_y);
    const message = p.configurationMessage(0);
    try t.expectEqual(abi.display.header_content, message.flags);
    _ = try wire.configuration(&message);
    const center = p.entries[0].window.accessory();
    const press = try p.input(.{ .kind = .pointer_down, .code = 1, .x = @intCast(center.x + 20), .y = @intCast(center.y + 12) }, 1);
    try t.expectEqual(@as(usize, 0), press.routed.?.index);
    try t.expectEqual(@as(i16, 124), press.routed.?.event.x);
    const close = p.entries[0].window.controlRect(.close);
    _ = try p.input(.{ .kind = .pointer_up, .code = 1, .x = @intCast(close.x + 12), .y = @intCast(close.y + 12) }, 2);
    try t.expect(!p.entries[0].window.closed);
    const control = try p.input(.{ .kind = .pointer_down, .code = 1, .x = @intCast(close.x + 12), .y = @intCast(close.y + 12) }, 3);
    try t.expect(control.routed == null);
    const closed = try p.input(.{ .kind = .pointer_up, .code = 1, .x = @intCast(close.x + 12), .y = @intCast(close.y + 12) }, 4);
    try t.expectEqual(@as(u8, 1), closed.close);
    var invalid = createMessage(notes_app, 11);
    invalid.flags = 2;
    try t.expectError(error.InvalidMessage, p.create(&invalid));
}
test "client header pixels cannot overwrite server title drag gaps or right controls" {
    const t = std.testing;
    const source = try t.allocator.alloc(u32, 800 * 600);
    defer t.allocator.free(source);
    const destination = try t.allocator.alloc(u32, 800 * 600);
    defer t.allocator.free(destination);
    @memset(source, 0x00112233);
    @memset(destination, 0x00445566);
    const cfg: wire.Config = .{ .sequence = 1, .width = 316, .height = 236, .screen_width = 800, .screen_height = 600, .origin_x = 40, .origin_y = 60, .header_content = true };
    try blitViewport(destination, source, cfg);
    const layout = try windows.header.layout(cfg.width);
    for (0..windows.header.height) |y| for (0..cfg.width) |x| {
        const actual = destination[(60 + y) * 800 + 40 + x];
        const expected: u32 = if (layout.accessory.contains(@intCast(x), @intCast(y))) 0x00112233 else 0x00445566;
        try t.expectEqual(expected, actual);
    };
    try t.expectEqual(@as(u32, 0x00112233), destination[(60 + 32) * 800 + 40]);
    try t.expectEqual(@as(u32, 0x00445566), destination[(60 + 32) * 800 + 39]);
}

fn ownedWindowMessage(app: u64, pid: u64, id: u16) abi.ServiceMessage {
    var message = createMessage(app, pid);
    message.flags = wire.flagsFor(id, abi.display.header_content | abi.display.header_tabs);
    return message;
}
test "four Files windows share one PID while grants epochs and foreign controls remain isolated" {
    const t = std.testing;
    var p = try Policy.init(1280, 800);
    _ = try p.create(&ownedWindowMessage(abi.display.files, 10, 0));
    _ = try p.create(&createMessage(notes_app, 11));
    for (1..4) |id| _ = try p.create(&ownedWindowMessage(abi.display.files, 10, @intCast(id)));
    try t.expectError(error.RegistryFull, p.create(&ownedWindowMessage(abi.display.files, 10, 4)));
    try t.expectError(error.InvalidPeer, p.create(&ownedWindowMessage(abi.display.files, 99, 4)));
    try t.expectError(error.InvalidPeer, p.create(&ownedWindowMessage(notes_app, 11, 1)));
    const primary = try p.boundWindow(abi.display.files, 10, 0);
    const secondary = try p.boundWindow(abi.display.files, 10, 1);
    try t.expect(primary != secondary);
    const configuration = p.configurationMessage(secondary);
    try t.expectEqual(@as(u16, 1), wire.windowId(configuration.flags));
    try t.expect((try wire.configuration(&configuration)).header_tabs);
    const frame = frameMessage(&p, secondary, 1);
    try t.expectEqual(secondary, try p.frame(&frame));
    var forged = frame;
    forged.flags = 0;
    try t.expectError(error.StaleFrame, p.frame(&forged));
    forged = frame;
    forged.peer_pid = 11;
    try t.expectError(error.InvalidPeer, p.frame(&forged));
    var request: abi.ServiceMessage = .{ .kind = abi.display.close_window, .flags = wire.flagsFor(1, 0), .peer_app = abi.display.files, .peer_pid = 99, .sequence = 1 };
    try t.expectError(error.InvalidPeer, p.request(&request));
    request.peer_pid = 10;
    _ = try p.request(&request);
    try t.expect(!p.visible(secondary) and p.visible(primary));
    try t.expect(p.visible(try p.boundWindow(notes_app, 11, 0)));
}

test "individual retirement preserves app connection while monotonic window IDs prevent ABA" {
    const t = std.testing;
    var p = try Policy.init(1280, 800);
    _ = try p.create(&ownedWindowMessage(abi.display.files, 10, 0));
    _ = try p.create(&ownedWindowMessage(abi.display.files, 10, 1));
    try t.expectError(error.InvalidMessage, p.retire(abi.display.files, 10, 1));
    const request: abi.ServiceMessage = .{ .kind = abi.display.close_window, .flags = wire.flagsFor(1, 0), .peer_app = abi.display.files, .peer_pid = 10, .sequence = 1 };
    _ = try p.request(&request);
    _ = try p.retire(abi.display.files, 10, 1);
    try t.expectEqual(@as(u64, 10), p.appPid(abi.display.files));
    try t.expectEqual(@as(u64, 0), p.closed_counts[0]);
    try t.expectError(error.InvalidPeer, p.create(&ownedWindowMessage(abi.display.files, 10, 1)));
    _ = try p.create(&ownedWindowMessage(abi.display.files, 10, 2));
    try t.expect(p.visible(try p.boundWindow(abi.display.files, 10, 0)));
    _ = try p.closed(abi.display.files, 10);
    try t.expectEqual(@as(u64, 0), p.appPid(abi.display.files));
    try t.expectEqual(@as(u64, 1), p.closed_counts[0]);
    try t.expect(p.slotForWindow(abi.display.files, 10, 0) == null and p.slotForWindow(abi.display.files, 10, 2) == null);
    _ = try p.create(&ownedWindowMessage(abi.display.files, 20, 0));
    try t.expectEqual(@as(u64, 20), p.appPid(abi.display.files));
}

test "tabs-only header captures drag outside its accessory and move requests clamp only the owned window" {
    const t = std.testing;
    var p = try Policy.init(800, 600);
    _ = try p.create(&ownedWindowMessage(abi.display.files, 10, 0));
    const first = try p.boundWindow(abi.display.files, 10, 0);
    const original = p.entries[first].window.frame();
    const tab = p.entries[first].window.accessory();
    _ = try p.input(.{ .kind = .pointer_down, .code = 1, .x = @intCast(tab.x + 20), .y = @intCast(tab.y + 12) }, 1);
    const moved = try p.input(.{ .kind = .pointer_move, .x = 799, .y = 590 }, 2);
    try t.expectEqual(first, moved.routed.?.index);
    const released = try p.input(.{ .kind = .pointer_up, .code = 1, .x = 799, .y = 590 }, 3);
    try t.expectEqual(first, released.routed.?.index);
    try t.expect(!p.entries[first].window.capture);
    _ = try p.create(&ownedWindowMessage(abi.display.files, 10, 1));
    const second = try p.boundWindow(abi.display.files, 10, 1);
    var request: abi.ServiceMessage = .{ .kind = abi.display.move_window, .peer_app = abi.display.files, .peer_pid = 10, .flags = wire.flagsFor(1, 0), .sequence = 1 };
    std.mem.writeInt(i32, request.payload[0..4], -100, .little);
    std.mem.writeInt(i32, request.payload[4..8], 1000, .little);
    _ = try p.request(&request);
    try t.expectEqualDeep(original, p.entries[first].window.frame());
    try t.expectEqual(@as(i32, 0), p.entries[second].window.x);
    try t.expectEqual(@as(i32, @intCast(600 - p.entries[second].window.height - windows.Window.workarea_bottom)), p.entries[second].window.y);
    _ = try click(&p, second, .minimize);
    _ = try p.helloShell(abi.display.shell, 20);
    _ = try p.launch(abi.display.shell, 20, abi.display.files);
    try t.expectEqual(@as(?usize, second), p.focused);
    try t.expect(p.visible(second));
}

test "multiwindow tile grid keeps minimum client extents on the small reference screen" {
    const t = std.testing;
    var p = try Policy.init(800, 600);
    _ = try p.create(&ownedWindowMessage(abi.display.files, 10, 0));
    _ = try p.create(&createMessage(notes_app, 11));
    for (1..4) |id| _ = try p.create(&ownedWindowMessage(abi.display.files, 10, @intCast(id)));
    _ = try p.setTiled(true);
    for (p.peers[0..capacity], 0..) |peer, i| if (peer.pid != 0) {
        const rect = p.entries[i].window.frame();
        try t.expect(rect.width >= 320 and rect.height >= 240);
        try t.expect(rect.x >= 0 and rect.y >= windows.Window.workarea_top);
        try t.expect(@as(u32, @intCast(rect.x)) + rect.width <= 800);
        try t.expect(@as(u32, @intCast(rect.y)) + rect.height <= 600 - windows.Window.workarea_bottom);
        _ = try windows.header.layoutMode(peer.configuration.?.width, peer.configuration.?.header_tabs);
    };
}
