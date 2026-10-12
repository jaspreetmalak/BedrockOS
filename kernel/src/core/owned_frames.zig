//! Serialized, kernel-owned frame leases. A live ledger must never be copied.
//! Identity issuance and physical allocation share a retained kernel lifetime.
//! This module tracks ownership; it neither maps nor dereferences physical RAM.
const std = @import("std");
const physical = @import("physical_memory.zig");
const protocol = @import("boot_protocol");

pub const OwnerId = enum(u64) { _ };
pub const Ticket = struct { owner: OwnerId, handle: u64 };
pub const Error = physical.Error || error{ InvalidOwner, OwnerIdentityExhausted, AllocationCapacity, OutOfMemory, ForeignAllocation, InvalidAllocation, StaleAllocation };

pub const IdIssuer = struct {
    next: u64 = 1,

    pub fn issue(self: *IdIssuer) Error!OwnerId {
        if (self.next == 0) return error.OwnerIdentityExhausted;
        const value = self.next;
        self.next = if (value == std.math.maxInt(u64)) 0 else value + 1;
        return @fromBackingInt(value);
    }
};

pub fn Owner(comptime capacity: usize) type {
    if (capacity == 0 or capacity > std.math.maxInt(u32)) @compileError("invalid ownership capacity");
    return struct {
        const Self = @This();
        const Slot = struct { range: ?protocol.PhysicalRange = null, generation: u32 = 1, retired: bool = false };
        pages: *physical.Allocator,
        id: OwnerId,
        slots: [capacity]Slot = @splat(Slot{}),

        pub fn init(pages: *physical.Allocator, id: OwnerId) Error!Self {
            if (@backingInt(id) == 0) return error.InvalidOwner;
            return .{ .pages = pages, .id = id };
        }

        /// Physical allocation failure does not consume a slot or ticket.
        pub fn allocate(self: *Self, count: usize, alignment_pages: usize) Error!Ticket {
            for (&self.slots, 0..) |*slot, slot_index| {
                if (slot.range != null or slot.retired) continue;
                const range = (try self.pages.allocateContiguous(count, alignment_pages)) orelse return error.OutOfMemory;
                slot.range = range;
                return self.ticket(slot_index);
            }
            return error.AllocationCapacity;
        }

        pub fn resolve(self: *const Self, value: Ticket) Error!protocol.PhysicalRange {
            return self.slots[try self.index(value)].range.?;
        }

        pub fn index(self: *const Self, value: Ticket) Error!usize {
            if (value.owner != self.id) return error.ForeignAllocation;
            const one_based: u32 = @truncate(value.handle);
            const generation: u32 = @intCast(value.handle >> 32);
            if (one_based == 0 or one_based > capacity or generation == 0) return error.InvalidAllocation;
            const slot = &self.slots[one_based - 1];
            if (slot.range == null or generation != slot.generation) return error.StaleAllocation;
            return one_based - 1;
        }

        /// Call only after all mappings/contexts referencing this range end.
        pub fn release(self: *Self, value: Ticket) Error!void {
            const slot = &self.slots[try self.index(value)];
            try self.pages.releaseContiguous(slot.range.?);
            slot.range = null;
            if (slot.generation == std.math.maxInt(u32)) {
                slot.retired = true;
            } else slot.generation += 1;
        }

        /// Rollback/teardown for this ledger only. A backend invariant error
        /// leaves the failing range owned; successful earlier releases remain.
        pub fn releaseAll(self: *Self) Error!void {
            for (self.slots, 0..) |slot, index_value| {
                if (slot.range != null) try self.release(self.ticket(index_value));
            }
        }

        fn ticket(self: *const Self, index_value: usize) Ticket {
            return .{ .owner = self.id, .handle = (@as(u64, self.slots[index_value].generation) << 32) | (index_value + 1) };
        }
    };
}

fn testLayout(count: u64) !physical.Layout {
    var info: protocol.BootInfo = undefined;
    info.memory_region_count = 1;
    info.mapped_range_count = 0;
    info.memory_regions[0] = .{ .range = .{ .base = 0x1000, .length = count * physical.page_size }, .kind = @backingInt(protocol.MemoryKind.usable), .attributes = 0 };
    return physical.Layout.init(&info, 0x100000);
}

test "leases reject foreign and stale tokens even when the frame is reused" {
    var bitmap: [2]u8 = undefined;
    var pages = try physical.Allocator.init(try testLayout(16), &bitmap);
    var issuer: IdIssuer = .{};
    var first = try Owner(2).init(&pages, try issuer.issue());
    var second = try Owner(2).init(&pages, try issuer.issue());
    const baseline = pages.stats();
    const old = try first.allocate(1, 1);
    const address = (try first.resolve(old)).base;
    try std.testing.expectError(error.ForeignAllocation, second.release(old));
    try std.testing.expectError(error.InvalidAllocation, first.resolve(.{ .owner = first.id, .handle = 0 }));
    try first.release(old);
    const replacement = try second.allocate(1, 1);
    try std.testing.expectEqual(address, (try second.resolve(replacement)).base);
    const before = pages.stats();
    try std.testing.expectError(error.StaleAllocation, first.release(old));
    try std.testing.expectEqualDeep(before, pages.stats());
    try second.releaseAll();
    try std.testing.expectEqualDeep(baseline, pages.stats());
    const fresh = try first.allocate(1, 1);
    try std.testing.expect(fresh.handle != old.handle);
    try std.testing.expectError(error.StaleAllocation, first.resolve(old));
    try first.release(fresh);
}

test "partial ownership transactions rollback and failed allocations are atomic" {
    var bitmap: [1]u8 = undefined;
    var pages = try physical.Allocator.init(try testLayout(4), &bitmap);
    var issuer: IdIssuer = .{};
    var owner = try Owner(3).init(&pages, try issuer.issue());
    const baseline = pages.stats();
    _ = try owner.allocate(1, 1);
    const before = pages.stats();
    try std.testing.expectError(error.InvalidAlignment, owner.allocate(1, 3));
    try std.testing.expectError(error.InvalidPageCount, owner.allocate(0, 1));
    try std.testing.expectError(error.OutOfMemory, owner.allocate(3, 1));
    try std.testing.expectEqualDeep(before, pages.stats());
    _ = try owner.allocate(1, 1);
    _ = try owner.allocate(1, 1);
    try std.testing.expectError(error.AllocationCapacity, owner.allocate(1, 1));
    try owner.releaseAll();
    try std.testing.expectEqualDeep(baseline, pages.stats());
    try owner.releaseAll();
}

test "identity and ticket generations exhaust without reviving old allocations" {
    var issuer: IdIssuer = .{ .next = std.math.maxInt(u64) };
    _ = try issuer.issue();
    try std.testing.expectError(error.OwnerIdentityExhausted, issuer.issue());
    var bitmap: [1]u8 = undefined;
    var pages = try physical.Allocator.init(try testLayout(4), &bitmap);
    try std.testing.expectError(error.InvalidOwner, Owner(1).init(&pages, @fromBackingInt(0)));
    var owner = try Owner(1).init(&pages, @fromBackingInt(1));
    owner.slots[0].generation = std.math.maxInt(u32);
    const last = try owner.allocate(1, 1);
    try owner.release(last);
    try std.testing.expectError(error.StaleAllocation, owner.resolve(last));
    try std.testing.expectError(error.AllocationCapacity, owner.allocate(1, 1));
    try std.testing.expectEqual(@as(u64, 0), pages.stats().allocated_pages);
}
