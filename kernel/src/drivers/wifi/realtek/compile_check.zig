// SPDX-License-Identifier: BSD-3-Clause
const realtek = @import("root.zig");
export fn bedrock_realtek_wifi_probe(bytes: [*]const u8, length: usize, cut: u8, output: *realtek.firmware.Image, packet: [*]u8, packet_length: usize, device: u16) callconv(.c) u64 {
    realtek.firmware.inspect(bytes[0..length], .{ .cut = cut }, output) catch return 0;
    const profile = realtek.profiles.identify(0x10ec, device) orelse return 0;
    const encoded = realtek.h2c.encode(packet[0..packet_length], .{ .category = 1, .class = 0, .function = 1, .sequence = 0 }, &.{}) catch return 0;
    return encoded.len + output.section_count + @as(u64, @intFromBool(profile.hardware_backend));
}
