//! Kernel bring-up policy for the named QEMU virt-10.1 ARM64 platform.
const std = @import("std");
const protocol = @import("boot_protocol");
const uart = @import("qemu_virt_uart");
const memory = @import("memory_init");
const options = @import("kernel_options");
const framebuffer = @import("framebuffer");
var console_ready = false;
var graphics_enabled = false;
const console = struct {
    pub fn write(bytes: []const u8) void {
        if (graphics_enabled) framebuffer.write(bytes) else if (console_ready) uart.write(bytes);
    }
    pub fn writeHex(value: u64) void {
        var text: [18]u8 = undefined;
        text[0..2].* = "0x".*;
        for (0..16) |i| text[i + 2] = "0123456789abcdef"[@intCast((value >> @as(u6, @intCast((15 - i) * 4))) & 15)];
        write(&text);
    }
};

pub const panic = std.debug.FullPanic(panicHandler);

extern fn bedrock_arch_current_el() callconv(.c) u64;
extern fn bedrock_arch_translation_state() callconv(.c) u64;
extern fn bedrock_arch_deliberate_brk() callconv(.c) void;
extern fn bedrock_arch_semihost_exit() callconv(.c) noreturn;
extern fn bedrock_arch_halt() callconv(.c) noreturn;
extern var bedrock_arch_brk_instruction: u8;
extern var __kernel_image_start: u8;
extern var __kernel_image_end: u8;
extern var __stack_top: u8;

const ram_base: u64 = 0x40000000;
const loader_end: usize = 0x40200000;
const handoff_arena_start: usize = 0x40100000;
const kernel_base: u64 = 0x40200000;
const kernel_reserved_size: u64 = 0x200000;
const kernel_stack_bottom: u64 = 0x403f0000;

export var bedrock_kernel_bss_sentinel: u64 = 0;
var break_state: u32 = 0;

fn breakState() *volatile u32 {
    return &break_state;
}

fn fail(message: []const u8) noreturn {
    console.write("[fault] kernel: ");
    console.write(message);
    console.write("\n");
    bedrock_arch_halt();
}

fn panicHandler(message: []const u8, return_address: ?usize) noreturn {
    console.write("[panic] kernel: ");
    console.write(message);
    if (return_address) |address| {
        console.write(" at ");
        console.writeHex(address);
    }
    console.write("\n");
    bedrock_arch_halt();
}

fn readBigEndian32(address: usize) u32 {
    const bytes: [*]volatile u8 = @ptrFromInt(address);
    return (@as(u32, bytes[0]) << 24) |
        (@as(u32, bytes[1]) << 16) |
        (@as(u32, bytes[2]) << 8) |
        @as(u32, bytes[3]);
}

fn validatePlatform(info: *const protocol.BootInfo) void {
    if (options.uefi_entry) {
        if (info.boot_environment != @backingInt(protocol.BootEnvironment.uefi) or
            info.entry_state != @backingInt(protocol.EntryState.aarch64_el1)) fail("unexpected UEFI entry state");
        const image_end = info.kernel_image.endExclusive() catch fail("kernel image overflow");
        if (info.kernel_image.base != @intFromPtr(&__kernel_image_start) or
            @intFromPtr(&__kernel_image_end) > image_end or @intFromPtr(&__stack_top) > image_end or
            @intFromPtr(&__stack_top) < info.kernel_image.base or !info.isMapped(info.kernel_reserved))
            fail("unexpected relocated kernel bounds");
        if (bedrock_arch_translation_state() & ((1 << 0) | (1 << 2) | (1 << 12)) != 0)
            fail("expected owned direct physical entry");
        if (info.dtb.length != 0) {
            if (info.dtb.length < 40 or readBigEndian32(@intCast(info.dtb.base)) != 0xd00dfeed or
                readBigEndian32(@intCast(info.dtb.base + 4)) != info.dtb.length) fail("invalid UEFI DTB");
        }
        return;
    }
    if (info.boot_environment != @backingInt(protocol.BootEnvironment.reset_firmware) or
        info.entry_state != @backingInt(protocol.EntryState.aarch64_el1)) fail("unexpected entry environment");
    if (info.console.kind != @backingInt(protocol.ConsoleKind.pl011) or info.console.register_stride != 4)
        fail("unsupported console type");
    if (info.ram.base != ram_base or info.ram.length < 0x400000) fail("insufficient boot RAM");
    if (info.memory_region_count == 0) fail("missing discovered memory map");
    if (info.loader_reserved.base != ram_base or
        info.loader_reserved.length != loader_end - ram_base)
        fail("unexpected loader reservation");
    if (info.kernel_reserved.base != kernel_base or
        info.kernel_reserved.length != kernel_reserved_size)
        fail("unexpected kernel reservation");

    const image_end = info.kernel_image.endExclusive() catch fail("kernel image range overflow");
    if (info.kernel_image.base != kernel_base or info.kernel_image.length == 0 or
        image_end > kernel_stack_bottom)
        fail("unexpected kernel image range");

    const dtb_end = info.dtb.endExclusive() catch fail("DTB range overflow");
    if (info.dtb.base != ram_base or info.dtb.length < 40 or dtb_end > handoff_arena_start)
        fail("unexpected DTB range");
    const dtb_address: usize = @intCast(info.dtb.base);
    if (readBigEndian32(dtb_address) != 0xd00dfeed) fail("invalid DTB magic");
    if (readBigEndian32(dtb_address + 4) != info.dtb.length) fail("DTB length mismatch");
}

