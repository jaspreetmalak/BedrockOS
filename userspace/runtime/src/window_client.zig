//! One frame in flight; callers handle input while its immutable snapshot settles.
const std = @import("std");
const abi = @import("bedrock64");
const wire = @import("window_wire.zig");
const rt = @import("root.zig");
pub const WindowOptions = wire.WindowOptions;
pub const Event = union(enum) { input: u64, configured: void, closed: void, acknowledged: u64, status: wire.Status, rejected: u64 };
pub const Error = wire.Error || error{ ScreenChanged, UnexpectedAcknowledgement, InvalidWindowId, WindowCapacity, WindowIdExhausted, ServiceFailure, Busy, InvalidSession };
pub const ConfigurationState = enum { waiting, ready, closed };
pub const Session = struct {
    endpoint: u64,
    window_id: u16 = 0,
    token: u64 = 0,
    server_pid: ?u64 = null,
    config: ?wire.Config = null,
    status_sequence: u64 = 0,
    counter: u32 = 0,
    in_flight: ?u64 = null,
    mapped: bool = false,
    dirty: bool = true,
    closing: bool = false,

    pub fn connect() Session {
        const endpoint = rt.success(rt.serviceConnect(abi.display.service));
        const request: abi.ServiceMessage = .{ .kind = abi.display.heartbeat, .sequence = 1 };
        sendControl(endpoint, &request);
        return .{ .endpoint = endpoint };
    }
    /// One window belongs to this authenticated process; no client-supplied identity.
    pub fn openWindow(options: WindowOptions) Session {
        const endpoint = rt.success(rt.serviceConnect(abi.display.service));
        const request = wire.create(options) catch rt.exit(99);
        sendControl(endpoint, &request);
        return .{ .endpoint = endpoint };
    }
    pub fn poll(self: *Session) ?Event {
        var message: abi.ServiceMessage = .{};
        const result = rt.serviceReceive(self.endpoint, &message);
        if (result == abi.errno.again) return null;
        rt.expect(result == 0);
        return self.accept(&message) catch rt.exit(99);
    }
    /// Geometry updates never discard an older immutable frame still in flight.
    /// The server retires and acknowledges that exact epoch before remapping.
    pub fn accept(self: *Session, message: *const abi.ServiceMessage) Error!Event {
        try wire.decode(message, self.server_pid);
        return self.acceptDecoded(message);
    }
    fn acceptDecoded(self: *Session, message: *const abi.ServiceMessage) Error!Event {
        if (wire.windowId(message.flags) != self.window_id) return error.InvalidWindowId;
        switch (message.kind) {
            abi.display.configure => {
                const cfg = try wire.configuration(message);
                if (self.config) |old| {
                    if (cfg.sequence <= old.sequence) return error.StaleConfigure;
                    if (cfg.screen_width != old.screen_width or cfg.screen_height != old.screen_height) return error.ScreenChanged;
                }
                self.server_pid = message.peer_pid;
                self.config = cfg;
                self.counter = 0;
                self.dirty = true;
                return .configured;
            },
            abi.display.window_status => {
                const state = try wire.status(message);
                if (state.sequence <= self.status_sequence) return error.StaleConfigure;
                self.status_sequence = state.sequence;
                self.server_pid = message.peer_pid;
                self.dirty = true;
                return .{ .status = state };
            },
            abi.display.input => {
                return .{ .input = std.mem.readInt(u64, message.payload[0..8], .little) };
            },
            abi.display.close => {
                self.closing = true;
                return .closed;
            },
            abi.display.window_rejected => {
                self.closing = true;
                return .{ .rejected = std.mem.readInt(u64, message.payload[0..8], .little) };
            },
            abi.display.ack => {
                if (self.in_flight == null or message.sequence != self.in_flight.?) return error.UnexpectedAcknowledgement;
                self.in_flight = null;
                return .{ .acknowledged = message.sequence };
            },
            else => unreachable,
        }
    }
    pub fn configurationState(self: *const Session) ConfigurationState {
        if (self.closing) return .closed;
        return if (self.config == null) .waiting else .ready;
    }
    /// Shared client-local center and protected caption geometry. Hidden
    /// configurations retain the capability but expose no painting rectangle.
    pub fn headerLayout(self: *const Session) ?wire.header.Layout {
        const cfg = self.config orelse return null;
        if (!cfg.header_content or cfg.width == 0) return null;
        return wire.header.layoutMode(cfg.width, cfg.header_tabs) catch unreachable;
    }
    pub fn awaitConfiguration(self: *Session) void {
        while (self.configurationState() == .waiting) {
            _ = self.poll();
            if (self.configurationState() == .waiting) rt.expect(rt.syscall(abi.syscall.sleep, 1, 0, 0) == 0);
        }
        if (self.configurationState() == .closed) self.close();
        const cfg = self.config.?;
        const request: abi.SurfaceCreate = .{ .width = cfg.screen_width, .height = cfg.screen_height };
        self.token = rt.success(rt.surfaceCreate(&request));
    }
    pub fn map(self: *Session) []volatile u32 {
        rt.expect(self.in_flight == null and !self.mapped and self.token != 0);
        const cfg = self.config.?;
        const address = rt.success(rt.surfaceMap(self.token, 0, true));
        self.mapped = true;
        return rt.display_wire.pixels(address, 0, cfg.screen_width, cfg.screen_height) catch rt.exit(99);
    }
    pub fn submit(self: *Session) void {
        rt.expect(self.mapped and self.in_flight == null);
        const cfg = self.config.?;
        rt.expect(self.counter < std.math.maxInt(u32));
        self.counter += 1;
        const sequence = wire.frameSequence(cfg.sequence, self.counter) catch rt.exit(99);
        while (true) {
            const result = rt.surfaceSubmit(self.token, self.endpoint, sequence);
            if (result == 0) break;
            rt.expect(result == abi.errno.again);
            rt.expect(rt.syscall(abi.syscall.sleep, 1, 0, 0) == 0);
        }
        self.mapped = false;
        self.in_flight = sequence;
        self.dirty = false;
    }
    pub fn launch(self: *Session, app_id: u64) void {
        rt.expect(app_id == abi.display.files or app_id == abi.display.notes);
        const message: abi.ServiceMessage = .{ .kind = abi.display.launch, .sequence = app_id };
        sendControl(self.endpoint, &message);
    }
    pub fn requestResize(self: *Session, width: u32, height: u32) void {
        rt.expect(width != 0 and height != 0);
        const message: abi.ServiceMessage = .{ .kind = abi.display.resize_window, .flags = wire.flagsFor(self.window_id, 0), .sequence = 1, .width = width, .height = height };
        sendControl(self.endpoint, &message);
    }
    pub fn requestFocus(self: *Session) void {
        const message: abi.ServiceMessage = .{ .kind = abi.display.focus_window, .flags = wire.flagsFor(self.window_id, 0), .sequence = 1 };
        sendControl(self.endpoint, &message);
    }
    pub fn requestClose(self: *Session) void {
        const message: abi.ServiceMessage = .{ .kind = abi.display.close_window, .flags = wire.flagsFor(self.window_id, 0), .sequence = 1 };
        sendControl(self.endpoint, &message);
    }
    pub fn moveTo(self: *Session, x: i32, y: i32) void {
        var message: abi.ServiceMessage = .{ .kind = abi.display.move_window, .flags = wire.flagsFor(self.window_id, 0), .sequence = 1 };
        std.mem.writeInt(i32, message.payload[0..4], x, .little);
        std.mem.writeInt(i32, message.payload[4..8], y, .little);
        sendControl(self.endpoint, &message);
    }
    pub fn close(self: *Session) noreturn {
        if (self.token != 0) rt.expect(rt.surfaceClose(self.token) == 0);
        rt.expect(rt.serviceClose(self.endpoint) == 0);
        rt.write("[window-client] window closed cleanly\n");
        rt.exit(0);
    }
};

