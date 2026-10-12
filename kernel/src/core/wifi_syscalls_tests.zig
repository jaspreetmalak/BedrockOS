const std = @import("std");
const abi = @import("bedrock64");
const security = @import("security");
const wifi = @import("networkkit").wifi;
const user = @import("user_memory.zig");
const requests = @import("wifi_syscalls.zig");
const Fake = struct {
    var calls: usize = 0;
    var pending = false;
    fn reset() void {
        calls = 0;
        pending = false;
    }
    pub fn status() wifi.Status {
        calls += 1;
        return .{ .state = .unavailable, .revision = 7, .simulated = false, .failure = .none, .current = null };
    }
    pub fn scan() !wifi.Scan {
        calls += 1;
        if (pending) return error.WouldBlock;
        return .{ .generation = 3, .count = 1, .entries = blk: {
            var entries = std.mem.zeroes([wifi.max_scan_results]wifi.Bss);
            entries[0] = .{ .ssid = try wifi.Ssid.init("Test SSID"), .bssid = .{ 2, 0, 0, 0, 0, 1 }, .channel = 6, .signal_dbm = -40, .security = .wpa2_personal };
            break :blk entries;
        } };
    }
    pub fn startScan(_: u64) !void {
        calls += 1;
    }
    pub fn setEnabled(_: bool, _: u64) !void {
        calls += 1;
    }
    pub fn disconnect(_: u64) !void {
        calls += 1;
    }
    pub fn join(generation: u64, index: usize, credentials: *wifi.Credentials, _: u64) !void {
        calls += 1;
        try std.testing.expectEqual(@as(u64, 3), generation);
        try std.testing.expectEqual(@as(usize, 0), index);
        try std.testing.expectEqualStrings("test-passphrase", credentials.bytes[0..credentials.len]);
        return error.StaleScan;
    }
};
const Boundary = requests.Boundary(Fake);
fn profile(mask: u32) !security.sandbox.Profile {
    return security.sandbox.Profile.init(1, mask, mask);
}
fn call(p: security.sandbox.Profile, regions: []const user.Region, number: u64, a: u64, b: u64, c: u64) !u64 {
    return Boundary.serve(p, regions, number, a, b, c, 1);
}
test "Wi-Fi has separate read and control authority with denial before device or memory work" {
    Fake.reset();
    const client = try profile(security.sandbox.bit(.network_client));
    for ([_]u64{ abi.syscall.wifi_status, abi.syscall.wifi_scan_read, abi.syscall.wifi_scan_start, abi.syscall.wifi_join, abi.syscall.wifi_disconnect, abi.syscall.wifi_enable }) |number|
        try std.testing.expectError(error.PermissionDenied, call(client, &.{}, number, 0xffffffffffffffff, 9, 9));
    const observer = try profile(security.sandbox.bit(.wifi_observe));
    for ([_]u64{ abi.syscall.wifi_scan_start, abi.syscall.wifi_join, abi.syscall.wifi_disconnect, abi.syscall.wifi_enable }) |number|
        try std.testing.expectError(error.PermissionDenied, call(observer, &.{}, number, 0, 0, 0));
    try std.testing.expectEqual(@as(usize, 0), Fake.calls);
}
test "Wi-Fi copyout validates full writable range before reading a snapshot" {
    Fake.reset();
    const p = try profile(security.sandbox.bit(.wifi_observe));
    var status: abi.WifiStatus = undefined;
    @memset(std.mem.asBytes(&status), 0xa5);
    const read_only = [_]user.Region{.{ .virtual = 0x1000, .physical = @intFromPtr(&status), .length = @sizeOf(abi.WifiStatus) }};
    try std.testing.expectError(error.InvalidUserRange, call(p, &read_only, abi.syscall.wifi_status, 0x1000, 0, 0));
    var maps = read_only;
    maps[0].writable = true;
    try std.testing.expectError(error.InvalidUserRange, call(p, &maps, abi.syscall.wifi_status, 0x1001, 0, 0));
    try std.testing.expectEqual(@as(usize, 0), Fake.calls);
    _ = try call(p, &maps, abi.syscall.wifi_status, 0x1000, 0, 0);
    try std.testing.expectEqual(@as(u64, 7), status.revision);
    try std.testing.expectEqual(@as(u8, 0), status.has_current);
    for (std.mem.asBytes(&status.current)) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    for (status.reserved) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
}
test "Wi-Fi scan copies only validated entries and preserves caller storage while pending" {
    Fake.reset();
    const p = try profile(security.sandbox.bit(.wifi_observe));
    var scan: abi.WifiScan = undefined;
    @memset(std.mem.asBytes(&scan), 0xa5);
    const maps = [_]user.Region{.{ .virtual = 0x2000, .physical = @intFromPtr(&scan), .length = @sizeOf(abi.WifiScan), .writable = true }};
    Fake.pending = true;
    try std.testing.expectError(error.WouldBlock, call(p, &maps, abi.syscall.wifi_scan_read, 0x2000, 0, 0));
    for (std.mem.asBytes(&scan)) |byte| try std.testing.expectEqual(@as(u8, 0xa5), byte);
    Fake.pending = false;
    _ = try call(p, &maps, abi.syscall.wifi_scan_read, 0x2000, 0, 0);
    try std.testing.expectEqual(@as(u32, 1), scan.count);
    try std.testing.expectEqualStrings("Test SSID", scan.entries[0].ssid[0..scan.entries[0].ssid_len]);
    for (std.mem.sliceAsBytes(scan.entries[1..])) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
}
test "Wi-Fi malformed join and reserved arguments cannot change radio state" {
    Fake.reset();
    const p = try profile(security.sandbox.bit(.wifi_control));
    var request: abi.WifiJoin = .{ .generation = 3, .index = 0 };
    const maps = [_]user.Region{.{ .virtual = 0x3000, .physical = @intFromPtr(&request), .length = @sizeOf(abi.WifiJoin) }};
    try std.testing.expectError(error.InvalidRequest, call(p, &maps, abi.syscall.wifi_enable, 2, 0, 0));
    try std.testing.expectError(error.InvalidRequest, call(p, &maps, abi.syscall.wifi_scan_start, 1, 0, 0));
    try std.testing.expectError(error.InvalidRequest, call(p, &maps, abi.syscall.wifi_disconnect, 0, 1, 0));
    try std.testing.expectError(error.InvalidUserRange, call(p, &maps, abi.syscall.wifi_join, 0x3001, 0, 0));
    request.credential_len = 64;
    try std.testing.expectError(error.InvalidRequest, call(p, &maps, abi.syscall.wifi_join, 0x3000, 0, 0));
    request.credential_len = 0;
    request.credential[62] = 1;
    try std.testing.expectError(error.InvalidRequest, call(p, &maps, abi.syscall.wifi_join, 0x3000, 0, 0));
    request.credential[62] = 0;
    request.reserved[0] = 1;
    try std.testing.expectError(error.InvalidRequest, call(p, &maps, abi.syscall.wifi_join, 0x3000, 0, 0));
    request.reserved[0] = 0;
    request.padding = 1;
    try std.testing.expectError(error.InvalidRequest, call(p, &maps, abi.syscall.wifi_join, 0x3000, 0, 0));
    try std.testing.expectEqual(@as(usize, 0), Fake.calls);
    request.padding = 0;
    request.credential_len = 15;
    @memcpy(request.credential[0..15], "test-passphrase");
    try std.testing.expectError(error.StaleScan, call(p, &maps, abi.syscall.wifi_join, 0x3000, 0, 0));
    try std.testing.expectEqual(@as(usize, 1), Fake.calls);
    // The kernel does not claim to erase user-owned input. SDK/caller owns it.
    try std.testing.expectEqualStrings("test-passphrase", request.credential[0..15]);
}
