// SPDX-License-Identifier: ISC
// Copyright (C) 2020 MediaTek Inc.
// Copyright (C) 2026 Bedrock contributors
// Derived from Linux v6.18 mt7921/{init.c,mac.c,regs.h}, mt792x_{mac.c,regs.h}.
// See PROVENANCE.json and LICENSE.
//! Bounded global MAC register setup. No PHY calibration/TX permission asserted.
const Registers = @import("registers.zig").Registers;
pub const Clock = struct { context: *anyopaque, delayUs: *const fn (*anyopaque, u32) anyerror!void };
pub const mdp_control: u32 = 0x820cd000;
pub const mdp_length: u32 = 0x820cd004;
pub const wtbl_update: u32 = 0x820d4230;
pub const raw_rx_limit = 1536;
fn update(registers: *Registers, address: u32, mask: u32, value: u32) !void {
    const before = try registers.read(address);
    if (before == 0xffffffff) return error.DeviceRemoved;
    _ = try registers.update(address, mask, value);
    const after = try registers.read(address);
    if (after == 0xffffffff) return error.DeviceRemoved;
    if (after & mask != value) return error.MacRegisterVerificationFailed;
}
fn waitWtbl(registers: *Registers, clock: Clock) !void {
    for (0..5000) |_| {
        const v = try registers.read(wtbl_update);
        if (v == 0xffffffff) return error.DeviceRemoved;
        if (v & (1 << 31) == 0) return;
        try clock.delayUs(clock.context, 1);
    }
    return error.WtblTimeout;
}
/// Caller owns firmware/device state and serializes the complete initialization.
/// Raw software-CCMP profile deliberately disables global Ethernet translation;
/// source deaggregation and counter setup are retained. This does not enable TX.
pub fn initialize(registers: *Registers, clock: Clock) !void {
    try update(registers, mdp_length, 0xfff8, raw_rx_limit << 3);
    try update(registers, mdp_control, (1 << 15) | (1 << 19), 1 << 15);
    for (0..20) |index| {
        try waitWtbl(registers, clock);
        const before = try registers.read(wtbl_update);
        if (before == 0xffffffff) return error.DeviceRemoved;
        // Source RMW preserves other command/status bits and requests ADM clear.
        try registers.write(wtbl_update, (before & ~@as(u32, 0x3ff)) | @as(u32, @intCast(index)) | (1 << 12));
        try waitWtbl(registers, clock);
    }
    for (0..2) |band| {
        const base: u32 = if (band == 0) 0x820e0000 else 0x820f0000;
        try update(registers, base + 0x40f4, 0x3f | (1 << 17) | (1 << 18), 0x3f | (1 << 17) | (1 << 18));
        try update(registers, base + 0x53c4, 1 << 30, 1 << 30);
        try update(registers, base + 0x5380, 1 << 30, 1 << 30);
        try update(registers, base + 0xd004, (1 << 8) | (1 << 9), (1 << 8) | (1 << 9));
        try update(registers, base + 0x7000, 0xfff8 | (1 << 23), raw_rx_limit << 3);
        try update(registers, base + 0x9008, (3 << 30) | (3 << 24), 3 << 24);
    }
}
