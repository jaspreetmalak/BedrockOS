// SPDX-License-Identifier: ISC
// Copyright (C) 2020, 2023 MediaTek Inc.
// Copyright (C) 2026 Bedrock contributors
// Derived from Linux v6.18 mt7921/regs.h and mt792x_regs.h. See LICENSE.
pub const remap_l1: u32 = 0xfe24c;
pub const remap_window: u32 = 0x40000;
pub const wfsys_reset: u32 = 0x18000140;
pub const reset_bit: u32 = 1;
pub const reset_done: u32 = 1 << 4;
pub const top_lpc: u32 = 0x18060010;
pub const top_fw_own: u32 = 1;
pub const top_driver_own: u32 = 2;
pub const conn_lpc: u32 = 0x7c060010;
pub const conn_own_sync: u32 = 4;
pub const conn_misc: u32 = 0x7c0600f0;
pub const firmware_ready_mask: u32 = 3;
pub const chip_id: u32 = 0x70010200;
pub const chip_revision: u32 = 0x70010204;
pub const wfdma_reset: u32 = 0xd4100;
pub const mcu_command: u32 = 0xd41f0;
pub const sw_interrupt_enable: u32 = 0xd41f4;
pub const interrupt_status: u32 = 0xd4200;
pub const interrupt_enable: u32 = 0xd4204;
pub const global_config: u32 = 0xd4208;
pub const tx_reset_pointer: u32 = 0xd420c;
pub const global_config_ext: u32 = 0xd42b0;
pub const delayed_interrupt: u32 = 0xd42f0;
pub const tx_ring_base: u32 = 0xd4300;
pub const event_ring_base: u32 = 0xd4500;
pub const data_ring_base: u32 = 0xd4520;
pub const mcu_second_event_base: u32 = 0xd4540;
pub const tx_ext_base: u32 = 0xd4600;
pub const rx_ext_base: u32 = 0xd4680;
pub const scheduler_control: u32 = 0x7c026004;
pub const scheduler_bypass: u32 = 1 << 28;
pub const pcie_interrupt_enable: u32 = 0x10188;
pub const pcie_power: u32 = 0x10194;
pub const dummy_config: u32 = 0x54000120;
pub const tx_enable: u32 = 1;
pub const tx_busy: u32 = 2;
pub const rx_enable: u32 = 4;
pub const rx_busy: u32 = 8;
pub const reset_mask: u32 = (1 << 4) | (1 << 5);
pub const dma_disable_mask: u32 = tx_enable | rx_enable | (1 << 15) | (1 << 28) | (1 << 27) | (1 << 21);
pub const dma_configuration: u32 = (1 << 6) | (1 << 12) | (1 << 30) | (1 << 28) | (3 << 4) | (1 << 11) | (1 << 13) | (1 << 15) | (1 << 21);
pub const tx_mcu_queue: u8 = 17;
pub const tx_download_queue: u8 = 16;
pub const rx_mcu_queue: u8 = 0;
pub fn txRing(queue: u8) !u32 {
    if (queue > 17) return error.InvalidRing;
    return tx_ring_base + @as(u32, queue) * 16;
}
