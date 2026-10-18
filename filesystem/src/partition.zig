//! Strict GPT discovery and a borrowed, bounded block-device view. Discovery
//! never writes, repairs or formats media. This profile accepts 512-byte blocks,
//! GPT revision 1.0 and at most 128 standard 128-byte entries.
const std = @import("std");
const storage = @import("root.zig");

pub const sector_bytes = 512;
pub const max_entries = 128;
pub const entry_bytes = 128;
/// 42454452-4f43-4b44-8000-444154410001, serialized in GPT GUID byte order.
pub const bedrock_data_type = [_]u8{ 0x52, 0x44, 0x45, 0x42, 0x43, 0x4f, 0x44, 0x4b, 0x80, 0x00, 0x44, 0x41, 0x54, 0x41, 0x00, 0x01 };

pub const Partition = struct {
    first_block: u64,
    block_count: u64,
    unique_guid: [16]u8,
    attributes: u64,
};

const Header = struct {
    first_usable: u64,
    last_usable: u64,
    disk_guid: [16]u8,
    entries_lba: u64,
    entry_count: u32,
    entries_crc: u32,
    table_blocks: u64,
};

/// Returns null for non-GPT disks or valid GPTs without a Bedrock data entry.
/// A protective MBR or GPT signature makes malformed metadata an error. Both
/// copies must validate and agree before any partition is returned.
pub fn parseBedrockData(device: storage.BlockDevice) !?Partition {
    var primary_bytes: [sector_bytes]u8 = undefined;
    var backup_bytes: [sector_bytes]u8 = undefined;
    var empty: [0]u8 = .{};
    try device.read(0, &empty);
    if (device.block_size != sector_bytes) return error.UnsupportedBlockSize;
    if (device.block_count < 3) return null;
    try device.read(0, &backup_bytes);
    const protective = backup_bytes[450] == 0xee;
    try device.read(1, &primary_bytes);
    if (!std.mem.eql(u8, primary_bytes[0..8], "EFI PART")) {
        if (protective) return error.InvalidGptHeader;
        try device.read(device.block_count - 1, &backup_bytes);
        if (std.mem.eql(u8, backup_bytes[0..8], "EFI PART")) return error.InvalidGptHeader;
        return null;
    }
    try validateMbr(&backup_bytes, device.block_count);
    const primary = try parseHeader(&primary_bytes, device.block_count, false);
    try device.read(device.block_count - 1, &backup_bytes);
    const backup = try parseHeader(&backup_bytes, device.block_count, true);
    if (primary.first_usable != backup.first_usable or primary.last_usable != backup.last_usable or
        primary.entry_count != backup.entry_count or primary.entries_crc != backup.entries_crc or
        !std.mem.eql(u8, &primary.disk_guid, &backup.disk_guid)) return error.GptCopiesDisagree;

    var ranges: [max_entries]Partition = undefined;
    var range_count: usize = 0;
    var selected: ?Partition = null;
    var crc: u32 = 0xffff_ffff;
    const bytes_to_hash: usize = @as(usize, primary.entry_count) * entry_bytes;
    for (0..@as(usize, @intCast(primary.table_blocks))) |block_index| {
        try device.read(primary.entries_lba + block_index, &primary_bytes);
        try device.read(backup.entries_lba + block_index, &backup_bytes);
        const length = @min(sector_bytes, bytes_to_hash - block_index * sector_bytes);
        if (!std.mem.eql(u8, primary_bytes[0..length], backup_bytes[0..length])) return error.GptCopiesDisagree;
        crc = crcUpdate(crc, primary_bytes[0..length]);
        for (0..length / entry_bytes) |entry_index| {
            const entry = primary_bytes[entry_index * entry_bytes ..][0..entry_bytes];
            if (allZero(entry[0..16])) continue;
            if (allZero(entry[16..32])) return error.InvalidPartitionGuid;
            const first = get(u64, entry[32..40]);
            const last = get(u64, entry[40..48]);
            if (first < primary.first_usable or last > primary.last_usable or first > last)
                return error.InvalidPartitionBounds;
            const partition: Partition = .{
                .first_block = first,
                .block_count = last - first + 1,
                .unique_guid = entry[16..32].*,
                .attributes = get(u64, entry[48..56]),
            };
            for (ranges[0..range_count]) |previous| {
                if (std.mem.eql(u8, &previous.unique_guid, &partition.unique_guid)) return error.DuplicatePartitionGuid;
                const previous_last = previous.first_block + previous.block_count - 1;
                if (first <= previous_last and previous.first_block <= last) return error.OverlappingPartitions;
            }
            ranges[range_count] = partition;
            range_count += 1;
            if (std.mem.eql(u8, entry[0..16], &bedrock_data_type)) {
                if (selected != null) return error.DuplicateDataPartition;
                // GPT's standard read-only attribute is honored for data mounts.
                if (partition.attributes & (@as(u64, 1) << 60) != 0) return error.ReadOnlyPartition;
                selected = partition;
            }
        }
    }
    if (~crc != primary.entries_crc) return error.InvalidGptTableCrc;
    return selected;
}

fn validateMbr(bytes: *const [sector_bytes]u8, blocks: u64) !void {
    if (bytes[510] != 0x55 or bytes[511] != 0xaa) return error.InvalidProtectiveMbr;
    const record = bytes[446..462];
    if (record[0] != 0 or record[4] != 0xee or get(u32, record[8..12]) != 1 or
        get(u32, record[12..16]) != @as(u32, @intCast(@min(blocks - 1, std.math.maxInt(u32)))) or
        !allZero(bytes[462..510])) return error.InvalidProtectiveMbr;
}

