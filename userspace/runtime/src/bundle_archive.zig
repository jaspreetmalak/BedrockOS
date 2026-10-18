//! Installed application archive, shared by the installer, loader and kernel.
//! Views borrow a validated immutable allocation; identity records request no
//! authority. The kernel must select grants from its trusted launch catalogue.
const std = @import("std");

pub const magic = "BEDAPP01";
pub const version: u16 = 1;
pub const header_size = 64;
pub const record_size = 160;
pub const max_apps = 8;
pub const max_file_bytes = 2 * 1024 * 1024;
pub const max_archive_bytes = 16 * 1024 * 1024;
pub const payload_alignment = 16;
pub const Architecture = enum(u16) { x86_64 = 62, aarch64 = 183, riscv64 = 243 };
pub const Error = error{
    InvalidHeader,
    UnsupportedVersion,
    ArchitectureMismatch,
    InvalidTable,
    TableHashMismatch,
    InvalidIdentity,
    InvalidPath,
    InvalidExtent,
    InvalidPadding,
    DuplicateIdentity,
    FileHashMismatch,
    InvalidExecutable,
};
pub const Entry = struct {
    app_id: u64,
    app_version: u32,
    name: []const u8,
    path: []const u8,
    bytes: []const u8,
};
pub const Archive = struct {
    bytes: []const u8,
    count: usize,

    /// Index is bounded internally, so callers cannot bypass archive extents.
    pub fn entry(self: *const Archive, index: usize) ?Entry {
        if (index >= self.count or self.count > max_apps) return null;
        const record = self.bytes[header_size + index * record_size ..][0..record_size];
        const name_length = std.mem.indexOfScalar(u8, record[16..48], 0).?;
        const path_length = std.mem.indexOfScalar(u8, record[48..112], 0).?;
        const offset: usize = @intCast(read(u64, record[112..120]));
        const length: usize = @intCast(read(u64, record[120..128]));
        return .{
            .app_id = read(u64, record[0..8]),
            .app_version = read(u32, record[8..12]),
            .name = record[16..][0..name_length],
            .path = record[48..][0..path_length],
            .bytes = self.bytes[offset..][0..length],
        };
    }

    pub fn find(self: *const Archive, app_id: u64) ?Entry {
        for (0..self.count) |index| {
            const item = self.entry(index).?;
            if (item.app_id == app_id) return item;
        }
        return null;
    }
};

/// Validate the entire file before exposing any entry. Hashes detect corruption
/// but are not signatures or a substitute for trusted launch authorization.
pub fn inspect(bytes: []const u8, architecture: Architecture) Error!Archive {
    if (bytes.len < header_size or bytes.len > max_archive_bytes or
        !std.mem.eql(u8, bytes[0..8], magic) or read(u32, bytes[12..16]) != header_size or
        read(u64, bytes[24..32]) != bytes.len) return error.InvalidHeader;
    if (read(u16, bytes[8..10]) != version) return error.UnsupportedVersion;
    if (read(u16, bytes[10..12]) != @backingInt(architecture)) return error.ArchitectureMismatch;
    const count: usize = read(u32, bytes[20..24]);
    if (read(u32, bytes[16..20]) != record_size or count == 0 or count > max_apps)
        return error.InvalidTable;
    const table_end = header_size + count * record_size;
    if (table_end > bytes.len) return error.InvalidTable;
    try hash(bytes[header_size..table_end], bytes[32..64], error.TableHashMismatch);
    var previous_end: usize = table_end;
    const result: Archive = .{ .bytes = bytes, .count = count };
    for (0..count) |index| {
        const record = bytes[header_size + index * record_size ..][0..record_size];
        if (read(u64, record[0..8]) == 0 or read(u32, record[8..12]) != 1 or
            read(u32, record[12..16]) != 1) return error.InvalidIdentity;
        const name = try terminated(record[16..48], error.InvalidIdentity);
        try validateName(name);
        const path = try terminated(record[48..112], error.InvalidPath);
        try validatePath(path);
        const offset = read(u64, record[112..120]);
        const length = read(u64, record[120..128]);
        const expected_offset = (previous_end + payload_alignment - 1) & ~@as(usize, payload_alignment - 1);
        if (offset != expected_offset or length < 64 or length > max_file_bytes or
            offset > bytes.len or length > bytes.len - offset) return error.InvalidExtent;
        if (!std.mem.allEqual(u8, bytes[previous_end..@intCast(offset)], 0)) return error.InvalidPadding;
        const contents = bytes[@intCast(offset)..][0..@intCast(length)];
        try hash(contents, record[128..160], error.FileHashMismatch);
        try executable(contents, architecture);
        previous_end = @intCast(offset + length);
        for (0..index) |other_index| {
            const other = result.entry(other_index).?;
            if (other.app_id == read(u64, record[0..8]) or std.mem.eql(u8, other.name, name))
                return error.DuplicateIdentity;
        }
    }
    if (previous_end != bytes.len) return error.InvalidExtent;
    return result;
}

