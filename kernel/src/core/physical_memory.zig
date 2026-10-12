//! Portable allocation of 4 KiB physical frames from a normalized memory map.
//! The caller validates the handoff and supplies the current address limit.
//! Explicit identity coverage further restricts eligibility when present.
//! Legacy reset profiles with no coverage rely on that trusted caller limit.
//! This module never dereferences physical addresses or reclaims reservations.
const std = @import("std");
const protocol = @import("boot_protocol");

pub const page_size: u64 = 4096;
pub const max_spans = protocol.max_memory_regions + protocol.max_mapped_ranges;

pub const Error = protocol.RangeError || error{
    InvalidMemoryRegionCount,
    InvalidMemoryRegionAttributes,
    InvalidMemoryRange,
    UnsortedMemoryRegions,
    InvalidMappedRangeCount,
    InvalidMappedRange,
    UnsortedMappedRanges,
    InvalidAddressLimit,
    TooManySpans,
    SizeOverflow,
    NoUsableMemory,
    MetadataUnavailable,
    InvalidLayout,
    BitmapTooSmall,
    InvalidPageCount,
    InvalidAlignment,
    InvalidFree,
    MetadataPage,
    DoubleFree,
};

/// Bitmap indices are packed across spans; physical holes consume no bits.
pub const Span = struct {
    base: u64 = 0,
    page_count: u64 = 0,
    first_index: u64 = 0,

    fn end(self: Span) u64 {
        return self.base + self.page_count * page_size;
    }
};

