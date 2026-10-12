// SPDX-License-Identifier: BSD-3-Clause
//! Synthetic format fixtures only; none contain executable vendor firmware.
const std = @import("std");
const fw = @import("firmware.zig");
const profiles = @import("profiles.zig");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectError = std.testing.expectError;

fn put(bytes: []u8, value: u32) void {
    for (0..4) |i| bytes[i] = @truncate(value >> @as(u5, @intCast(i * 8)));
}
const Fixture = struct {
    bytes: [64 * 1024]u8 = @splat(0),
    len: usize = fw.header_size,
    fn init() Fixture {
        var result: Fixture = .{};
        put(result.bytes[4..], fw.magic);
        put(result.bytes[72..], 17 << 8);
        return result;
    }
    fn tlv(self: *Fixture, kind: u32, data: []const u8) void {
        put(self.bytes[self.len..], kind);
        put(self.bytes[self.len + 4 ..], @intCast(data.len));
        @memcpy(self.bytes[self.len + 8 ..][0..data.len], data);
        self.len += 8 + ((data.len + 3) / 4) * 4;
    }
    fn scalar(self: *Fixture, kind: u32, value: u32) void {
        var data: [4]u8 = undefined;
        put(&data, value);
        self.tlv(kind, &data);
    }
    fn section(self: *Fixture, kind: u32, address: u32, data: []const u8) void {
        var buffer: [64]u8 = undefined;
        put(&buffer, address);
        @memcpy(buffer[4..][0..data.len], data);
        self.tlv(kind, buffer[0 .. 4 + data.len]);
    }
    fn bitmap(self: *Fixture, kind: u32, index: u32, value: u32) void {
        var data: [8]u8 = undefined;
        put(&data, index);
        put(data[4..], value);
        self.tlv(kind, &data);
    }
    fn slice(self: *const Fixture) []const u8 {
        return self.bytes[0..self.len];
    }
};

