// SPDX-License-Identifier: ISC
// Copyright (C) 2020 MediaTek Inc.
// Copyright (C) 2026 Bedrock contributors
// Derived from pinned Linux v6.18 mt76_connac_mcu.{c,h}, mt7921/{mcu.c,mt7921.h},
// mt792x.h and init.c. See PROVENANCE.json and LICENSE.
//! Native firmware codecs. Submission proves DMA consumption, not regulatory
//! acceptance, calibration, permission to transmit, or an operational radio.
const w = @import("wire.zig");
const mac = @import("mac.zig");
const firmware = @import("firmware.zig");
const Mcu = @import("mcu.zig").Mcu;

pub const Band = mac.Band;
pub const Environment = enum(u8) { any = 0, indoor = 1, outdoor = 2 };
pub const PowerType = enum(u8) { unset = 0, default = 1, lpi = 2, standard = 3, vlp = 4 };
pub const domain_command: u8 = 0x0f;
pub const clc_command: u8 = 0x5c;
pub const power_command: u8 = 0x5d;
pub const max_channels = 64;
pub const sku_size = 161;
pub const power_batch_channels = 8;
pub const domain_size = 12 + max_channels * 8;
pub const power_size = 44 + power_batch_channels * (1 + sku_size);
pub const clc_header_size = 76;
pub const max_clc_rules = 2048;
pub const max_country_rules = 32;

pub const ChannelLimit = struct {
    band: Band,
    number: u8,
    /// Conducted power after regulatory EIRP/antenna, device and board limits.
    max_power_mbm: i32,
    no_ir: bool = false,
    dfs: bool = false,
    indoor_only: bool = false,
};
pub const ChannelCapability = struct { band: Band, number: u8, max_power_mbm: i32 };
/// Trusted hardware-derived ceilings, not inferred from a PCI chip identifier.
pub const DeviceCapabilities = struct { channels: []const ChannelCapability };
pub const Domain = struct {
    country: [2]u8,
    environment: Environment,
    channels: []const ChannelLimit,
};
/// Every signed half-dBm entry must come from the caller's actual rate/board/SAR
/// calculation. This codec never constructs a default all-rates power table.
pub const PowerChannel = struct {
    band: Band,
    number: u8,
    board_ceiling_mbm: i32,
    rates: [sku_size]i8,
};
/// Values require actual EEPROM/ACPI/NIC data supplied by trusted platform code.
pub const Board = struct {
    encapsulation: u1,
    acpi_conf: u8,
    mtcl_conf: u8,
    power_type: PowerType,
    clc_event_supported: bool,
};