pub const RoutedEvent = struct { window_id: u16, event: Event };
/// One authenticated connection, with stable caller-owned Session slots. IDs
/// never repeat while the connection lives, including rejected/retired windows.
pub const Hub = struct {
    endpoint: u64 = 0,
    sessions: [4]?Session = @splat(null),
    next_id: u32 = 0,
    server_pid: ?u64 = null,

    pub fn connect() Hub {
        return .{ .endpoint = rt.success(rt.serviceConnect(abi.display.service)) };
    }
    pub fn activeCount(self: *const Hub) usize {
        var count: usize = 0;
        for (self.sessions) |entry| if (entry != null) {
            count += 1;
        };
        return count;
    }
    pub fn openWindow(self: *Hub, options: WindowOptions) Error!*Session {
        if (self.endpoint == 0) return error.InvalidSession;
        if (self.next_id > std.math.maxInt(u16)) return error.WindowIdExhausted;
        const slot = for (&self.sessions) |*entry| {
            if (entry.* == null) break entry;
        } else return error.WindowCapacity;
        var own_options = options;
        own_options.window_id = @intCast(self.next_id);
        const request = try wire.create(own_options);
        self.next_id += 1;
        try sendControlChecked(self.endpoint, &request);
        slot.* = .{ .endpoint = self.endpoint, .window_id = own_options.window_id, .server_pid = self.server_pid };
        return &slot.*.?;
    }
    pub fn session(self: *Hub, id: u16) ?*Session {
        for (&self.sessions) |*slot| if (slot.*) |*value| if (value.window_id == id) return value;
        return null;
    }
    pub fn accept(self: *Hub, message: *const abi.ServiceMessage) Error!?RoutedEvent {
        try wire.decode(message, self.server_pid);
        if (self.server_pid == null) self.server_pid = message.peer_pid;
        const id = wire.windowId(message.flags);
        const target = self.session(id) orelse {
            // Late ACKs/configurations cannot target a future slot after a
            // retirement, because the connection never reuses the old ID.
            if (@as(u32, id) < self.next_id) return null;
            return error.InvalidWindowId;
        };
        var event = try target.acceptDecoded(message);
        if (event == .configured and target.token == 0 and !target.closing and target.config.?.width != 0) {
            const cfg = target.config.?;
            const creation: abi.SurfaceCreate = .{ .width = cfg.screen_width, .height = cfg.screen_height, .reserved = id };
            const token = rt.surfaceCreate(&creation);
            if (abi.isError(token)) {
                target.requestClose();
                target.closing = true;
                event = .{ .rejected = token };
            } else target.token = token;
        }
        return .{ .window_id = id, .event = event };
    }
    pub fn poll(self: *Hub) ?RoutedEvent {
        var message: abi.ServiceMessage = .{};
        const result = rt.serviceReceive(self.endpoint, &message);
        if (result == abi.errno.again) return null;
        rt.expect(result == 0);
        return self.accept(&message) catch rt.exit(99);
    }
    pub fn retire(self: *Hub, target: *Session) Error!void {
        const slot = for (&self.sessions) |*entry| {
            if (entry.*) |*value| if (value == target) break entry;
        } else return error.InvalidSession;
        if (target.in_flight != null or target.mapped) return error.Busy;
        if (!target.closing) return error.Busy;
        if (target.token != 0) {
            const result = rt.surfaceClose(target.token);
            if (result == abi.errno.busy or result == abi.errno.again) return error.Busy;
            if (result != 0) return error.ServiceFailure;
            target.token = 0;
        }
        const message: abi.ServiceMessage = .{ .kind = abi.display.retire_window, .flags = wire.flagsFor(target.window_id, 0), .sequence = 1 };
        try sendControlChecked(self.endpoint, &message);
        slot.* = null;
    }
    pub fn close(self: *Hub) void {
        rt.expect(self.activeCount() == 0);
        rt.expect(rt.serviceClose(self.endpoint) == 0);
        self.endpoint = 0;
    }
};
fn sendControlChecked(endpoint: u64, message: *const abi.ServiceMessage) Error!void {
    while (true) {
        const result = rt.serviceSend(endpoint, message);
        if (result == 0) return;
        if (result != abi.errno.again) return error.ServiceFailure;
        rt.expect(rt.syscall(abi.syscall.sleep, 1, 0, 0) == 0);
    }
}
fn sendControl(endpoint: u64, message: *const abi.ServiceMessage) void {
    while (true) {
        const result = rt.serviceSend(endpoint, message);
        if (result == 0) return;
        rt.expect(result == abi.errno.again);
        rt.expect(rt.syscall(abi.syscall.sleep, 1, 0, 0) == 0);
    }
}

