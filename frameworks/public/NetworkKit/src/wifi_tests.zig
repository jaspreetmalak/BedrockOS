const std = @import("std");
const wifi = @import("wifi.zig");
const t = std.testing;

fn accessPoint(security: wifi.Security) !wifi.Bss {
    return .{ .ssid = try wifi.Ssid.init("Native radio"), .bssid = .{ 2, 0, 0, 0, 0, 1 }, .channel = 6, .signal_dbm = -44, .security = security };
}
fn snapshot() !wifi.Scan {
    var result: wifi.Scan = .{ .generation = 7, .count = 2, .entries = undefined };
    result.entries[0] = try accessPoint(.wpa2_personal);
    result.entries[1] = try accessPoint(.open);
    result.entries[1].bssid[5] = 2;
    return result;
}
fn expectCleared(credentials: *const wifi.Credentials) !void {
    try t.expectEqual(@as(u8, 0), credentials.len);
    for (credentials.bytes) |byte| try t.expectEqual(@as(u8, 0), byte);
}

const Mock = struct {
    state: wifi.Status = .{ .state = .idle, .failure = .none, .simulated = true, .revision = 1, .current = null },
    result: wifi.Scan = undefined,
    ready: bool = true,
    status_calls: usize = 0,
    start_calls: usize = 0,
    scan_calls: usize = 0,
    joins: usize = 0,
    disconnects: usize = 0,
    enable_calls: usize = 0,
    generation: u64 = 0,
    index: usize = 0,
    borrowed_length: u8 = 0,
    borrowed_valid: bool = false,
    enabled: bool = true,
    status_error: ?anyerror = null,
    start_error: ?anyerror = null,
    scan_error: ?anyerror = null,
    join_error: ?anyerror = null,
    disconnect_error: ?anyerror = null,
    enable_error: ?anyerror = null,

    fn from(context: *anyopaque) *Mock {
        return @ptrCast(@alignCast(context));
    }
    fn status(context: *anyopaque) anyerror!wifi.Status {
        const self = from(context);
        self.status_calls += 1;
        if (self.status_error) |err| return err;
        return self.state;
    }
    fn startScan(context: *anyopaque) anyerror!void {
        const self = from(context);
        self.start_calls += 1;
        if (self.start_error) |err| return err;
        self.ready = false;
    }
    fn scan(context: *anyopaque) anyerror!wifi.Scan {
        const self = from(context);
        self.scan_calls += 1;
        if (self.scan_error) |err| return err;
        if (!self.ready) return error.WouldBlock;
        return self.result;
    }
    fn join(context: *anyopaque, generation: u64, index: usize, credentials: *const wifi.Credentials) anyerror!void {
        const self = from(context);
        self.joins += 1;
        self.generation = generation;
        self.index = index;
        self.borrowed_length = credentials.len;
        // Inspect the synchronous borrow only; retain no secret bytes/pointer.
        self.borrowed_valid = credentials.len == 0 or std.mem.eql(u8, credentials.bytes[0..credentials.len], "passphrase");
        if (self.join_error) |err| return err;
    }
    fn disconnect(context: *anyopaque) anyerror!void {
        const self = from(context);
        self.disconnects += 1;
        if (self.disconnect_error) |err| return err;
    }
    fn setEnabled(context: *anyopaque, enabled: bool) anyerror!void {
        const self = from(context);
        self.enable_calls += 1;
        if (self.enable_error) |err| return err;
        self.enabled = enabled;
    }
    fn provider(self: *Mock) wifi.Provider {
        return .{ .context = self, .status = status, .startScan = startScan, .scan = scan, .join = join, .disconnect = disconnect, .setEnabled = setEnabled };
    }
};

