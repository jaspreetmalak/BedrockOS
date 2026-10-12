// SPDX-License-Identifier: BSD-3-Clause
// Selected BSD option from Linux v6.18 rtw89/fw.c, fw.h and core.h.
// Copyright(c) 2019-2020 Realtek Corporation
// Original notices and license terms are retained in NOTICE.md and LICENSE.
//! Borrowed v0 image inspection. Secure boot, signatures and hardware address
//! permissions are not validated; the result must not be used as a DMA plan.

pub const max_container_bytes = 16 * 1024 * 1024;
pub const max_entries = 32;
pub const max_sections = 10;
pub const max_dynamic_sections = 32;
pub const Kind = enum(u8) { normal = 1, wowlan = 3, normal_ce = 5 };
pub const Selection = struct { cut: u8, kind: Kind = .normal };
pub const Version = struct { major: u8, minor: u8, sub: u8, index: u8 };
pub const Section = struct {
    raw_destination: u32,
    destination: u32,
    kind: u8,
    metadata: u8,
    redownload: bool,
    bytes: []const u8,
    checksum: []const u8,
    signatures: []const u8,
    signature_count: u32,
};
pub const Image = struct {
    container_bytes: []const u8 = &.{},
    bytes: []const u8 = &.{},
    is_multi: bool = false,
    selected_cut: ?u8 = null,
    kind: Kind = .normal,
    raw_signature: u32 = 0,
    version: Version = .{ .major = 0, .minor = 0, .sub = 0, .index = 0 },
    commit_id: u32 = 0,
    command_version: u8 = 0,
    idmem_share_mode: u8 = 0,
    header_bytes: []const u8 = &.{},
    dynamic_header: []const u8 = &.{},
    dynamic_section_count: u32 = 0,
    section_count: usize = 0,
    sections: [max_sections]Section = undefined,
    // Multi-image containers may have firmware elements after the last entry.
    // Their contents are retained as opaque bytes, never treated as commands.
    trailing_elements: []const u8 = &.{},
};
pub fn le32(bytes: []const u8) u32 {
    return @as(u32, bytes[0]) | (@as(u32, bytes[1]) << 8) | (@as(u32, bytes[2]) << 16) | (@as(u32, bytes[3]) << 24);
}
fn knownKind(value: u8) bool {
    return switch (value) {
        1, 3, 5, 64, 65, 255 => true,
        else => false,
    };
}

