//! Bedrock-owned flash firmware for QEMU ARM64 virt-10.1.
const std = @import("std");
const protocol = @import("boot_protocol");
const options = @import("boot_options");
const device_tree = @import("device_tree");
const uart = @import("uart.zig");
const kernel_image = @embedFile("kernel_image");

const ram_base = 0x40000000;
const kernel_base = 0x40200000;
const kernel_capacity = 0x1f0000; // Leave the kernel's 64 KiB stack untouched.
const loader_range: device_tree.Range = .{ .base = ram_base, .length = 0x200000 };
const loader_used: device_tree.Range = .{ .base = 0x40100000, .length = 0x100000 };
const kernel_range: device_tree.Range = .{ .base = kernel_base, .length = 0x200000 };

extern fn bedrock_bootloader_current_el() callconv(.c) u64;
extern fn bedrock_bootloader_sctlr() callconv(.c) u64;
extern fn bedrock_bootloader_halt() callconv(.c) noreturn;
extern fn bedrock_bootloader_exit(status: u64) callconv(.c) noreturn;
extern fn bedrock_bootloader_jump(entry: u64, info: *const protocol.BootInfo, bytes: usize) callconv(.c) noreturn;

var boot_info: protocol.BootInfo = undefined;
var bss_sentinel: u64 = 0;

pub const panic = std.debug.FullPanic(panicHandler);

fn panicHandler(message: []const u8, _: ?usize) noreturn {
    uart.write("[panic] bootloader: ");
    uart.write(message);
    uart.write("\n");
    stop(1);
}

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

fn readBe32(address: usize) u32 {
    const bytes: [*]const volatile u8 = @ptrFromInt(address);
    return (@as(u32, bytes[0]) << 24) | (@as(u32, bytes[1]) << 16) |
        (@as(u32, bytes[2]) << 8) | @as(u32, bytes[3]);
}

fn wireRange(range: device_tree.Range) protocol.PhysicalRange {
    return .{ .base = range.base, .length = range.length };
}

export fn bedrock_bootloader_main() callconv(.c) noreturn {
    uart.init();
    uart.write("[bootloader] ARM64 firmware entry\n");
    if (bedrock_bootloader_current_el() != 1) fail("EL1 required");
    if (bedrock_bootloader_sctlr() & ((1 << 0) | (1 << 2) | (1 << 12)) != 0)
        fail("MMU and caches must be disabled at reset");
    // Volatile access prevents the compiler from assuming the initializer held.
    const sentinel: *volatile u64 = &bss_sentinel;
    if (sentinel.* != 0) fail("BSS was not cleared");
    sentinel.* = 0xbed;

    // QEMU's bare-metal DTB is at the RAM base, not in reset register x0.
    if (readBe32(ram_base) != 0xd00dfeed) fail("DTB magic invalid");
    const dtb_size = readBe32(ram_base + 4);
    if (dtb_size < 40 or dtb_size > 0x100000) fail("DTB overlaps loader memory");
    const blob: [*]const u8 = @ptrFromInt(ram_base);
    const discovered = device_tree.parse(blob[0..dtb_size]) catch |err| {
        uart.write(@errorName(err));
        uart.write("\n");
        fail("DTB discovery failed");
    };
    // The linked loader/kernel arenas remain constraints of this named port.
    const boot_bank = discovered.containingBank(.{ .base = ram_base, .length = 0x400000 }) orelse
        fail("RAM does not contain the linked boot arenas");
    if (discovered.conflicts(loader_used) or discovered.conflicts(kernel_range))
        fail("firmware reservations conflict with linked boot arenas");
    const dtb_range: device_tree.Range = .{ .base = ram_base, .length = dtb_size };
    if (!loader_range.contains(dtb_range) or dtb_range.overlaps(loader_used) or dtb_range.overlaps(kernel_range))
        fail("DTB conflicts with linked boot arenas");
    if (discovered.console.kind != .pl011) fail("this ARM platform requires a PL011 console");
    for (discovered.memoryBanks()) |bank| {
        if (bank.overlaps(discovered.console.range)) fail("console registers overlap RAM");
    }
    const console: protocol.Console = .{
        .kind = @backingInt(protocol.ConsoleKind.pl011),
        .base = discovered.console.range.base,
        .register_stride = discovered.console.register_stride,
        .clock_hz = discovered.console.clock_hz,
        .baud_rate = discovered.console.baud_rate,
    };
    uart.configure(console) catch fail("unsupported discovered UART configuration");
    uart.write("[bootloader] RAM discovered length=");
    uart.hex(boot_bank.length);
    uart.write("\n");
    if (kernel_image.len == 0 or kernel_image.len > kernel_capacity)
        fail("kernel image does not fit its reserved memory");

    const destination: [*]volatile u8 = @ptrFromInt(kernel_base);
    for (kernel_image, 0..) |byte, offset| destination[offset] = byte;
    for (kernel_image, 0..) |byte, offset| {
        if (destination[offset] != byte) fail("kernel copy verification failed");
    }
    uart.write("[bootloader] kernel image copied\n");

    var header = protocol.Header.init(.aarch64);
    header.header_size = @sizeOf(protocol.BootInfo);
    boot_info = .{
        .header = header,
        .uart_base = console.base,
        .dtb = wireRange(dtb_range),
        .kernel_image = .{ .base = kernel_base, .length = kernel_image.len },
        .ram = wireRange(boot_bank),
        .loader_reserved = wireRange(loader_range),
        .kernel_reserved = wireRange(kernel_range),
        .flags = if (options.smoke_test) protocol.flag_smoke_exit else 0,
        .console = console,
        .boot_environment = @backingInt(protocol.BootEnvironment.reset_firmware),
        .entry_state = @backingInt(protocol.EntryState.aarch64_el1),
    };
    var map: protocol.MemoryMap = .{};
    for (discovered.memoryBanks()) |bank| map.addRam(wireRange(bank)) catch fail("RAM map exceeds handoff bounds");
    for (discovered.reservations()) |reserved| map.addReservation(wireRange(reserved), .reserved) catch
        fail("reservation map exceeds handoff bounds");
    map.addReservation(wireRange(loader_range), .loader_reclaimable) catch fail("loader reservation invalid");
    map.addReservation(wireRange(kernel_range), .kernel) catch fail("kernel reservation invalid");
    map.addReservation(wireRange(discovered.console.range), .mmio) catch fail("console reservation invalid");
    map.finalize(&boot_info) catch fail("memory map normalization failed");
    boot_info.validate(@sizeOf(protocol.BootInfo), .aarch64) catch fail("invalid handoff");
    uart.write("[bootloader] handoff ready\n");
    bedrock_bootloader_jump(kernel_base, &boot_info, @sizeOf(protocol.BootInfo));
}

export fn bedrock_bootloader_fault(esr: u64, elr: u64, far: u64) callconv(.c) noreturn {
    uart.write("[fault] bootloader exception ESR=");
    uart.hex(esr);
    uart.write(" ELR=");
    uart.hex(elr);
    uart.write(" FAR=");
    uart.hex(far);
    uart.write("\n");
    stop(1);
}
