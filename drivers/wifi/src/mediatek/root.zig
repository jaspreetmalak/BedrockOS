// SPDX-License-Identifier: ISC
// Copyright (C) 2026 Bedrock contributors
//! MT7922 device-protocol port, not a qualified operational radio backend.
pub const regs = @import("regs.zig");
pub const registers = @import("registers.zig");
pub const Mmio = registers.Mmio;
pub const Registers = registers.Registers;
pub const firmware = @import("firmware.zig");
pub const dma = @import("dma.zig");
pub const mcu = @import("mcu.zig");
pub const mac = @import("mac.zig");
pub const scan = @import("scan.zig");
pub const regulatory = @import("regulatory.zig");
pub const nic = @import("nic.zig");
pub const nic_registers = @import("nic_registers.zig");
pub const board = @import("board.zig");
pub const Mcu = mcu.Mcu;
pub const Driver = @import("driver.zig").Driver;
pub const Clock = @import("driver.zig").Clock;
test {
    _ = @import("tests.zig");
    _ = @import("regulatory_tests.zig");
    _ = @import("nic_tests.zig");
    _ = @import("board_tests.zig");
}
