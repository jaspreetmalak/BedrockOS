//! Proposed common boot handoff records. The ABI is not finalized.
//! Wire records use fixed-width values and contain no native pointers.
const std = @import("std");

/// Numeric interpretation of the eight ASCII bytes "BEDROCKB" in little endian.
pub const magic: u64 = 0x424b434f52444542;
pub const version_major: u16 = 0;
pub const version_minor: u16 = 2;
pub const max_memory_regions = 64;
pub const max_mapped_ranges = 64;
pub const MemoryMap = @import("memory_map.zig").MemoryMap;
pub const MemoryMapError = @import("memory_map.zig").MemoryMapError;
pub const MappedRanges = @import("memory_map.zig").MappedRanges;
pub const MappedRangesError = @import("memory_map.zig").MappedRangesError;

pub const Architecture = enum(u32) {
    x86_64 = 1,
    aarch64 = 2,
    riscv64 = 3,
};

pub const HeaderError = error{
    InvalidMagic,
    UnsupportedMajorVersion,
    HeaderTooSmall,
    HeaderTruncated,
    ArchitectureMismatch,
    NonZeroReserved,
};

pub const Header = extern struct {
    magic_value: u64,
    major: u16,
    minor: u16,
    /// Includes this fixed prefix and any future header extension bytes.
    header_size: u32,
    /// A numeric tag permits validation before converting to an enum.
    architecture: u32,
    reserved: u32,

    pub fn init(architecture: Architecture) Header {
        return .{
            .magic_value = magic,
            .major = version_major,
            .minor = version_minor,
            .header_size = @sizeOf(Header),
            .architecture = @backingInt(architecture),
            .reserved = 0,
        };
    }

    /// Call only after safely obtaining this fixed prefix from mapped memory.
    /// available_bytes is the accessible size starting at the header address.
    /// Unknown minor versions and longer headers are accepted for extension.
    pub fn validate(self: Header, available_bytes: usize, expected_arch: Architecture) HeaderError!void {
        if (available_bytes < @sizeOf(Header)) return error.HeaderTruncated;
        if (self.magic_value != magic) return error.InvalidMagic;
        if (self.major != version_major) return error.UnsupportedMajorVersion;
        if (self.header_size < @sizeOf(Header)) return error.HeaderTooSmall;
        if (self.header_size > available_bytes) return error.HeaderTruncated;
        if (self.architecture != @backingInt(expected_arch)) return error.ArchitectureMismatch;
        if (self.reserved != 0) return error.NonZeroReserved;
    }
};

pub const RangeError = error{PhysicalRangeOverflow};

pub const PhysicalRange = extern struct {
    base: u64,
    length: u64,

    /// A zero-length range is valid, including at the largest physical address.
    /// A range whose exclusive end cannot be represented is rejected.
    pub fn endExclusive(self: PhysicalRange) RangeError!u64 {
        const sum = @addWithOverflow(self.base, self.length);
        if (sum[1] != 0) return error.PhysicalRangeOverflow;
        return sum[0];
    }
};

pub const MemoryKind = enum(u32) {
    usable = 1,
    reserved = 2,
    loader_reclaimable = 3,
    kernel = 4,
    firmware_runtime = 5,
    mmio = 6,
};

pub const MemoryRegion = extern struct {
    range: PhysicalRange,
    /// Consumers must handle unknown numeric kinds conservatively as reserved.
    kind: u32,
    /// Reserved for future attributes; producers currently write zero.
    attributes: u32,

    /// Unknown kinds are conservatively reserved, never available to allocate.
    pub fn isUsable(self: MemoryRegion) bool {
        return self.kind == @backingInt(MemoryKind.usable);
    }
};

pub const empty_memory_region: MemoryRegion = .{
    .range = .{ .base = 0, .length = 0 },
    .kind = 0,
    .attributes = 0,
};

pub const ConsoleKind = enum(u32) { none = 0, pl011 = 1, ns16550_mmio = 2, ns16550_io = 3, framebuffer = 4 };
pub const BootEnvironment = enum(u32) { reset_firmware = 1, uefi = 2 };
pub const EntryState = enum(u32) { x86_64_long_mode = 1, aarch64_el1 = 2, riscv64_m = 3, riscv64_s = 4 };

pub const Console = extern struct {
    kind: u32 = 0,
    register_stride: u32 = 1,
    base: u64 = 0,
    clock_hz: u32 = 0,
    baud_rate: u32 = 115200,
    reserved: u64 = 0,

    pub fn isSerial(self: Console) bool {
        return self.kind >= @backingInt(ConsoleKind.pl011) and self.kind <= @backingInt(ConsoleKind.ns16550_io);
    }

    pub fn validate(self: Console) error{InvalidConsole}!void {
        if (self.reserved != 0) return error.InvalidConsole;
        switch (self.kind) {
            @backingInt(ConsoleKind.none) => {
                if (self.base != 0 or self.clock_hz != 0 or self.register_stride != 1)
                    return error.InvalidConsole;
            },
            @backingInt(ConsoleKind.pl011) => {
                if (self.base == 0 or self.base % 4 != 0 or self.register_stride != 4 or
                    self.baud_rate == 0 or self.base > std.math.maxInt(u64) - 0x48)
                    return error.InvalidConsole;
                if (self.clock_hz != 0) {
                    // PL011 IBRD is 16 bits, FBRD is 6 bits, and IBRD >= 1.
                    const divisor64 = (@as(u64, self.clock_hz) * 4 + self.baud_rate / 2) / self.baud_rate;
                    if (divisor64 < 64 or divisor64 > 65535 * 64 + 63) return error.InvalidConsole;
                }
            },
            @backingInt(ConsoleKind.ns16550_mmio) => {
                if (self.base == 0 or self.baud_rate == 0 or
                    (self.register_stride != 1 and self.register_stride != 2 and self.register_stride != 4 and self.register_stride != 8) or
                    self.base % self.register_stride != 0 or
                    self.base > std.math.maxInt(u64) - (@as(u64, self.register_stride) * 7 + 1))
                    return error.InvalidConsole;
            },
            @backingInt(ConsoleKind.ns16550_io) => {
                if (self.base == 0 or self.base > 65528 or self.register_stride != 1 or self.baud_rate == 0)
                    return error.InvalidConsole;
            },
            @backingInt(ConsoleKind.framebuffer) => {
                if (self.base == 0 or self.base % 4 != 0 or self.register_stride != 1 or self.clock_hz != 0)
                    return error.InvalidConsole;
            },
            else => return error.InvalidConsole,
        }
        if ((self.kind == @backingInt(ConsoleKind.ns16550_mmio) or
            self.kind == @backingInt(ConsoleKind.ns16550_io)) and self.clock_hz != 0)
        {
            // The two divisor-latch bytes encode 1..65535. Check the same
            // rounded divider used by consumers before any truncating write.
            const divisor = (@as(u64, self.clock_hz) + @as(u64, self.baud_rate) * 8) /
                (@as(u64, self.baud_rate) * 16);
            if (divisor == 0 or divisor > 65535) return error.InvalidConsole;
        }
    }
};

