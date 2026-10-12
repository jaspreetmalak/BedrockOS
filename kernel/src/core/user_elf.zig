//! Bounded first-profile native ELF64 executables. Inspection never writes RAM.
//! One RX code/rodata page and one RW data/BSS page; stack is supplied separately.
const std = @import("std");
// The inspector is portable and has no dependency on runtime module instances.
pub const code_address: u64 = 0x20_0000_0000;
pub const data_address: u64 = code_address + page_size;
pub const page_size: u64 = 4096;
pub const max_segments = 2;
const max_program_headers = 16;
const max_section_headers = 128;

pub const Error = error{
    TruncatedImage,
    InvalidElf,
    WrongArchitecture,
    UnsupportedImage,
    TooManySegments,
    InvalidSegment,
    SegmentOverlap,
    UnsupportedAddressRange,
    MissingCodeSegment,
    MissingDataSegment,
    InvalidEntry,
    AddressOverflow,
};

pub const Segment = struct {
    offset: u64,
    address: u64,
    file_size: u64,
    memory_size: u64,
    flags: u32,
};

pub const Image = struct {
    entry: u64,
    segments: [max_segments]Segment,
    count: usize,
};

fn end(base: u64, length: u64) Error!u64 {
    const value = @addWithOverflow(base, length);
    if (value[1] != 0) return error.AddressOverflow;
    return value[0];
}

fn field(comptime T: type, bytes: []const u8, offset: u64) Error!T {
    if (try end(offset, @sizeOf(T)) > bytes.len) return error.TruncatedImage;
    return std.mem.readInt(T, bytes[@intCast(offset)..][0..@sizeOf(T)], .little);
}

fn machine(arch: std.Target.Cpu.Arch) Error!u16 {
    return switch (arch) {
        .x86_64 => 62,
        .aarch64 => 183,
        .riscv64 => 243,
        else => error.WrongArchitecture,
    };
}

fn sections(bytes: []const u8, image: *const Image) Error!void {
    const offset = try field(u64, bytes, 40);
    const size = try field(u16, bytes, 58);
    const count = try field(u16, bytes, 60);
    const names = try field(u16, bytes, 62);
    if (count == 0) {
        if (offset != 0 or names != 0 or (size != 0 and size != 64)) return error.InvalidElf;
        return;
    }
    if (count > max_section_headers or size != 64 or offset < 64 or offset % 8 != 0 or names >= count)
        return error.InvalidElf;
    if (try end(offset, @as(u64, count) * 64) > bytes.len) return error.TruncatedImage;
    if (names != 0 and try field(u32, bytes, offset + @as(u64, names) * 64 + 4) != 3)
        return error.InvalidElf;
    for (0..count) |index| {
        const at = offset + index * 64;
        const kind = try field(u32, bytes, at + 4);
        const flags = try field(u64, bytes, at + 8);
        const address = try field(u64, bytes, at + 16);
        const file_offset = try field(u64, bytes, at + 24);
        const length = try field(u64, bytes, at + 32);
        // Static executables have no relocation, dynamic-symbol or TLS work.
        if (kind == 4 or kind == 6 or kind == 9 or kind == 11 or flags & 0x400 != 0)
            return error.UnsupportedImage;
        if (kind != 8 and try end(file_offset, length) > bytes.len) return error.TruncatedImage;
        if (flags & 2 == 0 or length == 0) continue;
        const limit = try end(address, length);
        var covered = false;
        for (image.segments[0..image.count]) |segment| {
            if (address < segment.address or limit > try end(segment.address, segment.memory_size)) continue;
            if (flags & 1 != 0 and segment.flags & 2 == 0 or
                flags & 4 != 0 and segment.flags & 1 == 0) return error.InvalidSegment;
            if (kind != 8) {
                if (limit > try end(segment.address, segment.file_size) or
                    file_offset != try end(segment.offset, address - segment.address))
                    return error.InvalidSegment;
            }
            covered = true;
            break;
        }
        if (!covered) return error.UnsupportedAddressRange;
    }
}

/// Validate the entire supported profile before the caller copies any bytes.
/// The caller must keep the inspected source immutable until copying finishes.
pub fn inspect(bytes: []const u8, arch: std.Target.Cpu.Arch) Error!Image {
    return inspectProfile(bytes, arch, false);
}