fn read(comptime T: type, bytes: []const u8) T {
    return std.mem.readInt(T, bytes[0..@sizeOf(T)], .little);
}
fn hash(bytes: []const u8, expected: []const u8, failure: Error) Error!void {
    var actual: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &actual, .{});
    if (!std.mem.eql(u8, &actual, expected)) return failure;
}
fn terminated(bytes: []const u8, failure: Error) Error![]const u8 {
    const end = std.mem.indexOfScalar(u8, bytes, 0) orelse return failure;
    if (end == 0 or !std.mem.allEqual(u8, bytes[end..], 0)) return failure;
    return bytes[0..end];
}
fn validateName(name: []const u8) Error!void {
    if (name.len < 3 or name[0] == '.' or name[name.len - 1] == '.' or
        std.mem.indexOf(u8, name, "..") != null or std.mem.indexOfScalar(u8, name, '.') == null)
        return error.InvalidIdentity;
    for (name) |byte| if (!(byte >= 'a' and byte <= 'z') and !(byte >= '0' and byte <= '9') and byte != '.' and byte != '-')
        return error.InvalidIdentity;
}
fn validatePath(path: []const u8) Error!void {
    if (!std.mem.startsWith(u8, path, "/bundle/") or !std.mem.endsWith(u8, path, ".elf")) return error.InvalidPath;
    var parts = std.mem.splitScalar(u8, path[8..], '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return error.InvalidPath;
        for (part) |byte| if (!(byte >= 'a' and byte <= 'z') and !(byte >= 'A' and byte <= 'Z') and
            !(byte >= '0' and byte <= '9') and byte != '.' and byte != '-' and byte != '_') return error.InvalidPath;
    }
}
fn executable(bytes: []const u8, architecture: Architecture) Error!void {
    if (!std.mem.eql(u8, bytes[0..4], "\x7fELF") or bytes[4] != 2 or bytes[5] != 1 or bytes[6] != 1 or
        read(u16, bytes[16..18]) != 2 or read(u16, bytes[18..20]) != @backingInt(architecture) or
        read(u32, bytes[20..24]) != 1 or read(u16, bytes[52..54]) != 64) return error.InvalidExecutable;
}

