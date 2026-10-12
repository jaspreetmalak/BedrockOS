const std = @import("std");
const private = @import("wifi.zig");
const wifi = private.wifi;
const fixture = @import("wifi_test_radio.zig");
fn begin(controller: *private.Controller, radio: *fixture.Radio) !void {
    try controller.init(radio.backend(), 0);
    try controller.setEnabled(true, 0);
    try controller.startScan(1);
    pump(controller, 2);
}
fn pump(controller: *private.Controller, now: u64) void {
    controller.poll(now);
    controller.poll(now);
}
fn cleared(credentials: *const wifi.Credentials) !void {
    try std.testing.expectEqual(@as(u8, 0), credentials.len);
    for (credentials.bytes) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
}

test "explicit simulated radio scans and requires joined proof for open and WPA2 links" {
    var controller: private.Controller = .{};
    var radio: fixture.Radio = .{};
    try begin(&controller, &radio);
    const scan = try controller.scan();
    try scan.validate();
    try std.testing.expectEqual(@as(usize, 3), scan.count);
    try std.testing.expectEqual(scan.generation, (try controller.scan()).generation);
    var credentials: wifi.Credentials = .{};
    try controller.join(scan.generation, 0, &credentials, 3);
    try cleared(&credentials);
    try std.testing.expectEqual(wifi.State.associating, controller.status().state);
    try std.testing.expect(controller.status().current == null);
    pump(&controller, 4);
    var status = controller.status();
    try status.validate();
    try std.testing.expectEqual(wifi.State.connected, status.state);
    try std.testing.expect(status.simulated);
    try controller.disconnect(5);
    credentials = try wifi.Credentials.init("test-passphrase");
    try controller.join(scan.generation, 1, &credentials, 6);
    try cleared(&credentials);
    pump(&controller, 7);
    status = controller.status();
    try status.validate();
    try std.testing.expectEqual(wifi.Security.wpa2_personal, status.current.?.security);
    try std.testing.expect(std.mem.indexOf(u8, std.mem.asBytes(&controller), "test-passphrase") == null);
    try std.testing.expect(std.mem.indexOf(u8, std.mem.asBytes(&radio), "test-passphrase") == null);
}
test "all join preflight and submission returns wipe canonical credentials without downgrade" {
    var controller: private.Controller = .{};
    var radio: fixture.Radio = .{};
    try begin(&controller, &radio);
    const scan = try controller.scan();
    var credentials = try wifi.Credentials.init("test-passphrase");
    try std.testing.expectError(error.StaleScan, controller.join(scan.generation + 1, 1, &credentials, 3));
    try cleared(&credentials);
    credentials = try wifi.Credentials.init("test-passphrase");
    try std.testing.expectError(error.InvalidSelection, controller.join(scan.generation, 16, &credentials, 3));
    try cleared(&credentials);
    credentials = try wifi.Credentials.init("test-passphrase");
    try std.testing.expectError(error.UnsupportedSecurity, controller.join(scan.generation, 2, &credentials, 3));
    try cleared(&credentials);
    credentials = try wifi.Credentials.init("test-passphrase");
    credentials.bytes[62] = 'x';
    try std.testing.expectError(error.InvalidCredentials, controller.join(scan.generation, 1, &credentials, 3));
    try cleared(&credentials);
    controller.backend.capabilities.wpa2_psk = false;
    credentials = try wifi.Credentials.init("test-passphrase");
    try std.testing.expectError(error.UnsupportedSecurity, controller.join(scan.generation, 1, &credentials, 3));
    try cleared(&credentials);
    controller.backend.capabilities.wpa2_psk = true;
    radio.fail_submit = true;
    credentials = try wifi.Credentials.init("test-passphrase");
    try std.testing.expectError(error.NetworkUnavailable, controller.join(scan.generation, 1, &credentials, 3));
    try cleared(&credentials);
    try std.testing.expectEqual(@as(usize, 0), radio.joins);
    try std.testing.expect(controller.status().current == null);
}
test "fresh scan generations and cancelled association reject every stale completion" {
    var controller: private.Controller = .{};
    var radio: fixture.Radio = .{};
    try begin(&controller, &radio);
    const first = try controller.scan();
    try controller.startScan(3);
    try std.testing.expectError(error.WouldBlock, controller.scan());
    pump(&controller, 4);
    const second = try controller.scan();
    try std.testing.expect(second.generation > first.generation);
    var credentials: wifi.Credentials = .{};
    try std.testing.expectError(error.StaleScan, controller.join(first.generation, 0, &credentials, 5));
    radio.hold_events = true;
    try controller.join(second.generation, 0, &credentials, 5);
    const old = controller.operation;
    try controller.disconnect(6);
    try controller.join(second.generation, 0, &credentials, 7);
    const current = controller.operation;
    try std.testing.expect(current > old);
    try radio.push(.{ .joined = .{ .operation = old, .bssid = fixture.open_bss.bssid, .security = .open, .authenticated = false } });
    controller.poll(8);
    try std.testing.expectEqual(wifi.State.associating, controller.status().state);
    try radio.push(.{ .joined = .{ .operation = current, .bssid = fixture.open_bss.bssid, .security = .open, .authenticated = false } });
    controller.poll(9);
    try std.testing.expectEqual(wifi.State.connected, controller.status().state);
    try std.testing.expect(controller.stale_events != 0);
}
test "association timeout disable link loss and failed device never leave a phantom current link" {
    var controller: private.Controller = .{};
    var radio: fixture.Radio = .{};
    try begin(&controller, &radio);
    const scan = try controller.scan();
    radio.hold_events = true;
    var credentials: wifi.Credentials = .{};
    try controller.join(scan.generation, 0, &credentials, 3);
    const stale = controller.operation;
    controller.poll(3 + private.association_timeout_ticks);
    try std.testing.expectEqual(wifi.Failure.timeout, controller.status().failure);
    try std.testing.expect(controller.status().current == null);
    try controller.setEnabled(false, 1004);
    try radio.push(.{ .joined = .{ .operation = stale, .bssid = fixture.open_bss.bssid, .security = .open, .authenticated = false } });
    controller.poll(1005);
    try std.testing.expectEqual(wifi.State.disabled, controller.status().state);
    radio.hold_events = false;
    try controller.setEnabled(true, 1006);
    try controller.startScan(1006);
    pump(&controller, 1007);
    try controller.join((try controller.scan()).generation, 0, &credentials, 1008);
    pump(&controller, 1009);
    try radio.loseLink();
    controller.poll(1010);
    try std.testing.expectEqual(wifi.State.idle, controller.status().state);
    try std.testing.expect(controller.status().current == null);
    radio.fail_poll = true;
    controller.poll(1011);
    var status = controller.status();
    try status.validate();
    try std.testing.expectEqual(wifi.Failure.device_lost, status.failure);
}
test "BSSID dedup selects stronger signal while contradictory or malformed scans fail atomically" {
    var controller: private.Controller = .{};
    var radio: fixture.Radio = .{ .hold_events = true };
    try controller.init(radio.backend(), 0);
    try controller.setEnabled(true, 0);
    try controller.startScan(1);
    const operation = controller.operation;
    var stronger = fixture.wpa2_bss;
    stronger.signal_dbm = -30;
    try radio.push(.{ .scan_result = .{ .operation = operation, .bss = fixture.wpa2_bss } });
    try radio.push(.{ .scan_result = .{ .operation = operation, .bss = stronger } });
    try radio.push(.{ .scan_complete = .{ .operation = operation } });
    controller.poll(2);
    const scan = try controller.scan();
    try std.testing.expectEqual(@as(usize, 1), scan.count);
    try std.testing.expectEqual(@as(i16, -30), scan.entries[0].signal_dbm);
    try controller.startScan(3);
    const next = controller.operation;
    stronger.security = .open;
    try radio.push(.{ .scan_result = .{ .operation = next, .bss = fixture.wpa2_bss } });
    try radio.push(.{ .scan_result = .{ .operation = next, .bss = stronger } });
    try radio.push(.{ .scan_complete = .{ .operation = next } });
    pump(&controller, 4);
    try std.testing.expectEqual(wifi.State.failed, controller.status().state);
    try std.testing.expectError(error.RadioDisabled, controller.scan());
}
test "scan capacity event polling and exhausted identities stay bounded" {
    var controller: private.Controller = .{};
    var radio: fixture.Radio = .{ .hold_events = true };
    try controller.init(radio.backend(), 0);
    try controller.setEnabled(true, 0);
    try controller.startScan(1);
    const operation = controller.operation;
    for (0..17) |index| {
        var bss = fixture.open_bss;
        bss.bssid[5] = @intCast(index + 1);
        try radio.push(.{ .scan_result = .{ .operation = operation, .bss = bss } });
    }
    try radio.push(.{ .scan_complete = .{ .operation = operation } });
    controller.poll(2);
    try std.testing.expectEqual(wifi.State.scanning, controller.status().state);
    try std.testing.expectEqual(@as(usize, 2), radio.count);
    controller.poll(3);
    try std.testing.expectEqual(wifi.State.idle, controller.status().state);
    try std.testing.expectEqual(@as(usize, 0), controller.working_count);
    const snapshot = try controller.scan();
    try snapshot.validate();
    try std.testing.expectEqual(@as(usize, 16), snapshot.count);
    try std.testing.expectEqual(@as(u64, 1), controller.dropped_scan_results);
    try controller.setEnabled(true, 4);
    controller.next_operation = std.math.maxInt(u64);
    try controller.startScan(4);
    try std.testing.expectEqual(std.math.maxInt(u64), controller.operation);
    try controller.disconnect(5);
    try std.testing.expectError(error.OperationExhausted, controller.startScan(6));
    try std.testing.expectError(error.TimeOverflow, controller.startScan(std.math.maxInt(u64)));
}
test "joined proof cannot replace WPA2 with open security or a different BSSID" {
    for (0..3) |case| {
        var controller: private.Controller = .{};
        var radio: fixture.Radio = .{};
        try begin(&controller, &radio);
        const scan = try controller.scan();
        radio.hold_events = true;
        var credentials = try wifi.Credentials.init("test-passphrase");
        try controller.join(scan.generation, 1, &credentials, 3);
        var bssid = fixture.wpa2_bss.bssid;
        if (case == 0) bssid[5] = 42;
        try radio.push(.{ .joined = .{ .operation = controller.operation, .bssid = bssid, .security = if (case == 1) .open else .wpa2_personal, .authenticated = case != 2 } });
        pump(&controller, 4);
        try std.testing.expectEqual(wifi.State.failed, controller.status().state);
        try std.testing.expectEqual(wifi.Failure.authentication, controller.status().failure);
        try std.testing.expect(controller.status().current == null);
    }
}

