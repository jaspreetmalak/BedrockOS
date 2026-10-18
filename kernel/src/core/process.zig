//! Bounded single-CPU process policy. The trusted kernel serializes mutations;
//! native contexts, memory, handles and pending syscall buffers have other owners.
const std = @import("std");

pub const Pid = enum(u64) { _ };
pub const State = enum { free, ready, running, blocked, zombie };
pub const ExitStatus = struct { code: u64, faulted: bool = false };
pub const ExitRecord = struct { pid: Pid, status: ExitStatus };
pub const WaitResult = union(enum) { ready: ExitRecord, blocked: void };
pub const BlockReason = union(enum) {
    kernel_request: void,
    sleep: u64,
    wait_child: ?Pid,
    ipc_send: u64,
    ipc_receive: u64,
};
pub const Error = error{
    InvalidPid,
    StalePid,
    ProcessCapacity,
    InitAlreadyExists,
    InitUnavailable,
    InitHasChildren,
    InitFailureRequiresFault,
    ParentNotAlive,
    ProcessNotAlive,
    ProcessNotRunning,
    ProcessNotReady,
    ProcessNotBlocked,
    ProcessNotZombie,
    ProcessStillRunning,
    InvalidBlockReason,
    DeadlineAlreadyReached,
    WakeNotConsumed,
    TickOverflow,
    NoChildren,
    NotChild,
    ChildNotZombie,
    WaitAlreadyReady,
    ProcessAlreadyDispatched,
    ProcessHasChildren,
};

/// Identity validation only. A mailbox receives the sender identity selected by
/// the kernel; an application cannot use a PID value as IPC authority.
pub fn validIdentity(pid: Pid) bool {
    const value = @backingInt(pid);
    return @as(u32, @truncate(value)) != 0 and value >> 32 != 0;
}

