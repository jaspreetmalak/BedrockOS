//! A bounded allocator over the process-owned, zeroed heap lease.
//! Keep Heap at a stable address while any allocator or allocation is live.
const std = @import("std");

pub const max_allocations = 64;

pub const Heap = struct {
    const Allocation = struct { offset: usize = 0, length: usize = 0, alignment: std.mem.Alignment = .@"1", live: bool = false };
    bytes: []u8,
    pinned_address: usize = 0,
    allocations: [max_allocations]Allocation = @splat(.{}),

    pub fn init(bytes: []u8) Heap {
        return .{ .bytes = bytes };
    }

    pub fn allocator(self: *Heap) std.mem.Allocator {
        self.validateOwner() catch @panic("process heap moved while allocator was live");
        self.pinned_address = @intFromPtr(self);
        return .{ .ptr = self, .vtable = &.{ .alloc = allocate, .resize = resize, .remap = remap, .free = free } };
    }

    pub fn validateOwner(self: *const Heap) error{MovedHeap}!void {
        if (self.pinned_address != 0 and self.pinned_address != @intFromPtr(self)) return error.MovedHeap;
    }

    pub fn liveCount(self: *const Heap) usize {
        self.validateOwner() catch @panic("process heap moved while allocator was live");
        var result: usize = 0;
        for (self.allocations) |item| if (item.live) {
            result += 1;
        };
        return result;
    }

    pub fn usedBytes(self: *const Heap) usize {
        self.validateOwner() catch @panic("process heap moved while allocator was live");
        var result: usize = 0;
        for (self.allocations) |item| if (item.live) {
            result += item.length;
        };
        return result;
    }

    fn cast(context: *anyopaque) *Heap {
        const self: *Heap = @ptrCast(@alignCast(context));
        self.validateOwner() catch @panic("process heap moved while allocator was live");
        return self;
    }

    fn allocate(context: *anyopaque, length: usize, alignment: std.mem.Alignment, _: usize) ?[*]u8 {
        const self = cast(context);
        const slot = for (&self.allocations) |*item| {
            if (!item.live) break item;
        } else return null;
        var offset: usize = 0;
        while (true) {
            const address = std.math.add(usize, @intFromPtr(self.bytes.ptr), offset) catch return null;
            const aligned = std.math.add(usize, address, alignment.toByteUnits() - 1) catch return null;
            const start = (aligned & ~(alignment.toByteUnits() - 1)) - @intFromPtr(self.bytes.ptr);
            const end = std.math.add(usize, start, length) catch return null;
            if (end > self.bytes.len) return null;
            var next: ?usize = null;
            for (self.allocations) |item| {
                if (item.live and start < item.offset + item.length and item.offset < end)
                    next = @max(next orelse 0, item.offset + item.length);
            }
            if (next) |after| {
                offset = after;
                continue;
            }
            slot.* = .{ .offset = start, .length = length, .alignment = alignment, .live = true };
            return self.bytes.ptr + start;
        }
    }

    fn find(self: *Heap, bytes: []u8, alignment: std.mem.Alignment) ?*Allocation {
        for (&self.allocations) |*item| {
            if (item.live and @intFromPtr(bytes.ptr) == @intFromPtr(self.bytes.ptr) + item.offset and
                bytes.len == item.length and alignment == item.alignment) return item;
        }
        return null;
    }

    fn resize(context: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, new_length: usize, _: usize) bool {
        const self = cast(context);
        const item = self.find(bytes, alignment) orelse @panic("invalid process heap allocation");
        const end = std.math.add(usize, item.offset, new_length) catch return false;
        if (end > self.bytes.len) return false;
        for (&self.allocations) |*other| {
            if (other != item and other.live and item.offset < other.offset + other.length and other.offset < end) return false;
        }
        item.length = new_length;
        return true;
    }

    fn remap(context: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, new_length: usize, return_address: usize) ?[*]u8 {
        return if (resize(context, bytes, alignment, new_length, return_address)) bytes.ptr else null;
    }

    fn free(context: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, _: usize) void {
        const self = cast(context);
        const item = self.find(bytes, alignment) orelse @panic("invalid process heap allocation");
        item.* = .{};
    }
};