/// A trusted launcher chooses this separate, bounded desktop layout. The
/// executable cannot widen the ordinary process profile through its headers.
pub fn inspectDesktop(bytes: []const u8, arch: std.Target.Cpu.Arch) Error!Image {
    return inspectProfile(bytes, arch, true);
}

fn inspectProfile(bytes: []const u8, arch: std.Target.Cpu.Arch, desktop: bool) Error!Image {
    const code_base = if (desktop) code_address + 0x10000 else code_address;
    const data_base = if (desktop) code_address + 0x40000 else data_address;
    const code_bytes: u64 = if (desktop) 0x20000 else page_size;
    const data_bytes: u64 = if (desktop) 0x100000 else page_size;
    if (bytes.len < 64) return error.TruncatedImage;
    if (!std.mem.eql(u8, bytes[0..7], "\x7fELF\x02\x01\x01")) return error.InvalidElf;
    if (bytes[7] != 0 or bytes[8] != 0 or try field(u16, bytes, 16) != 2)
        return error.UnsupportedImage;
    for (bytes[9..16]) |padding| if (padding != 0) return error.InvalidElf;
    if (try field(u16, bytes, 18) != try machine(arch)) return error.WrongArchitecture;
    if (try field(u32, bytes, 20) != 1 or try field(u16, bytes, 52) != 64 or
        try field(u16, bytes, 54) != 56) return error.InvalidElf;
    const flags = try field(u32, bytes, 48);
    if (arch == .riscv64) {
        // Only the compressed-instruction flag; no floating-point ABI or RVE.
        if (flags & ~@as(u32, 1) != 0) return error.UnsupportedImage;
    } else if (flags != 0) return error.UnsupportedImage;
    const count = try field(u16, bytes, 56);
    if (count == 0 or count > max_program_headers) return error.TooManySegments;
    const phoff = try field(u64, bytes, 32);
    if (phoff < 64 or phoff % 8 != 0) return error.InvalidElf;
    if (try end(phoff, @as(u64, count) * 56) > bytes.len) return error.TruncatedImage;
    var image: Image = .{ .entry = try field(u64, bytes, 24), .segments = undefined, .count = 0 };
    if (arch == .aarch64 and image.entry % 4 != 0 or arch == .riscv64 and image.entry % 2 != 0)
        return error.InvalidEntry;
    var code_found = false;
    var data_found = false;
    var entry_found = false;
    for (0..count) |index| {
        const at = phoff + index * 56;
        const kind = try field(u32, bytes, at);
        if (kind == 0) continue;
        const segment: Segment = .{
            .flags = try field(u32, bytes, at + 4),
            .offset = try field(u64, bytes, at + 8),
            .address = try field(u64, bytes, at + 16),
            .file_size = try field(u64, bytes, at + 32),
            .memory_size = try field(u64, bytes, at + 40),
        };
        if (kind == 0x6474e551) { // Nonexecutable PT_GNU_STACK declaration only.
            if (segment.flags & ~@as(u32, 6) != 0 or segment.file_size != 0 or segment.memory_size != 0)
                return error.UnsupportedImage;
            continue;
        }
        if (kind != 1) return error.UnsupportedImage;
        if (image.count == max_segments) return error.TooManySegments;
        const physical_address = try field(u64, bytes, at + 24);
        const alignment = try field(u64, bytes, at + 48);
        const limit = try end(segment.address, segment.memory_size);
        if (segment.memory_size == 0 or segment.file_size > segment.memory_size or
            try end(segment.offset, segment.file_size) > bytes.len or physical_address != segment.address)
            return error.InvalidSegment;
        if (alignment > page_size or (alignment > 1 and
            (alignment & (alignment - 1) != 0 or segment.address % alignment != segment.offset % alignment)))
            return error.InvalidSegment;
        for (image.segments[0..image.count]) |previous| {
            if (segment.address < try end(previous.address, previous.memory_size) and previous.address < limit)
                return error.SegmentOverlap;
            if (segment.file_size != 0 and previous.file_size != 0 and
                segment.offset < try end(previous.offset, previous.file_size) and
                previous.offset < try end(segment.offset, segment.file_size)) return error.SegmentOverlap;
        }
        if (segment.address >= code_base and limit <= code_base + code_bytes) {
            if (code_found or segment.flags != 5 or segment.file_size == 0) return error.InvalidSegment;
            code_found = true;
            entry_found = image.entry >= segment.address and image.entry < try end(segment.address, segment.file_size);
        } else if (segment.address >= data_base and limit <= data_base + data_bytes) {
            if (data_found or segment.flags != 6) return error.InvalidSegment;
            data_found = true;
        } else return error.UnsupportedAddressRange;
        image.segments[image.count] = segment;
        image.count += 1;
    }
    if (!code_found) return error.MissingCodeSegment;
    if (!data_found) return error.MissingDataSegment;
    if (!entry_found) return error.InvalidEntry;
    try sections(bytes, &image);
    return image;
}

