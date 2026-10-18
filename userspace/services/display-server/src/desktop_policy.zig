//! Bounded desktop policy. Resource mappings and scanout stay in the adapter.
const std = @import("std");
const ui = @import("axisui");
const windows = @import("window_server");
const abi = @import("bedrock64");
const wire = @import("userspace_runtime").desktop_wire;
const shell = @import("desktop_shell");

pub const Error = error{ InvalidPeer, InvalidMessage, StaleFrame, InvalidFrame, ConfigurationExhausted };
pub const files_index: usize = 0;
pub const shell_index: usize = 1;

/// Coalesce motion while preserving ordinary event order. A stalled client
/// gets an explicit gesture cancellation if its bounded backlog overflows;
/// dropping one release alone could leave a press active indefinitely.
pub fn queueInput(queue: anytype, event: ui.Event) void {
    if (queue.records.len < 2) @compileError("Desktop input needs space for cancellation and the latest event");
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

pub const Peer = struct {
    app: u64,
    pid: u64 = 0,
    configuration: ?wire.Config = null,
    cache_valid: bool = false,
    counter: u32 = 0,
};
pub const Routed = struct { index: usize, event: ui.Event };
pub const Change = struct {
    routed: ?Routed = null,
    configure_files: bool = false,
    close_files: bool = false,
    compose: bool = false,
    minimized: bool = false,
    restored: bool = false,
};
pub const Policy = struct {
    window: windows.Window,
    peers: [2]Peer = .{ .{ .app = abi.display.files }, .{ .app = abi.display.shell } },
    configure_sequence: u32 = 0,
    launch_requests: u64 = 0,
    files_closed: u64 = 0,
    launch_pending: bool = false,
    launch_after_close: bool = false,
    cursor: ui.Point = .{ .x = 0, .y = 0 },
    shell_capture: bool = false,
    pointer_press: ui.Point = .{ .x = 0, .y = 0 },
    pointer_moved: bool = false,
    previous_click: ui.Point = .{ .x = 0, .y = 0 },
    previous_click_tick: u64 = 0,
    previous_click_valid: bool = false,

    pub fn init(width: u32, height: u32) !Policy {
        if (width > 1280 or height > 800) return error.InvalidDesktopGeometry;
        var result: Policy = .{ .window = try windows.Window.init(width, height) };
        result.window.close();
        return result;
    }
    pub fn index(app: u64) Error!usize {
        return switch (app) {
            abi.display.files => files_index,
            abi.display.shell => shell_index,
            else => error.InvalidPeer,
        };
    }
    pub fn boundPeer(self: *const Policy, app: u64, pid: u64) Error!usize {
        const i = try index(app);
        if (pid == 0 or self.peers[i].pid != pid) return error.InvalidPeer;
        return i;
    }
    pub fn hello(self: *Policy, app: u64, pid: u64) Error!usize {
        const i = try index(app);
        if (pid == 0 or (self.peers[i].pid != 0 and self.peers[i].pid != pid)) return error.InvalidPeer;
        // A repeated hello does not rotate an epoch while a frame is in flight.
        if (self.peers[i].pid == pid) return i;
        self.peers[i] = .{ .app = app, .pid = pid };
        if (i == files_index) {
            self.window.open();
            self.launch_pending = false;
            self.previous_click_valid = false;
        }
        try self.configure(i);
        return i;
    }
    pub fn configure(self: *Policy, i: usize) Error!void {
        if (i >= self.peers.len or self.peers[i].pid == 0) return error.InvalidPeer;
        if (self.configure_sequence == std.math.maxInt(u32)) return error.ConfigurationExhausted;
        self.configure_sequence += 1;
        var rect = if (i == files_index) self.window.client() else ui.Rect{
            .x = 0,
            .y = 0,
            .width = self.window.screen_width,
            .height = self.window.screen_height,
        };
        if (i == files_index and !self.window.visible) {
            rect.width = 0;
            rect.height = 0;
        }
        self.peers[i].configuration = .{
            .sequence = self.configure_sequence,
            .width = rect.width,
            .height = rect.height,
            .screen_width = self.window.screen_width,
            .screen_height = self.window.screen_height,
            .origin_x = rect.x,
            .origin_y = rect.y,
        };
        self.peers[i].cache_valid = false;
        self.peers[i].counter = 0;
        self.previous_click_valid = false;
    }
    pub fn configurationMessage(self: *const Policy, i: usize) abi.ServiceMessage {
        const peer = self.peers[i];
        const cfg = peer.configuration.?;
        var message = wire.configure(cfg.sequence, cfg.width, cfg.height, cfg.screen_width, cfg.screen_height, cfg.origin_x, cfg.origin_y);
        message.peer_app = peer.app;
        message.peer_pid = peer.pid;
        return message;
    }
    /// Check before copying a read lease; commit only after every row is copied.
    pub fn frame(self: *const Policy, message: *const abi.ServiceMessage) Error!usize {
        const i = try self.boundPeer(message.peer_app, message.peer_pid);
        const peer = self.peers[i];
        const cfg = peer.configuration orelse return error.InvalidFrame;
        const epoch: u32 = @truncate(message.sequence >> 32);
        const counter: u32 = @truncate(message.sequence);
        if (message.kind != abi.display.frame or message.flags != 0 or message.surface == 0 or
            message.width != cfg.screen_width or message.height != cfg.screen_height or !zero(&message.payload)) return error.InvalidFrame;
        if (epoch != cfg.sequence or counter == 0 or counter <= peer.counter or cfg.width == 0 or
            (i == files_index and self.window.closed)) return error.StaleFrame;
        return i;
    }
    pub fn commitFrame(self: *Policy, i: usize, sequence: u64) void {
        std.debug.assert(@as(u32, @truncate(sequence >> 32)) == self.peers[i].configuration.?.sequence);
        self.peers[i].counter = @truncate(sequence);
        self.peers[i].cache_valid = true;
    }
    pub fn closed(self: *Policy, app: u64, pid: u64) Error!usize {
        const i = try self.boundPeer(app, pid);
        self.peers[i] = .{ .app = app };
        if (i == files_index) {
            self.window.close();
            self.files_closed += 1;
            self.previous_click_valid = false;
            if (self.launch_after_close) {
                self.launch_after_close = false;
                self.requestLaunch();
            }
        }
        return i;
    }
    fn requestLaunch(self: *Policy) void {
        if (self.launch_pending) return;
        self.launch_requests += 1;
        self.launch_pending = true;
    }
    /// Only an authenticated Shell endpoint can request a launch or restore.
    pub fn launch(self: *Policy, app: u64, pid: u64) Error!Change {
        if (try self.boundPeer(app, pid) != shell_index) return error.InvalidPeer;
        if (self.peers[files_index].pid == 0) {
            self.requestLaunch();
            return .{};
        }
        if (self.window.closed) {
            self.launch_after_close = true;
            return .{};
        }
        const restored = !self.window.visible;
        self.window.open();
        if (restored) try self.configure(files_index);
        return .{
            .restored = restored,
            .compose = true,
            .configure_files = restored,
            .routed = .{ .index = files_index, .event = .{ .kind = .redraw, .code = @intFromBool(restored) } },
        };
    }
    pub fn input(self: *Policy, event: ui.Event, tick: u64) Error!Change {
        var change: Change = .{};
        const before = self.window;
        const pointer = ui.Point{ .x = event.x, .y = event.y };
        const pointer_event = event.kind == .pointer_move or event.kind == .pointer_down or event.kind == .pointer_up;
        if (pointer_event) {
            change.compose = pointer.x != self.cursor.x or pointer.y != self.cursor.y;
            self.cursor = pointer;
        }
        if (event.kind == .pointer_down and event.code == 1) {
            self.pointer_press = pointer;
            self.pointer_moved = false;
        }
        if (event.kind == .pointer_move and (@abs(@as(i64, pointer.x) - self.pointer_press.x) >= 4 or
            @abs(@as(i64, pointer.y) - self.pointer_press.y) >= 4)) self.pointer_moved = true;
        const global_launch = event.kind == .key_down and event.modifiers & ui.input.modifiers.super != 0 and (event.code == 'e' or event.code == 13);
        const captured_by_files = self.window.capture or self.window.drag != null or self.window.pressed_control != null;
        const bar_accessible = !self.window.visible or self.window.mode != .fullscreen;
        const shell_pointer = pointer_event and !captured_by_files and (self.shell_capture or
            (!self.window.visible or (bar_accessible and pointer.y >= 0 and pointer.y < shell.bar_height)));
        if (global_launch or shell_pointer) {
            if (shell_pointer and event.kind == .pointer_down and event.code == 1) {
                self.shell_capture = true;
                self.window.focused = false;
            }
            if (event.kind == .pointer_up and event.code == 1) self.shell_capture = false;
            if (self.peers[shell_index].pid != 0) change.routed = .{ .index = shell_index, .event = event };
        } else if (self.window.route(event)) |routed| {
            var local = routed;
            if (event.kind == .pointer_up and event.code == 1) {
                const is_click = !self.pointer_moved and self.window.client().contains(pointer);
                if (is_click and self.previous_click_valid and tick -% self.previous_click_tick <= 50 and
                    @abs(@as(i64, pointer.x) - self.previous_click.x) < 4 and @abs(@as(i64, pointer.y) - self.previous_click.y) < 4)
                {
                    local.modifiers |= ui.input.modifiers.double_click;
                    self.previous_click_valid = false;
                } else self.previous_click_valid = is_click;
                self.previous_click_tick = tick;
                self.previous_click = pointer;
            }
            change.routed = .{ .index = files_index, .event = local };
        } else if (event.kind == .pointer_up and event.code == 1) self.previous_click_valid = false;
        const geometry_changed = before.x != self.window.x or before.y != self.window.y or before.width != self.window.width or
            before.height != self.window.height or before.mode != self.window.mode;
        if ((geometry_changed or before.visible != self.window.visible) and self.peers[files_index].pid != 0 and !self.window.closed) {
            try self.configure(files_index);
            change.configure_files = true;
            change.routed = null;
        }
        if (!before.closed and self.window.closed) {
            self.peers[files_index].cache_valid = false;
            change.close_files = self.peers[files_index].pid != 0;
            change.routed = null;
        }
        change.minimized = !before.minimized and self.window.minimized;
        change.compose = change.compose or before.visible != self.window.visible or before.focused != self.window.focused or
            before.hovered != self.window.hovered or before.pressed_control != self.window.pressed_control or geometry_changed;
        return change;
    }
};
pub fn zero(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != 0) return false;
    return true;
}
pub fn controlMessage(message: *const abi.ServiceMessage) Error!void {
    _ = try Policy.index(message.peer_app);
    if (message.peer_pid == 0 or message.flags != 0 or message.surface != 0 or message.width != 0 or message.height != 0 or !zero(&message.payload)) return error.InvalidMessage;
    switch (message.kind) {
        abi.display.heartbeat, abi.display.launch => if (message.sequence == 0) return error.InvalidMessage,
        abi.display.peer_closed => {},
        else => return error.InvalidMessage,
    }
}

