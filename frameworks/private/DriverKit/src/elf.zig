//! Bounded ELF64 position-independent driver images. No dynamic symbol lookup,
//! constructors, TLS, interpreter, shared-library dependencies, or text writes.
const std = @import("std");
const abi = @import("abi.zig");
pub const max_segments = 8;
pub const max_span = 0x400000;
pub const max_file_size = 0x800000;
pub const max_matches = 8;
pub const page_size = 4096;
const max_program_headers = 32;
const max_relocations = 16384;
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
    MissingDescriptor,
    DuplicateDescriptor,
    InvalidDescriptor,
    InvalidNote,
};
pub const Segment = struct {
    offset: u64,
    address: u64,
    file_size: u64,
    memory_size: u64,
    /// ELF PF_R=4, PF_W=2, PF_X=1. Only R, RX, and RW are accepted.
    flags: u32,
};
pub const Image = struct {
    span: u64,
    alignment: u64,
    entry_offset: u64,
    segments: [max_segments]Segment,
    segment_count: usize,
    descriptor: abi.Descriptor,
    descriptor_offset: u64,
    matches: [max_matches]abi.Descriptor,
    match_count: usize,
    rela_offset: u64 = 0,
    rela_size: u64 = 0,

    pub fn executable(self: *const Image, offset: u64, length: u64) bool {
        return self.contains(offset, length, true, 5) catch false;
    }
    pub fn writable(self: *const Image, offset: u64, length: u64) bool {
        return self.contains(offset, length, false, 6) catch false;
    }
    pub fn matchesDevice(self: *const Image, vendor: u16, product: u16, subvendor: u16, subproduct: u16) bool {
        for (self.matches[0..self.match_count]) |*match| if (match.matches(vendor, product, subvendor, subproduct)) return true;
        return false;
    }
    fn contains(self: *const Image, address: u64, length: u64, file_backed: bool, flags: u32) Error!bool {
        const limit = try end(address, length);
        for (self.segments[0..self.segment_count]) |segment| {
            const available = if (file_backed) segment.file_size else segment.memory_size;
            if (segment.flags == flags and address >= segment.address and limit <= try end(segment.address, available)) return true;
        }
        return false;
    }
};
fn end(base: u64, length: u64) Error!u64 {
    const result = @addWithOverflow(base, length);
    if (result[1] != 0) return error.AddressOverflow;
    return result[0];
}
fn rounded(value: u64) Error!u64 {
    return (try end(value, page_size - 1)) & ~@as(u64, page_size - 1);
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
fn relative(arch: std.Target.Cpu.Arch) Error!u32 {
    return switch (arch) {
        .x86_64 => 8,
        .aarch64 => 1027,
        .riscv64 => 3,
        else => error.WrongArchitecture,
    };
}
fn fileOffset(image: *const Image, address: u64, size: u64, flags: ?u32) Error!?u64 {
    const limit = try end(address, size);
    for (image.segments[0..image.segment_count]) |segment| {
        if (flags != null and segment.flags != flags.?) continue;
        if (address >= segment.address and limit <= try end(segment.address, segment.file_size))
            return try end(segment.offset, address - segment.address);
    }
    return null;
}
fn readDescriptor(bytes: []const u8, at: u64, arch: std.Target.Cpu.Arch) Error!abi.Descriptor {
    if (try end(at, @sizeOf(abi.Descriptor)) > bytes.len) return error.TruncatedImage;
    var result: abi.Descriptor = undefined;
    @memcpy(std.mem.asBytes(&result), bytes[@intCast(at)..][0..@sizeOf(abi.Descriptor)]);
    if (!result.validate()) return error.InvalidDescriptor;
    if (result.architecture != try machine(arch)) return error.WrongArchitecture;
    return result;
}
fn notes(bytes: []const u8, image: *Image, table: Segment, arch: std.Target.Cpu.Arch) Error!void {
    if (table.file_size == 0 or table.file_size > 4096 or table.file_size != table.memory_size or table.flags != 4)
        return error.InvalidNote;
    const mapped = try fileOffset(image, table.address, table.file_size, 4) orelse return error.InvalidNote;
    if (mapped != table.offset) return error.InvalidNote;
    const last = try end(table.offset, table.file_size);
    var cursor = table.offset;
    while (cursor < last) {
        if (last - cursor < 12) return error.InvalidNote;
        const name_size = try field(u32, bytes, cursor);
        const descriptor_size = try field(u32, bytes, cursor + 4);
        const kind = try field(u32, bytes, cursor + 8);
        const name_offset = cursor + 12;
        const name_end = try end(name_offset, name_size);
        const descriptor_offset = (try end(name_end, 3)) & ~@as(u64, 3);
        const descriptor_end = try end(descriptor_offset, descriptor_size);
        const next = (try end(descriptor_end, 3)) & ~@as(u64, 3);
        if (name_size == 0 or name_end > last or descriptor_end > last or next > last) return error.InvalidNote;
        const name = bytes[@intCast(name_offset)..@intCast(name_end)];
        if (name_size == abi.note_name.len and std.mem.eql(u8, name, &abi.note_name)) {
            if (kind != abi.note_type or descriptor_size != @sizeOf(abi.Descriptor)) return error.InvalidDescriptor;
            const descriptor = try readDescriptor(bytes, descriptor_offset, arch);
            if (image.match_count == max_matches) return error.DuplicateDescriptor;
            if (image.match_count == 0) {
                image.descriptor = descriptor;
                image.descriptor_offset = descriptor_offset;
            } else {
                const primary = &image.descriptor;
                if (!std.mem.eql(u8, &descriptor.id, &primary.id) or descriptor.abi_major != primary.abi_major or
                    descriptor.abi_minor != primary.abi_minor or descriptor.class != primary.class or
                    descriptor.module_version != primary.module_version or descriptor.architecture != primary.architecture or
                    descriptor.capabilities != primary.capabilities) return error.InvalidDescriptor;
                for (image.matches[0..image.match_count]) |*previous| {
                    if (previous.vendor == descriptor.vendor and previous.product == descriptor.product and
                        previous.subsystem_vendor == descriptor.subsystem_vendor and
                        previous.subsystem_product == descriptor.subsystem_product) return error.DuplicateDescriptor;
                }
            }
            image.matches[image.match_count] = descriptor;
            image.match_count += 1;
        }
        cursor = next;
    }
}
/// Inspect every load segment, note, and relocation before mutating RAM.
pub fn inspect(bytes: []const u8, arch: std.Target.Cpu.Arch) Error!Image {
    if (bytes.len > max_file_size) return error.ImageTooLarge;
    if (bytes.len < 64) return error.TruncatedImage;
    if (!std.mem.eql(u8, bytes[0..4], "\x7fELF") or bytes[4] != 2 or bytes[5] != 1 or bytes[6] != 1)
        return error.InvalidElf;
    if (bytes[7] != 0 or bytes[8] != 0 or try field(u16, bytes, 16) != 3 or try field(u32, bytes, 20) != 1)
        return error.UnsupportedImage;
    if (try field(u16, bytes, 18) != try machine(arch)) return error.WrongArchitecture;
    const elf_flags = try field(u32, bytes, 48);
    if ((arch == .riscv64 and elf_flags & ~@as(u32, 1) != 0) or (arch != .riscv64 and elf_flags != 0))
        return error.UnsupportedImage;
    if (try field(u16, bytes, 52) != 64 or try field(u16, bytes, 54) != 56) return error.InvalidElf;
    const count = try field(u16, bytes, 56);
    if (count == 0 or count > max_program_headers) return error.TooManySegments;
    const phoff = try field(u64, bytes, 32);
    if (phoff < 64 or phoff % 8 != 0 or try end(phoff, @as(u64, count) * 56) > bytes.len) return error.TruncatedImage;
    var image: Image = .{ .span = 0, .alignment = page_size, .entry_offset = try field(u64, bytes, 24), .segments = undefined, .segment_count = 0, .descriptor = undefined, .descriptor_offset = 0, .matches = undefined, .match_count = 0 };
    if ((arch == .aarch64 and image.entry_offset % 4 != 0) or (arch == .riscv64 and image.entry_offset % 2 != 0))
        return error.InvalidEntry;
    var dynamic: ?Segment = null;
    var lowest: u64 = std.math.maxInt(u64);
    for (0..count) |index| {
        const offset = phoff + index * 56;
        const kind = try field(u32, bytes, offset);
        // PT_INTERP / PT_TLS; no platform-specific loader side effects.
        if (kind == 3 or kind == 7) return error.UnsupportedImage;
        if (kind == 0x6474e551 and try field(u32, bytes, offset + 4) & 1 != 0) return error.UnsupportedImage;
        if (kind != 1 and kind != 2 and kind != 4) continue;
        const segment: Segment = .{ .flags = try field(u32, bytes, offset + 4), .offset = try field(u64, bytes, offset + 8), .address = try field(u64, bytes, offset + 16), .file_size = try field(u64, bytes, offset + 32), .memory_size = try field(u64, bytes, offset + 40) };
        const alignment = try field(u64, bytes, offset + 48);
        const limit = try end(segment.address, segment.memory_size);
        if (segment.file_size > segment.memory_size or try end(segment.offset, segment.file_size) > bytes.len or
            try field(u64, bytes, offset + 24) != segment.address or
            (segment.flags != 4 and segment.flags != 5 and segment.flags != 6)) return error.InvalidSegment;
        if (alignment > max_span or (alignment > 1 and (alignment & (alignment - 1) != 0 or
            segment.address % alignment != segment.offset % alignment))) return error.InvalidSegment;
        if (limit > max_span) return error.ImageTooLarge;
        if (kind == 4) continue;
        if (kind == 2) {
            if (dynamic != null or segment.flags != 6 or segment.file_size == 0 or segment.file_size != segment.memory_size or
                segment.file_size % 16 != 0 or segment.file_size > 65536) return error.InvalidDynamicTable;
            dynamic = segment;
            continue;
        }
        if (segment.memory_size == 0) continue;
        if (image.segment_count == max_segments) return error.TooManySegments;
        if (segment.address % page_size != 0 or alignment < page_size) return error.InvalidSegment;
        const page_end = try rounded(limit);
        for (image.segments[0..image.segment_count]) |previous| {
            if (segment.address < try rounded(try end(previous.address, previous.memory_size)) and previous.address < page_end)
                return error.SegmentOverlap;
        }
        image.segments[image.segment_count] = segment;
        image.segment_count += 1;
        lowest = @min(lowest, segment.address);
        image.span = @max(image.span, page_end);
        image.alignment = @max(image.alignment, alignment);
    }
    if (image.segment_count == 0 or lowest != 0) return error.InvalidSegment;
    if (!image.executable(image.entry_offset, 1)) return error.InvalidEntry;
    for (0..count) |index| {
        const offset = phoff + index * 56;
        if (try field(u32, bytes, offset) != 4) continue;
        try notes(bytes, &image, .{ .flags = try field(u32, bytes, offset + 4), .offset = try field(u64, bytes, offset + 8), .address = try field(u64, bytes, offset + 16), .file_size = try field(u64, bytes, offset + 32), .memory_size = try field(u64, bytes, offset + 40) }, arch);
    }
    if (image.match_count == 0) return error.MissingDescriptor;
    if (dynamic) |table| {
        const expected = try fileOffset(&image, table.address, table.file_size, 6) orelse return error.InvalidDynamicTable;
        if (expected != table.offset) return error.InvalidDynamicTable;
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
                // Symbol/hash metadata is ignored, never resolved. Every
                // relocation is checked to have a zero symbol index.
                4, 5, 6, 10, 11, 21, 0x6ffffef5 => {},
                30 => if (value & ~@as(u64, 8) != 0) return error.UnsupportedRelocation,
                0x6ffffffb => if (value & ~@as(u64, 0x08000001) != 0) return error.UnsupportedRelocation,
                0x6ffffff9 => if (value > max_relocations) return error.InvalidDynamicTable,
                // Includes dependencies, PLT, constructors, REL/RELR, TLS,
                // text relocations and unresolved runtime loader behavior.
                else => return error.UnsupportedRelocation,
            }
        }
        if (!terminated) return error.InvalidDynamicTable;
        if (rela_address != null or rela_size != null or rela_entry != null) {
            if (rela_address == null or rela_size == null or rela_entry == null or rela_entry.? != 24 or
                rela_size.? % 24 != 0 or rela_size.? / 24 > max_relocations) return error.InvalidDynamicTable;
            image.rela_offset = try fileOffset(&image, rela_address.?, rela_size.?, null) orelse return error.InvalidDynamicTable;
            image.rela_size = rela_size.?;
        }
    }
    var relocation: u64 = 0;
    while (relocation < image.rela_size) : (relocation += 24) {
        const offset = image.rela_offset + relocation;
        const target = try field(u64, bytes, offset);
        const info = try field(u64, bytes, offset + 8);
        const addend = try field(i64, bytes, offset + 16);
        if (info == 0) {
            if (target != 0 or addend != 0) return error.InvalidRelocation;
            continue;
        }
        if (info >> 32 != 0 or @as(u32, @truncate(info)) != try relative(arch)) return error.UnsupportedRelocation;
        if (target % 8 != 0 or !image.writable(target, 8) or addend < 0 or @as(u64, @intCast(addend)) > image.span)
            return error.InvalidRelocation;
    }
    return image;
}
/// Caller-owned pages start RW/NX. After loading, the host must protect each
/// segment as R, RX, or RW/NX in every supervisor address space before entry.
/// ARM requires instruction-cache maintenance; RISC-V requires fence.i.
pub fn load(bytes: []const u8, arch: std.Target.Cpu.Arch, destination: []u8) Error!u64 {
    const image = try inspect(bytes, arch);
    const base: u64 = @intFromPtr(destination.ptr);
    if (destination.len < image.span) return error.DestinationTooSmall;
    if (base % image.alignment != 0) return error.DestinationMisaligned;
    const destination_end = try end(base, image.span);
    const source_base: u64 = @intFromPtr(bytes.ptr);
    if (source_base < destination_end and base < try end(source_base, bytes.len)) return error.SourceDestinationOverlap;
    @memset(destination[0..@intCast(image.span)], 0);
    for (image.segments[0..image.segment_count]) |segment|
        @memcpy(destination[@intCast(segment.address)..][0..@intCast(segment.file_size)], bytes[@intCast(segment.offset)..][0..@intCast(segment.file_size)]);
    var relocation: u64 = 0;
    while (relocation < image.rela_size) : (relocation += 24) {
        const offset = image.rela_offset + relocation;
        if (try field(u64, bytes, offset + 8) == 0) continue;
        const target = try field(u64, bytes, offset);
        const addend = try field(u64, bytes, offset + 16);
        std.mem.writeInt(u64, destination[@intCast(target)..][0..8], base + addend, .little);
    }
    return base + image.entry_offset;
}
test {
    _ = @import("elf_tests.zig");
}