/// Retain this instance for the complete runtime; resetting/copying its live
/// generation history could revive references from an earlier incarnation.
pub fn ProcessTable(comptime capacity: usize) type {
    if (capacity > std.math.maxInt(u32)) @compileError("Process capacity exceeds PID slot encoding");
    return struct {
        const Self = @This();
        const Entry = struct {
            generation: u32 = 1,
            retired: bool = false,
            state: State = .free,
            parent: ?Pid = null,
            reason: ?BlockReason = null,
            wake_result: ?u64 = null,
            status: ?ExitStatus = null,
            quanta: u64 = 0,
            dispatched: bool = false,
        };
        entries: [capacity]Entry = @splat(.{}),
        init_pid: ?Pid = null,
        current: ?Pid = null,
        cursor: usize = 0,
        ticks: u64 = 0,

        /// A null parent creates the designated init exactly once. Later
        /// processes require a live parent and inherit no authority here.
        pub fn spawn(self: *Self, parent_pid: ?Pid) Error!Pid {
            if (comptime capacity == 0) return error.ProcessCapacity;
            if (parent_pid) |parent_id| {
                const parent_slot = try self.slot(parent_id);
                if (!alive(self.entries[parent_slot].state)) return error.ParentNotAlive;
            } else if (self.init_pid != null) return error.InitAlreadyExists;
            for (&self.entries, 0..) |*entry, index| {
                if (entry.retired or entry.state != .free) continue;
                entry.state = .ready;
                entry.parent = parent_pid;
                entry.reason = null;
                entry.wake_result = null;
                entry.status = null;
                entry.quanta = 0;
                entry.dispatched = false;
                const pid = encode(index, entry.generation);
                if (parent_pid == null) self.init_pid = pid;
                return pid;
            }
            return error.ProcessCapacity;
        }

        /// Trusted rollback only, before a newly issued process has ever run.
        /// Root detaches every partially constructed native resource first.
        /// Aborting an undispatched init also resets its provisional designation.
        pub fn abortSpawn(self: *Self, pid: Pid) Error!void {
            if (comptime capacity == 0) return error.InvalidPid;
            const index = try self.slot(pid);
            if (self.current != null) return error.ProcessStillRunning;
            const entry = &self.entries[index];
            if (entry.state != .ready or entry.dispatched) return error.ProcessAlreadyDispatched;
            for (&self.entries) |*child| {
                if (child.state != .free and child.parent == pid) return error.ProcessHasChildren;
            }
            if (self.init_pid == pid) self.init_pid = null;
            self.recycle(index);
        }

        pub fn slot(self: *const Self, pid: Pid) Error!usize {
            const token = @backingInt(pid);
            const number: u32 = @truncate(token);
            const generation: u32 = @intCast(token >> 32);
            if (number == 0 or number > capacity or generation == 0) return error.InvalidPid;
            const index: usize = number - 1;
            const entry = &self.entries[index];
            if (entry.retired or entry.state == .free or entry.generation != generation) return error.StalePid;
            return index;
        }

        pub fn pidAt(self: *const Self, index: usize) ?Pid {
            if (index >= capacity or self.entries[index].retired or self.entries[index].state == .free) return null;
            return encode(index, self.entries[index].generation);
        }
        pub fn state(self: *const Self, pid: Pid) Error!State {
            return self.entries[try self.slot(pid)].state;
        }
        pub fn parent(self: *const Self, pid: Pid) Error!?Pid {
            return self.entries[try self.slot(pid)].parent;
        }
        pub fn blockedReason(self: *const Self, pid: Pid) Error!?BlockReason {
            return self.entries[try self.slot(pid)].reason;
        }

        /// The cursor advances after each selection, including yielded and
        /// awakened processes. Blocked and zombie records are never selected.
        pub fn dispatch(self: *Self) Error!?Pid {
            if (self.current != null) return error.ProcessStillRunning;
            if (capacity == 0) return null;
            var index = self.cursor;
            for (0..capacity) |_| {
                if (self.entries[index].state == .ready) {
                    const pid = encode(index, self.entries[index].generation);
                    self.entries[index].state = .running;
                    self.entries[index].dispatched = true;
                    self.current = pid;
                    self.cursor = if (index + 1 == capacity) 0 else index + 1;
                    return pid;
                }
                index = if (index + 1 == capacity) 0 else index + 1;
            }
            return null;
        }

        /// One verified hardware quantum. Counter overflow changes no state.
        pub fn preempt(self: *Self, pid: Pid) Error!void {
            const index = try self.runningSlot(pid);
            const next_tick = @addWithOverflow(self.ticks, 1);
            const next_quantum = @addWithOverflow(self.entries[index].quanta, 1);
            if (next_tick[1] != 0 or next_quantum[1] != 0) return error.TickOverflow;
            self.ticks = next_tick[0];
            self.entries[index].quanta = next_quantum[0];
            self.entries[index].state = .ready;
            self.current = null;
            self.wakeSleepers();
        }
        pub fn yield(self: *Self, pid: Pid) Error!void {
            const index = try self.runningSlot(pid);
            self.entries[index].state = .ready;
            self.current = null;
        }

        pub fn sleep(self: *Self, pid: Pid, delay_ticks: u64) Error!void {
            _ = try self.runningSlot(pid);
            const deadline = @addWithOverflow(self.ticks, delay_ticks);
            if (deadline[1] != 0) return error.TickOverflow;
            if (delay_ticks == 0) return self.yield(pid);
            try self.block(pid, .{ .sleep = deadline[0] });
        }

        /// Idle hardware ticks use this same clock even with no runnable user
        /// context. The architecture adapter supplies verified elapsed ticks.
        pub fn advanceTicks(self: *Self, delta: u64) Error!void {
            const next = @addWithOverflow(self.ticks, delta);
            if (next[1] != 0) return error.TickOverflow;
            self.ticks = next[0];
            self.wakeSleepers();
        }

        /// Probe and block occur in one serialized kernel operation. IPC queues
        /// must be checked before this call, with no interrupt-enabled gap.
        pub fn block(self: *Self, pid: Pid, reason: BlockReason) Error!void {
            const index = try self.runningSlot(pid);
            if (self.entries[index].wake_result != null) return error.WakeNotConsumed;
            try self.validateReason(pid, reason);
            self.entries[index].state = .blocked;
            self.entries[index].reason = reason;
            self.current = null;
        }

        /// A deferred kernel IPC retry may find that another waiter consumed
        /// readiness. Recheck and reblock atomically after consuming its wake.
        pub fn reblockReady(self: *Self, pid: Pid, reason: BlockReason) Error!void {
            const index = try self.slot(pid);
            if (self.entries[index].state != .ready or self.current == pid) return error.ProcessNotReady;
            if (self.entries[index].wake_result != null) return error.WakeNotConsumed;
            try self.validateReason(pid, reason);
            self.entries[index].state = .blocked;
            self.entries[index].reason = reason;
        }

        fn validateReason(self: *const Self, pid: Pid, reason: BlockReason) Error!void {
            switch (reason) {
                .kernel_request => {},
                .sleep => |deadline| if (deadline <= self.ticks) return error.DeadlineAlreadyReached,
                .wait_child => |selected| {
                    if (selected) |child| {
                        const child_index = try self.slot(child);
                        if (self.entries[child_index].parent != pid) return error.NotChild;
                        if (self.entries[child_index].state == .zombie) return error.WaitAlreadyReady;
                    } else {
                        var found = false;
                        for (&self.entries) |*child| {
                            if (child.state == .free or child.parent != pid) continue;
                            if (child.state == .zombie) return error.WaitAlreadyReady;
                            found = true;
                        }
                        if (!found) return error.NoChildren;
                    }
                },
                .ipc_send, .ipc_receive => |object| if (object == 0) return error.InvalidBlockReason,
            }
        }

        pub fn wake(self: *Self, pid: Pid, result: u64) Error!void {
            const index = try self.slot(pid);
            if (self.entries[index].state != .blocked) return error.ProcessNotBlocked;
            self.wakeSlot(index, result);
        }
        pub fn takeWake(self: *Self, pid: Pid) Error!?u64 {
            const index = try self.slot(pid);
            const value = self.entries[index].wake_result;
            self.entries[index].wake_result = null;
            return value;
        }

        /// Root calls this after committing queue progress/closure. All matching
        /// waiters become ready; their deferred operations recheck the mailbox.
        pub fn wakeMatching(self: *Self, reason: BlockReason, result: u64) usize {
            var count: usize = 0;
            for (&self.entries, 0..) |*entry, index| {
                if (entry.state != .blocked or entry.reason == null or !sameReason(entry.reason.?, reason)) continue;
                self.wakeSlot(index, result);
                count += 1;
            }
            return count;
        }

        /// Nonblocking inspection preserves scheduling and does not consume a
        /// zombie. Only the actual parent can select or later reap its child.
        pub fn pollWait(self: *const Self, parent_pid: Pid, selected: ?Pid) Error!?ExitRecord {
            const parent_index = try self.slot(parent_pid);
            if (!alive(self.entries[parent_index].state)) return error.ParentNotAlive;
            if (selected) |child| {
                const index = try self.slot(child);
                if (self.entries[index].parent != parent_pid) return error.NotChild;
                if (self.entries[index].state == .zombie)
                    return .{ .pid = child, .status = self.entries[index].status.? };
            } else {
                var found = false;
                for (self.entries, 0..) |entry, index| {
                    if (entry.state == .free or entry.parent != parent_pid) continue;
                    found = true;
                    if (entry.state == .zombie)
                        return .{ .pid = encode(index, entry.generation), .status = entry.status.? };
                }
                if (!found) return error.NoChildren;
            }
            return null;
        }

        /// Existing zombies may be selected by deferred completion while the
        /// parent is ready. Blocking a wait requires a running parent.
        pub fn wait(self: *Self, parent_pid: Pid, selected: ?Pid) Error!WaitResult {
            if (try self.pollWait(parent_pid, selected)) |record| return .{ .ready = record };
            try self.block(parent_pid, .{ .wait_child = selected });
            return .blocked;
        }

        /// Trusted inspection for deferred resource teardown. Reading this
        /// record neither consumes the status nor publishes a reusable PID.
        pub fn exitRecord(self: *const Self, pid: Pid) Error!ExitRecord {
            const index = try self.slot(pid);
            const entry = &self.entries[index];
            if (entry.state != .zombie) return error.ProcessNotZombie;
            return .{ .pid = pid, .status = entry.status.? };
        }

        /// Native resources must already be detached by the root before reap
        /// publishes a reusable slot. Only the child's actual parent may reap.
        pub fn reap(self: *Self, parent_pid: Pid, child: Pid) Error!ExitRecord {
            const parent_index = try self.slot(parent_pid);
            if (!alive(self.entries[parent_index].state)) return error.ParentNotAlive;
            const index = try self.slot(child);
            const entry = &self.entries[index];
            if (entry.parent != parent_pid) return error.NotChild;
            if (entry.state != .zombie) return error.ChildNotZombie;
            const record: ExitRecord = .{ .pid = child, .status = entry.status.? };
            self.recycle(index);
            return record;
        }

        fn recycle(self: *Self, index: usize) void {
            const entry = &self.entries[index];
            entry.state = .free;
            entry.parent = null;
            entry.reason = null;
            entry.wake_result = null;
            entry.status = null;
            entry.quanta = 0;
            entry.dispatched = false;
            if (entry.generation == std.math.maxInt(u32)) entry.retired = true else entry.generation += 1;
        }

        /// Faulted/exited children remain zombies until a parent reaps them.
        /// Live init adopts both live children and existing zombie records.
        /// Init itself may exit only after every direct child record is reaped;
        /// its final zombie is retained for trusted kernel shutdown inspection.
        pub fn exit(self: *Self, pid: Pid, status: ExitStatus) Error!void {
            const index = try self.slot(pid);
            if (!alive(self.entries[index].state)) return error.ProcessNotAlive;
            const is_init = self.init_pid == pid;
            var has_children = false;
            for (&self.entries) |*entry| {
                if (entry.state != .free and entry.parent == pid) has_children = true;
            }
            if (is_init and has_children) return error.InitHasChildren;
            if (has_children) {
                const init = self.init_pid orelse return error.InitUnavailable;
                const init_index = try self.slot(init);
                if (!alive(self.entries[init_index].state)) return error.InitUnavailable;
            }
            const parent_pid = self.entries[index].parent;
            self.entries[index].state = .zombie;
            self.entries[index].status = status;
            self.entries[index].reason = null;
            self.entries[index].wake_result = null;
            if (self.current == pid) self.current = null;
            for (&self.entries) |*entry| {
                if (entry.state != .free and entry.parent == pid) entry.parent = self.init_pid;
            }
            if (parent_pid) |parent_id| self.notifyParent(parent_id, pid, status.code);
            if (has_children) {
                const init = self.init_pid.?;
                for (&self.entries, 0..) |*entry, child_index| {
                    if (entry.state == .zombie and entry.parent == init)
                        self.notifyParent(init, encode(child_index, entry.generation), entry.status.?.code);
                }
            }
        }

        /// Trusted bootstrap failure policy, never a user-callable exit path.
        /// Failed init ends the session: stop all live processes for native
        /// cleanup, retaining previous zombies and every issued identity.
        pub fn failInit(self: *Self, status: ExitStatus) Error!void {
            if (!status.faulted) return error.InitFailureRequiresFault;
            const init = self.init_pid orelse return error.InitUnavailable;
            const init_index = try self.slot(init);
            if (!alive(self.entries[init_index].state)) return error.InitUnavailable;
            for (&self.entries, 0..) |*entry, index| {
                if (!alive(entry.state)) continue;
                entry.state = .zombie;
                entry.status = if (index == init_index) status else .{ .code = 137 };
                entry.reason = null;
                entry.wake_result = null;
            }
            self.current = null;
        }

        fn runningSlot(self: *const Self, pid: Pid) Error!usize {
            const index = try self.slot(pid);
            if (self.current != pid or self.entries[index].state != .running) return error.ProcessNotRunning;
            return index;
        }
        fn wakeSlot(self: *Self, index: usize, result: u64) void {
            std.debug.assert(self.entries[index].state == .blocked and self.entries[index].wake_result == null);
            self.entries[index].state = .ready;
            self.entries[index].reason = null;
            self.entries[index].wake_result = result;
        }
        fn wakeSleepers(self: *Self) void {
            for (&self.entries, 0..) |*entry, index| {
                if (entry.state != .blocked) continue;
                switch (entry.reason.?) {
                    .sleep => |deadline| if (deadline <= self.ticks) self.wakeSlot(index, 0),
                    else => {},
                }
            }
        }
        fn notifyParent(self: *Self, parent_pid: Pid, child: Pid, result: u64) void {
            const index = self.slot(parent_pid) catch return;
            const entry = &self.entries[index];
            if (entry.state != .blocked) return;
            switch (entry.reason.?) {
                .wait_child => |selected| if (selected == null or selected == child) self.wakeSlot(index, result),
                else => {},
            }
        }
        fn encode(index: usize, generation: u32) Pid {
            return @fromBackingInt((@as(u64, generation) << 32) | @as(u64, @intCast(index + 1)));
        }
    };
}

