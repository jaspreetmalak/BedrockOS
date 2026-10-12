//! Descriptor-selected PL011; there is no assumed platform MMIO address.
const protocol = @import("boot_protocol");
var base: usize = 0;
fn register(offset: usize) *volatile u32 {
    return @ptrFromInt(base + offset);
}
pub fn configure(console: protocol.Console) !void {
    try console.validate();
    if (console.kind != @backingInt(protocol.ConsoleKind.pl011) or console.clock_hz == 0)
        return error.UnsupportedConsole;
    const divisor = (@as(u64, console.clock_hz) * 4 + console.baud_rate / 2) / console.baud_rate;
    if (divisor < 64 or divisor > 0x3fffff) return error.UnsupportedBaudRate;
    base = @intCast(console.base);
    register(0x30).* = 0;
    register(0x38).* = 0;
    register(0x44).* = 0x7ff;
    register(0x24).* = @intCast(divisor / 64);
    register(0x28).* = @intCast(divisor % 64);
    register(0x2c).* = 0x70;
    register(0x30).* = 0x301;
}
pub fn write(bytes: []const u8) void {
    if (base == 0) return;
    for (bytes) |byte| {
        if (byte == '\n') put('\r');
        put(byte);
    }
}
fn put(byte: u8) void {
    while ((register(0x18).* & (1 << 5)) != 0) {}
    register(0).* = byte;
}
