//! Direct access to allocator-selected physical RAM in the bootstrap profiles.
//! Ownership and complete page accessibility remain the allocator's responsibility.
const std = @import("std");
const builtin = @import("builtin");
const protocol = @import("boot_protocol");

const page_size: u64 = 4096;
const words_per_frame = page_size / @sizeOf(u64);
const reset_x86_limit: u64 = 1 << 32;
const x86_canonical_limit: u64 = 1 << 47;
const qemu_riscv_physical_bits: u32 = 56;

extern fn bedrock_arch_physical_bits() callconv(.c) u32;
extern fn bedrock_arch_memory_features() callconv(.c) u64;

pub const Error = error{
    UnsupportedArchitecture,
    InvalidBootEnvironment,
    MissingMappedCoverage,
    UnsupportedPhysicalWidth,
    PhysicalWidthMismatch,
};

fn armPhysicalBits(features: u64) Error!u32 {
    // ID_AA64MMFR0_EL1.PARange is bits [3:0]. Wider future profiles must
    // explicitly extend this decoder and their direct-access contract.
    return switch (features & 15) {
        0 => 32,
        1 => 36,
        2 => 40,
        3 => 42,
        4 => 44,
        5 => 48,
        6 => 52,
        else => error.UnsupportedPhysicalWidth,
    };
}

fn limitFor(architecture: std.Target.Cpu.Arch, environment: u32, bits: u32) Error!u64 {
    const is_uefi = environment == @backingInt(protocol.BootEnvironment.uefi);
    if (!is_uefi and environment != @backingInt(protocol.BootEnvironment.reset_firmware))
        return error.InvalidBootEnvironment;
    switch (architecture) {
        .x86_64 => {
            if (bits < 32 or bits > 52) return error.UnsupportedPhysicalWidth;
            const physical_limit = @as(u64, 1) << @as(u6, @intCast(bits));
            return @min(physical_limit, if (is_uefi) x86_canonical_limit else reset_x86_limit);
        },
        .aarch64 => {
            switch (bits) {
                32, 36, 40, 42, 44, 48, 52 => {},
                else => return error.UnsupportedPhysicalWidth,
            }
            return @as(u64, 1) << @as(u6, @intCast(bits));
        },
        .riscv64 => {
            if (bits != qemu_riscv_physical_bits) return error.UnsupportedPhysicalWidth;
            return @as(u64, 1) << qemu_riscv_physical_bits;
        },
        else => return error.UnsupportedArchitecture,
    }
}

/// Call after platform and BootInfo validation. This is an exclusive ceiling,
/// not a claim that holes below it are accessible; intersect it with usable
/// regions and, for UEFI, the handoff's complete explicit mapped coverage.
pub fn bootstrapLimit(info: *const protocol.BootInfo) Error!u64 {
    const is_uefi = info.boot_environment == @backingInt(protocol.BootEnvironment.uefi);
    if (is_uefi and (info.mapped_range_count == 0 or info.mapped_range_count > protocol.max_mapped_ranges))
        return error.MissingMappedCoverage;
    const bits = switch (builtin.cpu.arch) {
        .x86_64 => bedrock_arch_physical_bits(),
        .aarch64 => try armPhysicalBits(bedrock_arch_memory_features()),
        // S-mode has no standard physical-width discovery CSR. This is the
        // named QEMU virt contract, shared with its direct M-mode profile.
        .riscv64 => qemu_riscv_physical_bits,
        else => return error.UnsupportedArchitecture,
    };
    const limit = try limitFor(builtin.cpu.arch, info.boot_environment, bits);
    if (is_uefi and info.physical_address_bits != bits) return error.PhysicalWidthMismatch;
    return limit;
}

/// The caller has already reserved this range and proved its complete identity
/// accessibility. Physical page zero is excluded by the bootstrap allocator.
pub fn metadata(range: protocol.PhysicalRange) []u8 {
    if (range.length == 0) return &.{};
    std.debug.assert(range.base != 0);
    const end = range.endExclusive() catch unreachable;
    std.debug.assert(end <= std.math.maxInt(usize));
    const bytes: [*]u8 = @ptrFromInt(@as(usize, @intCast(range.base)));
    return bytes[0..@intCast(range.length)];
}

fn frameWords(address: u64) [*]volatile u64 {
    std.debug.assert(address != 0 and address % page_size == 0);
    const end = @addWithOverflow(address, page_size);
    std.debug.assert(end[1] == 0 and end[0] <= std.math.maxInt(usize));
    return @ptrFromInt(@as(usize, @intCast(address)));
}

