//! x86-64 kernel entry shared by the reset-ROM and UEFI loader paths.
const std = @import("std");
const protocol = @import("boot_protocol");
const uart = @import("uart.zig");
const memory = @import("memory_init");
const options = @import("kernel_options");
const timer = @import("timer.zig");
pub const panic = std.debug.FullPanic(panicHandler);
extern fn bedrock_arch_halt() callconv(.c) noreturn;
extern fn bedrock_arch_exit(status: u64) callconv(.c) noreturn;
extern fn bedrock_arch_install_idt(base: usize, limit: u16) callconv(.c) void;
extern fn bedrock_arch_deliberate_int3() callconv(.c) bool;
extern fn bedrock_arch_default_isr() callconv(.c) void;
extern fn bedrock_x86_syscall_isr() callconv(.c) void;
extern fn bedrock_x86_timer_isr() callconv(.c) void;
extern var bedrock_arch_int3_resume: u8;
extern var bedrock_arch_isr_table: [32]usize;
extern var __kernel_image_start: u8;
extern var __kernel_image_end: u8;
extern var __stack_top: u8;
extern fn bedrock_arch_cr3() callconv(.c) u64;
extern fn bedrock_arch_physical_bits() callconv(.c) u32;
var bss_sentinel: u64 = 0;
var data_sentinel: u64 = 0xbedd0017;
var break_state: u32 = 0;
var smoke_exit: bool = false;

