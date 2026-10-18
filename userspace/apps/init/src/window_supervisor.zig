//! Init owns installed identities and supervises the two native window clients.
const std = @import("std");
const rt = @import("userspace_runtime");
const abi = @import("bedrock64");
pub const panic = std.debug.FullPanic(rt.panic);
const Child = struct {
    app_id: u64,
    name: []const u8,
    pid: u64 = 0,
    closed_generation: u64 = 0,
    launch_generation: u64 = 0,
    restart: bool = false,
    startup_pending: bool = false,
    startup_turns: usize = 0,
    fn observedPid(self: *const Child, heartbeat: *const abi.WindowHeartbeat) u64 {
        return if (self.app_id == abi.display.files) heartbeat.files_pid else heartbeat.notes_pid;
    }
    fn frames(self: *const Child, heartbeat: *const abi.WindowHeartbeat) u64 {
        return if (self.app_id == abi.display.files) heartbeat.files_frames else heartbeat.notes_frames;
    }
    fn closed(self: *const Child, heartbeat: *const abi.WindowHeartbeat) u64 {
        return if (self.app_id == abi.display.files) heartbeat.files_closed else heartbeat.notes_closed;
    }
    fn launches(self: *const Child, heartbeat: *const abi.WindowHeartbeat) u64 {
        return if (self.app_id == abi.display.files) heartbeat.files_launch_requests else heartbeat.notes_launch_requests;
    }
    fn ready(self: *const Child, heartbeat: *const abi.WindowHeartbeat) bool {
        return self.pid != 0 and self.observedPid(heartbeat) == self.pid and self.frames(heartbeat) >= 3;
    }
    fn reaped(self: *Child, status: u64) void {
        self.restart = status != 0;
        self.pid = 0;
        self.startup_pending = false;
    }
    fn mayLaunch(self: *const Child, heartbeat: *const abi.WindowHeartbeat) bool {
        return self.pid == 0 and self.observedPid(heartbeat) == 0 and self.closed(heartbeat) > self.closed_generation and
            (self.restart or self.launches(heartbeat) > self.launch_generation);
    }
    fn launched(self: *Child, pid: u64, heartbeat: *const abi.WindowHeartbeat, check_progress: bool) void {
        self.pid = pid;
        self.closed_generation = self.closed(heartbeat);
        self.launch_generation = self.launches(heartbeat);
        self.restart = false;
        self.startup_pending = check_progress;
        self.startup_turns = 0;
    }
};
fn logPids(server: u64, shell: u64, children: *const [2]Child) void {
    var bytes: [176]u8 = undefined;
    rt.write(std.fmt.bufPrint(&bytes, "[window-init] pids server={d} shell={d} files={d} notes={d}\n", .{ server, shell, children[0].pid, children[1].pid }) catch rt.exit(99));
}
fn drain(reader: u64, server: u64, latest: *abi.WindowHeartbeat) void {
    while (true) {
        var next: abi.WindowHeartbeat = undefined;
        const result = rt.read(reader, std.mem.asBytes(&next));
        if (result == abi.errno.again) return;
        rt.expect(result == @sizeOf(abi.WindowHeartbeat) and next.server_pid == server and next.reserved == 0 and next.workspace < 4 and next.tiled <= 1);
        rt.expect(next.shell_frames >= latest.shell_frames and next.files_closed >= latest.files_closed and next.notes_closed >= latest.notes_closed and
            next.files_launch_requests >= latest.files_launch_requests and next.notes_launch_requests >= latest.notes_launch_requests and
            next.configure_sequence >= latest.configure_sequence and next.presents >= latest.presents);
        if (next.files_pid == latest.files_pid and next.files_pid != 0) rt.expect(next.files_frames >= latest.files_frames);
        if (next.notes_pid == latest.notes_pid and next.notes_pid != 0) rt.expect(next.notes_frames >= latest.notes_frames);
        latest.* = next;
    }
}
fn pause() void {
    rt.expect(rt.syscall(abi.syscall.sleep, 1, 0, 0) == 0);
}
fn requireAlive(pid: u64) void {
    rt.expect(rt.waitPoll(pid) == abi.errno.again);
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
    var latest: abi.WindowHeartbeat = .{};
    var startup_turns: usize = 0;
    while (latest.server_pid == 0) {
        drain(pipe.reader, server, &latest);
        requireAlive(server);
        rt.expect(!acceptance or startup_turns < 8192);
        startup_turns += 1;
        pause();
    }
    const shell = rt.success(rt.spawnApp(abi.display.shell, 0, 0));
    var children = [_]Child{
        .{ .app_id = abi.display.files, .name = "Files" },
        .{ .app_id = abi.display.notes, .name = "Notes" },
    };
    for (&children) |*child| {
        child.launched(rt.success(rt.spawnApp(child.app_id, 0, 0)), &latest, false);
    }
    startup_turns = 0;
    var reported_ready = false;
    while (true) {
        drain(pipe.reader, server, &latest);
        requireAlive(server);
        requireAlive(shell);
        rt.expect(latest.shell_pid == shell or (!reported_ready and latest.shell_pid == 0));
        for (&children) |*child| {
            if (child.pid != 0) {
                const status = rt.waitPoll(child.pid);
                if (status != abi.errno.again) {
                    rt.expect(!abi.isError(status));
                    var bytes: [176]u8 = undefined;
                    rt.write(std.fmt.bufPrint(&bytes, "[window-init] {s} process reaped pid={d} status={d}\n", .{ child.name, child.pid, status }) catch rt.exit(99));
                    child.reaped(status);
                } else {
                    if (child.startup_pending) {
                        if (child.ready(&latest)) {
                            child.startup_pending = false;
                            var bytes: [112]u8 = undefined;
                            rt.write(std.fmt.bufPrint(&bytes, "[window-init] {s} restarted pid={d}\n", .{ child.name, child.pid }) catch rt.exit(99));
                            logPids(server, shell, &children);
                        } else {
                            rt.expect(!acceptance or child.startup_turns < 8192);
                            child.startup_turns += 1;
                        }
                    }
                }
            }
            // The service must retire the dead client's immutable grant first.
            if (child.mayLaunch(&latest)) {
                // Consume requests only when a spawn commits. A request sent
                // while the old child closes must survive its later reap.
                child.launched(rt.success(rt.spawnApp(child.app_id, 0, 0)), &latest, true);
            }
        }
        if (!reported_ready) {
            if (latest.shell_pid == shell and latest.shell_frames >= 3 and children[0].ready(&latest) and children[1].ready(&latest)) {
                logPids(server, shell, &children);
                rt.write("[window-init] protected windows ready\n");
                rt.expect(rt.syscall(abi.syscall.window_ready, 0, 0, 0) == 0);
                reported_ready = true;
            } else if (children[0].pid != 0 and children[1].pid != 0) {
                rt.expect(!acceptance or startup_turns < 8192);
                startup_turns += 1;
            } else {
                // An early clean close leaves the shell usable while waiting
                // for a fresh launch; waiting for the user is not a stall.
                startup_turns = 0;
            }
        }
        pause();
    }
}