fn alive(value: State) bool {
    return value == .ready or value == .running or value == .blocked;
}
fn sameReason(a: BlockReason, b: BlockReason) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .kernel_request => true,
        .sleep => |value| value == b.sleep,
        .wait_child => |value| value == b.wait_child,
        .ipc_send => |value| value == b.ipc_send,
        .ipc_receive => |value| value == b.ipc_receive,
    };
}

test "parent wait blocks then child exit wakes and reap invalidates PID" {
    const t = std.testing;
    var table: ProcessTable(3) = .{};
    const init = try table.spawn(null);
    const child = try table.spawn(init);
    try t.expectEqual(init, (try table.dispatch()).?);
    try t.expectEqualDeep(@as(WaitResult, .blocked), try table.wait(init, child));
    try t.expectEqual(child, (try table.dispatch()).?);
    try table.exit(child, .{ .code = 17 });
    try t.expectEqual(State.ready, try table.state(init));
    try t.expectEqual(@as(?u64, 17), try table.takeWake(init));
    const record = (try table.wait(init, child)).ready;
    try t.expectEqual(@as(u64, 17), record.status.code);
    _ = try table.reap(init, child);
    try t.expectError(error.StalePid, table.state(child));
    const replacement = try table.spawn(init);
    try t.expectEqual(try table.slot(replacement), @as(usize, 1));
    try t.expect(replacement != child);
    try t.expectError(error.StalePid, table.reap(init, child));
}

