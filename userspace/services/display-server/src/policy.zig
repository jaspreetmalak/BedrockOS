//! User-space window placement and focus, independent of framebuffer authority.
const std = @import("std");
const abi = @import("bedrock64");
pub const Window = struct { app: u64, pid: u64 = 0, x: i32, y: i32 = 64, width: u32 = 320, height: u32 = 240, sequence: u64 = 0 };
pub const Policy = struct {
    windows: [2]Window = .{ .{ .app = abi.display.client_a, .x = 24 }, .{ .app = abi.display.client_b, .x = 456 } },
    focused: usize = 0,
    pub fn frame(self: *Policy, message: *const abi.ServiceMessage) error{InvalidPeer}!usize {
        for (&self.windows, 0..) |*window, index| {
            if (window.app != message.peer_app) continue;
            if (window.pid != 0 and window.pid != message.peer_pid) return error.InvalidPeer;
            if (message.sequence <= window.sequence) return error.InvalidPeer;
            window.pid = message.peer_pid;
            window.sequence = message.sequence;
            return index;
        }
        return error.InvalidPeer;
    }
    pub fn close(self: *Policy, app: u64, pid: u64) error{InvalidPeer}!usize {
        for (&self.windows, 0..) |*window, index| {
            if (window.app == app and window.pid == pid) {
                window.pid = 0;
                window.sequence = 0;
                if (self.focused == index and self.windows[1 - index].pid != 0) self.focused = 1 - index;
                return index;
            }
        }
        return error.InvalidPeer;
    }
    pub fn input(self: *Policy, event: *const abi.DisplayInput) ?Window {
        if (event.kind == 1 or event.kind == 2 or event.kind == 3) {
            for (self.windows, 0..) |window, index| {
                const x = @as(i64, event.x) - window.x;
                const y = @as(i64, event.y) - window.y;
                if (window.pid != 0 and x >= 0 and y >= 0 and x < window.width and y < window.height) {
                    if (event.kind == 2) self.focused = index;
                    return window;
                }
            }
            return null;
        }
        const selected = self.windows[self.focused];
        return if (selected.pid != 0) selected else null;
    }
};
test "focus stays client-scoped and a restarted peer gets fresh sequence state" {
    var policy: Policy = .{};
    var message: abi.ServiceMessage = .{ .peer_app = abi.display.client_a, .peer_pid = 7, .sequence = 1 };
    try std.testing.expectEqual(@as(usize, 0), try policy.frame(&message));
    message.peer_app = abi.display.client_b;
    message.peer_pid = 8;
    _ = try policy.frame(&message);
    const click: abi.DisplayInput = .{ .kind = 2, .x = 460, .y = 80 };
    try std.testing.expectEqual(abi.display.client_b, policy.input(&click).?.app);
    const key: abi.DisplayInput = .{ .kind = 4, .code = 13 };
    try std.testing.expectEqual(@as(u64, 8), policy.input(&key).?.pid);
    const outside: abi.DisplayInput = .{ .kind = 2, .x = 400, .y = 10 };
    try std.testing.expect(policy.input(&outside) == null);
    try std.testing.expectError(error.InvalidPeer, policy.close(abi.display.client_a, 999));
    try std.testing.expectEqual(@as(u64, 7), policy.windows[0].pid);
    _ = try policy.close(abi.display.client_a, 7);
    message.peer_app = abi.display.client_a;
    message.peer_pid = 9;
    _ = try policy.frame(&message);
    try std.testing.expectError(error.InvalidPeer, policy.frame(&message));
    message.sequence = 2;
    message.peer_pid = 7;
    try std.testing.expectError(error.InvalidPeer, policy.frame(&message));
}