/// A 32-bit pixel framebuffer. Format 1 uses the three explicit channel masks.
pub const Framebuffer = extern struct {
    base: u64 = 0,
    size: u64 = 0,
    width: u32 = 0,
    height: u32 = 0,
    pixels_per_scanline: u32 = 0,
    format: u32 = 0,
    red_mask: u32 = 0,
    green_mask: u32 = 0,
    blue_mask: u32 = 0,
    reserved: u32 = 0,

    pub fn validate(self: Framebuffer) error{ InvalidFramebuffer, PhysicalRangeOverflow }!void {
        if (self.base == 0 and self.size == 0 and self.width == 0 and self.height == 0 and
            self.pixels_per_scanline == 0 and self.format == 0 and self.red_mask == 0 and
            self.green_mask == 0 and self.blue_mask == 0 and self.reserved == 0) return;
        if (self.base == 0 or self.base % 4 != 0 or self.width < 8 or self.height < 12 or
            self.pixels_per_scanline < self.width or self.format != 1 or self.reserved != 0 or
            self.red_mask == 0 or self.green_mask == 0 or self.blue_mask == 0 or
            self.red_mask & self.green_mask != 0 or self.red_mask & self.blue_mask != 0 or
            self.green_mask & self.blue_mask != 0) return error.InvalidFramebuffer;
        const row_bytes = @as(u64, self.pixels_per_scanline) * 4;
        const required_bytes = std.math.mul(u64, row_bytes, self.height) catch return error.PhysicalRangeOverflow;
        if (self.size < required_bytes) return error.InvalidFramebuffer;
        _ = try (PhysicalRange{ .base = self.base, .length = self.size }).endExclusive();
    }
};

/// Emulator acceptance tests may exit through the platform test device or
/// semihosting when this bit is set. Normal boot images leave it clear.
pub const flag_smoke_exit: u64 = 1;

pub const BootInfoError = HeaderError || RangeError || error{
    EmptyRange,
    RangeOutsideRam,
    OverlappingReservations,
    DtbOutsideLoader,
    KernelOutsideReservation,
    InvalidUart,
    InvalidDtb,
    InvalidConsole,
    InvalidFramebuffer,
    FramebufferOverlapsReservations,
    InvalidBootEnvironment,
    InvalidEntryState,
    InvalidMemoryRegionCount,
    InvalidMemoryRegionAttributes,
    UnsortedMemoryMap,
    UsableReservationOverlap,
    ReservationNotCovered,
    InvalidFirmwareMemoryMap,
    InvalidMappedRangeCount,
    InvalidPhysicalAddressBits,
    InvalidMappedRange,
    UnsortedMappedRanges,
    RequiredRangeNotMapped,
};