pub const Layout = struct {
    spans: [max_spans]Span = @splat(Span{}),
    span_count: usize = 0,
    /// Includes the bitmap's own permanently reserved pages.
    page_count: u64 = 0,
    /// Minimum byte length of the caller-owned bitmap.
    bitmap_bytes: usize = 0,
    /// A complete, accessible, usable span reserved for that bitmap.
    storage: protocol.PhysicalRange = .{ .base = 0, .length = 0 },

    /// Validates only the memory and coverage arrays, not other BootInfo fields.
    /// Unknown kinds stay reserved. An empty coverage array grants no new
    /// permission: the platform must establish the supplied address limit.
    pub fn init(info: *const protocol.BootInfo, limit_exclusive: u64) Error!Layout {
        if (limit_exclusive == 0) return error.InvalidAddressLimit;
        if (info.memory_region_count == 0 or info.memory_region_count > protocol.max_memory_regions)
            return error.InvalidMemoryRegionCount;
        if (info.mapped_range_count > protocol.max_mapped_ranges)
            return error.InvalidMappedRangeCount;

        const regions = info.memory_regions[0..info.memory_region_count];
        const mapped = info.mapped_ranges[0..info.mapped_range_count];
        var previous_end: u64 = 0;
        for (regions, 0..) |region, index| {
            if (region.range.length == 0) return error.InvalidMemoryRange;
            const end = try region.range.endExclusive();
            if (index != 0 and region.range.base < previous_end) return error.UnsortedMemoryRegions;
            if (region.attributes != 0) return error.InvalidMemoryRegionAttributes;
            previous_end = end;
        }
        previous_end = 0;
        for (mapped, 0..) |range, index| {
            if (range.length == 0) return error.InvalidMappedRange;
            const end = try range.endExclusive();
            if (index != 0 and range.base < previous_end) return error.UnsortedMappedRanges;
            previous_end = end;
        }

        var result: Layout = .{};
        var pending: ?Bounds = null;
        for (regions) |region| {
            if (!region.isUsable()) continue;
            const region_end = @min(try region.range.endExclusive(), limit_exclusive);
            if (mapped.len == 0) {
                try result.addInterval(&pending, region.range.base, region_end);
            } else {
                for (mapped) |coverage| {
                    const coverage_end = try coverage.endExclusive();
                    if (coverage_end <= region.range.base) continue;
                    if (coverage.base >= region_end) break;
                    try result.addInterval(&pending, @max(region.range.base, coverage.base), @min(region_end, coverage_end));
                }
            }
        }
        if (pending) |range| try result.addSpan(range.start, range.end);
        if (result.page_count == 0) return error.NoUsableMemory;
        result.bitmap_bytes = try bitmapSize(result.page_count);
        const storage_bytes = try bitmapStorageSize(result.bitmap_bytes);
        for (result.spans[0..result.span_count]) |span| {
            if (span.end() - span.base >= storage_bytes) {
                result.storage = .{ .base = span.base, .length = storage_bytes };
                return result;
            }
        }
        return error.MetadataUnavailable;
    }

    // Adjacent descriptors/coverage can jointly cover a whole page, even when
    // their internal boundary is unaligned. Round only after joining them.
    fn addInterval(self: *Layout, pending: *?Bounds, start: u64, end: u64) Error!void {
        if (start >= end) return;
        if (pending.*) |*range| {
            if (start == range.end) {
                range.end = end;
                return;
            }
            try self.addSpan(range.start, range.end);
        }
        pending.* = .{ .start = start, .end = end };
    }

    fn addSpan(self: *Layout, raw_start: u64, raw_end: u64) Error!void {
        if (raw_start >= raw_end) return;
        // Physical page zero is never handed out, even if firmware calls it RAM.
        const start = alignedForward(@max(raw_start, page_size), page_size) orelse return;
        const end = raw_end & ~(page_size - 1);
        if (start >= end) return;
        const count = (end - start) / page_size;
        const total = @addWithOverflow(self.page_count, count);
        if (total[1] != 0) return error.SizeOverflow;
        if (self.span_count != 0) {
            const last = &self.spans[self.span_count - 1];
            if (last.end() == start) {
                last.page_count += count;
                self.page_count = total[0];
                return;
            }
        }
        if (self.span_count == max_spans) return error.TooManySpans;
        self.spans[self.span_count] = .{ .base = start, .page_count = count, .first_index = self.page_count };
        self.span_count += 1;
        self.page_count = total[0];
    }

    /// Public layouts may be copied or persisted; check their internal bounds
    /// again before accepting a caller's bitmap storage.
    fn validate(self: *const Layout) Error!void {
        if (self.span_count == 0 or self.span_count > max_spans or self.page_count == 0)
            return error.InvalidLayout;
        var count: u64 = 0;
        var previous_end: u64 = 0;
        for (self.spans[0..self.span_count], 0..) |span, index| {
            if (span.base == 0 or span.base % page_size != 0 or span.page_count == 0 or span.first_index != count)
                return error.InvalidLayout;
            const bytes = @mulWithOverflow(span.page_count, page_size);
            if (bytes[1] != 0) return error.InvalidLayout;
            const end = @addWithOverflow(span.base, bytes[0]);
            if (end[1] != 0 or (index != 0 and span.base <= previous_end)) return error.InvalidLayout;
            previous_end = end[0];
            const total = @addWithOverflow(count, span.page_count);
            if (total[1] != 0) return error.InvalidLayout;
            count = total[0];
        }
        if (count != self.page_count or self.bitmap_bytes != try bitmapSize(count)) return error.InvalidLayout;
        if (self.storage.base % page_size != 0 or self.storage.length != try bitmapStorageSize(self.bitmap_bytes))
            return error.InvalidLayout;
        _ = self.indexForRange(self.storage) orelse return error.InvalidLayout;
    }

    fn indexForRange(self: *const Layout, range: protocol.PhysicalRange) ?u64 {
        const end = range.endExclusive() catch return null;
        for (self.spans[0..self.span_count]) |span| {
            if (range.base >= span.base and end <= span.end())
                return span.first_index + (range.base - span.base) / page_size;
        }
        return null;
    }

    fn addressForIndex(self: *const Layout, index: u64) u64 {
        for (self.spans[0..self.span_count]) |span| {
            if (index >= span.first_index and index - span.first_index < span.page_count)
                return span.base + (index - span.first_index) * page_size;
        }
        unreachable;
    }
};

