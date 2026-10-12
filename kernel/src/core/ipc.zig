//! Kernel-owned bounded mailboxes. Object identities are not application
//! authority: the current process's handle table must authorize every operation.
//! Root serializes queue probes, ProcessTable.block and waiter notifications.
const std = @import("std");
const process = @import("process.zig");

pub const ObjectId = u64;
pub const max_payload = 64;
pub const Message = struct {
    sender: process.Pid = @fromBackingInt(0),
    length: usize = 0,
    data: [max_payload]u8 = @splat(0),

    pub fn bytes(self: *const Message) []const u8 {
        return self.data[0..self.length];
    }
};
pub const SendStatus = union(enum) { sent: void, full: void, closed: void };
pub const ReceiveResult = union(enum) { message: Message, empty: void, closed: void };
pub const Error = error{
    InvalidOwner,
    InvalidSender,
    InvalidObjectIdentity,
    StaleObjectIdentity,
    MailboxCapacity,
    NotOwner,
    PayloadTooLarge,
    MailboxOpen,
    MailboxNotDrained,
};

/// Keep one instance alive with its generation history. Replacing it while
/// handles survive would invalidate the stale-object rejection contract.
pub fn Mailboxes(comptime channel_capacity: usize, comptime message_capacity: usize) type {
    if (channel_capacity > std.math.maxInt(u32)) @compileError("IPC capacity exceeds object slot encoding");
    return struct {
        const Self = @This();
        const Channel = struct {
            generation: u32 = 1,
            occupied: bool = false,
            retired: bool = false,
            owner: ?process.Pid = null,
            closed: bool = false,
            head: usize = 0,
            count: usize = 0,
            queue: [message_capacity]Message = @splat(.{}),
        };
        channels: [channel_capacity]Channel = @splat(.{}),

        pub fn open(self: *Self, owner_pid: process.Pid) Error!ObjectId {
            if (!process.validIdentity(owner_pid)) return error.InvalidOwner;
            for (&self.channels, 0..) |*channel, index| {
                if (channel.occupied or channel.retired) continue;
                channel.occupied = true;
                channel.owner = owner_pid;
                channel.closed = false;
                channel.head = 0;
                channel.count = 0;
                return encode(index, channel.generation);
            }
            return error.MailboxCapacity;
        }

        pub fn objectAt(self: *const Self, index: usize) ?ObjectId {
            if (index >= channel_capacity or !self.channels[index].occupied or self.channels[index].retired) return null;
            return encode(index, self.channels[index].generation);
        }
        pub fn owner(self: *const Self, id: ObjectId) Error!process.Pid {
            return self.channels[try self.objectSlot(id)].owner.?;
        }
        pub fn queued(self: *const Self, id: ObjectId) Error!usize {
            return self.channels[try self.objectSlot(id)].count;
        }
        pub fn isClosed(self: *const Self, id: ObjectId) Error!bool {
            return self.channels[try self.objectSlot(id)].closed;
        }

        /// The sender is chosen from the executing process by trusted root,
        /// never from an application's header. The entire payload is copied.
        pub fn send(self: *Self, id: ObjectId, sender: process.Pid, bytes: []const u8) Error!SendStatus {
            const channel = &self.channels[try self.objectSlot(id)];
            if (!process.validIdentity(sender)) return error.InvalidSender;
            if (bytes.len > max_payload) return error.PayloadTooLarge;
            if (channel.closed) return .closed;
            if (channel.count == message_capacity) return .full;
            var message: Message = .{ .sender = sender, .length = bytes.len };
            @memcpy(message.data[0..bytes.len], bytes);
            const until_wrap = message_capacity - channel.head;
            const tail = if (channel.count >= until_wrap) channel.count - until_wrap else channel.head + channel.count;
            channel.queue[tail] = message;
            channel.count += 1;
            return .sent;
        }

        /// Copied, stable observation for capacity/copyout checks. Queue commit
        /// must follow in the same serialized kernel operation without a gap.
        pub fn peek(self: *const Self, id: ObjectId) Error!ReceiveResult {
            const channel = &self.channels[try self.objectSlot(id)];
            if (channel.count == 0) return if (channel.closed) .closed else .empty;
            return .{ .message = channel.queue[channel.head] };
        }

        /// Closed endpoints still deliver committed messages in FIFO order.
        /// Root validates the user output range before this consuming call.
        pub fn receive(self: *Self, id: ObjectId) Error!ReceiveResult {
            const channel = &self.channels[try self.objectSlot(id)];
            if (channel.count == 0) return if (channel.closed) .closed else .empty;
            const message = channel.queue[channel.head];
            channel.queue[channel.head] = .{};
            channel.head = if (channel.head + 1 == message_capacity) 0 else channel.head + 1;
            channel.count -= 1;
            return .{ .message = message };
        }

        pub fn close(self: *Self, owner_pid: process.Pid, id: ObjectId) Error!void {
            const channel = &self.channels[try self.objectSlot(id)];
            if (channel.owner != owner_pid) return error.NotOwner;
            channel.closed = true;
        }

        /// Process exit closes its endpoints, but previously committed messages
        /// retain their sender identity and payload until drained. Root wakes
        /// both send/receive waiters for these objects and handles final refs.
        pub fn closeOwner(self: *Self, owner_pid: process.Pid) usize {
            var count: usize = 0;
            for (&self.channels) |*channel| {
                if (!channel.occupied or channel.closed or channel.owner != owner_pid) continue;
                channel.closed = true;
                count += 1;
            }
            return count;
        }

        /// Trusted final-reference teardown only. Draining lets root release
        /// exact queued-byte charges before the object generation is retired.
        pub fn destroy(self: *Self, id: ObjectId) Error!void {
            const channel = &self.channels[try self.objectSlot(id)];
            if (!channel.closed) return error.MailboxOpen;
            if (channel.count != 0) return error.MailboxNotDrained;
            channel.occupied = false;
            channel.owner = null;
            channel.head = 0;
            @memset(std.mem.asBytes(&channel.queue), 0);
            if (channel.generation == std.math.maxInt(u32)) channel.retired = true else channel.generation += 1;
        }

        fn objectSlot(self: *const Self, id: ObjectId) Error!usize {
            const number: u32 = @truncate(id);
            const generation: u32 = @intCast(id >> 32);
            if (number == 0 or number > channel_capacity or generation == 0) return error.InvalidObjectIdentity;
            const slot: usize = number - 1;
            const channel = &self.channels[slot];
            if (!channel.occupied or channel.retired or channel.generation != generation) return error.StaleObjectIdentity;
            return slot;
        }
        fn encode(slot: usize, generation: u32) ObjectId {
            return (@as(u64, generation) << 32) | @as(u64, @intCast(slot + 1));
        }
    };
}