/// Draft v0.2 hardware handoff. The ram prefix is an informational envelope
/// that may contain holes; it never grants allocation or mapping permission.
/// memory_regions describes allocation ownership across all discovered banks.
/// Before dereferencing, the consumer must validate pointer alignment and that
/// available_bytes are mapped in a trusted platform-provided loader arena.
pub const BootInfo = extern struct {
    header: Header,
    uart_base: u64,
    /// UEFI/ACPI paths and reset x86-64 may omit Devicetree with {0, 0}.
    dtb: PhysicalRange,
    kernel_image: PhysicalRange,
    ram: PhysicalRange,
    loader_reserved: PhysicalRange,
    kernel_reserved: PhysicalRange,
    flags: u64,
    memory_region_count: u32 = 0,
    memory_map_reserved: u32 = 0,
    memory_regions: [max_memory_regions]MemoryRegion = @splat(empty_memory_region),
    console: Console = .{},
    boot_environment: u32 = @backingInt(BootEnvironment.reset_firmware),
    entry_state: u32 = 0,
    acpi_rsdp: u64 = 0,
    framebuffer: Framebuffer = .{},
    firmware_memory_map: PhysicalRange = .{ .base = 0, .length = 0 },
    firmware_descriptor_size: u32 = 0,
    firmware_descriptor_version: u32 = 0,
    mapped_range_count: u32 = 0,
    physical_address_bits: u32 = 0,
    /// Sorted disjoint VA=PA coverage, independent of page/cache policy.
    /// UEFI producers report it explicitly; legacy reset profiles use zeros.
    mapped_ranges: [max_mapped_ranges]PhysicalRange = @splat(PhysicalRange{ .base = 0, .length = 0 }),

    /// Query validated identity coverage. Unreported legacy reset coverage is
    /// not inferred here: those consumers retain their pinned platform checks.
    pub fn isMapped(self: *const BootInfo, range: PhysicalRange) bool {
        if (self.mapped_range_count == 0 or self.mapped_range_count > max_mapped_ranges or range.length == 0)
            return false;
        const end = range.endExclusive() catch return false;
        var cursor = range.base;
        for (self.mapped_ranges[0..self.mapped_range_count]) |mapped| {
            const mapped_end = mapped.endExclusive() catch return false;
            if (mapped_end <= cursor) continue;
            if (mapped.base > cursor) return false;
            cursor = @min(mapped_end, end);
            if (cursor == end) return true;
        }
        return false;
    }

    pub fn validate(self: *const BootInfo, available_bytes: usize, expected_arch: Architecture) BootInfoError!void {
        if (available_bytes < @sizeOf(BootInfo)) return error.HeaderTruncated;
        try self.header.validate(available_bytes, expected_arch);
        if (self.header.header_size < @sizeOf(BootInfo)) return error.HeaderTooSmall;
        try self.console.validate();
        if (self.console.isSerial() and self.uart_base != 0 and self.uart_base != self.console.base)
            return error.InvalidUart;
        switch (self.boot_environment) {
            @backingInt(BootEnvironment.reset_firmware), @backingInt(BootEnvironment.uefi) => {},
            else => return error.InvalidBootEnvironment,
        }
        const entry_valid = switch (expected_arch) {
            .x86_64 => self.entry_state == @backingInt(EntryState.x86_64_long_mode),
            .aarch64 => self.entry_state == @backingInt(EntryState.aarch64_el1),
            .riscv64 => self.entry_state == @backingInt(EntryState.riscv64_m) or self.entry_state == @backingInt(EntryState.riscv64_s),
        };
        if (!entry_valid) return error.InvalidEntryState;
        const ram_end = try nonEmptyEnd(self.ram);
        const loader_end = try nonEmptyEnd(self.loader_reserved);
        const kernel_end = try nonEmptyEnd(self.kernel_reserved);
        const image_end = try nonEmptyEnd(self.kernel_image);
        if (self.loader_reserved.base < self.ram.base or loader_end > ram_end or
            self.kernel_reserved.base < self.ram.base or kernel_end > ram_end)
            return error.RangeOutsideRam;
        if (self.loader_reserved.base < kernel_end and self.kernel_reserved.base < loader_end)
            return error.OverlappingReservations;
        if (self.dtb.length == 0 and (expected_arch == .x86_64 or self.acpi_rsdp != 0 or
            self.boot_environment == @backingInt(BootEnvironment.uefi)))
        {
            if (self.dtb.base != 0) return error.InvalidDtb;
        } else {
            const dtb_end = try nonEmptyEnd(self.dtb);
            if (self.dtb.base < self.loader_reserved.base or dtb_end > loader_end)
                return error.DtbOutsideLoader;
        }
        if (self.kernel_image.base < self.kernel_reserved.base or image_end > kernel_end)
            return error.KernelOutsideReservation;
        try self.framebuffer.validate();
        if (self.console.kind == @backingInt(ConsoleKind.framebuffer) and
            (self.framebuffer.base == 0 or self.console.base != self.framebuffer.base))
            return error.InvalidFramebuffer;
        if (self.framebuffer.base != 0) {
            const framebuffer_end = try (PhysicalRange{ .base = self.framebuffer.base, .length = self.framebuffer.size }).endExclusive();
            if (overlaps(self.framebuffer.base, framebuffer_end, self.loader_reserved.base, loader_end) or
                overlaps(self.framebuffer.base, framebuffer_end, self.kernel_reserved.base, kernel_end))
                return error.FramebufferOverlapsReservations;
        }
        if (self.boot_environment == @backingInt(BootEnvironment.reset_firmware)) {
            if (self.firmware_memory_map.base != 0 or self.firmware_memory_map.length != 0 or
                self.firmware_descriptor_size != 0 or self.firmware_descriptor_version != 0)
                return error.InvalidFirmwareMemoryMap;
        } else {
            if (self.firmware_memory_map.length == 0 or self.firmware_descriptor_size < 40 or
                self.firmware_descriptor_version == 0 or self.firmware_memory_map.length % self.firmware_descriptor_size != 0)
                return error.InvalidFirmwareMemoryMap;
            const firmware_end = try self.firmware_memory_map.endExclusive();
            if (self.firmware_memory_map.base < self.loader_reserved.base or firmware_end > loader_end)
                return error.InvalidFirmwareMemoryMap;
        }
        try self.validateMemoryMap(loader_end, kernel_end);
        try self.validateMappings();
    }

    fn validateMappings(self: *const BootInfo) BootInfoError!void {
        if (self.mapped_range_count == 0) {
            if (self.boot_environment == @backingInt(BootEnvironment.uefi))
                return error.InvalidMappedRangeCount;
            if (self.physical_address_bits != 0) return error.InvalidPhysicalAddressBits;
            for (self.mapped_ranges) |range| {
                if (range.base != 0 or range.length != 0) return error.InvalidMappedRange;
            }
            return;
        }
        if (self.mapped_range_count > max_mapped_ranges) return error.InvalidMappedRangeCount;
        if (self.physical_address_bits < 32 or self.physical_address_bits > 64)
            return error.InvalidPhysicalAddressBits;
        var previous_end: u64 = 0;
        for (self.mapped_ranges[0..self.mapped_range_count], 0..) |range, index| {
            const end = try nonEmptyEnd(range);
            if (index != 0 and range.base < previous_end) return error.UnsortedMappedRanges;
            if (self.physical_address_bits < 64 and
                end > (@as(u64, 1) << @as(u6, @intCast(self.physical_address_bits))))
                return error.InvalidMappedRange;
            previous_end = end;
        }
        if (!self.isMapped(self.loader_reserved) or !self.isMapped(self.kernel_reserved))
            return error.RequiredRangeNotMapped;
        if (self.dtb.length != 0 and !self.isMapped(self.dtb)) return error.RequiredRangeNotMapped;
        if (self.firmware_memory_map.length != 0 and !self.isMapped(self.firmware_memory_map))
            return error.RequiredRangeNotMapped;
        if (self.framebuffer.base != 0 and
            !self.isMapped(.{ .base = self.framebuffer.base, .length = self.framebuffer.size }))
            return error.RequiredRangeNotMapped;
        const console_bytes: u64 = switch (self.console.kind) {
            @backingInt(ConsoleKind.pl011) => 0x48,
            @backingInt(ConsoleKind.ns16550_mmio) => @as(u64, self.console.register_stride) * 7 + 1,
            else => 0,
        };
        if (console_bytes != 0 and !self.isMapped(.{ .base = self.console.base, .length = console_bytes }))
            return error.RequiredRangeNotMapped;
    }

    fn validateMemoryMap(self: *const BootInfo, loader_end: u64, kernel_end: u64) BootInfoError!void {
        if (self.memory_region_count == 0 or self.memory_region_count > max_memory_regions)
            return error.InvalidMemoryRegionCount;
        if (self.memory_map_reserved != 0) return error.NonZeroReserved;
        const regions = self.memory_regions[0..self.memory_region_count];
        var previous_end: u64 = 0;
        for (regions, 0..) |region, index| {
            const end = try nonEmptyEnd(region.range);
            if (index != 0 and region.range.base < previous_end) return error.UnsortedMemoryMap;
            previous_end = end;
            if (region.attributes != 0) return error.InvalidMemoryRegionAttributes;
            if (region.isUsable() and (overlaps(region.range.base, end, self.loader_reserved.base, loader_end) or
                overlaps(region.range.base, end, self.kernel_reserved.base, kernel_end)))
                return error.UsableReservationOverlap;
        }
        try coverReservation(regions, self.loader_reserved);
        try coverReservation(regions, self.kernel_reserved);
    }
};