test "resize preserves old epoch lease until exact ACK and rejects forged or stale updates" {
    var session: Session = .{ .endpoint = 1 };
    var configuration = wire.configure(1, 700, 400, 1280, 800, 160, 100);
    configuration.peer_pid = 7;
    configuration.peer_app = abi.display.server;
    _ = try session.accept(&configuration);
    session.in_flight = try wire.frameSequence(1, 2);
    session.counter = 2;
    session.dirty = false;
    configuration.sequence = 2;
    configuration.width = 1000;
    std.mem.writeInt(i32, configuration.payload[8..12], 0, .little);
    _ = try session.accept(&configuration);
    try std.testing.expectEqual(@as(u64, 0x100000002), session.in_flight.?);
    try std.testing.expectEqual(@as(u32, 0), session.counter);
    try std.testing.expect(session.dirty);
    var ack: abi.ServiceMessage = .{ .kind = abi.display.ack, .peer_pid = 7, .peer_app = abi.display.server, .sequence = 0x200000001 };
    try std.testing.expectError(error.UnexpectedAcknowledgement, session.accept(&ack));
    ack.sequence = 0x100000002;
    _ = try session.accept(&ack);
    try std.testing.expect(session.in_flight == null);
    try std.testing.expectError(error.UnexpectedAcknowledgement, session.accept(&ack));
    try std.testing.expectError(error.StaleConfigure, session.accept(&configuration));
    configuration.sequence = 3;
    configuration.peer_pid = 8;
    try std.testing.expectError(error.InvalidDesktopMessage, session.accept(&configuration));
    configuration.peer_pid = 7;
    configuration.payload[0] = 0x20;
    configuration.payload[1] = 0x03;
    configuration.width = 800;
    try std.testing.expectError(error.ScreenChanged, session.accept(&configuration));
}
test "hidden viewport keeps pending snapshot and close requires no ACK" {
    var session: Session = .{ .endpoint = 1 };
    var configuration = wire.configure(1, 700, 400, 1280, 800, 160, 100);
    configuration.peer_pid = 7;
    configuration.peer_app = abi.display.server;
    _ = try session.accept(&configuration);
    session.in_flight = try wire.frameSequence(1, 1);
    configuration.sequence = 2;
    configuration.width = 0;
    configuration.height = 0;
    _ = try session.accept(&configuration);
    try std.testing.expect(session.config.?.width == 0 and session.in_flight != null);
    const close: abi.ServiceMessage = .{ .kind = abi.display.close, .peer_pid = 7, .peer_app = abi.display.server, .sequence = 3 };
    _ = try session.accept(&close);
    try std.testing.expect(session.closing and session.in_flight != null);
}

