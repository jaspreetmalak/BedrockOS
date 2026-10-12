//! Separately linked native service and fault executables from one small source.
const std = @import("std");
const runtime = @import("userspace_runtime");
const abi = @import("bedrock64");
const options = @import("program_options");
pub const panic = std.debug.FullPanic(runtime.panic);
const Packet = extern struct { header: abi.MessageHeader, payload: u64 };

export fn bedrock_user_main(parent_pid: u64, inherited_endpoint: u64, launch_arg: u64) callconv(.c) noreturn {
    runtime.markEntry();
    runtime.expect(parent_pid != 0);
    if (comptime options.role == .fault) {
        runtime.expect(inherited_endpoint == 0);
        switch (launch_arg) {
            0 => {
                runtime.expect(runtime.syscall(abi.syscall.sleep, 1, 0, 0) == 0);
                runtime.invalidRead();
            },
            abi.image.fault_stack => runtime.invalidStack(),
            abi.image.fault_boundary => runtime.boundaryReturn(),
            else => runtime.exit(99),
        }
    } else {
        runtime.expect(launch_arg == 0);
        runtime.expect(inherited_endpoint != 0);
        const pid = runtime.success(runtime.syscall(abi.syscall.getpid, 0, 0, 0));
        runtime.expect(pid != 0 and pid != parent_pid);
        var packet: Packet = undefined;
        runtime.expect(runtime.syscall(abi.syscall.ipc_receive, inherited_endpoint, abi.code, @sizeOf(Packet)) == abi.errno.fault);
        for (0..6) |index| {
            const received = runtime.syscall(abi.syscall.ipc_receive, inherited_endpoint, @intFromPtr(&packet), @sizeOf(Packet));
            runtime.expect(received == @sizeOf(Packet));
            runtime.expect(packet.header.sender == parent_pid and packet.header.length == 8 and packet.payload == abi.test_payload);
            if (index == 0) runtime.expect(runtime.syscall(abi.syscall.sleep, 1, 0, 0) == 0);
        }
        runtime.expect(runtime.syscall(abi.syscall.ipc_send, inherited_endpoint, @intFromPtr(&packet.payload), 8) == abi.errno.permission);
        runtime.expect(runtime.syscall(abi.syscall.sleep, 1, 0, 0) == 0);
        runtime.write("[user] service ipc verified\n");
        runtime.exit(42);
    }
}
