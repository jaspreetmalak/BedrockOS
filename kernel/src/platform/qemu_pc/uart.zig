//! Kernel console selected from the validated boot handoff.
const protocol = @import("boot_protocol");
const framebuffer = @import("framebuffer");
pub const base: u16 = 0x3f8;
var serial_base: u16 = base;
var kind: u32 = @backingInt(protocol.ConsoleKind.none);
extern fn bedrock_pc_in8(port: u16) callconv(.c) u8;
extern fn bedrock_pc_out8(port: u16, value: u8) callconv(.c) void;
pub fn init() void {
    if (kind != @backingInt(protocol.ConsoleKind.ns16550_io)) return;
    bedrock_pc_out8(serial_base + 1, 0);
    bedrock_pc_out8(serial_base + 3, 0x80);
    bedrock_pc_out8(serial_base, 1);
    bedrock_pc_out8(serial_base + 1, 0);
    bedrock_pc_out8(serial_base + 3, 3);
    bedrock_pc_out8(serial_base + 2, 0xc7);
    bedrock_pc_out8(serial_base + 4, 0x0b);
}
pub fn configure(info: *const protocol.BootInfo) bool {
    kind = info.console.kind;
    if (kind == @backingInt(protocol.ConsoleKind.ns16550_io)) {
        // This backend currently supports the standard PC 115200-baud clock.
        if (info.console.register_stride != 1 or info.console.baud_rate != 115200 or
            (info.console.clock_hz != 0 and info.console.clock_hz != 1843200)) return false;
        serial_base = @intCast(info.console.base);
        init();
        return true;
    }
    if (kind == @backingInt(protocol.ConsoleKind.framebuffer)) {
        framebuffer.configure(info.framebuffer);
        return true;
    }
    return false;
}
pub fn write(bytes: []const u8) void {
    if (kind == @backingInt(protocol.ConsoleKind.framebuffer)) {
        framebuffer.write(bytes);
        return;
    }
    if (kind != @backingInt(protocol.ConsoleKind.ns16550_io)) return;
    for (bytes) |byte| {
        while (bedrock_pc_in8(serial_base + 5) & 0x20 == 0) {}
        bedrock_pc_out8(serial_base, byte);
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
pub const writeHex = hex;
/// Named PC profile trace sink after desktop scanout takes over the GOP.
pub fn desktopTrace() void {
    kind = @backingInt(protocol.ConsoleKind.ns16550_io);
    serial_base = base;
    init();
}
