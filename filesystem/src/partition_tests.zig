const std = @import("std");
const t = std.testing;
const storage = @import("root.zig");
const gpt = @import("partition.zig");

const TestDisk = struct {
    bytes: [128][512]u8 = @splat(@splat(0)),
    reads: usize = 0,
    writes: usize = 0,
    flushes: usize = 0,
    last_start: u64 = 0,
    last_count: u64 = 0,
    fail_lba: ?u64 = null,

    fn device(self: *TestDisk) storage.BlockDevice {
        return .{ .context = self, .read_fn = read, .write_fn = write, .flush_fn = flush, .block_size = 512, .block_count = self.bytes.len };
    }
    fn read(context: *anyopaque, start: u64, count: u64, output: []u8) !void {
        const self: *TestDisk = @ptrCast(@alignCast(context));
        self.reads += 1;
        if (self.fail_lba == start) return error.FailedRead;
        self.last_start = start;
        self.last_count = count;
        if (start + count > self.bytes.len or output.len != count * 512) return error.UnsafeBackendCall;
        @memcpy(output, std.mem.asBytes(&self.bytes)[@as(usize, @intCast(start)) * 512 ..][0..output.len]);
    }
    fn write(context: *anyopaque, start: u64, count: u64, input: []const u8) !void {
        const self: *TestDisk = @ptrCast(@alignCast(context));
        self.writes += 1;
        self.last_start = start;
        self.last_count = count;
        if (start + count > self.bytes.len or input.len != count * 512) return error.UnsafeBackendCall;
        @memcpy(std.mem.asBytes(&self.bytes)[@as(usize, @intCast(start)) * 512 ..][0..input.len], input);
    }
    fn flush(context: *anyopaque) !void {
        const self: *TestDisk = @ptrCast(@alignCast(context));
        self.flushes += 1;
    }
    fn valid(self: *TestDisk) void {
        self.bytes = @splat(@splat(0));
        const mbr = &self.bytes[0];
        mbr[450] = 0xee;
        put(u32, mbr[454..458], 1);
        put(u32, mbr[458..462], 127);
        mbr[510] = 0x55;
        mbr[511] = 0xaa;
        self.entry(0, gpt.bedrock_data_type, 0x44, 16, 79);
        self.sealTables();
    }
    fn entry(self: *TestDisk, index: usize, type_guid: [16]u8, id: u8, first: u64, last: u64) void {
        const record = self.bytes[2 + index / 4][index % 4 * 128 ..][0..128];
        @memset(record, 0);
        @memcpy(record[0..16], &type_guid);
        @memset(record[16..32], id);
        put(u64, record[32..40], first);
        put(u64, record[40..48], last);
    }
    fn sealTables(self: *TestDisk) void {
        self.bytes[126] = self.bytes[2];
        const crc = gpt.crc32(&self.bytes[2]);
        self.header(1, 127, 2, crc);
        self.header(127, 1, 126, crc);
    }
    fn header(self: *TestDisk, index: usize, alternate: u64, entries_lba: u64, table_crc: u32) void {
        const header_bytes = &self.bytes[index];
        header_bytes.* = @splat(0);
        @memcpy(header_bytes[0..8], "EFI PART");
        put(u32, header_bytes[8..12], 0x0001_0000);
        put(u32, header_bytes[12..16], 92);
        put(u64, header_bytes[24..32], index);
        put(u64, header_bytes[32..40], alternate);
        put(u64, header_bytes[40..48], 3);
        put(u64, header_bytes[48..56], 125);
        @memset(header_bytes[56..72], 0x22);
        put(u64, header_bytes[72..80], entries_lba);
        put(u32, header_bytes[80..84], 4);
        put(u32, header_bytes[84..88], 128);
        put(u32, header_bytes[88..92], table_crc);
        self.sealHeader(index);
    }
    fn sealHeader(self: *TestDisk, index: usize) void {
        const bytes = &self.bytes[index];
        @memset(bytes[16..20], 0);
        put(u32, bytes[16..20], gpt.crc32(bytes[0..get(u32, bytes[12..16])]));
    }
};