/// The client paints a viewport at source0 using full-screen row stride.
/// Each retained cache keeps that same layout; pixels outside it are never used.
pub fn copyViewport(destination: []volatile u32, source: []const volatile u32, cfg: wire.Config) Error!void {
    try bitmapBounds(destination.len, source.len, cfg);
    for (0..cfg.height) |y| for (0..cfg.width) |x| {
        const offset = y * @as(usize, cfg.screen_width) + x;
        destination[offset] = source[offset];
    };
}
pub fn blitViewport(destination: []volatile u32, source: []const volatile u32, cfg: wire.Config) Error!void {
    try bitmapBounds(destination.len, source.len, cfg);
    if (cfg.origin_x < 0 or cfg.origin_y < 0 or @as(u64, @intCast(cfg.origin_x)) + cfg.width > cfg.screen_width or
        @as(u64, @intCast(cfg.origin_y)) + cfg.height > cfg.screen_height) return error.InvalidFrame;
    for (0..cfg.height) |y| for (0..cfg.width) |x| {
        const destination_offset = (y + @as(usize, @intCast(cfg.origin_y))) * cfg.screen_width + x + @as(usize, @intCast(cfg.origin_x));
        destination[destination_offset] = source[y * @as(usize, cfg.screen_width) + x];
    };
}
fn bitmapBounds(destination_len: usize, source_len: usize, cfg: wire.Config) Error!void {
    if (cfg.screen_width == 0 or cfg.screen_width > 1280 or cfg.screen_height == 0 or cfg.screen_height > 800 or
        cfg.width == 0 or cfg.width > cfg.screen_width or cfg.height == 0 or cfg.height > cfg.screen_height) return error.InvalidFrame;
    const count = @as(usize, cfg.screen_width) * cfg.screen_height;
    if (destination_len < count or source_len < count) return error.InvalidFrame;
}

