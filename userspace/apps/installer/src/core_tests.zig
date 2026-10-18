const std = @import("std");
const t = std.testing;
const fs = @import("filesystem");
const core = @import("core.zig");

const machine: u16 = 62; // ELF EM_X86_64, matching the installation payload.
const disk_guid: [16]u8 = .{ 0x44, 0x33, 0x22, 0x11, 0x66, 0x55, 0x88, 0x47, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff, 0x10 };
const sentinel = 0xa5;

const Fixture = struct {
    // Metadata need not be block aligned: the source is a checked byte stream.
    bytes: [512 + 2 * 32 + 4 * 512]u8 = @splat(0),
    reads: usize = 0,
    fail_offset: ?u64 = null,

    fn init() Fixture {
        var self: Fixture = .{};
        @memcpy(self.bytes[0..8], "BEDIP001");
        put(u32, self.bytes[8..12], 1);
        put(u16, self.bytes[12..14], machine);
        put(u16, self.bytes[14..16], 512);
        put(u64, self.bytes[16..24], self.bytes.len);
        put(u64, self.bytes[24..32], core.esp_first);
        put(u64, self.bytes[32..40], core.esp_blocks);
        put(u64, self.bytes[40..48], core.data_first);
        put(u64, self.bytes[48..56], core.data_blocks);
        put(u32, self.bytes[56..60], 2);
        @memset(self.bytes[64..96], 0x33);
        for (self.bytes[576..], 0..) |*byte, index| byte.* = @truncate(index * 17 + 9);
        self.row(0, core.esp_first, 2, 576);
        self.row(1, core.data_first, 2, 576 + 2 * 512);
        self.sealTable();
        return self;
    }
    fn row(self: *Fixture, index: usize, first: u64, blocks: u64, offset: u64) void {
        const record = self.bytes[512 + index * 32 ..][0..32];
        put(u64, record[0..8], first);
        put(u64, record[8..16], blocks);
        put(u64, record[16..24], offset);
        const start: usize = @intCast(offset);
        const length: usize = @intCast(blocks * 512);
        put(u32, record[24..28], fs.partition.crc32(self.bytes[start..][0..length]));
    }
    fn sealTable(self: *Fixture) void {
        put(u32, self.bytes[60..64], fs.partition.crc32(self.bytes[512..576]));
        self.sealHeader();
    }
    fn sealHeader(self: *Fixture) void {
        @memset(self.bytes[124..128], 0);
        put(u32, self.bytes[124..128], fs.partition.crc32(self.bytes[0..512]));
    }
    fn source(self: *Fixture) core.Source {
        return .{ .context = self, .byte_count = self.bytes.len, .read_fn = read };
    }
    fn read(context: *anyopaque, offset: u64, output: []u8) !void {
        const self: *Fixture = @ptrCast(@alignCast(context));
        self.reads += 1;
        if (self.fail_offset == offset) return error.SourceReadFailed;
        if (offset > self.bytes.len or output.len > self.bytes.len - offset) return error.UnsafeSourceRead;
        @memcpy(output, self.bytes[@as(usize, @intCast(offset))..][0..output.len]);
    }
};

const Disk = struct {
    bytes: []u8 = &.{},
    blocks: u64 = core.minimum_blocks,
    reads: usize = 0,
    writes: usize = 0,
    flushes: usize = 0,
    fail_write: ?usize = null,
    ignore_write: ?usize = null,
    fail_flush: ?usize = null,
    fail_read: ?usize = null,

    fn init(blocks: u64) !Disk {
        const bytes = try t.allocator.alloc(u8, @intCast(blocks * 512));
        @memset(bytes, sentinel);
        return .{ .bytes = bytes, .blocks = blocks };
    }
    fn deinit(self: *Disk) void {
        t.allocator.free(self.bytes);
    }
    fn device(self: *Disk) fs.BlockDevice {
        return .{ .context = self, .read_fn = read, .write_fn = write, .flush_fn = flush, .block_size = 512, .block_count = self.blocks };
    }
    fn slice(self: *Disk, start: u64, count: u64, length: usize) ![]u8 {
        const end = std.math.add(u64, start, count) catch return error.UnsafeTargetRequest;
        if (end > self.blocks or length != count * 512) return error.UnsafeTargetRequest;
        const begin: usize = @intCast(start * 512);
        if (begin > self.bytes.len or length > self.bytes.len - begin) return error.UnexpectedTargetAccess;
        return self.bytes[begin..][0..length];
    }
    fn read(context: *anyopaque, start: u64, count: u64, output: []u8) !void {
        const self: *Disk = @ptrCast(@alignCast(context));
        self.reads += 1;
        if (self.fail_read == self.reads) return error.TargetReadFailed;
        @memcpy(output, try self.slice(start, count, output.len));
    }
    fn write(context: *anyopaque, start: u64, count: u64, input: []const u8) !void {
        const self: *Disk = @ptrCast(@alignCast(context));
        self.writes += 1;
        if (self.fail_write == self.writes) return error.TargetWriteFailed;
        const destination = try self.slice(start, count, input.len);
        if (self.ignore_write == self.writes) return;
        @memcpy(destination, input);
    }
    fn flush(context: *anyopaque) !void {
        const self: *Disk = @ptrCast(@alignCast(context));
        self.flushes += 1;
        if (self.fail_flush == self.flushes) return error.TargetFlushFailed;
    }
};

