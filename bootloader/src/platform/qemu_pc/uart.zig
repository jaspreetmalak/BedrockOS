//! Polled 16550 COM1 on the pinned QEMU PC platform.
pub const base: u16 = 0x3f8;
extern fn bedrock_pc_in8(port: u16) callconv(.c) u8;
extern fn bedrock_pc_out8(port: u16, value: u8) callconv(.c) void;

pub fn init() void {
    bedrock_pc_out8(base + 1, 0);
    bedrock_pc_out8(base + 3, 0x80);
    bedrock_pc_out8(base + 0, 1);
    bedrock_pc_out8(base + 1, 0);
    bedrock_pc_out8(base + 3, 3);
    bedrock_pc_out8(base + 2, 0xc7);
    bedrock_pc_out8(base + 4, 0x0b);
}
pub fn write(bytes: []const u8) void {
    for (bytes) |byte| {
        while (bedrock_pc_in8(base + 5) & 0x20 == 0) {}
        bedrock_pc_out8(base, byte);
    }
}
pub fn hex(value: u64) void {
    const digits = "0123456789abcdef";
    var bytes: [18]u8 = undefined;
    bytes[0] = '0';
    bytes[1] = 'x';
    for (0..16) |index| {
        const shift: u6 = @intCast((15 - index) * 4);
        bytes[index + 2] = digits[@intCast((value >> shift) & 0xf)];
    }
    write(&bytes);
}