fn countryValid(country: [2]u8) bool {
    return (country[0] == '0' and country[1] == '0') or
        (country[0] >= 'A' and country[0] <= 'Z' and country[1] >= 'A' and country[1] <= 'Z');
}
pub fn channelValid(band: Band, number: u8) bool {
    return switch (band) {
        .ghz2 => number >= 1 and number <= 14,
        .ghz5 => switch (number) {
            36, 40, 44, 48, 52, 56, 60, 64, 100, 104, 108, 112, 116, 120, 124, 128, 132, 136, 140, 144, 149, 153, 157, 161, 165, 169, 173, 177 => true,
            else => false,
        },
        .ghz6 => number >= 1 and number <= 233 and number % 4 == 1,
    };
}
fn powerValid(power: i32) bool {
    // The signed half-dBm MCU encoding cannot represent a ceiling below -64dBm.
    return power >= -6400 and power <= 6350;
}
fn capability(caps: DeviceCapabilities, band: Band, number: u8) !ChannelCapability {
    for (caps.channels) |c| if (c.band == band and c.number == number) return c;
    return error.UnsupportedDeviceChannel;
}
fn limit(domain: Domain, band: Band, number: u8) !ChannelLimit {
    for (domain.channels) |c| if (c.band == band and c.number == number) return c;
    return error.ChannelOutsidePolicy;
}
pub fn validateDomain(domain: Domain, caps: DeviceCapabilities) !void {
    if (!countryValid(domain.country) or domain.channels.len == 0 or domain.channels.len > max_channels or caps.channels.len == 0 or caps.channels.len > max_channels) return error.InvalidChannelDomain;
    for (caps.channels, 0..) |c, i| {
        if (!channelValid(c.band, c.number) or !powerValid(c.max_power_mbm)) return error.InvalidDeviceCapabilities;
        for (caps.channels[0..i]) |previous| if (previous.band == c.band and previous.number == c.number) return error.DuplicateDeviceChannel;
    }
    for (domain.channels, 0..) |c, i| {
        if (!channelValid(c.band, c.number) or !powerValid(c.max_power_mbm)) return error.InvalidPolicyChannel;
        const cap = try capability(caps, c.band, c.number);
        if (c.max_power_mbm > cap.max_power_mbm) return error.PowerExceedsDevice;
        if (c.indoor_only and domain.environment != .indoor and !c.no_ir) return error.IndoorChannelInitiation;
        if ((domain.country[0] == '0' or c.band == .ghz6) and !c.no_ir) return error.RestrictedChannelInitiation;
        for (domain.channels[0..i]) |previous| if (previous.band == c.band and previous.number == c.number) return error.DuplicatePolicyChannel;
    }
}
pub fn encodeDomain(domain: Domain, caps: DeviceCapabilities, output: []u8) ![]const u8 {
    try validateDomain(domain, caps);
    const size = 12 + domain.channels.len * 8;
    if (output.len < size) return error.OutputTooSmall;
    const b = output[0..size];
    @memset(b, 0);
    @memcpy(b[0..2], &domain.country);
    // Linux's domain bandwidth enum: 1 == BW_20M. This port grants no HT40+.
    @memset(b[4..7], 1);
    var offset: usize = 12;
    for ([_]Band{ .ghz2, .ghz5, .ghz6 }, 0..) |band, band_index| {
        for (domain.channels) |c| {
            if (c.band != band) continue;
            b[8 + band_index] += 1;
            w.put16(b[offset..], c.number);
            // Firmware receives the numerical channel restriction bits passed
            // by upstream. All wider widths are denied; DFS never lifts NO_IR.
            var flags: u32 = (1 << 4) | (1 << 5) | (1 << 7) | (1 << 8) | (1 << 19);
            if (c.no_ir or c.dfs) flags |= 1 << 1;
            if (c.dfs) flags |= 1 << 3;
            if (c.indoor_only) flags |= 1 << 9;
            if (c.band == .ghz2 and c.number == 14) flags |= 1 << 6;
            w.put32(b[offset + 4 ..], flags);
            offset += 8;
        }
    }
    return b;
}
fn validatePower(domain: Domain, caps: DeviceCapabilities, p: PowerChannel) !void {
    const c = try limit(domain, p.band, p.number);
    const cap = try capability(caps, p.band, p.number);
    if (!powerValid(p.board_ceiling_mbm)) return error.InvalidBoardPower;
    const ceiling = @divFloor(@min(c.max_power_mbm, @min(cap.max_power_mbm, p.board_ceiling_mbm)), 50);
    for (p.rates) |rate| if (rate > ceiling) return error.RatePowerExceedsPolicy;
}
pub fn encodePowerBatch(domain: Domain, caps: DeviceCapabilities, channels: []const PowerChannel, last: bool, output: []u8) ![]const u8 {
    try validateDomain(domain, caps);
    if (channels.len == 0 or channels.len > power_batch_channels) return error.InvalidPowerBatch;
    for (channels, 0..) |p, i| {
        if (p.band != channels[0].band) return error.MixedPowerBands;
        try validatePower(domain, caps, p);
        for (channels[0..i]) |previous| if (previous.number == p.number) return error.DuplicatePowerChannel;
    }
    const size = 44 + channels.len * (1 + sku_size);
    if (output.len < size) return error.OutputTooSmall;
    const b = output[0..size];
    @memset(b, 0);
    // ver/len/reserved remain zero exactly as v6.18's legacy command.
    b[4] = @intCast(channels.len);
    b[5] = @backingInt(channels[0].band);
    b[6] = @intFromBool(last);
    @memcpy(b[8..10], &domain.country);
    for (channels, 0..) |p, i| {
        const offset = 44 + i * (1 + sku_size);
        b[offset] = p.number;
        for (p.rates, 0..) |rate, j| b[offset + 1 + j] = @bitCast(rate);
    }
    return b;
}