const Bounds = struct { start: u64, end: u64 };

pub const Stats = struct {
    free_pages: u64,
    allocated_pages: u64,
    metadata_pages: u64,
    managed_pages: u64,
};

/// Single-owner bootstrap allocator. The bitmap must outlive this object and
/// must not be modified separately. SMP/interrupt synchronization is a caller
/// responsibility; current Bedrock entry profiles run on one masked CPU.
pub const Allocator = struct {
    layout: Layout,
    bitmap: []u8,
    next_hint: u64 = 0,
    free_pages: u64,
    allocated_pages: u64 = 0,
    metadata_pages: u64,

    /// Only the provided slice is accessed. Production callers map it at
    /// layout.storage; host tests can supply ordinary memory instead.
    pub fn init(layout: Layout, bitmap: []u8) Error!Allocator {
        try layout.validate();
        if (bitmap.len < layout.bitmap_bytes) return error.BitmapTooSmall;
        const metadata_pages = layout.storage.length / page_size;
        var result: Allocator = .{
            .layout = layout,
            .bitmap = bitmap[0..layout.bitmap_bytes],
            .free_pages = layout.page_count - metadata_pages,
            .metadata_pages = metadata_pages,
        };
        @memset(result.bitmap, 0);
        const metadata_index = layout.indexForRange(layout.storage).?;
        result.mark(metadata_index, metadata_pages, true);
        // Unused high bits cannot become phantom pages in bitmap scans.
        if (layout.page_count % 8 != 0) {
            const used: u3 = @intCast(layout.page_count % 8);
            result.bitmap[result.bitmap.len - 1] |= @as(u8, 0xff) << used;
        }
        return result;
    }

    pub fn stats(self: *const Allocator) Stats {
        return .{
            .free_pages = self.free_pages,
            .allocated_pages = self.allocated_pages,
            .metadata_pages = self.metadata_pages,
            .managed_pages = self.layout.page_count,
        };
    }

    pub fn allocate(self: *Allocator) ?u64 {
        if (self.free_pages == 0) return null;
        const index = self.firstFree(self.next_hint, self.layout.page_count) orelse
            self.firstFree(0, self.next_hint) orelse unreachable;
        self.mark(index, 1, true);
        self.free_pages -= 1;
        self.allocated_pages += 1;
        self.next_hint = if (index + 1 == self.layout.page_count) 0 else index + 1;
        return self.layout.addressForIndex(index);
    }

    pub fn release(self: *Allocator, address: u64) Error!void {
        try self.releaseContiguous(.{ .base = address, .length = page_size });
    }

    /// Alignment is a nonzero power-of-two count of physical pages. A run
    /// cannot cross a physical hole. Failure leaves all allocation bits intact.
    pub fn allocateContiguous(self: *Allocator, count: usize, alignment_pages: usize) Error!?protocol.PhysicalRange {
        if (count == 0) return error.InvalidPageCount;
        if (alignment_pages == 0 or (alignment_pages & (alignment_pages - 1)) != 0)
            return error.InvalidAlignment;
        const length = @mulWithOverflow(@as(u64, count), page_size);
        const alignment = @mulWithOverflow(@as(u64, alignment_pages), page_size);
        if (length[1] != 0 or alignment[1] != 0) return error.SizeOverflow;
        if (count > self.free_pages) return null;

        for (self.layout.spans[0..self.layout.span_count]) |span| {
            var candidate = alignedForward(span.base, alignment[0]) orelse continue;
            const end = span.end();
            while (candidate < end and length[0] <= end - candidate) {
                const first = span.first_index + (candidate - span.base) / page_size;
                var busy_offset: ?u64 = null;
                for (0..count) |offset| {
                    if (self.isSet(first + offset)) {
                        busy_offset = offset;
                        break;
                    }
                }
                if (busy_offset) |offset| {
                    // Every earlier candidate would include this busy page.
                    candidate = alignedForward(candidate + (offset + 1) * page_size, alignment[0]) orelse break;
                    continue;
                }
                self.mark(first, count, true);
                self.free_pages -= count;
                self.allocated_pages += count;
                return .{ .base = candidate, .length = length[0] };
            }
        }
        return null;
    }

    /// All pages must be eligible, allocated, and outside permanent metadata.
    /// Validation completes before any bit or counter is changed.
    pub fn releaseContiguous(self: *Allocator, range: protocol.PhysicalRange) Error!void {
        if (range.base % page_size != 0) return error.InvalidAlignment;
        if (range.length == 0 or range.length % page_size != 0) return error.InvalidPageCount;
        const end = try range.endExclusive();
        const first = self.layout.indexForRange(range) orelse return error.InvalidFree;
        const metadata_end = self.layout.storage.endExclusive() catch unreachable;
        if (range.base < metadata_end and self.layout.storage.base < end) return error.MetadataPage;
        const count = range.length / page_size;
        var offset: u64 = 0;
        while (offset < count) : (offset += 1) {
            if (!self.isSet(first + offset)) return error.DoubleFree;
        }
        self.mark(first, count, false);
        self.free_pages += count;
        self.allocated_pages -= count;
        self.next_hint = @min(self.next_hint, first);
    }

    fn firstFree(self: *const Allocator, start: u64, end: u64) ?u64 {
        var index = start;
        while (index < end) {
            if (index % 8 == 0 and end - index >= 8 and self.bitmap[@intCast(index / 8)] == 0xff) {
                index += 8;
            } else {
                if (!self.isSet(index)) return index;
                index += 1;
            }
        }
        return null;
    }

    fn isSet(self: *const Allocator, index: u64) bool {
        const bit: u3 = @intCast(index % 8);
        return self.bitmap[@intCast(index / 8)] & (@as(u8, 1) << bit) != 0;
    }

    fn mark(self: *Allocator, first: u64, count: u64, allocated: bool) void {
        var index = first;
        while (index - first < count) : (index += 1) {
            const bit: u3 = @intCast(index % 8);
            const mask = @as(u8, 1) << bit;
            const byte = &self.bitmap[@intCast(index / 8)];
            if (allocated) byte.* |= mask else byte.* &= ~mask;
        }
    }
};