test "header fields and section bytes borrow a deliberately unaligned source" {
    var f = Fixture.init();
    put(f.bytes[76..], 123);
    f.bytes[80] = 0xcc; // The documented ignored header field is not reserved.
    f.section(19, 0x800000, &.{ 1, 2, 3 });
    f.bytes[f.len - 1] = 0xaa; // Padding may be nonzero.
    var unaligned: [1024]u8 = undefined;
    @memcpy(unaligned[1..][0..f.len], f.slice());
    var out: fw.Container = undefined;
    try fw.inspect(unaligned[1..][0..f.len], &out);
    try expectEqual(@as(u32, 17), out.api);
    try expectEqual(@as(u32, 123), out.build);
    try expectEqual(@as(usize, 1), out.section_count);
    try expect(out.sections[0].bytes.ptr == unaligned[1 + fw.header_size + 12 ..].ptr);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, out.sections[0].bytes);
    try out.requireApi(17, 17);
    try expectError(error.UnsupportedFirmwareApi, out.requireApi(18, 30));
}
test "truncated header magic and legacy distinctions" {
    var f = Fixture.init();
    var out: fw.Container = undefined;
    try expectError(error.TruncatedHeader, fw.inspect(f.bytes[0..87], &out));
    put(f.bytes[4..], 0);
    try expectError(error.InvalidMagic, fw.inspect(f.slice(), &out));
    put(&f.bytes, 1);
    try expectError(error.UnsupportedLegacyFormat, fw.inspect(f.slice(), &out));
}
test "all truncations after the complete header fail and clear output" {
    var f = Fixture.init();
    f.section(19, 0x800000, &.{ 1, 2, 3 });
    var out: fw.Container = undefined;
    for (fw.header_size..f.len) |cut| {
        if (fw.inspect(f.bytes[0..cut], &out)) |_| return error.UnexpectedAcceptance else |_| {}
        try expectEqual(@as(usize, 0), out.section_count);
        try expectEqual(@as(usize, 0), out.tlv_count);
    }
    try fw.inspect(f.slice(), &out);
}
test "large untrusted TLV lengths never wrap the remaining extent" {
    var f = Fixture.init();
    f.tlv(999, &.{});
    put(f.bytes[fw.header_size + 4 ..], 0xffffffff);
    var out: fw.Container = undefined;
    try expectError(error.TruncatedTlv, fw.inspect(f.slice(), &out));
}
test "API and capability flags merge only within pinned bit bounds" {
    var f = Fixture.init();
    put(f.bytes[72..], 77);
    f.section(24, 0x400000, &.{1});
    f.bitmap(29, 0, 1 << 20);
    f.bitmap(29, 0, 1 << 8);
    f.bitmap(29, 2, 1 << 4);
    f.bitmap(30, 4, 3);
    var out: fw.Container = undefined;
    try fw.inspect(f.slice(), &out);
    try expectEqual(@as(u32, 77), out.api);
    try expect(out.hasApi(20) and out.hasApi(8) and out.hasApi(68));
    try expect(!out.hasApi(69) and out.hasCapability(129) and !out.hasCapability(130));
    f.bitmap(30, 4, 4);
    try expectError(error.UnsupportedBitmap, fw.inspect(f.slice(), &out));
}
test "bitmap index and scalar lengths are checked before reading" {
    var f = Fixture.init();
    f.section(19, 0, &.{1});
    f.bitmap(29, 3, 0);
    var out: fw.Container = undefined;
    try expectError(error.UnsupportedBitmap, fw.inspect(f.slice(), &out));
    f = Fixture.init();
    f.tlv(30, &.{ 1, 2, 3 });
    try expectError(error.InvalidTlvLength, fw.inspect(f.slice(), &out));
    f = Fixture.init();
    f.tlv(27, &.{});
    try expectError(error.InvalidTlvLength, fw.inspect(f.slice(), &out));
}
test "version record flags and unknown TLVs remain distinct" {
    var f = Fixture.init();
    f.section(19, 0, &.{1});
    var version: [12]u8 = @splat(0);
    put(&version, 17);
    put(version[4..], 0x12345678);
    put(version[8..], 9);
    f.tlv(36, &version);
    f.scalar(18, 0x102);
    f.tlv(0xfefefefe, &.{ 8, 9 });
    var out: fw.Container = undefined;
    try fw.inspect(f.slice(), &out);
    try expectEqual(@as(u32, 0x12345678), out.version.?.minor);
    try expectEqual(@as(u8, 9), out.version.?.local);
    try expectEqual(@as(u32, 0x102), out.flags);
    try expectEqual(@as(usize, 1), out.unhandled_tlvs);
    f.tlv(36, &version);
    try expectError(error.DuplicateMetadata, fw.inspect(f.slice(), &out));
}
test "metadata ambiguity unsupported legacy and empty images reject" {
    var f = Fixture.init();
    var out: fw.Container = undefined;
    try expectError(error.MissingRuntimeImage, fw.inspect(f.slice(), &out));
    f.scalar(1, 9);
    try expectError(error.UnsupportedLegacySections, fw.inspect(f.slice(), &out));
    f = Fixture.init();
    f.section(19, 0, &.{});
    try expectError(error.EmptySection, fw.inspect(f.slice(), &out));
    f = Fixture.init();
    f.scalar(27, 3);
    try expectError(error.UnsupportedCpuCount, fw.inspect(f.slice(), &out));
    f = Fixture.init();
    f.scalar(18, 0);
    f.scalar(18, 0);
    try expectError(error.DuplicateMetadata, fw.inspect(f.slice(), &out));
}
test "destination overlap distinguishes separate images and CPU banks" {
    var f = Fixture.init();
    f.scalar(27, 2);
    f.section(24, 0x800000, &.{ 1, 2 });
    f.section(25, 0x800000, &.{ 3, 4 });
    f.section(24, fw.cpu_separator, &.{});
    f.section(24, 0x800000, &.{ 5, 6 });
    var out: fw.Container = undefined;
    try fw.inspect(f.slice(), &out);
    try expectEqual(@as(u8, 1), out.sections[3].cpu);
    f.section(24, 0x800001, &.{ 8, 9 });
    try expectError(error.OverlappingSections, fw.inspect(f.slice(), &out));
}
test "destination arithmetic permits exclusive 4GiB end but never wraps" {
    var f = Fixture.init();
    f.section(19, 0xffffffff, &.{1});
    var out: fw.Container = undefined;
    try fw.inspect(f.slice(), &out);
    f = Fixture.init();
    f.section(19, 0xffffffff, &.{ 1, 2 });
    try expectError(error.SectionAddressOverflow, fw.inspect(f.slice(), &out));
}
test "CPU delimiters cannot start repeat or finish an empty bank" {
    var f = Fixture.init();
    f.section(19, fw.cpu_separator, &.{});
    var out: fw.Container = undefined;
    try expectError(error.InvalidSeparator, fw.inspect(f.slice(), &out));
    f = Fixture.init();
    f.scalar(27, 2);
    f.section(19, 0, &.{1});
    f.section(19, fw.cpu_separator, &.{});
    try expectError(error.InvalidSeparator, fw.inspect(f.slice(), &out));
    f.section(19, 0, &.{2});
    f.section(19, fw.cpu_separator, &.{});
    try expectError(error.InvalidSeparator, fw.inspect(f.slice(), &out));
}
test "paging size and paging delimiter metadata are bounded" {
    var f = Fixture.init();
    f.section(19, 0, &.{1});
    f.section(19, fw.paging_separator, &.{});
    f.section(19, 0, &.{2});
    f.scalar(32, 4096);
    var out: fw.Container = undefined;
    try fw.inspect(f.slice(), &out);
    try expect(out.sections[2].paged);
    f = Fixture.init();
    f.scalar(32, 4097);
    try expectError(error.InvalidPagingSize, fw.inspect(f.slice(), &out));
    f = Fixture.init();
    f.scalar(32, fw.max_paging_bytes + 4096);
    try expectError(error.InvalidPagingSize, fw.inspect(f.slice(), &out));
}
test "section and TLV capacity limits are real resources" {
    var f = Fixture.init();
    for (0..fw.max_sections + 1) |i| f.section(19, @intCast(i * 4), &.{1});
    var out: fw.Container = undefined;
    try expectError(error.SectionCapacity, fw.inspect(f.slice(), &out));
    f = Fixture.init();
    for (0..fw.max_tlvs + 1) |_| f.tlv(999, &.{});
    try expectError(error.TlvCapacity, fw.inspect(f.slice(), &out));
}
test "known PCI inventories identify only Intel and never claim a backend" {
    for (&profiles.inventory) |*profile| {
        try expect(profiles.identify(0x8086, profile.device_id) == profile);
        try expect(!profile.hardware_backend);
    }
    try expect(profiles.identify(0x14c3, 0x2723) == null);
    try expect(profiles.identify(0x8086, 0xffff) == null);
    try expectEqual(profiles.Family.ax210, profiles.identify(0x8086, 0x2725).?.family);
    try expect(profiles.identify(0x8086, 0x2723).?.gen2_transport);
}
