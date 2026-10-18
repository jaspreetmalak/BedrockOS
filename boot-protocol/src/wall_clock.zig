//! Optional firmware wall-clock snapshot. No firmware pointers or callable code.
const std = @import("std");

pub const available: u32 = 1;
pub const utc: u32 = 2;
pub const unspecified_offset: i32 = 2047;
pub const min_seconds: i64 = -2_208_988_800; // 1900-01-01 00:00:00
pub const max_seconds: i64 = 253_402_300_799; // 9999-12-31 23:59:59

pub const WallClock = extern struct {
    /// Unix epoch seconds when UTC is set; otherwise firmware local calendar seconds.
    seconds: i64 = 0,
    nanoseconds: u32 = 0,
    flags: u32 = 0,
    /// Conventional minutes east of UTC, or 2047 when firmware did not specify it.
    utc_offset_minutes: i32 = 0,
    reserved: u32 = 0,

    pub fn validate(self: WallClock) error{InvalidWallClock}!void {
        if (self.flags == 0) {
            if (self.seconds != 0 or self.nanoseconds != 0 or self.utc_offset_minutes != 0 or self.reserved != 0)
                return error.InvalidWallClock;
            return;
        }
        if (self.flags & ~@as(u32, available | utc) != 0 or self.flags & available == 0 or self.reserved != 0 or
            self.seconds < min_seconds or self.seconds > max_seconds or self.nanoseconds >= 1_000_000_000)
            return error.InvalidWallClock;
        if (self.flags & utc != 0) {
            if (self.utc_offset_minutes < -1440 or self.utc_offset_minutes > 1440) return error.InvalidWallClock;
        } else if (self.utc_offset_minutes != unspecified_offset) return error.InvalidWallClock;
    }
};

/// UEFI's timezone uses UTC = local + timezone, opposite the conventional offset.
pub const Calendar = struct {
    year: u16,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,
    nanosecond: u32,
    uefi_timezone: i16,
    daylight: u8,
};

pub fn fromCalendar(value: Calendar) error{InvalidWallClock}!WallClock {
    if (value.year < 1900 or value.year > 9999 or value.month < 1 or value.month > 12 or
        value.day == 0 or value.day > monthDays(value.year, value.month) or
        value.hour > 23 or value.minute > 59 or value.second > 59 or value.nanosecond >= 1_000_000_000 or
        value.daylight & ~@as(u8, 3) != 0 or
        (value.uefi_timezone != unspecified_offset and (value.uefi_timezone < -1440 or value.uefi_timezone > 1440)))
        return error.InvalidWallClock;
    // Bounded integer arithmetic, including dates before the epoch.
    var days: i64 = 0;
    if (value.year >= 1970) {
        var year: u16 = 1970;
        while (year < value.year) : (year += 1) days += if (leap(year)) 366 else 365;
    } else {
        var year: u16 = value.year;
        while (year < 1970) : (year += 1) days -= if (leap(year)) 366 else 365;
    }
    var month: u8 = 1;
    while (month < value.month) : (month += 1) days += monthDays(value.year, month);
    days += value.day - 1;
    var seconds = days * 86400 + @as(i64, value.hour) * 3600 + @as(i64, value.minute) * 60 + value.second;
    const has_offset = value.uefi_timezone != unspecified_offset;
    if (has_offset) seconds += @as(i64, value.uefi_timezone) * 60;
    const result: WallClock = .{
        .seconds = seconds,
        .nanoseconds = value.nanosecond,
        .flags = available | (if (has_offset) utc else @as(u32, 0)),
        .utc_offset_minutes = if (has_offset) -@as(i32, value.uefi_timezone) else unspecified_offset,
    };
    try result.validate();
    return result;
}

fn leap(year: u16) bool {
    return year % 4 == 0 and (year % 100 != 0 or year % 400 == 0);
}
fn monthDays(year: u16, month: u8) u8 {
    return switch (month) {
        2 => if (leap(year)) 29 else 28,
        4, 6, 9, 11 => 30,
        else => 31,
    };
}

comptime {
    if (@sizeOf(WallClock) != 24 or @alignOf(WallClock) != 8 or
        @offsetOf(WallClock, "nanoseconds") != 8 or @offsetOf(WallClock, "flags") != 12 or
        @offsetOf(WallClock, "utc_offset_minutes") != 16 or @offsetOf(WallClock, "reserved") != 20)
        @compileError("wall clock handoff layout changed");
}