fn alignedForward(value: u64, alignment: u64) ?u64 {
    const sum = @addWithOverflow(value, alignment - 1);
    if (sum[1] != 0) return null;
    return sum[0] & ~(alignment - 1);
}

fn bitmapSize(pages: u64) Error!usize {
    const bytes = pages / 8 + @intFromBool(pages % 8 != 0);
    if (bytes > std.math.maxInt(usize)) return error.SizeOverflow;
    return @intCast(bytes);
}

fn bitmapStorageSize(bytes: usize) Error!u64 {
    return alignedForward(bytes, page_size) orelse error.SizeOverflow;
}

fn testInfo(regions: []const protocol.MemoryRegion, mapped: []const protocol.PhysicalRange) protocol.BootInfo {
    // Deliberately leave non-map fields uninitialized: Layout has no dependency
    // on header, console, loader, or other platform-specific handoff fields.
    var info: protocol.BootInfo = undefined;
    info.memory_region_count = @intCast(regions.len);
    info.mapped_range_count = @intCast(mapped.len);
    @memcpy(info.memory_regions[0..regions.len], regions);
    @memcpy(info.mapped_ranges[0..mapped.len], mapped);
    return info;
}

fn testRegion(base: u64, length: u64, kind: protocol.MemoryKind) protocol.MemoryRegion {
    return .{ .range = .{ .base = base, .length = length }, .kind = @backingInt(kind), .attributes = 0 };
}

