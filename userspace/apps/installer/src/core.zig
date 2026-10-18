//! Whole-disk installer mechanism. The caller owns target selection and consent.
const std = @import("std");
const fs = @import("filesystem");
pub const sector_size = 512;
pub const esp_first: u64 = 2048;
pub const esp_blocks: u64 = 128991;
pub const data_first: u64 = 131072;
pub const data_blocks: u64 = 8192;
pub const minimum_blocks: u64 = data_first + data_blocks + 33;
pub const max_extents = 256;
const chunk_bytes = 32768;
const table_bytes = 16384;
const esp_type = [_]u8{ 0x28, 0x73, 0x2a, 0xc1, 0x1f, 0xf8, 0xd2, 0x11, 0xba, 0x4b, 0x00, 0xa0, 0xc9, 0x3e, 0xc9, 0x3b };
var transfer: [chunk_bytes]u8 = undefined;
var readback: [chunk_bytes]u8 = undefined;
var entries: [table_bytes]u8 = undefined;

pub const Source = struct {
    context: *anyopaque,
    byte_count: u64,
    read_fn: *const fn (*anyopaque, u64, []u8) anyerror!void,
    pub fn read(self: Source, offset: u64, output: []u8) !void {
        if (offset > self.byte_count or output.len > self.byte_count - offset) return error.InvalidPayload;
        try self.read_fn(self.context, offset, output);
    }
};
pub const Progress = struct {
    context: *anyopaque,
    notify_fn: *const fn (*anyopaque, u64, u64) void,
};
pub const Extent = struct { first: u64, blocks: u64, offset: u64, crc: u32 };
pub const Manifest = struct {
    extents: [max_extents]Extent = undefined,
    count: usize = 0,
    source_id: [32]u8 = undefined,
    pub fn minimumBlocks(_: *const Manifest) u64 {
        return minimum_blocks;
    }
    pub fn load(source: Source, machine: u16, self: *Manifest) !void {
        self.count = 0;
        if (source.byte_count < 512 or source.byte_count > 64 * 1024 * 1024) return error.InvalidPayload;
        var header: [512]u8 = undefined;
        try source.read(0, &header);
        const checksum = get(u32, header[124..128]);
        @memset(header[124..128], 0);
        if (!std.mem.eql(u8, header[0..8], "BEDIP001") or get(u32, header[8..12]) != 1 or
            get(u16, header[12..14]) != machine or get(u16, header[14..16]) != 512 or
            get(u64, header[16..24]) != source.byte_count or get(u64, header[24..32]) != esp_first or
            get(u64, header[32..40]) != esp_blocks or get(u64, header[40..48]) != data_first or
            get(u64, header[48..56]) != data_blocks or fs.partition.crc32(&header) != checksum)
            return error.InvalidPayload;
        for (header[96..124]) |byte| if (byte != 0) return error.InvalidPayload;
        for (header[128..]) |byte| if (byte != 0) return error.InvalidPayload;
        const count = get(u32, header[56..60]);
        if (count == 0 or count > max_extents) return error.InvalidPayload;
        var table: [max_extents * 32]u8 = undefined;
        try source.read(512, table[0 .. count * 32]);
        if (fs.partition.crc32(table[0 .. count * 32]) != get(u32, header[60..64])) return error.InvalidPayload;
        var end_block: u64 = 0;
        var end_offset: u64 = 512 + @as(u64, count) * 32;
        for (0..count) |i| {
            const row = table[i * 32 ..][0..32];
            const extent: Extent = .{ .first = get(u64, row[0..8]), .blocks = get(u64, row[8..16]), .offset = get(u64, row[16..24]), .crc = get(u32, row[24..28]) };
            if (get(u32, row[28..32]) != 0 or extent.blocks == 0 or extent.blocks > esp_blocks or extent.first < end_block or extent.offset != end_offset) return error.InvalidPayload;
            const end = std.math.add(u64, extent.first, extent.blocks) catch return error.InvalidPayload;
            if (!((extent.first >= esp_first and end <= esp_first + esp_blocks) or (extent.first >= data_first and end <= data_first + data_blocks))) return error.InvalidPayload;
            const bytes = extent.blocks * 512;
            if (extent.offset > source.byte_count or bytes > source.byte_count - extent.offset) return error.InvalidPayload;
            self.extents[i] = extent;
            end_block = end;
            end_offset += bytes;
        }
        if (end_offset != source.byte_count) return error.InvalidPayload;
        @memcpy(&self.source_id, header[64..96]);
        self.count = count;
        try validateContents(source, self);
    }
};
fn get(comptime T: type, bytes: []const u8) T {
    return std.mem.readInt(T, bytes[0..@sizeOf(T)], .little);
}
fn put(comptime T: type, bytes: []u8, value: T) void {
    std.mem.writeInt(T, bytes[0..@sizeOf(T)], value, .little);
}
fn validateContents(source: Source, manifest: *const Manifest) !void {
    for (manifest.extents[0..manifest.count]) |extent| {
        var checksum = std.hash.Crc32.init();
        var offset: u64 = 0;
        while (offset < extent.blocks * 512) {
            const size: usize = @intCast(@min(chunk_bytes, extent.blocks * 512 - offset));
            try source.read(extent.offset + offset, transfer[0..size]);
            checksum.update(transfer[0..size]);
            offset += size;
        }
        if (checksum.final() != extent.crc) return error.PayloadChecksum;
    }
}
fn uuid(seed: []const u8, discriminator: u8) [16]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(seed);
    hash.update(&.{discriminator});
    var output: [32]u8 = undefined;
    hash.final(&output);
    var result: [16]u8 = output[0..16].*;
    result[7] = (result[7] & 15) | 0x40;
    result[8] = (result[8] & 63) | 0x80;
    return result;
}
fn partitionRow(index: usize, kind: [16]u8, disk_guid: [16]u8, first: u64, blocks: u64, name: []const u8) void {
    const row = entries[index * 128 ..][0..128];
    @memcpy(row[0..16], &kind);
    @memcpy(row[16..32], &uuid(&disk_guid, @intCast(index)));
    put(u64, row[32..40], first);
    put(u64, row[40..48], first + blocks - 1);
    for (name, 0..) |byte, i| put(u16, row[56 + i * 2 ..][0..2], byte);
}
fn gptHeader(block_count: u64, guid: [16]u8, backup: bool) [512]u8 {
    var bytes: [512]u8 = @splat(0);
    @memcpy(bytes[0..8], "EFI PART");
    put(u32, bytes[8..12], 0x10000);
    put(u32, bytes[12..16], 92);
    put(u64, bytes[24..32], if (backup) block_count - 1 else 1);
    put(u64, bytes[32..40], if (backup) 1 else block_count - 1);
    put(u64, bytes[40..48], 34);
    put(u64, bytes[48..56], block_count - 34);
    @memcpy(bytes[56..72], &guid);
    put(u64, bytes[72..80], if (backup) block_count - 33 else 2);
    put(u32, bytes[80..84], 128);
    put(u32, bytes[84..88], 128);
    put(u32, bytes[88..92], fs.partition.crc32(&entries));
    put(u32, bytes[16..20], fs.partition.crc32(bytes[0..92]));
    return bytes;
}
fn checkedWrite(target: fs.BlockDevice, block: u64, input: []const u8) !void {
    try target.write(block, input);
    try target.read(block, readback[0..input.len]);
    if (!std.mem.eql(u8, input, readback[0..input.len])) return error.InstallReadback;
}
pub fn install(source: Source, manifest: *const Manifest, target: fs.BlockDevice, guid: [16]u8, progress: Progress) !void {
    if (target.block_size != 512 or target.block_count < minimum_blocks or target.block_count > std.math.maxInt(u64) / 512 or target.write_fn == null or target.flush_fn == null or std.mem.allEqual(u8, &guid, 0) or manifest.count == 0 or manifest.count > max_extents) return error.InvalidInstallTarget;
    // Verify the complete source before the first target mutation, including retries.
    try validateContents(source, manifest);
    var blank: [512]u8 = @splat(0);
    try checkedWrite(target, 0, &blank);
    try checkedWrite(target, 1, &blank);
    try checkedWrite(target, target.block_count - 1, &blank);
    try target.flush();
    var total: u64 = esp_blocks + data_blocks + 70;
    for (manifest.extents[0..manifest.count]) |extent| total += extent.blocks;
    var completed: u64 = 3;
    for ([_]struct { first: u64, count: u64 }{ .{ .first = esp_first, .count = esp_blocks }, .{ .first = data_first, .count = data_blocks } }) |region| {
        var block: u64 = 0;
        @memset(&transfer, 0);
        while (block < region.count) {
            const count: u64 = @min(chunk_bytes / 512, region.count - block);
            try checkedWrite(target, region.first + block, transfer[0..@intCast(count * 512)]);
            block += count;
            completed += count;
            progress.notify_fn(progress.context, completed, total);
        }
    }
    for (manifest.extents[0..manifest.count]) |extent| {
        var checksum = std.hash.Crc32.init();
        var block: u64 = 0;
        while (block < extent.blocks) {
            const count: u64 = @min(chunk_bytes / 512, extent.blocks - block);
            const bytes: usize = @intCast(count * 512);
            try source.read(extent.offset + block * 512, transfer[0..bytes]);
            checksum.update(transfer[0..bytes]);
            try checkedWrite(target, extent.first + block, transfer[0..bytes]);
            block += count;
            completed += count;
            progress.notify_fn(progress.context, completed, total);
        }
        if (checksum.final() != extent.crc) return error.PayloadChecksum;
    }
    @memset(&entries, 0);
    partitionRow(0, esp_type, guid, esp_first, esp_blocks, "Bedrock ESP");
    partitionRow(1, fs.partition.bedrock_data_type, guid, data_first, data_blocks, "Bedrock Data");
    try checkedWrite(target, target.block_count - 33, &entries);
    try checkedWrite(target, target.block_count - 1, &gptHeader(target.block_count, guid, true));
    try target.flush();
    try checkedWrite(target, 2, &entries);
    try checkedWrite(target, 1, &gptHeader(target.block_count, guid, false));
    blank[446..450].* = .{ 0, 0, 2, 0 };
    blank[450..454].* = .{ 0xee, 0xff, 0xff, 0xff };
    put(u32, blank[454..458], 1);
    put(u32, blank[458..462], @intCast(@min(target.block_count - 1, std.math.maxInt(u32))));
    blank[510] = 0x55;
    blank[511] = 0xaa;
    try checkedWrite(target, 0, &blank);
    try target.flush();
    const partition = (try fs.partition.parseBedrockData(target)) orelse return error.InstallReadback;
    if (partition.first_block != data_first or partition.block_count != data_blocks) return error.InstallReadback;
    // Read the published partition bytes again after the final durability barrier.
    for (manifest.extents[0..manifest.count]) |extent| {
        var checksum = std.hash.Crc32.init();
        var block: u64 = 0;
        while (block < extent.blocks) {
            const count: u64 = @min(chunk_bytes / 512, extent.blocks - block);
            try target.read(extent.first + block, transfer[0..@intCast(count * 512)]);
            checksum.update(transfer[0..@intCast(count * 512)]);
            block += count;
        }
        if (checksum.final() != extent.crc) return error.InstallReadback;
    }
    progress.notify_fn(progress.context, total, total);
}