/// Failed inspection clears `out`. Source bytes must remain immutable/alive.
/// Single images have no cut metadata; callers must select their trusted file.
pub fn inspect(blob: []const u8, selection: Selection, out: *Image) !void {
    out.* = .{};
    errdefer out.* = .{};
    if (blob.len < 32) return error.TruncatedHeader;
    if (blob.len > max_container_bytes) return error.ContainerTooLarge;
    var selected = blob;
    if (blob[0] == 0xff) {
        const count: usize = blob[1];
        if (count == 0 or count > max_entries) return error.EntryCapacity;
        const table_end = 16 + count * 16;
        if (table_end > blob.len) return error.TruncatedTable;
        var best: ?usize = null;
        var best_cut: u8 = 0;
        var last_end = table_end;
        for (0..count) |i| {
            const entry = blob[16 + i * 16 ..][0..16];
            const start: usize = le32(entry[4..]);
            const size: usize = le32(entry[8..]);
            if (!knownKind(entry[1]) or entry[2] > 1) return error.UnsupportedEntry;
            if (start < table_end or size == 0 or start > blob.len or size > blob.len - start) return error.InvalidEntryRange;
            const end = start + size;
            last_end = @max(last_end, end);
            for (0..i) |j| {
                const prior = blob[16 + j * 16 ..][0..16];
                const prior_start: usize = le32(prior[4..]);
                const prior_end = prior_start + @as(usize, le32(prior[8..]));
                if (start < prior_end and prior_start < end) return error.OverlappingEntries;
                if (entry[0] == prior[0] and entry[1] == prior[1] and entry[2] == prior[2]) return error.AmbiguousSelection;
            }
            if (entry[1] == @backingInt(selection.kind) and entry[2] == 0 and entry[0] <= selection.cut and (best == null or entry[0] > best_cut)) {
                best = i;
                best_cut = entry[0];
            }
        }
        const chosen = best orelse return error.NoCompatibleImage;
        const entry = blob[16 + chosen * 16 ..][0..16];
        const start: usize = le32(entry[4..]);
        selected = blob[start..][0..le32(entry[8..])];
        out.is_multi = true;
        out.selected_cut = best_cut;
        out.trailing_elements = blob[last_end..];
    } else if (selection.kind != .normal) return error.NoCompatibleImage;
    try inspectImage(selected, out);
    out.container_bytes = blob;
    out.kind = selection.kind;
}
fn inspectImage(bytes: []const u8, out: *Image) !void {
    if (bytes.len < 32) return error.TruncatedHeader;
    const w3 = le32(bytes[12..]);
    if (w3 >> 24 != 0) return error.UnsupportedHeaderVersion;
    const section_count: usize = (le32(bytes[24..]) >> 8) & 255;
    if (section_count == 0 or section_count > max_sections) return error.SectionCapacity;
    const base_header = 32 + section_count * 16;
    if (base_header > bytes.len) return error.TruncatedTable;
    const w7 = le32(bytes[28..]);
    var header_length = base_header;
    if (w7 & (1 << 16) != 0) {
        header_length = (w3 >> 16) & 255;
        if (header_length < base_header + 8 or header_length > bytes.len) return error.InvalidDynamicHeader;
        const dynamic = bytes[base_header..header_length];
        if (le32(dynamic) != dynamic.len) return error.InvalidDynamicHeader;
        const count = le32(dynamic[4..]);
        if (count > max_dynamic_sections or count > (dynamic.len - 8) / 4) return error.InvalidDynamicHeader;
        out.dynamic_header = dynamic;
        out.dynamic_section_count = count;
        // Upstream only interprets aggregate length here. Nested metadata has
        // no named length/type masks in fw.h; preserve it without guessing.
    }
    out.header_bytes = bytes[0..header_length];
    out.raw_signature = le32(bytes);
    out.version = .{ .major = bytes[4], .minor = bytes[5], .sub = bytes[6], .index = bytes[7] };
    out.commit_id = le32(bytes[8..]);
    out.command_version = @truncate(w7 >> 24);
    out.idmem_share_mode = @truncate((w7 >> 18) & 15);
    var cursor = header_length;
    for (0..section_count) |i| {
        const header = bytes[32 + i * 16 ..][0..16];
        const raw_address = le32(header);
        const address = raw_address & 0x1fffffff;
        const word = le32(header[4..]);
        const size: usize = word & 0xffffff;
        const kind: u8 = @truncate((word >> 24) & 15);
        const checksum_length: usize = if (word & (1 << 28) != 0) 8 else 0;
        const mssc = if (kind == 9) le32(header[8..]) else 0;
        if (kind != 1 and kind != 2 and kind != 9) return error.UnsupportedSectionType;
        if (size == 0) return error.EmptySection;
        if (mssc & 255 == 255) return error.UnsupportedFormattedMssc;
        // Multiplication in u64, followed by remaining-length checks, works
        // identically for malicious u32 counts on all supported 64-bit ISAs.
        const signature_bytes = @as(u64, mssc) * 512;
        if (size > bytes.len - cursor or checksum_length > bytes.len - cursor - size) return error.TruncatedSection;
        if (signature_bytes > bytes.len - cursor - size - checksum_length) return error.TruncatedSignatures;
        const end = @as(u64, address) + size + checksum_length;
        if (end > 0x20000000) return error.SectionAddressOverflow;
        for (out.sections[0..i]) |prior| {
            const prior_end = @as(u64, prior.destination) + prior.bytes.len + prior.checksum.len;
            if (address < prior_end and prior.destination < end) return error.OverlappingSections;
        }
        out.sections[i] = .{
            .raw_destination = raw_address,
            .destination = address,
            .kind = kind,
            .metadata = @truncate(word >> 24),
            .redownload = word & (1 << 29) != 0,
            .bytes = bytes[cursor..][0..size],
            .checksum = bytes[cursor + size ..][0..checksum_length],
            .signatures = bytes[cursor + size + checksum_length ..][0..@intCast(signature_bytes)],
            .signature_count = mssc,
        };
        cursor += size + checksum_length + @as(usize, @intCast(signature_bytes));
    }
    if (cursor != bytes.len) return error.TrailingImageBytes;
    out.section_count = section_count;
    out.bytes = bytes;
}
