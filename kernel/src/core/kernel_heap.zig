//! First kernel heap: checked, page-granular contiguous allocations.
//! Physical access/zeroing belongs to memory_init, not this portable policy.
//! No small-object allocator, virtual heap growth or synchronization yet.
const std = @import("std");
const physical = @import("physical_memory.zig");
const owned = @import("owned_frames.zig");
const protocol = @import("boot_protocol");
pub const Ticket = owned.Ticket;
pub const Block = struct { range: protocol.PhysicalRange, requested_length: usize };
pub const Error = owned.Error || error{InvalidAllocationSize};

pub fn Heap(comptime capacity: usize) type {
    return struct {
        const Self = @This();
        owner: owned.Owner(capacity),
        lengths: [capacity]usize = @splat(0),

        pub fn init(pages: *physical.Allocator, id: owned.OwnerId) Error!Self {
            return .{ .owner = try owned.Owner(capacity).init(pages, id) };
        }

        pub fn allocate(self: *Self, bytes: usize, alignment: usize) Error!Ticket {
            if (bytes == 0) return error.InvalidAllocationSize;
            if (alignment == 0 or alignment & (alignment - 1) != 0) return error.InvalidAlignment;
            const rounded = @addWithOverflow(bytes, physical.page_size - 1);
            if (rounded[1] != 0) return error.SizeOverflow;
            const count = rounded[0] / physical.page_size;
            const alignment_pages = if (alignment <= physical.page_size) 1 else alignment / physical.page_size;
            const ticket = try self.owner.allocate(count, alignment_pages);
            self.lengths[try self.owner.index(ticket)] = bytes;
            return ticket;
        }

        pub fn resolve(self: *const Self, ticket: Ticket) Error!Block {
            const slot = try self.owner.index(ticket);
            return .{ .range = try self.owner.resolve(ticket), .requested_length = self.lengths[slot] };
        }

        pub fn release(self: *Self, ticket: Ticket) Error!void {
            const slot = try self.owner.index(ticket);
            try self.owner.release(ticket);
            self.lengths[slot] = 0;
        }

        pub fn releaseAll(self: *Self) Error!void {
            try self.owner.releaseAll();
            self.lengths = @splat(0);
        }
    };
}

test "heap rounds sizes, honors physical alignment and releases exact owned runs" {
    var info: protocol.BootInfo = undefined;
    info.memory_region_count = 1;
    info.mapped_range_count = 0;
    info.memory_regions[0] = .{ .range = .{ .base = 0x1000, .length = 0x10000 }, .kind = @backingInt(protocol.MemoryKind.usable), .attributes = 0 };
    var bitmap: [2]u8 = undefined;
    var pages = try physical.Allocator.init(try physical.Layout.init(&info, 0x20000), &bitmap);
    var issuer: owned.IdIssuer = .{};
    var heap = try Heap(2).init(&pages, try issuer.issue());
    const baseline = pages.stats();
    const small = try heap.allocate(17, 8);
    const large = try heap.allocate(4097, 8192);
    const block = try heap.resolve(large);
    try std.testing.expectEqual(@as(u64, 8192), block.range.length);
    try std.testing.expectEqual(@as(u64, 0), block.range.base % 8192);
    try std.testing.expectEqual(@as(usize, 4097), block.requested_length);
    try std.testing.expectEqual(@as(u64, 4096), (try heap.resolve(small)).range.length);
    try std.testing.expectError(error.AllocationCapacity, heap.allocate(1, 1));
    try heap.release(small);
    const reused = try heap.allocate(32, 32);
    try std.testing.expectError(error.StaleAllocation, heap.release(small));
    try std.testing.expectEqual(@as(usize, 32), (try heap.resolve(reused)).requested_length);
    try heap.releaseAll();
    try std.testing.expectEqualDeep(baseline, pages.stats());
    try std.testing.expectError(error.StaleAllocation, heap.resolve(large));
}

test "invalid and impossible heap requests leave physical accounting unchanged" {
    var info: protocol.BootInfo = undefined;
    info.memory_region_count = 1;
    info.mapped_range_count = 0;
    info.memory_regions[0] = .{ .range = .{ .base = 0x1000, .length = 0x4000 }, .kind = @backingInt(protocol.MemoryKind.usable), .attributes = 0 };
    var bitmap: [1]u8 = undefined;
    var pages = try physical.Allocator.init(try physical.Layout.init(&info, 0x10000), &bitmap);
    var heap = try Heap(2).init(&pages, @fromBackingInt(1));
    const baseline = pages.stats();
    try std.testing.expectError(error.InvalidAllocationSize, heap.allocate(0, 1));
    try std.testing.expectError(error.InvalidAlignment, heap.allocate(1, 3));
    try std.testing.expectError(error.InvalidAlignment, heap.allocate(1, 0));
    try std.testing.expectError(error.SizeOverflow, heap.allocate(std.math.maxInt(usize), 1));
    try std.testing.expectError(error.OutOfMemory, heap.allocate(16384, 1));
    try std.testing.expectEqualDeep(baseline, pages.stats());
    _ = try heap.allocate(3 * 4096, 1);
    try heap.releaseAll();
    try std.testing.expectEqualDeep(baseline, pages.stats());
}
