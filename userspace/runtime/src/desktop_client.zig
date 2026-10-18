//! One frame in flight; callers handle input while its immutable snapshot settles.
const std = @import("std");
const abi = @import("bedrock64");
const wire = @import("desktop_wire.zig");
const rt = @import("root.zig");
pub const Event = union(enum) { input: u64, configured: void, closed: void, acknowledged: u64 };
pub const Error = wire.Error || error{ ScreenChanged, UnexpectedAcknowledgement };
pub const Session = struct {
    endpoint: u64,
    token: u64 = 0,
    server_pid: ?u64 = null,
    config: ?wire.Config = null,
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
            abi.display.input => {
                return .{ .input = std.mem.readInt(u64, message.payload[0..8], .little) };
            },
            abi.display.close => {
                self.closing = true;
                return .closed;
            },
            abi.display.ack => {
                if (self.in_flight == null or message.sequence != self.in_flight.?) return error.UnexpectedAcknowledgement;
                self.in_flight = null;
                return .{ .acknowledged = message.sequence };
            },
            else => unreachable,
        }
    }
    pub fn awaitConfiguration(self: *Session) void {
        while (self.config == null) {
            _ = self.poll();
            rt.expect(rt.syscall(abi.syscall.sleep, 1, 0, 0) == 0);
        }
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
    pub fn launch(self: *Session) void {
        const message: abi.ServiceMessage = .{ .kind = abi.display.launch, .sequence = 1 };
        sendControl(self.endpoint, &message);
    }
    pub fn close(self: *Session) noreturn {
        rt.expect(rt.surfaceClose(self.token) == 0 and rt.serviceClose(self.endpoint) == 0);
        rt.write("[desktop-client] Files closed cleanly\n");
        rt.exit(0);
    }
};
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