fn click(policy: *Policy, control: windows.Control, tick: u64) !Change {
    const rect = policy.window.controlRect(control);
    const event: ui.Event = .{ .kind = .pointer_down, .code = 1, .x = @intCast(rect.x + 12), .y = @intCast(rect.y + 12) };
    _ = try policy.input(event, tick);
    var release = event;
    release.kind = .pointer_up;
    return policy.input(release, tick + 1);
}
fn frameMessage(policy: *const Policy, i: usize, counter: u32) abi.ServiceMessage {
    const peer = policy.peers[i];
    const cfg = peer.configuration.?;
    return .{ .kind = abi.display.frame, .peer_app = peer.app, .peer_pid = peer.pid, .surface = 9, .sequence = (@as(u64, cfg.sequence) << 32) | counter, .width = cfg.screen_width, .height = cfg.screen_height };
}
test "cache epochs reject stale dimensions and cannot cross restarted identities" {
    const t = std.testing;
    var p = try Policy.init(1280, 800);
    _ = try p.hello(abi.display.files, 10);
    var old = frameMessage(&p, files_index, 1);
    const i = try p.frame(&old);
    p.commitFrame(i, old.sequence);
    try t.expect(p.peers[i].cache_valid);
    const cfg = p.peers[i].configuration.?;
    try t.expectEqual(@as(u32, 956), cfg.width);
    try t.expectEqual(@as(i32, 162), cfg.origin_x);
    try t.expectError(error.StaleFrame, p.frame(&old));
    _ = try click(&p, .maximize, 2);
    try t.expect(!p.peers[i].cache_valid);
    try t.expectError(error.StaleFrame, p.frame(&old));
    old = frameMessage(&p, i, 1);
    old.width -= 1;
    try t.expectError(error.InvalidFrame, p.frame(&old));
    _ = try p.closed(abi.display.files, 10);
    _ = try p.hello(abi.display.files, 11);
    try t.expectError(error.InvalidPeer, p.frame(&old));
    try t.expectError(error.InvalidPeer, p.closed(abi.display.files, 10));
    try t.expect(!p.peers[i].cache_valid);
    try t.expectEqual(@as(u64, 11), p.peers[i].pid);
}
test "minimize retains the process while hidden and restored frames use fresh epochs" {
    const t = std.testing;
    var p = try Policy.init(1280, 800);
    _ = try p.hello(abi.display.shell, 20);
    _ = try p.hello(abi.display.files, 10);
    const message = frameMessage(&p, files_index, 1);
    p.commitFrame(try p.frame(&message), message.sequence);
    const epoch = p.peers[files_index].configuration.?.sequence;
    try t.expect((try click(&p, .minimize, 0)).minimized);
    try t.expect(!p.window.visible and !p.peers[files_index].cache_valid);
    try t.expectEqual(@as(u32, 0), p.peers[files_index].configuration.?.width);
    try t.expectError(error.StaleFrame, p.frame(&message));
    try t.expectError(error.InvalidPeer, p.launch(abi.display.files, 10));
    try t.expect((try p.launch(abi.display.shell, 20)).restored);
    try t.expect(p.peers[files_index].configuration.?.sequence > epoch);
    try t.expectEqual(@as(u64, 10), p.peers[files_index].pid);
    const restored_frame = frameMessage(&p, files_index, 1);
    p.commitFrame(try p.frame(&restored_frame), restored_frame.sequence);
    try t.expect(p.peers[files_index].cache_valid);
    try t.expectEqual(@as(u64, 0), p.launch_requests);
    try t.expect((try click(&p, .close, 10)).close_files);
    try t.expect(!p.peers[files_index].cache_valid);
    _ = try p.launch(abi.display.shell, 20);
    try t.expectEqual(@as(u64, 0), p.launch_requests);
    _ = try p.closed(abi.display.files, 10);
    try t.expectEqual(@as(u64, 1), p.launch_requests);
    _ = try p.launch(abi.display.shell, 20);
    try t.expectEqual(@as(u64, 1), p.launch_requests);
}
test "focused input capture and fullscreen keys stay in window policy" {
    const t = std.testing;
    var p = try Policy.init(1280, 800);
    _ = try p.hello(abi.display.files, 10);
    _ = try p.hello(abi.display.shell, 20);
    var change = try p.input(.{ .kind = .pointer_down, .code = 1, .x = 400, .y = 300 }, 1);
    try t.expectEqual(files_index, change.routed.?.index);
    change = try p.input(.{ .kind = .pointer_up, .code = 1, .x = 110, .y = 20 }, 2);
    try t.expectEqual(files_index, change.routed.?.index);
    try t.expect(!p.window.capture);
    change = try p.input(.{ .kind = .key_down, .code = windows.key.f11 }, 3);
    try t.expect(change.configure_files and change.routed == null);
    try t.expectEqual(windows.Mode.fullscreen, p.window.mode);
    const epoch = p.configure_sequence;
    _ = try p.input(.{ .kind = .key_down, .code = windows.key.f11 }, 4);
    try t.expectEqual(epoch, p.configure_sequence);
    _ = try p.input(.{ .kind = .key_up, .code = windows.key.f11 }, 5);
    _ = try p.input(.{ .kind = .key_down, .code = @backingInt(ui.input.Key.escape) }, 6);
    try t.expectEqual(windows.Mode.floating, p.window.mode);
    change = try p.input(.{ .kind = .key_down, .code = 'e', .modifiers = ui.input.modifiers.super }, 7);
    try t.expectEqual(shell_index, change.routed.?.index);
    try t.expectEqual(@as(u64, 0), p.launch_requests);
    _ = try p.input(.{ .kind = .pointer_down, .code = 1, .x = 110, .y = 20 }, 8);
    change = try p.input(.{ .kind = .text, .code = 'a' }, 9);
    try t.expect(change.routed == null);
}
test "title drag rotates origin epoch and caption presses never leak to Files" {
    const t = std.testing;
    var p = try Policy.init(1280, 800);
    _ = try p.hello(abi.display.files, 10);
    const first = p.configure_sequence;
    var change = try p.input(.{ .kind = .pointer_down, .code = 1, .x = 640, .y = 85 }, 0);
    try t.expect(change.routed == null);
    change = try p.input(.{ .kind = .pointer_move, .x = 600, .y = 60 }, 1);
    try t.expect(change.configure_files and change.routed == null);
    try t.expect(p.configure_sequence > first);
    try t.expectEqual(@as(i32, 122), p.peers[files_index].configuration.?.origin_x);
    change = try p.input(.{ .kind = .pointer_up, .code = 1, .x = 600, .y = 60 }, 2);
    try t.expect(change.routed == null and p.window.drag == null);
}
test "desktop motion coalescing preserves press release and modifier boundaries" {
    var queue: ui.Queue(4) = .{};
    queueInput(&queue, .{ .kind = .pointer_down, .code = 1 });
    queueInput(&queue, .{ .kind = .pointer_move, .x = 10 });
    queueInput(&queue, .{ .kind = .pointer_move, .x = 20 });
    queueInput(&queue, .{ .kind = .pointer_move, .x = 30, .modifiers = ui.input.modifiers.control });
    queueInput(&queue, .{ .kind = .pointer_up, .code = 1 });
    try std.testing.expectEqual(ui.input.Kind.pointer_down, queue.pop().?.kind);
    try std.testing.expectEqual(@as(i16, 20), queue.pop().?.x);
    try std.testing.expectEqual(ui.input.modifiers.control, queue.pop().?.modifiers);
    try std.testing.expectEqual(ui.input.Kind.pointer_up, queue.pop().?.kind);
    try std.testing.expect(queue.pop() == null);
}
test "input overflow cancels stale gestures before delivering the outside release" {
    var queue: ui.Queue(4) = .{};
    queueInput(&queue, .{ .kind = .pointer_down, .code = 1 });
    for (0..3) |_| queueInput(&queue, .{ .kind = .text, .code = 'a' });
    queueInput(&queue, .{ .kind = .pointer_up, .code = 1, .x = -20 });
    try std.testing.expectEqualDeep(ui.Event{ .kind = .redraw, .code = 1 }, queue.pop().?);
    try std.testing.expectEqualDeep(ui.Event{ .kind = .pointer_up, .code = 1, .x = -20 }, queue.pop().?);
    try std.testing.expect(queue.pop() == null);
    for (0..12) |_| queueInput(&queue, .{ .kind = .text, .code = 'a' });
    try std.testing.expectEqualDeep(ui.Event{ .kind = .redraw, .code = 1 }, queue.pop().?);
}
test "retained viewport copies respect full-screen stride and compose only configured bounds" {
    const t = std.testing;
    var source: [42]u32 = @splat(1);
    var cache: [42]u32 = @splat(0xdeadbeef);
    var screen: [42]u32 = @splat(0x12345678);
    const cfg: wire.Config = .{ .sequence = 1, .width = 3, .height = 2, .screen_width = 8, .screen_height = 5, .origin_x = 4, .origin_y = 2 };
    source[1] = 7;
    source[9] = 9;
    try copyViewport(cache[1..41], source[1..41], cfg);
    try t.expectEqual(@as(u32, 7), cache[1]);
    try t.expectEqual(@as(u32, 9), cache[9]);
    try t.expectEqual(@as(u32, 0xdeadbeef), cache[4]);
    try blitViewport(screen[1..41], cache[1..41], cfg);
    try t.expectEqual(@as(u32, 7), screen[1 + 2 * 8 + 4]);
    try t.expectEqual(@as(u32, 9), screen[1 + 3 * 8 + 4]);
    try t.expectEqual(@as(u32, 0x12345678), screen[0]);
    try t.expectEqual(@as(u32, 0x12345678), screen[41]);
    try t.expectEqual(@as(u32, 0x12345678), screen[1 + 2 * 8 + 3]);
    var invalid = cfg;
    invalid.origin_x = 6;
    try t.expectError(error.InvalidFrame, blitViewport(screen[1..41], cache[1..41], invalid));
    try t.expectError(error.InvalidFrame, copyViewport(cache[1..41], source[1..40], cfg));
}

