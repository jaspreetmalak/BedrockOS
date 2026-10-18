//! Bounded beacon metadata needed for real MAC/interface setup. All values come
//! from a checked received frame and caller-qualified legacy PHY rates.
const std = @import("std");
const ieee = @import("ieee80211/root.zig");
const wifi = @import("networkkit").wifi;
pub const Observation = struct {
    bss: wifi.Bss,
    rates: ieee.station.Rates,
    supported_rates: u16,
    basic_rates: u16,
    beacon_interval: u16,
    dtim_period: u8,
    rsn: [255]u8 = @splat(0),
    rsn_length: u8 = 0,
    pub fn rsnBody(self: *const Observation) []const u8 {
        return self.rsn[0..self.rsn_length];
    }
};
pub const legacy_rates = [_]u8{ 2, 4, 11, 22, 12, 18, 24, 36, 48, 72, 96, 108 };
/// MT76 legacy MODE[9:6]/IDX[5:0], in the same band-relative bitmap as the
/// checked AP observation. HT/VHT/HE, extra streams and flags are unsupported.
pub fn hardwareRateMask(encoded: u16, channel: u16) !u16 {
    if (encoded & ~@as(u16, 0x3ff) != 0) return error.UnsupportedFixedRate;
    const mode = encoded >> 6;
    const index = encoded & 0x3f;
    if (mode == 0) {
        if (channel > 14 or index > 3) return error.UnsupportedFixedRate;
        return @as(u16, 1) << @intCast(index);
    }
    if (mode != 1) return error.UnsupportedFixedRate;
    const ofdm = [_]u6{ 11, 15, 10, 14, 9, 13, 8, 12 };
    for (ofdm, 0..) |value, i| if (value == index)
        return @as(u16, 1) << @intCast(i + if (channel <= 14) @as(usize, 4) else 0);
    return error.UnsupportedFixedRate;
}
pub fn parse(bytes: []const u8, channel: u16, signal: i16, device_rates: u16) !Observation {
    const selected = try ieee.management.parse(bytes, channel, signal);
    if (selected.channel > 177 or (selected.channel > 14 and selected.channel < 32)) return error.UnsupportedChannel;
    const band_mask: u16 = if (selected.channel <= 14) 0x0fff else 0x00ff;
    if (device_rates == 0 or device_rates & ~band_mask != 0) return error.InvalidDeviceRates;
    var result: Observation = .{ .bss = selected, .rates = .{ .length = 0 }, .supported_rates = 0, .basic_rates = 0, .beacon_interval = std.mem.readInt(u16, bytes[32..34], .little), .dtim_period = 0 };
    var available: u16 = 0;
    var basic: u16 = 0;
    var have_rates = false;
    var have_extended = false;
    var have_tim = false;
    var offset: usize = 36;
    while (offset < bytes.len) {
        // management.parse already validated the complete IE boundaries.
        const id = bytes[offset];
        const len = bytes[offset + 1];
        const body = bytes[offset + 2 ..][0..len];
        offset += 2 + @as(usize, len);
        switch (id) {
            1, 50 => {
                if (id == 1) {
                    if (have_rates or len == 0 or len > 8) return error.InvalidRates;
                    have_rates = true;
                } else {
                    if (have_extended or len == 0) return error.InvalidRates;
                    have_extended = true;
                }
                for (body) |rate| {
                    const value = rate & 0x7f;
                    if (value == 0) return error.InvalidRates;
                    var bit: ?u16 = null;
                    const start: usize = if (selected.channel <= 14) 0 else 4;
                    for (legacy_rates[start..], 0..) |candidate, i| if (candidate == value) {
                        bit = @as(u16, 1) << @intCast(i);
                        break;
                    };
                    if (bit) |mask| {
                        if (available & mask != 0) return error.DuplicateRate;
                        available |= mask;
                        if (rate & 0x80 != 0) basic |= mask;
                    } else if (rate & 0x80 != 0) return error.UnsupportedBasicRate;
                }
            },
            5 => {
                if (have_tim or len < 4 or body[1] == 0 or body[0] >= body[1]) return error.InvalidTim;
                have_tim = true;
                result.dtim_period = body[1];
            },
            48 => {
                result.rsn_length = len;
                @memcpy(result.rsn[0..len], body);
            },
            else => {},
        }
    }
    if (!have_rates or !have_tim or basic == 0 or basic & ~device_rates != 0) return error.IncompleteObservation;
    // Supported Rates IE has at most8entries. Preserve all mandatory rates,
    // then fill remaining capacity with mutually supported legacy rates.
    const start: usize = if (selected.channel <= 14) 0 else 4;
    for ([_]bool{ true, false }) |mandatory| for (legacy_rates[start..], 0..) |rate, i| {
        const bit = @as(u16, 1) << @intCast(i);
        if (available & device_rates & bit == 0 or (basic & bit != 0) != mandatory) continue;
        if (result.rates.length == 8) {
            if (mandatory) return error.TooManyBasicRates;
            continue;
        }
        result.rates.bytes[result.rates.length] = rate | if (mandatory) @as(u8, 0x80) else 0;
        result.rates.length += 1;
        result.supported_rates |= bit;
    };
    result.basic_rates = basic;
    try result.rates.validate();
    return result;
}
test {
    _ = @import("observation_tests.zig");
}
test "fixed hardware rate must map to the AP's actual legacy support" {
    try std.testing.expectEqual(@as(u16, 1 << 4), try hardwareRateMask(0x4b, 1));
    try std.testing.expectEqual(@as(u16, 1), try hardwareRateMask(0x4b, 36));
    try std.testing.expectEqual(@as(u16, 1), try hardwareRateMask(0, 1));
    try std.testing.expectError(error.UnsupportedFixedRate, hardwareRateMask(0, 36));
    try std.testing.expectError(error.UnsupportedFixedRate, hardwareRateMask(0x140b, 1));
    try std.testing.expectError(error.UnsupportedFixedRate, hardwareRateMask(0x40, 1));
}
