//! Capture firmware time before the final memory-map/ExitBootServices boundary.
const std = @import("std");
const protocol = @import("boot_protocol");
const uefi = std.os.uefi;

pub fn capture(system_table: *const uefi.tables.SystemTable) protocol.WallClock {
    const runtime = system_table.runtime_services;
    // GetTime is the first entry, but still reject a truncated firmware table.
    if (runtime.hdr.header_size < @offsetOf(uefi.tables.RuntimeServices, "_getTime") + @sizeOf(usize)) return .{};
    var time: uefi.Time = undefined;
    // Capabilities are optional and are not part of this calendar handoff.
    if (runtime._getTime(&time, null) != .success) return .{};
    return protocol.wall_clock.fromCalendar(.{
        .year = time.year,
        .month = time.month,
        .day = time.day,
        .hour = time.hour,
        .minute = time.minute,
        .second = time.second,
        .nanosecond = time.nanosecond,
        .uefi_timezone = time.timezone,
        .daylight = @bitCast(time.daylight),
    }) catch .{};
}

test "firmware snapshot rejects truncated unsupported failed and invalid time services" {
    const t = std.testing;
    const Fake = struct {
        var status: uefi.Status = .success;
        var calls: usize = 0;
        var month: u8 = 10;
        fn getTime(time: *uefi.Time, capabilities: ?*uefi.TimeCapabilities) callconv(uefi.cc) uefi.Status {
            calls += 1;
            std.debug.assert(capabilities == null);
            if (status != .success) return status;
            time.* = .{
                .year = 2026,
                .month = month,
                .day = 12,
                .hour = 13,
                .minute = 25,
                .second = 30,
                ._pad1 = 0,
                .nanosecond = 123,
                .timezone = 420,
                .daylight = @bitCast(@as(u8, 3)),
                ._pad2 = 0,
            };
            return .success;
        }
    };
    var runtime: uefi.tables.RuntimeServices = undefined;
    runtime.hdr = .{ .signature = 0, .revision = 0, .header_size = @sizeOf(uefi.tables.RuntimeServices), .crc32 = 0, .reserved = 0 };
    runtime._getTime = Fake.getTime;
    var system: uefi.tables.SystemTable = undefined;
    system.runtime_services = &runtime;
    Fake.calls = 0;
    Fake.status = .success;
    Fake.month = 10;
    const valid = capture(&system);
    try valid.validate();
    try t.expectEqual(@as(u32, 3), valid.flags);
    try t.expectEqual(@as(i32, -420), valid.utc_offset_minutes);
    try t.expectEqual(@as(u32, 123), valid.nanoseconds);
    for ([_]uefi.Status{ .unsupported, .device_error, .invalid_parameter }) |status| {
        Fake.status = status;
        try t.expectEqualDeep(protocol.WallClock{}, capture(&system));
    }
    Fake.status = .success;
    Fake.month = 13;
    try t.expectEqualDeep(protocol.WallClock{}, capture(&system));
    try t.expectEqual(@as(usize, 5), Fake.calls);
    runtime.hdr.header_size = @offsetOf(uefi.tables.RuntimeServices, "_getTime");
    try t.expectEqualDeep(protocol.WallClock{}, capture(&system));
    try t.expectEqual(@as(usize, 5), Fake.calls);
}
