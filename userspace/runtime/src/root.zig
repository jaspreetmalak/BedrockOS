//! Native Bedrock64 calls. No libc, TLS, dynamic linking or host system API.
const builtin = @import("builtin");
pub const abi = @import("bedrock64");
pub const network = @import("network.zig");
pub const wifi = @import("wifi.zig");
export var bedrock_user_entry_count: u64 = 0;

pub fn markEntry() void {
    const count: *volatile u64 = &bedrock_user_entry_count;
    count.* += 1;
    expect(count.* == 1);
}

/// Raw values preserve opaque tokens whose high bit is set. Use abi.isError.
pub inline fn syscall(number: u64, arg0: u64, arg1: u64, arg2: u64) u64 {
    return switch (builtin.cpu.arch) {
        .x86_64 => asm volatile ("int $0x80"
            : [result] "={rax}" (-> u64),
            : [number] "{rax}" (number),
              [arg0] "{rdi}" (arg0),
              [arg1] "{rsi}" (arg1),
              [arg2] "{rdx}" (arg2),
            : .{ .memory = true }),
        .aarch64 => asm volatile ("svc #0"
            : [result] "={x0}" (-> u64),
            : [number] "{x8}" (number),
              [arg0] "{x0}" (arg0),
              [arg1] "{x1}" (arg1),
              [arg2] "{x2}" (arg2),
            : .{ .memory = true }),
        .riscv64 => asm volatile ("ecall"
            : [result] "={a0}" (-> u64),
            : [number] "{a7}" (number),
              [arg0] "{a0}" (arg0),
              [arg1] "{a1}" (arg1),
              [arg2] "{a2}" (arg2),
            : .{ .memory = true }),
        else => @compileError("Bedrock64 supports x86_64, ARM64 and RV64"),
    };
}

// Outlined wrappers keep the first-profile native RX page bounded. They return
// raw values; callers use abi.isError before interpreting descriptors or sizes.
pub noinline fn open(path: []const u8, flags: u64) u64 {
    return syscall(abi.syscall.open, @intFromPtr(path.ptr), path.len, flags);
}

pub noinline fn read(fd: u64, output: []u8) u64 {
    return syscall(abi.syscall.read, fd, @intFromPtr(output.ptr), output.len);
}

pub noinline fn writeFd(fd: u64, input: []const u8) u64 {
    return syscall(abi.syscall.write, fd, @intFromPtr(input.ptr), input.len);
}

pub noinline fn seek(fd: u64, offset: i64, whence: u64) u64 {
    return syscall(abi.syscall.seek, fd, @bitCast(offset), whence);
}

pub noinline fn close(fd: u64) u64 {
    return syscall(abi.syscall.close, fd, 0, 0);
}

pub noinline fn spawnPath(path: []const u8, launch_arg: u64) u64 {
    return syscall(abi.syscall.spawn_path, @intFromPtr(path.ptr), path.len, launch_arg);
}

/// Failure returns errno. A successful replacement enters the new ELF image.
pub noinline fn exec(path: []const u8, launch_arg: u64) u64 {
    return syscall(abi.syscall.exec, @intFromPtr(path.ptr), path.len, launch_arg);
}

pub noinline fn pipe(pair: *abi.PipePair) u64 {
    return syscall(abi.syscall.pipe, @intFromPtr(pair), 0, 0);
}

pub noinline fn dup(fd: u64, retained_rights: u64) u64 {
    return syscall(abi.syscall.dup, fd, retained_rights, 0);
}

pub noinline fn spawnPipe(path: []const u8, writer: u64) u64 {
    return syscall(abi.syscall.spawn_pipe, @intFromPtr(path.ptr), path.len, writer);
}

pub fn exit(status: u64) noreturn {
    _ = syscall(abi.syscall.exit, status, 0, 0);
    while (true) {
        switch (builtin.cpu.arch) {
            .x86_64 => asm volatile ("ud2"),
            .aarch64 => asm volatile ("brk #0"),
            .riscv64 => asm volatile ("ebreak"),
            else => unreachable,
        }
    }
}