test "status pins service identity, rejects foreign authority and preserves in-flight frame" {
    var session: Session = .{ .endpoint = 1 };
    var configuration = wire.configure(1, 600, 400, 1280, 800, 40, 60);
    configuration.peer_pid = 7;
    configuration.peer_app = abi.display.server;
    _ = try session.accept(&configuration);
    session.in_flight = try wire.frameSequence(1, 1);
    var status: abi.ServiceMessage = .{ .kind = abi.display.window_status, .peer_pid = 7, .peer_app = abi.display.server, .sequence = 3, .width = 2, .height = 1 };
    std.mem.writeInt(u64, status.payload[0..8], 11, .little);
    const accepted = try session.accept(&status);
    try std.testing.expectEqual(@as(u64, 11), accepted.status.focused_pid);
    try std.testing.expectEqual(@as(u64, 0x100000001), session.in_flight.?);
    try std.testing.expectError(error.StaleConfigure, session.accept(&status));
    status.sequence = 4;
    status.peer_pid = 8;
    try std.testing.expectError(error.InvalidWindowMessage, session.accept(&status));
    status.peer_pid = 7;
    status.peer_app = abi.display.notes;
    try std.testing.expectError(error.InvalidWindowMessage, session.accept(&status));
    status.peer_app = abi.display.server;
    status.surface = 99;
    try std.testing.expectError(error.InvalidWindowMessage, session.accept(&status));
    status.surface = 0;
    status.flags = 1;
    try std.testing.expectError(error.InvalidWindowMessage, session.accept(&status));
    status.flags = 0;
    status.payload[15] = 1;
    try std.testing.expectError(error.InvalidWindowMessage, session.accept(&status));
    try std.testing.expectEqual(@as(u64, 3), session.status_sequence);
}

