//! Polling byte-register NS16550A for the named QEMU RISC-V virt platform.
const protocol = @import("boot_protocol");
pub var base: usize = 0x10000000;
var stride: usize = 1;
extern fn bedrock_riscv_io_fence() callconv(.c) void;

fn register(offset: usize) *volatile u8 {
    return @ptrFromInt(base + offset * stride);
}

fn writeRegister(offset: usize, value: u8) void {
    register(offset).* = value;
    bedrock_riscv_io_fence();
}

fn readRegister(offset: usize) u8 {
    const value = register(offset).*;
    bedrock_riscv_io_fence();
    return value;
}

pub fn init() void {
    // This named platform's reset console is available before DTB validation.
    configure(.{ .kind = @backingInt(protocol.ConsoleKind.ns16550_mmio), .base = 0x10000000, .register_stride = 1, .clock_hz = 3686400, .baud_rate = 115200 }) catch unreachable;
}

pub fn configure(console: protocol.Console) error{InvalidConsole}!void {
    try console.validate();
    if (console.kind != @backingInt(protocol.ConsoleKind.ns16550_mmio) or console.clock_hz == 0)
        return error.InvalidConsole;
    const divisor = (@as(u64, console.clock_hz) + @as(u64, console.baud_rate) * 8) /
        (@as(u64, console.baud_rate) * 16);
    if (divisor == 0 or divisor > 65535) return error.InvalidConsole;
    base = @intCast(console.base);
    stride = console.register_stride;
    while ((readRegister(5) & (1 << 6)) == 0) {}
    writeRegister(3, 0x03);
    writeRegister(1, 0x00);
    writeRegister(3, 0x80);
    writeRegister(0, @truncate(divisor));
    writeRegister(1, @truncate(divisor >> 8));
    writeRegister(3, 0x03);
    writeRegister(2, 0x07);
    writeRegister(4, 0x03);
}

fn put(byte: u8) void {
    while ((readRegister(5) & (1 << 5)) == 0) {}
    writeRegister(0, byte);
}

pub fn write(bytes: []const u8) void {
    for (bytes) |byte| {
        if (byte == '\n') put('\r');
        put(byte);
    }
}

pub fn writeHex(value: u64) void {
    const digits = "0123456789abcdef";
    write("0x");
    for (0..16) |index| {
        const shift: u6 = @intCast((15 - index) * 4);
        put(digits[@as(usize, @intCast((value >> shift) & 0xf))]);
    }
}
