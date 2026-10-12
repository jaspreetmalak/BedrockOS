//! Shared kernel memory bring-up. Architecture code owns physical accesses;
//! the allocator owns frame bookkeeping and never depends on a CPU or board.
const protocol = @import("boot_protocol");
const physical = @import("physical_memory.zig");
const access = @import("physical_access");
const report = @import("boot_report.zig");
pub const ownership = @import("owned_frames.zig");
pub const heap_api = @import("kernel_heap.zig");

var frames: ?physical.Allocator = null;
var identities: ownership.IdIssuer = .{};
var heap: ?heap_api.Heap(64) = null;

pub fn newOwnerId() !ownership.OwnerId {
    if (frames == null) return error.MemoryNotInitialized;
    return identities.issue();
}

pub fn clearRange(range: protocol.PhysicalRange) void {
    var offset: u64 = 0;
    while (offset < range.length) : (offset += physical.page_size) access.fillFrame(range.base + offset, 0);
}

/// Page-backed kernel allocation. The returned lease, not a caller-supplied
/// pointer/size pair, identifies the exact allocation to resolve or release.
pub fn allocateKernel(bytes: usize, alignment: usize) !heap_api.Ticket {
    const value = if (heap) |*ready| ready else return error.MemoryNotInitialized;
    const ticket = try value.allocate(bytes, alignment);
    clearRange((try value.resolve(ticket)).range);
    return ticket;
}

pub fn resolveKernel(ticket: heap_api.Ticket) !heap_api.Block {
    const value = if (heap) |*ready| ready else return error.MemoryNotInitialized;
    return value.resolve(ticket);
}

pub fn freeKernel(ticket: heap_api.Ticket) !void {
    const value = if (heap) |*ready| ready else return error.MemoryNotInitialized;
    try value.release(ticket);
}

/// One kernel-owned instance, retained after the startup checks. Callers must
/// serialize access until interrupt/SMP synchronization is implemented.
pub fn allocator() ?*physical.Allocator {
    if (frames) |*value| return value;
    return null;
}

/// Return an owned identity-accessible frame with all previous data cleared.
/// This is physical memory, not a general heap or a virtual mapping operation.
pub fn allocateZeroed() !u64 {
    const pages = allocator() orelse return error.MemoryNotInitialized;
    const address = pages.allocate() orelse return error.OutOfMemory;
    access.fillFrame(address, 0);
    return address;
}

pub fn initialize(comptime console: type, info: *const protocol.BootInfo) !void {
    if (frames != null) return error.MemoryAlreadyInitialized;
    try report.print(console, info);
    const limit = try access.bootstrapLimit(info);
    const layout = try physical.Layout.init(info, limit);
    frames = try physical.Allocator.init(layout, access.metadata(layout.storage));
    access.publish();
    const stats = frames.?.stats();
    console.write("[kernel] allocator ready pages=");
    console.writeHex(stats.managed_pages);
    console.write(" free=");
    console.writeHex(stats.free_pages);
    console.write("\n[kernel] allocator metadata=");
    console.writeHex(layout.storage.base);
    console.write(" bytes=");
    console.writeHex(layout.storage.length);
    console.write("\n");
    try verify(console);
    heap = try heap_api.Heap(64).init(allocator().?, try newOwnerId());
    try verifyHeap(console);
}

fn verifyHeap(comptime console: type) !void {
    const pages = allocator().?;
    const before = pages.stats();
    const first = try allocateKernel(4097, 8192);
    const block = try resolveKernel(first);
    if (block.range.base % 8192 != 0 or block.range.length != 8192 or block.requested_length != 4097)
        return error.KernelHeapAlignmentFailed;
    for (0..2) |index| {
        if (!access.frameMatches(block.range.base + index * physical.page_size, 0)) return error.KernelHeapZeroingFailed;
        access.fillFrame(block.range.base + index * physical.page_size, 0x4845415011223344);
    }
    try freeKernel(first);
    const second = try allocateKernel(4097, 8192);
    const reused = try resolveKernel(second);
    if (reused.range.base != block.range.base) return error.KernelHeapReuseFailed;
    for (0..2) |index| {
        if (!access.frameMatches(reused.range.base + index * physical.page_size, 0)) return error.KernelHeapZeroingFailed;
    }
    if (freeKernel(first)) |_| return error.StaleHeapLeaseAccepted else |err| {
        if (err != error.StaleAllocation) return err;
    }
    try freeKernel(second);
    const after = pages.stats();
    if (before.free_pages != after.free_pages or before.allocated_pages != after.allocated_pages)
        return error.KernelHeapLeak;
    console.write("[kernel] kernel heap verified\n");
}

/// Exercise actual RAM on every boot path, with volatile reads/writes supplied
/// by the architecture adapter. The checks return every workload frame.
fn verify(comptime console: type) !void {
    const pages = allocator() orelse return error.MemoryNotInitialized;
    const before = pages.stats();
    const first = try allocateZeroed();
    const second = try allocateZeroed();
    if (first == second) return error.DuplicatePhysicalPage;
    if (!access.frameMatches(first, 0) or !access.frameMatches(second, 0))
        return error.PageZeroingFailed;
    access.fillFrame(first, 0xa110ca7e11223344);
    access.fillFrame(second, 0xa110ca7e55667788);

    const block = (try pages.allocateContiguous(4, 4)) orelse return error.OutOfMemory;
    if (block.base % (4 * physical.page_size) != 0 or block.length != 4 * physical.page_size)
        return error.InvalidContiguousAllocation;
    for (0..4) |index| {
        access.fillFrame(block.base + index * physical.page_size, 0xc0171c0000000000 + index);
    }
    if (!access.frameMatches(first, 0xa110ca7e11223344) or
        !access.frameMatches(second, 0xa110ca7e55667788)) return error.PhysicalPageAliasing;
    for (0..4) |index| {
        if (!access.frameMatches(block.base + index * physical.page_size, 0xc0171c0000000000 + index))
            return error.ContiguousPageIntegrityFailed;
    }
    console.write("[kernel] page allocation verified\n");

    try pages.release(first);
    const reused = try allocateZeroed();
    if (reused != first or !access.frameMatches(reused, 0) or
        !access.frameMatches(second, 0xa110ca7e55667788)) return error.PageReuseFailed;
    try pages.release(reused);
    try pages.release(second);
    try pages.releaseContiguous(block);
    const after = pages.stats();
    if (after.free_pages != before.free_pages or after.allocated_pages != before.allocated_pages or
        after.metadata_pages != before.metadata_pages or after.managed_pages != before.managed_pages)
        return error.PhysicalPageLeak;
    access.publish();
    console.write("[kernel] page reuse verified\n");
}
