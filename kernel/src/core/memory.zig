//! Page enumeration consumes the validated, normalized boot memory map.
//! Missing and unknown memory kinds are never available for allocation.
const std = @import("std");
const protocol = @import("boot_protocol");

pub const page_size: u64 = 4096;

pub const Summary = struct { regions: usize, usable_bytes: u64, usable_pages: u64 };

pub fn summarize(info: *const protocol.BootInfo) !Summary {
    if (info.memory_region_count == 0 or info.memory_region_count > protocol.max_memory_regions)
        return error.InvalidMemoryMap;
    var result: Summary = .{ .regions = info.memory_region_count, .usable_bytes = 0, .usable_pages = 0 };
    for (info.memory_regions[0..info.memory_region_count]) |region| {
        _ = try region.range.endExclusive();
        if (region.kind != @backingInt(protocol.MemoryKind.usable)) continue;
        result.usable_bytes = std.math.add(u64, result.usable_bytes, region.range.length) catch return error.MemorySizeOverflow;
        const bounds = pageBounds(region.range) orelse continue;
        result.usable_pages = std.math.add(u64, result.usable_pages, (bounds.end - bounds.start) / page_size) catch return error.MemorySizeOverflow;
    }
    return result;
}

const Bounds = struct { start: u64, end: u64 };
fn pageBounds(range: protocol.PhysicalRange) ?Bounds {
    const end = range.endExclusive() catch return null;
    const rounded = @addWithOverflow(range.base, page_size - 1);
    if (rounded[1] != 0) return null;
    const start = rounded[0] & ~(page_size - 1);
    const aligned_end = end & ~(page_size - 1);
    if (start >= aligned_end) return null;
    return .{ .start = start, .end = aligned_end };
}

/// A bootstrap cursor; callers retain the BootInfo storage and must have
/// validated its map. Each yielded physical frame becomes caller-owned.
/// limit_exclusive describes current addressability, not total installed RAM.
pub const PageCursor = struct {
    regions: []const protocol.MemoryRegion,
    mapped_ranges: []const protocol.PhysicalRange,
    limit_exclusive: u64,
    region_index: usize = 0,
    next_address: u64 = 0,

    pub fn init(info: *const protocol.BootInfo, limit_exclusive: u64) PageCursor {
        std.debug.assert(info.memory_region_count <= protocol.max_memory_regions);
        std.debug.assert(info.mapped_range_count <= protocol.max_mapped_ranges);
        return .{ .regions = info.memory_regions[0..info.memory_region_count], .mapped_ranges = info.mapped_ranges[0..info.mapped_range_count], .limit_exclusive = limit_exclusive };
    }

    pub fn next(self: *PageCursor) ?u64 {
        while (self.region_index < self.regions.len) {
            const region = self.regions[self.region_index];
            const bounds = if (region.kind == @backingInt(protocol.MemoryKind.usable)) pageBounds(region.range) else null;
            if (bounds) |range| {
                var address = @max(self.next_address, range.start);
                const limit = @min(range.end, self.limit_exclusive & ~(page_size - 1));
                if (self.mapped_ranges.len != 0) {
                    var found = false;
                    for (self.mapped_ranges) |mapped| {
                        const coverage = pageBounds(mapped) orelse continue;
                        const candidate = @max(address, coverage.start);
                        if (candidate < @min(limit, coverage.end)) {
                            address = candidate;
                            found = true;
                            break;
                        }
                    }
                    if (!found) {
                        self.region_index += 1;
                        self.next_address = 0;
                        continue;
                    }
                }
                if (address < limit) {
                    self.next_address = address + page_size;
                    return address;
                }
            }
            self.region_index += 1;
            self.next_address = 0;
        }
        return null;
    }
};

test "bootstrap frames skip holes, partial pages and unknown memory kinds" {
    var info: protocol.BootInfo = undefined;
    info.mapped_range_count = 0;
    info.memory_region_count = 4;
    info.memory_regions[0] = .{ .range = .{ .base = 0x1001, .length = 0x2fff }, .kind = @backingInt(protocol.MemoryKind.usable), .attributes = 0 };
    info.memory_regions[1] = .{ .range = .{ .base = 0x4000, .length = 0x1000 }, .kind = @backingInt(protocol.MemoryKind.kernel), .attributes = 0 };
    info.memory_regions[2] = .{ .range = .{ .base = 0x5000, .length = 0x1000 }, .kind = 99, .attributes = 0 };
    info.memory_regions[3] = .{ .range = .{ .base = 0x9000, .length = 0x3000 }, .kind = @backingInt(protocol.MemoryKind.usable), .attributes = 0 };
    const summary = try summarize(&info);
    try std.testing.expectEqual(@as(u64, 5), summary.usable_pages);
    var cursor = PageCursor.init(&info, 0xa800);
    try std.testing.expectEqual(@as(?u64, 0x2000), cursor.next());
    try std.testing.expectEqual(@as(?u64, 0x3000), cursor.next());
    try std.testing.expectEqual(@as(?u64, 0x9000), cursor.next());
    try std.testing.expectEqual(@as(?u64, null), cursor.next());
}

test "frames beyond the current mapping limit remain unavailable" {
    var info: protocol.BootInfo = undefined;
    info.mapped_range_count = 0;
    info.memory_region_count = 1;
    info.memory_regions[0] = .{ .range = .{ .base = 0x100000000, .length = 0x2000 }, .kind = @backingInt(protocol.MemoryKind.usable), .attributes = 0 };
    var cursor = PageCursor.init(&info, 0x100000000);
    try std.testing.expectEqual(@as(?u64, null), cursor.next());
    cursor = PageCursor.init(&info, 0x100002000);
    try std.testing.expectEqual(@as(?u64, 0x100000000), cursor.next());
    try std.testing.expectEqual(@as(?u64, 0x100001000), cursor.next());
    try std.testing.expectEqual(@as(?u64, null), cursor.next());
}

test "sparse bootstrap coverage limits usable frames across unmapped holes" {
    var info: protocol.BootInfo = undefined;
    info.memory_region_count = 1;
    info.memory_regions[0] = .{ .range = .{ .base = 0x1000, .length = 0x8000 }, .kind = @backingInt(protocol.MemoryKind.usable), .attributes = 0 };
    info.mapped_range_count = 3;
    info.mapped_ranges[0] = .{ .base = 0x1800, .length = 0x1800 };
    info.mapped_ranges[1] = .{ .base = 0x5000, .length = 0x2000 };
    info.mapped_ranges[2] = .{ .base = 0x100000000, .length = 0x1000 };
    var cursor = PageCursor.init(&info, std.math.maxInt(u64));
    try std.testing.expectEqual(@as(?u64, 0x2000), cursor.next());
    try std.testing.expectEqual(@as(?u64, 0x5000), cursor.next());
    try std.testing.expectEqual(@as(?u64, 0x6000), cursor.next());
    try std.testing.expectEqual(@as(?u64, null), cursor.next());
}
