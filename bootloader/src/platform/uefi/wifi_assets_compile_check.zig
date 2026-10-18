//! Forces the actual UEFI protocol path into freestanding compile probes.
const std = @import("std");
const assets = @import("wifi_assets.zig");
export fn bedrock_wifi_assets_check(bs: *std.os.uefi.tables.BootServices, image: std.os.uefi.Handle, limit: u64) callconv(.c) u32 {
    var result = assets.stage(bs, image, limit) catch return 1;
    if (result.assets) |*retained| {
        var handoff: @import("boot_protocol").WifiBoot = undefined;
        retained.publish(&handoff);
        retained.release(bs) catch return 2;
        return handoff.flags;
    }
    return 0;
}