fn testPid(slot: u32, generation: u32) process.Pid {
    return @fromBackingInt((@as(u64, generation) << 32) | slot);
}

test "FIFO copied messages preserve sender and wrap the bounded queue" {
    const t = std.testing;
    var boxes: Mailboxes(1, 2) = .{};
    const owner_pid = testPid(1, 1);
    const sender = testPid(2, 1);
    const id = try boxes.open(owner_pid);
    var input = [_]u8{ 1, 2, 3 };
    try t.expectEqualDeep(@as(SendStatus, .sent), try boxes.send(id, sender, &input));
    input[0] = 99;
    _ = try boxes.send(id, owner_pid, "second");
    try t.expectEqualDeep(@as(SendStatus, .full), try boxes.send(id, sender, "full"));
    const peeked = (try boxes.peek(id)).message;
    try t.expectEqual(@as(usize, 2), try boxes.queued(id));
    try t.expectEqual(sender, peeked.sender);
    try t.expectEqualSlices(u8, &[_]u8{ 1, 2, 3 }, peeked.bytes());
    const first = (try boxes.receive(id)).message;
    try t.expectEqualDeep(peeked, first);
    _ = try boxes.send(id, sender, "third");
    const second = (try boxes.receive(id)).message;
    const third = (try boxes.receive(id)).message;
    try t.expectEqualStrings("second", second.bytes());
    try t.expectEqualStrings("third", third.bytes());
    try t.expectEqualDeep(@as(ReceiveResult, .empty), try boxes.receive(id));
}

test "maximum and empty payloads are valid and oversize failure is atomic" {
    const t = std.testing;
    var boxes: Mailboxes(1, 2) = .{};
    const pid = testPid(1, 1);
    const id = try boxes.open(pid);
    const exact: [64]u8 = @splat(0xaa);
    const too_large: [65]u8 = @splat(0xbb);
    _ = try boxes.send(id, pid, &exact);
    const before = boxes;
    try t.expectError(error.PayloadTooLarge, boxes.send(id, pid, &too_large));
    try t.expectEqualDeep(before, boxes);
    _ = try boxes.send(id, pid, "");
    const full = (try boxes.receive(id)).message;
    const empty = (try boxes.receive(id)).message;
    try t.expectEqualSlices(u8, &exact, full.bytes());
    try t.expectEqual(@as(usize, 0), empty.length);
    try t.expectEqualDeep(@as([64]u8, @splat(0)), empty.data);
}

