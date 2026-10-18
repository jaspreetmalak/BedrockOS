//! An independently sandboxed, persistent application that watches its state.
const std = @import("std");
const runtime = @import("userspace_runtime");
const abi = @import("bedrock64");
pub const panic = std.debug.FullPanic(runtime.panic);
const Heartbeat = extern struct { pid: u64, sequence: u64 };
const state_path = "/container/session.txt";
export var bedrock_observer_state: [8192]u8 = @splat(0);

export fn bedrock_user_main(parent: u64, inherited: u64, argument: u64) callconv(.c) noreturn {
    runtime.markEntry();
    const info = runtime.startup(parent, inherited, argument) catch runtime.exit(99);
    runtime.expect(parent != 0 and inherited != 0 and argument == 0 and info.app_id == abi.application.observer);
    runtime.expect(std.mem.eql(u8, runtime.startup_record.argument(info, 0) orelse "", "org.bedrock.observer"));
    runtime.expect(std.mem.eql(u8, runtime.startup_record.environment(info, "BEDROCK_ROLE") orelse "", "observer"));
    runtime.expect(runtime.syscall(abi.syscall.getpid, 0, 0, 0) == info.pid);
    runtime.expect(runtime.spawnApp(abi.application.worker, 0, 0) == abi.errno.permission);
    runtime.expect(runtime.spawnApp(0xffff, 0, 0) == abi.errno.permission);
    runtime.expect(runtime.syscall(abi.syscall.application_ready, 0, 0, 0) == abi.errno.permission);
    runtime.expect(runtime.open("/bundle/main.elf", abi.open_flags.write) == abi.errno.permission);
    runtime.expect(runtime.open("/private/103/container/session.txt", abi.open_flags.read) == abi.errno.permission);
    const udp: abi.UdpConnect = .{ .address = .{ 127, 0, 0, 1 }, .port = 7 };
    runtime.expect(runtime.syscall(abi.syscall.udp_open, @intFromPtr(&udp), 0, 0) == abi.errno.permission);
    const state: *volatile [8192]u8 = &bedrock_observer_state;
    for (0..state.len) |i| runtime.expect(state.*[i] == 0);
    state.*[state.len - 1] = 0x72;
    var heap = runtime.appHeap(info);
    const allocator = heap.allocator();
    const retained = allocator.alloc(u8, 8192) catch runtime.exit(99);
    for (retained) |byte| runtime.expect(byte == 0);
    @memset(retained, 0x6f);
    const temporary = allocator.alloc(u8, 8192) catch runtime.exit(99);
    allocator.free(temporary);
    const replacement = allocator.alloc(u8, 8192) catch runtime.exit(99);
    runtime.expect(replacement.ptr == temporary.ptr and retained.ptr != replacement.ptr);
    allocator.free(replacement);

    const file = runtime.success(runtime.open(state_path, abi.open_flags.read | abi.open_flags.write | abi.open_flags.create | abi.open_flags.truncate));
    runtime.expect(runtime.writeFd(file, "OBSERVER") == 8);
    var heartbeat: Heartbeat = .{ .pid = info.pid, .sequence = 1 };
    runtime.write("[app] observer ready\n");
    while (true) {
        runtime.expect(runtime.seek(file, 0, abi.seek_whence.set) == 0);
        runtime.expect(runtime.read(file, retained[0..8]) == 8);
        runtime.expect(std.mem.eql(u8, retained[0..8], "OBSERVER"));
        runtime.expect(state.*[state.len - 1] == 0x72 and heap.liveCount() == 1);
        const sent = runtime.writeFd(inherited, std.mem.asBytes(&heartbeat));
        if (sent == @sizeOf(Heartbeat)) heartbeat.sequence += 1 else runtime.expect(sent == abi.errno.again);
        runtime.expect(runtime.syscall(abi.syscall.sleep, 1, 0, 0) == 0);
    }
}
