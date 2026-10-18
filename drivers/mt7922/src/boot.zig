//! One boot-scoped, private owner tree for the physical MT7922 station.
//! All platform objects stay in place; errors retire DMA before attachment.
const std = @import("std");
const builtin = @import("builtin");
const protocol = @import("boot_protocol");
const drivers = @import("wifi_drivers");
const mt = drivers.mediatek;
const platform_api = drivers.x86_64_platform;
pub const Stage = enum { absent, profile, entropy, platform, takeover, firmware, board, policy, binding, ready };
pub const Report = struct { attempted: bool = false, stage: Stage = .absent, failure: ?anyerror = null, factory_power_intersected: bool = false, dma_retained: bool = false };
var report: Report = .{};
var provider: platform_api.Provider = .{};
var transport: drivers.mt7922_transport.Transport = .{};
var client: mt.nic.Client = .{};
var authority: drivers.radio_policy.Authority = .{};
var binding: drivers.mt7922_station.Binding = .{};
var random: drivers.entropy.Generator = .{};
var profile: mt.board.Profile = .{};
var caps: [mt.board.max_channels]drivers.regulatory.ChannelCap = undefined;
var powers: [mt.board.max_channels]mt.regulatory.PowerChannel = undefined;

pub fn status() Report {
    return report;
}
/// Pure structural preflight, also used in native tests. It does not dereference
/// physical asset addresses or touch any PCI/MMIO provider.
pub fn preflight(info: *const protocol.BootInfo) !bool {
    try info.wifi.validate();
    if (info.wifi.flags == 0) return false;
    if (info.boot_environment != @backingInt(protocol.BootEnvironment.uefi)) return error.InvalidWifiBoot;
    if (!info.isMapped(info.wifi.reservation)) return error.UnmappedWifiAssets;
    if (info.wifi.flags & protocol.WifiBootFlags.profile == 0) return error.MissingBoardProfile;
    if (info.wifi.flags & protocol.WifiBootFlags.entropy == 0) return error.MissingFirmwareEntropy;
    return true;
}
fn bytes(range: protocol.PhysicalRange) []const u8 {
    const pointer: [*]const u8 = @ptrFromInt(range.base);
    return pointer[0..@intCast(range.length)];
}
fn eraseSeed(info: *const protocol.BootInfo) void {
    // The validated BootInfo resides in retained, supervisor RW loader memory.
    const assets = @constCast(&info.wifi);
    std.crypto.secureZero(u8, &assets.seed);
    assets.flags &= ~protocol.WifiBootFlags.entropy;
}
pub fn discardEntropy(info: *const protocol.BootInfo) void {
    eraseSeed(info);
}
fn cleanup() void {
    if (binding.owner_address == @intFromPtr(&binding)) {
        binding.retire() catch {};
    } else if (transport.owner_address == @intFromPtr(&transport) and transport.state != .stopped) {
        transport.stop() catch {};
    }
    report.dma_retained = transport.lease.ticket != null and !transport.lease.released;
    random.deinit();
}
pub fn retire() void {
    cleanup();
}
pub fn attachmentFailed() void {
    report.stage = .binding;
    report.failure = error.ControllerAttachmentFailed;
    cleanup();
}
/// Absence is normal. Present assets must pass the trusted board/profile and
/// named platform checks before the first hardware mutation. No reset retries.
pub fn initialize(info: *const protocol.BootInfo) !?*drivers.mt7922_station.Binding {
    if (report.attempted) return error.WifiBootAlreadyAttempted;
    report.attempted = true;
    // No secret survives even an unsupported platform or missing board file.
    defer eraseSeed(info);
    return initializeOnce(info) catch |err| {
        report.failure = err;
        cleanup();
        return err;
    };
}
fn initializeOnce(info: *const protocol.BootInfo) !?*drivers.mt7922_station.Binding {
    report.stage = .profile;
    if (!try preflight(info)) {
        report.stage = .absent;
        return null;
    }
    try mt.board.decode(bytes(info.wifi.profile), &profile);
    report.stage = .platform;
    if (builtin.cpu.arch != .x86_64) return error.UnsupportedNativePlatform;
    const id = profile.identity;
    const flags = profile.platform_flags;
    const options: platform_api.Options = .{
        .opt_in = flags & mt.board.PlatformFlags.opt_in != 0,
        .coherent_identity_dma = flags & mt.board.PlatformFlags.coherent_identity_dma != 0,
        .iommu_disabled = flags & mt.board.PlatformFlags.iommu_disabled != 0,
        .exclusive_takeover = flags & mt.board.PlatformFlags.exclusive_takeover != 0,
        .identity = .{ .vendor = id.vendor, .product = id.device, .subsystem_vendor = id.subsystem_vendor, .subsystem_product = id.subsystem_device, .revision = id.revision },
    };
    const firmware: drivers.mt7922_transport.Firmware = .{ .patch = bytes(info.wifi.patch), .ram = bytes(info.wifi.ram) };
    try firmware.validate();
    const clc = try mt.regulatory.Clc.fromRam(try mt.firmware.parseRam(firmware.ram), profile.board.encapsulation);
    const device = try platform_api.select(info, options);
    try provider.prepare(info, device, options);
    report.stage = .entropy;
    try random.init(@constCast(&info.wifi.seed));
    report.stage = .takeover;
    try provider.takeover();
    try provider.bindTransport(&transport);
    try transport.prepare(provider.config(), device, provider.platform());
    report.stage = .firmware;
    try transport.start(firmware);
    // This epoch follows the actual completed driver reset and firmware load.
    const epoch: u64 = 1;
    try client.initReusable(&transport.mcu, epoch);
    report.stage = .board;
    const capabilities = try client.capabilities();
    const efuse = try client.readEfuse(0x550);
    const subsystem = try provider.config().read(device.bdf, 0x2c);
    const actual: mt.board.Identity = .{ .vendor = device.vendor, .device = device.product, .subsystem_vendor = @truncate(subsystem), .subsystem_device = @truncate(subsystem >> 16), .revision = device.revision };
    const count = try profile.buildCapabilities(actual, capabilities, efuse, &caps, &powers);
    _ = try client.useEfuse();
    const factory = try client.txPowerInfo();
    for (powers[0..count]) |*power| {
        if (factory.channel == power.number and factory.channel != 0) {
            try factory.intersect(power.*, power);
            report.factory_power_intersected = true;
        }
    }
    report.stage = .policy;
    try authority.init(epoch, caps[0..count]);
    const generation = try authority.select(profile.country, profile.environment);
    try authority.submit(generation, &transport.mcu, .{ .clc = clc, .board = profile.board, .power = powers[0..count] });
    report.stage = .binding;
    // Pinned mt76 mac80211.c OFDM_RATE(11,60), PHY_TYPE_OFDM=1,
    // mt76_connac2_mac.h MODE[9:6]/IDX[5:0]: 6 Mbps OFDM = 0x4b.
    // Only 20 MHz OFDM WPA2 peers are supported by this initial boot port.
    try binding.init(&transport, &authority, &client, .{ .device_epoch = epoch, .fixed_rate = 0x4b, .entropy_context = &random, .entropy = drivers.entropy.Generator.nonce });
    report.stage = .ready;
    return &binding;
}