const TestArchive = struct {
    bytes: [64 + 2 * 160 + 2 * 64]u8 = @splat(0),
    fn init() TestArchive {
        var self: TestArchive = .{};
        @memcpy(self.bytes[0..8], magic);
        self.set(u16, 8, version);
        self.set(u16, 10, @backingInt(Architecture.x86_64));
        self.set(u32, 12, header_size);
        self.set(u32, 16, record_size);
        self.set(u32, 20, 2);
        self.set(u64, 24, self.bytes.len);
        for (0..2) |index| {
            const base = header_size + index * record_size;
            self.set(u64, base, index + 101);
            self.set(u32, base + 8, 1);
            self.set(u32, base + 12, 1);
            const name = if (index == 0) "org.bedrock.one" else "org.bedrock.two";
            @memcpy(self.bytes[base + 16 ..][0..name.len], name);
            @memcpy(self.bytes[base + 48 ..][0..16], "/bundle/main.elf");
            const offset = header_size + 2 * record_size + index * 64;
            self.set(u64, base + 112, offset);
            self.set(u64, base + 120, 64);
            @memcpy(self.bytes[offset..][0..4], "\x7fELF");
            self.bytes[offset + 4] = 2;
            self.bytes[offset + 5] = 1;
            self.bytes[offset + 6] = 1;
            self.set(u16, offset + 16, 2);
            self.set(u16, offset + 18, 62);
            self.set(u32, offset + 20, 1);
            self.set(u16, offset + 52, 64);
            std.crypto.hash.sha2.Sha256.hash(self.bytes[offset..][0..64], self.bytes[base + 128 ..][0..32], .{});
        }
        self.rehashTable();
        return self;
    }
    fn set(self: *TestArchive, comptime T: type, offset: usize, value: T) void {
        std.mem.writeInt(T, self.bytes[offset..][0..@sizeOf(T)], value, .little);
    }
    fn rehashTable(self: *TestArchive) void {
        std.crypto.hash.sha2.Sha256.hash(self.bytes[header_size .. header_size + 2 * record_size], self.bytes[32..64], .{});
    }
};

test "installed archive exposes immutable independently identified entry images" {
    var fixture = TestArchive.init();
    const archive = try inspect(&fixture.bytes, .x86_64);
    try std.testing.expectEqual(@as(usize, 2), archive.count);
    try std.testing.expectEqualStrings("org.bedrock.one", archive.find(101).?.name);
    try std.testing.expectEqualStrings("/bundle/main.elf", archive.find(102).?.path);
    try std.testing.expectEqual(@as(usize, 64), archive.find(102).?.bytes.len);
    try std.testing.expect(archive.find(103) == null and archive.entry(2) == null);
    try std.testing.expectError(error.ArchitectureMismatch, inspect(&fixture.bytes, .aarch64));
}
test "corrupted tables and file bytes are rejected before any entry publication" {
    var fixture = TestArchive.init();
    fixture.bytes[64] ^= 1;
    try std.testing.expectError(error.TableHashMismatch, inspect(&fixture.bytes, .x86_64));
    fixture = TestArchive.init();
    fixture.bytes[fixture.bytes.len - 1] ^= 1;
    try std.testing.expectError(error.FileHashMismatch, inspect(&fixture.bytes, .x86_64));
}
test "extent bounds overlapping payloads and trailing bytes fail closed" {
    var fixture = TestArchive.init();
    for ([_]u64{ 0, 384, std.math.maxInt(u64) }) |offset| {
        fixture.set(u64, 64 + 160 + 112, offset);
        fixture.rehashTable();
        try std.testing.expectError(error.InvalidExtent, inspect(&fixture.bytes, .x86_64));
    }
    fixture = TestArchive.init();
    fixture.set(u64, 64 + 120, max_file_bytes + 1);
    fixture.rehashTable();
    try std.testing.expectError(error.InvalidExtent, inspect(&fixture.bytes, .x86_64));
    fixture = TestArchive.init();
    fixture.set(u64, 24, fixture.bytes.len - 1);
    try std.testing.expectError(error.InvalidHeader, inspect(&fixture.bytes, .x86_64));
}
test "duplicate identities unknown flags and path traversal cannot enter the catalogue" {
    var fixture = TestArchive.init();
    fixture.set(u64, 64 + 160, 101);
    fixture.rehashTable();
    try std.testing.expectError(error.DuplicateIdentity, inspect(&fixture.bytes, .x86_64));
    fixture = TestArchive.init();
    fixture.set(u32, 64 + 12, 3);
    fixture.rehashTable();
    try std.testing.expectError(error.InvalidIdentity, inspect(&fixture.bytes, .x86_64));
    fixture = TestArchive.init();
    @memset(fixture.bytes[64 + 48 ..][0..64], 0);
    @memcpy(fixture.bytes[64 + 48 ..][0..16], "/bundle/../a.elf");
    fixture.rehashTable();
    try std.testing.expectError(error.InvalidPath, inspect(&fixture.bytes, .x86_64));
}
