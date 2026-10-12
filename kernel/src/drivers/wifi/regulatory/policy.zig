//! Original conservative 20MHz policy intersection. This is not an RF/board
//! certification engine; trusted adapters supply the hardware proof records.
const std = @import("std");
const types = @import("types.zig");
const Flags = types.Flags;
const Reasons = types.Reasons;
pub const max_channel_caps = 128;
pub const max_country_rules = 128;
pub const supported_bandwidth_khz = 20_000;
pub const Error = error{ InvalidCountry, EmptyRules, TooManyRules, InvalidRule, InvalidCapabilities, EmptyCapabilities, TooManyChannels, DuplicateChannel, RequestMismatch, PowerOverflow, BufferTooSmall, BufferOverlap };

pub fn validCountryCode(code: [2]u8) bool {
    return (code[0] == '0' and code[1] == '0') or (code[0] >= 'A' and code[0] <= 'Z' and code[1] >= 'A' and code[1] <= 'Z');
}
pub fn validateCountry(country: *const types.Country) Error!void {
    if (!validCountryCode(country.alpha2)) return error.InvalidCountry;
    if (country.rules.len == 0) return error.EmptyRules;
    if (country.rules.len > max_country_rules) return error.TooManyRules;
    for (country.rules) |rule| {
        if (rule.start_khz == 0 or rule.end_khz <= rule.start_khz or rule.max_bandwidth_khz == 0 or rule.flags & ~Flags.all != 0 or
            rule.flags & (Flags.no_indoor | Flags.no_outdoor) == (Flags.no_indoor | Flags.no_outdoor)) return error.InvalidRule;
    }
}
/// Explicit channel identity validation, not a country/channel whitelist. The
/// board list remains authoritative for actual availability. 4.9GHz and wider
/// channel-number spaces are outside this profile and rejected before use.
pub fn centerKhz(band: types.Band, channel: u16) Error!u32 {
    return switch (band) {
        .ghz2 => if (channel >= 1 and channel <= 13) 2_407_000 + @as(u32, channel) * 5000 else if (channel == 14) 2_484_000 else error.InvalidCapabilities,
        .ghz5 => if (channel >= 32 and channel <= 177) 5_000_000 + @as(u32, channel) * 5000 else error.InvalidCapabilities,
        .ghz6 => if (channel == 2) 5_935_000 else if (channel >= 1 and channel <= 233 and (channel - 1) % 4 == 0) 5_950_000 + @as(u32, channel) * 5000 else error.InvalidCapabilities,
    };
}
pub fn validateCap(cap: types.ChannelCap) Error!void {
    if (cap.center_khz != try centerKhz(cap.band, cap.channel) or cap.max_bandwidth_khz == 0 or cap.flags & ~Flags.all != 0 or
        cap.flags & (Flags.no_indoor | Flags.no_outdoor) == (Flags.no_indoor | Flags.no_outdoor)) return error.InvalidCapabilities;
}
pub fn validateCaps(caps: []const types.ChannelCap) Error!void {
    if (caps.len == 0) return error.EmptyCapabilities;
    if (caps.len > max_channel_caps) return error.TooManyChannels;
    for (caps, 0..) |cap, i| {
        try validateCap(cap);
        for (caps[0..i]) |prior| if (prior.band == cap.band and prior.channel == cap.channel) return error.DuplicateChannel;
    }
}
fn checkedPower(value: i64) Error!i32 {
    if (value < std.math.minInt(i32) or value > std.math.maxInt(i32)) return error.PowerOverflow;
    return @intCast(value);
}
fn constrainedEnvironment(flags: u32, environment: types.Environment) bool {
    if (flags & Flags.no_outdoor != 0 and environment != .indoor) return true;
    if (flags & Flags.no_indoor != 0 and environment != .outdoor) return true;
    return false;
}

