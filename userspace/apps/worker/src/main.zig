//! An installed worker whose crash leaves persistent state, never live pages.
const builtin = @import("builtin");
const std = @import("std");
const runtime = @import("userspace_runtime");
const abi = @import("bedrock64");
pub const panic = std.debug.FullPanic(runtime.panic);
const state_path = "/container/session.txt";
export var bedrock_worker_state: [8192]u8 = @splat(0);

fn startupWrite(info: *const abi.Startup) noreturn {
    const address = @intFromPtr(info);
    switch (builtin.cpu.arch) {
        .x86_64 => asm volatile ("movb $1, (%[address])"
            :
            : [address] "r" (address),
            : .{ .memory = true }),
        .aarch64 => asm volatile ("strb wzr, [%[address]]"
            :
            : [address] "r" (address),
            : .{ .memory = true }),
        .riscv64 => asm volatile ("sb zero, 0(%[address])"
            :
            : [address] "r" (address),
            : .{ .memory = true }),
        else => unreachable,
    }
    runtime.exit(99);
}

export fn bedrock_user_main(parent: u64, inherited: u64, argument: u64) callconv(.c) noreturn {
    runtime.markEntry();
    const info = runtime.startup(parent, inherited, argument) catch runtime.exit(99);
    runtime.expect(parent != 0 and inherited == 0 and argument <= 2 and info.app_id == abi.application.worker);
    runtime.expect(std.mem.eql(u8, runtime.startup_record.argument(info, 0) orelse "", "org.bedrock.worker"));
    runtime.expect(std.mem.eql(u8, runtime.startup_record.environment(info, "BEDROCK_ROLE") orelse "", "worker"));
    runtime.expect(runtime.syscall(abi.syscall.getpid, 0, 0, 0) == info.pid);
    runtime.expect(runtime.spawnApp(abi.application.observer, 0, 0) == abi.errno.permission);
    runtime.expect(runtime.spawnApp(0xffff, 0, 0) == abi.errno.permission);
    runtime.expect(runtime.syscall(abi.syscall.application_ready, 0, 0, 0) == abi.errno.permission);
    runtime.expect(runtime.open("/bundle/main.elf", abi.open_flags.write) == abi.errno.permission);
    runtime.expect(runtime.open("/private/102/container/session.txt", abi.open_flags.read) == abi.errno.permission);
    const udp: abi.UdpConnect = .{ .address = .{ 127, 0, 0, 1 }, .port = 7 };
    runtime.expect(runtime.syscall(abi.syscall.udp_open, @intFromPtr(&udp), 0, 0) == abi.errno.permission);
    const state: *volatile [8192]u8 = &bedrock_worker_state;
    for (0..state.len) |i| runtime.expect(state.*[i] == 0);
    state.*[state.len - 1] = 0x77;
    var heap = runtime.appHeap(info);
    const allocator = heap.allocator();
    const lease = allocator.alloc(u8, 8192) catch runtime.exit(99);
    for (lease) |byte| runtime.expect(byte == 0);
    @memset(lease, 0x77);
    // Exhaustion changes no existing allocation and frees restore usable space.
    runtime.expect(if (allocator.alloc(u8, @intCast(info.heap_length))) |unexpected| blk: {
        allocator.free(unexpected);
        break :blk false;
    } else |_| true);
    runtime.expect(heap.usedBytes() == lease.len);

    if (argument == 1) {
        const file = runtime.success(runtime.open(state_path, abi.open_flags.read | abi.open_flags.write | abi.open_flags.create | abi.open_flags.truncate));
        runtime.expect(runtime.writeFd(file, "FAULTED") == 7);
        runtime.expect(runtime.syscall(abi.syscall.sleep, 1, 0, 0) == 0);
        runtime.write("[app] worker fault requested\n");
        // Leave the file and allocation live: the kernel owns their teardown.
        startupWrite(info);
    }
    const file = runtime.success(runtime.open(state_path, abi.open_flags.read | abi.open_flags.write));
    runtime.expect(runtime.read(file, lease[0..7]) == 7);
    runtime.expect(std.mem.eql(u8, lease[0..7], "FAULTED") or
        (argument == 0 and std.mem.eql(u8, lease[0..7], "RUNNING")));
    runtime.expect(runtime.seek(file, 0, abi.seek_whence.set) == 0);
    runtime.expect(runtime.writeFd(file, "RUNNING") == 7);
    runtime.expect(state.*[state.len - 1] == 0x77);
    if (argument == 2) {
        allocator.free(lease);
        runtime.expect(heap.liveCount() == 0 and runtime.close(file) == 0);
        runtime.expect(runtime.syscall(abi.syscall.sleep, 2, 0, 0) == 0);
        runtime.write("[app] worker restart verified\n");
        runtime.exit(23);
    }
    runtime.write("[app] worker running\n");
    while (true) {
        runtime.expect(state.*[state.len - 1] == 0x77 and heap.liveCount() == 1);
        runtime.expect(runtime.syscall(abi.syscall.sleep, 10, 0, 0) == 0);
    }
}