test "initial clean close waits for a launcher and readiness follows replacement frames" {
    var child: Child = .{ .app_id = abi.display.notes, .name = "Notes" };
    var heartbeat: abi.WindowHeartbeat = .{};
    child.launched(10, &heartbeat, false);
    try std.testing.expect(!child.ready(&heartbeat));
    child.reaped(0);
    heartbeat.notes_closed = 1;
    try std.testing.expect(!child.mayLaunch(&heartbeat));
    heartbeat.notes_launch_requests = 1;
    try std.testing.expect(child.mayLaunch(&heartbeat));
    child.launched(20, &heartbeat, true);
    heartbeat.notes_pid = 20;
    heartbeat.notes_frames = 2;
    try std.testing.expect(!child.ready(&heartbeat));
    heartbeat.notes_frames = 3;
    try std.testing.expect(child.ready(&heartbeat));
}

test "a launch queued before clean reap survives both initial and later startup" {
    for ([_]bool{ false, true }) |checking_progress| {
        var child: Child = .{ .app_id = abi.display.notes, .name = "Notes" };
        var heartbeat: abi.WindowHeartbeat = .{};
        child.launched(10, &heartbeat, checking_progress);
        heartbeat.notes_pid = 10;
        heartbeat.notes_launch_requests = 1;
        child.reaped(0);
        try std.testing.expectEqual(@as(u64, 0), child.launch_generation);
        try std.testing.expect(!child.mayLaunch(&heartbeat));
        heartbeat.notes_pid = 0;
        heartbeat.notes_closed = 1;
        try std.testing.expect(child.mayLaunch(&heartbeat));
        child.launched(20, &heartbeat, true);
        child.reaped(0);
        heartbeat.notes_closed = 2;
        try std.testing.expect(!child.mayLaunch(&heartbeat));
        heartbeat.notes_launch_requests = 2;
        try std.testing.expect(child.mayLaunch(&heartbeat));
    }
}

test "fault restart still waits for lease retirement and retains the other child" {
    var heartbeat: abi.WindowHeartbeat = .{};
    var notes: Child = .{ .app_id = abi.display.notes, .name = "Notes" };
    var files: Child = .{ .app_id = abi.display.files, .name = "Files" };
    notes.launched(10, &heartbeat, false);
    files.launched(11, &heartbeat, false);
    heartbeat.notes_pid = 10;
    heartbeat.files_pid = 11;
    heartbeat.files_frames = 3;
    notes.reaped(139);
    try std.testing.expect(!notes.mayLaunch(&heartbeat));
    heartbeat.notes_pid = 0;
    heartbeat.notes_closed = 1;
    try std.testing.expect(notes.mayLaunch(&heartbeat));
    try std.testing.expect(files.ready(&heartbeat) and files.pid == 11 and !files.mayLaunch(&heartbeat));
}