test "layout excludes zero, partial pages, holes and every reserved kind" {
    var regions = [_]protocol.MemoryRegion{
        testRegion(0, 0x2800, .usable),
        testRegion(0x2800, 0x800, .reserved),
        testRegion(0x3000, 0x1000, .loader_reclaimable),
        testRegion(0x4000, 0x1000, .kernel),
        testRegion(0x5000, 0x1000, .firmware_runtime),
        testRegion(0x6000, 0x1000, .mmio),
        testRegion(0x7000, 0x1000, .reserved),
        testRegion(0x9100, 0x3f00, .usable),
    };
    regions[6].kind = 0xffff;
    var info = testInfo(&regions, &.{});
    const layout = try Layout.init(&info, std.math.maxInt(u64));
    try std.testing.expectEqual(@as(u64, 4), layout.page_count);
    try std.testing.expectEqual(@as(usize, 2), layout.span_count);
    try std.testing.expectEqualDeep(protocol.PhysicalRange{ .base = 0x1000, .length = 0x1000 }, layout.storage);
    var bitmap: [1]u8 = undefined;
    var allocator = try Allocator.init(layout, &bitmap);
    for ([_]u64{ 0xa000, 0xb000, 0xc000 }) |expected| try std.testing.expectEqual(@as(?u64, expected), allocator.allocate());
    try std.testing.expectEqual(@as(?u64, null), allocator.allocate());
}

test "layout intersects high sparse coverage with the trusted address limit" {
    const base: u64 = 0x100000000;
    var info = testInfo(&.{testRegion(base, 0x10000, .usable)}, &.{
        .{ .base = base + 0x800, .length = 0x2000 },
        .{ .base = base + 0x8000, .length = 0x3000 },
    });
    const layout = try Layout.init(&info, base + 0xa800);
    try std.testing.expectEqual(@as(u64, 3), layout.page_count);
    try std.testing.expectEqual(@as(u64, base + 0x1000), layout.storage.base);
    // Layout owns its spans; mutation of the source cannot change eligibility.
    info.memory_regions[0].range.length = 0;
    info.mapped_ranges[0].length = 0;
    var bitmap: [1]u8 = undefined;
    var allocator = try Allocator.init(layout, &bitmap);
    try std.testing.expectEqual(@as(?u64, base + 0x8000), allocator.allocate());
    try std.testing.expectEqual(@as(?u64, base + 0x9000), allocator.allocate());
    try std.testing.expectEqual(@as(?u64, null), allocator.allocate());
}

test "adjacent eligibility is merged without admitting an unmapped page" {
    var info = testInfo(&.{
        testRegion(0x1000, 0x2000, .usable),
        testRegion(0x3000, 0x4000, .usable),
    }, &.{
        .{ .base = 0x1000, .length = 0x3000 },
        .{ .base = 0x4000, .length = 0x1000 },
        .{ .base = 0x6000, .length = 0x1000 },
    });
    const layout = try Layout.init(&info, 0x7000);
    try std.testing.expectEqual(@as(usize, 2), layout.span_count);
    try std.testing.expectEqual(@as(u64, 4), layout.spans[0].page_count);
    try std.testing.expectEqual(@as(u64, 5), layout.page_count);

    // Both kinds of boundary may be unaligned while their union is accessible.
    info = testInfo(&.{
        testRegion(0x1000, 0x800, .usable),
        testRegion(0x1800, 0x1800, .usable),
    }, &.{
        .{ .base = 0x1000, .length = 0xc00 },
        .{ .base = 0x1c00, .length = 0x1400 },
    });
    const joined = try Layout.init(&info, 0x3000);
    try std.testing.expectEqual(@as(u64, 2), joined.page_count);
    try std.testing.expectEqual(@as(usize, 1), joined.span_count);
}

