const std = @import("std");
const anvil = @import("root.zig");
const t = std.testing;

fn fill() anvil.Command {
    return .{ .fill = .{
        .target = .{ .token = 1 },
        .rect = .{ .x = 2, .y = 3, .width = 4, .height = 5 },
        .color = 0x123456,
    } };
}

fn copy() anvil.Command {
    return .{ .copy = .{
        .source = .{ .token = 1 },
        .target = .{ .token = 2 },
        .source_rect = .{ .x = 2, .y = 3, .width = 4, .height = 5 },
        .destination = .{ .x = 10, .y = 11 },
    } };
}

const Mock = struct {
    calls: usize = 0,
    completion_calls: usize = 0,
    copied: [anvil.max_commands]anvil.Command = undefined,
    copied_len: usize = 0,
    sequence: u64 = 0,
    completion: u64 = 0,
    immediate: bool = false,
    result: ?u64 = null,
    submit_error: ?anyerror = null,
    completion_error: ?anyerror = null,
    info_error: ?anyerror = null,
    device: anvil.DeviceInfo = .{
        .name = "test software queue",
        .acceleration = .software,
        .capabilities = .{ .fill = true, .copy = true },
        .max_texture_extent = .{ .width = 640, .height = 480 },
    },

    fn from(context: *anyopaque) *Mock {
        return @ptrCast(@alignCast(context));
    }

    fn info(context: *anyopaque) anyerror!anvil.DeviceInfo {
        const self = from(context);
        if (self.info_error) |err| return err;
        return self.device;
    }

    fn submit(context: *anyopaque, sequence: u64, commands: []const anvil.Command) anyerror!anvil.Fence {
        const self = from(context);
        self.calls += 1;
        if (self.submit_error) |err| return err;
        @memcpy(self.copied[0..commands.len], commands);
        self.copied_len = commands.len;
        self.sequence = sequence;
        if (self.immediate) self.completion = sequence;
        return .{ .sequence = self.result orelse sequence };
    }

    fn completed(context: *anyopaque) anyerror!anvil.Fence {
        const self = from(context);
        self.completion_calls += 1;
        if (self.completion_error) |err| return err;
        return .{ .sequence = self.completion };
    }

    fn provider(self: *Mock) anvil.Provider {
        return .{ .context = self, .info = info, .submit = submit, .completed = completed };
    }
};

test "schema rejects empty rectangles, zero tokens, reserved color and overflow" {
    var command = fill();
    command.fill.target.token = 0;
    try t.expectError(error.InvalidTexture, anvil.validateCommand(command));
    command = fill();
    command.fill.rect.width = 0;
    try t.expectError(error.EmptyExtent, anvil.validateCommand(command));
    command = fill();
    command.fill.color = 0xff123456;
    try t.expectError(error.InvalidColor, anvil.validateCommand(command));
    command = fill();
    command.fill.rect.x = std.math.maxInt(u32);
    try t.expectError(error.Overflow, anvil.validateCommand(command));
    command = copy();
    command.copy.source.token = 0;
    try t.expectError(error.InvalidTexture, anvil.validateCommand(command));
    command = copy();
    command.copy.destination.y = std.math.maxInt(u32);
    try t.expectError(error.Overflow, anvil.validateCommand(command));
    try t.expectError(error.Overflow, (anvil.Extent{ .width = std.math.maxInt(u32), .height = std.math.maxInt(u32) }).validate());
    try t.expect(try (anvil.Rect{ .x = 10, .y = 11, .width = 20, .height = 21 }).fits(.{ .width = 30, .height = 32 }));
    try t.expect(!try (anvil.Rect{ .x = 10, .y = 11, .width = 20, .height = 21 }).fits(.{ .width = 29, .height = 32 }));
}

test "malformed whole batch never dispatches even after valid first command" {
    var mock: Mock = .{};
    var queue = try anvil.Queue.init(mock.provider());
    var commands = [_]anvil.Command{ fill(), copy() };
    commands[1].copy.target.token = 0;
    try t.expectError(error.InvalidTexture, queue.submit(1, &commands));
    try t.expectEqual(@as(usize, 0), mock.calls);
    try t.expectEqual(@as(u64, 0), queue.last_submitted);
    try t.expectError(error.EmptyBatch, queue.submit(1, &.{}));
    var too_many: [anvil.max_commands + 1]anvil.Command = @splat(fill());
    try t.expectError(error.TooManyCommands, queue.submit(1, &too_many));
    try t.expectEqual(@as(usize, 0), mock.calls);
}