test "heap reuses non-last frees without aliasing surviving allocations" {
    var backing: [256]u8 align(64) = @splat(0);
    var heap = Heap.init(&backing);
    const allocator = heap.allocator();
    const first = try allocator.alloc(u8, 32);
    const second = try allocator.alloc(u8, 32);
    @memset(second, 0xab);
    allocator.free(first);
    const replacement = try allocator.alloc(u8, 32);
    try std.testing.expectEqual(@intFromPtr(first.ptr), @intFromPtr(replacement.ptr));
    try std.testing.expectEqualSlices(u8, &(@as([32]u8, @splat(0xab))), second);
    try std.testing.expectEqual(@as(usize, 2), heap.liveCount());
    allocator.free(second);
    allocator.free(replacement);
    try std.testing.expectEqual(@as(usize, 0), heap.usedBytes());
}

test "heap preserves alignment even when the lease begins unaligned" {
    var backing: [256]u8 align(64) = @splat(0);
    var heap = Heap.init(backing[1..]);
    const allocator = heap.allocator();
    const bytes = try allocator.alignedAlloc(u8, .@"64", 65);
    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(bytes.ptr) % 64);
    allocator.free(bytes);
    try std.testing.expectEqual(@as(usize, 0), heap.liveCount());
}

test "heap exhaustion and failed growth preserve existing allocations" {
    var backing: [96]u8 = @splat(0);
    var heap = Heap.init(&backing);
    const allocator = heap.allocator();
    const first = try allocator.alloc(u8, 32);
    const second = try allocator.alloc(u8, 64);
    @memset(first, 0x55);
    try std.testing.expectError(error.OutOfMemory, allocator.alloc(u8, 1));
    try std.testing.expect(!allocator.resize(first, 33));
    try std.testing.expectEqual(@as(usize, 96), heap.usedBytes());
    try std.testing.expectEqualSlices(u8, &(@as([32]u8, @splat(0x55))), first);
    allocator.free(second);
    try std.testing.expect(allocator.resize(first, 64));
    const enlarged = first.ptr[0..64];
    try std.testing.expect(allocator.resize(enlarged, 16));
    allocator.free(enlarged.ptr[0..16]);
    try std.testing.expectEqual(@as(usize, 0), heap.liveCount());
}

test "heap metadata limit fails transactionally and released slots are reused" {
    var backing: [128]u8 = @splat(0);
    var heap = Heap.init(&backing);
    const allocator = heap.allocator();
    var allocations: [max_allocations][]u8 = undefined;
    for (&allocations) |*bytes| bytes.* = try allocator.alloc(u8, 1);
    try std.testing.expectError(error.OutOfMemory, allocator.alloc(u8, 1));
    allocator.free(allocations[9]);
    allocations[9] = try allocator.alloc(u8, 2);
    try std.testing.expectEqual(@as(usize, max_allocations), heap.liveCount());
    for (allocations) |bytes| allocator.free(bytes);
    try std.testing.expectEqual(@as(usize, 0), heap.liveCount());
}

test "heap rejects arithmetic overflow and oversized aligned requests" {
    var backing: [64]u8 align(64) = @splat(0);
    var heap = Heap.init(&backing);
    try std.testing.expect(heap.allocator().rawAlloc(std.math.maxInt(usize), .@"1", 0) == null);
    try std.testing.expect(heap.allocator().rawAlloc(65, .@"64", 0) == null);
    try std.testing.expectEqual(@as(usize, 0), heap.liveCount());
}

test "heap may move before pinning and detects copies after allocator publication" {
    var backing: [64]u8 = @splat(0);
    const initial = Heap.init(&backing);
    var heap = initial;
    try heap.validateOwner();
    const allocator = heap.allocator();
    const bytes = try allocator.alloc(u8, 16);
    const moved = heap;
    try std.testing.expectError(error.MovedHeap, moved.validateOwner());
    try heap.validateOwner();
    allocator.free(bytes);
    try std.testing.expectEqual(@as(usize, 0), heap.liveCount());
}