test "unrelated waits and live-child reap fail without state mutation" {
    const t = std.testing;
    var table: ProcessTable(4) = .{};
    const init = try table.spawn(null);
    const a = try table.spawn(init);
    const b = try table.spawn(init);
    const grandchild = try table.spawn(a);
    const before = table;
    try t.expectError(error.NotChild, table.wait(b, grandchild));
    try t.expectError(error.NotChild, table.reap(b, grandchild));
    try t.expectError(error.ChildNotZombie, table.reap(init, a));
    try t.expectError(error.NoChildren, table.wait(b, null));
    try t.expectEqualDeep(before, table);
}

test "already exited children and exact wait selection cannot lose a wake" {
    const t = std.testing;
    var table: ProcessTable(3) = .{};
    const init = try table.spawn(null);
    const a = try table.spawn(init);
    const b = try table.spawn(init);
    try t.expectEqual(init, (try table.dispatch()).?);
    _ = try table.wait(init, b);
    try table.exit(a, .{ .code = 1 });
    try t.expectEqual(State.blocked, try table.state(init));
    try table.exit(b, .{ .code = 2, .faulted = true });
    try t.expectEqual(@as(?u64, 2), try table.takeWake(init));
    try t.expectEqual(b, (try table.wait(init, b)).ready.pid);
    try t.expect((try table.wait(init, b)).ready.status.faulted);
    _ = try table.reap(init, b);
    try t.expectEqual(a, (try table.wait(init, null)).ready.pid);
    _ = try table.reap(init, a);
    try t.expectError(error.NoChildren, table.wait(init, null));
}

