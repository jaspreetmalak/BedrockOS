//! Explicit SOFTWARE TEST RADIO. No RF, WPA cryptography, hardware or IP link.
//! Production must never select this backend automatically.
const std = @import("std");
const controller = @import("wifi.zig");
const wifi = controller.wifi;
pub const open_bss: wifi.Bss = .{ .ssid = .{ .bytes = fixed("Bedrock Test Open"), .len = 17 }, .bssid = .{ 2, 0, 0, 0, 1, 1 }, .channel = 1, .signal_dbm = -42, .security = .open };
pub const wpa2_bss: wifi.Bss = .{ .ssid = .{ .bytes = fixed("Bedrock Test WPA2"), .len = 17 }, .bssid = .{ 2, 0, 0, 0, 1, 2 }, .channel = 6, .signal_dbm = -56, .security = .wpa2_personal };
pub const unsupported_bss: wifi.Bss = .{ .ssid = .{ .bytes = fixed("Bedrock Test WPA3"), .len = 17 }, .bssid = .{ 2, 0, 0, 0, 1, 3 }, .channel = 11, .signal_dbm = -61, .security = .wpa3_personal };
fn fixed(comptime text: []const u8) [32]u8 {
    var output: [32]u8 = @splat(0);
    @memcpy(output[0..text.len], text);
    return output;
}
pub const Radio = struct {
    enabled: bool = false,
    linked_operation: u64 = 0,
    events: [32]controller.Event = undefined,
    head: usize = 0,
    count: usize = 0,
    fail_submit: bool = false,
    fail_poll: bool = false,
    hold_events: bool = false,
    joins: usize = 0,
    credential_length_seen: usize = 0,
    defer_poll: bool = false,
    poll_calls: usize = 0,

    pub fn backend(self: *Radio) controller.Backend {
        return .{ .context = self, .capabilities = .{ .scan = true, .open = true, .wpa2_psk = true }, .simulated = true, .set_enabled = setEnabled, .start_scan = startScan, .start_join = startJoin, .cancel = cancel, .disconnect = disconnect, .poll = poll };
    }
    /// Test-only event injection; bounded and explicit for stale/proof cases.
    pub fn push(self: *Radio, event: controller.Event) !void {
        if (self.count == self.events.len) return error.TestQueueFull;
        self.events[(self.head + self.count) % self.events.len] = event;
        self.count += 1;
    }
    pub fn loseLink(self: *Radio) !void {
        if (self.linked_operation != 0) try self.push(.{ .link_lost = .{ .operation = self.linked_operation } });
        self.linked_operation = 0;
    }
    fn selfOf(context: *anyopaque) *Radio {
        return @ptrCast(@alignCast(context));
    }
    fn setEnabled(context: *anyopaque, value: bool) !void {
        const self = selfOf(context);
        if (self.fail_submit) return error.TestDeviceFailed;
        self.enabled = value;
        if (!value) self.linked_operation = 0;
    }
    fn startScan(context: *anyopaque, operation: u64) !void {
        const self = selfOf(context);
        if (!self.enabled or self.fail_submit) return error.TestDeviceFailed;
        if (self.hold_events) return;
        if (self.events.len - self.count < 4) return error.TestQueueFull;
        try self.push(.{ .scan_result = .{ .operation = operation, .bss = open_bss } });
        try self.push(.{ .scan_result = .{ .operation = operation, .bss = wpa2_bss } });
        try self.push(.{ .scan_result = .{ .operation = operation, .bss = unsupported_bss } });
        try self.push(.{ .scan_complete = .{ .operation = operation } });
        self.defer_poll = true;
    }
    fn startJoin(context: *anyopaque, operation: u64, selected: wifi.Bss, credentials: []const u8) !void {
        const self = selfOf(context);
        if (!self.enabled or self.fail_submit) return error.TestDeviceFailed;
        self.joins += 1;
        self.credential_length_seen = credentials.len; // Counts only, no bytes.
        if (self.hold_events) return;
        const authenticated = selected.security == .open or std.mem.eql(u8, credentials, "test-passphrase");
        if (authenticated) {
            try self.push(.{ .joined = .{ .operation = operation, .bssid = selected.bssid, .security = selected.security, .authenticated = selected.security == .wpa2_personal } });
            self.linked_operation = operation;
        } else try self.push(.{ .failed = .{ .operation = operation, .failure = .authentication } });
        self.defer_poll = true;
    }
    fn cancel(_: *anyopaque, _: u64) !void {
        // Preserve queued events deliberately: Controller must reject stale IDs.
    }
    fn disconnect(context: *anyopaque) !void {
        const self = selfOf(context);
        self.linked_operation = 0;
        if (self.fail_submit) return error.TestDeviceFailed;
    }
    fn poll(context: *anyopaque) !?controller.Event {
        const self = selfOf(context);
        self.poll_calls += 1;
        if (self.fail_poll) return error.TestDeviceFailed;
        if (self.defer_poll) {
            self.defer_poll = false;
            return null;
        }
        if (self.count == 0) return null;
        const event = self.events[self.head];
        self.head = (self.head + 1) % self.events.len;
        self.count -= 1;
        return event;
    }
};
pub const TestRadio = Radio;