fn overlaps(base: u64, end: u64, other_base: u64, other_end: u64) bool {
    return base < other_end and other_base < end;
}

fn coverReservation(regions: []const MemoryRegion, range: PhysicalRange) BootInfoError!void {
    var cursor = range.base;
    const end = try range.endExclusive();
    for (regions) |region| {
        const region_end = try region.range.endExclusive();
        if (region_end <= cursor) continue;
        if (region.range.base > cursor) return error.ReservationNotCovered;
        if (region.isUsable()) return error.UsableReservationOverlap;
        cursor = @min(region_end, end);
        if (cursor == end) return;
    }
    return error.ReservationNotCovered;
}

fn nonEmptyEnd(range: PhysicalRange) BootInfoError!u64 {
    if (range.length == 0) return error.EmptyRange;
    return range.endExclusive();
}

comptime {
    if (@import("builtin").target.cpu.arch.endian() != .little)
        @compileError("The proposed boot protocol currently supports little-endian targets only");
    // These assertions run for every build target, not only during unit tests.
    if (@sizeOf(Header) != 24 or @alignOf(Header) != 8 or
        @offsetOf(Header, "magic_value") != 0 or
        @offsetOf(Header, "major") != 8 or
        @offsetOf(Header, "minor") != 10 or
        @offsetOf(Header, "header_size") != 12 or
        @offsetOf(Header, "architecture") != 16 or
        @offsetOf(Header, "reserved") != 20)
        @compileError("Header ABI layout changed");
    if (@sizeOf(PhysicalRange) != 16 or @alignOf(PhysicalRange) != 8 or
        @offsetOf(PhysicalRange, "base") != 0 or
        @offsetOf(PhysicalRange, "length") != 8)
        @compileError("PhysicalRange ABI layout changed");
    if (@sizeOf(MemoryRegion) != 24 or @alignOf(MemoryRegion) != 8 or
        @offsetOf(MemoryRegion, "range") != 0 or
        @offsetOf(MemoryRegion, "kind") != 16 or
        @offsetOf(MemoryRegion, "attributes") != 20)
        @compileError("MemoryRegion ABI layout changed");
    if (@sizeOf(Console) != 32 or @alignOf(Console) != 8 or
        @offsetOf(Console, "kind") != 0 or @offsetOf(Console, "register_stride") != 4 or
        @offsetOf(Console, "base") != 8 or @offsetOf(Console, "clock_hz") != 16 or
        @offsetOf(Console, "baud_rate") != 20 or @offsetOf(Console, "reserved") != 24)
        @compileError("Console ABI layout changed");
    if (@sizeOf(Framebuffer) != 48 or @alignOf(Framebuffer) != 8 or
        @offsetOf(Framebuffer, "base") != 0 or @offsetOf(Framebuffer, "size") != 8 or
        @offsetOf(Framebuffer, "width") != 16 or @offsetOf(Framebuffer, "height") != 20 or
        @offsetOf(Framebuffer, "pixels_per_scanline") != 24 or @offsetOf(Framebuffer, "format") != 28 or
        @offsetOf(Framebuffer, "red_mask") != 32 or @offsetOf(Framebuffer, "green_mask") != 36 or
        @offsetOf(Framebuffer, "blue_mask") != 40 or @offsetOf(Framebuffer, "reserved") != 44)
        @compileError("Framebuffer ABI layout changed");
    if (@sizeOf(BootInfo) != 2816 or @alignOf(BootInfo) != 8 or
        @offsetOf(BootInfo, "header") != 0 or
        @offsetOf(BootInfo, "uart_base") != 24 or
        @offsetOf(BootInfo, "dtb") != 32 or
        @offsetOf(BootInfo, "kernel_image") != 48 or
        @offsetOf(BootInfo, "ram") != 64 or
        @offsetOf(BootInfo, "loader_reserved") != 80 or
        @offsetOf(BootInfo, "kernel_reserved") != 96 or
        @offsetOf(BootInfo, "flags") != 112 or
        @offsetOf(BootInfo, "memory_region_count") != 120 or
        @offsetOf(BootInfo, "memory_map_reserved") != 124 or
        @offsetOf(BootInfo, "memory_regions") != 128 or
        @offsetOf(BootInfo, "console") != 1664 or
        @offsetOf(BootInfo, "boot_environment") != 1696 or
        @offsetOf(BootInfo, "entry_state") != 1700 or
        @offsetOf(BootInfo, "acpi_rsdp") != 1704 or
        @offsetOf(BootInfo, "framebuffer") != 1712 or
        @offsetOf(BootInfo, "firmware_memory_map") != 1760 or
        @offsetOf(BootInfo, "firmware_descriptor_size") != 1776 or
        @offsetOf(BootInfo, "firmware_descriptor_version") != 1780 or
        @offsetOf(BootInfo, "mapped_range_count") != 1784 or
        @offsetOf(BootInfo, "physical_address_bits") != 1788 or
        @offsetOf(BootInfo, "mapped_ranges") != 1792)
        @compileError("BootInfo ABI layout changed");
}

test "headers validate for each launch architecture" {
    inline for (.{ Architecture.x86_64, Architecture.aarch64, Architecture.riscv64 }) |arch| {
        try Header.init(arch).validate(@sizeOf(Header), arch);
    }
}

test "invalid magic and unsupported major versions are rejected" {
    var header = Header.init(.x86_64);
    header.magic_value ^= 1;
    try std.testing.expectError(error.InvalidMagic, header.validate(24, .x86_64));
    header = Header.init(.x86_64);
    header.major = version_major + 1;
    try std.testing.expectError(error.UnsupportedMajorVersion, header.validate(24, .x86_64));
    header.major = std.math.maxInt(u16);
    try std.testing.expectError(error.UnsupportedMajorVersion, header.validate(24, .x86_64));
}

test "architecture mismatch and unknown numeric tags are rejected" {
    var header = Header.init(.aarch64);
    try std.testing.expectError(error.ArchitectureMismatch, header.validate(24, .riscv64));
    header.architecture = std.math.maxInt(u32);
    try std.testing.expectError(error.ArchitectureMismatch, header.validate(24, .aarch64));
}

