// SPDX-License-Identifier: ISC
// Copyright (C) 2020 MediaTek Inc.
// Copyright (C) 2026 Bedrock contributors
// Derived from Linux v6.18 mt7921/pci.c and mt7921/mt7921.h. See LICENSE.
const regs = @import("regs.zig");
pub const Mmio = struct {
    context: *anyopaque,
    span: u32,
    /// Must serialize ALL access to this device, including its IRQ handler.
    begin: *const fn (*anyopaque) anyerror!void,
    end: *const fn (*anyopaque) void,
    read32: *const fn (*anyopaque, u32) anyerror!u32,
    write32: *const fn (*anyopaque, u32, u32) anyerror!void,
    fence: *const fn (*anyopaque) void,
};
const Mapping = struct { physical: u32, bar: u32, size: u32 };
const fixed = [_]Mapping{
    .{ .physical = 0x820d0000, .bar = 0x30000, .size = 0x10000 },
    .{ .physical = 0x820ed000, .bar = 0x24800, .size = 0x00800 },
    .{ .physical = 0x820e4000, .bar = 0x21000, .size = 0x00400 },
    .{ .physical = 0x820e7000, .bar = 0x21e00, .size = 0x00200 },
    .{ .physical = 0x820eb000, .bar = 0x24200, .size = 0x00400 },
    .{ .physical = 0x820e2000, .bar = 0x20800, .size = 0x00400 },
    .{ .physical = 0x820e3000, .bar = 0x20c00, .size = 0x00400 },
    .{ .physical = 0x820e5000, .bar = 0x21400, .size = 0x00800 },
    .{ .physical = 0x00400000, .bar = 0x80000, .size = 0x10000 },
    .{ .physical = 0x00410000, .bar = 0x90000, .size = 0x10000 },
    .{ .physical = 0x40000000, .bar = 0x70000, .size = 0x10000 },
    .{ .physical = 0x54000000, .bar = 0x02000, .size = 0x01000 },
    .{ .physical = 0x55000000, .bar = 0x03000, .size = 0x01000 },
    .{ .physical = 0x58000000, .bar = 0x06000, .size = 0x01000 },
    .{ .physical = 0x59000000, .bar = 0x07000, .size = 0x01000 },
    .{ .physical = 0x7c000000, .bar = 0xf0000, .size = 0x10000 },
    .{ .physical = 0x7c020000, .bar = 0xd0000, .size = 0x10000 },
    .{ .physical = 0x7c060000, .bar = 0xe0000, .size = 0x10000 },
    .{ .physical = 0x80020000, .bar = 0xb0000, .size = 0x10000 },
    .{ .physical = 0x81020000, .bar = 0xc0000, .size = 0x10000 },
    .{ .physical = 0x820c0000, .bar = 0x08000, .size = 0x04000 },
    .{ .physical = 0x820c8000, .bar = 0x0c000, .size = 0x02000 },
    .{ .physical = 0x820cc000, .bar = 0x0e000, .size = 0x01000 },
    .{ .physical = 0x820cd000, .bar = 0x0f000, .size = 0x01000 },
    .{ .physical = 0x74030000, .bar = 0x10000, .size = 0x10000 },
    .{ .physical = 0x820ce000, .bar = 0x21c00, .size = 0x00200 },
    .{ .physical = 0x820cf000, .bar = 0x22000, .size = 0x01000 },
    .{ .physical = 0x820e0000, .bar = 0x20000, .size = 0x00400 },
    .{ .physical = 0x820e1000, .bar = 0x20400, .size = 0x00200 },
    .{ .physical = 0x820e9000, .bar = 0x23400, .size = 0x00200 },
    .{ .physical = 0x820ea000, .bar = 0x24000, .size = 0x00200 },
    .{ .physical = 0x820ec000, .bar = 0x24600, .size = 0x00200 },
    .{ .physical = 0x820f0000, .bar = 0xa0000, .size = 0x00400 },
    .{ .physical = 0x820f1000, .bar = 0xa0600, .size = 0x00200 },
    .{ .physical = 0x820f2000, .bar = 0xa0800, .size = 0x00400 },
    .{ .physical = 0x820f3000, .bar = 0xa0c00, .size = 0x00400 },
    .{ .physical = 0x820f4000, .bar = 0xa1000, .size = 0x00400 },
    .{ .physical = 0x820f5000, .bar = 0xa1400, .size = 0x00800 },
    .{ .physical = 0x820f7000, .bar = 0xa1e00, .size = 0x00200 },
    .{ .physical = 0x820f9000, .bar = 0xa3400, .size = 0x00200 },
    .{ .physical = 0x820fa000, .bar = 0xa4000, .size = 0x00200 },
    .{ .physical = 0x820fb000, .bar = 0xa4200, .size = 0x00400 },
    .{ .physical = 0x820fc000, .bar = 0xa4600, .size = 0x00200 },
    .{ .physical = 0x820fd000, .bar = 0xa4800, .size = 0x00800 },
};
/// Pure fixed lookup. Rejects the upstream one-past-window boundary.
pub fn fixedOffset(address: u32) !?u32 {
    if (address & 3 != 0) return error.UnalignedRegister;
    if (address < 0x100000) return address;
    for (fixed) |m| if (address >= m.physical and address - m.physical < m.size) {
        if (m.size - (address - m.physical) < 4) return error.UnalignedRegister;
        return m.bar + (address - m.physical);
    };
    return null;
}
fn dynamicAllowed(address: u32) bool {
    return (address >= 0x18000000 and address < 0x18c00000) or
        (address >= 0x70000000 and address < 0x78000000) or
        (address >= 0x7c000000 and address < 0x7c400000);
}
pub const Registers = struct {
    provider: Mmio,
    busy: bool = false,
    pub fn init(provider: Mmio) !Registers {
        if (provider.span < 0x100000) return error.InvalidBarSize;
        return .{ .provider = provider };
    }
    fn start(self: *Registers) !void {
        if (self.busy) return error.RegisterBusy;
        self.busy = true;
        errdefer self.busy = false;
        try self.provider.begin(self.provider.context);
    }
    fn finish(self: *Registers) void {
        self.provider.end(self.provider.context);
        self.busy = false;
    }
    fn offset(self: *Registers, address: u32) !u32 {
        if (try fixedOffset(address)) |mapped| return mapped;
        if (!dynamicAllowed(address)) return error.UnsupportedRegister;
        const p = self.provider;
        const previous = try p.read32(p.context, regs.remap_l1);
        try p.write32(p.context, regs.remap_l1, (previous & 0xffff0000) | (address >> 16));
        p.fence(p.context);
        const observed = try p.read32(p.context, regs.remap_l1);
        if (observed & 0xffff != address >> 16) return error.RemapFailed;
        return regs.remap_window + (address & 0xffff);
    }
    pub fn read(self: *Registers, address: u32) !u32 {
        try self.start();
        defer self.finish();
        const o = try self.offset(address);
        return self.provider.read32(self.provider.context, o);
    }
    pub fn write(self: *Registers, address: u32, value: u32) !void {
        try self.start();
        defer self.finish();
        const o = try self.offset(address);
        try self.provider.write32(self.provider.context, o, value);
        self.provider.fence(self.provider.context);
    }
    /// Mask is replaced, not ORed. One lock covers remap + read/modify/write.
    pub fn update(self: *Registers, address: u32, mask: u32, value: u32) !u32 {
        if (value & ~mask != 0) return error.InvalidRegisterValue;
        try self.start();
        defer self.finish();
        const o = try self.offset(address);
        const current = try self.provider.read32(self.provider.context, o);
        const result = (current & ~mask) | value;
        try self.provider.write32(self.provider.context, o, result);
        self.provider.fence(self.provider.context);
        return result;
    }
};