test "layout rejects malformed map counts, attributes, order and overflow" {
    var info = testInfo(&.{testRegion(0x1000, 0x4000, .usable)}, &.{});
    try std.testing.expectError(error.InvalidAddressLimit, Layout.init(&info, 0));
    info.memory_region_count = 0;
    try std.testing.expectError(error.InvalidMemoryRegionCount, Layout.init(&info, 0x10000));
    info.memory_region_count = protocol.max_memory_regions + 1;
    try std.testing.expectError(error.InvalidMemoryRegionCount, Layout.init(&info, 0x10000));
    info.memory_region_count = 1;
    info.memory_regions[0].attributes = 1;
    try std.testing.expectError(error.InvalidMemoryRegionAttributes, Layout.init(&info, 0x10000));
    info.memory_regions[0].attributes = 0;
    info.memory_regions[0].range.length = 0;
    try std.testing.expectError(error.InvalidMemoryRange, Layout.init(&info, 0x10000));
    info.memory_regions[0].range = .{ .base = std.math.maxInt(u64), .length = 1 };
    try std.testing.expectError(error.PhysicalRangeOverflow, Layout.init(&info, std.math.maxInt(u64)));
    info.memory_regions[0] = testRegion(0x1000, 0x4000, .usable);
    info.memory_regions[1] = testRegion(0x4000, 0x2000, .reserved);
    info.memory_region_count = 2;
    try std.testing.expectError(error.UnsortedMemoryRegions, Layout.init(&info, 0x10000));
}

test "layout rejects malformed coverage and an empty eligible intersection" {
    var info = testInfo(&.{testRegion(0x1000, 0x4000, .usable)}, &.{});
    info.mapped_range_count = protocol.max_mapped_ranges + 1;
    try std.testing.expectError(error.InvalidMappedRangeCount, Layout.init(&info, 0x10000));
    info.mapped_range_count = 1;
    info.mapped_ranges[0] = .{ .base = 0x1000, .length = 0 };
    try std.testing.expectError(error.InvalidMappedRange, Layout.init(&info, 0x10000));
    info.mapped_ranges[0] = .{ .base = std.math.maxInt(u64), .length = 1 };
    try std.testing.expectError(error.PhysicalRangeOverflow, Layout.init(&info, std.math.maxInt(u64)));
    info.mapped_range_count = 2;
    info.mapped_ranges[0] = .{ .base = 0x3000, .length = 0x2000 };
    info.mapped_ranges[1] = .{ .base = 0x4000, .length = 0x1000 };
    try std.testing.expectError(error.UnsortedMappedRanges, Layout.init(&info, 0x10000));
    info.mapped_range_count = 1;
    info.mapped_ranges[0] = .{ .base = 0x5000, .length = 0x1000 };
    try std.testing.expectError(error.NoUsableMemory, Layout.init(&info, 0x10000));
}

test "metadata spanning multiple pages is never returned or released" {
    var info = testInfo(&.{testRegion(0x1000, 33000 * page_size, .usable)}, &.{});
    const layout = try Layout.init(&info, std.math.maxInt(u64));
    try std.testing.expectEqual(@as(usize, 4125), layout.bitmap_bytes);
    try std.testing.expectEqual(@as(u64, 8192), layout.storage.length);
    var bitmap: [4126]u8 = @splat(0x5a);
    var allocator = try Allocator.init(layout, &bitmap);
    try std.testing.expectEqual(@as(u8, 0x5a), bitmap[4125]);
    try std.testing.expectEqual(@as(?u64, 0x3000), allocator.allocate());
    try std.testing.expectError(error.MetadataPage, allocator.release(0x1000));
    try std.testing.expectError(error.MetadataPage, allocator.release(0x2000));
    try std.testing.expectEqualDeep(Stats{ .free_pages = 32997, .allocated_pages = 1, .metadata_pages = 2, .managed_pages = 33000 }, allocator.stats());

    // A short first span cannot hold two bitmap pages; use the later pool.
    info = testInfo(&.{
        testRegion(0x1000, page_size, .usable),
        testRegion(0x4000, 33000 * page_size, .usable),
    }, &.{});
    const later = try Layout.init(&info, std.math.maxInt(u64));
    try std.testing.expectEqualDeep(protocol.PhysicalRange{ .base = 0x4000, .length = 8192 }, later.storage);
    allocator = try Allocator.init(later, &bitmap);
    try std.testing.expectEqual(@as(?u64, 0x1000), allocator.allocate());
    try std.testing.expectEqual(@as(?u64, 0x6000), allocator.allocate());
    try std.testing.expectError(error.MetadataPage, allocator.release(0x4000));
    try std.testing.expectError(error.MetadataPage, allocator.release(0x5000));
}