test "sleep deadlines wake on idle ticks with fair dispatch and no early wake" {
    const t = std.testing;
    var table: ProcessTable(2) = .{};
    const init = try table.spawn(null);
    const child = try table.spawn(init);
    try t.expectEqual(init, (try table.dispatch()).?);
    try table.sleep(init, 2);
    try t.expectEqual(child, (try table.dispatch()).?);
    try table.sleep(child, 2);
    try t.expectEqual(@as(?Pid, null), try table.dispatch());
    try table.advanceTicks(1);
    try t.expectEqual(State.blocked, try table.state(init));
    try table.advanceTicks(1);
    try t.expectEqual(@as(?u64, 0), try table.takeWake(init));
    try t.expectEqual(@as(?u64, 0), try table.takeWake(child));
    for (0..8) |i| {
        const pid = (try table.dispatch()).?;
        try t.expectEqual(if (i % 2 == 0) init else child, pid);
        try table.preempt(pid);
    }
    try t.expectEqual(@as(u64, 10), table.ticks);
}

test "overflow and stale transition rejection are atomic" {
    const t = std.testing;
    var table: ProcessTable(2) = .{};
    const init = try table.spawn(null);
    const child = try table.spawn(init);
    _ = try table.dispatch();
    table.ticks = std.math.maxInt(u64);
    const before = table;
    try t.expectError(error.TickOverflow, table.sleep(init, 1));
    try t.expectError(error.TickOverflow, table.preempt(init));
    try t.expectError(error.TickOverflow, table.advanceTicks(1));
    try t.expectError(error.ProcessNotRunning, table.yield(child));
    try t.expectError(error.ProcessStillRunning, table.dispatch());
    try t.expectEqualDeep(before, table);
    table.ticks = 0;
    const running_index = try table.slot(init);
    table.entries[running_index].quanta = std.math.maxInt(u64);
    const before_quantum = table;
    try t.expectError(error.TickOverflow, table.preempt(init));
    try t.expectEqualDeep(before_quantum, table);
    table.entries[running_index].quanta = 0;
    try table.sleep(init, 0);
    try t.expectEqual(State.ready, try table.state(init));
}

