// SPDX-License-Identifier: ISC
// Copyright (C) 2020 MediaTek Inc.
// Copyright (C) 2026 Bedrock contributors
// Derived from Linux v6.18 mt76_connac_mcu.{c,h}; see PROVENANCE.json and LICENSE.
//! Structural parsing only; firmware checksums/signatures are not authenticated.
const w = @import("wire.zig");
pub const max_regions = 32;
pub const max_image_size = 8 * 1024 * 1024;
pub const patch_header_size = 96;
pub const patch_section_size = 64;
pub const ram_trailer_size = 36;
pub const ram_region_size = 40;
pub const patch_name = "mediatek/WIFI_MT7922_patch_mcu_1_1_hdr.bin";
pub const ram_name = "mediatek/WIFI_RAM_CODE_MT7922_1.bin";
pub const need_response: u32 = 1 << 31;
pub const Region = struct {
    address: u32,
    data: []const u8,
    download_mode: u32,
    feature: u8 = 0,
    kind: u8 = 0,
    download: bool = true,
};
pub const Patch = struct {
    bytes: []const u8,
    region_count: usize,
    hardware_version: u32,
    version: u32,
    pub fn region(self: Patch, index: usize) !Region {
        if (index >= self.region_count) return error.InvalidRegion;
        const s = self.bytes[patch_header_size + index * patch_section_size ..][0..patch_section_size];
        const off = w.be32(s[4..]);
        const len = w.be32(s[16..]);
        return .{ .address = w.be32(s[12..]), .data = self.bytes[off..][0..len], .download_mode = try patchMode(w.be32(s[20..])) };
    }
};
pub const Ram = struct {
    bytes: []const u8,
    table_offset: usize,
    region_count: usize,
    chip_id: u8,
    format_version: u8,
    version: [10]u8,
    build_date: [15]u8,
    /// The actual MT7922 image has auxiliary bytes before its region table.
    metadata: []const u8,
    pub fn region(self: Ram, index: usize) !Region {
        if (index >= self.region_count) return error.InvalidRegion;
        var offset: usize = 0;
        for (0..index) |i| offset += w.le32(self.bytes[self.table_offset + i * ram_region_size + 20 ..]);
        const r = self.bytes[self.table_offset + index * ram_region_size ..][0..ram_region_size];
        const f = r[24];
        const len = w.le32(r[20..]);
        return .{ .address = w.le32(r[16..]), .data = self.bytes[offset..][0..len], .download_mode = ramMode(f), .feature = f, .kind = r[25], .download = f & 0x40 == 0 };
    }
};
fn addressRange(address: u32, length: usize) !void {
    if (length == 0 or address == 0 or length > @as(u64, 0x1_0000_0000) - address) return error.InvalidFirmwareAddress;
}
pub fn patchMode(info: u32) !u32 {
    if (info == 0xffffffff) return need_response;
    return switch (info >> 24) {
        0 => need_response,
        1 => need_response | 1 | 8 | ((info & 3) << 1),
        2 => need_response | 1 | 8 | 64,
        else => error.UnsupportedEncryption,
    };
}
pub fn ramMode(feature: u8) u32 {
    return need_response | @as(u32, feature & 6) | (if (feature & 1 != 0) @as(u32, 9) else 0) | (if (feature & 16 != 0) @as(u32, 64) else 0);
}
pub fn parsePatch(bytes: []const u8) !Patch {
    if (bytes.len < patch_header_size or bytes.len > max_image_size) return error.InvalidFirmwareSize;
    const n = w.be32(bytes[44..]);
    if (n == 0 or n > max_regions) return error.InvalidRegionCount;
    const table_end = try w.checkedEnd(bytes.len, patch_header_size, @as(usize, n) * patch_section_size);
    const image: Patch = .{ .bytes = bytes, .region_count = n, .hardware_version = w.be32(bytes[20..]), .version = w.be32(bytes[24..]) };
    for (0..n) |i| {
        const s = bytes[patch_header_size + i * patch_section_size ..][0..patch_section_size];
        if (w.be32(s) & 0xffff != 2) return error.UnsupportedPatchSection;
        const off = w.be32(s[4..]);
        const size = w.be32(s[8..]);
        const len = w.be32(s[16..]);
        if (off < table_end or len > size) return error.InvalidFirmwareRegion;
        _ = try w.checkedEnd(bytes.len, off, size);
        try addressRange(w.be32(s[12..]), len);
        _ = try patchMode(w.be32(s[20..]));
        for (0..i) |j| {
            const p = bytes[patch_header_size + j * patch_section_size ..];
            const po = w.be32(p[4..]);
            const pl = w.be32(p[8..]);
            if (@as(u64, off) < @as(u64, po) + pl and @as(u64, po) < @as(u64, off) + size) return error.OverlappingFirmwareRegions;
        }
    }
    return image;
}
pub fn parseRam(bytes: []const u8) !Ram {
    if (bytes.len < ram_trailer_size or bytes.len > max_image_size) return error.InvalidFirmwareSize;
    const t = bytes[bytes.len - ram_trailer_size ..];
    const n = t[2];
    if (n == 0 or n > max_regions) return error.InvalidRegionCount;
    const table_len = @as(usize, n) * ram_region_size;
    if (table_len > bytes.len - ram_trailer_size) return error.TruncatedFirmware;
    const table = bytes.len - ram_trailer_size - table_len;
    if (t[3] != 2) return error.UnsupportedFirmwareFormat;
    var offset: usize = 0;
    for (0..n) |i| {
        const r = bytes[table + i * ram_region_size ..][0..ram_region_size];
        const len = w.le32(r[20..]);
        if (len == 0) return error.InvalidFirmwareRegion;
        offset = try w.checkedEnd(table, offset, len);
        if (w.le32(r[4..]) != 0 or w.le32(r[8..]) != 0) return error.UnsupportedCompression;
        const f = r[24];
        if (f & 0x80 != 0) return error.UnsupportedFirmwareFeature;
        if (f & 0x40 == 0) try addressRange(w.le32(r[16..]), len);
    }
    return .{ .bytes = bytes, .table_offset = table, .region_count = n, .chip_id = t[0], .format_version = t[3], .version = t[7..17].*, .build_date = t[17..32].*, .metadata = bytes[offset..table] };
}