/// Borrow only during this call. The caller controls country/environment through
/// a trusted kernel authority; neither a beacon nor an application selects them.
/// Every positive-overlap rule intersects power/flags, even if another broad
/// rule fully contains the channel. At least one rule must contain all20MHz.
pub fn evaluate(country: *const types.Country, cap: types.ChannelCap, environment: types.Environment, request: types.Request) Error!types.Decision {
    try validateCountry(country);
    try validateCap(cap);
    if (request.band != cap.band or request.channel != cap.channel) return error.RequestMismatch;
    var result: types.Decision = .{ .center_khz = cap.center_khz, .bandwidth_khz = request.bandwidth_khz, .flags = cap.flags };
    if (request.bandwidth_khz != supported_bandwidth_khz or cap.max_bandwidth_khz < supported_bandwidth_khz) result.reasons |= Reasons.unsupported_bandwidth;
    if (request.band == .ghz6) result.reasons |= Reasons.unsupported_band;
    if (!cap.calibrated) result.reasons |= Reasons.uncalibrated;
    if (!cap.available_rx) result.reasons |= Reasons.receive_unavailable;
    if (result.reasons & (Reasons.unsupported_band | Reasons.unsupported_bandwidth) != 0) return result;
    const lower = @as(u64, cap.center_khz) - supported_bandwidth_khz / 2;
    const upper = @as(u64, cap.center_khz) + supported_bandwidth_khz / 2;
    var fully_covered = false;
    var eirp: ?i32 = null;
    var maximum_gain: ?i32 = null;
    var wmm = false;
    for (country.rules) |rule| {
        if (rule.start_khz >= upper or rule.end_khz <= lower) continue;
        result.flags |= rule.flags;
        if (rule.max_bandwidth_khz < supported_bandwidth_khz) result.reasons |= Reasons.unsupported_bandwidth;
        if (rule.start_khz <= lower and rule.end_khz >= upper and rule.max_bandwidth_khz >= supported_bandwidth_khz) fully_covered = true;
        var ceiling = rule.max_eirp_mbm;
        if (rule.psd_mbm_mhz) |psd| {
            // floor(100*10*log10(20)) =1301mB. Rounded down so a20MHz
            // total-power cap never exceeds the supplied per-MHz PSD cap.
            ceiling = @min(ceiling, try checkedPower(@as(i64, psd) + 1301));
            result.reasons |= Reasons.psd; // Total EIRP alone cannot prove per-MHz density enforcement.
        }
        eirp = if (eirp) |prior| @min(prior, ceiling) else ceiling;
        if (rule.max_antenna_gain_mbi) |gain| maximum_gain = if (maximum_gain) |prior| @min(prior, gain) else gain;
        wmm = wmm or rule.wmm == .etsi;
    }
    if (!fully_covered or eirp == null) result.reasons |= Reasons.no_matching_rule;
    if (constrainedEnvironment(result.flags, environment)) result.reasons |= Reasons.environment;
    if (result.flags & Flags.afc != 0) result.reasons |= Reasons.afc;
    const receive_denials = Reasons.unsupported_bandwidth | Reasons.uncalibrated | Reasons.receive_unavailable | Reasons.no_matching_rule | Reasons.environment | Reasons.afc;
    result.allow_passive_scan = result.reasons & receive_denials == 0;
    result.max_eirp_mbm = eirp;
    if (cap.max_conducted_power_mbm != null and cap.antenna_gain_mbi != null and eirp != null) {
        const gain = cap.antenna_gain_mbi.?;
        if (maximum_gain) |limit| if (gain > limit) {
            result.reasons |= Reasons.antenna_gain;
        };
        const power = @min(cap.max_conducted_power_mbm.?, try checkedPower(@as(i64, eirp.?) - gain));
        result.max_conducted_power_mbm = power;
        result.max_eirp_mbm = @min(eirp.?, try checkedPower(@as(i64, power) + gain));
    } else result.reasons |= Reasons.power_unproven;
    if (result.flags & Flags.no_ir != 0) result.reasons |= Reasons.no_ir;
    if (result.flags & Flags.dfs != 0) result.reasons |= Reasons.dfs;
    if (result.flags & Flags.no_ofdm != 0 or (cap.band == .ghz2 and cap.channel == 14)) result.reasons |= Reasons.no_ofdm;
    if (result.flags & Flags.no_cck != 0) result.reasons |= Reasons.no_cck;
    if (wmm and !cap.wmm_etsi_configured) result.reasons |= Reasons.wmm;
    if (country.alpha2[0] == '0' and country.alpha2[1] == '0') {
        result.reasons |= Reasons.world | Reasons.no_ir;
        result.flags |= Flags.no_ir;
    }
    const transmit_denials = receive_denials | Reasons.no_ir | Reasons.dfs | Reasons.power_unproven | Reasons.antenna_gain | Reasons.world | Reasons.wmm | Reasons.no_ofdm | Reasons.no_cck | Reasons.psd;
    result.allow_initiate_tx = result.reasons & transmit_denials == 0;
    return result;
}

/// Write only after complete preflight, so a short buffer or malformed cap/rule
/// cannot publish a partial approved list. Output records own their decisions.
pub fn approvedScanList(country: *const types.Country, caps: []const types.ChannelCap, environment: types.Environment, output: []types.Decision) Error!usize {
    try validateCountry(country);
    try validateCaps(caps);
    const size = @mulWithOverflow(output.len, @sizeOf(types.Decision));
    const output_base = @intFromPtr(output.ptr);
    const output_end = @addWithOverflow(output_base, size[0]);
    if (size[1] != 0 or output_end[1] != 0) return error.BufferOverlap;
    for ([_][]const u8{ std.mem.sliceAsBytes(caps), std.mem.sliceAsBytes(country.rules), std.mem.asBytes(country) }) |input| {
        const base = @intFromPtr(input.ptr);
        const end = @addWithOverflow(base, input.len);
        if (end[1] != 0 or (size[0] != 0 and input.len != 0 and base < output_end[0] and output_base < end[0])) return error.BufferOverlap;
    }
    var count: usize = 0;
    for (caps) |cap| {
        const decision = try evaluate(country, cap, environment, .{ .band = cap.band, .channel = cap.channel });
        count += @intFromBool(decision.allow_passive_scan);
    }
    if (output.len < count) return error.BufferTooSmall;
    var at: usize = 0;
    for (caps) |cap| {
        const decision = try evaluate(country, cap, environment, .{ .band = cap.band, .channel = cap.channel });
        if (!decision.allow_passive_scan) continue;
        output[at] = decision;
        at += 1;
    }
    return at;
}