test "Wi-Fi SSIDs copy binary bytes and hidden scans remain distinct from joining" {
    const binary = [_]u8{ 0, 255, 'N', 0, 'Z' };
    const ssid = try wifi.Ssid.init(&binary);
    try t.expectEqualSlices(u8, &binary, try ssid.slice());
    for (ssid.bytes[ssid.len..]) |byte| try t.expectEqual(@as(u8, 0), byte);
    const hidden: wifi.Ssid = .{};
    try hidden.validate();
    try t.expectEqual(@as(usize, 0), (try hidden.slice()).len);
    try t.expectError(error.InvalidSsid, wifi.Ssid.init(""));
    const full: [32]u8 = @splat(0xff);
    const maximum = try wifi.Ssid.init(&full);
    try t.expectEqualSlices(u8, &full, try maximum.slice());
    const too_long: [33]u8 = @splat('a');
    try t.expectError(error.InvalidSsid, wifi.Ssid.init(&too_long));
}

test "Wi-Fi SSID slicing rejects length overflow and dirty unused tails" {
    var ssid: wifi.Ssid = .{ .len = 33 };
    try t.expectError(error.InvalidSsid, ssid.slice());
    ssid = .{};
    ssid.bytes[31] = 'x';
    try t.expectError(error.InvalidSsid, ssid.validate());
    ssid = try wifi.Ssid.init("name");
    ssid.bytes[4] = 1;
    try t.expectError(error.InvalidSsid, ssid.slice());
}

test "Wi-Fi BSS validates MAC channel and dBm boundaries independently" {
    var bss = try accessPoint(.unsupported);
    try bss.validate();
    for ([_]u16{ 1, 233 }) |channel| for ([_]i16{ -127, 0 }) |signal| {
        bss.channel = channel;
        bss.signal_dbm = signal;
        try bss.validate();
    };
    bss.channel = 0;
    try t.expectError(error.InvalidBss, bss.validate());
    bss.channel = 234;
    try t.expectError(error.InvalidBss, bss.validate());
    bss.channel = 6;
    bss.signal_dbm = -128;
    try t.expectError(error.InvalidBss, bss.validate());
    bss.signal_dbm = 1;
    try t.expectError(error.InvalidBss, bss.validate());
    bss.signal_dbm = -44;
    bss.bssid = @splat(0);
    try t.expectError(error.InvalidBss, bss.validate());
    bss.bssid = @splat(255);
    try t.expectError(error.InvalidBss, bss.validate());
    bss.bssid = .{ 1, 0, 0, 0, 0, 1 };
    try t.expectError(error.InvalidBss, bss.validate());
}

test "Wi-Fi scan validates bounded used entries nonzero generation and unique BSSIDs" {
    var scan = try snapshot();
    try scan.validate();
    scan.count = 0;
    scan.entries = undefined;
    try scan.validate();
    scan.generation = 0;
    try t.expectError(error.InvalidScan, scan.validate());
    scan = try snapshot();
    scan.count = 17;
    try t.expectError(error.InvalidScan, scan.validate());
    scan = try snapshot();
    scan.entries[1].bssid = scan.entries[0].bssid;
    try t.expectError(error.InvalidScan, scan.validate());
    scan = try snapshot();
    scan.entries[1].ssid.len = 255;
    try t.expectError(error.InvalidSsid, scan.validate());
}

test "Wi-Fi credentials validate ASCII WPA2 limits canonical tail and volatile full clearing" {
    for ([_][]const u8{ "12345678", "passphrase", " space! " }) |passphrase| {
        var credentials = try wifi.Credentials.init(passphrase);
        try credentials.validate();
        try t.expectEqualSlices(u8, passphrase, credentials.bytes[0..credentials.len]);
        credentials.clear();
        try expectCleared(&credentials);
    }
    const maximum: [63]u8 = @splat('A');
    var credentials = try wifi.Credentials.init(&maximum);
    try credentials.validate();
    credentials.clear();
    try expectCleared(&credentials);
    const overflow: [64]u8 = @splat('A');
    try t.expectError(error.InvalidCredentials, wifi.Credentials.init(&overflow));
    for ([_][]const u8{ "", "short", "1234567\x00", "1234567\x7f", "1234567\xff" }) |invalid| try t.expectError(error.InvalidCredentials, wifi.Credentials.init(invalid));
    credentials = .{};
    try credentials.validate();
    credentials.len = 64;
    try t.expectError(error.InvalidCredentials, credentials.validate());
    credentials.clear();
    credentials.bytes[62] = 1;
    try t.expectError(error.InvalidCredentials, credentials.validate());
    credentials.clear();
    try expectCleared(&credentials);
}