fn put(comptime T: type, bytes: []u8, value: T) void {
    std.mem.writeInt(T, bytes[0..@sizeOf(T)], value, .little);
}
fn get(comptime T: type, bytes: []const u8) T {
    return std.mem.readInt(T, bytes[0..@sizeOf(T)], .little);
}

test "matching GPT copies discover exactly the custom Bedrock type without writes" {
    var disk: TestDisk = .{};
    disk.valid();
    const result = (try gpt.parseBedrockData(disk.device())).?;
    try t.expectEqual(@as(u64, 16), result.first_block);
    try t.expectEqual(@as(u64, 64), result.block_count);
    try t.expectEqualSlices(u8, &@as([16]u8, @splat(0x44)), &result.unique_guid);
    try t.expectEqual(@as(usize, 5), disk.reads);
    try t.expectEqual(@as(usize, 0), disk.writes);
    try t.expectEqual(@as(usize, 0), disk.flushes);
    try t.expectEqual(@as(u32, 0xcbf4_3926), gpt.crc32("123456789"));
}

test "non-GPT and GPT without our data type are ignored without formatting" {
    var disk: TestDisk = .{};
    try t.expectEqual(@as(?gpt.Partition, null), try gpt.parseBedrockData(disk.device()));
    disk.valid();
    disk.entry(0, @splat(0x11), 0x44, 16, 79);
    disk.sealTables();
    try t.expectEqual(@as(?gpt.Partition, null), try gpt.parseBedrockData(disk.device()));
    try t.expectEqual(@as(usize, 0), disk.writes);
    try t.expectEqual(@as(usize, 0), disk.flushes);
}

test "bad primary, backup and array CRCs are rejected" {
    var disk: TestDisk = .{};
    disk.valid();
    disk.bytes[1][56] ^= 1;
    try t.expectError(error.InvalidGptHeaderCrc, gpt.parseBedrockData(disk.device()));
    disk.valid();
    disk.bytes[127][56] ^= 1;
    try t.expectError(error.InvalidGptHeaderCrc, gpt.parseBedrockData(disk.device()));
    disk.valid();
    disk.bytes[2][56] ^= 1;
    disk.bytes[126][56] ^= 1;
    try t.expectError(error.InvalidGptTableCrc, gpt.parseBedrockData(disk.device()));
    disk.valid();
    disk.bytes[126][56] ^= 1;
    try t.expectError(error.GptCopiesDisagree, gpt.parseBedrockData(disk.device()));
}

test "GPT copies must agree on identity, usable geometry and tables" {
    var disk: TestDisk = .{};
    disk.valid();
    disk.bytes[127][56] ^= 1;
    disk.sealHeader(127);
    try t.expectError(error.GptCopiesDisagree, gpt.parseBedrockData(disk.device()));
    disk.valid();
    put(u64, disk.bytes[127][40..48], 4);
    disk.sealHeader(127);
    try t.expectError(error.GptCopiesDisagree, gpt.parseBedrockData(disk.device()));
    disk.valid();
    put(u32, disk.bytes[127][88..92], get(u32, disk.bytes[127][88..92]) ^ 1);
    disk.sealHeader(127);
    try t.expectError(error.GptCopiesDisagree, gpt.parseBedrockData(disk.device()));
}

test "protective MBR is required and hybrid or truncated MBRs are rejected" {
    var disk: TestDisk = .{};
    disk.valid();
    disk.bytes[0][510] = 0;
    try t.expectError(error.InvalidProtectiveMbr, gpt.parseBedrockData(disk.device()));
    disk.valid();
    disk.bytes[0][462] = 0x80;
    try t.expectError(error.InvalidProtectiveMbr, gpt.parseBedrockData(disk.device()));
    disk.valid();
    put(u32, disk.bytes[0][458..462], 64);
    try t.expectError(error.InvalidProtectiveMbr, gpt.parseBedrockData(disk.device()));
    disk.valid();
    disk.bytes[1][0] = 0;
    try t.expectError(error.InvalidGptHeader, gpt.parseBedrockData(disk.device()));
    disk.bytes[0][450] = 0;
    try t.expectError(error.InvalidGptHeader, gpt.parseBedrockData(disk.device()));
}