fn calendar(year: u16, month: u8, day: u8) Calendar {
    return .{ .year = year, .month = month, .day = day, .hour = 0, .minute = 0, .second = 0, .nanosecond = 0, .uefi_timezone = 0, .daylight = 0 };
}

test "firmware dates convert leap centuries and epoch boundaries without guessed UTC" {
    const t = std.testing;
    try t.expectEqual(@as(i64, 0), (try fromCalendar(calendar(1970, 1, 1))).seconds);
    try t.expectEqual(min_seconds, (try fromCalendar(calendar(1900, 1, 1))).seconds);
    try t.expectEqual(@as(i64, 951_782_400), (try fromCalendar(calendar(2000, 2, 29))).seconds);
    try t.expectEqual(@as(i64, 4_107_542_400), (try fromCalendar(calendar(2100, 3, 1))).seconds);
    var date = calendar(9999, 12, 31);
    date.hour = 23;
    date.minute = 59;
    date.second = 59;
    try t.expectEqual(max_seconds, (try fromCalendar(date)).seconds);
    date = calendar(1970, 1, 1);
    date.uefi_timezone = 480;
    date.daylight = 3; // Offset is already adjusted; no extra DST hour is added.
    const west = try fromCalendar(date);
    try t.expectEqual(@as(i64, 8 * 3600), west.seconds);
    try t.expectEqual(@as(i32, -480), west.utc_offset_minutes);
    date.uefi_timezone = -120;
    try t.expectEqual(@as(i64, -2 * 3600), (try fromCalendar(date)).seconds);
    date.uefi_timezone = unspecified_offset;
    const local = try fromCalendar(date);
    try t.expectEqual(available, local.flags);
    try t.expectEqual(unspecified_offset, local.utc_offset_minutes);
    try t.expectEqual(@as(i64, 0), local.seconds);
}

test "invalid firmware calendars offsets and reserved bits stay unavailable" {
    const t = std.testing;
    for ([_]Calendar{
        calendar(1899, 1, 1), calendar(10000, 1, 1), calendar(2026, 0, 1),  calendar(2026, 13, 1),
        calendar(2026, 1, 0), calendar(2026, 4, 31), calendar(1900, 2, 29), calendar(2100, 2, 29),
    }) |date| try t.expectError(error.InvalidWallClock, fromCalendar(date));
    const valid = calendar(2026, 1, 1);
    var date = valid;
    date.hour = 24;
    try t.expectError(error.InvalidWallClock, fromCalendar(date));
    date = valid;
    date.minute = 60;
    try t.expectError(error.InvalidWallClock, fromCalendar(date));
    date = valid;
    date.second = 60;
    try t.expectError(error.InvalidWallClock, fromCalendar(date));
    date = valid;
    date.nanosecond = 1_000_000_000;
    try t.expectError(error.InvalidWallClock, fromCalendar(date));
    date = valid;
    date.uefi_timezone = 1441;
    try t.expectError(error.InvalidWallClock, fromCalendar(date));
    date.uefi_timezone = -1441;
    try t.expectError(error.InvalidWallClock, fromCalendar(date));
    date = valid;
    date.daylight = 4;
    try t.expectError(error.InvalidWallClock, fromCalendar(date));
    date = calendar(1900, 1, 1);
    date.uefi_timezone = -1;
    try t.expectError(error.InvalidWallClock, fromCalendar(date));
    date = calendar(9999, 12, 31);
    date.hour = 23;
    date.minute = 59;
    date.second = 59;
    date.uefi_timezone = 1;
    try t.expectError(error.InvalidWallClock, fromCalendar(date));
}

test "absent or present wall-clock records reject malformed encodings" {
    const t = std.testing;
    try (WallClock{}).validate();
    for ([_]WallClock{
        .{ .seconds = 1 },                                         .{ .nanoseconds = 1 },                                     .{ .utc_offset_minutes = 1 },                                .{ .reserved = 1 },
        .{ .flags = utc },                                         .{ .flags = available },                                   .{ .flags = available | utc, .reserved = 1 },                .{ .flags = 4 },
        .{ .flags = available | utc, .seconds = min_seconds - 1 }, .{ .flags = available | utc, .seconds = max_seconds + 1 }, .{ .flags = available | utc, .nanoseconds = 1_000_000_000 }, .{ .flags = available | utc, .utc_offset_minutes = unspecified_offset },
        .{ .flags = available | utc, .utc_offset_minutes = 1441 },
    }) |record| try t.expectError(error.InvalidWallClock, record.validate());
    try (WallClock{ .flags = available, .utc_offset_minutes = unspecified_offset }).validate();
}
