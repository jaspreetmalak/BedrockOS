//! Same-PID executable replacement and explicitly inherited pipe peer.
const std = @import("std");
const runtime = @import("userspace_runtime");
const abi = @import("bedrock64");
pub const panic = std.debug.FullPanic(runtime.panic);

export fn bedrock_user_main(parent_pid: u64, inherited_writer: u64, launch_arg: u64) callconv(.c) noreturn {
    runtime.markEntry();
    runtime.expect(parent_pid != 0);
    const pid = runtime.success(runtime.syscall(abi.syscall.getpid, 0, 0, 0));
    if (inherited_writer != 0) {
        runtime.expect(launch_arg == 0 and inherited_writer & abi.fd_tag_pipe != 0);
        var payload: u64 = abi.test_payload;
        runtime.expect(runtime.writeFd(inherited_writer, std.mem.asBytes(&payload)) == 8);
        runtime.expect(runtime.close(inherited_writer) == 0);
        runtime.exit(44);
    }
    runtime.expect(pid == launch_arg);
    runtime.write("[user] same pid exec verified\n");
    runtime.exit(43);
}
