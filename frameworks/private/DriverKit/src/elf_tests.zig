const std = @import("std");
const elf = @import("elf.zig");
const abi = @import("abi.zig");
fn put(comptime T: type, bytes: []u8, offset: usize, value: T) void {
    std.mem.writeInt(T, bytes[offset..][0..@sizeOf(T)], value, .little);
}
fn ph(bytes: []u8, index: usize, kind: u32, flags: u32, offset: u64, address: u64, filesz: u64, memsz: u64, alignment: u64) void {
    const at = 64 + index * 56;
    put(u32, bytes, at, kind);
    put(u32, bytes, at + 4, flags);
    put(u64, bytes, at + 8, offset);
    put(u64, bytes, at + 16, address);
    put(u64, bytes, at + 24, address);
    put(u64, bytes, at + 32, filesz);
    put(u64, bytes, at + 40, memsz);
    put(u64, bytes, at + 48, alignment);
}
fn note(bytes: []u8, index: usize, arch: std.Target.Cpu.Arch, vendor: u16, product: u16) void {
    var value: abi.Note = .{ .descriptor = .{ .vendor = vendor, .product = product, .architecture = switch (arch) {
        .x86_64 => 62,
        .aarch64 => 183,
        .riscv64 => 243,
        else => unreachable,
    }, .capabilities = 3, .id = @splat(0) } };
    @memcpy(value.descriptor.id[0..18], "org.bedrock.mt7922");
    @memcpy(bytes[0x400 + index * @sizeOf(abi.Note) ..][0..@sizeOf(abi.Note)], std.mem.asBytes(&value));
}
fn fixture(arch: std.Target.Cpu.Arch) [12288]u8 {
    var bytes: [12288]u8 = @splat(0);
    @memcpy(bytes[0..7], "\x7fELF\x02\x01\x01");
    put(u16, &bytes, 16, 3);
    put(u16, &bytes, 18, switch (arch) {
        .x86_64 => 62,
        .aarch64 => 183,
        .riscv64 => 243,
        else => unreachable,
    });
    put(u32, &bytes, 20, 1);
    put(u64, &bytes, 24, 0x1000);
    put(u64, &bytes, 32, 64);
    put(u16, &bytes, 52, 64);
    put(u16, &bytes, 54, 56);
    put(u16, &bytes, 56, 5);
    ph(&bytes, 0, 1, 4, 0, 0, 4096, 4096, 4096);
    ph(&bytes, 1, 1, 5, 0x1000, 0x1000, 128, 4096, 4096);
    ph(&bytes, 2, 1, 6, 0x2000, 0x2000, 256, 4096, 4096);
    ph(&bytes, 3, 2, 6, 0x2080, 0x2080, 80, 80, 8);
    ph(&bytes, 4, 4, 4, 0x400, 0x400, @sizeOf(abi.Note), @sizeOf(abi.Note), 4);
    note(&bytes, 0, arch, 0x14c3, 0x0616);
    put(u64, &bytes, 0x2080, 7);
    put(u64, &bytes, 0x2088, 0x600);
    put(u64, &bytes, 0x2090, 8);
    put(u64, &bytes, 0x2098, 24);
    put(u64, &bytes, 0x20a0, 9);
    put(u64, &bytes, 0x20a8, 24);
    put(u64, &bytes, 0x20b0, 0x6ffffffb);
    put(u64, &bytes, 0x20b8, 0x08000000);
    put(u64, &bytes, 0x600, 0x2000);
    put(u64, &bytes, 0x608, switch (arch) {
        .x86_64 => 8,
        .aarch64 => 1027,
        .riscv64 => 3,
        else => unreachable,
    });
    put(u64, &bytes, 0x610, 0x1000);
    bytes[0x1000] = 0xcc;
    return bytes;
}
test "driver images relocate at different page-aligned bases on all three architectures" {
    var destinations: [2][12288]u8 align(4096) = undefined;
    for ([_]std.Target.Cpu.Arch{ .x86_64, .aarch64, .riscv64 }) |arch| {
        const bytes = fixture(arch);
        const image = try elf.inspect(&bytes, arch);
        try std.testing.expectEqual(@as(u64, 12288), image.span);
        try std.testing.expectEqual(@as(usize, 3), image.segment_count);
        try std.testing.expect(image.executable(0x1000, 1));
        try std.testing.expect(!image.writable(0x1000, 8));
        for (&destinations) |*destination| {
            @memset(destination, 0xa5);
            const entry = try elf.load(&bytes, arch, destination);
            try std.testing.expectEqual(@intFromPtr(destination) + 0x1000, entry);
            try std.testing.expectEqual(entry, std.mem.readInt(u64, destination[0x2000..0x2008], .little));
            try std.testing.expectEqual(@as(u8, 0xcc), destination[0x1000]);
            try std.testing.expectEqual(@as(u8, 0), destination[12287]);
        }
    }
}
test "read-only metadata supports exact bounded same-module PCI aliases" {
    var bytes = fixture(.x86_64);
    ph(&bytes, 4, 4, 4, 0x400, 0x400, @sizeOf(abi.Note) * 3, @sizeOf(abi.Note) * 3, 4);
    note(&bytes, 1, .x86_64, 0x14c3, 0x7922);
    note(&bytes, 2, .x86_64, 0x0b48, 0x7922);
    const image = try elf.inspect(&bytes, .x86_64);
    try std.testing.expectEqual(@as(usize, 3), image.match_count);
    try std.testing.expect(image.matchesDevice(0x14c3, 0x7922, 1, 2));
    try std.testing.expect(image.matchesDevice(0x0b48, 0x7922, 1, 2));
    try std.testing.expect(!image.matchesDevice(0x14c3, 0x7921, 1, 2));
    note(&bytes, 2, .x86_64, 0x14c3, 0x7922);
    try std.testing.expectError(error.DuplicateDescriptor, elf.inspect(&bytes, .x86_64));
    note(&bytes, 2, .x86_64, 0x0b48, 0x7922);
    bytes[0x400 + 2 * @sizeOf(abi.Note) + 20 + 40] = 'x';
    try std.testing.expectError(error.InvalidDescriptor, elf.inspect(&bytes, .x86_64));
}
test "invalid relocations and executable writable segments fail before copying" {
    var destination: [12288]u8 align(4096) = @splat(0xa5);
    var bytes = fixture(.x86_64);
    put(u64, &bytes, 0x600, 0x1000);
    try std.testing.expectError(error.InvalidRelocation, elf.load(&bytes, .x86_64, &destination));
    bytes = fixture(.x86_64);
    put(u64, &bytes, 0x608, (@as(u64, 1) << 32) | 8);
    try std.testing.expectError(error.UnsupportedRelocation, elf.load(&bytes, .x86_64, &destination));
    bytes = fixture(.x86_64);
    put(u32, &bytes, 64 + 56 + 4, 7);
    try std.testing.expectError(error.InvalidSegment, elf.load(&bytes, .x86_64, &destination));
    for (destination) |byte| try std.testing.expectEqual(@as(u8, 0xa5), byte);
}
test "metadata must be read-only, complete, and match the host architecture" {
    var bytes = fixture(.x86_64);
    put(u32, &bytes, 64 + 4 * 56, 0);
    try std.testing.expectError(error.MissingDescriptor, elf.inspect(&bytes, .x86_64));
    bytes = fixture(.x86_64);
    put(u32, &bytes, 64 + 4, 6);
    try std.testing.expectError(error.InvalidNote, elf.inspect(&bytes, .x86_64));
    bytes = fixture(.x86_64);
    put(u32, &bytes, 0x404, 63);
    try std.testing.expectError(error.InvalidDescriptor, elf.inspect(&bytes, .x86_64));
    bytes = fixture(.x86_64);
    put(u16, &bytes, 0x400 + 20 + 32, 183);
    try std.testing.expectError(error.WrongArchitecture, elf.inspect(&bytes, .x86_64));
    try std.testing.expectError(error.WrongArchitecture, elf.inspect(&bytes, .aarch64));
    try std.testing.expectError(error.TruncatedImage, elf.inspect(bytes[0..63], .x86_64));
}
test "driver loader rejects interpreters, constructors, malformed dynamic tables and page overlaps" {
    var bytes = fixture(.x86_64);
    put(u32, &bytes, 64 + 3 * 56, 3);
    try std.testing.expectError(error.UnsupportedImage, elf.inspect(&bytes, .x86_64));
    bytes = fixture(.x86_64);
    put(u64, &bytes, 0x2080, 12);
    try std.testing.expectError(error.UnsupportedRelocation, elf.inspect(&bytes, .x86_64));
    bytes = fixture(.x86_64);
    put(u64, &bytes, 0x20a8, 16);
    try std.testing.expectError(error.InvalidDynamicTable, elf.inspect(&bytes, .x86_64));
    bytes = fixture(.x86_64);
    ph(&bytes, 1, 1, 5, 0, 0, 128, 4096, 4096);
    try std.testing.expectError(error.SegmentOverlap, elf.inspect(&bytes, .x86_64));
    bytes = fixture(.x86_64);
    put(u64, &bytes, 24, 0x400);
    try std.testing.expectError(error.InvalidEntry, elf.inspect(&bytes, .x86_64));
}
test "allocation bounds, aliasing and architecture alignment are enforced before mutation" {
    var bytes: [12288]u8 align(4096) = fixture(.x86_64);
    var destination: [16384]u8 align(4096) = @splat(0xa5);
    try std.testing.expectError(error.DestinationTooSmall, elf.load(&bytes, .x86_64, destination[0..12287]));
    try std.testing.expectError(error.DestinationMisaligned, elf.load(&bytes, .x86_64, destination[1..12289]));
    try std.testing.expectError(error.SourceDestinationOverlap, elf.load(&bytes, .x86_64, &bytes));
    for ([_]std.Target.Cpu.Arch{ .aarch64, .riscv64 }) |arch| {
        bytes = fixture(arch);
        put(u64, &bytes, 24, 0x1001);
        try std.testing.expectError(error.InvalidEntry, elf.load(&bytes, arch, destination[0..12288]));
    }
    for (destination) |byte| try std.testing.expectEqual(@as(u8, 0xa5), byte);
}
