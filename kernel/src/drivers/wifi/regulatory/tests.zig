const std = @import("std");
const t = std.testing;
const r = @import("root.zig");
const rule: r.Rule = .{ .start_khz = 2_402_000, .end_khz = 2_482_000, .max_bandwidth_khz = 40_000, .max_eirp_mbm = 2000 };
const us: r.Country = .{ .alpha2 = .{ 'U', 'S' }, .rules = &.{rule} };
fn cap(channel: u16) r.ChannelCap {
    return .{ .band = .ghz2, .channel = channel, .center_khz = r.centerKhz(.ghz2, channel) catch unreachable, .calibrated = true, .available_rx = true, .max_conducted_power_mbm = 2500, .antenna_gain_mbi = 300 };
}
fn decide(country: *const r.Country, device: r.ChannelCap, environment: r.Environment) !r.Decision {
    return r.evaluate(country, device, environment, .{ .band = device.band, .channel = device.channel });
}
test "exact20MHz boundaries permit containment and never combine adjacent ranges" {
    var boundary: r.Rule = rule;
    boundary.start_khz = 2_402_000;
    boundary.end_khz = 2_422_000;
    boundary.max_bandwidth_khz = 20_000;
    var country: r.Country = .{ .alpha2 = .{ 'U', 'S' }, .rules = &.{boundary} };
    try t.expect((try decide(&country, cap(1), .unknown)).allow_initiate_tx);
    boundary.start_khz += 1;
    country.rules = &.{boundary};
    const denied = try decide(&country, cap(1), .unknown);
    try t.expect(!denied.allow_passive_scan and !denied.allow_initiate_tx);
    try t.expect(denied.reasons & r.Reasons.no_matching_rule != 0);
    const split = [_]r.Rule{
        .{ .start_khz = 2_402_000, .end_khz = 2_412_000, .max_bandwidth_khz = 20_000, .max_eirp_mbm = 2000 },
        .{ .start_khz = 2_412_000, .end_khz = 2_422_000, .max_bandwidth_khz = 20_000, .max_eirp_mbm = 2000 },
    };
    country.rules = &split;
    try t.expect(!(try decide(&country, cap(1), .unknown)).allow_passive_scan);
    try t.expect(!(try decide(&us, cap(14), .unknown)).allow_passive_scan);
}
test "all overlapping country and board restrictions intersect" {
    const restricted: r.Rule = .{ .start_khz = 2_450_000, .end_khz = 2_482_000, .max_bandwidth_khz = 20_000, .max_eirp_mbm = 1500, .flags = r.Flags.no_ir };
    const country: r.Country = .{ .alpha2 = .{ 'U', 'S' }, .rules = &.{ rule, restricted } };
    const result = try decide(&country, cap(9), .unknown);
    try t.expect(result.allow_passive_scan and !result.allow_initiate_tx);
    try t.expectEqual(@as(?i32, 1500), result.max_eirp_mbm);
    try t.expectEqual(@as(?i32, 1200), result.max_conducted_power_mbm);
    var device = cap(1);
    device.flags = r.Flags.no_ir | r.Flags.ir_concurrent;
    try t.expect(!(try decide(&us, device, .unknown)).allow_initiate_tx);
    const disjoint: r.Rule = .{ .start_khz = 5_170_000, .end_khz = 5_250_000, .max_bandwidth_khz = 80_000, .max_eirp_mbm = -1000, .flags = r.Flags.dfs };
    const other: r.Country = .{ .alpha2 = .{ 'U', 'S' }, .rules = &.{ rule, disjoint } };
    try t.expect((try decide(&other, cap(1), .unknown)).allow_initiate_tx);
}
test "world noIR DFS and indoor outdoor environments never authorize unsupported initiation" {
    const world: r.Country = .{ .alpha2 = .{ '0', '0' }, .rules = &.{rule} };
    const roaming = try decide(&world, cap(1), .indoor);
    try t.expect(roaming.allow_passive_scan and !roaming.allow_initiate_tx);
    try t.expect(roaming.flags & r.Flags.no_ir != 0 and roaming.reasons & r.Reasons.world != 0);
    for ([_]u32{ r.Flags.no_ir, r.Flags.dfs }) |flag| {
        var limited = rule;
        limited.flags = flag;
        const country: r.Country = .{ .alpha2 = .{ 'U', 'S' }, .dfs_region = .fcc, .rules = &.{limited} };
        const result = try decide(&country, cap(1), .indoor);
        try t.expect(result.allow_passive_scan and !result.allow_initiate_tx);
    }
    var limited = rule;
    limited.flags = r.Flags.no_outdoor;
    var country: r.Country = .{ .alpha2 = .{ 'U', 'S' }, .rules = &.{limited} };
    try t.expect((try decide(&country, cap(1), .indoor)).allow_initiate_tx);
    try t.expect(!(try decide(&country, cap(1), .outdoor)).allow_passive_scan);
    try t.expect(!(try decide(&country, cap(1), .unknown)).allow_passive_scan);
    limited.flags = r.Flags.no_indoor;
    country.rules = &.{limited};
    try t.expect((try decide(&country, cap(1), .outdoor)).allow_initiate_tx);
    try t.expect(!(try decide(&country, cap(1), .indoor)).allow_passive_scan);
    try t.expect(!(try decide(&country, cap(1), .unknown)).allow_passive_scan);
}
test "calibrated receive certified power and gain are explicit independent proofs" {
    var device = cap(1);
    device.calibrated = false;
    var result = try decide(&us, device, .unknown);
    try t.expect(!result.allow_passive_scan and !result.allow_initiate_tx);
    device.calibrated = true;
    device.available_rx = false;
    try t.expect(!(try decide(&us, device, .unknown)).allow_passive_scan);
    device.available_rx = true;
    device.max_conducted_power_mbm = null;
    result = try decide(&us, device, .unknown);
    try t.expect(result.allow_passive_scan and !result.allow_initiate_tx and result.max_conducted_power_mbm == null);
    device.max_conducted_power_mbm = 2500;
    device.antenna_gain_mbi = null;
    try t.expect(!(try decide(&us, device, .unknown)).allow_initiate_tx);
}
test "negative conducted power gain limits and PSD arithmetic are conservative" {
    var limited = rule;
    limited.max_eirp_mbm = -100;
    var country: r.Country = .{ .alpha2 = .{ 'U', 'S' }, .rules = &.{limited} };
    var result = try decide(&country, cap(1), .unknown);
    try t.expect(result.allow_initiate_tx);
    try t.expectEqual(@as(?i32, -400), result.max_conducted_power_mbm);
    try t.expectEqual(@as(?i32, -100), result.max_eirp_mbm);
    limited.max_antenna_gain_mbi = 200;
    country.rules = &.{limited};
    result = try decide(&country, cap(1), .unknown);
    try t.expect(result.allow_passive_scan and !result.allow_initiate_tx and result.reasons & r.Reasons.antenna_gain != 0);
    var device = cap(1);
    device.antenna_gain_mbi = -300;
    device.max_conducted_power_mbm = 1000;
    result = try decide(&us, device, .unknown);
    try t.expectEqual(@as(?i32, 1000), result.max_conducted_power_mbm);
    try t.expectEqual(@as(?i32, 700), result.max_eirp_mbm);
    limited = rule;
    limited.psd_mbm_mhz = -1000;
    country.rules = &.{limited};
    result = try decide(&country, cap(1), .unknown);
    try t.expectEqual(@as(?i32, 301), result.max_eirp_mbm);
    try t.expectEqual(@as(?i32, 1), result.max_conducted_power_mbm);
    try t.expect(result.allow_passive_scan and !result.allow_initiate_tx and result.reasons & r.Reasons.psd != 0);
    limited.psd_mbm_mhz = std.math.maxInt(i32);
    country.rules = &.{limited};
    try t.expectError(error.PowerOverflow, decide(&country, cap(1), .unknown));
}
test "unsupported bandwidth6GHz AFC OFDM and unconfigured WMM stay denied" {
    var device = cap(1);
    const wider = try r.evaluate(&us, device, .unknown, .{ .band = .ghz2, .channel = 1, .bandwidth_khz = 40_000 });
    try t.expect(!wider.allow_passive_scan and !wider.allow_initiate_tx and wider.reasons & r.Reasons.unsupported_bandwidth != 0);
    device.max_bandwidth_khz = 10_000;
    try t.expect(!(try decide(&us, device, .unknown)).allow_passive_scan);
    const six: r.ChannelCap = .{ .band = .ghz6, .channel = 1, .center_khz = 5_955_000, .calibrated = true, .available_rx = true, .max_conducted_power_mbm = 2000, .antenna_gain_mbi = 0 };
    const unsupported = try decide(&us, six, .indoor);
    try t.expect(!unsupported.allow_passive_scan and unsupported.reasons & r.Reasons.unsupported_band != 0);
    var limited = rule;
    limited.flags = r.Flags.afc;
    var country: r.Country = .{ .alpha2 = .{ 'U', 'S' }, .rules = &.{limited} };
    try t.expect(!(try decide(&country, cap(1), .indoor)).allow_passive_scan);
    limited.flags = r.Flags.no_ofdm;
    country.rules = &.{limited};
    try t.expect(!(try decide(&country, cap(1), .indoor)).allow_initiate_tx);
    limited.flags = r.Flags.no_cck;
    country.rules = &.{limited};
    const no_cck = try decide(&country, cap(1), .indoor);
    try t.expect(no_cck.allow_passive_scan and !no_cck.allow_initiate_tx and no_cck.reasons & r.Reasons.no_cck != 0);
    limited.flags = 0;
    limited.wmm = .etsi;
    country.rules = &.{limited};
    try t.expect(!(try decide(&country, cap(1), .indoor)).allow_initiate_tx);
    device = cap(1);
    device.wmm_etsi_configured = true;
    try t.expect((try decide(&country, device, .indoor)).allow_initiate_tx);
}
test "malformed country caps request duplicates and limits reject before output" {
    const empty: r.Country = .{ .alpha2 = .{ 'U', 'S' }, .rules = &.{} };
    try t.expectError(error.EmptyRules, decide(&empty, cap(1), .unknown));
    var bad_country = us;
    bad_country.alpha2 = .{ 'u', 's' };
    try t.expectError(error.InvalidCountry, decide(&bad_country, cap(1), .unknown));
    var bad_rule = rule;
    bad_rule.flags = 1 << 31;
    bad_country = .{ .alpha2 = .{ 'U', 'S' }, .rules = &.{bad_rule} };
    try t.expectError(error.InvalidRule, decide(&bad_country, cap(1), .unknown));
    var device = cap(1);
    device.center_khz += 1;
    try t.expectError(error.InvalidCapabilities, decide(&us, device, .unknown));
    try t.expectError(error.EmptyCapabilities, r.validateCaps(&.{}));
    try t.expectError(error.DuplicateChannel, r.validateCaps(&.{ cap(1), cap(1) }));
    try t.expectError(error.RequestMismatch, r.evaluate(&us, cap(1), .unknown, .{ .band = .ghz2, .channel = 2 }));
    var too_many: [129]r.ChannelCap = undefined;
    try t.expectError(error.TooManyChannels, r.validateCaps(&too_many));
}
test "approved passive list is bounded atomic and excludes unsupported channels" {
    const caps = [_]r.ChannelCap{ cap(1), cap(6), cap(14) };
    var output: [2]r.Decision = @splat(.{ .center_khz = 123, .bandwidth_khz = 456 });
    try t.expectError(error.BufferTooSmall, r.approvedScanList(&us, &caps, .unknown, output[0..1]));
    try t.expectEqual(@as(u32, 123), output[0].center_khz);
    try t.expectEqual(@as(usize, 2), try r.approvedScanList(&us, &caps, .unknown, &output));
    try t.expectEqual(@as(u32, 2_412_000), output[0].center_khz);
    try t.expectEqual(@as(u32, 2_437_000), output[1].center_khz);
    var bad_caps = caps;
    bad_caps[2].center_khz = 0;
    const before = output;
    try t.expectError(error.InvalidCapabilities, r.approvedScanList(&us, &bad_caps, .unknown, &output));
    try t.expectEqualDeep(before, output);
    var aliased_caps = [_]r.ChannelCap{ cap(1), cap(6) };
    const original = aliased_caps;
    const aliased_output: [*]r.Decision = @ptrCast(&aliased_caps);
    try t.expectError(error.BufferOverlap, r.approvedScanList(&us, &aliased_caps, .unknown, aliased_output[0..1]));
    try t.expectEqualDeep(original, aliased_caps);
}
test "official database lookup keeps every country valid and unknown country absent" {
    try t.expectEqual(@as(usize, 182), r.database.countries.len);
    for (r.database.countries) |*country| try r.validateCountry(country);
    try t.expect(r.lookup(.{ 'U', 'S' }) != null and r.lookup(.{ '0', '0' }) != null);
    try t.expect(r.lookup(.{ 'Z', 'Z' }) == null);
    try t.expect(r.lookup(.{ 'u', 's' }) == null);
    const world = r.lookup(.{ '0', '0' }).?;
    const result = try decide(world, cap(1), .unknown);
    try t.expect(result.allow_passive_scan and !result.allow_initiate_tx);
}
