//! Bedrock M-mode firmware for QEMU RISC-V virt; no OpenSBI or SBI calls.
const std = @import("std");
const builtin = @import("builtin");
const protocol = @import("boot_protocol");
const options = @import("boot_options");
const device_tree = @import("device_tree");
const uart = @import("uart.zig");
const kernel_image = @embedFile("kernel_image");

const ram_base: usize = 0x80000000;
const dtb_copy: usize = 0x80100000;
const dtb_capacity: usize = 0x80000;
const kernel_base: usize = 0x80200000;
const kernel_capacity: usize = 0x1f0000;
const reserved_end: usize = 0x80400000;
const loader_range: device_tree.Range = .{ .base = ram_base, .length = 0x200000 };
const loader_used: device_tree.Range = .{ .base = ram_base, .length = 0x180000 };
const kernel_range: device_tree.Range = .{ .base = kernel_base, .length = 0x200000 };

extern fn bedrock_riscv_loader_misa() callconv(.c) u64;
extern fn bedrock_riscv_loader_jump(entry: usize, info: *const protocol.BootInfo, bytes: usize) callconv(.c) noreturn;
extern fn bedrock_riscv_loader_halt() callconv(.c) noreturn;
extern fn bedrock_riscv_loader_exit(status: u32) callconv(.c) noreturn;

pub const panic = std.debug.FullPanic(panicHandler);
var boot_info: protocol.BootInfo = undefined;
var bss_sentinel: u64 = 0;

comptime {
    if (builtin.cpu.arch != .riscv64) @compileError("This firmware profile requires RV64");
    if (std.Target.riscv.featureSetHasAny(builtin.cpu.features, &.{ .f, .d, .v }))
        @compileError("RV64 firmware requires an integer-only target without F, D or V");
}