test "owner closure drains committed messages then reports closed" {
    const t = std.testing;
    var boxes: Mailboxes(2, 2) = .{};
    const owner_pid = testPid(1, 1);
    const sender = testPid(2, 1);
    const id = try boxes.open(owner_pid);
    const other = try boxes.open(sender);
    _ = try boxes.send(id, sender, "committed");
    try t.expectError(error.NotOwner, boxes.close(sender, id));
    try t.expectError(error.MailboxOpen, boxes.destroy(id));
    try t.expectEqual(@as(usize, 1), boxes.closeOwner(owner_pid));
    try t.expectEqual(@as(usize, 0), boxes.closeOwner(owner_pid));
    try t.expect(!(try boxes.isClosed(other)));
    try t.expectEqualDeep(@as(SendStatus, .closed), try boxes.send(id, sender, "late"));
    try t.expectError(error.MailboxNotDrained, boxes.destroy(id));
    const message = (try boxes.receive(id)).message;
    try t.expectEqualStrings("committed", message.bytes());
    try t.expectEqualDeep(@as(ReceiveResult, .closed), try boxes.peek(id));
    try t.expectEqualDeep(@as(ReceiveResult, .closed), try boxes.receive(id));
    try boxes.destroy(id);
    try t.expectError(error.StaleObjectIdentity, boxes.peek(id));
    const replacement = try boxes.open(owner_pid);
    try t.expect(replacement != id);
    try t.expectEqualDeep(@as(ReceiveResult, .empty), try boxes.receive(replacement));
}

test "invalid identities cannot mutate queues and generation overflow retires" {
    const t = std.testing;
    var boxes: Mailboxes(1, 1) = .{};
    const pid = testPid(1, 1);
    try t.expectError(error.InvalidOwner, boxes.open(@fromBackingInt(0)));
    const id = try boxes.open(pid);
    const before = boxes;
    try t.expectError(error.InvalidSender, boxes.send(id, @fromBackingInt(0), "x"));
    try t.expectError(error.InvalidObjectIdentity, boxes.receive(0));
    try t.expectError(error.MailboxCapacity, boxes.open(pid));
    try t.expectEqualDeep(before, boxes);
    boxes.channels[0].generation = std.math.maxInt(u32);
    const final = boxes.objectAt(0).?;
    try boxes.close(pid, final);
    try boxes.destroy(final);
    try t.expectError(error.StaleObjectIdentity, boxes.receive(final));
    try t.expectError(error.MailboxCapacity, boxes.open(pid));
    try t.expectEqual(@as(?ObjectId, null), boxes.objectAt(0));
}

test "committed message survives sender exit while owner death closes peers" {
    const t = std.testing;
    var processes: process.ProcessTable(3) = .{};
    const init = try processes.spawn(null);
    const sender = try processes.spawn(init);
    const owner_pid = try processes.spawn(init);
    var boxes: Mailboxes(1, 2) = .{};
    const id = try boxes.open(owner_pid);
    _ = try boxes.send(id, sender, "before exit");
    try processes.exit(sender, .{ .code = 0 });
    _ = try processes.reap(init, sender);
    const committed = (try boxes.peek(id)).message;
    try t.expectEqual(sender, committed.sender);
    try t.expectEqualStrings("before exit", committed.bytes());
    try processes.exit(owner_pid, .{ .code = 3, .faulted = true });
    try t.expectEqual(@as(usize, 1), boxes.closeOwner(owner_pid));
    try t.expectEqualDeep(@as(SendStatus, .closed), try boxes.send(id, init, "late"));
    _ = try boxes.receive(id);
    try t.expectEqualDeep(@as(ReceiveResult, .closed), try boxes.receive(id));
}

test "serialized receive and send notifications complete blocked operations" {
    const t = std.testing;
    var processes: process.ProcessTable(2) = .{};
    const receiver = try processes.spawn(null);
    const sender = try processes.spawn(receiver);
    var boxes: Mailboxes(1, 1) = .{};
    const id = try boxes.open(receiver);
    try t.expectEqual(receiver, (try processes.dispatch()).?);
    try t.expectEqualDeep(@as(ReceiveResult, .empty), try boxes.peek(id));
    try processes.block(receiver, .{ .ipc_receive = id });
    try t.expectEqual(sender, (try processes.dispatch()).?);
    _ = try boxes.send(id, sender, "one");
    try t.expectEqual(@as(usize, 1), processes.wakeMatching(.{ .ipc_receive = id }, 0));
    try t.expectEqualDeep(@as(SendStatus, .full), try boxes.send(id, sender, "two"));
    try processes.block(sender, .{ .ipc_send = id });
    try t.expectEqual(receiver, (try processes.dispatch()).?);
    _ = try processes.takeWake(receiver);
    const first = (try boxes.receive(id)).message;
    try t.expectEqualStrings("one", first.bytes());
    try t.expectEqual(@as(usize, 1), processes.wakeMatching(.{ .ipc_send = id }, 0));
    // Root completes the retained send before the sender re-enters userspace.
    _ = try processes.takeWake(sender);
    _ = try boxes.send(id, sender, "two");
    try processes.yield(receiver);
    try t.expectEqual(sender, (try processes.dispatch()).?);
    const second = (try boxes.receive(id)).message;
    try t.expectEqualStrings("two", second.bytes());
}

test "empty bounded endpoint tables reject allocation" {
    const t = std.testing;
    var boxes: Mailboxes(0, 1) = .{};
    try t.expectError(error.MailboxCapacity, boxes.open(testPid(1, 1)));
    try t.expectEqual(@as(?ObjectId, null), boxes.objectAt(0));
}
