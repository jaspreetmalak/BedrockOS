//! Single-hart M-mode bring-up for QEMU RISC-V virt, using integer-only code.
const std = @import("std");
const builtin = @import("builtin");
const protocol = @import("boot_protocol");
const uart = @import("uart.zig");
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

const ram_base: u64 = 0x80000000;
const handoff_arena_end: usize = 0x80100000;
const dtb_base: u64 = 0x80100000;
const dtb_capacity: u64 = 0x80000;
const kernel_base: u64 = 0x80200000;
const kernel_stack_bottom: u64 = 0x803f0000;

extern fn bedrock_riscv_kernel_misa() callconv(.c) u64;
extern fn bedrock_riscv_kernel_status() callconv(.c) u64;
extern fn bedrock_riscv_kernel_translation() callconv(.c) u64;
extern fn bedrock_riscv_kernel_break() callconv(.c) void;
extern fn bedrock_riscv_kernel_exit(status: u32) callconv(.c) noreturn;
extern fn bedrock_riscv_kernel_halt() callconv(.c) noreturn;
extern var bedrock_riscv_break_instruction: u8;
extern var __kernel_image_start: u8;
extern var __kernel_image_end: u8;
extern var __stack_top: u8;

pub const panic = std.debug.FullPanic(panicHandler);
export var bedrock_riscv_bss_sentinel: u64 = 0;
var break_state: u32 = 0;
var smoke_enabled: bool = false;

comptime {
    if (builtin.cpu.arch != .riscv64) @compileError("This kernel profile requires RV64");
    if (std.Target.riscv.featureSetHasAny(builtin.cpu.features, &.{ .f, .d, .v }))
        @compileError("RV64 kernel requires an integer-only target without F, D or V");
}

fn breakState() *volatile u32 {
    return &break_state;
}

fn stop(status: u32) noreturn {
    if (smoke_enabled) bedrock_riscv_kernel_exit(status);
    bedrock_riscv_kernel_halt();
}

fn fail(message: []const u8) noreturn {
    console.write("[fault] kernel: ");
    console.write(message);
    console.write("\n");
    stop(1);
}

fn panicHandler(message: []const u8, return_address: ?usize) noreturn {
    console.write("[panic] kernel: ");
    console.write(message);
    if (return_address) |address| {
        console.write(" at ");
        console.writeHex(address);
    }
    console.write("\n");
    stop(1);
}

fn readBe32(address: usize) u32 {
    const bytes: [*]const volatile u8 = @ptrFromInt(address);
    return (@as(u32, bytes[0]) << 24) | (@as(u32, bytes[1]) << 16) |
        (@as(u32, bytes[2]) << 8) | @as(u32, bytes[3]);
}

fn validatePlatform(info: protocol.BootInfo) void {
    if (options.uefi_entry) {
        if (info.boot_environment != @backingInt(protocol.BootEnvironment.uefi) or
            info.entry_state != @backingInt(protocol.EntryState.riscv64_s)) fail("unexpected UEFI entry state");
        const image_end = info.kernel_image.endExclusive() catch fail("kernel image overflow");
        if (info.kernel_image.base != @intFromPtr(&__kernel_image_start) or
            @intFromPtr(&__kernel_image_end) > image_end or @intFromPtr(&__stack_top) > image_end or
            @intFromPtr(&__stack_top) < info.kernel_image.base or !info.isMapped(info.kernel_reserved))
            fail("unexpected relocated kernel bounds");
        if (info.dtb.length != 0) {
            if (info.dtb.length < 40 or readBe32(@intCast(info.dtb.base)) != 0xd00dfeed or
                readBe32(@intCast(info.dtb.base + 4)) != info.dtb.length) fail("invalid UEFI DTB");
        }
        return;
    }
    if (info.boot_environment != @backingInt(protocol.BootEnvironment.reset_firmware) or
        info.entry_state != @backingInt(protocol.EntryState.riscv64_m)) fail("unexpected entry environment");
    if (info.console.kind != @backingInt(protocol.ConsoleKind.ns16550_mmio)) fail("unsupported console type");
    if (info.ram.base != ram_base or info.ram.length < 0x400000) fail("insufficient boot RAM");
    if (info.memory_region_count == 0) fail("missing discovered memory map");
    if (info.loader_reserved.base != ram_base or info.loader_reserved.length != 0x200000)
        fail("unexpected loader reservation");
    if (info.kernel_reserved.base != kernel_base or info.kernel_reserved.length != 0x200000)
        fail("unexpected kernel reservation");
    const image_end = info.kernel_image.endExclusive() catch fail("kernel image range overflow");
    if (info.kernel_image.base != kernel_base or info.kernel_image.length == 0 or
        image_end > kernel_stack_bottom)
        fail("unexpected kernel image range");
    if (info.dtb.base != dtb_base or info.dtb.length < 40 or info.dtb.length > dtb_capacity)
        fail("unexpected copied DTB range");
    if (readBe32(dtb_base) != 0xd00dfeed) fail("invalid DTB magic");
    if (readBe32(dtb_base + 4) != info.dtb.length) fail("DTB length mismatch");
}