fn parseHeader(bytes: *[sector_bytes]u8, blocks: u64, backup: bool) !Header {
    if (!std.mem.eql(u8, bytes[0..8], "EFI PART")) return error.InvalidGptHeader;
    if (get(u32, bytes[8..12]) != 0x0001_0000) return error.UnsupportedGptRevision;
    const size = get(u32, bytes[12..16]);
    if (size < 92 or size > sector_bytes or get(u32, bytes[20..24]) != 0) return error.InvalidGptHeader;
    const expected_crc = get(u32, bytes[16..20]);
    @memset(bytes[16..20], 0);
    const actual_crc = crc32(bytes[0..size]);
    if (actual_crc != expected_crc) return error.InvalidGptHeaderCrc;
    const current = if (backup) blocks - 1 else 1;
    const alternate = if (backup) 1 else blocks - 1;
    if (get(u64, bytes[24..32]) != current or get(u64, bytes[32..40]) != alternate)
        return error.InvalidGptHeaderBounds;
    const count = get(u32, bytes[80..84]);
    if (count == 0 or count > max_entries or get(u32, bytes[84..88]) != entry_bytes)
        return error.UnsupportedGptEntries;
    const result: Header = .{
        .first_usable = get(u64, bytes[40..48]),
        .last_usable = get(u64, bytes[48..56]),
        .disk_guid = bytes[56..72].*,
        .entries_lba = get(u64, bytes[72..80]),
        .entry_count = count,
        .entries_crc = get(u32, bytes[88..92]),
        .table_blocks = (@as(u64, count) * entry_bytes + sector_bytes - 1) / sector_bytes,
    };
    if (allZero(&result.disk_guid)) return error.InvalidDiskGuid;
    if (result.first_usable < 3 or result.first_usable > result.last_usable or result.last_usable >= blocks - 1)
        return error.InvalidGptHeaderBounds;
    const table_end = std.math.add(u64, result.entries_lba, result.table_blocks) catch return error.InvalidGptTableBounds;
    if (backup) {
        if (result.entries_lba <= result.last_usable or table_end > current) return error.InvalidGptTableBounds;
    } else {
        if (result.entries_lba < 2 or table_end > result.first_usable) return error.InvalidGptTableBounds;
    }
    return result;
}

/// Retain this object at a stable address while any returned BlockDevice lives.
/// Requests are checked again at the forwarding boundary, including if a caller
/// retained a view while its owner changed its geometry.
pub const View = struct {
    parent: storage.BlockDevice,
    partition: Partition,

    pub fn init(parent: storage.BlockDevice, partition: Partition) !View {
        var result: View = .{ .parent = parent, .partition = partition };
        try result.validate(0, 0);
        return result;
    }

    pub fn device(self: *View) storage.BlockDevice {
        return .{
            .context = self,
            .read_fn = read,
            .write_fn = if (self.parent.write_fn != null and self.partition.attributes & (@as(u64, 1) << 60) == 0) write else null,
            .flush_fn = if (self.parent.flush_fn != null) flush else null,
            .block_size = self.parent.block_size,
            .block_count = self.partition.block_count,
        };
    }

    fn validate(self: *const View, start: u64, bytes: usize) !void {
        var empty: [0]u8 = .{};
        try self.parent.read(0, &empty);
        if (self.partition.block_count == 0) return error.InvalidGeometry;
        const partition_end = std.math.add(u64, self.partition.first_block, self.partition.block_count) catch return error.ArithmeticOverflow;
        if (partition_end > self.parent.block_count) return error.OutOfBounds;
        if (bytes % self.parent.block_size != 0) return error.InvalidBufferLength;
        const request_end = std.math.add(u64, start, @as(u64, @intCast(bytes / self.parent.block_size))) catch return error.ArithmeticOverflow;
        if (start > self.partition.block_count or request_end > self.partition.block_count) return error.OutOfBounds;
    }

    fn read(context: *anyopaque, start: u64, _: u64, bytes: []u8) !void {
        const self: *View = @ptrCast(@alignCast(context));
        try self.validate(start, bytes.len);
        try self.parent.read(self.partition.first_block + start, bytes);
    }
    fn write(context: *anyopaque, start: u64, _: u64, bytes: []const u8) !void {
        const self: *View = @ptrCast(@alignCast(context));
        try self.validate(start, bytes.len);
        if (self.partition.attributes & (@as(u64, 1) << 60) != 0) return error.ReadOnly;
        try self.parent.write(self.partition.first_block + start, bytes);
    }
    fn flush(context: *anyopaque) !void {
        const self: *View = @ptrCast(@alignCast(context));
        try self.validate(0, 0);
        try self.parent.flush();
    }
};

pub fn crc32(bytes: []const u8) u32 {
    return ~crcUpdate(0xffff_ffff, bytes);
}
fn crcUpdate(initial: u32, bytes: []const u8) u32 {
    var crc = initial;
    for (bytes) |byte| {
        crc ^= byte;
        for (0..8) |_| crc = (crc >> 1) ^ (if (crc & 1 != 0) @as(u32, 0xedb8_8320) else 0);
    }
    return crc;
}
fn get(comptime T: type, bytes: []const u8) T {
    return std.mem.readInt(T, bytes[0..@sizeOf(T)], .little);
}
fn allZero(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != 0) return false;
    return true;
}

test {
    _ = @import("partition_tests.zig");
}
