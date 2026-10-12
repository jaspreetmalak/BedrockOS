//! Wi-Fi SDK transport for checked, separately entitled Bedrock64 controls.
const std = @import("std");
const wifi = @import("networkkit").wifi;
const runtime = @import("root.zig");
const abi = @import("bedrock64");
const wire = @import("wifi_wire.zig");
var context: u8 = 0;
pub fn provider() wifi.Provider {
    return .{ .context = &context, .status = status, .startScan = startScan, .scan = scan, .join = join, .disconnect = disconnect, .setEnabled = setEnabled };
}
fn checked(value: u64) !void {
    if (!abi.isError(value)) {
        if (value != 0) return error.InvalidProviderResult;
        return;
    }
    return switch (value) {
        abi.errno.again => error.WouldBlock,
        abi.errno.permission => error.PermissionDenied,
        abi.errno.fault => error.InvalidBuffer,
        abi.errno.invalid => error.InvalidRequest,
        abi.errno.network_unavailable => error.RadioUnavailable,
        abi.errno.not_supported => error.UnsupportedSecurity,
        abi.errno.stale => error.StaleScan,
        abi.errno.busy => error.Busy,
        else => error.IOError,
    };
}
fn status(_: *anyopaque) !wifi.Status {
    var raw: abi.WifiStatus = .{};
    try checked(runtime.syscall(abi.syscall.wifi_status, @intFromPtr(&raw), 0, 0));
    return wire.decodeStatus(raw);
}
fn startScan(_: *anyopaque) !void {
    try checked(runtime.syscall(abi.syscall.wifi_scan_start, 0, 0, 0));
}
fn scan(_: *anyopaque) !wifi.Scan {
    var raw: abi.WifiScan = .{};
    try checked(runtime.syscall(abi.syscall.wifi_scan_read, @intFromPtr(&raw), 0, 0));
    return wire.decodeScan(raw);
}
fn join(_: *anyopaque, generation: u64, index: usize, credentials: *const wifi.Credentials) !void {
    if (index >= wifi.max_scan_results) return error.InvalidRequest;
    var request: abi.WifiJoin = .{ .generation = generation, .index = @intCast(index), .credential_len = credentials.len, .credential = credentials.bytes };
    defer wipe(std.mem.asBytes(&request));
    try checked(runtime.syscall(abi.syscall.wifi_join, @intFromPtr(&request), 0, 0));
}
fn disconnect(_: *anyopaque) !void {
    try checked(runtime.syscall(abi.syscall.wifi_disconnect, 0, 0, 0));
}
fn setEnabled(_: *anyopaque, enabled: bool) !void {
    try checked(runtime.syscall(abi.syscall.wifi_enable, @intFromBool(enabled), 0, 0));
}
fn wipe(bytes: []u8) void {
    const pointer: [*]volatile u8 = bytes.ptr;
    for (0..bytes.len) |index| pointer[index] = 0;
}
