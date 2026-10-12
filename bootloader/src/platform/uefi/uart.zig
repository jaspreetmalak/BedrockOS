//! COM1 is used only by the explicit QEMU smoke profile, never guessed on PCs.
const base: u16 = 0x3f8;
extern fn bedrock_pc_in8(port: u16) callconv(.c) u8;
extern fn bedrock_pc_out8(port: u16, value: u8) callconv(.c) void;
pub fn init() void {
    bedrock_pc_out8(base + 1, 0);
    bedrock_pc_out8(base + 3, 0x80);
    bedrock_pc_out8(base, 1);
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
