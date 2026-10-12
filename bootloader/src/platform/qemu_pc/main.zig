//! Bedrock reset ROM for the named QEMU pc-i440fx-10.1 x86-64 profile.
const std = @import("std");
const protocol = @import("boot_protocol");
const options = @import("boot_options");
const uart = @import("uart.zig");
const kernel_image = @embedFile("kernel_image");

const kernel_base = 0x200000;
const kernel_capacity = 0x1f0000;
extern fn bedrock_bootloader_halt() callconv(.c) noreturn;
extern fn bedrock_bootloader_exit(status: u64) callconv(.c) noreturn;
extern fn bedrock_bootloader_jump(entry: u64, info: *const protocol.BootInfo, bytes: usize) callconv(.c) noreturn;
extern fn bedrock_pc_in8(port: u16) callconv(.c) u8;
extern fn bedrock_pc_out16(port: u16, value: u16) callconv(.c) void;
var boot_info: protocol.BootInfo = undefined;
var bss_sentinel: u64 = 0;
var data_sentinel: u64 = 0xbedd0017;

pub const panic = std.debug.FullPanic(panicHandler);
fn stop(status: u64) noreturn {
    if (options.smoke_test) bedrock_bootloader_exit(status);
    bedrock_bootloader_halt();
}
fn fail(message: []const u8) noreturn {
    uart.write("[fault] bootloader: ");
    uart.write(message);
    uart.write("\n");
    stop(1);
}
fn panicHandler(message: []const u8, _: ?usize) noreturn {
    uart.write("[panic] bootloader: ");
    uart.write(message);
    uart.write("\n");
    stop(1);
}

