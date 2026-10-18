//! Module-local facade for generation checked allocations owned by the kernel.
//! No kernel allocator implementation or Zig owner representation crosses ABI.
const std = @import("std");
const abi = @import("driver_abi");
const protocol = @import("boot_protocol");
pub const heap_api = struct {
    pub const Ticket = struct { token: u64 };
    pub const Block = struct { range: protocol.PhysicalRange, requested_length: usize };
};
var host: ?abi.Host = null;

pub fn install(value: *const abi.Host) !void {
    if (host != null) return error.ModuleAlreadyInitialized;
    if (!value.validate()) return error.InvalidHostAbi;
    host = value.*;
}
fn imports() !*const abi.Host {
    return if (host) |*value| value else error.MissingHostImports;
}
fn success(status: u32) !void {
    if (status != @backingInt(abi.Status.ok)) return error.HostAllocationFailed;
}
fn validate(value: abi.Allocation, token: ?u64) !void {
    if (value.token == 0 or (token != null and value.token != token.?) or value.base == 0 or value.base % 4096 != 0 or value.length == 0 or value.length % 4096 != 0)
        return error.InvalidHostAllocation;
    _ = try (protocol.PhysicalRange{ .base = value.base, .length = value.length }).endExclusive();
}
pub fn allocateKernel(bytes: usize, alignment: usize) !heap_api.Ticket {
    if (bytes == 0 or alignment == 0 or alignment & (alignment - 1) != 0) return error.InvalidAllocationRequest;
    const imported = try imports();
    var result: abi.Allocation = .{ .token = 0, .base = 0, .length = 0 };
    try success(imported.allocate(imported.context, bytes, alignment, &result));
    errdefer if (result.token != 0) {
        _ = imported.release(imported.context, result.token);
    };
    try validate(result, null);
    const rounded = std.math.add(u64, bytes, 4095) catch return error.InvalidAllocationRequest;
    if (result.length != (rounded & ~@as(u64, 4095)) or result.base % alignment != 0) return error.InvalidHostAllocation;
    return .{ .token = result.token };
}
pub fn resolveKernel(ticket: heap_api.Ticket) !heap_api.Block {
    if (ticket.token == 0) return error.InvalidHostAllocation;
    const imported = try imports();
    var result: abi.Allocation = .{ .token = 0, .base = 0, .length = 0 };
    try success(imported.resolve(imported.context, ticket.token, &result));
    try validate(result, ticket.token);
    return .{ .range = .{ .base = result.base, .length = result.length }, .requested_length = @intCast(result.length) };
}
pub fn freeKernel(ticket: heap_api.Ticket) !void {
    if (ticket.token == 0) return error.InvalidHostAllocation;
    const imported = try imports();
    try success(imported.release(imported.context, ticket.token));
}

const Fake = struct {
    live: bool = false,
    generation: u64 = 1,
    releases: usize = 0,
    malformed: bool = false,
    fn cast(context: *anyopaque) *Fake {
        return @ptrCast(@alignCast(context));
    }
    fn table(self: *Fake) abi.Host {
        return .{ .context = self, .boot_info = @ptrFromInt(8), .boot_info_size = 1, .now_ms = 0, .allocate = allocate, .resolve = resolve, .release = release };
    }
    fn allocate(context: *anyopaque, size: u64, _: u64, output: *abi.Allocation) callconv(.c) u32 {
        const self = cast(context);
        if (self.live or size != 4097) return @backingInt(abi.Status.failed);
        self.live = true;
        output.* = .{ .token = self.generation, .base = 0x8000, .length = if (self.malformed) 4096 else 8192 };
        return @backingInt(abi.Status.ok);
    }
    fn resolve(context: *anyopaque, token: u64, output: *abi.Allocation) callconv(.c) u32 {
        const self = cast(context);
        if (!self.live or token != self.generation) return @backingInt(abi.Status.failed);
        output.* = .{ .token = self.generation, .base = 0x8000, .length = 8192 };
        return @backingInt(abi.Status.ok);
    }
    fn release(context: *anyopaque, token: u64) callconv(.c) u32 {
        const self = cast(context);
        if (!self.live or token != self.generation) return @backingInt(abi.Status.failed);
        self.live = false;
        self.generation += 1;
        self.releases += 1;
        return @backingInt(abi.Status.ok);
    }
};
test "module allocation callbacks preserve opaque token generation and release rejected leases" {
    defer host = null;
    var fake: Fake = .{};
    const imported = fake.table();
    try install(&imported);
    const first = try allocateKernel(4097, 8192);
    try std.testing.expectEqual(@as(u64, 8192), (try resolveKernel(first)).range.length);
    try freeKernel(first);
    const second = try allocateKernel(4097, 8192);
    try std.testing.expectError(error.HostAllocationFailed, resolveKernel(first));
    try std.testing.expectError(error.HostAllocationFailed, freeKernel(first));
    try std.testing.expect(fake.live);
    try freeKernel(second);
    fake.malformed = true;
    try std.testing.expectError(error.InvalidHostAllocation, allocateKernel(4097, 8192));
    try std.testing.expect(!fake.live);
    try std.testing.expectEqual(@as(usize, 3), fake.releases);
}
