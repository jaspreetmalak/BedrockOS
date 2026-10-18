//! Native Bedrock64 calls. No libc, TLS, dynamic linking or host system API.
const builtin = @import("builtin");
pub const abi = @import("bedrock64");
pub const network = @import("network.zig");
pub const wifi = @import("wifi.zig");
pub const startup_record = @import("startup.zig");
pub const Heap = @import("heap.zig").Heap;
pub const display_wire = @import("display_wire.zig");
pub const desktop_wire = @import("desktop_wire.zig");
pub const desktop_client = @import("desktop_client.zig");
pub const window_wire = @import("window_wire.zig");
pub const window_client = @import("window_client.zig");
pub const window_header = @import("window_header");
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

/// Only a trusted launcher may select an installed application's identity.
pub noinline fn spawnApp(package_id: u64, launch_arg: u64, pipe_writer: u64) u64 {
    return syscall(abi.syscall.spawn_app, package_id, launch_arg, pipe_writer);
}
pub noinline fn waitPoll(pid: u64) u64 {
    return syscall(abi.syscall.wait, pid, abi.wait_flags.nohang, 0);
}

/// Read firmware calendar time advanced by observed timer quanta. Success can
/// still report !output.isAvailable(); do not invent a time for that case.
pub noinline fn clockRead(output: *abi.ClockTime) u64 {
    return syscall(abi.syscall.clock_read, @intFromPtr(output), 0, 0);
}

pub noinline fn surfaceCreate(request: *const abi.SurfaceCreate) u64 {
    return syscall(abi.syscall.surface_create, @intFromPtr(request), 0, 0);
}
pub noinline fn surfaceMap(token: u64, slot: u64, writable: bool) u64 {
    return syscall(abi.syscall.surface_map, token, slot, @intFromBool(writable));
}
pub noinline fn surfaceUnmap(token: u64) u64 {
    return syscall(abi.syscall.surface_unmap, token, 0, 0);
}
pub noinline fn surfaceSubmit(token: u64, endpoint: u64, sequence: u64) u64 {
    return syscall(abi.syscall.surface_submit, token, endpoint, sequence);
}
pub noinline fn surfaceRelease(token: u64) u64 {
    return syscall(abi.syscall.surface_release, token, 0, 0);
}
pub noinline fn surfaceClose(token: u64) u64 {
    return syscall(abi.syscall.surface_close, token, 0, 0);
}
pub noinline fn serviceOpen(name: u64) u64 {
    return syscall(abi.syscall.service_open, name, 0, 0);
}
pub noinline fn serviceConnect(name: u64) u64 {
    return syscall(abi.syscall.service_connect, name, 0, 0);
}
pub noinline fn serviceSend(endpoint: u64, message: *const abi.ServiceMessage) u64 {
    return syscall(abi.syscall.service_send, endpoint, @intFromPtr(message), @sizeOf(abi.ServiceMessage));
}
pub noinline fn serviceReceive(endpoint: u64, message: *abi.ServiceMessage) u64 {
    return syscall(abi.syscall.service_receive, endpoint, @intFromPtr(message), @sizeOf(abi.ServiceMessage));
}
pub noinline fn serviceClose(endpoint: u64) u64 {
    return syscall(abi.syscall.service_close, endpoint, 0, 0);
}
pub noinline fn displayPresent(request: *const abi.PresentRequest) u64 {
    return syscall(abi.syscall.display_present, @intFromPtr(request), 0, 0);
}
pub noinline fn displayInfo(info: *abi.DisplayInfo) u64 {
    return syscall(abi.syscall.display_info, @intFromPtr(info), 0, 0);
}
pub noinline fn displayInput(event: *abi.DisplayInput) u64 {
    return syscall(abi.syscall.display_input, @intFromPtr(event), 0, 0);
}
pub noinline fn desktopState(state: u64) u64 {
    return syscall(abi.syscall.desktop_state, state, 0, 0);
}

pub noinline fn windowState(state: u64, app_id: u64, auxiliary: u64) u64 {
    return syscall(abi.syscall.window_state, state, app_id, auxiliary);
}

/// Installed programs read a kernel-authored RO/NX startup page. Legacy
/// fixture programs receive errno.not_supported from startup_info.
pub fn startup(parent: u64, inherited_token: u64, launch_arg: u64) startup_record.Error!*const abi.Startup {
    const address = syscall(abi.syscall.startup_info, 0, 0, 0);
    if (address != abi.application.startup_address) return error.InvalidStartupHeader;
    const result: *const abi.Startup = @ptrFromInt(address);
    try startup_record.validateEntry(result, parent, inherited_token, launch_arg);
    return result;
}

/// Call only after validating Startup. This lease belongs to this process and
/// is reclaimed by the kernel on exit, fault or successful exec.
pub fn appHeap(info: *const abi.Startup) Heap {
    const bytes: [*]u8 = @ptrFromInt(info.heap_base);
    return Heap.init(bytes[0..@intCast(info.heap_length)]);
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
    invalidReadAt(0);
}

/// Used by protected resource tests to access an explicitly revoked mapping.
pub fn invalidReadAt(address: u64) noreturn {
    _ = switch (builtin.cpu.arch) {
        .x86_64 => asm volatile ("movq (%[address]), %[value]"
            : [value] "=r" (-> u64),
            : [address] "r" (address),
            : .{ .memory = true }),
        .aarch64 => asm volatile ("ldr %[value], [%[address]]"
            : [value] "=r" (-> u64),
            : [address] "r" (address),
            : .{ .memory = true }),
        .riscv64 => asm volatile ("ld %[value], 0(%[address])"
            : [value] "=r" (-> u64),
            : [address] "r" (address),
            : .{ .memory = true }),
        else => unreachable,
    };
    exit(99);
}
