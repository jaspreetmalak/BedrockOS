//! Translate a bounded input through the current task's trusted mapping list.
//! No arbitrary application pointer is dereferenced by the syscall dispatcher.
pub const Region = struct { virtual: u64, physical: u64, length: u64, readable: bool = true, writable: bool = false };

pub fn translateRead(regions: []const Region, address: u64, length: u64) !u64 {
    return translate(regions, address, length, false);
}

pub fn translateWrite(regions: []const Region, address: u64, length: u64) !u64 {
    return translate(regions, address, length, true);
}

fn translate(regions: []const Region, address: u64, length: u64, writing: bool) !u64 {
    if (length == 0) return error.InvalidUserRange;
    const end = @addWithOverflow(address, length);
    if (end[1] != 0) return error.InvalidUserRange;
    for (regions) |region| {
        const region_end = @addWithOverflow(region.virtual, region.length);
        const physical_end = @addWithOverflow(region.physical, region.length);
        if (region.length == 0 or region_end[1] != 0 or physical_end[1] != 0)
            return error.InvalidMapping;
        if ((if (writing) region.writable else region.readable) and address >= region.virtual and end[0] <= region_end[0])
            return region.physical + (address - region.virtual);
    }
    return error.InvalidUserRange;
}

test "copyout rejects executable input and requires the selected writable region" {
    const t = @import("std").testing;
    const regions = [_]Region{
        .{ .virtual = 0x10000, .physical = 0x500000, .length = 4096 },
        .{ .virtual = 0x11000, .physical = 0x600000, .length = 4096, .writable = true },
    };
    try t.expectError(error.InvalidUserRange, translateWrite(&regions, 0x10000, 8));
    try t.expectError(error.InvalidUserRange, translateWrite(&regions, 0x11ffc, 8));
    try t.expectError(error.InvalidUserRange, translateWrite(&regions, 0x600000, 8));
    try t.expectEqual(@as(u64, 0x600001), try translateWrite(&regions, 0x11001, 16));
}

test "user reads translate through only the selected task's mappings" {
    const t = @import("std").testing;
    const a = [_]Region{.{ .virtual = 0x2000000000, .physical = 0x500000, .length = 4096 }};
    const b = [_]Region{.{ .virtual = 0x2000000000, .physical = 0x600000, .length = 4096 }};
    try t.expectEqual(@as(u64, 0x500000), try translateRead(&a, 0x2000000000, 8));
    try t.expectEqual(@as(u64, 0x600fff), try translateRead(&b, 0x2000000fff, 1));
    try t.expectError(error.InvalidUserRange, translateRead(&a, 0x600000, 8));
    try t.expectError(error.InvalidUserRange, translateRead(&a, 0x500000, 8));
}

test "user ranges reject page crossing guard pages and unreadable mappings" {
    const t = @import("std").testing;
    const regions = [_]Region{
        .{ .virtual = 0x10000, .physical = 0x500000, .length = 4096 },
        .{ .virtual = 0x12000, .physical = 0x600000, .length = 4096, .readable = false },
    };
    try t.expectError(error.InvalidUserRange, translateRead(&regions, 0x10ffc, 8));
    try t.expectError(error.InvalidUserRange, translateRead(&regions, 0x11000, 1));
    try t.expectError(error.InvalidUserRange, translateRead(&regions, 0x12000, 1));
    try t.expectError(error.InvalidUserRange, translateRead(&regions, 0xffff, 1));
}

test "user pointer arithmetic rejects wraparound and empty requests" {
    const t = @import("std").testing;
    const regions = [_]Region{.{ .virtual = 0x10000, .physical = 0x500000, .length = 4096 }};
    try t.expectError(error.InvalidUserRange, translateRead(&regions, 0xfffffffffffffff8, 16));
    try t.expectError(error.InvalidUserRange, translateRead(&regions, 0x10000, 0));
    try t.expectError(error.InvalidUserRange, translateRead(&regions, 0x10000, 0xffffffffffffffff));
}

test "malformed trusted mapping geometry fails before physical access" {
    const t = @import("std").testing;
    for ([_]Region{
        .{ .virtual = 0xfffffffffffffff0, .physical = 1, .length = 4096 },
        .{ .virtual = 0x10000, .physical = 0xfffffffffffffff0, .length = 4096 },
        .{ .virtual = 0x10000, .physical = 1, .length = 0 },
    }) |region| try t.expectError(error.InvalidMapping, translateRead(&.{region}, 0x10000, 1));
}