const Progress = struct {
    calls: usize = 0,
    completed: u64 = 0,
    total: u64 = 0,
    malformed: bool = false,
    fn callback(self: *Progress) core.Progress {
        return .{ .context = self, .notify_fn = notify };
    }
    fn notify(context: *anyopaque, completed: u64, total: u64) void {
        const self: *Progress = @ptrCast(@alignCast(context));
        if (total == 0 or completed > total or completed < self.completed or (self.calls != 0 and self.total != total)) self.malformed = true;
        self.calls += 1;
        self.completed = completed;
        self.total = total;
    }
};

fn run(fixture: *Fixture, disk: *Disk, architecture: u16, progress: *Progress) !void {
    var manifest: core.Manifest = .{};
    try core.Manifest.load(fixture.source(), architecture, &manifest);
    try core.install(fixture.source(), &manifest, disk.device(), disk_guid, progress.callback());
}
fn put(comptime T: type, bytes: []u8, value: T) void {
    std.mem.writeInt(T, bytes[0..@sizeOf(T)], value, .little);
}
fn get(comptime T: type, bytes: []const u8) T {
    return std.mem.readInt(T, bytes[0..@sizeOf(T)], .little);
}
fn expectNoTargetAccess(disk: *const Disk) !void {
    try t.expectEqual(@as(usize, 0), disk.reads + disk.writes + disk.flushes);
}
fn expectSentinel(bytes: []const u8) !void {
    try t.expect(std.mem.allEqual(u8, bytes, sentinel));
}

test "payload header, metadata CRCs and architecture reject before target access" {
    var disk: Disk = .{};
    var progress: Progress = .{};
    var fixture = Fixture.init();
    fixture.bytes[0] ^= 1;
    fixture.sealHeader();
    try t.expectError(error.InvalidPayload, run(&fixture, &disk, machine, &progress));
    fixture = Fixture.init();
    fixture.bytes[124] ^= 1;
    try t.expectError(error.InvalidPayload, run(&fixture, &disk, machine, &progress));
    fixture = Fixture.init();
    fixture.bytes[60] ^= 1;
    fixture.sealHeader();
    try t.expectError(error.InvalidPayload, run(&fixture, &disk, machine, &progress));
    fixture = Fixture.init();
    try t.expectError(error.InvalidPayload, run(&fixture, &disk, 183, &progress));
    fixture = Fixture.init();
    fixture.bytes[96] = 1;
    fixture.sealHeader();
    try t.expectError(error.InvalidPayload, run(&fixture, &disk, machine, &progress));
    try expectNoTargetAccess(&disk);
    try t.expectEqual(@as(usize, 0), progress.calls);
}

