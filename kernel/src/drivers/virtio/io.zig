//! Named QEMU coherent-DMA profiles. CPU barriers include device I/O; real
//! noncoherent hardware requires an additional cache-maintenance adapter.
const builtin = @import("builtin");

pub fn read(comptime T: type, address: u64) T {
    const pointer: *const volatile T = @ptrFromInt(address);
    return pointer.*;
}

pub fn write(comptime T: type, address: u64, value: T) void {
    const pointer: *volatile T = @ptrFromInt(address);
    pointer.* = value;
}

pub fn fence() void {
    switch (builtin.cpu.arch) {
        .x86_64 => asm volatile ("mfence" ::: .{ .memory = true }),
        .aarch64 => asm volatile ("dsb sy" ::: .{ .memory = true }),
        .riscv64 => asm volatile ("fence iorw, iorw" ::: .{ .memory = true }),
        else => @compileError("VirtIO requires a supported Bedrock architecture"),
    }
}

pub fn relax() void {
    switch (builtin.cpu.arch) {
        .x86_64 => asm volatile ("pause"),
        .aarch64 => asm volatile ("yield"),
        .riscv64 => asm volatile ("nop"),
        else => unreachable,
    }
}

pub fn out32(port: u16, value: u32) void {
    if (builtin.cpu.arch != .x86_64) unreachable;
    asm volatile ("outl %[value], %[port]"
        :
        : [value] "{eax}" (value),
          [port] "{dx}" (port),
        : .{ .memory = true });
}

pub fn in32(port: u16) u32 {
    if (builtin.cpu.arch != .x86_64) unreachable;
    return asm volatile ("inl %[port], %[value]"
        : [value] "={eax}" (-> u32),
        : [port] "{dx}" (port),
        : .{ .memory = true });
}
