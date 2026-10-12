//! Explicit owned resource adapters for hardware ports. The MMIO range must be
//! supervisor mapped already; coherent DMA is a separate platform precondition.
const std = @import("std");
const protocol = @import("boot_protocol");
const memory = @import("memory_init");
pub const max_dma_address: u64 = 0xffffffff;
pub const Mmio = struct {
    range: protocol.PhysicalRange,
    active: bool = false,
    pub fn init(info: *const protocol.BootInfo, base: u64, length: u32) !Mmio {
        if (base == 0 or base % 4096 != 0 or length == 0 or length % 4096 != 0) return error.InvalidMmio;
        const range: protocol.PhysicalRange = .{ .base = base, .length = length };
        const aperture_end = try range.endExclusive();
        if (info.memory_region_count == 0 or info.memory_region_count > protocol.max_memory_regions)
            return error.InvalidMemoryRegionCount;
        if (info.mapped_range_count == 0 or info.mapped_range_count > protocol.max_mapped_ranges)
            return error.InvalidMappedRangeCount;
        if (info.loader_reserved.length == 0 or info.kernel_reserved.length == 0)
            return error.InvalidReservedRange;
        if ((info.framebuffer.base == 0) != (info.framebuffer.size == 0))
            return error.InvalidFramebufferRange;
        // Addressability does not make RAM a device register aperture. Protect
        // the actual reservations/map, rather than the legacy RAM envelope,
        // whose gaps may contain valid device MMIO.
        for ([_]protocol.PhysicalRange{
            info.loader_reserved,
            info.kernel_reserved,
            .{ .base = info.framebuffer.base, .length = info.framebuffer.size },
        }) |protected| {
            const protected_end = try protected.endExclusive();
            if (protected.length != 0 and range.base < protected_end and protected.base < aperture_end)
                return error.ProtectedMemoryAlias;
        }
        var prior_end: u64 = 0;
        for (info.memory_regions[0..info.memory_region_count], 0..) |region, i| {
            const region_end = try region.range.endExclusive();
            if (region.range.length == 0 or (i != 0 and region.range.base < prior_end))
                return error.InvalidMemoryMap;
            if (region.isUsable() and range.base < region_end and region.range.base < aperture_end)
                return error.ProtectedMemoryAlias;
            prior_end = region_end;
        }
        prior_end = 0;
        for (info.mapped_ranges[0..info.mapped_range_count], 0..) |mapped, i| {
            const mapped_end = try mapped.endExclusive();
            if (mapped.length == 0 or (i != 0 and mapped.base < prior_end))
                return error.InvalidMappedRanges;
            prior_end = mapped_end;
        }
        if (!info.isMapped(range)) return error.UnmappedRegisters;
        return .{ .range = range };
    }
    pub fn begin(context: *anyopaque) !void {
        const self: *Mmio = @ptrCast(@alignCast(context));
        if (self.active) return error.ReentrantRegisterTransaction;
        self.active = true;
    }
    pub fn end(context: *anyopaque) void {
        const self: *Mmio = @ptrCast(@alignCast(context));
        std.debug.assert(self.active);
        self.active = false;
    }
    fn address(self: *Mmio, offset: u32) !u64 {
        if (!self.active or offset % 4 != 0 or offset > self.range.length or self.range.length - offset < 4) return error.InvalidRegisterAccess;
        return self.range.base + offset;
    }
    pub fn read(context: *anyopaque, offset: u32) !u32 {
        const self: *Mmio = @ptrCast(@alignCast(context));
        const pointer: *const volatile u32 = @ptrFromInt(try self.address(offset));
        return pointer.*;
    }
    pub fn write(context: *anyopaque, offset: u32, value: u32) !void {
        const self: *Mmio = @ptrCast(@alignCast(context));
        const pointer: *volatile u32 = @ptrFromInt(try self.address(offset));
        pointer.* = value;
    }
    pub fn fence(_: *anyopaque) void {
        switch (@import("builtin").cpu.arch) {
            .x86_64 => asm volatile ("mfence" ::: .{ .memory = true }),
            .aarch64 => asm volatile ("dsb sy" ::: .{ .memory = true }),
            .riscv64 => asm volatile ("fence iorw, iorw" ::: .{ .memory = true }),
            else => unreachable,
        }
    }
};
/// Retained DMA lease. Failed quiescence must retain the lease; exposing a
/// physical address does not transfer allocator ownership to device firmware.
pub const Dma32 = DmaLease(memory);
/// Same ownership logic for live kernel memory and deterministic native fake
/// providers. Memory supplies heap_api.Ticket and allocate/resolve/freeKernel.
pub fn DmaLease(comptime Memory: type) type {
    return struct {
        const Self = @This();
        ticket: ?Memory.heap_api.Ticket = null,
        range: protocol.PhysicalRange = .{ .base = 0, .length = 0 },
        owner_address: usize = 0,
        exposed: bool = false,
        released: bool = false,
        /// Initialize in place. Moving/copying this owner does not duplicate its
        /// lease or its exposure state; all later operations reject such a copy.
        pub fn init(self: *Self, bytes: usize, alignment: usize) !void {
            if (self.owner_address != 0) return error.DmaLeaseAlreadyInitialized;
            const ticket = try Memory.allocateKernel(bytes, alignment);
            errdefer Memory.freeKernel(ticket) catch @panic("wireless unexposed allocation rollback");
            const block = try Memory.resolveKernel(ticket);
            try checkDma32(block.range.base, block.range.length);
            self.* = .{ .ticket = ticket, .range = block.range, .owner_address = @intFromPtr(self) };
        }
        fn validateOwner(self: *Self) !void {
            if (self.owner_address == 0 or self.owner_address != @intFromPtr(self)) return error.MovedDmaLease;
            if (self.released) return error.ReleasedDmaLease;
            const block = try Memory.resolveKernel(self.ticket orelse return error.InvalidDmaLease);
            if (block.range.base != self.range.base or block.range.length != self.range.length) return error.InvalidDmaLease;
            try checkDma32(block.range.base, block.range.length);
        }
        pub fn publish(self: *Self) !u32 {
            try self.validateOwner();
            self.exposed = true;
            return @intCast(self.range.base);
        }
        /// Only the owning driver can establish actual DMA stop/reset completion.
        /// This method cannot prove a caller's device-specific quiescence claim.
        pub fn releaseAfterQuiescence(self: *Self) !void {
            try self.validateOwner();
            try Memory.freeKernel(self.ticket.?);
            self.released = true;
        }
        pub fn releaseUnexposed(self: *Self) !void {
            try self.validateOwner();
            if (self.exposed) return error.DmaStillExposed;
            try self.releaseAfterQuiescence();
        }
    };
}
pub fn checkDma32(base: u64, length: u64) !void {
    if (base == 0 or base % 16 != 0 or length == 0 or length > 0x1_0000_0000 or base > max_dma_address or length - 1 > max_dma_address - base) return error.UnsupportedDmaRange;
}
test "wireless DMA validates the complete 32-bit range before descriptor exposure" {
    try checkDma32(0xfffffff0, 16);
    try std.testing.expectError(error.UnsupportedDmaRange, checkDma32(0xfffffff0, 17));
    try std.testing.expectError(error.UnsupportedDmaRange, checkDma32(0x1_0000_0000, 16));
    try std.testing.expectError(error.UnsupportedDmaRange, checkDma32(0, 16));
    try std.testing.expectError(error.UnsupportedDmaRange, checkDma32(0x1001, 16));
    try std.testing.expectError(error.UnsupportedDmaRange, checkDma32(0x1000, 0));
}