test "manifest extent order, source spans and partition boundaries reject before writes" {
    var disk: Disk = .{};
    var progress: Progress = .{};
    const cases = [_]struct { offset: usize, value: u64 }{
        .{ .offset = 512, .value = 1 }, // metadata is never a payload extent
        .{ .offset = 512, .value = core.esp_first - 1 },
        .{ .offset = 512, .value = core.esp_first + core.esp_blocks - 1 },
        .{ .offset = 520, .value = 0 },
        .{ .offset = 520, .value = std.math.maxInt(u64) },
        .{ .offset = 528, .value = 575 },
        .{ .offset = 544, .value = core.esp_first }, // overlaps prior extent
        .{ .offset = 544, .value = core.data_first + core.data_blocks - 1 },
        .{ .offset = 560, .value = 576 }, // repeated source offset
        .{ .offset = 560, .value = std.math.maxInt(u64) },
    };
    for (cases) |case| {
        var fixture = Fixture.init();
        put(u64, fixture.bytes[case.offset..][0..8], case.value);
        fixture.sealTable();
        try t.expectError(error.InvalidPayload, run(&fixture, &disk, machine, &progress));
        try expectNoTargetAccess(&disk);
    }
    var fixture = Fixture.init();
    put(u32, fixture.bytes[540..544], 1);
    fixture.sealTable();
    try t.expectError(error.InvalidPayload, run(&fixture, &disk, machine, &progress));
    try expectNoTargetAccess(&disk);
}

test "malformed source bytes and source I/O failures never mutate the target" {
    var disk: Disk = .{};
    var progress: Progress = .{};
    var fixture = Fixture.init();
    fixture.bytes[576] ^= 1;
    try t.expectError(error.PayloadChecksum, run(&fixture, &disk, machine, &progress));
    fixture = Fixture.init();
    fixture.fail_offset = 576;
    try t.expectError(error.SourceReadFailed, run(&fixture, &disk, machine, &progress));
    try expectNoTargetAccess(&disk);
    try t.expectEqual(@as(usize, 0), progress.calls);
}

test "source and extent count size limits are enforced before writes" {
    var fixture = Fixture.init();
    var manifest: core.Manifest = .{};
    var source = fixture.source();
    source.byte_count = 511;
    try t.expectError(error.InvalidPayload, core.Manifest.load(source, machine, &manifest));
    source.byte_count = 64 * 1024 * 1024 + 1;
    try t.expectError(error.InvalidPayload, core.Manifest.load(source, machine, &manifest));
    fixture = Fixture.init();
    put(u32, fixture.bytes[56..60], 257);
    fixture.sealHeader();
    try t.expectError(error.InvalidPayload, core.Manifest.load(fixture.source(), machine, &manifest));
    fixture = Fixture.init();
    put(u32, fixture.bytes[56..60], 0);
    fixture.sealHeader();
    try t.expectError(error.InvalidPayload, core.Manifest.load(fixture.source(), machine, &manifest));
}

test "undersize, read-only, no flush and incompatible target geometry fail before mutation" {
    var fixture = Fixture.init();
    var manifest: core.Manifest = .{};
    try core.Manifest.load(fixture.source(), machine, &manifest);
    var disk: Disk = .{};
    var progress: Progress = .{};
    var device = disk.device();
    device.block_count = core.minimum_blocks - 1;
    try t.expectError(error.InvalidInstallTarget, core.install(fixture.source(), &manifest, device, disk_guid, progress.callback()));
    device = disk.device();
    device.write_fn = null;
    try t.expectError(error.InvalidInstallTarget, core.install(fixture.source(), &manifest, device, disk_guid, progress.callback()));
    device = disk.device();
    device.flush_fn = null;
    try t.expectError(error.InvalidInstallTarget, core.install(fixture.source(), &manifest, device, disk_guid, progress.callback()));
    device = disk.device();
    device.block_size = 4096;
    try t.expectError(error.InvalidInstallTarget, core.install(fixture.source(), &manifest, device, disk_guid, progress.callback()));
    device = disk.device();
    device.block_count = std.math.maxInt(u64);
    try t.expectError(error.InvalidInstallTarget, core.install(fixture.source(), &manifest, device, disk_guid, progress.callback()));
    try t.expectError(error.InvalidInstallTarget, core.install(fixture.source(), &manifest, disk.device(), @splat(0), progress.callback()));
    try expectNoTargetAccess(&disk);
    try t.expectEqual(@as(usize, 0), progress.calls);
}

test "loaded source is checked again before every install attempt" {
    var fixture = Fixture.init();
    var manifest: core.Manifest = .{};
    try core.Manifest.load(fixture.source(), machine, &manifest);
    fixture.bytes[576] ^= 1;
    var disk: Disk = .{};
    var progress: Progress = .{};
    try t.expectError(error.PayloadChecksum, core.install(fixture.source(), &manifest, disk.device(), disk_guid, progress.callback()));
    try expectNoTargetAccess(&disk);
}

