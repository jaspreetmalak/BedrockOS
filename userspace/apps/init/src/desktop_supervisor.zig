//! Only init chooses installed identities; the compositor requests Files launches.
const std = @import("std");
const rt = @import("userspace_runtime");
const abi = @import("bedrock64");
pub const panic = std.debug.FullPanic(rt.panic);
fn logPids(server: u64, shell: u64, files: u64) void {
    var bytes: [160]u8 = undefined;
    rt.write(std.fmt.bufPrint(&bytes, "[desktop-init] pids server={x} shell={x} files={x}\n", .{ server, shell, files }) catch rt.exit(99));
}
fn drain(reader: u64, server: u64, latest: *abi.DesktopHeartbeat) void {
    while (true) {
        var next: abi.DesktopHeartbeat = undefined;
        const result = rt.read(reader, std.mem.asBytes(&next));
        if (result == abi.errno.again) return;
        rt.expect(result == @sizeOf(abi.DesktopHeartbeat) and next.server_pid == server and next.reserved == 0);
        rt.expect(next.launch_requests >= latest.launch_requests and next.shell_frames >= latest.shell_frames and
            next.files_closed >= latest.files_closed and next.configure_sequence >= latest.configure_sequence and next.presents >= latest.presents);
        if (next.files_pid == latest.files_pid and next.files_pid != 0) rt.expect(next.files_frames >= latest.files_frames);
        latest.* = next;
    }
}
fn pause() void {
    rt.expect(rt.syscall(abi.syscall.sleep, 1, 0, 0) == 0);
}
fn ready(reader: u64, server: u64, shell: u64, files: u64, frames: u64, latest: *abi.DesktopHeartbeat, acceptance: bool) void {
    var turns: usize = 0;
    while (true) {
        drain(reader, server, latest);
        if (latest.shell_pid == shell and latest.files_pid == files and latest.shell_frames >= 3 and latest.files_frames >= frames) return;
        rt.expect(!acceptance or turns < 8192);
        turns += 1;
        pause();
    }
}
export fn bedrock_user_main(parent: u64, inherited: u64, argument: u64) callconv(.c) noreturn {
    rt.markEntry();
    const info = rt.startup(parent, inherited, argument) catch rt.exit(99);
    rt.expect(parent == 0 and inherited == 0 and argument == 0 and info.app_id == abi.application.init);
    const acceptance = info.flags & abi.application.test_mode != 0;
    var pipe: abi.PipePair = undefined;
    rt.expect(rt.pipe(&pipe) == 0);
    const server = rt.success(rt.spawnApp(abi.display.server, 0, pipe.writer));
    rt.expect(rt.close(pipe.writer) == 0);
    var latest: abi.DesktopHeartbeat = std.mem.zeroes(abi.DesktopHeartbeat);
    while (latest.server_pid == 0) {
        drain(pipe.reader, server, &latest);
        pause();
    }
    const shell = rt.success(rt.spawnApp(abi.display.shell, 0, 0));
    var files = rt.success(rt.spawnApp(abi.display.files, 0, 0));
    var generation_closed = latest.files_closed;
    var launch_requests = latest.launch_requests;
    ready(pipe.reader, server, shell, files, 3, &latest, acceptance);
    generation_closed = latest.files_closed;
    launch_requests = latest.launch_requests;
    logPids(latest.server_pid, latest.shell_pid, latest.files_pid);
    rt.write("[desktop-init] protected desktop ready\n");
    rt.expect(rt.syscall(abi.syscall.desktop_ready, 0, 0, 0) == 0);
    var restart = false;
    while (true) {
        drain(pipe.reader, server, &latest);
        rt.expect(latest.shell_pid == shell);
        if (files != 0) {
            const status = rt.waitPoll(files);
            if (status != abi.errno.again) {
                rt.expect(!abi.isError(status));
                var bytes: [96]u8 = undefined;
                rt.write(std.fmt.bufPrint(&bytes, "[desktop-init] Files process reaped pid={x}\n", .{files}) catch rt.exit(99));
                restart = status != 0;
                files = 0;
            }
        }
        // A peer closure retires the compositor's last read lease before reuse.
        if (files == 0 and latest.files_pid == 0 and latest.files_closed > generation_closed and (restart or latest.launch_requests > launch_requests)) {
            generation_closed = latest.files_closed;
            launch_requests = latest.launch_requests;
            restart = false;
            files = rt.success(rt.spawnApp(abi.display.files, 0, 0));
            ready(pipe.reader, server, shell, files, 3, &latest, false);
            generation_closed = latest.files_closed;
            launch_requests = latest.launch_requests;
            logPids(latest.server_pid, latest.shell_pid, latest.files_pid);
        }
        pause();
    }
}