fn stop(status: u32) noreturn {
    if (options.smoke_test) bedrock_riscv_loader_exit(status);
    bedrock_riscv_loader_halt();
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

fn readBe32(address: usize) u32 {
    const bytes: [*]const volatile u8 = @ptrFromInt(address);
    return (@as(u32, bytes[0]) << 24) | (@as(u32, bytes[1]) << 16) |
        (@as(u32, bytes[2]) << 8) | @as(u32, bytes[3]);
}

fn dtbSize(raw_dtb: usize) usize {
    // QEMU's reset a1 is a trusted pointer to accessible RAM. Its RAM size is
    // not known until discovery, so no guessed upper RAM bound is applied.
    // The parsed bank must contain the entire source before any relocation.
    if (raw_dtb % 8 != 0 or raw_dtb < reserved_end or raw_dtb > std.math.maxInt(usize) - 40)
        fail("DTB pointer outside the source arena");
    if (readBe32(raw_dtb) != 0xd00dfeed) fail("DTB magic invalid");
    const size: usize = readBe32(raw_dtb + 4);
    if (size < 40 or size > dtb_capacity or size > std.math.maxInt(usize) - raw_dtb)
        fail("DTB range invalid");
    return size;
}

fn copyDtb(raw_dtb: usize, size: usize) void {
    const source: [*]const volatile u8 = @ptrFromInt(raw_dtb);
    const destination: [*]volatile u8 = @ptrFromInt(dtb_copy);
    for (0..size) |offset| destination[offset] = source[offset];
    for (0..size) |offset| {
        if (destination[offset] != source[offset]) fail("DTB copy verification failed");
    }
}

fn wireRange(range: device_tree.Range) protocol.PhysicalRange {
    return .{ .base = range.base, .length = range.length };
}

export fn bedrock_riscv_loader_main(hart_id: usize, raw_dtb: usize) callconv(.c) noreturn {
    uart.init();
    uart.write("[bootloader] riscv64 firmware entry\n");
    if (hart_id != 0) fail("single hart zero required");
    const misa = bedrock_riscv_loader_misa();
    const required_extensions: u64 = (1 << 8) | (1 << 12) | (1 << 0) | (1 << 2);
    if (misa >> 62 != 2 or (misa & required_extensions) != required_extensions)
        fail("RV64IMAC required");
    const sentinel: *volatile u64 = &bss_sentinel;
    if (sentinel.* != 0) fail("BSS was not cleared");
    sentinel.* = 0xbed;
    const dtb_size = dtbSize(raw_dtb);
    const source_blob: [*]const u8 = @ptrFromInt(raw_dtb);
    const discovered = device_tree.parse(source_blob[0..dtb_size]) catch |err| {
        uart.write(@errorName(err));
        uart.write("\n");
        fail("DTB discovery failed");
    };
    const boot_bank = discovered.containingBank(.{ .base = ram_base, .length = 0x400000 }) orelse
        fail("RAM does not contain the linked boot arenas");
    const source_range: device_tree.Range = .{ .base = raw_dtb, .length = dtb_size };
    if (discovered.containingBank(source_range) == null) fail("source DTB is outside discovered RAM");
    if (discovered.conflicts(loader_used) or discovered.conflicts(kernel_range))
        fail("firmware reservations conflict with linked boot arenas");
    const copied_range: device_tree.Range = .{ .base = dtb_copy, .length = dtb_size };
    if (!loader_range.contains(copied_range) or source_range.overlaps(loader_range) or source_range.overlaps(kernel_range))
        fail("DTB conflicts with linked boot arenas");
    if (discovered.console.kind != .ns16550_mmio) fail("this RV64 platform requires an NS16550 MMIO console");
    for (discovered.memoryBanks()) |bank| {
        if (bank.overlaps(discovered.console.range)) fail("console registers overlap RAM");
    }
    const console: protocol.Console = .{
        .kind = @backingInt(protocol.ConsoleKind.ns16550_mmio),
        .base = discovered.console.range.base,
        .register_stride = discovered.console.register_stride,
        .clock_hz = discovered.console.clock_hz,
        .baud_rate = discovered.console.baud_rate,
    };
    uart.configure(console) catch fail("unsupported discovered UART configuration");
    uart.write("[bootloader] RAM discovered length=");
    uart.writeHex(boot_bank.length);
    uart.write("\n");
    copyDtb(raw_dtb, dtb_size);

    if (kernel_image.len == 0 or kernel_image.len > kernel_capacity)
        fail("kernel image exceeds reserved memory");
    const destination: [*]volatile u8 = @ptrFromInt(kernel_base);
    for (kernel_image, 0..) |byte, offset| destination[offset] = byte;
    for (kernel_image, 0..) |byte, offset| {
        if (destination[offset] != byte) fail("kernel copy verification failed");
    }
    uart.write("[bootloader] kernel image copied\n");

    var header = protocol.Header.init(.riscv64);
    header.header_size = @sizeOf(protocol.BootInfo);
    boot_info = .{
        .header = header,
        .uart_base = console.base,
        .dtb = wireRange(copied_range),
        .kernel_image = .{ .base = kernel_base, .length = kernel_image.len },
        .ram = wireRange(boot_bank),
        .loader_reserved = wireRange(loader_range),
        .kernel_reserved = wireRange(kernel_range),
        .flags = if (options.smoke_test) protocol.flag_smoke_exit else 0,
        .console = console,
        .boot_environment = @backingInt(protocol.BootEnvironment.reset_firmware),
        .entry_state = @backingInt(protocol.EntryState.riscv64_m),
    };
    var map: protocol.MemoryMap = .{};
    for (discovered.memoryBanks()) |bank| map.addRam(wireRange(bank)) catch fail("RAM map exceeds handoff bounds");
    for (discovered.reservations()) |reserved| map.addReservation(wireRange(reserved), .reserved) catch
        fail("reservation map exceeds handoff bounds");
    map.addReservation(wireRange(loader_range), .loader_reclaimable) catch fail("loader reservation invalid");
    map.addReservation(wireRange(kernel_range), .kernel) catch fail("kernel reservation invalid");
    map.addReservation(wireRange(source_range), .loader_reclaimable) catch fail("source DTB reservation invalid");
    map.addReservation(wireRange(discovered.console.range), .mmio) catch fail("console reservation invalid");
    map.finalize(&boot_info) catch fail("memory map normalization failed");
    boot_info.validate(@sizeOf(protocol.BootInfo), .riscv64) catch fail("invalid handoff");
    uart.write("[bootloader] handoff ready\n");
    bedrock_riscv_loader_jump(kernel_base, &boot_info, @sizeOf(protocol.BootInfo));
}

export fn bedrock_riscv_loader_fault(cause: u64, pc: u64, value: u64) callconv(.c) noreturn {
    uart.write("[fault] bootloader exception mcause=");
    uart.writeHex(cause);
    uart.write(" mepc=");
    uart.writeHex(pc);
    uart.write(" mtval=");
    uart.writeHex(value);
    uart.write("\n");
    stop(1);
}
