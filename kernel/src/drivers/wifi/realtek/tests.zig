// SPDX-License-Identifier: BSD-3-Clause
//! Synthetic format fixtures; vendor payloads are not embedded or executed.
const std = @import("std");
const fw = @import("firmware.zig");
const h2c = @import("h2c.zig");
const profiles = @import("profiles.zig");
const expect = std.testing.expect;
const equal = std.testing.expectEqual;
const fails = std.testing.expectError;
fn put(bytes: []u8, word: u32) void {
    for (0..4) |i| bytes[i] = @truncate(word >> @as(u5, @intCast(i * 8)));
}
fn fixture() [64]u8 {
    var bytes: [64]u8 = @splat(0);
    put(&bytes, 0x88520002); // Preserved raw signature, never chip authority.
    put(bytes[4..], 0x02030d00);
    put(bytes[8..], 0x12345678);
    put(bytes[24..], 1 << 8);
    put(bytes[32..], 0xb8970000);
    put(bytes[36..], (2 << 24) | 16);
    for (bytes[48..], 0..) |*byte, i| byte.* = @intCast(i);
    return bytes;
}
fn mfw(images: []const []const u8, cuts: []const u8, kinds: []const u8, output: []u8) []const u8 {
    @memset(output, 0);
    output[0] = 255;
    output[1] = @intCast(images.len);
    var cursor = 16 + images.len * 16;
    for (images, 0..) |image, i| {
        const entry = output[16 + i * 16 ..][0..16];
        entry[0] = cuts[i];
        entry[1] = kinds[i];
        put(entry[4..], @intCast(cursor));
        put(entry[8..], @intCast(image.len));
        @memcpy(output[cursor..][0..image.len], image);
        cursor += image.len;
    }
    return output[0..cursor];
}
test "v0 unaligned sections preserve raw address and borrowed payload" {
    const bytes = fixture();
    var unaligned: [65]u8 = undefined;
    @memcpy(unaligned[1..], &bytes);
    var out: fw.Image = undefined;
    try fw.inspect(unaligned[1..], .{ .cut = 2 }, &out);
    try equal(@as(u32, 0xb8970000), out.sections[0].raw_destination);
    try equal(@as(u32, 0x18970000), out.sections[0].destination);
    try equal(@as(u32, 0x12345678), out.commit_id);
    try equal(@as(u8, 13), out.version.minor);
    try expect(out.sections[0].bytes.ptr == unaligned[49..].ptr);
    try equal(@as(usize, 16), out.sections[0].bytes.len);
    try expect(out.selected_cut == null);
}
test "every truncation fails and clears borrowed references" {
    const bytes = fixture();
    var out: fw.Image = undefined;
    for (0..bytes.len) |length| {
        if (fw.inspect(bytes[0..length], .{ .cut = 2 }, &out)) |_| return error.UnexpectedAcceptance else |_| {}
        try equal(@as(usize, 0), out.section_count);
        try equal(@as(usize, 0), out.bytes.len);
    }
}
test "header versions section capacities and exact image extent" {
    var bytes = fixture();
    var out: fw.Image = undefined;
    put(bytes[12..], 1 << 24);
    try fails(error.UnsupportedHeaderVersion, fw.inspect(&bytes, .{ .cut = 0 }, &out));
    bytes = fixture();
    put(bytes[24..], 11 << 8);
    try fails(error.SectionCapacity, fw.inspect(&bytes, .{ .cut = 0 }, &out));
    bytes = fixture();
    put(bytes[36..], (2 << 24) | 15);
    try fails(error.TrailingImageBytes, fw.inspect(&bytes, .{ .cut = 0 }, &out));
    try fails(error.NoCompatibleImage, fw.inspect(&bytes, .{ .cut = 0, .kind = .wowlan }, &out));
}
test "multi-image chooses closest cut independently of input order" {
    var a = fixture();
    var b = fixture();
    b[5] = 33;
    var buffer: [512]u8 = undefined;
    const bytes = mfw(&.{ &b, &a }, &.{ 2, 1 }, &.{ 1, 1 }, &buffer);
    var out: fw.Image = undefined;
    try fw.inspect(bytes, .{ .cut = 1 }, &out);
    try equal(@as(?u8, 1), out.selected_cut);
    try equal(@as(u8, 13), out.version.minor);
    try fw.inspect(bytes, .{ .cut = 4 }, &out);
    try equal(@as(?u8, 2), out.selected_cut);
    try equal(@as(u8, 33), out.version.minor);
    try fails(error.NoCompatibleImage, fw.inspect(bytes, .{ .cut = 0 }, &out));
}
test "multi-image MP exclusion and type-specific selection" {
    const a = fixture();
    var buffer: [512]u8 = undefined;
    const bytes = mfw(&.{ &a, &a, &a }, &.{ 2, 1, 2 }, &.{ 1, 1, 3 }, &buffer);
    buffer[18] = 1;
    var out: fw.Image = undefined;
    try fw.inspect(bytes, .{ .cut = 2 }, &out);
    try equal(@as(?u8, 1), out.selected_cut);
    try fw.inspect(bytes, .{ .cut = 2, .kind = .wowlan }, &out);
    try equal(@as(?u8, 2), out.selected_cut);
}
test "multi-image validates unselected entry bounds overlap and ambiguity" {
    const a = fixture();
    var buffer: [512]u8 = undefined;
    var bytes = mfw(&.{ &a, &a }, &.{ 1, 2 }, &.{ 1, 3 }, &buffer);
    var out: fw.Image = undefined;
    put(buffer[32 + 8 ..], 0xffffffff);
    try fails(error.InvalidEntryRange, fw.inspect(bytes, .{ .cut = 1 }, &out));
    bytes = mfw(&.{ &a, &a }, &.{ 1, 2 }, &.{ 1, 3 }, &buffer);
    put(buffer[32 + 4 ..], 48);
    try fails(error.OverlappingEntries, fw.inspect(bytes, .{ .cut = 1 }, &out));
    bytes = mfw(&.{ &a, &a }, &.{ 1, 1 }, &.{ 1, 1 }, &buffer);
    try fails(error.AmbiguousSelection, fw.inspect(bytes, .{ .cut = 1 }, &out));
}
test "multi-image opaque trailing elements are never included in image" {
    const a = fixture();
    var buffer: [512]u8 = undefined;
    const bytes = mfw(&.{&a}, &.{1}, &.{1}, &buffer);
    @memcpy(buffer[bytes.len..][0..3], &[_]u8{ 88, 99, 111 });
    var out: fw.Image = undefined;
    try fw.inspect(buffer[0 .. bytes.len + 3], .{ .cut = 1 }, &out);
    try std.testing.expectEqualSlices(u8, &.{ 88, 99, 111 }, out.trailing_elements);
    try equal(a.len, out.bytes.len);
}
test "dynamic header aggregate length and count are validated" {
    const a = fixture();
    var bytes: [80]u8 = @splat(0);
    @memcpy(bytes[0..48], a[0..48]);
    @memcpy(bytes[64..], a[48..]);
    put(bytes[12..], 64 << 16);
    put(bytes[28..], 1 << 16);
    put(bytes[48..], 16);
    put(bytes[52..], 1);
    var out: fw.Image = undefined;
    try fw.inspect(&bytes, .{ .cut = 1 }, &out);
    try equal(@as(usize, 16), out.dynamic_header.len);
    try equal(@as(u32, 1), out.dynamic_section_count);
    put(bytes[48..], 15);
    try fails(error.InvalidDynamicHeader, fw.inspect(&bytes, .{ .cut = 1 }, &out));
    put(bytes[48..], 16);
    put(bytes[52..], 100);
    try fails(error.InvalidDynamicHeader, fw.inspect(&bytes, .{ .cut = 1 }, &out));
    put(bytes[12..], 32 << 16);
    try fails(error.InvalidDynamicHeader, fw.inspect(&bytes, .{ .cut = 1 }, &out));
}
test "checksum trailers and unformatted security signature extents" {
    const a = fixture();
    var bytes: [600]u8 = @splat(0);
    @memcpy(bytes[0..64], &a);
    put(bytes[36..], (9 << 24) | (1 << 28) | 16);
    put(bytes[40..], 1);
    var out: fw.Image = undefined;
    try fw.inspect(bytes[0..584], .{ .cut = 1 }, &out);
    try equal(@as(usize, 8), out.sections[0].checksum.len);
    try equal(@as(usize, 512), out.sections[0].signatures.len);
    try fails(error.TruncatedSignatures, fw.inspect(bytes[0..583], .{ .cut = 1 }, &out));
    put(bytes[40..], 255);
    try fails(error.UnsupportedFormattedMssc, fw.inspect(bytes[0..584], .{ .cut = 1 }, &out));
    put(bytes[40..], 0xfffffffe);
    try fails(error.TruncatedSignatures, fw.inspect(bytes[0..584], .{ .cut = 1 }, &out));
}
test "destination overflow and section overlap reject" {
    var bytes = fixture();
    put(bytes[32..], 0x1ffffff8);
    var out: fw.Image = undefined;
    try fails(error.SectionAddressOverflow, fw.inspect(&bytes, .{ .cut = 1 }, &out));
    var two: [96]u8 = @splat(0);
    bytes = fixture();
    @memcpy(two[0..48], bytes[0..48]);
    @memcpy(two[48..64], bytes[32..48]);
    put(two[24..], 2 << 8);
    try fails(error.OverlappingSections, fw.inspect(&two, .{ .cut = 1 }, &out));
}
test "H2C packed words match source masks and every fourth receive ACK" {
    var buffer: [32]u8 = @splat(0xaa);
    const packet = try h2c.encode(&buffer, .{ .category = 1, .class = 5, .function = 0x42, .sequence = 4, .done_ack = true }, &.{ 7, 8 });
    try std.testing.expectEqualSlices(u8, &.{ 0x15, 0x42, 0, 4, 10, 0xc0, 0, 0, 7, 8 }, packet);
    const packet2 = try h2c.encode(&buffer, .{ .category = 1, .class = 0, .function = 1, .sequence = 5 }, &.{});
    try equal(@as(u32, 8), fw.le32(packet2[4..]));
}
test "H2C invalid construction is atomic and aliasing is rejected" {
    var buffer: [h2c.max_packet_bytes + 1]u8 = @splat(0xaa);
    const header: h2c.Header = .{ .category = 1, .class = 1, .function = 1, .sequence = 1 };
    try fails(error.InvalidHeader, h2c.encode(&buffer, .{ .category = 4, .class = 1, .function = 1, .sequence = 1 }, &.{}));
    try fails(error.BufferTooSmall, h2c.encode(buffer[0..7], header, &.{}));
    const large: [2041]u8 = @splat(0);
    try fails(error.PacketTooLarge, h2c.encode(&buffer, header, &large));
    try fails(error.AliasedBuffer, h2c.encode(&buffer, header, buffer[0..2]));
    for (buffer) |byte| try equal(@as(u8, 0xaa), byte);
}
test "targeted Realtek IDs never imply a hardware backend" {
    for (&profiles.inventory) |*profile| {
        try expect(profiles.identify(0x10ec, profile.device_id) == profile);
        try expect(!profile.hardware_backend);
    }
    try expect(profiles.identify(0x8086, 0x8852) == null);
    try expect(profiles.identify(0x10ec, 0x8851) == null);
}