test "short declared headers and inaccessible header bytes are rejected" {
    var header = Header.init(.riscv64);
    header.header_size = 23;
    try std.testing.expectError(error.HeaderTooSmall, header.validate(24, .riscv64));
    header = Header.init(.riscv64);
    try std.testing.expectError(error.HeaderTruncated, header.validate(23, .riscv64));
    header.header_size = 32;
    try std.testing.expectError(error.HeaderTruncated, header.validate(31, .riscv64));
}

test "future minor and longer accessible headers are accepted" {
    var header = Header.init(.x86_64);
    header.minor = std.math.maxInt(u16);
    try header.validate(24, .x86_64);
    header.header_size = 64;
    try header.validate(64, .x86_64);
}

test "reserved prefix fields must remain zero within the draft major version" {
    var header = Header.init(.x86_64);
    header.reserved = 1;
    try std.testing.expectError(error.NonZeroReserved, header.validate(24, .x86_64));
}

test "physical ranges check exclusive end at the address-space boundary" {
    try std.testing.expectEqual(@as(u64, 0), try (PhysicalRange{ .base = 0, .length = 0 }).endExclusive());
    try std.testing.expectEqual(@as(u64, 0x3000), try (PhysicalRange{ .base = 0x1000, .length = 0x2000 }).endExclusive());
    const max = std.math.maxInt(u64);
    try std.testing.expectEqual(max, try (PhysicalRange{ .base = max, .length = 0 }).endExclusive());
    try std.testing.expectEqual(max, try (PhysicalRange{ .base = max - 1, .length = 1 }).endExclusive());
    try std.testing.expectError(error.PhysicalRangeOverflow, (PhysicalRange{ .base = max, .length = 1 }).endExclusive());
    try std.testing.expectError(error.PhysicalRangeOverflow, (PhysicalRange{ .base = 1, .length = max }).endExclusive());
}

fn sampleBootInfo() BootInfo {
    var header = Header.init(.aarch64);
    header.header_size = @sizeOf(BootInfo);
    var info: BootInfo = .{
        .header = header,
        .uart_base = 0x09000000,
        .dtb = .{ .base = 0x40000000, .length = 0x10000 },
        .kernel_image = .{ .base = 0x40200000, .length = 0x10000 },
        .ram = .{ .base = 0x40000000, .length = 0x08000000 },
        .loader_reserved = .{ .base = 0x40000000, .length = 0x200000 },
        .kernel_reserved = .{ .base = 0x40200000, .length = 0x200000 },
        .flags = 0,
        .console = .{ .kind = @backingInt(ConsoleKind.pl011), .register_stride = 4, .base = 0x09000000, .clock_hz = 24000000 },
        .entry_state = @backingInt(EntryState.aarch64_el1),
    };
    var map: MemoryMap = .{};
    map.addRam(info.ram) catch unreachable;
    map.addReservation(info.loader_reserved, .loader_reclaimable) catch unreachable;
    map.addReservation(info.kernel_reserved, .kernel) catch unreachable;
    map.finalize(&info) catch unreachable;
    return info;
}

test "boot handoff validates bounds and rejects incomplete records" {
    var info = sampleBootInfo();
    try info.validate(@sizeOf(BootInfo), .aarch64);
    try std.testing.expectError(error.HeaderTruncated, info.validate(@sizeOf(BootInfo) - 1, .aarch64));
    info.header.header_size = @sizeOf(Header);
    try std.testing.expectError(error.HeaderTooSmall, info.validate(@sizeOf(BootInfo), .aarch64));
}

test "boot handoff rejects overflowing and overlapping memory reservations" {
    var info = sampleBootInfo();
    info.kernel_reserved.base = 0x40100000;
    try std.testing.expectError(error.OverlappingReservations, info.validate(@sizeOf(BootInfo), .aarch64));
    info = sampleBootInfo();
    info.ram.length = std.math.maxInt(u64);
    try std.testing.expectError(error.PhysicalRangeOverflow, info.validate(@sizeOf(BootInfo), .aarch64));
    info = sampleBootInfo();
    info.kernel_reserved.base = 0x48000000;
    try std.testing.expectError(error.RangeOutsideRam, info.validate(@sizeOf(BootInfo), .aarch64));
}

test "boot handoff keeps loaded bytes and DTB inside their owning reservations" {
    var info = sampleBootInfo();
    info.dtb.length = 0x200001;
    try std.testing.expectError(error.DtbOutsideLoader, info.validate(@sizeOf(BootInfo), .aarch64));
    info = sampleBootInfo();
    info.kernel_image.length = 0x200001;
    try std.testing.expectError(error.KernelOutsideReservation, info.validate(@sizeOf(BootInfo), .aarch64));
    info = sampleBootInfo();
    info.kernel_image.length = 0;
    try std.testing.expectError(error.EmptyRange, info.validate(@sizeOf(BootInfo), .aarch64));
}

test "reset handoff requires a DTB unless x86-64 or ACPI describes the platform" {
    var info = sampleBootInfo();
    info.dtb = .{ .base = 0, .length = 0 };
    try std.testing.expectError(error.EmptyRange, info.validate(@sizeOf(BootInfo), .aarch64));
    info.header.architecture = @backingInt(Architecture.riscv64);
    info.entry_state = @backingInt(EntryState.riscv64_m);
    try std.testing.expectError(error.EmptyRange, info.validate(@sizeOf(BootInfo), .riscv64));
    info.header.architecture = @backingInt(Architecture.x86_64);
    info.entry_state = @backingInt(EntryState.x86_64_long_mode);
    try info.validate(@sizeOf(BootInfo), .x86_64);
    info.dtb.base = 1;
    try std.testing.expectError(error.InvalidDtb, info.validate(@sizeOf(BootInfo), .x86_64));
    info = sampleBootInfo();
    info.dtb = .{ .base = 0, .length = 0 };
    info.acpi_rsdp = 0x44000000;
    try info.validate(@sizeOf(BootInfo), .aarch64);
}

