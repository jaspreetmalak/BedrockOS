//! Read-only firmware calendar baseline advanced by observed hardware quanta.
//! No runtime firmware calls, writable clock API, privilege grants or allocations.
const std = @import("std");
const protocol = @import("boot_protocol");
const abi = @import("bedrock64");

pub const Clock = struct {
    baseline: protocol.WallClock = .{},
    baseline_ticks: u64 = 0,

    pub fn init(baseline: protocol.WallClock, ticks: u64) !Clock {
        try baseline.validate();
        return .{ .baseline = baseline, .baseline_ticks = ticks };
    }

    pub fn read(self: Clock, ticks: u64) abi.ClockTime {
        if (self.baseline.flags & protocol.wall_clock.available == 0) return .{ .observed_ticks = ticks };
        // The process timer already detects overflow; do not turn regressed
        // input into an enormous elapsed interval if that contract changes.
        const elapsed = ticks -| self.baseline_ticks;
        const fractional_ns: u64 = @as(u64, self.baseline.nanoseconds) + elapsed % 100 * 10_000_000;
        const elapsed_seconds = elapsed / 100 + fractional_ns / 1_000_000_000;
        const room: u64 = @intCast(protocol.wall_clock.max_seconds - self.baseline.seconds);
        const clamps = elapsed_seconds > room;
        return .{
            .seconds = if (clamps) protocol.wall_clock.max_seconds else self.baseline.seconds + @as(i64, @intCast(elapsed_seconds)),
            .nanoseconds = if (clamps) 999_999_999 else @intCast(fractional_ns % 1_000_000_000),
            .flags = self.baseline.flags | abi.clock_flags.observed_quanta | (if (clamps) abi.clock_flags.clamped else @as(u32, 0)),
            .utc_offset_minutes = self.baseline.utc_offset_minutes,
            .observed_ticks = ticks,
        };
    }
};

comptime {
    if (protocol.wall_clock.available != abi.clock_flags.available or protocol.wall_clock.utc != abi.clock_flags.utc)
        @compileError("firmware and public clock flags disagree");
}

test "firmware clock progresses on quantum boundaries with nanosecond carry" {
    const t = std.testing;
    const clock = try Clock.init(.{ .seconds = 86_399, .nanoseconds = 990_000_000, .flags = 3, .utc_offset_minutes = -480 }, 10);
    const first = clock.read(10);
    try t.expect(first.isAvailable());
    try t.expectEqual(@as(i64, 86_399), first.seconds);
    const next = clock.read(11);
    try t.expectEqual(@as(i64, 86_400), next.seconds);
    try t.expectEqual(@as(u32, 0), next.nanoseconds);
    try t.expectEqual(@as(i32, -480), next.utc_offset_minutes);
    try t.expectEqual(@as(u64, 11), next.observed_ticks);
    try t.expectEqual(@as(u32, 7), next.flags);
    const second = clock.read(111);
    try t.expectEqual(@as(i64, 86_401), second.seconds);
    try t.expectEqual(@as(u32, 0), second.nanoseconds);
    try t.expectEqual(@as(i64, 86_399), clock.read(9).seconds);
}

test "absent and unspecified firmware clocks do not fabricate UTC or zero dates" {
    const t = std.testing;
    const absent = (try Clock.init(.{}, 0)).read(std.math.maxInt(u64));
    try t.expect(!absent.isAvailable());
    try t.expectEqual(@as(u32, 0), absent.flags);
    try t.expectEqual(@as(i64, 0), absent.seconds);
    try t.expectEqual(std.math.maxInt(u64), absent.observed_ticks);
    const local = (try Clock.init(.{ .seconds = 123, .flags = 1, .utc_offset_minutes = 2047 }, 0)).read(100);
    try t.expectEqual(@as(i64, 124), local.seconds);
    try t.expectEqual(@as(u32, 5), local.flags);
    try t.expectEqual(@as(i32, 2047), local.utc_offset_minutes);
}

test "clock clamps the supported calendar and cannot wrap at maximal timer counts" {
    const t = std.testing;
    const clock = try Clock.init(.{ .seconds = protocol.wall_clock.max_seconds, .nanoseconds = 990_000_000, .flags = 3 }, 0);
    const last = clock.read(1);
    try t.expectEqual(protocol.wall_clock.max_seconds, last.seconds);
    try t.expectEqual(@as(u32, 999_999_999), last.nanoseconds);
    try t.expectEqual(@as(u32, 15), last.flags);
    const huge = (try Clock.init(.{ .seconds = protocol.wall_clock.min_seconds, .flags = 3 }, 0)).read(std.math.maxInt(u64));
    try t.expectEqual(protocol.wall_clock.max_seconds, huge.seconds);
    try t.expectEqual(@as(u32, 999_999_999), huge.nanoseconds);
    try t.expectEqual(@as(u32, 15), huge.flags);
    try t.expectError(error.InvalidWallClock, Clock.init(.{ .flags = 3, .nanoseconds = 1_000_000_000 }, 0));
}
