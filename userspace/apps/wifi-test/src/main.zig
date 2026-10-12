//! Protected Wi-Fi control acceptance. The only backend is an explicit test radio.
const std = @import("std");
const wifi = @import("networkkit").wifi;
const rt = @import("userspace_runtime");
const abi = @import("bedrock64");
pub const panic = std.debug.FullPanic(rt.panic);
var radio: wifi.Radio = undefined;
var snapshot: wifi.Scan = undefined;
const attempts = 128;
noinline fn tick() void {
    rt.expect(rt.syscall(abi.syscall.sleep, 1, 0, 0) == 0);
}
noinline fn scan() void {
    radio.startScan() catch rt.exit(99);
    for (0..attempts) |_| {
        snapshot = radio.scan() catch |err| switch (err) {
            error.WouldBlock => {
                tick();
                continue;
            },
            else => rt.exit(99),
        };
        return;
    }
    rt.exit(99);
}
noinline fn awaitState(wanted: wifi.State) wifi.Status {
    for (0..attempts) |_| {
        const status = radio.status() catch rt.exit(99);
        rt.expect(status.simulated);
        if (status.state == wanted) return status;
        tick();
    }
    rt.exit(99);
}
noinline fn cleared(credentials: *wifi.Credentials) void {
    rt.expect(credentials.len == 0);
    for (credentials.bytes) |byte| rt.expect(byte == 0);
}
export fn bedrock_user_main(parent: u64, inherited: u64, argument: u64) callconv(.c) noreturn {
    rt.markEntry();
    rt.expect(parent != 0 and inherited == 0 and argument <= 1);
    radio = wifi.Radio.init(rt.wifi.provider());
    const initial = radio.status() catch rt.exit(99);
    if (argument == 1) {
        rt.expect(!initial.simulated and initial.state == .unavailable and initial.current == null);
        rt.expect(rt.syscall(abi.syscall.wifi_scan_read, @intFromPtr(&snapshot), 0, 0) == abi.errno.network_unavailable);
        for ([_]u64{ abi.syscall.wifi_scan_start, abi.syscall.wifi_join, abi.syscall.wifi_disconnect, abi.syscall.wifi_enable }) |number|
            rt.expect(rt.syscall(number, 0xffffffffffffffff, 9, 9) == abi.errno.permission);
        rt.write("[user] Wi-Fi unavailable status verified\n[user] Wi-Fi observer control denied\n");
        rt.exit(45);
    }
    rt.expect(initial.simulated and initial.state == .disabled and initial.current == null);
    radio.setEnabled(true) catch rt.exit(99);
    scan();
    rt.expect(snapshot.count == 3 and snapshot.generation != 0);
    rt.expect(snapshot.entries[0].security == .open and snapshot.entries[1].security == .wpa2_personal and snapshot.entries[2].security == .wpa3_personal);
    const old_generation = snapshot.generation;
    // Bad output pointers must preserve a committed snapshot and generation.
    rt.expect(rt.syscall(abi.syscall.wifi_scan_read, 0x2000010000, 0, 0) == abi.errno.fault);
    rt.expect(rt.syscall(abi.syscall.wifi_scan_read, 0x20001df000, 0, 0) == abi.errno.fault);
    const same = radio.scan() catch rt.exit(99);
    rt.expect(same.generation == old_generation and same.count == snapshot.count);
    rt.write("[user] Wi-Fi scan verified\n");
    var credential = wifi.Credentials.init("test-passphrase") catch rt.exit(99);
    if (radio.join(old_generation, 2, &credential)) |_| rt.exit(99) else |err| rt.expect(err == error.UnsupportedSecurity);
    cleared(&credential);
    // Raw calls also enforce the selected security; the SDK is not the authority.
    var raw: abi.WifiJoin = .{ .generation = old_generation, .index = 2, .credential_len = 15 };
    @memcpy(raw.credential[0..15], "test-passphrase");
    rt.expect(rt.syscall(abi.syscall.wifi_join, @intFromPtr(&raw), 0, 0) == abi.errno.not_supported);
    raw.index = 1;
    raw.reserved[0] = 1;
    rt.expect(rt.syscall(abi.syscall.wifi_join, @intFromPtr(&raw), 0, 0) == abi.errno.invalid);
    raw.reserved[0] = 0;
    rt.expect(rt.syscall(abi.syscall.wifi_join, 0x20001df000, 0, 0) == abi.errno.fault);
    scan();
    rt.expect(snapshot.generation > old_generation);
    raw.generation = old_generation;
    rt.expect(rt.syscall(abi.syscall.wifi_join, @intFromPtr(&raw), 0, 0) == abi.errno.stale);
    @memset(&raw.credential, 0);
    credential = wifi.Credentials.init("bad-passphrase") catch rt.exit(99);
    radio.join(snapshot.generation, 1, &credential) catch rt.exit(99);
    cleared(&credential);
    const failed = awaitState(.failed);
    rt.expect(failed.failure == .authentication and failed.current == null);
    credential = wifi.Credentials.init("test-passphrase") catch rt.exit(99);
    radio.join(snapshot.generation, 1, &credential) catch rt.exit(99);
    cleared(&credential);
    const connected = awaitState(.connected);
    rt.expect(connected.current.?.security == .wpa2_personal);
    rt.expect(std.mem.eql(u8, &connected.current.?.bssid, &snapshot.entries[1].bssid));
    rt.write("[user] Wi-Fi authentication policy verified\n");
    radio.disconnect() catch rt.exit(99);
    _ = awaitState(.idle);
    credential = .{};
    radio.join(snapshot.generation, 0, &credential) catch rt.exit(99);
    cleared(&credential);
    rt.expect(awaitState(.connected).current.?.security == .open);
    radio.setEnabled(false) catch rt.exit(99);
    _ = awaitState(.disabled);
    rt.expect(rt.syscall(abi.syscall.wifi_scan_start, 0, 0, 0) == abi.errno.network_unavailable);
    rt.expect(rt.syscall(abi.syscall.wifi_enable, 2, 0, 0) == abi.errno.invalid);
    rt.expect(rt.syscall(abi.syscall.wifi_disconnect, 0, 1, 0) == abi.errno.invalid);
    rt.write("[user] Wi-Fi control lifecycle verified\n[user] Wi-Fi authority checks passed\n");
    rt.exit(45);
}
