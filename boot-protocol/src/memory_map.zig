//! Bounded allocation-free normalization of RAM banks and reservations.
const protocol = @import("root.zig");

pub const MemoryMapError = protocol.RangeError || error{
    EmptyRange,
    NoRam,
    TooManyInputs,
    TooManyRegions,
    OverlappingRam,
    InvalidReservationKind,
};

const limit = protocol.max_memory_regions;
const empty_range: protocol.PhysicalRange = .{ .base = 0, .length = 0 };
const Reservation = struct { range: protocol.PhysicalRange = empty_range, kind: protocol.MemoryKind = .reserved };

pub const MappedRangesError = protocol.RangeError || error{
    EmptyRange,
    InvalidPhysicalAddressBits,
    InvalidMappedRange,
    TooManyMappedRanges,
};

/// Allocation-free identity coverage, separate from allocation ownership.
/// Add only addresses whose mapping (or direct-physical entry) is established.
pub const MappedRanges = struct {
    ranges: [protocol.max_mapped_ranges]protocol.PhysicalRange = @splat(empty_range),
    count: usize = 0,
    physical_address_bits: u32,

    pub fn init(bits: u32) MappedRangesError!MappedRanges {
        if (bits < 32 or bits > 64) return error.InvalidPhysicalAddressBits;
        return .{ .physical_address_bits = bits };
    }

    /// Merge both overlapping and adjacent ranges. A failed insertion leaves
    /// this builder unchanged, including when an unmergeable 65th range arrives.
    pub fn add(self: *MappedRanges, range: protocol.PhysicalRange) MappedRangesError!void {
        if (range.length == 0) return error.EmptyRange;
        var end = try range.endExclusive();
        if (self.physical_address_bits < 32 or self.physical_address_bits > 64)
            return error.InvalidPhysicalAddressBits;
        if (self.physical_address_bits < 64 and
            end > (@as(u64, 1) << @as(u6, @intCast(self.physical_address_bits))))
            return error.InvalidMappedRange;
        if (self.count > protocol.max_mapped_ranges) return error.TooManyMappedRanges;
        var base = range.base;
        var first: usize = 0;
        while (first < self.count and try self.ranges[first].endExclusive() < base) : (first += 1) {}
        var last = first;
        while (last < self.count and self.ranges[last].base <= end) : (last += 1) {
            base = @min(base, self.ranges[last].base);
            end = @max(end, try self.ranges[last].endExclusive());
        }
        const count = self.count - (last - first) + 1;
        if (count > protocol.max_mapped_ranges) return error.TooManyMappedRanges;
        var result: [protocol.max_mapped_ranges]protocol.PhysicalRange = @splat(empty_range);
        @memcpy(result[0..first], self.ranges[0..first]);
        result[first] = .{ .base = base, .length = end - base };
        @memcpy(result[first + 1 .. count], self.ranges[last..self.count]);
        self.ranges = result;
        self.count = count;
    }

    pub fn finalize(self: *const MappedRanges, info: *protocol.BootInfo) void {
        info.mapped_ranges = self.ranges;
        info.mapped_range_count = @intCast(self.count);
        info.physical_address_bits = self.physical_address_bits;
    }
};

pub const MemoryMap = struct {
    ram: [limit]protocol.PhysicalRange = @splat(empty_range),
    ram_count: usize = 0,
    reservations: [limit]Reservation = @splat(Reservation{}),
    reservation_count: usize = 0,

    pub fn reset(self: *MemoryMap) void {
        self.* = .{};
    }

    pub fn addRam(self: *MemoryMap, range: protocol.PhysicalRange) MemoryMapError!void {
        const end = try checkedEnd(range);
        if (self.ram_count >= limit) return error.TooManyInputs;
        for (self.ram[0..self.ram_count]) |other| {
            const other_end = try other.endExclusive();
            if (range.base < other_end and other.base < end) return error.OverlappingRam;
        }
        self.ram[self.ram_count] = range;
        self.ram_count += 1;
    }

    pub fn addReservation(self: *MemoryMap, range: protocol.PhysicalRange, kind: protocol.MemoryKind) MemoryMapError!void {
        _ = try checkedEnd(range);
        if (kind == .usable) return error.InvalidReservationKind;
        if (self.reservation_count >= limit) return error.TooManyInputs;
        self.reservations[self.reservation_count] = .{ .range = range, .kind = kind };
        self.reservation_count += 1;
    }

    /// Overlay reservations, including ranges outside RAM, then merge matching
    /// neighbors. On failure the destination BootInfo remains unchanged.
    /// Other handoff metadata and the legacy boot RAM bank are caller-owned.
    pub fn finalize(self: *const MemoryMap, info: *protocol.BootInfo) MemoryMapError!void {
        if (self.ram_count == 0) return error.NoRam;
        if (self.ram_count > limit or self.reservation_count > limit) return error.TooManyInputs;
        var boundaries: [4 * limit]u64 = undefined;
        var boundary_count: usize = 0;
        for (self.ram[0..self.ram_count]) |range| {
            insertBoundary(&boundaries, &boundary_count, range.base);
            insertBoundary(&boundaries, &boundary_count, try checkedEnd(range));
        }
        for (self.reservations[0..self.reservation_count]) |reservation| {
            if (reservation.kind == .usable) return error.InvalidReservationKind;
            insertBoundary(&boundaries, &boundary_count, reservation.range.base);
            insertBoundary(&boundaries, &boundary_count, try checkedEnd(reservation.range));
        }
        var result: [limit]protocol.MemoryRegion = @splat(protocol.empty_memory_region);
        var count: usize = 0;
        for (boundaries[0 .. boundary_count - 1], 0..) |base, index| {
            const end = boundaries[index + 1];
            var selected: ?protocol.MemoryKind = null;
            for (self.ram[0..self.ram_count]) |range| {
                if (range.base <= base and end <= try range.endExclusive()) selected = .usable;
            }
            for (self.reservations[0..self.reservation_count]) |reservation| {
                if (reservation.range.base <= base and end <= try reservation.range.endExclusive()) {
                    if (selected == null or priority(reservation.kind) > priority(selected.?)) selected = reservation.kind;
                }
            }
            const kind = selected orelse continue;
            if (count != 0 and result[count - 1].kind == @backingInt(kind) and
                try result[count - 1].range.endExclusive() == base)
            {
                result[count - 1].range.length = end - result[count - 1].range.base;
                continue;
            }
            if (count == limit) return error.TooManyRegions;
            result[count] = .{ .range = .{ .base = base, .length = end - base }, .kind = @backingInt(kind), .attributes = 0 };
            count += 1;
        }
        info.memory_regions = result;
        info.memory_region_count = @intCast(count);
        info.memory_map_reserved = 0;
    }
};

fn checkedEnd(range: protocol.PhysicalRange) MemoryMapError!u64 {
    if (range.length == 0) return error.EmptyRange;
    return range.endExclusive();
}

fn insertBoundary(boundaries: *[4 * limit]u64, count: *usize, value: u64) void {
    var index: usize = 0;
    while (index < count.* and boundaries[index] < value) : (index += 1) {}
    if (index < count.* and boundaries[index] == value) return;
    var shift = count.*;
    while (shift > index) : (shift -= 1) boundaries[shift] = boundaries[shift - 1];
    boundaries[index] = value;
    count.* += 1;
}

fn priority(kind: protocol.MemoryKind) u8 {
    return switch (kind) {
        .usable => 0,
        .loader_reclaimable => 1,
        .kernel => 2,
        .reserved => 3,
        .firmware_runtime => 4,
        .mmio => 5,
    };
}
