//! System Wi-Fi controls use separate observation/control entitlements.
const std = @import("std");
const abi = @import("bedrock64");
const security = @import("security");
const wifi = @import("networkkit").wifi;
const user = @import("user_memory.zig");
pub const Live = Boundary(@import("wifi_runtime.zig"));

pub fn Boundary(comptime Runtime: type) type {
    return struct {
        pub fn serve(profile: security.sandbox.Profile, regions: []const user.Region, number: u64, arg0: u64, arg1: u64, arg2: u64, now: u64) !u64 {
            const observes = profile.mayRequest(.wifi_observe) or profile.mayRequest(.wifi_control);
            const controls = profile.mayRequest(.wifi_control);
            // Authorization precedes pointer translation, device work and request parsing.
            switch (number) {
                abi.syscall.wifi_status, abi.syscall.wifi_scan_read => if (!observes) return error.PermissionDenied,
                abi.syscall.wifi_scan_start, abi.syscall.wifi_join, abi.syscall.wifi_disconnect, abi.syscall.wifi_enable => if (!controls) return error.PermissionDenied,
                else => return error.UnsupportedSyscall,
            }
            if (arg1 != 0 or arg2 != 0) return error.InvalidRequest;
            switch (number) {
                abi.syscall.wifi_status => {
                    const physical = try user.translateWrite(regions, arg0, @sizeOf(abi.WifiStatus));
                    const status = Runtime.status();
                    try status.validate();
                    var output: abi.WifiStatus = .{ .revision = status.revision, .state = @intCast(@backingInt(status.state)), .failure = @intCast(@backingInt(status.failure)), .simulated = @intFromBool(status.simulated) };
                    if (status.current) |bss| {
                        output.has_current = 1;
                        output.current = encodeBss(bss);
                    }
                    copyout(physical, std.mem.asBytes(&output));
                },
                abi.syscall.wifi_scan_read => {
                    const physical = try user.translateWrite(regions, arg0, @sizeOf(abi.WifiScan));
                    const scan = try Runtime.scan();
                    try scan.validate();
                    var output: abi.WifiScan = .{ .generation = scan.generation, .count = @intCast(scan.count) };
                    for (scan.entries[0..scan.count], 0..) |bss, index| output.entries[index] = encodeBss(bss);
                    copyout(physical, std.mem.asBytes(&output));
                },
                abi.syscall.wifi_scan_start => {
                    if (arg0 != 0) return error.InvalidRequest;
                    try Runtime.startScan(now);
                },
                abi.syscall.wifi_join => {
                    var request: abi.WifiJoin = undefined;
                    // The secret exists only in bounded transient storage and is wiped
                    // on every path, including copy/validation/backend failures.
                    defer wipe(std.mem.asBytes(&request));
                    const physical = try user.translateRead(regions, arg0, @sizeOf(abi.WifiJoin));
                    const source: [*]const volatile u8 = @ptrFromInt(physical);
                    for (std.mem.asBytes(&request), 0..) |*byte, index| byte.* = source[index];
                    if (!zero(&request.reserved) or request.padding != 0 or request.credential_len > 63) return error.InvalidRequest;
                    const length: usize = request.credential_len;
                    if (!zero(request.credential[length..]) or (length != 0 and length < 8)) return error.InvalidRequest;
                    for (request.credential[0..length]) |byte| if (byte < 32 or byte > 126) return error.InvalidRequest;
                    var credentials: wifi.Credentials = .{ .bytes = request.credential, .len = request.credential_len };
                    defer credentials.clear();
                    try Runtime.join(request.generation, request.index, &credentials, now);
                },
                abi.syscall.wifi_disconnect => {
                    if (arg0 != 0) return error.InvalidRequest;
                    try Runtime.disconnect(now);
                },
                abi.syscall.wifi_enable => {
                    if (arg0 > 1) return error.InvalidRequest;
                    try Runtime.setEnabled(arg0 == 1, now);
                },
                else => unreachable,
            }
            return 0;
        }
    };
}

fn encodeBss(bss: wifi.Bss) abi.WifiBss {
    return .{ .ssid = bss.ssid.bytes, .ssid_len = bss.ssid.len, .bssid = bss.bssid, .channel = bss.channel, .signal_dbm = bss.signal_dbm, .security = @intCast(@backingInt(bss.security)) };
}
fn copyout(physical: u64, bytes: []const u8) void {
    const target: [*]volatile u8 = @ptrFromInt(physical);
    for (bytes, 0..) |byte, index| target[index] = byte;
}
fn wipe(bytes: []u8) void {
    const target: [*]volatile u8 = bytes.ptr;
    for (0..bytes.len) |index| target[index] = 0;
}
fn zero(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != 0) return false;
    return true;
}

test {
    _ = @import("wifi_syscalls_tests.zig");
}