test "close before first configuration finishes startup without allocating a surface" {
    var session: Session = .{ .endpoint = 1 };
    try std.testing.expectEqual(ConfigurationState.waiting, session.configurationState());
    const close: abi.ServiceMessage = .{ .kind = abi.display.close, .peer_pid = 7, .peer_app = abi.display.server, .sequence = 1 };
    const event = try session.accept(&close);
    try std.testing.expect(event == .closed);
    try std.testing.expectEqual(ConfigurationState.closed, session.configurationState());
    try std.testing.expect(session.config == null and session.token == 0 and session.in_flight == null and !session.mapped);
}

test "startup closure wins over an already queued configure without requiring an ACK" {
    var session: Session = .{ .endpoint = 1 };
    var configuration = wire.configure(1, 600, 400, 1280, 800, 40, 60);
    configuration.peer_pid = 7;
    configuration.peer_app = abi.display.server;
    _ = try session.accept(&configuration);
    try std.testing.expectEqual(ConfigurationState.ready, session.configurationState());
    const close: abi.ServiceMessage = .{ .kind = abi.display.close, .peer_pid = 7, .peer_app = abi.display.server, .sequence = 2 };
    _ = try session.accept(&close);
    try std.testing.expectEqual(ConfigurationState.closed, session.configurationState());
    try std.testing.expect(session.token == 0 and session.in_flight == null);
}
test "integrated caption configuration preserves the old lease and hides its center until visible" {
    const t = std.testing;
    var session: Session = .{ .endpoint = 1 };
    var configuration = wire.configure(1, 636, 566, 1280, 800, 2, 44);
    configuration.peer_pid = 7;
    configuration.peer_app = abi.display.server;
    configuration.flags = abi.display.header_content;
    _ = try session.accept(&configuration);
    try t.expectEqual(@as(u32, 386), session.headerLayout().?.accessory.width);
    session.in_flight = try wire.frameSequence(1, 1);
    configuration.sequence = 2;
    configuration.width = 0;
    configuration.height = 0;
    _ = try session.accept(&configuration);
    try t.expect(session.config.?.header_content and session.headerLayout() == null);
    try t.expectEqual(@as(u64, 0x100000001), session.in_flight.?);
    const ack: abi.ServiceMessage = .{ .kind = abi.display.ack, .peer_pid = 7, .peer_app = abi.display.server, .sequence = 0x100000001 };
    _ = try session.accept(&ack);
    try t.expect(session.in_flight == null);
}

