//! Single-CPU round-robin policy. Native contexts and interrupt control belong
//! to architecture adapters; apps cannot choose these slots or their states.
pub const State = enum { unused, ready, running, stopped };
pub const StopReason = enum { exited, faulted, budget };

pub fn Scheduler(comptime capacity: usize) type {
    return struct {
        const Self = @This();
        states: [capacity]State = @splat(.unused),
        reasons: [capacity]?StopReason = @splat(null),
        quanta: [capacity]u64 = @splat(0),
        ticks: u64 = 0,
        current: ?usize = null,
        cursor: usize = 0,

        pub fn add(self: *Self, slot: usize) !void {
            if (slot >= capacity) return error.InvalidTask;
            if (self.states[slot] != .unused) return error.TaskAlreadyRegistered;
            self.states[slot] = .ready;
        }

        pub fn dispatch(self: *Self) !?usize {
            if (self.current != null) return error.TaskStillRunning;
            if (capacity == 0) return null;
            var slot = self.cursor;
            for (0..capacity) |_| {
                if (self.states[slot] == .ready) {
                    self.states[slot] = .running;
                    self.current = slot;
                    self.cursor = if (slot + 1 == capacity) 0 else slot + 1;
                    return slot;
                }
                slot = if (slot + 1 == capacity) 0 else slot + 1;
            }
            return null;
        }

        /// A verified hardware timer ended this user quantum. Counters are
        /// committed together; overflow leaves the task running unchanged.
        pub fn preempt(self: *Self, slot: usize) !void {
            try self.requireRunning(slot);
            const next_ticks = @addWithOverflow(self.ticks, 1);
            const next_quanta = @addWithOverflow(self.quanta[slot], 1);
            if (next_ticks[1] != 0 or next_quanta[1] != 0) return error.TickOverflow;
            self.ticks = next_ticks[0];
            self.quanta[slot] = next_quanta[0];
            self.states[slot] = .ready;
            self.current = null;
        }

        pub fn finish(self: *Self, slot: usize, reason: StopReason) !void {
            try self.requireRunning(slot);
            self.states[slot] = .stopped;
            self.reasons[slot] = reason;
            self.current = null;
        }

        /// The trusted scheduler may stop a suspended ready task at its budget.
        pub fn stopReady(self: *Self, slot: usize, reason: StopReason) !void {
            if (slot >= capacity) return error.InvalidTask;
            if (self.states[slot] != .ready) return error.TaskNotReady;
            self.states[slot] = .stopped;
            self.reasons[slot] = reason;
        }

        fn requireRunning(self: *const Self, slot: usize) !void {
            if (slot >= capacity) return error.InvalidTask;
            if (self.current != slot or self.states[slot] != .running) return error.TaskNotRunning;
        }
    };
}

test "round robin resumes both tasks fairly and wraps without starvation" {
    const t = @import("std").testing;
    var queue: Scheduler(2) = .{};
    try queue.add(0);
    try queue.add(1);
    for (0..8) |tick| {
        const selected = (try queue.dispatch()).?;
        try t.expectEqual(tick % 2, selected);
        try queue.preempt(selected);
    }
    try t.expectEqual(@as(u64, 8), queue.ticks);
    try t.expectEqualDeep([2]u64{ 4, 4 }, queue.quanta);
}

test "exited faulted and budget-stopped tasks never dispatch again" {
    const t = @import("std").testing;
    var queue: Scheduler(3) = .{};
    for (0..3) |slot| try queue.add(slot);
    try t.expectEqual(@as(?usize, 0), try queue.dispatch());
    try queue.finish(0, .exited);
    try t.expectEqual(@as(?usize, 1), try queue.dispatch());
    try queue.finish(1, .faulted);
    try t.expectEqual(@as(?usize, 2), try queue.dispatch());
    try queue.preempt(2);
    try queue.stopReady(2, .budget);
    try t.expectEqual(@as(?usize, null), try queue.dispatch());
    try t.expectEqualDeep([3]?StopReason{ .exited, .faulted, .budget }, queue.reasons);
    try t.expectError(error.TaskAlreadyRegistered, queue.add(0));
}

test "invalid and out of order transitions cannot change another task" {
    const t = @import("std").testing;
    var queue: Scheduler(2) = .{};
    try t.expectError(error.InvalidTask, queue.add(2));
    try t.expectError(error.TaskNotRunning, queue.preempt(0));
    try queue.add(0);
    try queue.add(1);
    _ = try queue.dispatch();
    const before = queue;
    try t.expectError(error.TaskStillRunning, queue.dispatch());
    try t.expectError(error.TaskNotRunning, queue.finish(1, .faulted));
    try t.expectError(error.TaskNotRunning, queue.preempt(1));
    try t.expectError(error.TaskNotReady, queue.stopReady(0, .budget));
    try t.expectEqualDeep(before, queue);
}

test "timer counter overflow is atomic" {
    const t = @import("std").testing;
    var queue: Scheduler(1) = .{};
    try queue.add(0);
    _ = try queue.dispatch();
    queue.ticks = 0xffffffffffffffff;
    const before = queue;
    try t.expectError(error.TickOverflow, queue.preempt(0));
    try t.expectEqualDeep(before, queue);
    queue.ticks = 0;
    queue.quanta[0] = 0xffffffffffffffff;
    const before_quantum = queue;
    try t.expectError(error.TickOverflow, queue.preempt(0));
    try t.expectEqualDeep(before_quantum, queue);
}

test "empty queues and isolated ready tasks handle sparse slots" {
    const t = @import("std").testing;
    var empty: Scheduler(0) = .{};
    try t.expectEqual(@as(?usize, null), try empty.dispatch());
    try t.expectError(error.InvalidTask, empty.add(0));
    var sparse: Scheduler(8) = .{};
    try sparse.add(7);
    for (0..4) |_| {
        try t.expectEqual(@as(?usize, 7), try sparse.dispatch());
        try sparse.preempt(7);
    }
}
