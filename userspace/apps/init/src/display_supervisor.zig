//! The installed display supervisor uses the shared process runtime and pipe.
const std = @import("std");
const runtime = @import("userspace_runtime");
const abi = @import("bedrock64");
pub const panic = std.debug.FullPanic(runtime.panic);
const Heartbeat = extern struct { server_pid: u64, frames_a: u64, frames_b: u64, closed_a: u64, presents: u64 };
fn drain(reader: u64, server: u64, latest: *Heartbeat) void {
    while (true) {
        var next: Heartbeat = undefined;
        const result = runtime.read(reader, std.mem.asBytes(&next));
        if (result == abi.errno.again) return;
        runtime.expect(result == @sizeOf(Heartbeat) and next.server_pid == server);
        runtime.expect(next.frames_a >= latest.frames_a and next.frames_b >= latest.frames_b and next.closed_a >= latest.closed_a and next.presents >= latest.presents);
        latest.* = next;
    }
}
fn waitProgress(reader: u64, server: u64, latest: *Heartbeat, closed: u64, frames_b: u64, frames_a: u64, acceptance: bool) void {
    var turns: usize = 0;
    while (latest.server_pid == 0 or latest.closed_a < closed or latest.frames_b < frames_b or latest.frames_a < frames_a) {
        drain(reader, server, latest);
        if (latest.server_pid != 0 and latest.closed_a >= closed and latest.frames_b >= frames_b and latest.frames_a >= frames_a) break;
        runtime.expect(!acceptance or turns < 1024);
        turns += 1;
        runtime.expect(runtime.syscall(abi.syscall.sleep, 1, 0, 0) == 0);
    }
}
export fn bedrock_user_main(parent: u64, inherited: u64, argument: u64) callconv(.c) noreturn {
    runtime.markEntry();
    const info = runtime.startup(parent, inherited, argument) catch runtime.exit(99);
    runtime.expect(parent == 0 and inherited == 0 and info.app_id == abi.application.init);
    const acceptance = info.flags & abi.application.test_mode != 0;
    var pair: abi.PipePair = undefined;
    runtime.expect(runtime.pipe(&pair) == 0);
    const server = runtime.success(runtime.spawnApp(abi.display.server, 0, pair.writer));
    runtime.expect(runtime.close(pair.writer) == 0);
    var latest: Heartbeat = .{ .server_pid = 0, .frames_a = 0, .frames_b = 0, .closed_a = 0, .presents = 0 };
    waitProgress(pair.reader, server, &latest, 0, 0, 0, acceptance);
    const stable = runtime.success(runtime.spawnApp(abi.display.client_b, 0, 0));
    runtime.expect(stable != server);
    waitProgress(pair.reader, server, &latest, 0, 3, 0, acceptance);
    var closed: u64 = 0;
    const cycles: usize = if (acceptance) 3 else 1;
    for (0..cycles) |_| {
        var before = latest.frames_b;
        const faulted = runtime.success(runtime.spawnApp(abi.display.client_a, 1, 0));
        runtime.expect(runtime.syscall(abi.syscall.wait, faulted, 0, 0) == abi.fault_exit_status);
        closed += 1;
        waitProgress(pair.reader, server, &latest, closed, before + 1, 0, acceptance);
        before = latest.frames_b;
        const restarted = runtime.success(runtime.spawnApp(abi.display.client_a, 2, 0));
        runtime.expect(restarted != faulted);
        runtime.expect(runtime.syscall(abi.syscall.wait, restarted, 0, 0) == 23);
        closed += 1;
        waitProgress(pair.reader, server, &latest, closed, before + 1, 0, acceptance);
    }
    const before_a = latest.frames_a;
    const before_b = latest.frames_b;
    var client = runtime.success(runtime.spawnApp(abi.display.client_a, 0, 0));
    waitProgress(pair.reader, server, &latest, closed, before_b + 1, before_a + 3, acceptance);
    runtime.write("[display-init] two surfaces and client survival verified\n");
    runtime.expect(runtime.syscall(abi.syscall.display_ready, 0, 0, 0) == 0);
    while (true) {
        _ = runtime.success(runtime.syscall(abi.syscall.wait, client, 0, 0));
        closed += 1;
        waitProgress(pair.reader, server, &latest, closed, latest.frames_b + 1, 0, false);
        client = runtime.success(runtime.spawnApp(abi.display.client_a, 0, 0));
    }
}