test "exhaustion, release and reuse maintain accounting" {
    var info = testInfo(&.{testRegion(0x1000, 0x4000, .usable)}, &.{});
    const layout = try Layout.init(&info, 0x10000);
    var bitmap: [1]u8 = undefined;
    var allocator = try Allocator.init(layout, &bitmap);
    for ([_]u64{ 0x2000, 0x3000, 0x4000 }) |expected| try std.testing.expectEqual(@as(?u64, expected), allocator.allocate());
    try std.testing.expectEqual(@as(?u64, null), allocator.allocate());
    try std.testing.expectEqualDeep(Stats{ .free_pages = 0, .allocated_pages = 3, .metadata_pages = 1, .managed_pages = 4 }, allocator.stats());
    try allocator.release(0x3000);
    try std.testing.expectEqual(@as(?u64, 0x3000), allocator.allocate());
    try allocator.release(0x2000);
    try allocator.release(0x3000);
    try allocator.release(0x4000);
    try std.testing.expectEqual(@as(u64, 3), allocator.stats().free_pages);
    try std.testing.expectEqual(@as(u64, 0), allocator.stats().allocated_pages);
}

test "invalid, metadata and double frees leave state unchanged" {
    var info = testInfo(&.{testRegion(0x1000, 0x5000, .usable)}, &.{});
    const layout = try Layout.init(&info, 0x10000);
    var bitmap: [1]u8 = undefined;
    var allocator = try Allocator.init(layout, &bitmap);
    const page = allocator.allocate().?;
    const before = allocator.stats();
    const bits = bitmap;
    try std.testing.expectError(error.InvalidAlignment, allocator.release(page + 1));
    try std.testing.expectError(error.InvalidFree, allocator.release(0));
    try std.testing.expectError(error.InvalidFree, allocator.release(0x6000));
    try std.testing.expectError(error.MetadataPage, allocator.release(layout.storage.base));
    try std.testing.expectError(error.DoubleFree, allocator.releaseContiguous(.{ .base = page, .length = 2 * page_size }));
    try std.testing.expectEqualDeep(before, allocator.stats());
    try std.testing.expectEqualSlices(u8, &bits, &bitmap);
    try allocator.release(page);
    try std.testing.expectError(error.DoubleFree, allocator.release(page));
    try std.testing.expectEqual(@as(u64, 0), allocator.stats().allocated_pages);
}

test "contiguous physical alignment and atomic release work across sparse pools" {
    var info = testInfo(&.{
        testRegion(0x1000, 0x8000, .usable),
        testRegion(0xb000, 0x5000, .usable),
    }, &.{});
    const layout = try Layout.init(&info, 0x20000);
    var bitmap: [2]u8 = undefined;
    var allocator = try Allocator.init(layout, &bitmap);
    const run = (try allocator.allocateContiguous(3, 4)).?;
    try std.testing.expectEqualDeep(protocol.PhysicalRange{ .base = 0x4000, .length = 0x3000 }, run);
    const before = allocator.stats();
    const bits = bitmap;
    try std.testing.expectEqual(@as(?protocol.PhysicalRange, null), try allocator.allocateContiguous(6, 1));
    try std.testing.expectError(error.InvalidFree, allocator.releaseContiguous(.{ .base = 0x8000, .length = 0x4000 }));
    try std.testing.expectError(error.DoubleFree, allocator.releaseContiguous(.{ .base = run.base, .length = run.length + page_size }));
    try std.testing.expectEqualDeep(before, allocator.stats());
    try std.testing.expectEqualSlices(u8, &bits, &bitmap);
    try allocator.releaseContiguous(run);
    try std.testing.expectEqualDeep(run, (try allocator.allocateContiguous(3, 4)).?);
}