test "IPC reason matching preserves unrelated waiters and pending results" {
    const t = std.testing;
    var table: ProcessTable(3) = .{};
    const init = try table.spawn(null);
    const a = try table.spawn(init);
    const b = try table.spawn(init);
    _ = try table.dispatch();
    try table.block(init, .{ .ipc_receive = 7 });
    _ = try table.dispatch();
    try table.block(a, .{ .ipc_send = 7 });
    _ = try table.dispatch();
    try table.block(b, .{ .ipc_receive = 8 });
    try t.expectEqual(@as(usize, 1), table.wakeMatching(.{ .ipc_receive = 7 }, 64));
    try t.expectEqual(State.blocked, try table.state(a));
    try t.expectEqual(State.blocked, try table.state(b));
    try t.expectEqual(init, (try table.dispatch()).?);
    try t.expectError(error.WakeNotConsumed, table.block(init, .{ .ipc_receive = 7 }));
    try t.expectEqual(@as(?u64, 64), try table.takeWake(init));
    try table.block(init, .{ .ipc_receive = 7 });
    try t.expectEqual(@as(usize, 1), table.wakeMatching(.{ .ipc_receive = 7 }, 0));
    try t.expectError(error.ProcessNotBlocked, table.wake(init, 1));
}

test "orphans and existing zombies are adopted by init before parent reap" {
    const t = std.testing;
    var table: ProcessTable(4) = .{};
    const init = try table.spawn(null);
    const parent_pid = try table.spawn(init);
    const live = try table.spawn(parent_pid);
    const dead = try table.spawn(parent_pid);
    try table.exit(dead, .{ .code = 22 });
    try table.exit(parent_pid, .{ .code = 11 });
    try t.expectEqual(@as(?Pid, init), try table.parent(live));
    try t.expectEqual(@as(?Pid, init), try table.parent(dead));
    try t.expectError(error.InitHasChildren, table.exit(init, .{ .code = 0 }));
    _ = try table.reap(init, parent_pid);
    _ = try table.reap(init, dead);
    try table.exit(live, .{ .code = 33 });
    _ = try table.reap(init, live);
    try table.exit(init, .{ .code = 0 });
    try t.expectEqual(State.zombie, try table.state(init));
    try t.expectError(error.InitAlreadyExists, table.spawn(null));
}

