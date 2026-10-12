//! Polling PL011 for the pinned QEMU ARM64 virt-10.1 prototype.
pub const base: usize = 0x09000000;
var active_base: usize = base;

fn register(offset: usize) *volatile u32 {
    return @ptrFromInt(active_base + offset);
}

pub fn configure(address: usize, clock_hz: u32, baud_rate: u32) bool {
    if (address == 0 or address % 4 != 0 or clock_hz == 0 or baud_rate == 0) return false;
    const divisor = (@as(u64, clock_hz) * 4 + baud_rate / 2) / baud_rate;
    if (divisor < 64 or divisor > 0x3fffff) return false;
    active_base = address;
    register(0x030).* = 0;
    register(0x038).* = 0;
    register(0x044).* = 0x7ff;
    register(0x024).* = @intCast(divisor / 64);
    register(0x028).* = @intCast(divisor % 64);
    register(0x02c).* = (3 << 5) | (1 << 4);
    register(0x030).* = (1 << 0) | (1 << 8) | (1 << 9);
    return true;
}

pub fn init() void {
    // Disable the UART and its interrupts; configure 8N1 and 115200 baud
    // from this platform's 24 MHz UART clock, then enable RX and TX.
    register(0x030).* = 0;
    register(0x038).* = 0;
    register(0x044).* = 0x7ff;
    register(0x024).* = 13;
    register(0x028).* = 1;
    register(0x02c).* = (3 << 5) | (1 << 4);
    register(0x030).* = (1 << 0) | (1 << 8) | (1 << 9);
}

fn put(byte: u8) void {
    while ((register(0x018).* & (1 << 5)) != 0) {}
    register(0x000).* = byte;
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
