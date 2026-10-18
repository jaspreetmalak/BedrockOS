//! Bounded live x86 page-table/PAT/MTRR proof, separate from the privileged
//! reader. EFI memory attributes alone do not establish a CPU cache policy.
const std = @import("std");
const protocol = @import("boot_protocol");
pub const Type = enum(u8) { uc = 0, wc = 1, wt = 4, wp = 5, wb = 6, uc_minus = 7 };
pub const Variable = struct { base: u64 = 0, length: u64 = 0, kind: Type = .uc };
pub const max_variables = 32;
pub const Snapshot = struct {
    root: u64 = 0,
    physical_bits: u8 = 0,
    pat: u64 = 0,
    mtrr_enabled: bool = false,
    default_type: Type = .uc,
    count: usize = 0,
    variables: [max_variables]Variable = @splat(.{}),
    pub fn physicalMask(self: *const Snapshot) !u64 {
        if (self.physical_bits < 32 or self.physical_bits > 52) return error.UnsupportedPhysicalWidth;
        return ((@as(u64, 1) << @intCast(self.physical_bits)) - 1) & ~@as(u64, 4095);
    }
    pub fn validate(self: *const Snapshot) !void {
        const mask = try self.physicalMask();
        if (self.root == 0 or self.root & 4095 != 0 or self.root & ~mask != 0 or self.count > max_variables) return error.InvalidCacheSnapshot;
        for (0..8) |i| _ = try cacheType(@truncate(self.pat >> @intCast(i * 8)), true);
        for (self.variables[0..self.count]) |v| {
            if (v.length < 4096 or !std.math.isPowerOfTwo(v.length) or v.base % v.length != 0 or v.base & ~mask != 0 or v.length > (@as(u64, 1) << @intCast(self.physical_bits)) - v.base or v.kind == .uc_minus) return error.InvalidMtrr;
        }
    }
    pub fn addMtrr(self: *Snapshot, base_register: u64, mask_register: u64) !void {
        if (mask_register & (1 << 11) == 0) return;
        if (self.count == max_variables) return error.UnsupportedMtrrCount;
        const physical_mask = try self.physicalMask();
        if (base_register & ~(physical_mask | @as(u64, 0xff)) != 0 or mask_register & ~(physical_mask | @as(u64, 1 << 11)) != 0) return error.InvalidMtrr;
        const base = base_register & physical_mask;
        const mask = mask_register & physical_mask;
        const length = ((~mask) & physical_mask) + 4096;
        if (!std.math.isPowerOfTwo(length) or base % length != 0) return error.InvalidMtrr;
        self.variables[self.count] = .{ .base = base, .length = length, .kind = try cacheType(@truncate(base_register), false) };
        self.count += 1;
    }
    fn mtrr(self: *const Snapshot, address: u64) !Type {
        if (!self.mtrr_enabled) return .uc;
        var found: ?Type = null;
        for (self.variables[0..self.count]) |v| if (address >= v.base and address - v.base < v.length) {
            if (found) |prior| {
                if (prior == v.kind) continue;
                if (prior == .uc or v.kind == .uc) {
                    found = .uc;
                    continue;
                }
                if ((prior == .wb and v.kind == .wt) or (prior == .wt and v.kind == .wb)) {
                    found = .wt;
                    continue;
                }
                return error.UndefinedMtrrOverlap;
            } else found = v.kind;
        };
        return found orelse self.default_type;
    }
    fn nextBoundary(self: *const Snapshot, address: u64, end: u64) u64 {
        var next = end;
        for (self.variables[0..self.count]) |v| {
            if (v.base > address) next = @min(next, v.base);
            const high = v.base + v.length;
            if (high > address) next = @min(next, high);
        }
        return next;
    }
};
pub fn cacheType(value: u8, pat: bool) !Type {
    return switch (value) {
        0 => .uc,
        1 => .wc,
        4 => .wt,
        5 => .wp,
        6 => .wb,
        7 => if (pat) .uc_minus else error.InvalidCacheType,
        else => error.InvalidCacheType,
    };
}
pub const Reader = struct {
    context: *anyopaque,
    read: *const fn (*anyopaque, u64) anyerror!u64,
};
const Leaf = struct { end: u64, cache: Type };
fn leaf(snapshot: *const Snapshot, info: *const protocol.BootInfo, reader: Reader, address: u64, write: bool) !Leaf {
    if (address >= 0x8000_0000_0000) return error.UnsupportedVirtualAddress;
    const mask = try snapshot.physicalMask();
    var table = snapshot.root;
    var user_accessible = true;
    const shifts = [_]u6{ 39, 30, 21, 12 };
    for (shifts, 0..) |shift, level| {
        const table_range: protocol.PhysicalRange = .{ .base = table, .length = 4096 };
        if (table == 0 or table & ~mask != 0 or !info.isMapped(table_range) or !ramCovered(info, table_range, false)) return error.InvalidPageTable;
        const entry = try reader.read(reader.context, table + ((address >> shift) & 511) * 8);
        // A task's shared PML4 may be U=1 for another branch. x86 combines
        // U/S restrictions across all levels; a supervisor leaf/ancestor keeps
        // this identity alias inaccessible to CPL3.
        if (entry & 1 == 0) return error.UnmappedCpuAddress;
        user_accessible = user_accessible and entry & 4 != 0;
        if (write and entry & 2 == 0) return error.ReadOnlyCpuAlias;
        if (entry & 0x000f_ffff_ffff_f000 & ~mask != 0) return error.InvalidPageTable;
        const large = (level == 1 or level == 2) and entry & (1 << 7) != 0;
        if (level == 0 and entry & (1 << 7) != 0) return error.InvalidPageTable;
        if (large or level == 3) {
            if (user_accessible) return error.UserAccessibleAlias;
            const bytes: u64 = @as(u64, 1) << (if (large) shift else @as(u6, 12));
            const physical = entry & mask & ~(bytes - 1);
            const low_reserved = (bytes - 1) & ~@as(u64, 0x1fff);
            if (large and entry & low_reserved != 0) return error.InvalidPageTable;
            if (physical | (address & (bytes - 1)) != address) return error.NonIdentityCpuAlias;
            const index: u6 = @intCast(((entry >> 3) & 3) | (((entry >> @as(u6, if (large) 12 else 7)) & 1) << 2));
            return .{ .end = (address & ~(bytes - 1)) + bytes, .cache = try cacheType(@truncate(snapshot.pat >> (index * 8)), true) };
        }
        table = entry & mask;
    }
    return error.InvalidPageTable;
}
/// Normalized map ownership, allowing adjoining RAM descriptors. Unknown
/// kinds and MMIO never authorize page-table reads or allocator-backed DMA.
pub fn ramCovered(info: *const protocol.BootInfo, range: protocol.PhysicalRange, usable_only: bool) bool {
    if (range.length == 0 or info.memory_region_count == 0 or info.memory_region_count > protocol.max_memory_regions) return false;
    const end = range.endExclusive() catch return false;
    var cursor = range.base;
    for (info.memory_regions[0..info.memory_region_count]) |region| {
        const high = region.range.endExclusive() catch return false;
        if (high <= cursor) continue;
        if (region.range.base > cursor) return false;
        const allowed = region.isUsable() or (!usable_only and (region.kind == @backingInt(protocol.MemoryKind.kernel) or region.kind == @backingInt(protocol.MemoryKind.loader_reclaimable)));
        if (!allowed) return false;
        cursor = @min(end, high);
        if (cursor == end) return true;
    }
    return false;
}
/// Fixed MTRRs are deliberately out of this first provider: both MMIO and
/// allocation candidates below1MiB are rejected instead of guessing that table.
pub fn require(snapshot: *const Snapshot, info: *const protocol.BootInfo, reader: Reader, range: protocol.PhysicalRange, wanted: Type) !void {
    try snapshot.validate();
    const end = try range.endExclusive();
    if (range.length == 0 or range.base < 0x100000 or end > 0x8000_0000_0000 or !info.isMapped(range)) return error.UnsupportedCpuRange;
    var cursor = range.base;
    while (cursor < end) {
        const current = try leaf(snapshot, info, reader, cursor, true);
        const mtrr_type = try snapshot.mtrr(cursor);
        if (wanted == .wb) {
            if (current.cache != .wb or mtrr_type != .wb) return error.NonWriteBackDma;
        } else if (wanted == .uc) {
            if (current.cache != .uc) return error.NonUncachedMmio;
        } else return error.UnsupportedCachePolicy;
        cursor = snapshot.nextBoundary(cursor, @min(end, current.end));
    }
}
test "variable MTRR decoding rejects widened masks and incompatible overlap" {
    var snap: Snapshot = .{ .root = 0x100000, .physical_bits = 36, .pat = 0x0007040600070406, .mtrr_enabled = true, .default_type = .wb };
    try snap.addMtrr(0xe0000000, 0xffff00000 | 0x800);
    try snap.validate();
    try std.testing.expectEqual(Type.uc, try snap.mtrr(0xe0000000));
    try snap.addMtrr(0xe0000000 | 1, 0xffff00000 | 0x800);
    try std.testing.expectEqual(Type.uc, try snap.mtrr(0xe0000000));
    try std.testing.expectError(error.InvalidMtrr, snap.addMtrr(0x400000 | 6, 0xfffeff000 | 0x800));
    snap.variables[0].kind = .wt;
    try std.testing.expectError(error.UndefinedMtrrOverlap, snap.mtrr(0xe0000000));
}
