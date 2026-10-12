//! Bounded sparse four-level identity mappings for the UEFI transition.
//! The PAT layout is installed by entry.S before these tables are activated.
const std = @import("std");
const protocol = @import("boot_protocol");
pub const page_size = 4096;
pub const large_page_size = 0x200000;
pub const max_table_pages = 256;
pub const canonical_limit: u64 = 1 << 47;
const address_mask: u64 = 0x000ffffffffff000;
const present: u64 = 1;
const writable: u64 = 2;
const large: u64 = 1 << 7;

pub const Cache = enum { write_back, write_through, write_combining, uncacheable };
pub const Error = protocol.RangeError || error{
    InvalidTablePool,
    UnsupportedPhysicalWidth,
    AddressOutsideBootstrapMap,
    PageTablePoolExhausted,
    TooManyMappedRanges,
    InvalidPageTable,
};
pub const Translation = struct { physical: u64, cache: Cache, page_bytes: u64 };

fn cacheFlags(cache: Cache, is_large: bool) u64 {
    return switch (cache) {
        .write_back => 0,
        .write_through => 1 << 3,
        .uncacheable => (1 << 3) | (1 << 4),
        .write_combining => (1 << 4) | (@as(u64, 1) << @as(u6, if (is_large) 12 else 7)),
    };
}
fn flagsCache(flags: u64, is_large: bool) Cache {
    const pat = flags & (@as(u64, 1) << @as(u6, if (is_large) 12 else 7)) != 0;
    const index: u3 = @as(u3, @intCast((flags >> 3) & 3)) | (if (pat) @as(u3, 4) else 0);
    return switch (index) {
        0, 4 => .write_back,
        1, 5 => .write_through,
        6 => .write_combining,
        else => .uncacheable,
    };
}

