//! First native init: process lifecycle, attenuated IPC and scheduler calls.
const std = @import("std");
const runtime = @import("userspace_runtime");
const abi = @import("bedrock64");
pub const panic = std.debug.FullPanic(runtime.panic);

export fn bedrock_user_main(parent_pid: u64, inherited_endpoint: u64, launch_arg: u64) callconv(.c) noreturn {
    runtime.markEntry();
    runtime.expect(parent_pid == 0 and inherited_endpoint == 0 and launch_arg <= 0x3ffff);
    const pid = runtime.success(runtime.syscall(abi.syscall.getpid, 0, 0, 0));
    runtime.expect(pid != 0);
    const channel = runtime.success(runtime.syscall(abi.syscall.ipc_create, 0, 0, 0));
    runtime.expect(channel != 0);
    var payload: u64 = abi.test_payload;
    const pointer = @intFromPtr(&payload);
    runtime.expect(runtime.syscall(0xffff, 0, 0, 0) == abi.errno.unknown);
    runtime.expect(runtime.syscall(abi.syscall.write, 1, 0, 8) == abi.errno.fault);
    runtime.expect(runtime.syscall(abi.syscall.ipc_receive, channel, abi.code, 24) == abi.errno.fault);
    runtime.expect(runtime.syscall(abi.syscall.ipc_send, channel, pointer, abi.max_payload + 1) == abi.errno.message_size);
    runtime.expect(runtime.syscall(abi.syscall.spawn, 0xffff, 0, 0) == abi.errno.invalid);

    const service = runtime.success(runtime.syscall(abi.syscall.spawn, abi.image.service, channel, abi.receive_right));
    runtime.expect(service != 0 and service != pid);
    // Service reaches receive before this message exists and blocks there.
    runtime.expect(runtime.syscall(abi.syscall.yield, 0, 0, 0) == 0);
    // After receiving one, the service sleeps while five more fill four slots.
    for (0..6) |_| runtime.expect(runtime.syscall(abi.syscall.ipc_send, channel, pointer, 8) == 8);
    // Remain runnable until two real timer ticks advance while yielding.
    const start = runtime.success(runtime.syscall(abi.syscall.clock_ticks, 0, 0, 0));
    runtime.expect(start <= std.math.maxInt(u64) - 2);
    var yields: usize = 0;
    while (runtime.success(runtime.syscall(abi.syscall.clock_ticks, 0, 0, 0)) < start + 2) {
        runtime.expect(yields < 2048);
        var count: u64 = 0;
        const observed: *volatile u64 = &count;
        for (0..4096) |_| observed.* += 1;
        runtime.expect(observed.* == 4096);
        runtime.expect(runtime.syscall(abi.syscall.yield, 0, 0, 0) == 0);
        yields += 1;
    }
    runtime.expect(runtime.syscall(abi.syscall.wait, service, 0, 0) == 42);

    const fault = runtime.success(runtime.syscall(abi.syscall.spawn, abi.image.fault, 0, 0));
    runtime.expect(fault != 0 and fault != pid and fault != service);
    runtime.expect(runtime.syscall(abi.syscall.wait, fault, 0, 0) == abi.fault_exit_status);
    for ([_]u64{ abi.image.fault_stack, abi.image.fault_boundary }) |image| {
        const adversary = runtime.success(runtime.syscall(abi.syscall.spawn, image, 0, 0));
        runtime.expect(adversary != 0 and adversary != pid);
        runtime.expect(runtime.syscall(abi.syscall.wait, adversary, 0, 0) == abi.fault_exit_status);
    }
    // With no other live user task, the kernel must still advance timer ticks.
    runtime.expect(runtime.syscall(abi.syscall.sleep, 2, 0, 0) == 0);
    runtime.expect(runtime.syscall(abi.syscall.yield, 0, 0, 0) == 0);
    runtime.expect(runtime.syscall(abi.syscall.close, channel, 0, 0) == 0);
    runtime.expect(runtime.syscall(abi.syscall.close, channel, 0, 0) == abi.errno.bad_descriptor);
    runtime.expect(runtime.syscall(abi.syscall.ipc_send, channel, pointer, 8) == abi.errno.bad_descriptor);
    const io = runtime.success(runtime.spawnPath("/bundle/io.elf", 0));
    runtime.expect(io != 0 and io != pid);
    runtime.expect(runtime.syscall(abi.syscall.wait, io, 0, 0) == 43);
    if (launch_arg & 0xffff != 0) {
        const network = runtime.success(runtime.spawnPath("/bundle/network.elf", launch_arg & 0xffff));
        runtime.expect(network != 0 and network != pid);
        runtime.expect(runtime.syscall(abi.syscall.wait, network, 0, 0) == 44);
    }
    if (launch_arg & 0x30000 != 0) {
        const wifi = runtime.success(runtime.spawnPath("/bundle/wifi.elf", if (launch_arg & 0x20000 != 0) 1 else 0));
        runtime.expect(wifi != 0 and wifi != pid);
        runtime.expect(runtime.syscall(abi.syscall.wait, wifi, 0, 0) == 45);
    }
    runtime.write("[user] init lifecycle verified\n");
    runtime.exit(0);
}