// Deliberately supplies real generation/live-state checks rather than always
// accepting a ticket. No fake method dereferences its physical range.
const FakeMemory = struct {
    pub const heap_api = struct {
        pub const Ticket = struct { generation: u64 };
    };
    const State = struct {
        range: protocol.PhysicalRange = .{ .base = 0x1000, .length = 0x1000 },
        generation: u64 = 1,
        live: bool = false,
        allocations: usize = 0,
        resolutions: usize = 0,
        frees: usize = 0,
        fail_free: bool = false,
    };
    var state: State = .{};
    fn reset() void {
        state = .{};
    }
    pub fn allocateKernel(_: usize, _: usize) !heap_api.Ticket {
        if (state.live) return error.AllocationCapacity;
        state.live = true;
        state.allocations += 1;
        return .{ .generation = state.generation };
    }
    pub fn resolveKernel(ticket: heap_api.Ticket) !struct { range: protocol.PhysicalRange } {
        state.resolutions += 1;
        if (!state.live or ticket.generation != state.generation) return error.StaleAllocation;
        return .{ .range = state.range };
    }
    pub fn freeKernel(ticket: heap_api.Ticket) !void {
        state.frees += 1;
        if (!state.live or ticket.generation != state.generation) return error.StaleAllocation;
        if (state.fail_free) return error.FreeFailed;
        state.live = false;
        state.generation += 1;
    }
};
const FakeLease = DmaLease(FakeMemory);
test "DMA allocation beyond 32 bits rolls back before publishing an owner" {
    FakeMemory.reset();
    FakeMemory.state.range = .{ .base = 0xfffff000, .length = 0x2000 };
    var lease: FakeLease = .{};
    try std.testing.expectError(error.UnsupportedDmaRange, lease.init(0x2000, 4096));
    try std.testing.expectEqual(@as(usize, 1), FakeMemory.state.allocations);
    try std.testing.expectEqual(@as(usize, 1), FakeMemory.state.frees);
    try std.testing.expect(!FakeMemory.state.live and lease.ticket == null);
    try std.testing.expect(!lease.exposed and !lease.released and lease.owner_address == 0);
    FakeMemory.state.range = .{ .base = 0x1000, .length = 0x1000 };
    try lease.init(4096, 4096); // Rollback did not poison in-place initialization.
    try std.testing.expectEqual(@as(u32, 0x1000), try lease.publish());
    try lease.releaseAfterQuiescence();
}
test "DMA moved owner rejects operations before provider access or exposure" {
    FakeMemory.reset();
    var owner: FakeLease = .{};
    try owner.init(4096, 4096);
    var moved = owner;
    const resolutions = FakeMemory.state.resolutions;
    try std.testing.expectError(error.MovedDmaLease, moved.publish());
    try std.testing.expectError(error.MovedDmaLease, moved.releaseUnexposed());
    try std.testing.expectError(error.MovedDmaLease, moved.releaseAfterQuiescence());
    try std.testing.expectEqual(resolutions, FakeMemory.state.resolutions);
    try std.testing.expectEqual(@as(usize, 0), FakeMemory.state.frees);
    try std.testing.expect(FakeMemory.state.live and !owner.exposed and !owner.released);
    try owner.releaseUnexposed();
}
test "DMA external free and same-address generation reuse cannot publish stale ticket" {
    FakeMemory.reset();
    var owner: FakeLease = .{};
    try owner.init(4096, 4096);
    const stale = owner.ticket.?;
    try FakeMemory.freeKernel(stale);
    const replacement = try FakeMemory.allocateKernel(4096, 4096);
    try std.testing.expect(replacement.generation != stale.generation);
    try std.testing.expectError(error.StaleAllocation, owner.publish());
    try std.testing.expectError(error.StaleAllocation, owner.releaseAfterQuiescence());
    try std.testing.expect(!owner.exposed and !owner.released);
    _ = try FakeMemory.resolveKernel(replacement); // Old release did not free it.
    try FakeMemory.freeKernel(replacement);
}
test "DMA copied unexposed state cannot release the live exposed owner" {
    FakeMemory.reset();
    var owner: FakeLease = .{};
    try owner.init(4096, 4096);
    var old_copy = owner;
    _ = try owner.publish();
    try std.testing.expectError(error.DmaStillExposed, owner.releaseUnexposed());
    try std.testing.expectError(error.MovedDmaLease, old_copy.releaseUnexposed());
    try std.testing.expectError(error.MovedDmaLease, old_copy.releaseAfterQuiescence());
    try std.testing.expect(FakeMemory.state.live and owner.exposed and !owner.released);
    try owner.releaseAfterQuiescence();
    try std.testing.expectError(error.ReleasedDmaLease, owner.publish());
    try std.testing.expectError(error.ReleasedDmaLease, owner.releaseAfterQuiescence());
}
test "DMA failed free preserves a retriable live owner and exposure state" {
    FakeMemory.reset();
    var owner: FakeLease = .{};
    try owner.init(4096, 4096);
    _ = try owner.publish();
    FakeMemory.state.fail_free = true;
    try std.testing.expectError(error.FreeFailed, owner.releaseAfterQuiescence());
    try std.testing.expect(owner.exposed and !owner.released and FakeMemory.state.live);
    try std.testing.expectEqual(@as(u32, 0x1000), try owner.publish());
    FakeMemory.state.fail_free = false;
    try owner.releaseAfterQuiescence();
    try std.testing.expect(!FakeMemory.state.live and owner.released);
    try std.testing.expectEqual(@as(usize, 2), FakeMemory.state.frees);
}
test "DMA live ticket cannot substitute a changed provider range" {
    FakeMemory.reset();
    var owner: FakeLease = .{};
    try owner.init(4096, 4096);
    FakeMemory.state.range.base = 0x2000;
    try std.testing.expectError(error.InvalidDmaLease, owner.publish());
    try std.testing.expect(!owner.exposed);
    FakeMemory.state.range.base = 0x1000;
    try owner.releaseUnexposed();
    try std.testing.expectError(error.DmaLeaseAlreadyInitialized, owner.init(4096, 4096));
}

