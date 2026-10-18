//! Clock snapshot copyout through the requesting task's writable mappings.
const std = @import("std");
const abi = @import("bedrock64");
const user = @import("user_memory.zig");
const Clock = @import("wall_clock.zig").Clock;

pub fn read(clock: Clock, regions: []const user.Region, address: u64, reserved1: u64, reserved2: u64, ticks: u64) !u64 {
    if (reserved1 != 0 or reserved2 != 0) return error.InvalidRequest;
    const physical = try user.translateWrite(regions, address, @sizeOf(abi.ClockTime));
    const snapshot = clock.read(ticks);
    // Byte copy permits a caller's unaligned writable storage without creating
    // an aligned kernel pointer to the raw user address.
    const output: [*]volatile u8 = @ptrFromInt(physical);
    for (std.mem.asBytes(&snapshot), 0..) |byte, index| output[index] = byte;
    return 0;
}

test "clock snapshots require current writable storage and reject wrapping ranges" {
    const t = std.testing;
    const clock = try Clock.init(.{ .seconds = 123, .flags = 3 }, 0);
    var bytes: [96]u8 = @splat(0xaa);
    const maps = [_]user.Region{
        .{ .virtual = 0x1000, .physical = @intFromPtr(&bytes), .length = 48, .writable = true },
        .{ .virtual = 0x2000, .physical = @intFromPtr(&bytes) + 48, .length = 48 },
    };
    try t.expectError(error.InvalidRequest, read(clock, &maps, 0x1001, 1, 0, 100));
    try t.expectError(error.InvalidRequest, read(clock, &maps, 0x1001, 0, 1, 100));
    try t.expectError(error.InvalidUserRange, read(clock, &maps, 0x2000, 0, 0, 100));
    try t.expectError(error.InvalidUserRange, read(clock, &maps, 0x1011, 0, 0, 100));
    try t.expectError(error.InvalidUserRange, read(clock, &maps, @intFromPtr(&bytes), 0, 0, 100));
    try t.expectError(error.InvalidUserRange, read(clock, &maps, std.math.maxInt(u64) - 1, 0, 0, 100));
    try t.expect(std.mem.allEqual(u8, &bytes, 0xaa));
    try t.expectEqual(@as(u64, 0), try read(clock, &maps, 0x1001, 0, 0, 100));
    var result: abi.ClockTime = undefined;
    @memcpy(std.mem.asBytes(&result), bytes[1..33]);
    try t.expectEqual(@as(i64, 124), result.seconds);
    try t.expectEqual(@as(u64, 100), result.observed_ticks);
    try t.expectEqual(@as(u32, 7), result.flags);
    try t.expectEqual(@as(u32, 0), result.reserved);
    try t.expectEqual(@as(u8, 0xaa), bytes[0]);
    try t.expect(std.mem.allEqual(u8, bytes[33..], 0xaa));
}

test "unavailable clock returns a successful explicit unavailable snapshot" {
    const t = std.testing;
    var snapshot: abi.ClockTime = undefined;
    const maps = [_]user.Region{.{ .virtual = 0x1000, .physical = @intFromPtr(&snapshot), .length = @sizeOf(abi.ClockTime), .writable = true }};
    try t.expectEqual(@as(u64, 0), try read(try Clock.init(.{}, 0), &maps, 0x1000, 0, 0, 321));
    try t.expect(!snapshot.isAvailable());
    try t.expectEqual(@as(u64, 321), snapshot.observed_ticks);
    try t.expectEqual(@as(u32, 0), snapshot.reserved);
}