test "Hub routes independent epochs ACKs close and input to the owning stable Session" {
    const t = std.testing;
    var hub: Hub = .{ .endpoint = 1, .next_id = 2 };
    hub.sessions[0] = .{ .endpoint = 1, .window_id = 0, .token = 11 };
    hub.sessions[1] = .{ .endpoint = 1, .window_id = 1, .token = 12 };
    var configuration = wire.configure(1, 636, 566, 1280, 800, 2, 44);
    configuration.peer_pid = 7;
    configuration.peer_app = abi.display.server;
    configuration.flags = wire.flagsFor(0, abi.display.header_content | abi.display.header_tabs);
    try t.expectEqual(@as(u16, 0), (try hub.accept(&configuration)).?.window_id);
    configuration.sequence = 2;
    configuration.flags = wire.flagsFor(1, abi.display.header_content | abi.display.header_tabs);
    try t.expectEqual(@as(u16, 1), (try hub.accept(&configuration)).?.window_id);
    try t.expectEqual(@as(usize, 2), hub.activeCount());
    try t.expectEqual(@as(i32, 8), hub.session(1).?.headerLayout().?.accessory.x);
    hub.session(0).?.in_flight = try wire.frameSequence(1, 1);
    hub.session(1).?.in_flight = try wire.frameSequence(2, 1);
    var ack: abi.ServiceMessage = .{ .kind = abi.display.ack, .peer_pid = 7, .peer_app = abi.display.server, .sequence = wire.frameSequence(2, 1) catch unreachable, .flags = wire.flagsFor(1, 0) };
    const accepted = (try hub.accept(&ack)).?;
    try t.expect(accepted.window_id == 1 and accepted.event == .acknowledged);
    try t.expect(hub.session(1).?.in_flight == null and hub.session(0).?.in_flight != null);
    ack.flags = wire.flagsFor(0, 0);
    try t.expectError(error.UnexpectedAcknowledgement, hub.accept(&ack));
    ack.flags = wire.flagsFor(1, 0);
    ack.kind = abi.display.close;
    _ = try hub.accept(&ack);
    try t.expect(hub.session(1).?.closing and !hub.session(0).?.closing);
    ack.kind = abi.display.input;
    std.mem.writeInt(u64, ack.payload[0..8], 4, .little);
    try t.expectEqual(@as(u16, 1), (try hub.accept(&ack)).?.window_id);
}

test "Hub drains retired IDs without routing stale authority into a reused slot" {
    const t = std.testing;
    var hub: Hub = .{ .endpoint = 1, .next_id = 3, .server_pid = 7 };
    hub.sessions[0] = .{ .endpoint = 1, .window_id = 0, .token = 11 };
    hub.sessions[1] = .{ .endpoint = 1, .window_id = 2, .token = 13 };
    var message: abi.ServiceMessage = .{ .kind = abi.display.close, .flags = wire.flagsFor(1, 0), .peer_pid = 7, .peer_app = abi.display.server, .sequence = 2 };
    try t.expect((try hub.accept(&message)) == null);
    try t.expect(!hub.session(0).?.closing and !hub.session(2).?.closing);
    message.flags = wire.flagsFor(2, 0);
    message.peer_pid = 8;
    try t.expectError(error.InvalidDesktopMessage, hub.accept(&message));
    message.peer_pid = 7;
    message.flags = wire.flagsFor(3, 0);
    try t.expectError(error.InvalidWindowId, hub.accept(&message));
    message.flags = wire.flagsFor(2, 0);
    message.kind = abi.display.window_rejected;
    std.mem.writeInt(u64, message.payload[0..8], abi.errno.no_memory, .little);
    const rejected = (try hub.accept(&message)).?;
    try t.expect(rejected.window_id == 2 and rejected.event == .rejected);
    try t.expect(hub.session(2).?.closing and !hub.session(0).?.closing);
}