// QEMU's x86 fw_cfg uses a native little-endian 16-bit selector at port
// 0x510 and a byte stream at 0x511. Directory fields are big endian, while
// the packed etc/e820 records and FW_CFG_RAM_SIZE item are little endian.
fn fwSelect(selector: u16) void {
    bedrock_pc_out16(0x510, selector);
}
fn fwRead(bytes: []u8) void {
    for (bytes) |*byte| byte.* = bedrock_pc_in8(0x511);
}
fn little64(bytes: *const [8]u8) u64 {
    var value: u64 = 0;
    for (bytes, 0..) |byte, index| value |= @as(u64, byte) << @as(u6, @intCast(index * 8));
    return value;
}
fn big32(bytes: *const [4]u8) u32 {
    return (@as(u32, bytes[0]) << 24) | (@as(u32, bytes[1]) << 16) |
        (@as(u32, bytes[2]) << 8) | bytes[3];
}
fn discoverMemory(map: *protocol.MemoryMap) protocol.PhysicalRange {
    var signature: [4]u8 = undefined;
    fwSelect(0);
    fwRead(&signature);
    if (!std.mem.eql(u8, &signature, "QEMU")) fail("fw_cfg signature unavailable");
    var ram_bytes: [8]u8 = undefined;
    fwSelect(3);
    fwRead(&ram_bytes);
    if (little64(&ram_bytes) < 0x400000) fail("insufficient RAM for this kernel profile");
    uart.write("[bootloader] RAM discovered length=");
    uart.hex(little64(&ram_bytes));
    uart.write("\n");

    fwSelect(0x19);
    var count_bytes: [4]u8 = undefined;
    fwRead(&count_bytes);
    const file_count = big32(&count_bytes);
    if (file_count > 1024) fail("fw_cfg directory exceeds bounded reader");
    var selector: u16 = 0;
    var size: u32 = 0;
    for (0..file_count) |_| {
        var record: [64]u8 = undefined;
        fwRead(&record);
        if (std.mem.eql(u8, record[8..17], "etc/e820\x00")) {
            if (selector != 0) fail("duplicate fw_cfg e820 item");
            size = big32(record[0..4]);
            selector = (@as(u16, record[4]) << 8) | record[5];
        }
    }
    if (selector < 0x20 or size == 0 or size % 20 != 0 or size / 20 > protocol.max_memory_regions)
        fail("fw_cfg e820 item invalid or too large");
    fwSelect(selector);
    var boot_ram: ?protocol.PhysicalRange = null;
    for (0..size / 20) |_| {
        var record: [20]u8 = undefined;
        fwRead(&record);
        const range: protocol.PhysicalRange = .{ .base = little64(record[0..8]), .length = little64(record[8..16]) };
        const kind = @as(u32, record[16]) | (@as(u32, record[17]) << 8) |
            (@as(u32, record[18]) << 16) | (@as(u32, record[19]) << 24);
        const end = range.endExclusive() catch fail("e820 range overflow");
        if (range.length == 0) continue;
        if (kind == 1) {
            map.addRam(range) catch fail("invalid e820 RAM bank");
            // The legacy prefix describes the boot RAM bank, not all memory.
            if (range.base == 0 and end >= 0x400000) boot_ram = range;
        } else {
            // A conservative map cannot make an occupied arena safe to use.
            // Reject the conflict before copying any kernel bytes into RAM.
            if (range.base < 0x400000 and end > 0x100000)
                fail("firmware reservation overlaps the boot arenas");
            map.addReservation(range, .reserved) catch fail("too many e820 reservations");
        }
    }
    // PC low memory includes the IVT/BDA, VGA window and firmware aliases.
    // Keep it reserved even if QEMU's raw RAM descriptor spans those holes.
    map.addReservation(.{ .base = 0, .length = 0x100000 }, .reserved) catch fail("memory map full");
    map.addReservation(.{ .base = 0x100000, .length = 0x100000 }, .loader_reclaimable) catch fail("memory map full");
    map.addReservation(.{ .base = 0x200000, .length = 0x200000 }, .kernel) catch fail("memory map full");
    map.addReservation(.{ .base = 0xffe00000, .length = 0x200000 }, .reserved) catch fail("memory map full");
    return boot_ram orelse fail("boot arenas are not inside a discovered RAM bank");
}
export fn bedrock_bootloader_main() callconv(.c) noreturn {
    uart.init();
    uart.write("[bootloader] x86_64 firmware entry\n");
    const bss: *volatile u64 = &bss_sentinel;
    const data: *volatile u64 = &data_sentinel;
    if (bss.* != 0 or data.* != 0xbedd0017) fail("RAM initialization failed");
    bss.* = 0xbed;
    var memory: protocol.MemoryMap = .{};
    const boot_ram = discoverMemory(&memory);
    if (kernel_image.len == 0 or kernel_image.len > kernel_capacity)
        fail("kernel image exceeds its reservation");
    const destination: [*]volatile u8 = @ptrFromInt(kernel_base);
    for (kernel_image, 0..) |byte, offset| destination[offset] = byte;
    for (kernel_image, 0..) |byte, offset| {
        if (destination[offset] != byte) fail("kernel copy verification failed");
    }
    uart.write("[bootloader] kernel image copied\n");

    var header = protocol.Header.init(.x86_64);
    header.header_size = @sizeOf(protocol.BootInfo);
    boot_info = .{
        .header = header,
        .uart_base = uart.base,
        .dtb = .{ .base = 0, .length = 0 },
        .kernel_image = .{ .base = kernel_base, .length = kernel_image.len },
        .ram = boot_ram,
        .loader_reserved = .{ .base = 0, .length = 0x200000 },
        .kernel_reserved = .{ .base = kernel_base, .length = 0x200000 },
        .flags = if (options.smoke_test) protocol.flag_smoke_exit else 0,
        .console = .{
            .kind = @backingInt(protocol.ConsoleKind.ns16550_io),
            .base = uart.base,
            .register_stride = 1,
            .clock_hz = 1843200,
            .baud_rate = 115200,
        },
        .entry_state = @backingInt(protocol.EntryState.x86_64_long_mode),
    };
    memory.finalize(&boot_info) catch fail("cannot normalize discovered memory map");
    boot_info.validate(@sizeOf(protocol.BootInfo), .x86_64) catch fail("invalid handoff");
    uart.write("[bootloader] handoff ready\n");
    bedrock_bootloader_jump(kernel_base, &boot_info, @sizeOf(protocol.BootInfo));
}
export fn bedrock_bootloader_fault() callconv(.c) noreturn {
    uart.init();
    fail("unexpected CPU exception");
}
