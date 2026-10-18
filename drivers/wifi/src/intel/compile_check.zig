// SPDX-License-Identifier: BSD-3-Clause
const intel = @import("root.zig");
/// Compile-only entry, never called by a hardware backend.
export fn bedrock_intel_wifi_probe(bytes: [*]const u8, length: usize, result: *intel.firmware.Container, vendor: u16, device: u16) callconv(.c) u64 {
    intel.firmware.inspect(bytes[0..length], result) catch return 0;
    const profile = intel.profiles.identify(vendor, device) orelse return 0;
    result.requireApi(1, 255) catch return 0;
    return result.api + @as(u64, @intFromBool(profile.gen2_transport)) + @as(u64, @intFromBool(result.hasCapability(128)));
}
