//! Architectural invariant-TSC clock. CPUID.15 supplies the exact rational
//! frequency; CPUID.16 CPU MHz is deliberately not treated as TSC frequency.
const std = @import("std");
pub const Ratio = struct {
    denominator: u32,
    numerator: u32,
    crystal_hz: u32,
    pub fn init(invariant: bool, denominator: u32, numerator: u32, crystal_hz: u32) !Ratio {
        if (!invariant or denominator == 0 or numerator == 0 or crystal_hz == 0) return error.UnsupportedClock;
        return .{ .denominator = denominator, .numerator = numerator, .crystal_hz = crystal_hz };
    }
    pub fn ticksForMicros(self: Ratio, micros: u32) !u64 {
        const numerator = @as(u128, micros) * self.crystal_hz * self.numerator;
        const denominator = @as(u128, self.denominator) * 1_000_000;
        const ticks = (numerator + denominator - 1) / denominator;
        if (ticks > std.math.maxInt(u64)) return error.ClockOverflow;
        return @intCast(ticks);
    }
    pub fn microsForTicks(self: Ratio, ticks: u64) !u64 {
        const micros = @as(u128, ticks) * self.denominator * 1_000_000 / (@as(u128, self.crystal_hz) * self.numerator);
        if (micros > std.math.maxInt(u64)) return error.ClockOverflow;
        return @intCast(micros);
    }
};
test "TSC ratio preserves fractional frequency and never shortens a delay" {
    const ratio = try Ratio.init(true, 3, 2, 10_000_001);
    try std.testing.expectEqual(@as(u64, 7), try ratio.ticksForMicros(1));
    try std.testing.expectEqual(@as(u64, 1_000_000), try ratio.microsForTicks(6_666_668));
    try std.testing.expectEqual(@as(u64, 0), try ratio.ticksForMicros(0));
    try std.testing.expectError(error.UnsupportedClock, Ratio.init(false, 1, 1, 24_000_000));
    try std.testing.expectError(error.UnsupportedClock, Ratio.init(true, 0, 1, 24_000_000));
    try std.testing.expectError(error.UnsupportedClock, Ratio.init(true, 1, 1, 0));
}
