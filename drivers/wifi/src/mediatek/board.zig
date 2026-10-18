// SPDX-License-Identifier: ISC
// Copyright (C) 2026 Bedrock contributors
//! Original bounded board-profile format and MT7921/MT7922 factory power facts.
//! A profile hash/provenance ID is not calibration, authentication or approval.
//! PCI/PHY IDs alone never create calibration, antenna or SAR facts.
const std = @import("std");
const nic = @import("nic.zig");
const mac = @import("mac.zig");
const mt_reg = @import("regulatory.zig");
const common = @import("../regulatory/types.zig");
const policy = @import("../regulatory/policy.zig");
pub const max_channels = 64;
pub const header_size = 128;
pub const record_size = 192;
pub const max_profile_size = header_size + max_channels * record_size;
pub const magic = "BRDBRD01";
pub const firmware_power_command: u8 = 0xd0;
pub const power_body_size = 494;
pub const power_rate_count = 161;
pub const PlatformFlags = struct {
    pub const opt_in: u8 = 1;
    pub const coherent_identity_dma: u8 = 2;
    pub const iommu_disabled: u8 = 4;
    pub const exclusive_takeover: u8 = 8;
    pub const all: u8 = 15;
};
pub const Identity = struct {
    vendor: u16,
    device: u16,
    subsystem_vendor: u16,
    subsystem_device: u16,
    revision: u8,
};
pub const Error = error{
    InvalidProfile,
    UnsupportedProfile,
    ProfileTooLarge,
    ProfileIntegrity,
    InvalidIdentity,
    InvalidChannel,
    DuplicateChannel,
    InvalidPower,
    InvalidGain,
    InvalidPlatformFlags,
    MissingBoardFacts,
    HardwareAssumptionsMissing,
    DeviceMismatch,
    PhyMismatch,
    EfuseMismatch,
    UninitializedProfile,
    BufferOverlap,
    BufferTooSmall,
    InvalidPowerReport,
    StalePowerResponse,
    UnsupportedPowerReport,
    InvalidPowerChannel,
    PowerUnavailable,
};
fn integer(comptime T: type, bytes: []const u8, offset: usize) T {
    return std.mem.readInt(T, bytes[offset..][0..@sizeOf(T)], .little);
}
fn overlaps(a: []const u8, b: []const u8) bool {
    if (a.len == 0 or b.len == 0) return false;
    const aa = @intFromPtr(a.ptr);
    const bb = @intFromPtr(b.ptr);
    return if (aa <= bb) bb - aa < a.len else aa - bb < b.len;
}
fn identityValid(id: Identity) bool {
    return ((id.vendor == 0x14c3 and (id.device == 0x7922 or id.device == 0x0616)) or
        (id.vendor == 0x0b48 and id.device == 0x7922)) and
        id.subsystem_vendor != 0 and id.subsystem_vendor != 0xffff and id.subsystem_device != 0xffff;
}
fn sameIdentity(a: Identity, b: Identity) bool {
    return std.meta.eql(a, b);
}
fn profileHash(bytes: []const u8) [32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(bytes[0..40]);
    hash.update(&@as([32]u8, @splat(0)));
    hash.update(bytes[72..]);
    var result: [32]u8 = undefined;
    hash.final(&result);
    return result;
}
const Header = struct {
    identity: Identity,
    count: usize,
    antenna_mask: u8,
    board: mt_reg.Board,
    platform_flags: u8,
    country: [2]u8,
    environment: common.Environment,
    provenance: [32]u8,
    efuse: nic.EepromBlock,
};
fn header(bytes: []const u8) Error!Header {
    if (bytes.len < header_size) return error.InvalidProfile;
    if (bytes.len > max_profile_size) return error.ProfileTooLarge;
    if (!std.mem.eql(u8, bytes[0..8], magic) or integer(u16, bytes, 8) != 1 or
        integer(u16, bytes, 10) != header_size or integer(u16, bytes, 18) != record_size) return error.UnsupportedProfile;
    const count = integer(u16, bytes, 16);
    if (count == 0 or count > max_channels or bytes.len != header_size + @as(usize, count) * record_size or integer(u32, bytes, 12) != bytes.len) return error.InvalidProfile;
    const id: Identity = .{ .vendor = integer(u16, bytes, 20), .device = integer(u16, bytes, 22), .subsystem_vendor = integer(u16, bytes, 24), .subsystem_device = integer(u16, bytes, 26), .revision = bytes[28] };
    if (!identityValid(id)) return error.InvalidIdentity;
    if (bytes[29] == 0 or bytes[29] & ~@as(u8, 3) != 0 or bytes[30] > 1 or bytes[31] > 1 or bytes[34] > 1 or bytes[39] != 0) return error.InvalidProfile;
    if (bytes[32] & ~@as(u8, 7) != 0) return error.UnsupportedProfile;
    if (bytes[35] & ~PlatformFlags.all != 0) return error.InvalidPlatformFlags;
    const country = bytes[36..38].*;
    if (!policy.validCountryCode(country) or bytes[38] > 2) return error.InvalidProfile;
    if (integer(u32, bytes, 104) != 0x550 or bytes[123] & 1 != bytes[30]) return error.InvalidProfile;
    if (!std.crypto.timing_safe.eql([32]u8, bytes[40..72].*, profileHash(bytes))) return error.ProfileIntegrity;
    return .{
        .identity = id,
        .count = count,
        .antenna_mask = bytes[29],
        .board = .{ .encapsulation = @intCast(bytes[30]), .power_type = @fromBackingInt(@intCast(bytes[31])), .acpi_conf = bytes[32], .mtcl_conf = bytes[33], .clc_event_supported = bytes[34] != 0 },
        .platform_flags = bytes[35],
        .country = country,
        .environment = @fromBackingInt(@intCast(bytes[38])),
        .provenance = bytes[72..104].*,
        .efuse = .{ .address = 0x550, .validity = integer(u32, bytes, 108), .data = bytes[112..128].* },
    };
}
pub const Channel = struct {
    band: mac.Band,
    number: u8,
    antenna_gain_mbi: i32,
    board_conducted_mbm: i32,
    sar_conducted_mbm: i32,
    rates: [power_rate_count]i8,
    pub fn ceiling(self: Channel) i32 {
        return @min(self.board_conducted_mbm, self.sar_conducted_mbm);
    }
};
fn channelRecord(bytes: []const u8) Error!Channel {
    if (bytes[0] != 1 and bytes[0] != 2) return error.InvalidChannel;
    const band: mac.Band = @fromBackingInt(@intCast(bytes[0]));
    if (!mt_reg.channelValid(band, bytes[1]) or integer(u32, bytes, 16) != 20_000) return error.InvalidChannel;
    // Explicit installed facts, not a certification scheme or fabricated fallback.
    if (integer(u16, bytes, 2) != 7) return error.MissingBoardFacts;
    if (!std.mem.allEqual(u8, bytes[181..192], 0)) return error.InvalidProfile;
    const gain = integer(i32, bytes, 4);
    if (gain < -20_000 or gain > 20_000) return error.InvalidGain;
    const board = integer(i32, bytes, 8);
    const sar = integer(i32, bytes, 12);
    if (board < -6400 or board > 6350 or sar < -6400 or sar > 6350) return error.InvalidPower;
    var result: Channel = .{ .band = band, .number = bytes[1], .antenna_gain_mbi = gain, .board_conducted_mbm = board, .sar_conducted_mbm = sar, .rates = undefined };
    for (bytes[20..181], 0..) |value, index| {
        const rate: i8 = @bitCast(value);
        if (@as(i32, rate) * 50 > @min(board, sar)) return error.InvalidPower;
        result.rates[index] = rate;
    }
    return result;
}
/// Loader-only structural/integrity validation. No large Profile aggregate,
/// actual hardware reads or inference that the profile's facts are true.
pub fn validate(bytes: []const u8) Error!void {
    const info = try header(bytes);
    for (0..info.count) |i| {
        const record = try channelRecord(bytes[header_size + i * record_size ..][0..record_size]);
        for (0..i) |previous| {
            const prior = bytes[header_size + previous * record_size ..];
            if (prior[0] == @backingInt(record.band) and prior[1] == record.number) return error.DuplicateChannel;
        }
    }
}
pub const Profile = struct {
    initialized: bool = false,
    identity: Identity = undefined,
    antenna_mask: u8 = 0,
    board: mt_reg.Board = undefined,
    platform_flags: u8 = 0,
    country: [2]u8 = undefined,
    environment: common.Environment = .unknown,
    provenance: [32]u8 = @splat(0),
    efuse: nic.EepromBlock = undefined,
    count: usize = 0,
    channels: [max_channels]Channel = undefined,
    /// Matching firmware/EFUSE facts do not independently prove installed
    /// antenna/SAR/profile declarations. The platform owns their provenance.
    pub fn verify(self: *const Profile, actual: Identity, capabilities: nic.Capabilities, efuse: nic.EepromBlock) Error!void {
        if (!self.initialized or self.count == 0 or self.count > max_channels) return error.UninitializedProfile;
        if (self.platform_flags != PlatformFlags.all) return error.HardwareAssumptionsMissing;
        if (!sameIdentity(self.identity, actual)) return error.DeviceMismatch;
        if (capabilities.phy.antenna_mask != self.antenna_mask or self.antenna_mask == 0 or self.antenna_mask & ~@as(u8, 3) != 0) return error.PhyMismatch;
        if (efuse.address != self.efuse.address or efuse.validity != self.efuse.validity or !std.mem.eql(u8, &efuse.data, &self.efuse.data)) return error.EfuseMismatch;
        if (self.board.clc_event_supported != ((capabilities.chip_capability orelse 0) & 1 != 0)) return error.PhyMismatch;
        for (self.channels[0..self.count]) |channel| {
            if ((channel.band == .ghz2 and !capabilities.phy.has_2ghz) or (channel.band == .ghz5 and !capabilities.phy.has_5ghz)) return error.PhyMismatch;
        }
    }
    /// Caller keeps the decoded profile immutable and serializes all access.
    /// Failures preflight both capacities and aliases before either output changes.
    pub fn buildCapabilities(self: *const Profile, actual: Identity, capabilities: nic.Capabilities, efuse: nic.EepromBlock, caps: []common.ChannelCap, powers: []mt_reg.PowerChannel) Error!usize {
        try self.verify(actual, capabilities, efuse);
        if (caps.len < self.count or powers.len < self.count) return error.BufferTooSmall;
        const profile_bytes = std.mem.asBytes(self);
        const cap_bytes = std.mem.sliceAsBytes(caps);
        const power_bytes = std.mem.sliceAsBytes(powers);
        if (overlaps(profile_bytes, cap_bytes) or overlaps(profile_bytes, power_bytes) or overlaps(cap_bytes, power_bytes)) return error.BufferOverlap;
        for (self.channels[0..self.count], 0..) |channel, i| {
            const common_band: common.Band = @fromBackingInt(@intCast(@backingInt(channel.band)));
            caps[i] = .{ .band = common_band, .channel = channel.number, .center_khz = policy.centerKhz(common_band, channel.number) catch return error.InvalidChannel, .available_rx = true, .calibrated = true, .max_conducted_power_mbm = channel.ceiling(), .antenna_gain_mbi = channel.antenna_gain_mbi };
            powers[i] = .{ .band = channel.band, .number = channel.number, .board_ceiling_mbm = channel.ceiling(), .rates = channel.rates };
        }
        return self.count;
    }
};
/// Atomic checked decode into caller-owned storage; wire bytes are never retained.
pub fn decode(bytes: []const u8, output: *Profile) Error!void {
    if (overlaps(bytes, std.mem.asBytes(output))) return error.BufferOverlap;
    try validate(bytes);
    const info = try header(bytes);
    output.initialized = false;
    output.identity = info.identity;
    output.antenna_mask = info.antenna_mask;
    output.board = info.board;
    output.platform_flags = info.platform_flags;
    output.country = info.country;
    output.environment = info.environment;
    output.provenance = info.provenance;
    output.efuse = info.efuse;
    for (0..info.count) |i| output.channels[i] = try channelRecord(bytes[header_size + i * record_size ..][0..record_size]);
    output.count = info.count;
    output.initialized = true;
}
pub const PowerTable = enum(u8) { user, eeprom, mac };
pub const PowerRow = struct { channel: u8, rates: [power_rate_count]i8 };
pub const PowerReport = struct {
    channel: u8,
    tables: [3]PowerRow,
    /// The EEPROM table is the genuine factory report.127 is N.A, not a
    /// permissive ceiling. User/MAC rows only further restrict known factory data.
    pub fn rateCeiling(self: *const PowerReport, index: usize) Error!i32 {
        if (index >= power_rate_count) return error.InvalidPowerReport;
        if (self.channel == 0 or self.tables[1].channel != self.channel) return error.InvalidPowerChannel;
        var value = self.tables[1].rates[index];
        if (value == 127) return error.PowerUnavailable;
        for ([_]usize{ 0, 2 }) |table| {
            if (self.tables[table].channel != self.channel) return error.InvalidPowerChannel;
            const actual = self.tables[table].rates[index];
            if (actual != 127) value = @min(value, actual);
        }
        return @as(i32, value) * 50;
    }
    /// Apply only authenticated-to-device firmware facts for this exact channel
    /// to already trusted board/SAR ceilings. Missing firmware rows never widen.
    pub fn intersect(self: *const PowerReport, input: mt_reg.PowerChannel, output: *mt_reg.PowerChannel) Error!void {
        if (self.channel != input.number) return error.InvalidPowerChannel;
        if (input.band == .ghz6 or !mt_reg.channelValid(input.band, input.number) or input.board_ceiling_mbm < -6400 or input.board_ceiling_mbm > 6350) return error.InvalidPower;
        for (input.rates) |rate| if (@as(i32, rate) * 50 > input.board_ceiling_mbm) return error.InvalidPower;
        var rates: [power_rate_count]i8 = undefined;
        for (&rates, 0..) |*rate, index| {
            const ceiling = self.rateCeiling(index) catch |err| switch (err) {
                error.PowerUnavailable => @as(i32, input.rates[index]) * 50,
                else => return err,
            };
            rate.* = @intCast(@min(@as(i32, input.rates[index]), @divFloor(@min(ceiling, input.board_ceiling_mbm), 50)));
        }
        if (overlaps(std.mem.asBytes(self), std.mem.asBytes(output))) return error.BufferOverlap;
        output.* = input;
        output.rates = rates;
    }
};
pub fn encodeTxPowerQuery(output: []u8) Error![]const u8 {
    if (output.len < 8) return error.BufferTooSmall;
    @memset(output[0..8], 0); // version/action/len/dbdc0/reserved, source exact.
    return output[0..8];
}
/// Original bounded translation of the ISC MT7921 GET_TXPWR response layout.
/// Reported channel/current tables are facts, not factory-calibration proof.
pub fn decodeTxPowerInfo(raw: []const u8, sequence: u8) Error!PowerReport {
    if (sequence == 0 or sequence > 15) return error.StalePowerResponse;
    const packet = mac.packet(raw) catch return error.InvalidPowerReport;
    const bytes = packet.bytes;
    if (packet.kind != .event or bytes.len < 36) return error.InvalidPowerReport;
    const length = integer(u16, bytes, 24);
    if (length < 12 or length > bytes.len - 24 or bytes.len - 24 - length > 3) return error.InvalidPowerReport;
    if (bytes[29] != sequence) return error.StalePowerResponse;
    if (bytes[28] != firmware_power_command or bytes[30] & 4 != 0) return error.UnsupportedPowerReport;
    const body = bytes[36 .. 24 + length];
    if (body.len != power_body_size or body[0] != 0 or body[1] != 0 or integer(u16, body, 2) != power_body_size or !std.mem.allEqual(u8, body[5..8], 0)) return error.InvalidPowerReport;
    if (body[4] > 233) return error.InvalidPowerChannel;
    var report: PowerReport = .{ .channel = body[4], .tables = undefined };
    for (&report.tables, 0..) |*row, i| {
        const start = 8 + i * (power_rate_count + 1);
        row.channel = body[start];
        if (row.channel > 233) return error.InvalidPowerChannel;
        for (&row.rates, 0..) |*rate, j| rate.* = @bitCast(body[start + 1 + j]);
    }
    return report;
}