test "contiguous requests validate counts, alignment and arithmetic before mutation" {
    var info = testInfo(&.{testRegion(0x1000, 0x4000, .usable)}, &.{});
    const layout = try Layout.init(&info, 0x10000);
    var bitmap: [1]u8 = undefined;
    var allocator = try Allocator.init(layout, &bitmap);
    const before = allocator.stats();
    const bits = bitmap;
    try std.testing.expectError(error.InvalidPageCount, allocator.allocateContiguous(0, 1));
    try std.testing.expectError(error.InvalidAlignment, allocator.allocateContiguous(1, 0));
    try std.testing.expectError(error.InvalidAlignment, allocator.allocateContiguous(1, 3));
    if (@sizeOf(usize) == 8) {
        try std.testing.expectError(error.SizeOverflow, allocator.allocateContiguous(std.math.maxInt(usize), 1));
        try std.testing.expectError(error.SizeOverflow, allocator.allocateContiguous(1, @as(usize, 1) << 63));
    }
    try std.testing.expectError(error.InvalidPageCount, allocator.releaseContiguous(.{ .base = 0x2000, .length = 0 }));
    try std.testing.expectError(error.InvalidPageCount, allocator.releaseContiguous(.{ .base = 0x2000, .length = 4097 }));
    try std.testing.expectError(error.PhysicalRangeOverflow, allocator.releaseContiguous(.{ .base = 0xfffffffffffff000, .length = 0x2000 }));
    try std.testing.expectEqualDeep(before, allocator.stats());
    try std.testing.expectEqualSlices(u8, &bits, &bitmap);
}

test "allocator checks caller bitmap capacity and copied layout consistency" {
    var info = testInfo(&.{testRegion(0x1000, 0x9000, .usable)}, &.{});
    var layout = try Layout.init(&info, 0x10000);
    var bitmap: [2]u8 = @splat(0x5a);
    const before = bitmap;
    try std.testing.expectError(error.BitmapTooSmall, Allocator.init(layout, bitmap[0..1]));
    try std.testing.expectEqualSlices(u8, &before, &bitmap);
    layout.page_count -= 1;
    try std.testing.expectError(error.InvalidLayout, Allocator.init(layout, &bitmap));
    try std.testing.expectEqualSlices(u8, &before, &bitmap);
    layout = try Layout.init(&info, 0x10000);
    layout.storage.base = 0x10000;
    try std.testing.expectError(error.InvalidLayout, Allocator.init(layout, &bitmap));
    try std.testing.expectEqualSlices(u8, &before, &bitmap);
}

test "a sole usable page can hold metadata without granting a free frame" {
    var info = testInfo(&.{testRegion(0x1000, page_size, .usable)}, &.{});
    const layout = try Layout.init(&info, 0x2000);
    var bitmap: [1]u8 = undefined;
    var allocator = try Allocator.init(layout, &bitmap);
    try std.testing.expectEqual(@as(?u64, null), allocator.allocate());
    try std.testing.expectEqual(@as(?protocol.PhysicalRange, null), try allocator.allocateContiguous(1, 1));
    try std.testing.expectEqualDeep(Stats{ .free_pages = 0, .allocated_pages = 0, .metadata_pages = 1, .managed_pages = 1 }, allocator.stats());
}