pub const ClcRule = struct { index: u8, country: [2]u8, kind: [2]u8, data: []const u8 };
/// Borrowed authentic CLC storage. Unknown future indices are bounded opaque
/// records, never decoded as older rules or counted as regulatory authority.
pub const Clc = struct {
    blocks: [2]?[]const u8 = .{ null, null },
    encapsulation: u1,
    skipped_blocks: usize = 0,
    pub fn fromRam(ram: firmware.Ram, encapsulation: u1) !Clc {
        var found: ?[]const u8 = null;
        for (0..ram.region_count) |i| {
            const region = try ram.region(i);
            if (region.download or region.kind != 2) continue;
            if (found != null) return error.DuplicateClcRegion;
            found = region.data;
        }
        return parse(found orelse return error.MissingClcData, encapsulation);
    }
    pub fn parse(bytes: []const u8, encapsulation: u1) !Clc {
        if (bytes.len == 0 or bytes.len > 1024 * 1024) return error.InvalidClc;
        var result: Clc = .{ .encapsulation = encapsulation };
        var pos: usize = 0;
        var blocks: usize = 0;
        var rule_count: usize = 0;
        while (pos < bytes.len) {
            if (bytes.len - pos < 16 or blocks == 16) return error.InvalidClc;
            const b = bytes[pos..];
            const size = w.le32(b);
            if (size < 16 or size > b.len) return error.InvalidClc;
            const record = b[0..size];
            const index = b[4];
            if (index >= 2) {
                result.skipped_blocks += 1;
            } else {
                if (b[5] != 1) return error.UnsupportedClcVersion;
                var cursor: usize = 16;
                while (cursor < record.len) {
                    if (record.len - cursor < 6 or rule_count == max_clc_rules) return error.InvalidClc;
                    const length = w.le16(record[cursor + 4 ..]);
                    if (length == 0 or length > record.len - cursor - 6) return error.InvalidClc;
                    cursor += 6 + length;
                    rule_count += 1;
                }
                if (index != 0 or b[7] & 1 == encapsulation) {
                    if (result.blocks[index] != null) return error.DuplicateClcBlock;
                    result.blocks[index] = record;
                }
            }
            blocks += 1;
            pos += size;
        }
        if (result.blocks[0] == null) return error.MissingClcPowerData;
        return result;
    }
    pub fn rules(self: Clc, country: [2]u8) Iterator {
        return .{ .clc = self, .country = country };
    }
    fn validate(self: Clc) !void {
        if (self.blocks[0] == null) return error.MissingClcPowerData;
        var rule_count: usize = 0;
        for (self.blocks, 0..) |maybe, index| {
            const block = maybe orelse continue;
            if (block.len < 16 or block.len > 1024 * 1024 or w.le32(block) != block.len or block[4] != index or block[5] != 1) return error.InvalidClc;
            if (index == 0 and block[7] & 1 != self.encapsulation) return error.ClcEncapsulationMismatch;
            var cursor: usize = 16;
            while (cursor < block.len) {
                if (block.len - cursor < 6 or rule_count == max_clc_rules) return error.InvalidClc;
                const len = w.le16(block[cursor + 4 ..]);
                if (len == 0 or len > block.len - cursor - 6) return error.InvalidClc;
                cursor += 6 + len;
                rule_count += 1;
            }
        }
    }
    pub const Iterator = struct {
        clc: Clc,
        country: [2]u8,
        index: usize = 0,
        offset: usize = 16,
        pub fn next(self: *Iterator) ?ClcRule {
            while (self.index < 2) {
                const b = self.clc.blocks[self.index] orelse {
                    self.index += 1;
                    self.offset = 16;
                    continue;
                };
                while (self.offset < b.len) {
                    const r = b[self.offset..];
                    const len = w.le16(r[4..]);
                    self.offset += 6 + len;
                    if (r[0] != self.country[0] or r[1] != self.country[1]) continue;
                    return .{ .index = @intCast(self.index), .country = r[0..2].*, .kind = r[2..4].*, .data = r[6..][0..len] };
                }
                self.index += 1;
                self.offset = 16;
            }
            return null;
        }
    };
};
pub fn encodeClc(rule: ClcRule, environment: Environment, board: Board, output: []u8) ![]const u8 {
    if (!countryValid(rule.country) or rule.index >= 2 or rule.data.len == 0 or rule.data.len > 4096 - clc_header_size) return error.InvalidClcRule;
    const size = clc_header_size + rule.data.len;
    if (output.len < size) return error.OutputTooSmall;
    const b = output[0..size];
    @memset(b, 0);
    b[0] = 1;
    w.put16(b[2..], @intCast(size));
    b[4] = rule.index;
    b[5] = @backingInt(environment);
    b[6] = board.acpi_conf;
    b[7] = @intFromBool(board.clc_event_supported);
    // CLC_CAP_DTS_EN stays clear: no Linux device-tree power node is invented.
    @memcpy(b[8..10], &rule.country);
    @memcpy(b[10..12], &rule.kind);
    b[12] = @backingInt(board.power_type);
    b[13] = board.mtcl_conf;
    @memcpy(b[clc_header_size..], rule.data);
    return b;
}

