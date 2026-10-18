//! Bounded UEFI device paths used to keep installer media out of target lists.
const std = @import("std");
pub const max_bytes = 4096;
pub const max_nodes = 64;

/// Returns the non-terminal prefix, after checking every node and the sole end.
pub fn prefix(bytes: []const u8) ![]const u8 {
    var offset: usize = 0;
    var nodes: usize = 0;
    while (offset < bytes.len and offset < max_bytes and nodes < max_nodes) : (nodes += 1) {
        if (bytes.len - offset < 4) return error.InvalidDevicePath;
        const kind = bytes[offset];
        const subtype = bytes[offset + 1];
        const size = std.mem.readInt(u16, bytes[offset + 2 ..][0..2], .little);
        if (size < 4 or size > bytes.len - offset or size > max_bytes - offset) return error.InvalidDevicePath;
        if (kind == 0x7f) {
            if (subtype != 0xff or size != 4 or offset + size != bytes.len or offset == 0) return error.InvalidDevicePath;
            return bytes[0..offset];
        }
        if (kind == 0 or kind > 5) return error.InvalidDevicePath;
        offset += size;
    }
    return error.InvalidDevicePath;
}

/// The disk path must consist of complete nodes matching the source ancestor.
pub fn isSourceAncestor(disk: []const u8, source: []const u8) !bool {
    const disk_prefix = try prefix(disk);
    const source_prefix = try prefix(source);
    return disk_prefix.len <= source_prefix.len and std.mem.eql(u8, disk_prefix, source_prefix[0..disk_prefix.len]);
}

test "source partition and whole disk ancestry excludes source without excluding sibling disks" {
    const whole = [_]u8{ 3, 1, 6, 0, 1, 0, 0x7f, 0xff, 4, 0 };
    const sibling = [_]u8{ 3, 1, 6, 0, 2, 0, 0x7f, 0xff, 4, 0 };
    const source = [_]u8{ 3, 1, 6, 0, 1, 0, 4, 1, 6, 0, 9, 0, 0x7f, 0xff, 4, 0 };
    try std.testing.expect(try isSourceAncestor(&whole, &source));
    try std.testing.expect(try isSourceAncestor(&source, &source));
    try std.testing.expect(!try isSourceAncestor(&sibling, &source));
    try std.testing.expect(!try isSourceAncestor(&source, &whole));
}

test "malformed truncated multi-instance and empty paths fail closed" {
    for ([_][]const u8{
        &.{},                               &.{ 0x7f, 0xff, 4, 0 },          &.{ 3, 1, 0, 0 },
        &.{ 3, 1, 6, 0, 1 },                &.{ 3, 1, 4, 0, 0x7f, 1, 4, 0 }, &.{ 3, 1, 4, 0, 0x7f, 0xff, 4, 0, 0 },
        &.{ 6, 1, 4, 0, 0x7f, 0xff, 4, 0 },
    }) |bytes| try std.testing.expectError(error.InvalidDevicePath, prefix(bytes));
}

test "device path node count and byte cap are enforced" {
    var bytes: [max_bytes + 4]u8 = @splat(0);
    for (0..max_nodes) |index| @memcpy(bytes[index * 4 ..][0..4], &[_]u8{ 3, 1, 4, 0 });
    @memcpy(bytes[max_nodes * 4 ..][0..4], &[_]u8{ 0x7f, 0xff, 4, 0 });
    try std.testing.expectError(error.InvalidDevicePath, prefix(bytes[0 .. max_nodes * 4 + 4]));
    @memcpy(bytes[0..4], &[_]u8{ 3, 1, 0, 16 });
    @memcpy(bytes[max_bytes..][0..4], &[_]u8{ 0x7f, 0xff, 4, 0 });
    try std.testing.expectError(error.InvalidDevicePath, prefix(&bytes));
}
