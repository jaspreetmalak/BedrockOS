//! Persistent installed-application init. Acceptance uses this same supervisor.
const std = @import("std");
const runtime = @import("userspace_runtime");
const abi = @import("bedrock64");
pub const panic = std.debug.FullPanic(runtime.panic);
const Heartbeat = extern struct { pid: u64, sequence: u64 };

fn drain(reader: u64, observer: u64, previous: *u64) void {
    var heartbeat: Heartbeat = undefined;
    while (true) {
        const got = runtime.read(reader, std.mem.asBytes(&heartbeat));
        if (got == abi.errno.again) return;
        runtime.expect(got == @sizeOf(Heartbeat));
        runtime.expect(heartbeat.pid == observer and heartbeat.sequence > previous.*);
        previous.* = heartbeat.sequence;
    }
}

export fn bedrock_user_main(parent: u64, inherited: u64, argument: u64) callconv(.c) noreturn {
    runtime.markEntry();
    const info = runtime.startup(parent, inherited, argument) catch runtime.exit(99);
    runtime.expect(parent == 0 and inherited == 0 and info.app_id == abi.application.init);
    runtime.expect(std.mem.eql(u8, runtime.startup_record.argument(info, 0) orelse "", "org.bedrock.init"));
    runtime.expect(runtime.syscall(abi.syscall.getpid, 0, 0, 0) == info.pid);
    runtime.expect(std.mem.eql(u8, runtime.startup_record.environment(info, "BEDROCK_ROLE") orelse "", "init"));
    var heap = runtime.appHeap(info);
    const allocator = heap.allocator();
    const scratch = allocator.alloc(u8, 128) catch runtime.exit(99);
    @memset(scratch, 0x61);
    allocator.free(scratch);
    runtime.expect(heap.liveCount() == 0);

    var pair: abi.PipePair = undefined;
    runtime.expect(runtime.pipe(&pair) == 0);
    const observer = runtime.success(runtime.spawnApp(abi.application.observer, 0, pair.writer));
    runtime.expect(observer != info.pid and observer != 0);
    runtime.expect(runtime.close(pair.writer) == 0);
    var last_heartbeat: u64 = 0;
    const acceptance = info.flags & abi.application.test_mode != 0;
    var startup_ticks: usize = 0;
    // The first heartbeat follows Observer's heap/file initialization. Its
    // held descriptor must exist before a worker cleanup baseline is captured.
    while (last_heartbeat == 0) {
        drain(pair.reader, observer, &last_heartbeat);
        if (last_heartbeat != 0) break;
        runtime.expect(!acceptance or startup_ticks < 64);
        runtime.expect(runtime.syscall(abi.syscall.sleep, 1, 0, 0) == 0);
        startup_ticks += 1;
    }
    const rounds: usize = if (acceptance) 3 else 1;
    for (0..rounds) |_| {
        const faulting = runtime.success(runtime.spawnApp(abi.application.worker, 1, 0));
        runtime.expect(faulting != observer);
        runtime.expect(runtime.syscall(abi.syscall.wait, faulting, 0, 0) == abi.fault_exit_status);
        drain(pair.reader, observer, &last_heartbeat);
        const restarted = runtime.success(runtime.spawnApp(abi.application.worker, 2, 0));
        runtime.expect(restarted != faulting and restarted != observer);
        runtime.expect(runtime.syscall(abi.syscall.wait, restarted, 0, 0) == 23);
        runtime.expect(runtime.syscall(abi.syscall.sleep, 2, 0, 0) == 0);
        drain(pair.reader, observer, &last_heartbeat);
    }
    runtime.expect(last_heartbeat >= rounds);
    var worker = runtime.success(runtime.spawnApp(abi.application.worker, 0, 0));
    runtime.expect(runtime.syscall(abi.syscall.sleep, 2, 0, 0) == 0);
    drain(pair.reader, observer, &last_heartbeat);
    runtime.write("[app] init supervision verified\n");
    runtime.expect(runtime.syscall(abi.syscall.application_ready, 0, 0, 0) == 0);
    // Keep init alive. A later worker failure gets a fresh identity-preserving
    // process and heap; backoff prevents a broken package spinning on restart.
    while (true) {
        _ = runtime.success(runtime.syscall(abi.syscall.wait, worker, 0, 0));
        runtime.expect(runtime.syscall(abi.syscall.sleep, 10, 0, 0) == 0);
        drain(pair.reader, observer, &last_heartbeat);
        worker = runtime.success(runtime.spawnApp(abi.application.worker, 0, 0));
    }
}
