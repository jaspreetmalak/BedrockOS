// SPDX-License-Identifier: BSD-3-Clause
// Selected BSD option from Linux v6.18 iwlwifi/pcie/drv.c and cfg/*.c.
// Copyright (C) 2005-2014, 2018-2025 Intel Corporation
// Copyright (C) 2013-2015 Intel Mobile Communications GmbH
// Copyright (C) 2015-2017 Intel Deutschland GmbH
// Original notices and license terms are retained in NOTICE.md and LICENSE.
//! PCI family inventory only. Subsystem IDs, MAC/RF revision and NVM remain
//! necessary before selecting firmware or enabling a transport.
pub const vendor_id: u16 = 0x8086;
pub const Family = enum { series7000, series8000, ax200, ax210 };
pub const Profile = struct {
    device_id: u16,
    family: Family,
    name: []const u8,
    gen2_transport: bool,
    hardware_backend: bool = false,
};
pub const inventory = [_]Profile{
    .{ .device_id = 0x08b1, .family = .series7000, .name = "7260", .gen2_transport = false },
    .{ .device_id = 0x08b2, .family = .series7000, .name = "7260", .gen2_transport = false },
    .{ .device_id = 0x08b3, .family = .series7000, .name = "3160", .gen2_transport = false },
    .{ .device_id = 0x08b4, .family = .series7000, .name = "3160", .gen2_transport = false },
    .{ .device_id = 0x3165, .family = .series7000, .name = "3165", .gen2_transport = false },
    .{ .device_id = 0x3166, .family = .series7000, .name = "3165", .gen2_transport = false },
    .{ .device_id = 0x24fb, .family = .series7000, .name = "3168", .gen2_transport = false },
    .{ .device_id = 0x095a, .family = .series7000, .name = "7265 (revision-dependent)", .gen2_transport = false },
    .{ .device_id = 0x095b, .family = .series7000, .name = "7265 (revision-dependent)", .gen2_transport = false },
    .{ .device_id = 0x24f3, .family = .series8000, .name = "8260", .gen2_transport = false },
    .{ .device_id = 0x24f4, .family = .series8000, .name = "8260", .gen2_transport = false },
    .{ .device_id = 0x24f5, .family = .series8000, .name = "4165", .gen2_transport = false },
    .{ .device_id = 0x24f6, .family = .series8000, .name = "4165", .gen2_transport = false },
    .{ .device_id = 0x24fd, .family = .series8000, .name = "8265 / subsystem variants", .gen2_transport = false },
    .{ .device_id = 0x2723, .family = .ax200, .name = "AX200", .gen2_transport = true },
    .{ .device_id = 0x2725, .family = .ax210, .name = "AX210", .gen2_transport = true },
};
pub fn identify(vendor: u16, device: u16) ?*const Profile {
    if (vendor != vendor_id) return null;
    for (&inventory) |*profile| if (profile.device_id == device) return profile;
    return null;
}
