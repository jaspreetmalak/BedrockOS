const regulatory = @import("root.zig");
export fn bedrock_regulatory_probe(country: *const [2]u8, cap: *const regulatory.ChannelCap) callconv(.c) u32 {
    const rules = regulatory.lookup(country.*) orelse return 0;
    const decision = regulatory.evaluate(rules, cap.*, .unknown, .{ .band = cap.band, .channel = cap.channel }) catch return 0;
    return @as(u32, @intFromBool(decision.allow_passive_scan)) | @as(u32, @intFromBool(decision.allow_initiate_tx)) << 1;
}