test "maps reject malformed counts reserved fields attributes and ranges" {
    var info = sampleBootInfo();
    info.memory_region_count = 0;
    try std.testing.expectError(error.InvalidMemoryRegionCount, info.validate(@sizeOf(BootInfo), .aarch64));
    info.memory_region_count = max_memory_regions + 1;
    try std.testing.expectError(error.InvalidMemoryRegionCount, info.validate(@sizeOf(BootInfo), .aarch64));
    info = sampleBootInfo();
    info.memory_map_reserved = 1;
    try std.testing.expectError(error.NonZeroReserved, info.validate(@sizeOf(BootInfo), .aarch64));
    info = sampleBootInfo();
    info.memory_regions[0].attributes = 1;
    try std.testing.expectError(error.InvalidMemoryRegionAttributes, info.validate(@sizeOf(BootInfo), .aarch64));
    info = sampleBootInfo();
    info.memory_regions[0].range.length = 0;
    try std.testing.expectError(error.EmptyRange, info.validate(@sizeOf(BootInfo), .aarch64));
    info = sampleBootInfo();
    info.memory_regions[2].range = .{ .base = std.math.maxInt(u64), .length = 1 };
    try std.testing.expectError(error.PhysicalRangeOverflow, info.validate(@sizeOf(BootInfo), .aarch64));
}

test "maps reject overlaps gaps and usable reservations but accept unknown reserved kinds" {
    var info = sampleBootInfo();
    info.memory_regions[1].range.base -= 1;
    try std.testing.expectError(error.UnsortedMemoryMap, info.validate(@sizeOf(BootInfo), .aarch64));
    info = sampleBootInfo();
    info.memory_regions[0].range.base += 1;
    info.memory_regions[0].range.length -= 1;
    try std.testing.expectError(error.ReservationNotCovered, info.validate(@sizeOf(BootInfo), .aarch64));
    info = sampleBootInfo();
    info.memory_regions[1].kind = @backingInt(MemoryKind.usable);
    try std.testing.expectError(error.UsableReservationOverlap, info.validate(@sizeOf(BootInfo), .aarch64));
    info = sampleBootInfo();
    info.memory_regions[0].kind = 0xfedcba98;
    info.memory_regions[1].kind = 0xffffffff;
    try std.testing.expect(!info.memory_regions[0].isUsable());
    try info.validate(@sizeOf(BootInfo), .aarch64);
}

test "builder normalizes unordered banks conservatively splits overlaps and includes outside MMIO" {
    var map: MemoryMap = .{};
    try map.addRam(.{ .base = 0x10000, .length = 0x1000 });
    try map.addRam(.{ .base = 0x1000, .length = 0x8000 });
    try map.addReservation(.{ .base = 0x5000, .length = 0x2000 }, .kernel);
    try map.addReservation(.{ .base = 0x4000, .length = 0x2000 }, .reserved);
    try map.addReservation(.{ .base = 0xa000, .length = 0x1000 }, .mmio);
    var info = sampleBootInfo();
    const legacy_ram = info.ram;
    try map.finalize(&info);
    try std.testing.expectEqual(@as(u32, 6), info.memory_region_count);
    try std.testing.expectEqualDeep(legacy_ram, info.ram);
    try std.testing.expectEqualDeep(MemoryRegion{ .range = .{ .base = 0x1000, .length = 0x3000 }, .kind = @backingInt(MemoryKind.usable), .attributes = 0 }, info.memory_regions[0]);
    try std.testing.expectEqualDeep(MemoryRegion{ .range = .{ .base = 0x4000, .length = 0x2000 }, .kind = @backingInt(MemoryKind.reserved), .attributes = 0 }, info.memory_regions[1]);
    try std.testing.expectEqualDeep(MemoryRegion{ .range = .{ .base = 0x6000, .length = 0x1000 }, .kind = @backingInt(MemoryKind.kernel), .attributes = 0 }, info.memory_regions[2]);
    try std.testing.expectEqual(@backingInt(MemoryKind.mmio), info.memory_regions[4].kind);
    try std.testing.expectEqualDeep(empty_memory_region, info.memory_regions[6]);
}

test "builder bounds input and output capacity and leaves handoff unchanged on failure" {
    var map: MemoryMap = .{};
    try map.addRam(.{ .base = 0x1000, .length = 0x1000 });
    try std.testing.expectError(error.OverlappingRam, map.addRam(.{ .base = 0x1800, .length = 0x1000 }));
    try std.testing.expectError(error.EmptyRange, map.addRam(.{ .base = 0, .length = 0 }));
    try std.testing.expectError(error.PhysicalRangeOverflow, map.addRam(.{ .base = std.math.maxInt(u64), .length = 1 }));
    try std.testing.expectError(error.InvalidReservationKind, map.addReservation(.{ .base = 0x1000, .length = 1 }, .usable));
    map.reset();
    var info = sampleBootInfo();
    try std.testing.expectError(error.NoRam, map.finalize(&info));
    try map.addRam(.{ .base = 0x1000, .length = 0x1000 });
    for (0..max_memory_regions) |index| try map.addReservation(.{ .base = 0x1001 + index * 2, .length = 1 }, .reserved);
    try std.testing.expectError(error.TooManyInputs, map.addReservation(.{ .base = 0x2000, .length = 1 }, .reserved));
    const before = info;
    try std.testing.expectError(error.TooManyRegions, map.finalize(&info));
    try std.testing.expectEqualDeep(before, info);
}

test "console validates supported layouts baud rates port ranges and serial divider bounds" {
    try (Console{}).validate();
    try (Console{ .kind = @backingInt(ConsoleKind.ns16550_io), .base = 0x3f8 }).validate();
    inline for (.{ 1, 2, 4, 8 }) |stride| try (Console{ .kind = @backingInt(ConsoleKind.ns16550_mmio), .base = 0x10000000, .register_stride = stride }).validate();
    var console = sampleBootInfo().console;
    try console.validate();
    console.clock_hz = 1;
    try std.testing.expectError(error.InvalidConsole, console.validate());
    console.clock_hz = std.math.maxInt(u32);
    console.baud_rate = 1;
    try std.testing.expectError(error.InvalidConsole, console.validate());
    console = .{ .kind = @backingInt(ConsoleKind.ns16550_io), .base = 65529 };
    try std.testing.expectError(error.InvalidConsole, console.validate());
    console = .{ .kind = @backingInt(ConsoleKind.ns16550_mmio), .base = 0x10000000, .register_stride = 3 };
    try std.testing.expectError(error.InvalidConsole, console.validate());
    console.register_stride = 1;
    console.baud_rate = 0;
    try std.testing.expectError(error.InvalidConsole, console.validate());
    console = .{ .kind = 999 };
    try std.testing.expectError(error.InvalidConsole, console.validate());
    console = .{ .reserved = 1 };
    try std.testing.expectError(error.InvalidConsole, console.validate());
    console = .{ .kind = @backingInt(ConsoleKind.ns16550_mmio), .base = std.math.maxInt(u64) - 7 };
    try std.testing.expectError(error.InvalidConsole, console.validate());
    inline for (.{ ConsoleKind.ns16550_mmio, ConsoleKind.ns16550_io }) |kind| {
        console = .{ .kind = @backingInt(kind), .base = 0x3f8, .clock_hz = 1 };
        try std.testing.expectError(error.InvalidConsole, console.validate());
        console.clock_hz = std.math.maxInt(u32);
        console.baud_rate = 1;
        try std.testing.expectError(error.InvalidConsole, console.validate());
        console.clock_hz = 16;
        try console.validate();
        console.clock_hz = 16 * 65535;
        try console.validate();
        console.clock_hz = 16 * 65536;
        try std.testing.expectError(error.InvalidConsole, console.validate());
    }
    var info = sampleBootInfo();
    info.uart_base += 4;
    try std.testing.expectError(error.InvalidUart, info.validate(@sizeOf(BootInfo), .aarch64));
}