fn put(comptime T: type, bytes: []u8, offset: usize, value: T) void {
    std.mem.writeInt(T, bytes[offset..][0..@sizeOf(T)], value, .little);
}

test "desktop ELF profile is explicit bounded and keeps code read-only" {
    const t = std.testing;
    var bytes = fixture(.x86_64);
    const code_base = code_address + 0x10000;
    const data_base = code_address + 0x40000;
    put(u64, &bytes, 24, code_base);
    put(u64, &bytes, 80, code_base);
    put(u64, &bytes, 88, code_base);
    put(u64, &bytes, 136, data_base);
    put(u64, &bytes, 144, data_base);
    put(u64, &bytes, 104, 0x20000);
    put(u64, &bytes, 160, 0x100000);
    _ = try inspectDesktop(&bytes, .x86_64);
    try t.expectError(error.UnsupportedAddressRange, inspect(&bytes, .x86_64));
    put(u64, &bytes, 104, 0x20001);
    try t.expectError(error.UnsupportedAddressRange, inspectDesktop(&bytes, .x86_64));
    put(u64, &bytes, 104, 0x20000);
    put(u32, &bytes, 68, 7);
    try t.expectError(error.InvalidSegment, inspectDesktop(&bytes, .x86_64));
}

fn fixture(arch: std.Target.Cpu.Arch) [2048]u8 {
    var bytes: [2048]u8 = @splat(0);
    @memcpy(bytes[0..7], "\x7fELF\x02\x01\x01");
    put(u16, &bytes, 16, 2);
    put(u16, &bytes, 18, machine(arch) catch unreachable);
    put(u32, &bytes, 20, 1);
    put(u64, &bytes, 24, code_address + 16);
    put(u64, &bytes, 32, 64);
    put(u16, &bytes, 52, 64);
    put(u16, &bytes, 54, 56);
    put(u16, &bytes, 56, 2);
    for (0..2) |index| {
        const at = 64 + index * 56;
        const address = if (index == 0) code_address else data_address;
        put(u32, &bytes, at, 1);
        put(u32, &bytes, at + 4, if (index == 0) 5 else 6);
        put(u64, &bytes, at + 8, if (index == 0) 256 else 1024);
        put(u64, &bytes, at + 16, address);
        put(u64, &bytes, at + 24, address);
        put(u64, &bytes, at + 32, if (index == 0) 128 else 8);
        put(u64, &bytes, at + 40, if (index == 0) 256 else 64);
        put(u64, &bytes, at + 48, 256);
    }
    return bytes;
}

test "bounded executables retain exact segment and nonzero entry offsets on each ISA" {
    for ([_]std.Target.Cpu.Arch{ .x86_64, .aarch64, .riscv64 }) |arch| {
        var bytes = fixture(arch);
        if (arch == .riscv64) put(u32, &bytes, 48, 1);
        const image = try inspect(&bytes, arch);
        try std.testing.expectEqual(code_address + 16, image.entry);
        try std.testing.expectEqual(@as(usize, 2), image.count);
        try std.testing.expectEqual(@as(u64, 8), image.segments[1].file_size);
        try std.testing.expectEqual(@as(u64, 64), image.segments[1].memory_size);
        // The caller must retain an accepted LOAD's offset within its page.
        for (0..2) |index| {
            const at = 64 + index * 56;
            const address = (if (index == 0) code_address else data_address) + 16;
            put(u64, &bytes, at + 16, address);
            put(u64, &bytes, at + 24, address);
            put(u64, &bytes, at + 48, 1);
        }
        put(u64, &bytes, 24, code_address + 32);
        const shifted = try inspect(&bytes, arch);
        try std.testing.expectEqual(code_address + 32, shifted.entry);
        try std.testing.expectEqual(code_address + 16, shifted.segments[0].address);
        try std.testing.expectEqual(data_address + 16, shifted.segments[1].address);
    }
}

