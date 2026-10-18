const std = @import("std");
const drivers = @import("root.zig");
test "native Wi-Fi family discovery never turns a profile or firmware parser into a radio backend" {
    try std.testing.expectEqual(drivers.Family.mediatek_mt792x, drivers.family(0x14c3, 0x0616));
    try std.testing.expectEqual(drivers.Family.mediatek_mt792x, drivers.family(0x0b48, 0x7922));
    try std.testing.expectEqual(drivers.Family.unknown, drivers.family(0x0e8d, 0x7922));
    try std.testing.expectEqual(drivers.Family.intel_iwlwifi, drivers.family(0x8086, 0x2723));
    try std.testing.expectEqual(drivers.Family.realtek_rtw89, drivers.family(0x10ec, 0xb852));
    try std.testing.expectEqual(drivers.Family.unknown, drivers.family(0x1af4, 0x1041));
    try std.testing.expectEqual(drivers.Family.unknown, drivers.family(0xffff, 0x0616));
    const candidate: drivers.Candidate = .{ .device = .{ .bdf = .{ .bus = 3, .device = 0, .function = 0 }, .vendor = 0x14c3, .product = 0x0616, .class = 2, .subclass = 0x80, .programming_interface = 0, .revision = 0, .header = 0 }, .family = .mediatek_mt792x };
    try std.testing.expect(!candidate.hardware_backend);
}
