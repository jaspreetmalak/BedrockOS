// SPDX-License-Identifier: BSD-3-Clause
//! Optional native format checks against intact, separately licensed reference
//! blobs. Supply `reference_files` from the local cache; production never imports
//! this module, and this source contains no vendor executable bytes.
const std = @import("std");
const fw = @import("firmware.zig");
const reference = @import("reference_files");
test "pinned RTL8852A reference format" {
    var image: fw.Image = undefined;
    try fw.inspect(reference.rtl8852a, .{ .cut = 2 }, &image);
    try std.testing.expectEqual(@as(usize, 3), image.section_count);
    try std.testing.expectEqual(@as(?u8, 2), image.selected_cut);
    try std.testing.expectEqual(@as(usize, 386304), image.bytes.len);
    try std.testing.expectEqual(@as(u8, 13), image.version.minor);
}
test "pinned RTL8852B reference dynamic format" {
    var image: fw.Image = undefined;
    try fw.inspect(reference.rtl8852b, .{ .cut = 2, .kind = .normal_ce }, &image);
    try std.testing.expectEqual(@as(usize, 3), image.section_count);
    try std.testing.expectEqual(@as(?u8, 2), image.selected_cut);
    try std.testing.expectEqual(@as(usize, 326536), image.bytes.len);
    try std.testing.expectEqual(@as(usize, 64), image.dynamic_header.len);
}
test "pinned RTL8852C reference dynamic format" {
    var image: fw.Image = undefined;
    try fw.inspect(reference.rtl8852c, .{ .cut = 2 }, &image);
    try std.testing.expectEqual(@as(usize, 3), image.section_count);
    try std.testing.expectEqual(@as(?u8, 2), image.selected_cut);
    try std.testing.expectEqual(@as(usize, 327720), image.bytes.len);
    try std.testing.expectEqual(@as(u32, 2), image.dynamic_section_count);
}