/// Pointer remains an integer until its trusted physical arena is checked.
export fn bedrock_riscv_kernel_main(raw_info: usize, available_bytes: usize, arena_base: usize, arena_bytes: usize) callconv(.c) noreturn {
    if (!options.uefi_entry) {
        uart.init();
        console_ready = true;
        console.write("[kernel] riscv64 entry\n");
        if (bedrock_riscv_kernel_misa() >> 62 != 2) fail("RV64 M-mode required");
    }
    const status = bedrock_riscv_kernel_status();
    const forbidden_status: u64 = if (options.uefi_entry)
        ((1 << 18) | (1 << 19) | (3 << 13) | (3 << 9) | (1 << 1))
    else
        ((1 << 17) | (3 << 13) | (3 << 9) | (1 << 3));
    if ((status & forbidden_status) != 0 or bedrock_riscv_kernel_translation() != 0)
        fail("expected integer-only direct physical execution");
    const sentinel: *volatile u64 = &bedrock_riscv_bss_sentinel;
    if (sentinel.* != 0 or breakState().* != 0) fail("BSS was not cleared");

    const arena_end = @addWithOverflow(arena_base, arena_bytes);
    if (arena_end[1] != 0 or arena_bytes == 0 or raw_info < arena_base or raw_info >= arena_end[0])
        fail("handoff pointer outside loader arena");
    if (options.uefi_entry) {
        if (arena_base % 4096 != 0 or arena_bytes != 0x200000) fail("unexpected trusted UEFI arena");
    } else if (arena_base != ram_base or arena_end[0] != handoff_arena_end)
        fail("unexpected trusted reset arena");
    if (raw_info % @alignOf(protocol.BootInfo) != 0) fail("misaligned handoff pointer");
    if (available_bytes > arena_end[0] - raw_info)
        fail("handoff buffer outside loader arena");
    if (available_bytes < @sizeOf(protocol.Header)) fail("truncated handoff prefix");
    const header: *const protocol.Header = @ptrFromInt(raw_info);
    header.validate(available_bytes, .riscv64) catch |err| {
        console.write("[fault] kernel handoff prefix: ");
        console.write(@errorName(err));
        console.write("\n");
        stop(1);
    };
    if (available_bytes < @sizeOf(protocol.BootInfo) or
        header.header_size < @sizeOf(protocol.BootInfo))
        fail("truncated handoff record");
    const info = @as(*const protocol.BootInfo, @ptrFromInt(raw_info)).*;
    info.validate(available_bytes, .riscv64) catch |err| {
        console.write("[fault] kernel handoff: ");
        console.write(@errorName(err));
        console.write("\n");
        stop(1);
    };
    smoke_enabled = (info.flags & protocol.flag_smoke_exit) != 0;
    if (options.uefi_entry and (info.loader_reserved.base != arena_base or info.loader_reserved.length != arena_bytes))
        fail("handoff contradicts trusted loader arena");
    validatePlatform(info);
    if (info.console.kind == @backingInt(protocol.ConsoleKind.framebuffer) and options.uefi_entry) {
        framebuffer.configure(info.framebuffer);
        graphics_enabled = true;
    } else {
        if (info.console.kind != @backingInt(protocol.ConsoleKind.ns16550_mmio) or
            !uart.configure(@intCast(info.console.base), info.console.register_stride, info.console.clock_hz, info.console.baud_rate))
            fail("unsupported console description");
        console_ready = true;
    }
    if (options.uefi_entry) console.write("[kernel] riscv64 entry\n");
    console.write("[kernel] handoff valid\n");
    console.write("[kernel] RAM base=");
    console.writeHex(info.ram.base);
    console.write(" bytes=");
    console.writeHex(info.ram.length);
    console.write(" reserved through=");
    console.writeHex(info.kernel_reserved.base + info.kernel_reserved.length);
    console.write("\n");
    memory.initialize(console, &info) catch |err| {
        console.write("[fault] kernel memory initialization: ");
        console.write(@errorName(err));
        console.write("\n");
        stop(1);
    };
    breakState().* = 1;
    bedrock_riscv_kernel_break();
    if (breakState().* != 2) fail("deliberate trap did not resume");
    breakState().* = 0;
    if (options.uefi_entry) {
        @import("isolation").run(console, &info) catch |err| {
            console.write("[fault] kernel isolation: ");
            console.write(@errorName(err));
            console.write("\n");
            stop(1);
        };
    }
    console.write("[kernel] riscv64 boot complete\n");
    if (options.uefi_entry and !smoke_enabled and graphics_enabled) {
        graphics_enabled = false;
        uart.init();
        console_ready = true;
        @import("isolation").runDesktop(console, &info, "RV64") catch |err| {
            framebuffer.configure(info.framebuffer);
            fail(@errorName(err));
        };
    }
    stop(0);
}

/// The direct mtvec assembly entry preserves every GPR and mstatus.
export fn bedrock_riscv_kernel_trap(cause: u64, pc: u64, value: u64, status: u64) callconv(.c) u64 {
    const expected_privilege = if (options.uefi_entry) (status & (1 << 8)) != 0 else (status & (3 << 11)) == (3 << 11);
    if (cause == 3 and expected_privilege and
        breakState().* == 1 and pc == @intFromPtr(&bedrock_riscv_break_instruction))
    {
        breakState().* = 2;
        console.write("[kernel] exception handled\n");
        return pc + 4;
    }
    console.write("[fault] kernel exception mcause=");
    console.writeHex(cause);
    console.write(" mepc=");
    console.writeHex(pc);
    console.write(" mtval=");
    console.writeHex(value);
    console.write("\n");
    stop(1);
}
