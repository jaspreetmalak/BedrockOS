//! Kernel-owned polling NS16550A; it does not rely on loader configuration.
pub const base: usize = 0x10000000;
var active_base: usize = base;
var stride: usize = 1;
extern fn bedrock_riscv_io_fence() callconv(.c) void;

fn register(offset: usize) *volatile u8 {
    return @ptrFromInt(active_base + offset * stride);
}

pub fn configure(address: usize, register_stride: u32, clock_hz: u32, baud_rate: u32) bool {
    if (address == 0 or baud_rate == 0 or clock_hz == 0 or
        (register_stride != 1 and register_stride != 2 and register_stride != 4 and register_stride != 8)) return false;
    const divisor = (@as(u64, clock_hz) + @as(u64, baud_rate) * 8) / (@as(u64, baud_rate) * 16);
    if (divisor == 0 or divisor > 0xffff) return false;
    active_base = address;
    stride = register_stride;
    writeRegister(1, 0);
    writeRegister(3, 0x80);
    writeRegister(0, @truncate(divisor));
    writeRegister(1, @truncate(divisor >> 8));
    writeRegister(3, 0x03);
    writeRegister(2, 0x07);
    writeRegister(4, 0x03);
    return true;
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
    while ((readRegister(5) & (1 << 6)) == 0) {}
    writeRegister(3, 0x03);
    writeRegister(1, 0x00);
    writeRegister(3, 0x80);
    writeRegister(0, 0x02);
    writeRegister(1, 0x00);
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