test "batch append validation and capacity failures are atomic" {
    var storage: [3]anvil.Command = @splat(copy());
    var batch = try anvil.Batch.init(&storage);
    try batch.append(fill());
    var bad = fill();
    bad.fill.color = 0xff123456;
    try t.expectError(error.InvalidColor, batch.appendSlice(&.{ fill(), bad }));
    try t.expectEqual(@as(usize, 1), batch.len);
    try t.expectEqualDeep(copy(), storage[1]);
    try t.expectEqualDeep(copy(), storage[2]);
    try t.expectError(error.BufferTooSmall, batch.appendSlice(&.{ fill(), copy(), fill() }));
    try t.expectEqualDeep(copy(), storage[1]);
    try batch.appendSlice(&.{ copy(), fill() });
    try t.expectEqual(@as(usize, 3), batch.commands().len);
    try t.expectError(error.BufferTooSmall, batch.append(fill()));
    try t.expectEqual(@as(usize, 3), batch.len);
    batch.reset();
    try t.expectEqual(@as(usize, 0), batch.commands().len);
    var oversized: [anvil.max_commands + 1]anvil.Command = undefined;
    try t.expectError(error.TooManyCommands, anvil.Batch.init(&oversized));
    var empty: [0]anvil.Command = .{};
    var empty_batch = try anvil.Batch.init(&empty);
    try t.expectError(error.BufferTooSmall, empty_batch.append(fill()));
    try empty_batch.appendSlice(&.{});
}

test "overlapping caller storage append preserves the original commands" {
    var storage = [_]anvil.Command{ fill(), copy(), fill(), copy() };
    var batch = try anvil.Batch.init(&storage);
    try batch.append(fill());
    try batch.appendSlice(storage[0..3]);
    try t.expectEqualDeep(fill(), storage[1]);
    try t.expectEqualDeep(copy(), storage[2]);
    try t.expectEqualDeep(fill(), storage[3]);
}

test "capabilities and maximum bounds reject before provider dispatch" {
    var mock: Mock = .{};
    mock.device.capabilities.copy = false;
    var queue = try anvil.Queue.init(mock.provider());
    try t.expectError(error.UnsupportedOperation, queue.submit(1, &.{ fill(), copy() }));
    try t.expectEqual(@as(usize, 0), mock.calls);
    var outside = fill();
    outside.fill.rect.x = 640;
    try t.expectError(error.OutOfBounds, queue.submit(1, &.{outside}));
    try t.expectEqual(@as(usize, 0), mock.calls);
    _ = try queue.submit(1, &.{fill()});
    try t.expectEqual(@as(usize, 1), mock.calls);
    mock = .{};
    mock.device.capabilities.fill = false;
    queue = try anvil.Queue.init(mock.provider());
    try t.expectError(error.UnsupportedOperation, queue.submit(1, &.{fill()}));
    outside = copy();
    outside.copy.destination.x = 640;
    try t.expectError(error.OutOfBounds, queue.submit(1, &.{outside}));
    try t.expectEqual(@as(usize, 0), mock.calls);
}

test "device metadata is truthful provider data and must be usable" {
    var mock: Mock = .{};
    mock.device.acceleration = .hardware;
    const queue = try anvil.Queue.init(mock.provider());
    try t.expectEqual(anvil.Acceleration.hardware, queue.device.acceleration);
    try t.expectEqualStrings(mock.device.name, queue.device.name);
    mock.device.name = "";
    try t.expectError(error.InvalidDeviceInfo, anvil.Queue.init(mock.provider()));
    mock = .{};
    mock.device.formats = .{ .xrgb8888 = false, .xbgr8888 = false };
    try t.expectError(error.InvalidDeviceInfo, anvil.Queue.init(mock.provider()));
    mock = .{};
    mock.device.max_texture_extent.width = anvil.max_texture_dimension + 1;
    try t.expectError(error.InvalidDeviceInfo, anvil.Queue.init(mock.provider()));
    mock = .{};
    mock.info_error = error.DeviceUnavailable;
    try t.expectError(error.DeviceUnavailable, anvil.Queue.init(mock.provider()));
}