test "headers reject truncation, wrong architecture, format and extended table counts" {
    var bytes = fixture(.x86_64);
    try std.testing.expectError(error.TruncatedImage, inspect(bytes[0..63], .x86_64));
    try std.testing.expectError(error.WrongArchitecture, inspect(&bytes, .aarch64));
    bytes[5] = 2;
    try std.testing.expectError(error.InvalidElf, inspect(&bytes, .x86_64));
    bytes = fixture(.x86_64);
    put(u16, &bytes, 16, 3);
    try std.testing.expectError(error.UnsupportedImage, inspect(&bytes, .x86_64));
    bytes = fixture(.x86_64);
    put(u16, &bytes, 56, 0xffff);
    try std.testing.expectError(error.TooManySegments, inspect(&bytes, .x86_64));
    bytes = fixture(.x86_64);
    put(u64, &bytes, 32, 2040);
    try std.testing.expectError(error.TruncatedImage, inspect(&bytes, .x86_64));
}

test "entry must be file backed executable bytes with native instruction alignment" {
    var bytes = fixture(.x86_64);
    put(u64, &bytes, 24, code_address + 128);
    try std.testing.expectError(error.InvalidEntry, inspect(&bytes, .x86_64));
    put(u64, &bytes, 24, data_address);
    try std.testing.expectError(error.InvalidEntry, inspect(&bytes, .x86_64));
    bytes = fixture(.aarch64);
    put(u64, &bytes, 24, code_address + 2);
    try std.testing.expectError(error.InvalidEntry, inspect(&bytes, .aarch64));
    bytes = fixture(.riscv64);
    put(u64, &bytes, 24, code_address + 1);
    try std.testing.expectError(error.InvalidEntry, inspect(&bytes, .riscv64));
}

test "native architecture flags reject floating ABI and unsupported ISA variants" {
    var bytes = fixture(.riscv64);
    for ([_]u32{ 2, 4, 6, 8, 16 }) |flags| {
        put(u32, &bytes, 48, flags);
        try std.testing.expectError(error.UnsupportedImage, inspect(&bytes, .riscv64));
    }
    bytes = fixture(.aarch64);
    put(u32, &bytes, 48, 1);
    try std.testing.expectError(error.UnsupportedImage, inspect(&bytes, .aarch64));
}

test "dynamic interpreter TLS and executable-stack program headers are unsupported" {
    for ([_]u32{ 2, 3, 7, 4, 0x70000003 }) |kind| {
        var bytes = fixture(.x86_64);
        put(u16, &bytes, 56, 3);
        put(u32, &bytes, 176, kind);
        try std.testing.expectError(error.UnsupportedImage, inspect(&bytes, .x86_64));
    }
    var bytes = fixture(.x86_64);
    put(u16, &bytes, 56, 3);
    put(u32, &bytes, 176, 0x6474e551);
    put(u32, &bytes, 180, 6);
    _ = try inspect(&bytes, .x86_64);
    put(u32, &bytes, 180, 7);
    try std.testing.expectError(error.UnsupportedImage, inspect(&bytes, .x86_64));
}

test "load flags require exact RX and RW and reject writable executable leaves" {
    for ([_]u32{ 0, 1, 3, 4, 6, 7, 13 }) |flags| {
        var bytes = fixture(.x86_64);
        put(u32, &bytes, 68, flags);
        try std.testing.expectError(error.InvalidSegment, inspect(&bytes, .x86_64));
    }
    var bytes = fixture(.x86_64);
    put(u32, &bytes, 124, 5);
    try std.testing.expectError(error.InvalidSegment, inspect(&bytes, .x86_64));
}