test "GPT metadata ranges are validated before table I/O" {
    var disk: TestDisk = .{};
    const cases = [_]struct { index: usize, offset: usize, value: u64, expected: anyerror }{
        .{ .index = 1, .offset = 24, .value = 2, .expected = error.InvalidGptHeaderBounds },
        .{ .index = 127, .offset = 32, .value = 2, .expected = error.InvalidGptHeaderBounds },
        .{ .index = 1, .offset = 40, .value = 0, .expected = error.InvalidGptHeaderBounds },
        .{ .index = 127, .offset = 48, .value = 127, .expected = error.InvalidGptHeaderBounds },
        .{ .index = 1, .offset = 72, .value = 3, .expected = error.InvalidGptTableBounds },
        .{ .index = 127, .offset = 72, .value = 125, .expected = error.InvalidGptTableBounds },
        .{ .index = 1, .offset = 72, .value = std.math.maxInt(u64), .expected = error.InvalidGptTableBounds },
    };
    for (cases) |case| {
        disk.valid();
        disk.reads = 0;
        put(u64, disk.bytes[case.index][case.offset..][0..8], case.value);
        disk.sealHeader(case.index);
        try t.expectError(case.expected, gpt.parseBedrockData(disk.device()));
        try t.expect(disk.reads <= 3);
    }
}

test "oversized or unsupported GPT structures never request their tables" {
    var disk: TestDisk = .{};
    disk.valid();
    put(u32, disk.bytes[1][80..84], 129);
    disk.sealHeader(1);
    try t.expectError(error.UnsupportedGptEntries, gpt.parseBedrockData(disk.device()));
    disk.valid();
    put(u32, disk.bytes[1][84..88], 256);
    disk.sealHeader(1);
    try t.expectError(error.UnsupportedGptEntries, gpt.parseBedrockData(disk.device()));
    disk.valid();
    put(u32, disk.bytes[1][8..12], 0x0001_0001);
    disk.sealHeader(1);
    try t.expectError(error.UnsupportedGptRevision, gpt.parseBedrockData(disk.device()));
    disk.valid();
    put(u32, disk.bytes[1][12..16], 513);
    try t.expectError(error.InvalidGptHeader, gpt.parseBedrockData(disk.device()));
}

test "partition ranges, IDs and duplicate Bedrock entries cannot be ambiguous" {
    var disk: TestDisk = .{};
    disk.valid();
    disk.entry(0, gpt.bedrock_data_type, 0x44, 2, 79);
    disk.sealTables();
    try t.expectError(error.InvalidPartitionBounds, gpt.parseBedrockData(disk.device()));
    disk.valid();
    disk.entry(0, gpt.bedrock_data_type, 0x44, 80, 79);
    disk.sealTables();
    try t.expectError(error.InvalidPartitionBounds, gpt.parseBedrockData(disk.device()));
    disk.valid();
    disk.entry(0, gpt.bedrock_data_type, 0x44, 16, 126);
    disk.sealTables();
    try t.expectError(error.InvalidPartitionBounds, gpt.parseBedrockData(disk.device()));
    disk.valid();
    disk.entry(1, @splat(0x11), 0x55, 79, 90);
    disk.sealTables();
    try t.expectError(error.OverlappingPartitions, gpt.parseBedrockData(disk.device()));
    disk.valid();
    disk.entry(1, @splat(0x11), 0x44, 80, 90);
    disk.sealTables();
    try t.expectError(error.DuplicatePartitionGuid, gpt.parseBedrockData(disk.device()));
    disk.valid();
    disk.entry(0, gpt.bedrock_data_type, 0, 16, 79);
    disk.sealTables();
    try t.expectError(error.InvalidPartitionGuid, gpt.parseBedrockData(disk.device()));
    disk.valid();
    disk.entry(1, gpt.bedrock_data_type, 0x55, 80, 90);
    disk.sealTables();
    try t.expectError(error.DuplicateDataPartition, gpt.parseBedrockData(disk.device()));
}