/// Write only an allocator-owned, accessible frame. Aligned scalar volatile
/// stores also support ARM's MMU-off Device-memory data-access rules.
pub fn fillFrame(address: u64, pattern: u64) void {
    const words = frameWords(address);
    for (0..words_per_frame) |index| words[index] = pattern;
    publish();
}

pub fn frameMatches(address: u64, pattern: u64) bool {
    const words = frameWords(address);
    for (0..words_per_frame) |index| {
        if (words[index] != pattern) return false;
    }
    return true;
}

/// Order completed RAM accesses before subsequent RAM consumers. This is not
/// instruction-cache maintenance, DMA synchronization or a page-table switch.
pub fn publish() void {
    switch (builtin.cpu.arch) {
        .x86_64 => asm volatile ("mfence" ::: .{ .memory = true }),
        .aarch64 => asm volatile ("dsb sy" ::: .{ .memory = true }),
        .riscv64 => asm volatile ("fence rw, rw" ::: .{ .memory = true }),
        else => @compileError("Physical RAM publication requires a supported Bedrock architecture"),
    }
}

test "ARM PARange decodes supported widths and rejects wider unknown profiles" {
    const widths = [_]u32{ 32, 36, 40, 42, 44, 48, 52 };
    for (widths, 0..) |bits, encoding| {
        try std.testing.expectEqual(bits, try armPhysicalBits(encoding | 0xf000));
    }
    for (7..16) |encoding|
        try std.testing.expectError(error.UnsupportedPhysicalWidth, armPhysicalBits(encoding));
}

test "bootstrap ceilings distinguish reset mappings from CPU and UEFI limits" {
    const reset = @backingInt(protocol.BootEnvironment.reset_firmware);
    const uefi = @backingInt(protocol.BootEnvironment.uefi);
    try std.testing.expectEqual(@as(u64, 1) << 32, try limitFor(.x86_64, reset, 36));
    try std.testing.expectEqual(@as(u64, 1) << 36, try limitFor(.x86_64, uefi, 36));
    try std.testing.expectEqual(@as(u64, 1) << 47, try limitFor(.x86_64, uefi, 52));
    try std.testing.expectEqual(@as(u64, 1) << 44, try limitFor(.aarch64, reset, 44));
    try std.testing.expectEqual(@as(u64, 1) << 52, try limitFor(.aarch64, uefi, 52));
    try std.testing.expectEqual(@as(u64, 1) << 56, try limitFor(.riscv64, uefi, 56));
    try std.testing.expectError(error.UnsupportedPhysicalWidth, limitFor(.x86_64, reset, 31));
    try std.testing.expectError(error.UnsupportedPhysicalWidth, limitFor(.aarch64, uefi, 33));
    try std.testing.expectError(error.UnsupportedPhysicalWidth, limitFor(.riscv64, uefi, 64));
    try std.testing.expectError(error.InvalidBootEnvironment, limitFor(.x86_64, 0, 36));
}

test "frame fill and verification cover the first and last word" {
    var frame: [words_per_frame]u64 align(page_size) = undefined;
    const address = @intFromPtr(&frame);
    fillFrame(address, 0x0123456789abcdef);
    try std.testing.expect(frameMatches(address, 0x0123456789abcdef));
    frame[words_per_frame - 1] = 1;
    try std.testing.expect(!frameMatches(address, 0x0123456789abcdef));
    fillFrame(address, 0);
    try std.testing.expect(frameMatches(address, 0));
    frame[0] = 1;
    try std.testing.expect(!frameMatches(address, 0));
}

test "metadata exposes only the caller-selected identity range" {
    var backing: [32]u8 = @splat(0xaa);
    const bytes = metadata(.{ .base = @intFromPtr(&backing) + 8, .length = 16 });
    try std.testing.expectEqual(@as(usize, 16), bytes.len);
    @memset(bytes, 0);
    try std.testing.expectEqual(@as(u8, 0xaa), backing[7]);
    try std.testing.expectEqual(@as(u8, 0), backing[8]);
    try std.testing.expectEqual(@as(u8, 0), backing[23]);
    try std.testing.expectEqual(@as(u8, 0xaa), backing[24]);
    try std.testing.expectEqual(@as(usize, 0), metadata(.{ .base = 0, .length = 0 }).len);
}
