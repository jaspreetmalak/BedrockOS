//! Polling console for the pinned QEMU virt-10.1 platform.
const protocol = @import("boot_protocol");
var base: usize = 0x09000000;

fn register(offset: usize) *volatile u32 {
    return @ptrFromInt(base + offset);
}

pub fn init() void {
    // This named platform's reset console is available before DTB validation.
    configure(.{ .kind = @backingInt(protocol.ConsoleKind.pl011), .base = 0x09000000, .register_stride = 4, .clock_hz = 24000000, .baud_rate = 115200 }) catch unreachable;
}

pub fn configure(console: protocol.Console) error{InvalidConsole}!void {
    try console.validate();
    if (console.kind != @backingInt(protocol.ConsoleKind.pl011) or console.clock_hz == 0)
        return error.InvalidConsole;
    const divisor64 = (@as(u64, console.clock_hz) * 4 + console.baud_rate / 2) / console.baud_rate;
    base = @intCast(console.base);
    register(0x30).* = 0;
    register(0x38).* = 0;
    register(0x44).* = 0x7ff;
    register(0x24).* = @intCast(divisor64 / 64);
    register(0x28).* = @intCast(divisor64 % 64);
    register(0x2c).* = 0x70;
    register(0x30).* = 0x301;
}

pub fn write(bytes: []const u8) void {
    for (bytes) |byte| {
        if (byte == '\n') put('\r');
        put(byte);
    }
}

fn put(byte: u8) void {
    while (register(0x18).* & (1 << 5) != 0) {}
    register(0).* = byte;
}

pub fn hex(value: u64) void {
    write("0x");
    var shift: u6 = 60;
    while (true) {
        const digit: usize = @intCast((value >> shift) & 0xf);
        put("0123456789abcdef"[digit]);
        if (shift == 0) break;
        shift -= 4;
    }
}
