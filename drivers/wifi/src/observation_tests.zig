const std = @import("std");
const observation = @import("observation.zig");
fn beacon() [64]u8 {
    var out: [64]u8 = @splat(0);
    out[0] = 0x80;
    @memset(out[4..10], 0xff);
    @memcpy(out[10..16], &@as([6]u8, .{ 2, 1, 2, 3, 4, 5 }));
    @memcpy(out[16..22], out[10..16]);
    out[32] = 100;
    out[34] = 1;
    @memcpy(out[36..], &@as([28]u8, .{ 0, 4, 'T', 'e', 's', 't', 1, 4, 0x82, 0x84, 0x8b, 0x96, 3, 1, 6, 5, 4, 0, 2, 0, 0, 50, 5, 12, 18, 24, 36, 48 }));
    return out;
}
test "beacon observation derives rates TIM interval and exact selected channel" {
    var bytes = beacon();
    const found = try observation.parse(&bytes, 6, -40, 0x0fff);
    try std.testing.expectEqual(@as(u16, 100), found.beacon_interval);
    try std.testing.expectEqual(@as(u8, 2), found.dtim_period);
    try std.testing.expectEqual(@as(u16, 15), found.basic_rates);
    try std.testing.expectEqual(@as(u8, 8), found.rates.length);
    try std.testing.expectEqual(@as(u16, 255), found.supported_rates);
    try std.testing.expectEqual(@as(u8, 0), found.rsn_length);
    var copy: [65]u8 = undefined;
    @memcpy(copy[1..], &bytes);
    try std.testing.expectEqualDeep(found, try observation.parse(copy[1..], 6, -40, 0x0fff));
}
test "observation cannot invent mandatory PHY support DTIM or rate identity" {
    var bytes = beacon();
    try std.testing.expectError(error.IncompleteObservation, observation.parse(&bytes, 6, -40, 1));
    bytes[54] = 0;
    try std.testing.expectError(error.InvalidTim, observation.parse(&bytes, 6, -40, 0x0fff));
    bytes = beacon();
    bytes[59] = 2;
    try std.testing.expectError(error.DuplicateRate, observation.parse(&bytes, 6, -40, 0x0fff));
    bytes = beacon();
    bytes[59] = 0xff;
    try std.testing.expectError(error.UnsupportedBasicRate, observation.parse(&bytes, 6, -40, 0x0fff));
    try std.testing.expectError(error.ChannelContradiction, observation.parse(&bytes, 11, -40, 0x0fff));
}