test "read-only partition attribute is rejected and read failures are preserved" {
    var disk: TestDisk = .{};
    disk.valid();
    put(u64, disk.bytes[2][48..56], @as(u64, 1) << 60);
    disk.sealTables();
    try t.expectError(error.ReadOnlyPartition, gpt.parseBedrockData(disk.device()));
    disk.valid();
    disk.fail_lba = 126;
    try t.expectError(error.FailedRead, gpt.parseBedrockData(disk.device()));
    try t.expectEqual(@as(usize, 0), disk.writes);
}

test "maximum-size arrays stream all sectors and validate their last entry" {
    var disk: TestDisk = .{};
    disk.valid();
    @memset(std.mem.asBytes(&disk.bytes)[2 * 512 .. 34 * 512], 0);
    disk.entry(127, gpt.bedrock_data_type, 0x55, 64, 79);
    const table = std.mem.asBytes(&disk.bytes)[2 * 512 .. 34 * 512];
    @memcpy(std.mem.asBytes(&disk.bytes)[95 * 512 .. 127 * 512], table);
    const crc = gpt.crc32(table);
    disk.header(1, 127, 2, crc);
    disk.header(127, 1, 95, crc);
    for ([_]usize{ 1, 127 }) |index| {
        put(u64, disk.bytes[index][40..48], 34);
        put(u64, disk.bytes[index][48..56], 94);
        put(u32, disk.bytes[index][80..84], 128);
        disk.sealHeader(index);
    }
    const result = (try gpt.parseBedrockData(disk.device())).?;
    try t.expectEqual(@as(u64, 64), result.first_block);
    try t.expectEqual(@as(u64, 16), result.block_count);
    try t.expectEqual(@as(usize, 67), disk.reads);
    disk.bytes[126][511] ^= 1;
    try t.expectError(error.GptCopiesDisagree, gpt.parseBedrockData(disk.device()));
}

test "partial array CRC covers entries and ignores unrelated sector padding" {
    var disk: TestDisk = .{};
    disk.valid();
    const crc = gpt.crc32(disk.bytes[2][0..128]);
    for ([_]usize{ 1, 127 }) |index| {
        put(u32, disk.bytes[index][80..84], 1);
        put(u32, disk.bytes[index][88..92], crc);
        disk.sealHeader(index);
    }
    disk.bytes[126][511] = 0x66;
    try t.expect((try gpt.parseBedrockData(disk.device())) != null);
}

test "bounded view offsets reads, writes and flushes without crossing partitions" {
    var disk: TestDisk = .{};
    disk.valid();
    var view = try gpt.View.init(disk.device(), (try gpt.parseBedrockData(disk.device())).?);
    var device = view.device();
    var bytes: [512]u8 = @splat(0x5a);
    try device.write(63, &bytes);
    try t.expectEqual(@as(u64, 79), disk.last_start);
    try t.expectEqual(@as(u64, 1), disk.last_count);
    @memset(&bytes, 0);
    try device.read(63, &bytes);
    try t.expectEqual(@as(u8, 0x5a), bytes[511]);
    try device.flush();
    try t.expectEqual(@as(usize, 1), disk.flushes);
    const calls = disk.reads + disk.writes;
    try t.expectError(error.OutOfBounds, device.write(64, &bytes));
    try t.expectError(error.OutOfBounds, device.read(64, &bytes));
    try t.expectError(error.InvalidBufferLength, device.read(0, bytes[0..511]));
    try t.expectEqual(calls, disk.reads + disk.writes);
    try device.read(64, bytes[0..0]);
    try t.expectEqual(calls, disk.reads + disk.writes);
    try t.expectEqual(@as(u8, 0), disk.bytes[15][0]);
    try t.expectEqual(@as(u8, 0), disk.bytes[80][0]);
}

