// SPDX-License-Identifier: BSD-3-Clause
// Selected BSD option from Linux v6.18 iwlwifi/fw/file.h, fw/img.h, iwl-drv.c.
// Copyright (C) 2005-2014, 2018-2024 Intel Corporation
// Copyright (C) 2013-2015 Intel Mobile Communications GmbH
// Copyright (C) 2016-2017 Intel Deutschland GmbH
// Original notices and license terms are retained in NOTICE.md and LICENSE.
//! Bounded TLV inspection, not firmware authentication or a DMA load plan.
//! All returned byte slices borrow the input, which must stay immutable/alive.

pub const magic: u32 = 0x0a4c5749;
pub const header_size = 88;
pub const max_container_bytes = 16 * 1024 * 1024;
pub const max_tlvs = 4096;
pub const max_sections = 64;
pub const api_bits = 69;
pub const capability_bits = 130;
pub const cpu_separator: u32 = 0xffffcccc;
pub const paging_separator: u32 = 0xaaaabbbb;
pub const max_paging_bytes: u32 = 1024 * 1024;

pub const Image = enum(u8) { runtime, init, wowlan, sniffer };
pub const SectionKind = enum(u8) { bytes, cpu_separator, paging_separator };
pub const Section = struct {
    image: Image,
    kind: SectionKind,
    secure: bool,
    cpu: u8,
    paged: bool,
    destination: u32,
    bytes: []const u8,
};
pub const Version = struct { major: u32, minor: u32, local: u8 };
pub const Container = struct {
    human_readable: []const u8 = &.{},
    raw_version: u32 = 0,
    build: u32 = 0,
    version: ?Version = null,
    api: u32 = 0,
    flags: u32 = 0,
    flags_words: []const u8 = &.{},
    api_flags: [3]u32 = @splat(0),
    capabilities: [5]u32 = @splat(0),
    cpu_count: u8 = 1,
    paging_bytes: u32 = 0,
    section_count: usize = 0,
    sections: [max_sections]Section = undefined,
    tlv_count: usize = 0,
    unhandled_tlvs: usize = 0,

    pub fn hasApi(self: *const Container, bit: usize) bool {
        return bit < api_bits and (self.api_flags[bit / 32] & (@as(u32, 1) << @intCast(bit % 32))) != 0;
    }
    pub fn hasCapability(self: *const Container, bit: usize) bool {
        return bit < capability_bits and (self.capabilities[bit / 32] & (@as(u32, 1) << @intCast(bit % 32))) != 0;
    }
    pub fn requireApi(self: *const Container, minimum: u32, maximum: u32) !void {
        if (minimum > maximum or self.api < minimum or self.api > maximum) return error.UnsupportedFirmwareApi;
    }
};

fn le32(bytes: []const u8) u32 {
    // Byte reads are valid for deliberately unaligned containers on all ISAs.
    return @as(u32, bytes[0]) | (@as(u32, bytes[1]) << 8) | (@as(u32, bytes[2]) << 16) | (@as(u32, bytes[3]) << 24);
}
fn scalar(bytes: []const u8) !u32 {
    if (bytes.len != 4) return error.InvalidTlvLength;
    return le32(bytes);
}
fn bitmap(words: []u32, bits: usize, payload: []const u8) !void {
    if (payload.len != 8) return error.InvalidTlvLength;
    const index = le32(payload);
    const value = le32(payload[4..]);
    if (index >= words.len) return error.UnsupportedBitmap;
    const remaining = bits - @as(usize, index) * 32;
    if (remaining < 32 and value >> @as(u5, @intCast(remaining)) != 0) return error.UnsupportedBitmap;
    words[index] |= value;
}
fn imageFor(kind: u32) ?Image {
    return switch (kind) {
        19, 24 => .runtime,
        20, 25 => .init,
        21, 26 => .wowlan,
        34 => .sniffer,
        else => null,
    };
}