test "PID generation exhaustion retires the reaped slot" {
    const t = std.testing;
    var table: ProcessTable(2) = .{};
    const init = try table.spawn(null);
    const original = try table.spawn(init);
    const index = try table.slot(original);
    table.entries[index].generation = std.math.maxInt(u32);
    const final = table.pidAt(index).?;
    try table.exit(final, .{ .code = 0 });
    _ = try table.reap(init, final);
    try t.expectError(error.StalePid, table.slot(final));
    try t.expectError(error.ProcessCapacity, table.spawn(init));
    try t.expectEqual(@as(?Pid, null), table.pidAt(index));
    var empty: ProcessTable(0) = .{};
    try t.expectEqual(@as(?Pid, null), try empty.dispatch());
    try t.expectError(error.ProcessCapacity, empty.spawn(null));
}

test "construction abort invalidates only an undispatched child" {
    const t = std.testing;
    var table: ProcessTable(3) = .{};
    const init = try table.spawn(null);
    _ = try table.dispatch();
    try table.block(init, .kernel_request);
    const partial = try table.spawn(init);
    try table.abortSpawn(partial);
    try t.expectError(error.StalePid, table.slot(partial));
    const child = try table.spawn(init);
    try t.expect(child != partial);
    try table.wake(init, @backingInt(child));
    _ = try table.takeWake(init);
    try t.expectEqual(child, (try table.dispatch()).?);
    try table.yield(child);
    const before = table;
    try t.expectError(error.ProcessAlreadyDispatched, table.abortSpawn(child));
    try t.expectEqualDeep(before, table);
}

test "zombie inspection retains status and never reaps its identity" {
    const t = std.testing;
    var table: ProcessTable(2) = .{};
    const init = try table.spawn(null);
    const child = try table.spawn(init);
    const live = table;
    try t.expectError(error.ProcessNotZombie, table.exitRecord(child));
    try t.expectEqualDeep(live, table);
    try table.exit(child, .{ .code = 71, .faulted = true });
    const before = table;
    const record = try table.exitRecord(child);
    try t.expectEqualDeep(ExitRecord{ .pid = child, .status = .{ .code = 71, .faulted = true } }, record);
    try t.expectEqualDeep(before, table);
    _ = try table.reap(init, child);
    try t.expectError(error.StalePid, table.exitRecord(child));
}