/// x0 is kept as an integer until its range, size and alignment are checked.
export fn bedrock_kernel_main(raw_info: usize, available_bytes: usize, arena_base: usize, arena_bytes: usize) callconv(.c) noreturn {
    if (!options.uefi_entry) {
        uart.init();
        console_ready = true;
        console.write("[kernel] ARM64 entry\n");
    }
    if (bedrock_arch_current_el() != 1) fail("expected EL1");

    const sentinel: *volatile u64 = &bedrock_kernel_bss_sentinel;
    if (sentinel.* != 0 or breakState().* != 0) fail("BSS was not cleared");

    // This envelope is part of the pinned platform contract, not untrusted
    // information taken from the handoff itself.
    const arena_end = @addWithOverflow(arena_base, arena_bytes);
    if (arena_end[1] != 0 or arena_bytes == 0 or raw_info < arena_base or raw_info >= arena_end[0])
        fail("handoff pointer outside loader arena");
    if (options.uefi_entry) {
        if (arena_base % 4096 != 0 or arena_bytes != 0x200000) fail("unexpected trusted UEFI arena");
    } else if (arena_base != handoff_arena_start or arena_end[0] != loader_end)
        fail("unexpected trusted reset arena");
    if (raw_info % @alignOf(protocol.BootInfo) != 0) fail("misaligned handoff pointer");
    if (available_bytes > arena_end[0] - raw_info) fail("handoff buffer outside loader arena");
    if (available_bytes < @sizeOf(protocol.Header)) fail("truncated handoff prefix");

    // Read only the checked fixed prefix before dereferencing the full record.
    const header: *const protocol.Header = @ptrFromInt(raw_info);
    header.validate(available_bytes, .aarch64) catch |err| {
        console.write("[fault] kernel invalid handoff prefix: ");
        console.write(@errorName(err));
        console.write("\n");
        bedrock_arch_halt();
    };
    if (available_bytes < @sizeOf(protocol.BootInfo) or
        header.header_size < @sizeOf(protocol.BootInfo))
        fail("truncated handoff record");

    // Retain one validated handoff owner instead of making secret seed copies.
    const info: *const protocol.BootInfo = @ptrFromInt(raw_info);
    info.validate(available_bytes, .aarch64) catch |err| {
        console.write("[fault] kernel invalid handoff: ");
        console.write(@errorName(err));
        console.write("\n");
        bedrock_arch_halt();
    };
    if (options.uefi_entry and (info.loader_reserved.base != arena_base or info.loader_reserved.length != arena_bytes))
        fail("handoff contradicts trusted loader arena");
    validatePlatform(info);
    if (info.console.kind == @backingInt(protocol.ConsoleKind.framebuffer) and options.uefi_entry) {
        framebuffer.configure(info.framebuffer);
        graphics_enabled = true;
    } else {
        if (info.console.kind != @backingInt(protocol.ConsoleKind.pl011) or info.console.register_stride != 4 or
            !uart.configure(@intCast(info.console.base), info.console.clock_hz, info.console.baud_rate))
            fail("unsupported console description");
        console_ready = true;
    }
    if (options.uefi_entry) console.write("[kernel] ARM64 entry\n");
    console.write("[kernel] handoff valid\n");
    console.write("[kernel] RAM base=");
    console.writeHex(info.ram.base);
    console.write(" bytes=");
    console.writeHex(info.ram.length);
    console.write(" reserved through=");
    console.writeHex(info.kernel_reserved.base + info.kernel_reserved.length);
    console.write("\n");
    memory.initialize(console, info) catch |err| {
        console.write("[fault] kernel memory initialization: ");
        console.write(@errorName(err));
        console.write("\n");
        bedrock_arch_halt();
    };

    breakState().* = 1;
    bedrock_arch_deliberate_brk();
    if (breakState().* != 2) fail("deliberate trap did not resume");
    breakState().* = 0;
    if (options.uefi_entry) {
        @import("isolation").run(console, info) catch |err| {
            console.write("[fault] kernel user isolation: ");
            console.write(@errorName(err));
            console.write("\n");
            bedrock_arch_halt();
        };
    }
    console.write("[kernel] ARM64 boot complete\n");
    if (options.uefi_entry and (info.flags & protocol.flag_smoke_exit) == 0 and graphics_enabled) {
        graphics_enabled = false;
        uart.init();
        console_ready = true;
        @import("isolation").runDesktop(console, info, "ARM64") catch |err| {
            framebuffer.configure(info.framebuffer);
            fail(@errorName(err));
        };
    }
    if ((info.flags & protocol.flag_smoke_exit) != 0) bedrock_arch_semihost_exit();
    bedrock_arch_halt();
}

/// Assembly preserves all GPRs, SIMD state and SPSR around this C ABI call.
/// Returning a PC is permitted only for the armed current-EL SPx BRK probe.
export fn bedrock_exception_handler(esr: u64, elr: u64, far: u64, vector_slot: u64) callconv(.c) u64 {
    const exception_class = (esr >> 26) & 0x3f;
    if (vector_slot == 4 and exception_class == 0x3c and
        (esr & 0xffff) == 0xbed and breakState().* == 1 and
        elr == @intFromPtr(&bedrock_arch_brk_instruction))
    {
        breakState().* = 2;
        console.write("[kernel] exception handled\n");
        return elr + 4;
    }

    console.write("[fault] kernel exception: vector=");
    console.writeHex(vector_slot);
    console.write(" ESR=");
    console.writeHex(esr);
    console.write(" ELR=");
    console.writeHex(elr);
    console.write(" FAR=");
    console.writeHex(far);
    console.write("\n");
    bedrock_arch_halt();
}