test "submission sequences and rejection retry are explicit" {
    var mock: Mock = .{};
    var queue = try anvil.Queue.init(mock.provider());
    try t.expectError(error.InvalidSequence, queue.submit(0, &.{fill()}));
    mock.submit_error = error.ResourceBusy;
    try t.expectError(error.ResourceBusy, queue.submit(3, &.{fill()}));
    try t.expectEqual(@as(u64, 0), queue.last_submitted);
    mock.submit_error = null;
    const fence = try queue.submit(3, &.{fill()});
    try t.expectEqual(@as(u64, 3), fence.sequence);
    try t.expectError(error.InvalidSequence, queue.submit(3, &.{fill()}));
    try t.expectError(error.InvalidSequence, queue.submit(2, &.{fill()}));
    try t.expectEqual(@as(usize, 2), mock.calls);
    _ = try queue.submit(std.math.maxInt(u64), &.{copy()});
    try t.expectError(error.InvalidSequence, queue.submit(std.math.maxInt(u64), &.{fill()}));
}

test "invalid acceptance fence poisons the queue instead of retrying executed work" {
    var mock: Mock = .{ .result = 2 };
    var queue = try anvil.Queue.init(mock.provider());
    try t.expectError(error.InvalidProviderResult, queue.submit(1, &.{fill()}));
    mock.result = null;
    try t.expectError(error.InvalidProviderResult, queue.submit(2, &.{fill()}));
    try t.expectError(error.InvalidProviderResult, queue.completed());
    try t.expectEqual(@as(usize, 1), mock.calls);
    try t.expectEqual(@as(usize, 0), mock.completion_calls);
}

test "asynchronous completion keeps resources in flight while batch storage is reusable" {
    var mock: Mock = .{};
    var queue = try anvil.Queue.init(mock.provider());
    var storage: [1]anvil.Command = undefined;
    var batch = try anvil.Batch.init(&storage);
    try batch.append(fill());
    const first = try queue.submit(1, batch.commands());
    batch.reset();
    try batch.append(copy());
    try t.expectEqualDeep(fill(), mock.copied[0]);
    try t.expect(!try queue.isComplete(first));
    const second = try queue.submit(2, batch.commands());
    mock.completion = 1;
    try t.expect(try queue.isComplete(first));
    try t.expect(!try queue.isComplete(second));
    mock.completion = 2;
    try t.expect(try queue.isComplete(second));
    try t.expectError(error.InvalidFence, queue.isComplete(.{ .sequence = 0 }));
    try t.expectError(error.InvalidFence, queue.isComplete(.{ .sequence = 3 }));
}

test "CPU synchronous completion is immediate without fabricating a hardware device" {
    var mock: Mock = .{ .immediate = true };
    var queue = try anvil.Queue.init(mock.provider());
    const fence = try queue.submit(1, &.{fill()});
    try t.expect(try queue.isComplete(fence));
    try t.expectEqual(anvil.Acceleration.software, queue.device.acceleration);
}

test "completion cannot move backwards or acknowledge unsubmitted work" {
    var mock: Mock = .{};
    var queue = try anvil.Queue.init(mock.provider());
    try t.expectEqual(@as(u64, 0), (try queue.completed()).sequence);
    _ = try queue.submit(1, &.{fill()});
    mock.completion_error = error.DeviceBusy;
    try t.expectError(error.DeviceBusy, queue.completed());
    mock.completion_error = null;
    mock.completion = 1;
    _ = try queue.completed();
    mock.completion = 0;
    try t.expectError(error.InvalidProviderResult, queue.completed());
    try t.expectError(error.InvalidProviderResult, queue.submit(2, &.{fill()}));
    mock = .{};
    queue = try anvil.Queue.init(mock.provider());
    mock.completion = 1;
    try t.expectError(error.InvalidProviderResult, queue.completed());
}