test "authentication failure wipes secret and a later explicit attempt can establish the selected link" {
    var controller: private.Controller = .{};
    var radio: fixture.Radio = .{};
    try begin(&controller, &radio);
    const scan = try controller.scan();
    var credentials = try wifi.Credentials.init("bad-passphrase");
    try controller.join(scan.generation, 1, &credentials, 3);
    try cleared(&credentials);
    pump(&controller, 4);
    var status = controller.status();
    try status.validate();
    try std.testing.expectEqual(wifi.Failure.authentication, status.failure);
    try std.testing.expect(status.current == null);
    credentials = try wifi.Credentials.init("test-passphrase");
    try controller.join(scan.generation, 1, &credentials, 5);
    try cleared(&credentials);
    pump(&controller, 6);
    try std.testing.expectEqual(wifi.State.connected, controller.status().state);
}

test "malformed scan disables safely and prevents another backend poll in that pass" {
    var controller: private.Controller = .{};
    var radio: fixture.Radio = .{ .hold_events = true };
    try controller.init(radio.backend(), 0);
    try controller.setEnabled(true, 0);
    try controller.startScan(1);
    var malformed = fixture.open_bss;
    malformed.channel = 0;
    try radio.push(.{ .scan_result = .{ .operation = controller.operation, .bss = malformed } });
    try radio.push(.{ .scan_complete = .{ .operation = controller.operation } });
    controller.poll(2);
    try std.testing.expectEqual(@as(usize, 1), radio.poll_calls);
    try std.testing.expectEqual(@as(usize, 1), radio.count);
    try std.testing.expectEqual(wifi.Failure.device_lost, controller.status().failure);
    try std.testing.expectEqual(@as(u64, 0), controller.cache.generation);
    controller.poll(3);
    try std.testing.expectEqual(@as(usize, 1), radio.poll_calls);
    var credentials = try wifi.Credentials.init("test-passphrase");
    try std.testing.expectError(error.RadioDisabled, controller.join(1, 0, &credentials, 3));
    try cleared(&credentials);
}