test "entry state and boot environment reject unknown or incompatible numeric tags" {
    var info = sampleBootInfo();
    info.entry_state = @backingInt(EntryState.x86_64_long_mode);
    try std.testing.expectError(error.InvalidEntryState, info.validate(@sizeOf(BootInfo), .aarch64));
    info.entry_state = 0;
    try std.testing.expectError(error.InvalidEntryState, info.validate(@sizeOf(BootInfo), .aarch64));
    info = sampleBootInfo();
    info.boot_environment = 999;
    try std.testing.expectError(error.InvalidBootEnvironment, info.validate(@sizeOf(BootInfo), .aarch64));
    info = sampleBootInfo();
    info.header.architecture = @backingInt(Architecture.riscv64);
    info.entry_state = @backingInt(EntryState.riscv64_s);
    try info.validate(@sizeOf(BootInfo), .riscv64);
}

fn sampleFramebuffer() Framebuffer {
    return .{ .base = 0xe0000000, .size = 768, .width = 8, .height = 12, .pixels_per_scanline = 16, .format = 1, .red_mask = 0xff0000, .green_mask = 0xff00, .blue_mask = 0xff };
}

test "framebuffer checks geometry masks byte coverage physical overflow and arena collisions" {
    try (Framebuffer{}).validate();
    var fb = sampleFramebuffer();
    try fb.validate();
    fb.width = 7;
    try std.testing.expectError(error.InvalidFramebuffer, fb.validate());
    fb = sampleFramebuffer();
    fb.height = 11;
    try std.testing.expectError(error.InvalidFramebuffer, fb.validate());
    fb = sampleFramebuffer();
    fb.base += 1;
    try std.testing.expectError(error.InvalidFramebuffer, fb.validate());
    fb = sampleFramebuffer();
    fb.reserved = 1;
    try std.testing.expectError(error.InvalidFramebuffer, fb.validate());
    fb = sampleFramebuffer();
    fb.format = 2;
    try std.testing.expectError(error.InvalidFramebuffer, fb.validate());
    fb = sampleFramebuffer();
    fb.size -= 1;
    try std.testing.expectError(error.InvalidFramebuffer, fb.validate());
    fb = sampleFramebuffer();
    fb.pixels_per_scanline = fb.width - 1;
    try std.testing.expectError(error.InvalidFramebuffer, fb.validate());
    fb = sampleFramebuffer();
    fb.green_mask = fb.red_mask;
    try std.testing.expectError(error.InvalidFramebuffer, fb.validate());
    fb = sampleFramebuffer();
    fb.blue_mask = 0;
    try std.testing.expectError(error.InvalidFramebuffer, fb.validate());
    fb = sampleFramebuffer();
    fb.base = std.math.maxInt(u64) - 3;
    try std.testing.expectError(error.PhysicalRangeOverflow, fb.validate());
    fb = sampleFramebuffer();
    fb.height = std.math.maxInt(u32);
    fb.pixels_per_scanline = std.math.maxInt(u32);
    fb.size = std.math.maxInt(u64);
    try std.testing.expectError(error.PhysicalRangeOverflow, fb.validate());
    var info = sampleBootInfo();
    info.framebuffer = sampleFramebuffer();
    info.console = .{ .kind = @backingInt(ConsoleKind.framebuffer), .base = info.framebuffer.base };
    info.uart_base = 0;
    try info.validate(@sizeOf(BootInfo), .aarch64);
    info.console.base += 4;
    try std.testing.expectError(error.InvalidFramebuffer, info.validate(@sizeOf(BootInfo), .aarch64));
    info.console = .{};
    info.framebuffer.base = info.loader_reserved.base;
    try std.testing.expectError(error.FramebufferOverlapsReservations, info.validate(@sizeOf(BootInfo), .aarch64));
}

test "UEFI requires retained bounded descriptor metadata while reset requires it absent" {
    var info = sampleBootInfo();
    info.boot_environment = @backingInt(BootEnvironment.uefi);
    var coverage = try MappedRanges.init(48);
    try coverage.add(.{ .base = 0, .length = @as(u64, 1) << 48 });
    coverage.finalize(&info);
    try std.testing.expectError(error.InvalidFirmwareMemoryMap, info.validate(@sizeOf(BootInfo), .aarch64));
    info.firmware_memory_map = .{ .base = info.loader_reserved.base + 0x10000, .length = 80 };
    info.firmware_descriptor_size = 40;
    info.firmware_descriptor_version = 1;
    info.dtb = .{ .base = 0, .length = 0 };
    try info.validate(@sizeOf(BootInfo), .aarch64);
    info.firmware_memory_map.length = 79;
    try std.testing.expectError(error.InvalidFirmwareMemoryMap, info.validate(@sizeOf(BootInfo), .aarch64));
    info.firmware_memory_map.length = 80;
    info.firmware_descriptor_size = 39;
    try std.testing.expectError(error.InvalidFirmwareMemoryMap, info.validate(@sizeOf(BootInfo), .aarch64));
    info.firmware_descriptor_size = 40;
    info.firmware_descriptor_version = 0;
    try std.testing.expectError(error.InvalidFirmwareMemoryMap, info.validate(@sizeOf(BootInfo), .aarch64));
    info.firmware_descriptor_version = 1;
    info.firmware_memory_map.base = info.loader_reserved.base + info.loader_reserved.length;
    try std.testing.expectError(error.InvalidFirmwareMemoryMap, info.validate(@sizeOf(BootInfo), .aarch64));
    info.firmware_memory_map.base = std.math.maxInt(u64) - 39;
    try std.testing.expectError(error.PhysicalRangeOverflow, info.validate(@sizeOf(BootInfo), .aarch64));
    info.firmware_memory_map.base = info.loader_reserved.base;
    info.boot_environment = @backingInt(BootEnvironment.reset_firmware);
    info.dtb = sampleBootInfo().dtb;
    try std.testing.expectError(error.InvalidFirmwareMemoryMap, info.validate(@sizeOf(BootInfo), .aarch64));
}