fn mmioFixture() protocol.BootInfo {
    var info: protocol.BootInfo = undefined;
    info.loader_reserved = .{ .base = 0x100000, .length = 0x10000 };
    info.kernel_reserved = .{ .base = 0x200000, .length = 0x10000 };
    info.framebuffer = .{ .base = 0x300000, .size = 0x10000 };
    info.memory_region_count = 1;
    info.memory_regions[0] = .{ .range = .{ .base = 0x400000, .length = 0x200000 }, .kind = @backingInt(protocol.MemoryKind.usable), .attributes = 0 };
    info.mapped_range_count = 1;
    info.mapped_ranges[0] = .{ .base = 0x100000, .length = 0x700000 };
    // Informational RAM envelope includes a mapped hole; usable map is source.
    info.ram = .{ .base = 0x100000, .length = 0x700000 };
    return info;
}
test "MMIO rejects protected aliases while allowing an actual mapped RAM-envelope hole" {
    var info = mmioFixture();
    for ([_]u64{ 0x100000, 0x200000, 0x300000, 0x400000, 0x5ff000 }) |base|
        try std.testing.expectError(error.ProtectedMemoryAlias, Mmio.init(&info, base, 4096));
    try std.testing.expectError(error.ProtectedMemoryAlias, Mmio.init(&info, 0x1ff000, 8192));
    var device = try Mmio.init(&info, 0x600000, 4096);
    try std.testing.expectEqual(@as(u64, 0x600000), device.range.base);
    try Mmio.begin(&device);
    try std.testing.expectEqual(@as(u64, 0x600ffc), try device.address(4092));
    try std.testing.expectError(error.InvalidRegisterAccess, device.address(4096));
    try std.testing.expectError(error.InvalidRegisterAccess, device.address(1));
    try std.testing.expectError(error.ReentrantRegisterTransaction, Mmio.begin(&device));
    Mmio.end(&device);
    try std.testing.expectError(error.InvalidRegisterAccess, device.address(0));
}
test "MMIO validates bounded map counts shape and full mapped coverage before access" {
    var info = mmioFixture();
    info.memory_region_count = protocol.max_memory_regions + 1;
    try std.testing.expectError(error.InvalidMemoryRegionCount, Mmio.init(&info, 0x600000, 4096));
    info = mmioFixture();
    info.mapped_range_count = protocol.max_mapped_ranges + 1;
    try std.testing.expectError(error.InvalidMappedRangeCount, Mmio.init(&info, 0x600000, 4096));
    info = mmioFixture();
    info.memory_region_count = 0;
    try std.testing.expectError(error.InvalidMemoryRegionCount, Mmio.init(&info, 0x600000, 4096));
    info = mmioFixture();
    info.mapped_ranges[0].length = 0x500800;
    try std.testing.expectError(error.UnmappedRegisters, Mmio.init(&info, 0x600000, 4096));
    info = mmioFixture();
    info.mapped_range_count = 2;
    info.mapped_ranges[1] = info.mapped_ranges[0];
    try std.testing.expectError(error.InvalidMappedRanges, Mmio.init(&info, 0x600000, 4096));
    info = mmioFixture();
    info.memory_regions[0].range.length = 0;
    try std.testing.expectError(error.InvalidMemoryMap, Mmio.init(&info, 0x600000, 4096));
    info = mmioFixture();
    info.kernel_reserved = .{ .base = 0xfffffffffffff000, .length = 8192 };
    try std.testing.expectError(error.PhysicalRangeOverflow, Mmio.init(&info, 0x600000, 4096));
    info = mmioFixture();
    try std.testing.expectError(error.InvalidMmio, Mmio.init(&info, 0x600001, 4096));
    try std.testing.expectError(error.InvalidMmio, Mmio.init(&info, 0x600000, 0));
}