test "view rejects overflow, changed bounds and revoked write authority" {
    var disk: TestDisk = .{};
    const good: gpt.Partition = .{ .first_block = 16, .block_count = 64, .unique_guid = @splat(0x44), .attributes = 0 };
    var bad = good;
    bad.first_block = std.math.maxInt(u64);
    try t.expectError(error.ArithmeticOverflow, gpt.View.init(disk.device(), bad));
    bad = good;
    bad.block_count = 0;
    try t.expectError(error.InvalidGeometry, gpt.View.init(disk.device(), bad));
    bad = good;
    bad.first_block = 100;
    try t.expectError(error.OutOfBounds, gpt.View.init(disk.device(), bad));
    var view = try gpt.View.init(disk.device(), good);
    const retained = view.device();
    var bytes: [512]u8 = @splat(0);
    view.partition.block_count = 1;
    try t.expectError(error.OutOfBounds, retained.write(2, &bytes));
    view.partition = good;
    view.partition.attributes = @as(u64, 1) << 60;
    try t.expectError(error.ReadOnly, retained.write(0, &bytes));
    try t.expectError(error.ReadOnly, view.device().write(0, &bytes));
    view.partition = good;
    view.parent.block_count = 20;
    try t.expectError(error.OutOfBounds, retained.read(0, &bytes));
    try t.expectEqual(@as(usize, 0), disk.reads + disk.writes);
}

const LargeDisk = struct {
    bytes: []u8,
    fn device(self: *LargeDisk) storage.BlockDevice {
        return .{ .context = self, .read_fn = read, .write_fn = write, .flush_fn = flush, .block_size = 512, .block_count = self.bytes.len / 512 };
    }
    fn read(context: *anyopaque, start: u64, count: u64, output: []u8) !void {
        const self: *LargeDisk = @ptrCast(@alignCast(context));
        if (start + count > self.bytes.len / 512 or output.len != count * 512) return error.UnsafeBackendCall;
        @memcpy(output, self.bytes[@as(usize, @intCast(start)) * 512 ..][0..output.len]);
    }
    fn write(context: *anyopaque, start: u64, count: u64, input: []const u8) !void {
        const self: *LargeDisk = @ptrCast(@alignCast(context));
        if (start + count > self.bytes.len / 512 or input.len != count * 512) return error.UnsafeBackendCall;
        @memcpy(self.bytes[@as(usize, @intCast(start)) * 512 ..][0..input.len], input);
    }
    fn flush(_: *anyopaque) !void {}
};

test "durable transactions remount through the view while neighboring sectors stay intact" {
    var disk: LargeDisk = .{ .bytes = try t.allocator.alloc(u8, storage.durable.disk_bytes + 32 * 512) };
    defer t.allocator.free(disk.bytes);
    @memset(disk.bytes, 0xa5);
    var view = try gpt.View.init(disk.device(), .{
        .first_block = 16,
        .block_count = storage.durable.disk_bytes / 512,
        .unique_guid = @splat(0x55),
        .attributes = 0,
    });
    const Fs = storage.durable.DurableFs(12, 64, 96);
    var fs: Fs = .{};
    try fs.format(view.device());
    const metadata: storage.ramfs.Metadata = .{ .domain = .container, .owner = 2 };
    _ = try fs.mkdir("/data", metadata);
    const file = try fs.create("/data/note", metadata);
    _ = try fs.write(file, 0, "partition persistence");
    var recovered: Fs = .{};
    try recovered.mount(view.device());
    var output: [32]u8 = undefined;
    const length = try recovered.read(try recovered.lookup("/data/note"), 0, &output);
    try t.expectEqualStrings("partition persistence", output[0..length]);
    try recovered.nullify("/data/note");
    for (disk.bytes[0 .. 16 * 512]) |byte| try t.expectEqual(@as(u8, 0xa5), byte);
    for (disk.bytes[16 * 512 + storage.durable.disk_bytes ..]) |byte| try t.expectEqual(@as(u8, 0xa5), byte);
}