test "physical boot preflight distinguishes absent missing profile entropy and mapping" {
    var info: protocol.BootInfo = undefined;
    info.wifi = .{};
    try std.testing.expect(!try preflight(&info));
    info.boot_environment = @backingInt(protocol.BootEnvironment.uefi);
    info.wifi = .{ .version = 1, .flags = protocol.WifiBootFlags.firmware, .reservation = .{ .base = 0x1000000, .length = 0x200000 }, .patch = .{ .base = 0x1000000, .length = 137632 }, .ram = .{ .base = 0x1022000, .length = 1231252 } };
    info.mapped_range_count = 1;
    info.mapped_ranges[0] = info.wifi.reservation;
    try std.testing.expectError(error.MissingBoardProfile, preflight(&info));
    info.wifi.flags |= protocol.WifiBootFlags.profile;
    info.wifi.profile = .{ .base = 0x1180000, .length = 320 };
    try std.testing.expectError(error.MissingFirmwareEntropy, preflight(&info));
    info.wifi.flags |= protocol.WifiBootFlags.entropy;
    info.wifi.seed = @splat(0x55);
    try std.testing.expect(try preflight(&info));
    info.mapped_range_count = 0;
    try std.testing.expectError(error.UnmappedWifiAssets, preflight(&info));
    eraseSeed(&info);
    try std.testing.expect(std.mem.allEqual(u8, &info.wifi.seed, 0));
    try std.testing.expectEqual(@as(u32, protocol.WifiBootFlags.firmware | protocol.WifiBootFlags.profile), info.wifi.flags);
    try info.wifi.validate();
}
