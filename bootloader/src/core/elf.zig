//! Bounded ELF64 PIE loading. Only local, symbol-free RELA relative relocations
//! are supported; no interpreter, shared libraries, TLS or symbol resolver.
const std = @import("std");
pub const max_segments = 64;
pub const max_span = 0x400000;
const max_relocations = 65536;
pub const Error = error{
    TruncatedImage,
    InvalidElf,
    WrongArchitecture,
    UnsupportedImage,
    TooManySegments,
    InvalidSegment,
    SegmentOverlap,
    InvalidEntry,
    InvalidDynamicTable,
    UnsupportedRelocation,
    InvalidRelocation,
    ImageTooLarge,
    DestinationTooSmall,
    DestinationMisaligned,
    AddressOverflow,
    SourceDestinationOverlap,
};
const Segment = struct { offset: u64, address: u64, file_size: u64, memory_size: u64, flags: u32 };
pub const Image = struct {
    span: u64,
    alignment: u64,
    entry_offset: u64,
    segments: [max_segments]Segment,
    segment_count: usize,
    rela_offset: u64 = 0,
    rela_size: u64 = 0,
};
fn end(base: u64, length: u64) Error!u64 {
    const result = @addWithOverflow(base, length);
    if (result[1] != 0) return error.AddressOverflow;
    return result[0];
}
fn field(comptime T: type, bytes: []const u8, offset: u64) Error!T {
    const limit = try end(offset, @sizeOf(T));
    if (limit > bytes.len) return error.TruncatedImage;
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
fn relative(arch: std.Target.Cpu.Arch) Error!u32 {
    return switch (arch) {
        .x86_64 => 8,
        .aarch64 => 1027,
        .riscv64 => 3,
        else => error.WrongArchitecture,
    };
}
fn contains(image: *const Image, address: u64, size: u64, file_backed: bool) Error!?u64 {
    const limit = try end(address, size);
    for (image.segments[0..image.segment_count]) |segment| {
        const length = if (file_backed) segment.file_size else segment.memory_size;
        if (address >= segment.address and limit <= try end(segment.address, length))
            return try end(segment.offset, address - segment.address);
    }
    return null;
}

/// Inspect all metadata and relocations before any destination bytes are changed.
pub fn inspect(bytes: []const u8, arch: std.Target.Cpu.Arch) Error!Image {
    if (bytes.len < 64) return error.TruncatedImage;
    if (!std.mem.eql(u8, bytes[0..4], "\x7fELF") or bytes[4] != 2 or bytes[5] != 1 or bytes[6] != 1)
        return error.InvalidElf;
    if (bytes[7] != 0 or bytes[8] != 0 or try field(u16, bytes, 16) != 3 or try field(u32, bytes, 20) != 1)
        return error.UnsupportedImage;
    if (try field(u16, bytes, 18) != try machine(arch)) return error.WrongArchitecture;
    const flags = try field(u32, bytes, 48);
    if ((arch == .riscv64 and flags & ~@as(u32, 1) != 0) or (arch != .riscv64 and flags != 0))
        return error.UnsupportedImage;
    if (try field(u16, bytes, 52) != 64 or try field(u16, bytes, 54) != 56) return error.InvalidElf;
    const count = try field(u16, bytes, 56);
    if (count == 0 or count > max_segments) return error.TooManySegments;
    const phoff = try field(u64, bytes, 32);
    if (try end(phoff, @as(u64, count) * 56) > bytes.len) return error.TruncatedImage;
    var image: Image = .{ .span = 0, .alignment = 4096, .entry_offset = try field(u64, bytes, 24), .segments = undefined, .segment_count = 0 };
    if ((arch == .aarch64 and image.entry_offset % 4 != 0) or
        (arch == .riscv64 and image.entry_offset % 2 != 0)) return error.InvalidEntry;
    var dynamic: ?Segment = null;
    var lowest: u64 = std.math.maxInt(u64);
    var entry_valid = false;
    for (0..count) |index| {
        const offset = phoff + index * 56;
        const kind = try field(u32, bytes, offset);
        if (kind == 3 or kind == 7) return error.UnsupportedImage; // PT_INTERP / PT_TLS.
        if (kind != 1 and kind != 2) continue;
        const segment: Segment = .{
            .flags = try field(u32, bytes, offset + 4),
            .offset = try field(u64, bytes, offset + 8),
            .address = try field(u64, bytes, offset + 16),
            .file_size = try field(u64, bytes, offset + 32),
            .memory_size = try field(u64, bytes, offset + 40),
        };
        const physical = try field(u64, bytes, offset + 24);
        const alignment = try field(u64, bytes, offset + 48);
        const limit = try end(segment.address, segment.memory_size);
        if (segment.file_size > segment.memory_size or try end(segment.offset, segment.file_size) > bytes.len or
            segment.flags & ~@as(u32, 7) != 0 or physical != segment.address) return error.InvalidSegment;
        if (alignment > max_span or (alignment > 1 and (alignment & (alignment - 1) != 0 or
            segment.address % alignment != segment.offset % alignment))) return error.InvalidSegment;
        if (limit > max_span) return error.ImageTooLarge;
        if (kind == 2) {
            if (dynamic != null or segment.file_size == 0 or segment.file_size != segment.memory_size or segment.file_size % 16 != 0 or segment.file_size > 65536)
                return error.InvalidDynamicTable;
            dynamic = segment;
            continue;
        }
        if (segment.memory_size == 0) continue;
        for (image.segments[0..image.segment_count]) |previous| {
            if (segment.address < try end(previous.address, previous.memory_size) and previous.address < limit)
                return error.SegmentOverlap;
        }
        image.segments[image.segment_count] = segment;
        image.segment_count += 1;
        lowest = @min(lowest, segment.address);
        image.span = @max(image.span, limit);
        image.alignment = @max(image.alignment, alignment);
        if (segment.flags & 1 != 0 and image.entry_offset >= segment.address and image.entry_offset < try end(segment.address, segment.file_size))
            entry_valid = true;
    }
    if (image.segment_count == 0 or lowest != 0) return error.InvalidSegment;
    if (!entry_valid) return error.InvalidEntry;
    if (dynamic) |table| {
        const expected_offset = try contains(&image, table.address, table.file_size, true) orelse return error.InvalidDynamicTable;
        if (expected_offset != table.offset) return error.InvalidDynamicTable;
        var rela_address: ?u64 = null;
        var rela_size: ?u64 = null;
        var rela_entry: ?u64 = null;
        var terminated = false;
        var cursor = table.offset;
        while (cursor < table.offset + table.file_size) : (cursor += 16) {
            const tag = try field(u64, bytes, cursor);
            const value = try field(u64, bytes, cursor + 8);
            switch (tag) {
                0 => {
                    terminated = true;
                    break;
                },
                7 => {
                    if (rela_address != null) return error.InvalidDynamicTable;
                    rela_address = value;
                },
                8 => {
                    if (rela_size != null) return error.InvalidDynamicTable;
                    rela_size = value;
                },
                9 => {
                    if (rela_entry != null) return error.InvalidDynamicTable;
                    rela_entry = value;
                },
                1, 2, 17, 18, 19, 20, 22, 23, 35, 36, 37 => return error.UnsupportedRelocation,
                // Symbol/hash metadata is never dereferenced: every relocation
                // must be symbol-free. No runtime symbol binding is performed.
                4, 5, 6, 10, 11, 21, 30, 0x6ffffef5, 0x6ffffff9, 0x6ffffffb => {},
                else => return error.InvalidDynamicTable,
            }
        }
        if (!terminated) return error.InvalidDynamicTable;
        if (rela_address != null or rela_size != null or rela_entry != null) {
            if (rela_address == null or rela_size == null or rela_entry == null or rela_entry.? != 24 or
                rela_size.? % 24 != 0 or rela_size.? / 24 > max_relocations) return error.InvalidDynamicTable;
            image.rela_offset = try contains(&image, rela_address.?, rela_size.?, true) orelse return error.InvalidDynamicTable;
            image.rela_size = rela_size.?;
        }
    }
    var relocation: u64 = 0;
    while (relocation < image.rela_size) : (relocation += 24) {
        const offset = image.rela_offset + relocation;
        const target = try field(u64, bytes, offset);
        const info = try field(u64, bytes, offset + 8);
        const addend = try field(i64, bytes, offset + 16);
        if (info == 0) continue;
        if (info >> 32 != 0 or @as(u32, @truncate(info)) != try relative(arch)) return error.UnsupportedRelocation;
        if (target % 8 != 0 or try contains(&image, target, 8, false) == null or addend < 0 or
            @as(u64, @intCast(addend)) > image.span) return error.InvalidRelocation;
    }
    return image;
}

pub fn load(bytes: []const u8, arch: std.Target.Cpu.Arch, destination: []u8) Error!u64 {
    const image = try inspect(bytes, arch);
    const base: u64 = @intFromPtr(destination.ptr);
    if (destination.len < image.span) return error.DestinationTooSmall;
    if (base % image.alignment != 0) return error.DestinationMisaligned;
    const destination_end = try end(base, image.span);
    const source_base: u64 = @intFromPtr(bytes.ptr);
    if (source_base < destination_end and base < try end(source_base, bytes.len)) return error.SourceDestinationOverlap;
    @memset(destination[0..@intCast(image.span)], 0);
    for (image.segments[0..image.segment_count]) |segment| {
        @memcpy(destination[@intCast(segment.address)..][0..@intCast(segment.file_size)], bytes[@intCast(segment.offset)..][0..@intCast(segment.file_size)]);
    }
    var relocation: u64 = 0;
    while (relocation < image.rela_size) : (relocation += 24) {
        const offset = image.rela_offset + relocation;
        const target = try field(u64, bytes, offset);
        const info = try field(u64, bytes, offset + 8);
        if (info == 0) continue;
        const addend = try field(u64, bytes, offset + 16);
        // One-past pointers (such as stack top) are valid; end is checked.
        std.mem.writeInt(u64, destination[@intCast(target)..][0..8], base + addend, .little);
    }
    return base + image.entry_offset;
}

fn put(comptime T: type, bytes: []u8, offset: usize, value: T) void {
    std.mem.writeInt(T, bytes[offset..][0..@sizeOf(T)], value, .little);
}
fn fixture(arch: std.Target.Cpu.Arch) [1024]u8 {
    var bytes: [1024]u8 = @splat(0);
    @memcpy(bytes[0..7], "\x7fELF\x02\x01\x01");
    put(u16, &bytes, 16, 3);
    put(u16, &bytes, 18, machine(arch) catch unreachable);
    put(u32, &bytes, 20, 1);
    put(u64, &bytes, 24, 0x20);
    put(u64, &bytes, 32, 64);
    put(u16, &bytes, 52, 64);
    put(u16, &bytes, 54, 56);
    put(u16, &bytes, 56, 2);
    put(u32, &bytes, 64, 1);
    put(u32, &bytes, 68, 7);
    put(u64, &bytes, 72, 256);
    put(u64, &bytes, 96, 512);
    put(u64, &bytes, 104, 4096);
    put(u64, &bytes, 112, 1);
    put(u32, &bytes, 120, 2);
    put(u32, &bytes, 124, 6);
    put(u64, &bytes, 128, 512);
    put(u64, &bytes, 136, 256);
    put(u64, &bytes, 144, 256);
    put(u64, &bytes, 152, 64);
    put(u64, &bytes, 160, 64);
    put(u64, &bytes, 168, 1);
    put(u64, &bytes, 512, 7);
    put(u64, &bytes, 520, 384);
    put(u64, &bytes, 528, 8);
    put(u64, &bytes, 536, 24);
    put(u64, &bytes, 544, 9);
    put(u64, &bytes, 552, 24);
    put(u64, &bytes, 640, 128);
    put(u64, &bytes, 648, relative(arch) catch unreachable);
    put(u64, &bytes, 656, 0x20);
    bytes[288] = 0xcc;
    return bytes;
}
test "PIE loads at two arbitrary aligned bases for all three architectures" {
    var destinations: [2][4096]u8 align(4096) = undefined;
    for ([_]std.Target.Cpu.Arch{ .x86_64, .aarch64, .riscv64 }) |arch| {
        const bytes = fixture(arch);
        for (&destinations) |*destination| {
            @memset(destination, 0xa5);
            const entry = try load(&bytes, arch, destination);
            try std.testing.expectEqual(@intFromPtr(destination) + 0x20, entry);
            try std.testing.expectEqual(entry, std.mem.readInt(u64, destination[128..136], .little));
            try std.testing.expectEqual(@as(u8, 0xcc), destination[0x20]);
            try std.testing.expectEqual(@as(u8, 0), destination[4095]);
        }
    }
}
test "ELF malformed metadata fails before destination mutation" {
    var bytes = fixture(.x86_64);
    var destination: [4096]u8 align(4096) = @splat(0xa5);
    put(u64, &bytes, 648, 1); // Symbol-resolving relocation unsupported.
    try std.testing.expectError(error.UnsupportedRelocation, load(&bytes, .x86_64, &destination));
    for (destination) |byte| try std.testing.expectEqual(@as(u8, 0xa5), byte);
    try std.testing.expectError(error.WrongArchitecture, inspect(&bytes, .aarch64));
    try std.testing.expectError(error.TruncatedImage, inspect(bytes[0..63], .x86_64));
}
test "ELF rejects overlaps, non-executable entry and escaped relocation targets" {
    var bytes = fixture(.x86_64);
    put(u64, &bytes, 640, 4096);
    try std.testing.expectError(error.InvalidRelocation, inspect(&bytes, .x86_64));
    bytes = fixture(.x86_64);
    put(u32, &bytes, 68, 6);
    try std.testing.expectError(error.InvalidEntry, inspect(&bytes, .x86_64));
    bytes = fixture(.x86_64);
    put(u32, &bytes, 120, 1);
    try std.testing.expectError(error.SegmentOverlap, inspect(&bytes, .x86_64));
}
test "ELF rejects bad dynamic tables and wrong ABI before copying" {
    var bytes = fixture(.riscv64);
    put(u32, &bytes, 48, 4);
    try std.testing.expectError(error.UnsupportedImage, inspect(&bytes, .riscv64));
    bytes = fixture(.x86_64);
    put(u64, &bytes, 552, 16);
    try std.testing.expectError(error.InvalidDynamicTable, inspect(&bytes, .x86_64));
    bytes = fixture(.x86_64);
    put(u64, &bytes, 512, 1);
    try std.testing.expectError(error.UnsupportedRelocation, inspect(&bytes, .x86_64));
}
test "ELF load checks destination capacity, alignment and source aliasing" {
    var bytes: [1024]u8 align(4096) = fixture(.x86_64);
    var destination: [8192]u8 align(4096) = undefined;
    try std.testing.expectError(error.DestinationTooSmall, load(&bytes, .x86_64, destination[0..4095]));
    try std.testing.expectError(error.DestinationMisaligned, load(&bytes, .x86_64, destination[1..4097]));
    @memcpy(destination[0..bytes.len], &bytes);
    try std.testing.expectError(error.SourceDestinationOverlap, load(destination[0..bytes.len], .x86_64, destination[0..4096]));
}

test "ELF enforces architecture instruction alignment before copying" {
    var destination: [4096]u8 align(4096) = @splat(0xa5);
    for ([_]std.Target.Cpu.Arch{ .aarch64, .riscv64 }) |arch| {
        var bytes = fixture(arch);
        put(u64, &bytes, 24, 0x21);
        try std.testing.expectError(error.InvalidEntry, load(&bytes, arch, &destination));
    }
    for (destination) |byte| try std.testing.expectEqual(@as(u8, 0xa5), byte);
    var bytes = fixture(.x86_64);
    put(u64, &bytes, 24, 0x21);
    _ = try inspect(&bytes, .x86_64);
}

test "ELF preserves one-past allocation pointers while bounding relocation writes" {
    var bytes = fixture(.x86_64);
    put(u64, &bytes, 656, 4096);
    var destination: [4096]u8 align(4096) = undefined;
    _ = try load(&bytes, .x86_64, &destination);
    try std.testing.expectEqual(@intFromPtr(&destination) + destination.len, std.mem.readInt(u64, destination[128..136], .little));
    put(u64, &bytes, 656, 4097);
    try std.testing.expectError(error.InvalidRelocation, inspect(&bytes, .x86_64));
    put(u64, &bytes, 656, 4096);
    put(u64, &bytes, 640, 4096);
    try std.testing.expectError(error.InvalidRelocation, inspect(&bytes, .x86_64));
}