/// On failure `out` is cleared; its sections must only be used after success.
/// Legacy INST/DATA containers are explicitly unsupported. Unhandled TLVs are
/// bounded and counted, never interpreted as register commands or trusted data.
pub fn inspect(blob: []const u8, out: *Container) !void {
    out.* = .{};
    errdefer out.* = .{};
    if (blob.len < header_size) return error.TruncatedHeader;
    if (blob.len > max_container_bytes) return error.ContainerTooLarge;
    if (le32(blob) != 0) return error.UnsupportedLegacyFormat;
    if (le32(blob[4..]) != magic) return error.InvalidMagic;
    out.human_readable = blob[8..72];
    out.raw_version = le32(blob[72..]);
    out.build = le32(blob[76..]);
    // Header bytes 80..88 are explicitly ignored by the upstream format.
    var cursor: usize = header_size;
    var cpus: [4]u8 = @splat(0);
    var paged: [4]bool = @splat(false);
    var data_counts: [4]u8 = @splat(0);
    var seen_flags = false;
    var seen_cpu_count = false;
    var seen_paging = false;
    while (cursor != blob.len) {
        if (blob.len - cursor < 8) return error.TruncatedTlv;
        if (out.tlv_count == max_tlvs) return error.TlvCapacity;
        out.tlv_count += 1;
        const kind = le32(blob[cursor..]);
        const length: usize = le32(blob[cursor + 4 ..]);
        cursor += 8;
        if (length > blob.len - cursor) return error.TruncatedTlv;
        const padding = (4 - length % 4) % 4;
        if (padding > blob.len - cursor - length) return error.TruncatedPadding;
        const payload = blob[cursor .. cursor + length];
        cursor += length + padding;
        // Alignment bytes need not be zero; only their extent is significant.
        if (imageFor(kind)) |image| {
            if (length < 4) return error.InvalidTlvLength;
            if (out.section_count == max_sections) return error.SectionCapacity;
            const index: usize = @backingInt(image);
            const destination = le32(payload);
            var section_kind: SectionKind = .bytes;
            if (destination == cpu_separator) {
                if (length != 4 or cpus[index] != 0 or paged[index] or data_counts[index] == 0) return error.InvalidSeparator;
                section_kind = .cpu_separator;
                cpus[index] = 1;
                data_counts[index] = 0;
            } else if (destination == paging_separator) {
                if (length != 4 or paged[index] or data_counts[index] == 0 or (image != .runtime and image != .sniffer)) return error.InvalidSeparator;
                section_kind = .paging_separator;
                paged[index] = true;
                data_counts[index] = 0;
            } else {
                if (length == 4) return error.EmptySection;
                const end = @as(u64, destination) + length - 4;
                if (end > 0x1_0000_0000) return error.SectionAddressOverflow;
                if (!paged[index]) for (out.sections[0..out.section_count]) |prior| {
                    if (prior.kind != .bytes or prior.paged or prior.image != image or prior.cpu != cpus[index]) continue;
                    const prior_end = @as(u64, prior.destination) + prior.bytes.len;
                    if (destination < prior_end and prior.destination < end) return error.OverlappingSections;
                };
                data_counts[index] += 1;
            }
            out.sections[out.section_count] = .{ .image = image, .kind = section_kind, .secure = kind >= 24 and kind <= 26, .cpu = cpus[index], .paged = paged[index], .destination = destination, .bytes = payload[4..] };
            out.section_count += 1;
            continue;
        }
        switch (kind) {
            0 => return error.InvalidTlvType,
            1, 2, 3, 4, 5, 16, 17 => return error.UnsupportedLegacySections,
            18 => {
                if (length < 4 or length % 4 != 0) return error.InvalidTlvLength;
                if (seen_flags) return error.DuplicateMetadata;
                seen_flags = true;
                out.flags = le32(payload);
                out.flags_words = payload;
            },
            27 => {
                if (seen_cpu_count) return error.DuplicateMetadata;
                seen_cpu_count = true;
                const count = try scalar(payload);
                if (count < 1 or count > 2) return error.UnsupportedCpuCount;
                out.cpu_count = @intCast(count);
            },
            29 => try bitmap(&out.api_flags, api_bits, payload),
            30 => try bitmap(&out.capabilities, capability_bits, payload),
            32 => {
                if (seen_paging) return error.DuplicateMetadata;
                seen_paging = true;
                out.paging_bytes = try scalar(payload);
                if (out.paging_bytes > max_paging_bytes or out.paging_bytes % 4096 != 0) return error.InvalidPagingSize;
            },
            36 => {
                if (length != 12) return error.InvalidTlvLength;
                if (out.version != null) return error.DuplicateMetadata;
                const local = le32(payload[8..]);
                if (local > 255) return error.InvalidVersion;
                out.version = .{ .major = le32(payload), .minor = le32(payload[4..]), .local = @intCast(local) };
            },
            else => out.unhandled_tlvs += 1,
        }
    }
    var runtime_bytes = false;
    for (out.sections[0..out.section_count]) |section| {
        if (section.cpu >= out.cpu_count) return error.InvalidSeparator;
        if (section.kind == .bytes and section.image == .runtime and !section.paged) runtime_bytes = true;
    }
    for (0..4) |i| {
        if (cpus[i] != 0 and data_counts[i] == 0) return error.InvalidSeparator;
        if (paged[i] and (out.paging_bytes == 0 or data_counts[i] == 0)) return error.InvalidPagingSize;
    }
    if (!runtime_bytes) return error.MissingRuntimeImage;
    out.api = if (out.hasApi(20)) out.raw_version else (out.raw_version >> 8) & 255;
    if (out.api == 0) return error.InvalidVersion;
}