test "installer publishes two matching GPT partitions at each actual disk end and preserves free ranges" {
    for ([_]u64{ core.minimum_blocks, core.minimum_blocks + 8192 }) |blocks| {
        var fixture = Fixture.init();
        var disk = try Disk.init(blocks);
        defer disk.deinit();
        var progress: Progress = .{};
        try run(&fixture, &disk, machine, &progress);
        const partition = (try fs.partition.parseBedrockData(disk.device())).?;
        try t.expectEqual(core.data_first, partition.first_block);
        try t.expectEqual(core.data_blocks, partition.block_count);
        const primary = disk.bytes[512..1024];
        const backup = disk.bytes[@as(usize, @intCast(blocks - 1)) * 512 ..][0..512];
        try t.expectEqual(@as(u64, 1), get(u64, primary[24..32]));
        try t.expectEqual(blocks - 1, get(u64, primary[32..40]));
        try t.expectEqual(blocks - 1, get(u64, backup[24..32]));
        try t.expectEqual(@as(u64, 1), get(u64, backup[32..40]));
        try t.expectEqual(blocks - 33, get(u64, backup[72..80]));
        const table = disk.bytes[2 * 512 .. 34 * 512];
        try t.expectEqualSlices(u8, table, disk.bytes[@as(usize, @intCast(blocks - 33)) * 512 ..][0..16384]);
        try t.expectEqualSlices(u8, &fs.partition.bedrock_data_type, table[128..144]);
        try t.expectEqual(core.esp_first, get(u64, table[32..40]));
        try t.expectEqual(core.esp_first + core.esp_blocks - 1, get(u64, table[40..48]));
        try t.expect(std.mem.allEqual(u8, table[256..], 0));
        try t.expectEqualSlices(u8, fixture.bytes[576..1600], disk.bytes[core.esp_first * 512 ..][0..1024]);
        try t.expectEqualSlices(u8, fixture.bytes[1600..2624], disk.bytes[core.data_first * 512 ..][0..1024]);
        try t.expect(std.mem.allEqual(u8, disk.bytes[(core.esp_first + 2) * 512 .. (core.esp_first + core.esp_blocks) * 512], 0));
        try t.expect(std.mem.allEqual(u8, disk.bytes[(core.data_first + 2) * 512 .. (core.data_first + core.data_blocks) * 512], 0));
        try expectSentinel(disk.bytes[34 * 512 .. core.esp_first * 512]);
        try expectSentinel(disk.bytes[(core.esp_first + core.esp_blocks) * 512 .. core.data_first * 512]);
        try expectSentinel(disk.bytes[(core.data_first + core.data_blocks) * 512 .. @as(usize, @intCast(blocks - 33)) * 512]);
        try t.expect(!progress.malformed);
        try t.expect(progress.calls > 0);
        try t.expectEqual(progress.total, progress.completed);
        try t.expectEqual(@as(usize, 3), disk.flushes);
    }
}

test "failed writes, readback and flush barriers cannot report install success" {
    const cases = [_]struct { fail_write: ?usize = null, ignore_write: ?usize = null, fail_flush: ?usize = null, fail_read: ?usize = null, expected: anyerror }{
        .{ .fail_write = 1, .expected = error.TargetWriteFailed },
        .{ .fail_write = 10, .expected = error.TargetWriteFailed },
        .{ .ignore_write = 1, .expected = error.InstallReadback },
        .{ .ignore_write = 10, .expected = error.InstallReadback },
        .{ .fail_read = 1, .expected = error.TargetReadFailed },
        .{ .fail_flush = 1, .expected = error.TargetFlushFailed },
        .{ .fail_flush = 2, .expected = error.TargetFlushFailed },
        .{ .fail_flush = 3, .expected = error.TargetFlushFailed },
    };
    for (cases) |case| {
        var fixture = Fixture.init();
        var disk = try Disk.init(core.minimum_blocks);
        defer disk.deinit();
        disk.fail_write = case.fail_write;
        disk.ignore_write = case.ignore_write;
        disk.fail_flush = case.fail_flush;
        disk.fail_read = case.fail_read;
        var progress: Progress = .{};
        try t.expectError(case.expected, run(&fixture, &disk, machine, &progress));
        try t.expect(!progress.malformed);
    }
}