test "deferred retry reblocks only ready processes after their wake is consumed" {
    const t = std.testing;
    var table: ProcessTable(1) = .{};
    const init = try table.spawn(null);
    _ = try table.dispatch();
    try table.block(init, .{ .ipc_receive = 9 });
    try table.wake(init, 0);
    const unconsumed = table;
    try t.expectError(error.WakeNotConsumed, table.reblockReady(init, .{ .ipc_receive = 9 }));
    try t.expectEqualDeep(unconsumed, table);
    _ = try table.takeWake(init);
    const ready = table;
    try t.expectError(error.InvalidBlockReason, table.reblockReady(init, .{ .ipc_receive = 0 }));
    try t.expectError(error.DeadlineAlreadyReached, table.reblockReady(init, .{ .sleep = table.ticks }));
    try t.expectEqualDeep(ready, table);
    try table.reblockReady(init, .{ .ipc_receive = 9 });
    try t.expectEqual(State.blocked, try table.state(init));
    try t.expectEqual(@as(?Pid, null), try table.dispatch());
    try t.expectEqual(@as(usize, 1), table.wakeMatching(.{ .ipc_receive = 9 }, 8));
    _ = try table.takeWake(init);
    try t.expectEqual(init, (try table.dispatch()).?);
    const running = table;
    try t.expectError(error.ProcessNotReady, table.reblockReady(init, .{ .ipc_send = 9 }));
    try t.expectEqualDeep(running, table);
}

test "trusted init failure stops live children and preserves prior zombies" {
    const t = std.testing;
    var table: ProcessTable(4) = .{};
    const init = try table.spawn(null);
    const blocked = try table.spawn(init);
    const running = try table.spawn(init);
    const previous = try table.spawn(init);
    _ = try table.dispatch();
    try table.block(init, .kernel_request);
    _ = try table.dispatch();
    try table.block(blocked, .{ .ipc_receive = 7 });
    try t.expectEqual(running, (try table.dispatch()).?);
    try table.exit(previous, .{ .code = 42 });
    try table.wake(init, 5);
    const before = table;
    try t.expectError(error.InitFailureRequiresFault, table.failInit(.{ .code = 0 }));
    try t.expectEqualDeep(before, table);
    try table.failInit(.{ .code = 139, .faulted = true });
    try t.expectEqualDeep(ExitStatus{ .code = 139, .faulted = true }, (try table.exitRecord(init)).status);
    for ([_]Pid{ blocked, running }) |child| {
        try t.expectEqual(State.zombie, try table.state(child));
        try t.expectEqual(@as(u64, 137), (try table.exitRecord(child)).status.code);
        try t.expectEqual(@as(?BlockReason, null), try table.blockedReason(child));
        try t.expectEqual(@as(?u64, null), try table.takeWake(child));
    }
    try t.expectEqual(@as(?u64, null), try table.takeWake(init));
    try t.expectEqual(@as(u64, 42), (try table.exitRecord(previous)).status.code);
    try t.expectEqual(@as(?Pid, null), table.current);
    try t.expectEqual(@as(?Pid, null), try table.dispatch());
    try t.expectError(error.ParentNotAlive, table.spawn(init));
    try t.expectError(error.InitUnavailable, table.failInit(.{ .code = 139, .faulted = true }));
}

test "nonblocking child wait preserves scheduling and parent authority" {
    const t = std.testing;
    var table: ProcessTable(4) = .{};
    const init = try table.spawn(null);
    const child = try table.spawn(init);
    const other = try table.spawn(init);
    const grandchild = try table.spawn(other);
    try t.expectEqual(init, (try table.dispatch()).?);
    const running = table;
    try t.expectEqual(@as(?ExitRecord, null), try table.pollWait(init, child));
    try t.expectEqualDeep(running, table);
    try t.expectError(error.NotChild, table.pollWait(init, grandchild));
    try t.expectEqualDeep(running, table);
    try table.exit(child, .{ .code = 23 });
    const exited = table;
    const first = (try table.pollWait(init, null)).?;
    try t.expectEqual(child, first.pid);
    try t.expectEqual(@as(u64, 23), first.status.code);
    try t.expectEqualDeep(exited, table);
    try t.expectEqual(first, (try table.pollWait(init, child)).?);
    _ = try table.reap(init, child);
    try t.expectError(error.StalePid, table.pollWait(init, child));
    try t.expectEqual(@as(?ExitRecord, null), try table.pollWait(init, null));
    try t.expectEqual(State.running, try table.state(init));
}