test "Wi-Fi status enforces current failure and revision coherence for all states" {
    var status: wifi.Status = .{ .state = .idle, .failure = .none, .simulated = false, .revision = 1, .current = null };
    inline for (.{ wifi.State.unavailable, wifi.State.disabled, wifi.State.idle, wifi.State.scanning, wifi.State.associating }) |state| {
        status.state = state;
        try status.validate();
        status.current = try accessPoint(.open);
        try t.expectError(error.InvalidStatus, status.validate());
        status.current = null;
        status.failure = .device_lost;
        try t.expectError(error.InvalidStatus, status.validate());
        status.failure = .none;
    }
    status.state = .failed;
    try t.expectError(error.InvalidStatus, status.validate());
    inline for (.{ wifi.Failure.authentication, wifi.Failure.timeout, wifi.Failure.device_lost }) |failure| {
        status.failure = failure;
        try status.validate();
    }
    status.state = .connected;
    status.failure = .none;
    try t.expectError(error.InvalidStatus, status.validate());
    status.current = try accessPoint(.wpa2_personal);
    try status.validate();
    status.current.?.channel = 0;
    try t.expectError(error.InvalidBss, status.validate());
    status.current = try accessPoint(.open);
    status.revision = 0;
    try t.expectError(error.InvalidStatus, status.validate());
}

test "Wi-Fi Radio validates provider status and never converts callback failures into success" {
    var mock: Mock = .{};
    var radio = wifi.Radio.init(mock.provider());
    const status = try radio.status();
    try t.expect(status.simulated and status.state == .idle);
    mock.state.revision = 0;
    try t.expectError(error.InvalidStatus, radio.status());
    mock.status_error = error.PermissionDenied;
    try t.expectError(error.PermissionDenied, radio.status());
    try t.expectEqual(@as(usize, 3), mock.status_calls);
}

test "Wi-Fi startScan is explicit cached reads never rescan and successful renewal invalidates selection" {
    var mock: Mock = .{ .result = try snapshot() };
    var radio = wifi.Radio.init(mock.provider());
    _ = try radio.scan();
    _ = try radio.scan();
    try t.expectEqual(@as(usize, 0), mock.start_calls);
    const generation = radio.last_scan.?.generation;
    mock.start_error = error.WouldBlock;
    try t.expectError(error.WouldBlock, radio.startScan());
    try t.expectEqual(generation, radio.last_scan.?.generation);
    mock.start_error = null;
    try radio.startScan();
    try t.expect(radio.last_scan == null);
    try t.expectError(error.WouldBlock, radio.scan());
    try t.expect(radio.last_scan == null);
    mock.ready = true;
    mock.result.generation += 1;
    const renewed = try radio.scan();
    try t.expectEqual(generation + 1, renewed.generation);
    try t.expectEqual(@as(usize, 2), mock.start_calls);
}

test "Wi-Fi malformed scan results cannot replace a previously validated snapshot" {
    var mock: Mock = .{ .result = try snapshot() };
    var radio = wifi.Radio.init(mock.provider());
    _ = try radio.scan();
    mock.result.count = 17;
    try t.expectError(error.InvalidScan, radio.scan());
    try t.expectEqual(@as(usize, 2), radio.last_scan.?.count);
    mock.scan_error = error.DeviceLost;
    try t.expectError(error.DeviceLost, radio.scan());
    try t.expectEqual(@as(u64, 7), radio.last_scan.?.generation);
}