pub const Builder = struct {
    tables: []align(page_size) u64,
    physical_base: u64,
    pages_used: usize = 1,
    physical_bits: u32,
    limit: u64,
    range_count: usize = 0,
    ranges: [protocol.max_mapped_ranges]protocol.PhysicalRange = @splat(.{ .base = 0, .length = 0 }),

    pub fn init(tables: []align(page_size) u64, physical_base: u64, physical_bits: u32) Error!Builder {
        if (tables.len < 512 or tables.len > max_table_pages * 512 or tables.len % 512 != 0 or physical_base % page_size != 0)
            return error.InvalidTablePool;
        if (physical_bits < 32 or physical_bits > 52) return error.UnsupportedPhysicalWidth;
        const limit = @min(canonical_limit, @as(u64, 1) << @as(u6, @intCast(physical_bits)));
        const pool: protocol.PhysicalRange = .{ .base = physical_base, .length = @as(u64, @intCast(tables.len)) * 8 };
        if (try pool.endExclusive() > limit) return error.AddressOutsideBootstrapMap;
        @memset(tables, 0);
        return .{ .tables = tables, .physical_base = physical_base, .physical_bits = physical_bits, .limit = limit };
    }
    fn table(self: *Builder, address: u64) Error![]u64 {
        if (address < self.physical_base or (address - self.physical_base) % page_size != 0)
            return error.InvalidPageTable;
        const offset = (address - self.physical_base) / 8;
        if (offset + 512 > self.tables.len) return error.InvalidPageTable;
        return self.tables[@intCast(offset)..][0..512];
    }
    fn allocate(self: *Builder) Error!u64 {
        if (self.pages_used >= self.tables.len / 512) return error.PageTablePoolExhausted;
        const address = self.physical_base + self.pages_used * page_size;
        self.pages_used += 1;
        return address;
    }
    fn child(self: *Builder, parent: []u64, index: usize) Error![]u64 {
        if (parent[index] & present == 0) parent[index] = try self.allocate() | present | writable;
        if (parent[index] & large != 0) return error.InvalidPageTable;
        return self.table(parent[index] & address_mask);
    }
    fn directory(self: *Builder, address: u64) Error![]u64 {
        const root = try self.table(self.physical_base);
        const pdpt = try self.child(root, @intCast((address >> 39) & 511));
        return self.child(pdpt, @intCast((address >> 30) & 511));
    }
    fn split(self: *Builder, directory_entry: *u64) Error![]u64 {
        const old = directory_entry.*;
        const address = try self.allocate();
        const entries = try self.table(address);
        const base = old & 0x000fffffffe00000;
        const flags = present | writable | cacheFlags(flagsCache(old, true), false);
        for (entries, 0..) |*entry, index| entry.* = base + index * page_size | flags;
        directory_entry.* = address | present | writable;
        return entries;
    }
    fn mapPage(self: *Builder, address: u64, cache: Cache, use_large: bool) Error!void {
        const pd = try self.directory(address);
        const index: usize = @intCast((address >> 21) & 511);
        if (use_large and (pd[index] & present == 0 or pd[index] & large != 0)) {
            pd[index] = address | present | writable | large | cacheFlags(cache, true);
            return;
        }
        const pt = if (pd[index] & large != 0) try self.split(&pd[index]) else try self.child(pd, index);
        if (use_large) {
            for (pt, 0..) |*entry, offset| entry.* = address + offset * page_size | present | writable | cacheFlags(cache, false);
        } else pt[@intCast((address >> 12) & 511)] = address | present | writable | cacheFlags(cache, false);
    }
    fn remember(self: *Builder, range: protocol.PhysicalRange) Error!void {
        var base = range.base;
        var end = try range.endExclusive();
        var index: usize = 0;
        while (index < self.range_count) {
            const other = self.ranges[index];
            const other_end = try other.endExclusive();
            if (other_end < base) {
                index += 1;
                continue;
            }
            if (other.base > end) break;
            base = @min(base, other.base);
            end = @max(end, other_end);
            for (index + 1..self.range_count) |position| self.ranges[position - 1] = self.ranges[position];
            self.range_count -= 1;
        }
        if (self.range_count == self.ranges.len) return error.TooManyMappedRanges;
        var position = self.range_count;
        while (position > index) : (position -= 1) self.ranges[position] = self.ranges[position - 1];
        self.ranges[index] = .{ .base = base, .length = end - base };
        self.range_count += 1;
    }
    pub fn map(self: *Builder, range: protocol.PhysicalRange, cache: Cache) Error!void {
        if (range.length == 0) return;
        const end = try range.endExclusive();
        const rounded = @addWithOverflow(end, @as(u64, page_size - 1));
        if (rounded[1] != 0) return error.PhysicalRangeOverflow;
        const mapped_end = rounded[0] & ~@as(u64, page_size - 1);
        var address = range.base & ~@as(u64, page_size - 1);
        if (mapped_end > self.limit) return error.AddressOutsideBootstrapMap;
        const mapped_base = address;
        while (address < mapped_end) {
            const use_large = address % large_page_size == 0 and mapped_end - address >= large_page_size;
            try self.mapPage(address, cache, use_large);
            address += if (use_large) large_page_size else page_size;
        }
        try self.remember(.{ .base = mapped_base, .length = mapped_end - mapped_base });
    }
    pub fn publish(self: *const Builder, info: *protocol.BootInfo) void {
        info.mapped_range_count = @intCast(self.range_count);
        info.physical_address_bits = self.physical_bits;
        info.mapped_ranges = @splat(.{ .base = 0, .length = 0 });
        @memcpy(info.mapped_ranges[0..self.range_count], self.ranges[0..self.range_count]);
    }
    pub fn translate(self: *Builder, address: u64) Error!?Translation {
        if (address >= self.limit) return null;
        var table_address = self.physical_base;
        const shifts = [_]u6{ 39, 30, 21, 12 };
        for (shifts, 0..) |shift, level| {
            const entries = try self.table(table_address);
            const entry = entries[@intCast((address >> shift) & 511)];
            if (entry & present == 0) return null;
            if (level == 2 and entry & large != 0)
                return .{ .physical = (entry & 0x000fffffffe00000) | (address & (large_page_size - 1)), .cache = flagsCache(entry, true), .page_bytes = large_page_size };
            if (level == 3)
                return .{ .physical = (entry & address_mask) | (address & (page_size - 1)), .cache = flagsCache(entry, false), .page_bytes = page_size };
            table_address = entry & address_mask;
        }
        return error.InvalidPageTable;
    }
};

