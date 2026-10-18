const std = @import("std");
const abi = @import("driver_abi");
const api = @import("wifi_module_adapter.zig");
const core = @import("network_core");
const wifi = core.networkkit.wifi;
const Fake = struct {
    events: [3]abi.Event = @splat(.{}),
    count: usize = 0,
    cursor: usize = 0,
    active_poll: bool = false,
    sent: usize = 0,
    selected: abi.Bss = .{},
    secret: [63]u8 = @splat(0),
    secret_len: u32 = 0,
    override_status: u32 = 0,
    fn cast(context: *anyopaque) *Fake {
        return @ptrCast(@alignCast(context));
    }
    fn table(self: *Fake) abi.Radio {
        return .{ .context = self, .capabilities = 3, .enable = enable, .scan = scan, .join = join, .cancel = cancel, .disconnect = disconnect, .poll = poll, .send = send, .connected = connected, .mac = mac, .stop = stop, .report = report };
    }
    fn enable(_: *anyopaque, value: u8) callconv(.c) u32 {
        return if (value <= 1) 0 else @backingInt(abi.Status.invalid_abi);
    }
    fn scan(context: *anyopaque, operation: u64) callconv(.c) u32 {
        const self = cast(context);
        var bss: abi.Bss = .{ .ssid_len = 4, .bssid = .{ 2, 0, 0, 0, 0, 2 }, .channel = 6, .signal_dbm = -42, .security = 1 };
        @memcpy(bss.ssid[0..4], "Test");
        self.events[0] = .{ .kind = 1, .operation = operation, .bss = bss };
        self.events[1] = .{ .kind = 2, .operation = operation };
        self.count = 2;
        self.cursor = 0;
        return 0;
    }
    fn join(context: *anyopaque, operation: u64, bss: *const abi.Bss, secret: [*]const u8, length: u32, _: u64) callconv(.c) u32 {
        const self = cast(context);
        if (length > self.secret.len) return @backingInt(abi.Status.invalid_abi);
        self.selected = bss.*;
        @memcpy(self.secret[0..length], secret[0..length]);
        self.secret_len = length;
        self.events[0] = .{ .kind = 3, .operation = operation, .bssid = bss.bssid, .security = bss.security, .authenticated = 1 };
        self.count = 1;
        self.cursor = 0;
        return 0;
    }
    fn cancel(_: *anyopaque, _: u64) callconv(.c) u32 {
        return @backingInt(abi.Status.retired);
    }
    fn disconnect(_: *anyopaque) callconv(.c) u32 {
        return @backingInt(abi.Status.retired);
    }
    fn poll(context: *anyopaque, _: u64, output: *abi.Event) callconv(.c) u32 {
        const self = cast(context);
        self.active_poll = true;
        defer self.active_poll = false;
        if (self.override_status != 0) return self.override_status;
        if (self.cursor == self.count) return @backingInt(abi.Status.no_event);
        output.* = self.events[self.cursor];
        self.cursor += 1;
        return 0;
    }
    fn send(context: *anyopaque, _: [*]const u8, _: u32) callconv(.c) u32 {
        const self = cast(context);
        if (self.active_poll) return @backingInt(abi.Status.failed);
        self.sent += 1;
        return 0;
    }
    fn connected(_: *anyopaque) callconv(.c) u8 {
        return 1;
    }
    fn mac(_: *anyopaque, output: *[6]u8) callconv(.c) u32 {
        output.* = .{ 2, 0, 0, 0, 0, 1 };
        return 0;
    }
    fn stop(_: *anyopaque) callconv(.c) u32 {
        return @backingInt(abi.Status.retired);
    }
    fn report(_: *anyopaque, output: *abi.Report) callconv(.c) u32 {
        output.* = .{};
        return 0;
    }
};

test "generic module adapter carries real controller operations and retires lost hardware" {
    var fake: Fake = .{};
    const table = fake.table();
    var adapter: api.Adapter = .{};
    try adapter.init(&table, 0);
    var controller: core.wifi.Controller = .{};
    try controller.init(adapter.backend(), 0);
    try controller.setEnabled(true, 0);
    try controller.startScan(1);
    adapter.now = 2;
    controller.poll(2);
    const found = try controller.scan();
    try std.testing.expectEqual(@as(usize, 1), found.count);
    try std.testing.expectEqualStrings("Test", try found.entries[0].ssid.slice());
    var credentials = try wifi.Credentials.init("correct horse");
    adapter.now = 3;
    try controller.join(found.generation, 0, &credentials, 3);
    try std.testing.expectEqual(@as(u8, 0), credentials.len);
    try std.testing.expectEqualStrings("correct horse", fake.secret[0..fake.secret_len]);
    controller.poll(4);
    try std.testing.expectEqual(wifi.State.connected, controller.status().state);
    try std.testing.expect(api.Adapter.connected(&adapter));
    try std.testing.expectError(error.NetworkUnavailable, controller.disconnect(5));
    try std.testing.expectEqual(wifi.Failure.device_lost, controller.status().failure);
    try std.testing.expect(adapter.retired and !adapter.enabled);
    try std.testing.expectError(error.NetworkUnavailable, api.Adapter.send(&adapter, &.{}));
}
test "module event validation rejects unknown enums and lengths and moved owners" {
    var fake: Fake = .{};
    const table = fake.table();
    var adapter: api.Adapter = .{};
    try adapter.init(&table, 0);
    const backend = adapter.backend();
    fake.events[0] = .{ .kind = 3, .operation = 1, .security = 255, .bssid = .{ 2, 0, 0, 0, 0, 2 } };
    fake.count = 1;
    try std.testing.expectError(error.InvalidModuleEvent, backend.poll(backend.context));
    fake.events[0] = .{ .kind = 6, .length = 1281 };
    fake.cursor = 0;
    try std.testing.expectError(error.InvalidModuleEvent, backend.poll(backend.context));
    fake.override_status = 255;
    try std.testing.expectError(error.InvalidModuleStatus, backend.poll(backend.context));
    var moved = adapter;
    const stale = moved.backend();
    try std.testing.expectError(error.InvalidModuleAdapter, stale.start_scan(stale.context, 2));
    var malformed = table;
    malformed.poll = null;
    var rejected: api.Adapter = .{};
    try std.testing.expectError(error.InvalidModuleAbi, rejected.init(&malformed, 0));
}
const Reply = struct {
    adapter: *api.Adapter,
    failed: bool = false,
    fn ingest(context: *anyopaque, frame: []const u8) void {
        const self: *Reply = @ptrCast(@alignCast(context));
        api.Adapter.send(self.adapter, frame) catch {
            self.failed = true;
        };
    }
};
test "copied module Ethernet can produce a synchronous reply after callback return" {
    var fake: Fake = .{};
    const table = fake.table();
    var adapter: api.Adapter = .{};
    try adapter.init(&table, 0);
    adapter.enabled = true;
    var reply: Reply = .{ .adapter = &adapter };
    adapter.sink = .{ .context = &reply, .ingest = Reply.ingest };
    fake.events[0] = .{ .kind = 6, .length = 14 };
    fake.count = 1;
    const backend = adapter.backend();
    try std.testing.expectEqual(@as(?core.wifi.Event, null), try backend.poll(backend.context));
    try std.testing.expect(!reply.failed);
    try std.testing.expectEqual(@as(usize, 1), fake.sent);
}