test "Wi-Fi join borrows a WPA2 secret synchronously and wipes it on success and provider error" {
    var mock: Mock = .{ .result = try snapshot() };
    var radio = wifi.Radio.init(mock.provider());
    _ = try radio.scan();
    var credentials = try wifi.Credentials.init("passphrase");
    try radio.join(7, 0, &credentials);
    try t.expect(mock.joins == 1 and mock.borrowed_valid and mock.borrowed_length == 10);
    try t.expectEqual(@as(u64, 7), mock.generation);
    try t.expectEqual(@as(usize, 0), mock.index);
    try expectCleared(&credentials);
    mock.join_error = error.AuthenticationFailed;
    credentials = try wifi.Credentials.init("passphrase");
    try t.expectError(error.AuthenticationFailed, radio.join(7, 0, &credentials));
    try expectCleared(&credentials);
    try t.expectEqual(@as(usize, 2), mock.joins);
}

test "Wi-Fi join wipes all failed preflights without calling the provider" {
    var mock: Mock = .{ .result = try snapshot() };
    var radio = wifi.Radio.init(mock.provider());
    var credentials = try wifi.Credentials.init("passphrase");
    try t.expectError(error.NoScan, radio.join(7, 0, &credentials));
    try expectCleared(&credentials);
    _ = try radio.scan();
    credentials = try wifi.Credentials.init("passphrase");
    try t.expectError(error.StaleScan, radio.join(6, 0, &credentials));
    try expectCleared(&credentials);
    credentials = try wifi.Credentials.init("passphrase");
    try t.expectError(error.InvalidSelection, radio.join(7, 2, &credentials));
    try expectCleared(&credentials);
    credentials = try wifi.Credentials.init("passphrase");
    credentials.bytes[62] = 'x';
    try t.expectError(error.InvalidCredentials, radio.join(7, 0, &credentials));
    try expectCleared(&credentials);
    credentials = .{ .len = 255, .bytes = @splat(0xa5) };
    try t.expectError(error.InvalidCredentials, radio.join(7, 0, &credentials));
    try expectCleared(&credentials);
    try t.expectEqual(@as(usize, 0), mock.joins);
}

test "Wi-Fi open hidden WPA2 and unsupported security selections never downgrade" {
    var mock: Mock = .{ .result = try snapshot() };
    var radio = wifi.Radio.init(mock.provider());
    _ = try radio.scan();
    var credentials = try wifi.Credentials.init("passphrase");
    try t.expectError(error.InvalidCredentials, radio.join(7, 1, &credentials));
    try expectCleared(&credentials);
    try radio.join(7, 1, &credentials);
    try t.expect(mock.borrowed_length == 0 and mock.joins == 1);
    try t.expectError(error.InvalidCredentials, radio.join(7, 0, &credentials));
    try expectCleared(&credentials);
    mock.result.entries[0].ssid = .{};
    _ = try radio.scan();
    credentials = try wifi.Credentials.init("passphrase");
    try t.expectError(error.HiddenSsid, radio.join(7, 0, &credentials));
    try expectCleared(&credentials);
    mock.result.entries[0].ssid = try wifi.Ssid.init("Unsupported");
    inline for (.{ wifi.Security.wpa3_personal, wifi.Security.unsupported }) |security| {
        mock.result.entries[0].security = security;
        _ = try radio.scan();
        credentials = try wifi.Credentials.init("passphrase");
        try t.expectError(error.UnsupportedSecurity, radio.join(7, 0, &credentials));
        try expectCleared(&credentials);
    }
    try t.expectEqual(@as(usize, 1), mock.joins);
}

test "Wi-Fi disable invalidates cached selection only on success and callbacks are not retried" {
    var mock: Mock = .{ .result = try snapshot() };
    var radio = wifi.Radio.init(mock.provider());
    _ = try radio.scan();
    mock.enable_error = error.PermissionDenied;
    try t.expectError(error.PermissionDenied, radio.setEnabled(false));
    try t.expect(radio.last_scan != null and mock.enabled);
    mock.enable_error = null;
    try radio.setEnabled(false);
    try t.expect(radio.last_scan == null and !mock.enabled);
    try radio.setEnabled(true);
    try t.expect(mock.enabled and mock.enable_calls == 3);
    mock.disconnect_error = error.DeviceLost;
    try t.expectError(error.DeviceLost, radio.disconnect());
    mock.disconnect_error = null;
    try radio.disconnect();
    try t.expectEqual(@as(usize, 2), mock.disconnects);
}