fn sampleUefiInfo() BootInfo {
    var info = sampleBootInfo();
    info.boot_environment = @backingInt(BootEnvironment.uefi);
    info.firmware_memory_map = .{ .base = info.loader_reserved.base + 0x10000, .length = 80 };
    info.firmware_descriptor_size = 40;
    info.firmware_descriptor_version = 1;
    info.physical_address_bits = 48;
    info.mapped_range_count = 3;
    info.mapped_ranges[0] = .{ .base = info.console.base, .length = 0x1000 };
    info.mapped_ranges[1] = info.loader_reserved;
    info.mapped_ranges[2] = info.kernel_reserved;
    return info;
}

test "sparse mappings cover required references without claiming usable holes" {
    var info = sampleUefiInfo();
    try info.validate(@sizeOf(BootInfo), .aarch64);
    try std.testing.expect(info.isMapped(info.loader_reserved));
    try std.testing.expect(info.isMapped(.{ .base = 0x401ff000, .length = 0x2000 }));
    try std.testing.expect(!info.isMapped(.{ .base = 0x10000000, .length = 0x1000 }));
    try std.testing.expect(!info.isMapped(.{ .base = 0x40400000, .length = 0x1000 }));
    try std.testing.expect(!info.isMapped(.{ .base = 0x40000000, .length = 0 }));
    info.mapped_ranges[0].base += 4;
    try std.testing.expectError(error.RequiredRangeNotMapped, info.validate(@sizeOf(BootInfo), .aarch64));
    info = sampleUefiInfo();
    info.mapped_ranges[1].length -= 1;
    try std.testing.expectError(error.RequiredRangeNotMapped, info.validate(@sizeOf(BootInfo), .aarch64));
    info = sampleUefiInfo();
    info.framebuffer = sampleFramebuffer();
    info.console = .{ .kind = @backingInt(ConsoleKind.framebuffer), .base = info.framebuffer.base };
    info.uart_base = 0;
    try std.testing.expectError(error.RequiredRangeNotMapped, info.validate(@sizeOf(BootInfo), .aarch64));
}

test "mapped range counts sorting extents and physical width are bounded" {
    var info = sampleUefiInfo();
    info.mapped_range_count = 0;
    try std.testing.expectError(error.InvalidMappedRangeCount, info.validate(@sizeOf(BootInfo), .aarch64));
    info.mapped_range_count = max_mapped_ranges + 1;
    try std.testing.expectError(error.InvalidMappedRangeCount, info.validate(@sizeOf(BootInfo), .aarch64));
    try std.testing.expect(!info.isMapped(info.loader_reserved));
    inline for (.{ 0, 31, 65 }) |bits| {
        info = sampleUefiInfo();
        info.physical_address_bits = bits;
        try std.testing.expectError(error.InvalidPhysicalAddressBits, info.validate(@sizeOf(BootInfo), .aarch64));
    }
    info = sampleUefiInfo();
    info.physical_address_bits = 64;
    try info.validate(@sizeOf(BootInfo), .aarch64);
    info = sampleUefiInfo();
    info.mapped_ranges[2].base -= 1;
    try std.testing.expectError(error.UnsortedMappedRanges, info.validate(@sizeOf(BootInfo), .aarch64));
    info = sampleUefiInfo();
    info.mapped_ranges[0].length = 0;
    try std.testing.expectError(error.EmptyRange, info.validate(@sizeOf(BootInfo), .aarch64));
    info = sampleUefiInfo();
    info.mapped_ranges[2] = .{ .base = std.math.maxInt(u64), .length = 1 };
    try std.testing.expectError(error.PhysicalRangeOverflow, info.validate(@sizeOf(BootInfo), .aarch64));
    info = sampleUefiInfo();
    info.physical_address_bits = 32;
    info.mapped_range_count = 4;
    info.mapped_ranges[3] = .{ .base = @as(u64, 1) << 32, .length = 4096 };
    try std.testing.expectError(error.InvalidMappedRange, info.validate(@sizeOf(BootInfo), .aarch64));
}

test "legacy reset mapping metadata is wholly absent and never inferred" {
    var info = sampleBootInfo();
    try info.validate(@sizeOf(BootInfo), .aarch64);
    try std.testing.expect(!info.isMapped(info.kernel_reserved));
    info.physical_address_bits = 48;
    try std.testing.expectError(error.InvalidPhysicalAddressBits, info.validate(@sizeOf(BootInfo), .aarch64));
    info = sampleBootInfo();
    info.mapped_ranges[63].base = 1;
    try std.testing.expectError(error.InvalidMappedRange, info.validate(@sizeOf(BootInfo), .aarch64));
}

test "mapped range builder merges unordered overlapping and adjacent extents atomically" {
    try std.testing.expectError(error.InvalidPhysicalAddressBits, MappedRanges.init(31));
    var coverage = try MappedRanges.init(32);
    try coverage.add(.{ .base = 0x3000, .length = 0x1000 });
    try coverage.add(.{ .base = 0x1000, .length = 0x1000 });
    try coverage.add(.{ .base = 0x2000, .length = 0x1800 });
    try std.testing.expectEqual(@as(usize, 1), coverage.count);
    try std.testing.expectEqualDeep(PhysicalRange{ .base = 0x1000, .length = 0x3000 }, coverage.ranges[0]);
    try std.testing.expectError(error.InvalidMappedRange, coverage.add(.{ .base = @as(u64, 1) << 32, .length = 1 }));
    coverage = try MappedRanges.init(64);
    for (0..max_mapped_ranges) |index| try coverage.add(.{ .base = index * 8192, .length = 4096 });
    const before = coverage;
    try std.testing.expectError(error.TooManyMappedRanges, coverage.add(.{ .base = max_mapped_ranges * 8192, .length = 4096 }));
    try std.testing.expectEqualDeep(before, coverage);
    try coverage.add(.{ .base = 4096, .length = 4096 });
    try std.testing.expectEqual(@as(usize, max_mapped_ranges - 1), coverage.count);
}