test "hidden networks and invalid credentials never reach backend and secrets clear before every return" {
    var controller: private.Controller = .{};
    var radio: fixture.Radio = .{ .hold_events = true };
    var credentials = try wifi.Credentials.init("test-passphrase");
    try std.testing.expectError(error.NetworkUnavailable, controller.join(1, 0, &credentials, 0));
    try cleared(&credentials);
    try controller.init(radio.backend(), 0);
    try controller.setEnabled(true, 0);
    try controller.startScan(1);
    var hidden = fixture.wpa2_bss;
    hidden.ssid = .{};
    try radio.push(.{ .scan_result = .{ .operation = controller.operation, .bss = hidden } });
    try radio.push(.{ .scan_complete = .{ .operation = controller.operation } });
    controller.poll(2);
    credentials = try wifi.Credentials.init("test-passphrase");
    try std.testing.expectError(error.HiddenSsid, controller.join((try controller.scan()).generation, 0, &credentials, 3));
    try cleared(&credentials);
    credentials.len = 255;
    @memset(&credentials.bytes, 'x');
    try std.testing.expectError(error.InvalidCredentials, controller.join(1, 0, &credentials, 3));
    try cleared(&credentials);
    try std.testing.expectEqual(@as(usize, 0), radio.joins);
}

test "scan generation exhaustion preserves the last complete cache without wrapping or submitting" {
    var controller: private.Controller = .{};
    var radio: fixture.Radio = .{};
    try begin(&controller, &radio);
    controller.scan_generation = std.math.maxInt(u64) - 1;
    try controller.startScan(3);
    pump(&controller, 4);
    const snapshot = try controller.scan();
    try std.testing.expectEqual(std.math.maxInt(u64), snapshot.generation);
    const next_operation = controller.next_operation;
    try std.testing.expectError(error.GenerationExhausted, controller.startScan(5));
    try std.testing.expectEqual(next_operation, controller.next_operation);
    try std.testing.expectEqual(snapshot.generation, (try controller.scan()).generation);
    try std.testing.expectEqual(@as(usize, 0), radio.count);
}