test "duplicate hello preserves an in-flight epoch and rejects replacement or forged controls" {
    const t = std.testing;
    var p = try Policy.init(1280, 800);
    _ = try p.hello(abi.display.files, 10);
    const before = frameMessage(&p, files_index, 1);
    _ = try p.hello(abi.display.files, 10);
    try t.expectEqual(files_index, try p.frame(&before));
    try t.expectError(error.InvalidPeer, p.hello(abi.display.files, 11));
    try t.expectError(error.InvalidPeer, p.hello(999, 10));
    var heartbeat_message: abi.ServiceMessage = .{ .kind = abi.display.heartbeat, .peer_app = abi.display.files, .peer_pid = 10, .sequence = 1 };
    try controlMessage(&heartbeat_message);
    heartbeat_message.flags = 1;
    try t.expectError(error.InvalidMessage, controlMessage(&heartbeat_message));
    heartbeat_message.flags = 0;
    heartbeat_message.payload[15] = 1;
    try t.expectError(error.InvalidMessage, controlMessage(&heartbeat_message));
    heartbeat_message.payload[15] = 0;
    heartbeat_message.surface = 8;
    try t.expectError(error.InvalidMessage, controlMessage(&heartbeat_message));
    try t.expectEqual(@as(u64, 10), p.peers[files_index].pid);
    try t.expectEqual(@as(u64, 0), p.files_closed);
}
