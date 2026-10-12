//! Pure decoding of sanitized Bedrock64 Wi-Fi records. No syscall or runtime
//! import: malformed tags and unused bytes are rejected before publication.
const std = @import("std");
const abi = @import("bedrock64");
const wifi = @import("networkkit").wifi;

fn zero(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != 0) return false;
    return true;
}

fn decodeBss(raw: abi.WifiBss) !wifi.Bss {
    if (raw.security > @backingInt(wifi.Security.unsupported)) return error.InvalidProviderResult;
    const result: wifi.Bss = .{
        .ssid = .{ .bytes = raw.ssid, .len = raw.ssid_len },
        .bssid = raw.bssid,
        .channel = raw.channel,
        .signal_dbm = raw.signal_dbm,
        .security = @fromBackingInt(@intCast(raw.security)),
    };
    result.validate() catch return error.InvalidProviderResult;
    return result;
}

pub fn decodeStatus(raw: abi.WifiStatus) !wifi.Status {
    if (raw.state > @backingInt(wifi.State.failed) or raw.failure > @backingInt(wifi.Failure.device_lost) or raw.simulated > 1 or raw.has_current > 1)
        return error.InvalidProviderResult;
    if (!zero(&raw.reserved) or raw.has_current == 0 and !zero(std.mem.asBytes(&raw.current))) return error.InvalidProviderResult;
    const result: wifi.Status = .{
        .state = @fromBackingInt(@intCast(raw.state)),
        .failure = @fromBackingInt(@intCast(raw.failure)),
        .simulated = raw.simulated == 1,
        .revision = raw.revision,
        .current = if (raw.has_current == 1) try decodeBss(raw.current) else null,
    };
    result.validate() catch return error.InvalidProviderResult;
    return result;
}

pub fn decodeScan(raw: abi.WifiScan) !wifi.Scan {
    if (raw.count > wifi.max_scan_results or raw.reserved != 0 or raw.generation == 0) return error.InvalidProviderResult;
    if (!zero(std.mem.sliceAsBytes(raw.entries[raw.count..]))) return error.InvalidProviderResult;
    var result: wifi.Scan = .{
        .generation = raw.generation,
        .count = raw.count,
        .entries = std.mem.zeroes([wifi.max_scan_results]wifi.Bss),
    };
    for (raw.entries[0..raw.count], 0..) |entry, index| result.entries[index] = try decodeBss(entry);
    result.validate() catch return error.InvalidProviderResult;
    return result;
}

fn validBss() abi.WifiBss {
    var result: abi.WifiBss = .{
        .ssid_len = 3,
        .bssid = .{ 2, 0, 0, 0, 0, 1 },
        .channel = 36,
        .signal_dbm = -40,
        .security = @backingInt(wifi.Security.wpa2_personal),
    };
    result.ssid[0..3].* = .{ 'N', 0, 255 };
    return result;
}

test "Wi-Fi wire valid absent status and binary current SSID decode coherently" {
    const absent = try decodeStatus(.{ .revision = 7 });
    try std.testing.expect(absent.state == .unavailable and absent.current == null and !absent.simulated);
    const current = try decodeStatus(.{ .revision = 8, .state = @backingInt(wifi.State.connected), .simulated = 1, .has_current = 1, .current = validBss() });
    try std.testing.expect(current.simulated and current.current != null);
    try std.testing.expectEqualSlices(u8, &.{ 'N', 0, 255 }, try current.current.?.ssid.slice());
}

test "Wi-Fi wire rejects all out-of-range enum and boolean status tags" {
    var raw: abi.WifiStatus = .{ .revision = 1 };
    raw.state = 255;
    try std.testing.expectError(error.InvalidProviderResult, decodeStatus(raw));
    raw.state = 0;
    raw.failure = 255;
    try std.testing.expectError(error.InvalidProviderResult, decodeStatus(raw));
    raw.failure = 0;
    raw.simulated = 2;
    try std.testing.expectError(error.InvalidProviderResult, decodeStatus(raw));
    raw.simulated = 0;
    raw.has_current = 2;
    try std.testing.expectError(error.InvalidProviderResult, decodeStatus(raw));
    raw.has_current = 1;
    raw.state = @backingInt(wifi.State.connected);
    raw.current = validBss();
    raw.current.security = 255;
    try std.testing.expectError(error.InvalidProviderResult, decodeStatus(raw));
}

