// SPDX-License-Identifier: ISC
// Copyright (C) 2026 Bedrock contributors
//! Bytewise endian helpers: no alignment assumptions about firmware or events.
pub fn le16(b: []const u8) u16 {
    return @as(u16, b[0]) | @as(u16, b[1]) << 8;
}
pub fn le32(b: []const u8) u32 {
    return @as(u32, le16(b)) | @as(u32, le16(b[2..])) << 16;
}
pub fn be16(b: []const u8) u16 {
    return @as(u16, b[0]) << 8 | b[1];
}
pub fn be32(b: []const u8) u32 {
    return @as(u32, be16(b)) << 16 | be16(b[2..]);
}
pub fn put16(b: []u8, v: u16) void {
    b[0] = @truncate(v);
    b[1] = @truncate(v >> 8);
}
pub fn put32(b: []u8, v: u32) void {
    put16(b, @truncate(v));
    put16(b[2..], @truncate(v >> 16));
}
pub fn putBe32(b: []u8, v: u32) void {
    b[0] = @truncate(v >> 24);
    b[1] = @truncate(v >> 16);
    b[2] = @truncate(v >> 8);
    b[3] = @truncate(v);
}
pub fn checkedEnd(total: usize, offset: usize, length: usize) !usize {
    if (offset > total or length > total - offset) return error.TruncatedFirmware;
    return offset + length;
}