const IdtGate = extern struct {
    offset_low: u16,
    selector: u16,
    ist: u8,
    attributes: u8,
    offset_middle: u16,
    offset_high: u32,
    reserved: u32,
    fn init(address: usize) IdtGate {
        return .{
            .offset_low = @truncate(address),
            .selector = 0x18,
            .ist = 0,
            .attributes = 0x8e,
            .offset_middle = @truncate(address >> 16),
            .offset_high = @truncate(address >> 32),
            .reserved = 0,
        };
    }
};
comptime {
    if (@sizeOf(IdtGate) != 16 or @offsetOf(IdtGate, "offset_high") != 8)
        @compileError("x86-64 interrupt gate layout changed");
}
var idt: [256]IdtGate align(16) = undefined;
fn installIdt() void {
    for (&idt) |*gate| gate.* = IdtGate.init(@intFromPtr(&bedrock_arch_default_isr));
    for (bedrock_arch_isr_table, 0..) |address, index| idt[index] = IdtGate.init(address);
    bedrock_arch_install_idt(@intFromPtr(&idt), @sizeOf(@TypeOf(idt)) - 1);
}
export fn bedrock_x86_install_isolation_idt() callconv(.c) void {
    if (options.uefi_entry) {
        idt[128] = IdtGate.init(@intFromPtr(&bedrock_x86_syscall_isr));
        idt[128].attributes = 0xee;
        idt[8].ist = 1;
        bedrock_arch_install_idt(@intFromPtr(&idt), @sizeOf(@TypeOf(idt)) - 1);
    }
}
export fn bedrock_pc_timer_prepare(info: *const protocol.BootInfo) callconv(.c) bool {
    if (!options.uefi_entry or !timer.prepare(info)) return false;
    idt[timer.vector] = IdtGate.init(@intFromPtr(&bedrock_x86_timer_isr));
    bedrock_arch_install_idt(@intFromPtr(&idt), @sizeOf(@TypeOf(idt)) - 1);
    return true;
}
export fn bedrock_pc_timer_arm() callconv(.c) void {
    timer.arm();
}
export fn bedrock_pc_timer_acknowledge() callconv(.c) bool {
    return timer.acknowledge();
}
export fn bedrock_pc_timer_stop() callconv(.c) void {
    timer.stop();
}
export fn bedrock_pc_timer_idle_until_tick() callconv(.c) bool {
    return timer.idleUntilTick();
}
fn breakState() *volatile u32 {
    return &break_state;
}
fn stop(status: u64) noreturn {
    if (smoke_exit) bedrock_arch_exit(status);
    bedrock_arch_halt();
}
fn fail(message: []const u8) noreturn {
    uart.write("[fault] kernel: ");
    uart.write(message);
    uart.write("\n");
    stop(1);
}
fn panicHandler(message: []const u8, _: ?usize) noreturn {
    uart.write("[panic] kernel: ");
    uart.write(message);
    uart.write("\n");
    stop(1);
}
fn addressLimit(bits: u32) u64 {
    if (bits < 32 or bits > 52) fail("unsupported physical address width");
    return @min(@as(u64, 1) << 47, @as(u64, 1) << @as(u6, @intCast(bits)));
}
// The loader identity-maps its page-table pool. Consult the live tables before
// any arbitrary handoff pointer is dereferenced, including cross-page records.
fn identityMapped(base: u64, bytes: u64, bits: u32) bool {
    if (base == 0 or bytes == 0) return false;
    const sum = @addWithOverflow(base, bytes);
    const limit = addressLimit(bits);
    if (sum[1] != 0 or sum[0] > limit) return false;
    const mask: u64 = 0x000ffffffffff000;
    var address = base;
    while (address < sum[0]) {
        var table_address = bedrock_arch_cr3() & mask;
        const shifts = [_]u6{ 39, 30, 21, 12 };
        var next: u64 = 0;
        for (shifts, 0..) |shift, level| {
            if (table_address == 0 or table_address >= limit) return false;
            const entries: [*]const volatile u64 = @ptrFromInt(table_address);
            const entry = entries[@intCast((address >> shift) & 511)];
            if (entry & 1 == 0) return false;
            const is_large = (level == 1 or level == 2) and entry & (1 << 7) != 0;
            if (is_large or level == 3) {
                const leaf_shift: u6 = if (is_large) shift else 12;
                const offset_mask = (@as(u64, 1) << leaf_shift) - 1;
                const physical = (entry & mask & ~offset_mask) | (address & offset_mask);
                if (physical != address) return false;
                next = (address & ~offset_mask) + offset_mask + 1;
                break;
            }
            table_address = entry & mask;
        }
        if (next <= address) return false;
        address = @min(next, sum[0]);
    }
    return true;
}
fn validatePlatform(info: *const protocol.BootInfo) void {
    if (info.entry_state != @backingInt(protocol.EntryState.x86_64_long_mode)) fail("unexpected CPU entry state");
    if (info.memory_region_count == 0) fail("missing discovered memory map");
    if (info.boot_environment == @backingInt(protocol.BootEnvironment.reset_firmware)) {
        if (info.console.kind != @backingInt(protocol.ConsoleKind.ns16550_io) or info.console.base != uart.base)
            fail("unexpected reset console");
        if (info.ram.base != 0 or info.ram.length < 0x400000) fail("insufficient boot RAM");
        if (info.loader_reserved.base != 0 or info.loader_reserved.length != 0x200000)
            fail("unexpected reset loader reservation");
    } else if (info.boot_environment == @backingInt(protocol.BootEnvironment.uefi)) {
        if (info.physical_address_bits != bedrock_arch_physical_bits()) fail("incorrect CPU physical width");
        if (!identityMapped(info.loader_reserved.base, info.loader_reserved.length, info.physical_address_bits) or
            !identityMapped(info.kernel_reserved.base, info.kernel_reserved.length, info.physical_address_bits))
            fail("boot arenas are not identity mapped");
        if (info.framebuffer.size != 0 and !identityMapped(info.framebuffer.base, info.framebuffer.size, info.physical_address_bits))
            fail("framebuffer is not identity mapped");
    } else fail("unsupported boot environment");
    if (info.boot_environment == @backingInt(protocol.BootEnvironment.reset_firmware) and
        (info.kernel_reserved.base != 0x200000 or info.kernel_reserved.length != 0x200000))
        fail("unexpected kernel reservation");
    const image_end = info.kernel_image.endExclusive() catch fail("kernel range overflow");
    const linked_start = @intFromPtr(&__kernel_image_start);
    const linked_end = @intFromPtr(&__kernel_image_end);
    const stack_top = @intFromPtr(&__stack_top);
    const reserved_end = info.kernel_reserved.endExclusive() catch fail("kernel reservation overflow");
    if (info.kernel_image.base != linked_start or info.kernel_image.length == 0 or image_end < linked_end or
        linked_start < info.kernel_reserved.base or stack_top > reserved_end)
        fail("unexpected kernel image range");
    if (info.dtb.base != 0 or info.dtb.length != 0) fail("this PC profile has no DTB");
}
export fn bedrock_kernel_main(raw_info: usize, available_bytes: usize) callconv(.c) noreturn {
    const bss: *volatile u64 = &bss_sentinel;
    const data: *volatile u64 = &data_sentinel;
    if (bss.* != 0 or data.* != 0xbedd0017 or breakState().* != 0)
        fail("RAM initialization failed");
    installIdt();
    const physical_bits = bedrock_arch_physical_bits();
    // The live page tables establish accessibility before trusting metadata.
    if (raw_info % @alignOf(protocol.BootInfo) != 0) fail("misaligned handoff pointer");
    if (available_bytes > 0x200000) fail("handoff exceeds bounded record limit");
    if (available_bytes < @sizeOf(protocol.Header)) fail("truncated handoff prefix");
    if (!identityMapped(raw_info, @sizeOf(protocol.Header), physical_bits)) fail("handoff prefix is not mapped");
    const header: *const protocol.Header = @ptrFromInt(raw_info);
    header.validate(available_bytes, .x86_64) catch fail("invalid handoff prefix");
    if (available_bytes < @sizeOf(protocol.BootInfo) or header.header_size < @sizeOf(protocol.BootInfo))
        fail("truncated handoff record");
    if (!identityMapped(raw_info, @sizeOf(protocol.BootInfo), physical_bits)) fail("handoff record is not mapped");
    // Retain one validated handoff owner instead of making secret seed copies.
    const info: *const protocol.BootInfo = @ptrFromInt(raw_info);
    info.validate(available_bytes, .x86_64) catch fail("invalid handoff record");
    const loader_end = info.loader_reserved.endExclusive() catch fail("loader reservation overflow");
    if (raw_info < info.loader_reserved.base or raw_info >= loader_end or available_bytes > loader_end - raw_info)
        fail("handoff crosses loader reservation");
    validatePlatform(info);
    if (!uart.configure(info)) fail("unsupported console description");
    uart.write("[kernel] x86_64 entry\n");
    smoke_exit = info.flags & protocol.flag_smoke_exit != 0;
    uart.write("[kernel] handoff valid\n");
    uart.write("[kernel] RAM base=");
    uart.hex(info.ram.base);
    uart.write(" bytes=");
    uart.hex(info.ram.length);
    uart.write(" reserved through=");
    uart.hex(info.kernel_reserved.base + info.kernel_reserved.length);
    uart.write("\n");
    memory.initialize(uart, info) catch |err| {
        uart.write("[fault] kernel memory initialization: ");
        uart.write(@errorName(err));
        uart.write("\n");
        stop(1);
    };
    breakState().* = 1;
    const state_preserved = bedrock_arch_deliberate_int3();
    if (breakState().* != 2 or !state_preserved) fail("exception state was not preserved");
    breakState().* = 0;
    if (options.uefi_entry) {
        @import("isolation").run(uart, info) catch |err| {
            uart.write("[fault] kernel isolation: ");
            uart.write(@errorName(err));
            uart.write("\n");
            stop(1);
        };
    }
    uart.write("[kernel] x86_64 boot complete\n");
    if (options.uefi_entry and !smoke_exit and info.console.kind == @backingInt(protocol.ConsoleKind.framebuffer)) {
        uart.desktopTrace();
        @import("isolation").runDesktop(uart, info, "x86_64") catch |err| {
            @import("framebuffer").configure(info.framebuffer);
            fail(@errorName(err));
        };
    }
    stop(0);
}
/// The wrapper saves GPRs, x87/SSE state and the original hardware frame.
/// Only the armed INT3 probe may return; its saved RIP is already past INT3.
export fn bedrock_exception_handler(vector: u64, error_code: u64, rip: u64, cr2: u64) callconv(.c) void {
    if (vector == 3 and error_code == 0 and breakState().* == 1 and
        rip == @intFromPtr(&bedrock_arch_int3_resume))
    {
        breakState().* = 2;
        uart.write("[kernel] exception handled\n");
        return;
    }
    uart.write("[fault] kernel exception vector=");
    uart.hex(vector);
    uart.write(" error=");
    uart.hex(error_code);
    uart.write(" RIP=");
    uart.hex(rip);
    uart.write(" CR2=");
    uart.hex(cr2);
    uart.write("\n");
    stop(1);
}