test "Wi-Fi wire rejects every reserved status byte and every dirty absent current byte" {
    for (0..8) |index| {
        var raw: abi.WifiStatus = .{ .revision = 1 };
        raw.reserved[index] = 1;
        try std.testing.expectError(error.InvalidProviderResult, decodeStatus(raw));
    }
    for (0..@sizeOf(abi.WifiBss)) |index| {
        var raw: abi.WifiStatus = .{ .revision = 1 };
        std.mem.asBytes(&raw.current)[index] = 1;
        try std.testing.expectError(error.InvalidProviderResult, decodeStatus(raw));
    }
}

test "Wi-Fi wire rejects zero revision and incoherent current or failure state" {
    try std.testing.expectError(error.InvalidProviderResult, decodeStatus(.{}));
    try std.testing.expectError(error.InvalidProviderResult, decodeStatus(.{ .revision = 1, .state = @backingInt(wifi.State.connected) }));
    try std.testing.expectError(error.InvalidProviderResult, decodeStatus(.{ .revision = 1, .has_current = 1, .current = validBss() }));
    try std.testing.expectError(error.InvalidProviderResult, decodeStatus(.{ .revision = 1, .state = @backingInt(wifi.State.failed) }));
    try std.testing.expectError(error.InvalidProviderResult, decodeStatus(.{ .revision = 1, .failure = @backingInt(wifi.Failure.timeout) }));
    const failed = try decodeStatus(.{ .revision = 1, .state = @backingInt(wifi.State.failed), .failure = @backingInt(wifi.Failure.authentication) });
    try std.testing.expect(failed.failure == .authentication and failed.current == null);
}

test "Wi-Fi wire scan decodes empty maximum and hidden results without implicit extra entries" {
    try std.testing.expectEqual(@as(usize, 0), (try decodeScan(.{ .generation = 1 })).count);
    var raw: abi.WifiScan = .{ .generation = 3, .count = 16 };
    for (&raw.entries, 0..) |*entry, index| {
        entry.* = validBss();
        entry.bssid[5] = @intCast(index + 1);
    }
    raw.entries[1].ssid = @splat(0);
    raw.entries[1].ssid_len = 0;
    const scan = try decodeScan(raw);
    try std.testing.expectEqual(@as(usize, 16), scan.count);
    try std.testing.expectEqualSlices(u8, &.{ 'N', 0, 255 }, try scan.entries[0].ssid.slice());
    try std.testing.expectEqual(@as(u8, 0), scan.entries[1].ssid.len);
}

test "Wi-Fi wire rejects scan count generation reserved and dirty unused records" {
    try std.testing.expectError(error.InvalidProviderResult, decodeScan(.{}));
    try std.testing.expectError(error.InvalidProviderResult, decodeScan(.{ .generation = 1, .count = 17 }));
    try std.testing.expectError(error.InvalidProviderResult, decodeScan(.{ .generation = 1, .reserved = 1 }));
    for (0..@sizeOf(abi.WifiBss)) |index| {
        var raw: abi.WifiScan = .{ .generation = 1, .count = 1 };
        raw.entries[0] = validBss();
        std.mem.asBytes(&raw.entries[15])[index] = 1;
        try std.testing.expectError(error.InvalidProviderResult, decodeScan(raw));
    }
}

test "Wi-Fi wire rejects malformed SSID lengths tails MAC and duplicate BSSID before publication" {
    var raw: abi.WifiScan = .{ .generation = 1, .count = 1 };
    raw.entries[0] = validBss();
    raw.entries[0].ssid_len = 33;
    try std.testing.expectError(error.InvalidProviderResult, decodeScan(raw));
    raw.entries[0] = validBss();
    raw.entries[0].ssid[31] = 1;
    try std.testing.expectError(error.InvalidProviderResult, decodeScan(raw));
    raw.entries[0] = validBss();
    raw.entries[0].bssid[0] = 1;
    try std.testing.expectError(error.InvalidProviderResult, decodeScan(raw));
    raw.entries[0] = validBss();
    raw.entries[0].channel = 234;
    try std.testing.expectError(error.InvalidProviderResult, decodeScan(raw));
    raw.entries[0] = validBss();
    raw.entries[0].signal_dbm = -128;
    try std.testing.expectError(error.InvalidProviderResult, decodeScan(raw));
    raw.entries[0] = validBss();
    raw.count = 2;
    raw.entries[1] = raw.entries[0];
    try std.testing.expectError(error.InvalidProviderResult, decodeScan(raw));
}