test "sparse identity mappings span above 4 GiB and leave holes absent" {
    var pool: [16 * 512]u64 align(page_size) = undefined;
    var builder = try Builder.init(&pool, 0x100000, 48);
    try builder.map(.{ .base = 0x200000, .length = large_page_size }, .write_back);
    try builder.map(.{ .base = 0x100200000, .length = large_page_size }, .write_combining);
    try std.testing.expectEqual(@as(u64, 0x100200123), (try builder.translate(0x100200123)).?.physical);
    try std.testing.expectEqual(Cache.write_combining, (try builder.translate(0x100200123)).?.cache);
    try std.testing.expect((try builder.translate(0x400000)) == null);
    try std.testing.expectEqual(@as(usize, 2), builder.range_count);
}
test "partial cache override splits a large page without changing neighbors" {
    var pool: [8 * 512]u64 align(page_size) = undefined;
    var builder = try Builder.init(&pool, 0x100000, 36);
    try builder.map(.{ .base = 0x200000, .length = large_page_size }, .write_back);
    try builder.map(.{ .base = 0x201123, .length = 4 }, .uncacheable);
    try std.testing.expectEqual(Cache.uncacheable, (try builder.translate(0x201123)).?.cache);
    try std.testing.expectEqual(Cache.write_back, (try builder.translate(0x202000)).?.cache);
    try std.testing.expectEqual(@as(u64, page_size), (try builder.translate(0x202000)).?.page_bytes);
    try std.testing.expectEqual(@as(usize, 1), builder.range_count);
    // A later full-range policy update must also work after a prior split.
    try builder.map(.{ .base = 0x200000, .length = large_page_size }, .write_combining);
    try std.testing.expectEqual(Cache.write_combining, (try builder.translate(0x201123)).?.cache);
    try std.testing.expectEqual(Cache.write_combining, (try builder.translate(0x202000)).?.cache);
}
test "coverage publication merges unsorted adjacent ranges and clears unused records" {
    var pool: [8 * 512]u64 align(page_size) = undefined;
    var builder = try Builder.init(&pool, 0x100000, 52);
    try builder.map(.{ .base = 0x600000, .length = large_page_size }, .write_back);
    try builder.map(.{ .base = 0x200000, .length = large_page_size }, .uncacheable);
    try builder.map(.{ .base = 0x400000, .length = large_page_size }, .write_back);
    var info: protocol.BootInfo = undefined;
    builder.publish(&info);
    try std.testing.expectEqual(@as(u32, 1), info.mapped_range_count);
    try std.testing.expectEqual(protocol.PhysicalRange{ .base = 0x200000, .length = 0x600000 }, info.mapped_ranges[0]);
    for (info.mapped_ranges[1..]) |range| try std.testing.expectEqual(protocol.PhysicalRange{ .base = 0, .length = 0 }, range);
    try std.testing.expectError(error.AddressOutsideBootstrapMap, builder.map(.{ .base = canonical_limit, .length = 4096 }, .write_back));
}
test "mapper rejects overflow, unsupported address widths and exhausted tables" {
    var pool: [3 * 512]u64 align(page_size) = undefined;
    try std.testing.expectError(error.UnsupportedPhysicalWidth, Builder.init(&pool, 0x100000, 31));
    var builder = try Builder.init(&pool, 0x100000, 36);
    try std.testing.expectError(error.PhysicalRangeOverflow, builder.map(.{ .base = std.math.maxInt(u64), .length = 2 }, .write_back));
    try std.testing.expectError(error.AddressOutsideBootstrapMap, builder.map(.{ .base = 1 << 36, .length = 4096 }, .write_back));
    try std.testing.expectError(error.PageTablePoolExhausted, builder.map(.{ .base = 0x201000, .length = 4096 }, .write_back));
}
