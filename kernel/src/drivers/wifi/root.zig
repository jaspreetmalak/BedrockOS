//! Native chipset protocol ports and trusted device inventory. Recognizing a
//! PCI ID or parsing firmware is not an operational or qualified radio backend.
const protocol = @import("boot_protocol");
pub const pci = @import("pci");
pub const pci_native = @import("pci_native");
pub const resources = @import("resources.zig");
pub const mediatek = @import("mediatek/root.zig");
pub const intel = @import("intel/root.zig");
pub const realtek = @import("realtek/root.zig");
pub const ieee80211 = @import("ieee80211/root.zig");
pub const mt7922_transport = @import("mt7922_transport.zig");
pub const regulatory = @import("regulatory/root.zig");
pub const radio_policy = @import("radio_policy.zig");
pub const Family = enum { mediatek_mt792x, intel_iwlwifi, realtek_rtw89, unknown };
pub const Candidate = struct { device: pci.Device, family: Family, hardware_backend: bool = false };
pub const Inventory = struct { candidates: [16]Candidate = undefined, count: usize = 0, dropped: usize = 0, config_accessible: bool = false };
pub fn family(vendor: u16, product: u16) Family {
    // Numeric device identities from the pinned mt7921 PCI inventory. The
    // translated register/firmware port currently targets MT7922 specifically.
    if ((vendor == 0x14c3 and (product == 0x7961 or product == 0x7922 or product == 0x0608 or product == 0x0616 or product == 0x7920)) or
        (vendor == 0x0b48 and product == 0x7922)) return .mediatek_mt792x;
    if (intel.profiles.identify(vendor, product) != null) return .intel_iwlwifi;
    if (realtek.profiles.identify(vendor, product) != null) return .realtek_rtw89;
    return .unknown;
}
pub fn discover(info: *const protocol.BootInfo) !Inventory {
    const config = pci_native.legacy(info) catch return .{};
    return inspect(config, 0, 0, 255);
}
pub fn inspect(config: pci.Config, segment: u16, first: u8, last: u8) !Inventory {
    const devices = try pci.wirelessInventory(config, segment, first, last);
    var result: Inventory = .{ .config_accessible = true, .count = devices.count, .dropped = devices.dropped };
    for (devices.items[0..devices.count], 0..) |device, index| result.candidates[index] = .{ .device = device, .family = family(device.vendor, device.product) };
    return result;
}
test {
    _ = @import("tests.zig");
    _ = pci;
    _ = pci_native;
    _ = resources;
    _ = mediatek;
    _ = intel;
    _ = realtek;
    _ = ieee80211;
    _ = mt7922_transport;
    _ = regulatory;
    _ = radio_policy;
}
