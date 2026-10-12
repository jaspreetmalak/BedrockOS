// SPDX-License-Identifier: BSD-3-Clause
// Selected BSD option from Linux v6.18 rtw89/rtw8852{ae,be,ce}.c.
// Copyright(c) 2019-2022 Realtek Corporation
pub const vendor_id: u16 = 0x10ec;
pub const Chip = enum { rtl8852a, rtl8852b, rtl8852c };
pub const Profile = struct { device_id: u16, chip: Chip, firmware_basename: []const u8, hardware_backend: bool = false };
pub const inventory = [_]Profile{
    .{ .device_id = 0x8852, .chip = .rtl8852a, .firmware_basename = "rtw89/rtw8852a_fw" },
    .{ .device_id = 0xa85a, .chip = .rtl8852a, .firmware_basename = "rtw89/rtw8852a_fw" },
    .{ .device_id = 0xb852, .chip = .rtl8852b, .firmware_basename = "rtw89/rtw8852b_fw" },
    .{ .device_id = 0xb85b, .chip = .rtl8852b, .firmware_basename = "rtw89/rtw8852b_fw" },
    .{ .device_id = 0xc852, .chip = .rtl8852c, .firmware_basename = "rtw89/rtw8852c_fw" },
};
pub fn identify(vendor: u16, device: u16) ?*const Profile {
    if (vendor != vendor_id) return null;
    for (&inventory) |*profile| if (profile.device_id == device) return profile;
    return null;
}