test "segment bounds alignment and source offsets fail before a copy" {
    var bytes = fixture(.x86_64);
    put(u64, &bytes, 96, 257);
    try std.testing.expectError(error.InvalidSegment, inspect(&bytes, .x86_64));
    bytes = fixture(.x86_64);
    put(u64, &bytes, 72, 2048);
    try std.testing.expectError(error.InvalidSegment, inspect(&bytes, .x86_64));
    bytes = fixture(.x86_64);
    put(u64, &bytes, 112, 3);
    try std.testing.expectError(error.InvalidSegment, inspect(&bytes, .x86_64));
    bytes = fixture(.x86_64);
    put(u64, &bytes, 72, 257);
    try std.testing.expectError(error.InvalidSegment, inspect(&bytes, .x86_64));
    bytes = fixture(.x86_64);
    put(u64, &bytes, 88, 0);
    try std.testing.expectError(error.InvalidSegment, inspect(&bytes, .x86_64));
}

test "virtual overflow guard stack and outside-window mappings are rejected" {
    var bytes = fixture(.x86_64);
    put(u64, &bytes, 80, std.math.maxInt(u64) - 127);
    put(u64, &bytes, 88, std.math.maxInt(u64) - 127);
    try std.testing.expectError(error.AddressOverflow, inspect(&bytes, .x86_64));
    for ([_]u64{ 0, code_address + 2 * page_size, code_address + 3 * page_size, data_address + page_size - 32 }) |address| {
        bytes = fixture(.x86_64);
        put(u64, &bytes, 136, address);
        put(u64, &bytes, 144, address);
        put(u64, &bytes, 168, 1);
        try std.testing.expectError(error.UnsupportedAddressRange, inspect(&bytes, .x86_64));
    }
}

test "overlapping virtual or file-backed segments and missing pages are rejected" {
    var bytes = fixture(.x86_64);
    put(u64, &bytes, 136, code_address);
    put(u64, &bytes, 144, code_address);
    try std.testing.expectError(error.SegmentOverlap, inspect(&bytes, .x86_64));
    bytes = fixture(.x86_64);
    put(u64, &bytes, 128, 256);
    try std.testing.expectError(error.SegmentOverlap, inspect(&bytes, .x86_64));
    bytes = fixture(.x86_64);
    put(u32, &bytes, 120, 0);
    try std.testing.expectError(error.MissingDataSegment, inspect(&bytes, .x86_64));
    bytes = fixture(.x86_64);
    put(u32, &bytes, 64, 0);
    try std.testing.expectError(error.MissingCodeSegment, inspect(&bytes, .x86_64));
}

test "section metadata is bounded and cannot introduce TLS dynamic or relocation work" {
    var bytes = fixture(.x86_64);
    put(u64, &bytes, 40, 1536);
    put(u16, &bytes, 58, 64);
    put(u16, &bytes, 60, 2);
    _ = try inspect(&bytes, .x86_64);
    for ([_]u32{ 4, 6, 9, 11 }) |kind| {
        put(u32, &bytes, 1604, kind);
        try std.testing.expectError(error.UnsupportedImage, inspect(&bytes, .x86_64));
    }
    put(u32, &bytes, 1604, 1);
    put(u64, &bytes, 1608, 0x400);
    try std.testing.expectError(error.UnsupportedImage, inspect(&bytes, .x86_64));
    put(u64, &bytes, 1608, 0);
    put(u64, &bytes, 1624, 2048);
    put(u64, &bytes, 1632, 1);
    try std.testing.expectError(error.TruncatedImage, inspect(&bytes, .x86_64));
}

test "allocated section records must agree with load bytes and permissions" {
    var bytes = fixture(.x86_64);
    put(u64, &bytes, 40, 1536);
    put(u16, &bytes, 58, 64);
    put(u16, &bytes, 60, 2);
    put(u32, &bytes, 1604, 1);
    put(u64, &bytes, 1608, 6);
    put(u64, &bytes, 1616, code_address + 16);
    put(u64, &bytes, 1624, 272);
    put(u64, &bytes, 1632, 16);
    _ = try inspect(&bytes, .x86_64);
    put(u64, &bytes, 1608, 3);
    try std.testing.expectError(error.InvalidSegment, inspect(&bytes, .x86_64));
    put(u64, &bytes, 1608, 6);
    put(u64, &bytes, 1624, 273);
    try std.testing.expectError(error.InvalidSegment, inspect(&bytes, .x86_64));
}
