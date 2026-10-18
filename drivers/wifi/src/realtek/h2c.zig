// SPDX-License-Identifier: BSD-3-Clause
// Selected BSD option from Linux v6.18 rtw89/fw.c and fw.h.
// Copyright(c) 2019-2020 Realtek Corporation
//! H2C wire header subset only; no command submission, sequence ownership,
//! acknowledgements or radio completion is implied by encoding a packet.
pub const header_bytes = 8;
pub const max_packet_bytes = 2048;
pub const Header = struct { category: u8, class: u8, function: u8, sequence: u8, receive_ack: bool = false, done_ack: bool = false };
fn put(bytes: []u8, word: u32) void {
    for (0..4) |i| bytes[i] = @truncate(word >> @as(u5, @intCast(i * 8)));
}
/// Invalid arguments leave output untouched. As in upstream normal H2C,
/// every fourth sequence number requests a receive acknowledgement.
pub fn encode(output: []u8, header: Header, payload: []const u8) ![]const u8 {
    if (header.category > 3 or header.class > 63) return error.InvalidHeader;
    if (payload.len > max_packet_bytes - header_bytes) return error.PacketTooLarge;
    const total = payload.len + header_bytes;
    if (output.len < total) return error.BufferTooSmall;
    // Overlapping input and output is not a supported command construction.
    if (payload.len != 0) {
        const start = @intFromPtr(output.ptr);
        const pstart = @intFromPtr(payload.ptr);
        if (start > ~@as(usize, 0) - total or pstart > ~@as(usize, 0) - payload.len) return error.InvalidBuffer;
        if (start < pstart + payload.len and pstart < start + total) return error.AliasedBuffer;
    }
    const word0 = @as(u32, header.category) | (@as(u32, header.class) << 2) | (@as(u32, header.function) << 8) | (@as(u32, header.sequence) << 24);
    const rack = header.receive_ack or header.sequence % 4 == 0;
    const word1 = @as(u32, @intCast(total)) | (@as(u32, @intFromBool(rack)) << 14) | (@as(u32, @intFromBool(header.done_ack)) << 15);
    put(output, word0);
    put(output[4..], word1);
    @memcpy(output[header_bytes..][0..payload.len], payload);
    return output[0..total];
}
