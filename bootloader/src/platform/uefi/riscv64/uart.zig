//! Descriptor-selected byte-wide NS16550 MMIO console.
const protocol = @import("boot_protocol");
var base: usize = 0;
var stride: usize = 1;
extern fn bedrock_uefi_io_fence() callconv(.c) void;
fn register(index: usize) *volatile u8 {
    return @ptrFromInt(base + index * stride);
}
pub fn configure(console: protocol.Console) !void {
    try console.validate();
    if (console.kind != @backingInt(protocol.ConsoleKind.ns16550_mmio) or console.clock_hz == 0)
        return error.UnsupportedConsole;
    const divisor = (@as(u64, console.clock_hz) + @as(u64, console.baud_rate) * 8) / (@as(u64, console.baud_rate) * 16);
    if (divisor == 0 or divisor > 0xffff) return error.UnsupportedBaudRate;
    base = @intCast(console.base);
    stride = console.register_stride;
    writeRegister(1, 0);
    writeRegister(3, 0x80);
    writeRegister(0, @truncate(divisor));
    writeRegister(1, @truncate(divisor >> 8));
    writeRegister(3, 3);
    writeRegister(2, 7);
    writeRegister(4, 3);
}
fn writeRegister(index: usize, value: u8) void {
    register(index).* = value;
    bedrock_uefi_io_fence();
}
fn readRegister(index: usize) u8 {
    const value = register(index).*;
    bedrock_uefi_io_fence();
    return value;
}
pub fn write(bytes: []const u8) void {
    if (base == 0) return;
    for (bytes) |byte| {
        if (byte == '\n') put('\r');
        put(byte);
    }
}
fn put(byte: u8) void {
    while ((readRegister(5) & 0x20) == 0) {}
    writeRegister(0, byte);
}
