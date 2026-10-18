//! Convert the private C ABI into module-local framework values.
const std = @import("std");
const abi = @import("driver_abi");
const wifi = @import("networkkit").wifi;

pub fn decode(value: *const abi.Bss) !wifi.Bss {
    if (!std.mem.allEqual(u8, &value.reserved, 0) or value.security > @backingInt(wifi.Security.unsupported)) return error.InvalidBss;
    const result: wifi.Bss = .{
        .ssid = .{ .bytes = value.ssid, .len = value.ssid_len },
        .bssid = value.bssid,
        .channel = value.channel,
        .signal_dbm = value.signal_dbm,
        .security = @fromBackingInt(value.security),
    };
    try result.validate();
    return result;
}
pub fn encode(value: wifi.Bss) abi.Bss {
    return .{ .ssid = value.ssid.bytes, .ssid_len = value.ssid.len, .bssid = value.bssid, .channel = value.channel, .signal_dbm = value.signal_dbm, .security = @backingInt(value.security) };
}

test "BSS conversion validates bounded binary SSIDs and enum values" {
    const value: wifi.Bss = .{ .ssid = try wifi.Ssid.init(&.{ 'a', 0, 'b' }), .bssid = .{ 2, 0, 0, 0, 0, 1 }, .channel = 6, .signal_dbm = -40, .security = .wpa2_personal };
    var raw = encode(value);
    try std.testing.expectEqualDeep(value, try decode(&raw));
    raw.security = 255;
    try std.testing.expectError(error.InvalidBss, decode(&raw));
    raw = encode(value);
    raw.ssid_len = 33;
    try std.testing.expectError(error.InvalidSsid, decode(&raw));
    raw = encode(value);
    raw.reserved[0] = 1;
    try std.testing.expectError(error.InvalidBss, decode(&raw));
}