pub const Plan = struct {
    device_epoch: u64,
    generation: u64,
    domain: Domain,
    capabilities: DeviceCapabilities,
    clc: Clc,
    board: Board,
    power: []const PowerChannel,
};
pub const Stage = enum { idle, submitting, policy_submitted, failed };
pub const Session = struct {
    owner_address: usize = 0,
    device_epoch: u64 = 0,
    highest_generation: u64 = 0,
    submitted_generation: u64 = 0,
    stage: Stage = .idle,
    domain_packet: [domain_size]u8 = undefined,
    power_packet: [power_size]u8 = undefined,
    clc_packet: [4096]u8 = undefined,
    /// Initialize a zero-owner Session (.{}), once. Retain it in place and
    /// serialize calls and all borrowed plan inputs throughout submission.
    pub fn init(self: *Session, device_epoch: u64) !void {
        if (self.owner_address != 0) return error.SessionAlreadyInitialized;
        if (device_epoch == 0) return error.InvalidDeviceEpoch;
        self.owner_address = @intFromPtr(self);
        self.device_epoch = device_epoch;
        self.highest_generation = 0;
        self.submitted_generation = 0;
        self.stage = .idle;
    }
    pub fn isSubmitted(self: *const Session, epoch: u64, generation: u64) bool {
        return self.owner_address == @intFromPtr(self) and generation != 0 and self.device_epoch == epoch and self.stage == .policy_submitted and self.submitted_generation == generation;
    }
    fn checkOwner(self: *const Session) !void {
        if (self.owner_address == 0) return error.SessionUninitialized;
        if (self.owner_address != @intFromPtr(self)) return error.MovedSession;
    }
    pub fn invalidate(self: *Session) !void {
        try self.checkOwner();
        if (self.stage == .submitting) return error.RegulatoryBusy;
        self.submitted_generation = 0;
        if (self.stage != .failed) self.stage = .idle;
    }
    /// Caller must independently prove real hardware reset/quiescence. A new
    /// epoch invalidates every previously submitted policy without ABA reuse.
    pub fn afterDeviceReset(self: *Session, epoch: u64) !void {
        try self.checkOwner();
        if (self.stage == .submitting) return error.RegulatoryBusy;
        if (epoch == 0 or epoch <= self.device_epoch) return error.StaleDeviceEpoch;
        self.device_epoch = epoch;
        self.submitted_generation = 0;
        self.stage = .idle;
    }
    fn preflight(self: *Session, plan: Plan) !void {
        try self.checkOwner();
        if (self.stage == .submitting) return error.RegulatoryBusy;
        if (self.stage == .failed) return error.RegulatoryResetRequired;
        if (self.device_epoch == 0 or plan.device_epoch != self.device_epoch) return error.StaleDeviceEpoch;
        if (plan.generation == 0 or plan.generation <= self.highest_generation) return error.StalePolicyGeneration;
        _ = try encodeDomain(plan.domain, plan.capabilities, &self.domain_packet);
        try plan.clc.validate();
        if (plan.clc.encapsulation != plan.board.encapsulation) return error.ClcEncapsulationMismatch;
        var iterator = plan.clc.rules(plan.domain.country);
        var count: usize = 0;
        var power_found = false;
        while (iterator.next()) |rule| {
            count += 1;
            if (count > max_country_rules) return error.TooManyClcRules;
            if (rule.index == 0) power_found = true;
            _ = try encodeClc(rule, plan.domain.environment, plan.board, &self.clc_packet);
        }
        if (!power_found) return error.CountryMissingClc;
        if (plan.power.len != plan.domain.channels.len) return error.IncompleteRatePower;
        for (plan.power, 0..) |p, i| {
            try validatePower(plan.domain, plan.capabilities, p);
            for (plan.power[0..i]) |previous| if (previous.band == p.band and previous.number == p.number) return error.DuplicatePowerChannel;
        }
    }
    pub fn submit(self: *Session, mcu: *Mcu, plan: Plan) !void {
        // All possible input failures precede generation issuance and I/O.
        try self.preflight(plan);
        self.highest_generation = plan.generation;
        self.submitted_generation = 0;
        self.stage = .submitting;
        errdefer self.stage = .failed;
        var iterator = plan.clc.rules(plan.domain.country);
        while (iterator.next()) |rule| {
            const packet = try encodeClc(rule, plan.domain.environment, plan.board, &self.clc_packet);
            try mcu.sendCe(clc_command, packet);
        }
        try mcu.sendCe(domain_command, try encodeDomain(plan.domain, plan.capabilities, &self.domain_packet));
        var batch: [power_batch_channels]PowerChannel = undefined;
        var emitted: usize = 0;
        for ([_]Band{ .ghz2, .ghz5, .ghz6 }) |band| {
            var n: usize = 0;
            for (plan.power) |p| {
                if (p.band != band) continue;
                batch[n] = p;
                n += 1;
                if (n == power_batch_channels) {
                    emitted += n;
                    try mcu.sendCe(power_command, try encodePowerBatch(plan.domain, plan.capabilities, batch[0..n], emitted == plan.power.len, &self.power_packet));
                    n = 0;
                }
            }
            if (n != 0) {
                emitted += n;
                try mcu.sendCe(power_command, try encodePowerBatch(plan.domain, plan.capabilities, batch[0..n], emitted == plan.power.len, &self.power_packet));
            }
        }
        self.submitted_generation = plan.generation;
        self.stage = .policy_submitted;
    }
};