pub fn expect(condition: bool) void {
    if (!condition) exit(99);
}

pub fn success(value: u64) u64 {
    expect(!abi.isError(value));
    return value;
}

pub fn write(text: []const u8) void {
    expect(writeFd(1, text) == text.len);
}

pub fn panic(_: []const u8, _: ?usize) noreturn {
    exit(99);
}

/// Destroy the user stack before suspending. There is no stack use afterward.
pub fn invalidStack() noreturn {
    switch (builtin.cpu.arch) {
        .x86_64 => asm volatile (
            \\xor %esp, %esp
            \\int $0x80
            \\ud2
            :
            : [number] "{rax}" (abi.syscall.yield),
              [arg0] "{rdi}" (@as(u64, 0)),
              [arg1] "{rsi}" (@as(u64, 0)),
              [arg2] "{rdx}" (@as(u64, 0)),
            : .{ .memory = true }),
        .aarch64 => asm volatile (
            \\mov sp, x0
            \\svc #0
            \\brk #0
            :
            : [number] "{x8}" (abi.syscall.yield),
              [arg0] "{x0}" (@as(u64, 0)),
              [arg1] "{x1}" (@as(u64, 0)),
              [arg2] "{x2}" (@as(u64, 0)),
            : .{ .memory = true }),
        .riscv64 => asm volatile (
            \\mv sp, zero
            \\ecall
            \\ebreak
            :
            : [number] "{a7}" (abi.syscall.yield),
              [arg0] "{a0}" (@as(u64, 0)),
              [arg1] "{a1}" (@as(u64, 0)),
              [arg2] "{a2}" (@as(u64, 0)),
            : .{ .memory = true }),
        else => unreachable,
    }
    unreachable;
}

/// Execute getpid at the final code instruction; return lands on the NX page.
pub fn boundaryReturn() noreturn {
    switch (builtin.cpu.arch) {
        .x86_64 => asm volatile ("jmp bedrock_user_boundary"
            :
            : [number] "{rax}" (abi.syscall.getpid),
              [arg0] "{rdi}" (@as(u64, 0)),
              [arg1] "{rsi}" (@as(u64, 0)),
              [arg2] "{rdx}" (@as(u64, 0)),
            : .{ .memory = true }),
        .aarch64 => asm volatile ("b bedrock_user_boundary"
            :
            : [number] "{x8}" (abi.syscall.getpid),
              [arg0] "{x0}" (@as(u64, 0)),
              [arg1] "{x1}" (@as(u64, 0)),
              [arg2] "{x2}" (@as(u64, 0)),
            : .{ .memory = true }),
        .riscv64 => asm volatile ("j bedrock_user_boundary"
            :
            : [number] "{a7}" (abi.syscall.getpid),
              [arg0] "{a0}" (@as(u64, 0)),
              [arg1] "{a1}" (@as(u64, 0)),
              [arg2] "{a2}" (@as(u64, 0)),
            : .{ .memory = true }),
        else => unreachable,
    }
    unreachable;
}

/// Emit an actual architectural null load, never a compiler-generated trap.
pub fn invalidRead() noreturn {
    _ = switch (builtin.cpu.arch) {
        .x86_64 => asm volatile ("movq (%[address]), %[value]"
            : [value] "=r" (-> u64),
            : [address] "r" (@as(u64, 0)),
            : .{ .memory = true }),
        .aarch64 => asm volatile ("ldr %[value], [%[address]]"
            : [value] "=r" (-> u64),
            : [address] "r" (@as(u64, 0)),
            : .{ .memory = true }),
        .riscv64 => asm volatile ("ld %[value], 0(%[address])"
            : [value] "=r" (-> u64),
            : [address] "r" (@as(u64, 0)),
            : .{ .memory = true }),
        else => unreachable,
    };
    exit(99);
}
