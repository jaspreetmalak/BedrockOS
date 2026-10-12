const std = @import("std");
pub const ramfs = @import("ramfs.zig");
pub const durable = @import("durable.zig");

test {
    _ = ramfs;
    _ = durable;
}

/// Failures detected before a storage backend is invoked.
pub const ValidationError = error{
    InvalidGeometry,
    InvalidBufferLength,
    OutOfBounds,
    ArithmeticOverflow,
    ReadOnly,
    FlushUnavailable,
};

/// Includes ValidationError and preserves the backend's own error values.
pub const ReadError = anyerror;

pub const ReadFn = *const fn (
    context: *anyopaque,
    start_block: u64,
    block_count: u64,
    buffer: []u8,
) ReadError!void;
pub const WriteError = anyerror;
pub const WriteFn = *const fn (context: *anyopaque, start_block: u64, block_count: u64, buffer: []const u8) WriteError!void;
pub const FlushFn = *const fn (context: *anyopaque) WriteError!void;

/// Borrowed storage interface. The caller owns the context, buffer and backend.
/// The callback must finish using the buffer before returning.
pub const BlockDevice = struct {
    context: *anyopaque,
    read_fn: ReadFn,
    write_fn: ?WriteFn = null,
    flush_fn: ?FlushFn = null,
    block_size: u32,
    block_count: u64,

    /// Read whole blocks. Empty reads at a valid position succeed without I/O.
    /// Device capacity and request ranges must be representable in u64 bytes.
    pub fn read(self: BlockDevice, start_block: u64, buffer: []u8) ReadError!void {
        const requested_blocks = try self.validateRange(start_block, buffer.len);
        if (requested_blocks == 0) return;

        try self.read_fn(self.context, start_block, requested_blocks, buffer);
    }

    pub fn write(self: BlockDevice, start_block: u64, buffer: []const u8) WriteError!void {
        const requested_blocks = try self.validateRange(start_block, buffer.len);
        const callback = self.write_fn orelse return error.ReadOnly;
        if (requested_blocks == 0) return;
        try callback(self.context, start_block, requested_blocks, buffer);
    }

    /// A successful flush guarantees prior writes reached the backend's durable
    /// storage. A failed flush has an uncertain outcome; callers must recover.
    pub fn flush(self: BlockDevice) WriteError!void {
        try self.validateGeometry();
        const callback = self.flush_fn orelse return error.FlushUnavailable;
        try callback(self.context);
    }

    fn validateGeometry(self: BlockDevice) ValidationError!void {
        if (self.block_size == 0 or self.block_count == 0) return error.InvalidGeometry;
        _ = std.math.mul(u64, self.block_size, self.block_count) catch return error.ArithmeticOverflow;
    }

    fn validateRange(self: BlockDevice, start_block: u64, length: usize) ValidationError!u64 {
        try self.validateGeometry();
        const byte_count = std.math.cast(u64, length) orelse return error.ArithmeticOverflow;
        if (byte_count % self.block_size != 0) return error.InvalidBufferLength;
        const requested_blocks = byte_count / self.block_size;
        const end_block = std.math.add(u64, start_block, requested_blocks) catch return error.ArithmeticOverflow;
        if (start_block > self.block_count or end_block > self.block_count) return error.OutOfBounds;
        return requested_blocks;
    }
};

const TestBackend = struct {
    calls: usize = 0,
    start_block: u64 = 0,
    block_count: u64 = 0,
    byte_count: usize = 0,
    failure: ?anyerror = null,
    writes: usize = 0,
    flushes: usize = 0,

    fn read(context: *anyopaque, start_block: u64, block_count: u64, buffer: []u8) ReadError!void {
        const self: *TestBackend = @ptrCast(@alignCast(context));
        self.calls += 1;
        self.start_block = start_block;
        self.block_count = block_count;
        self.byte_count = buffer.len;
        if (self.failure) |failure| return failure;
        @memset(buffer, 0xa5);
    }

    fn device(self: *TestBackend, block_size: u32, block_count: u64) BlockDevice {
        return .{
            .context = self,
            .read_fn = read,
            .block_size = block_size,
            .block_count = block_count,
        };
    }

    fn write(context: *anyopaque, start_block: u64, block_count: u64, buffer: []const u8) WriteError!void {
        const self: *TestBackend = @ptrCast(@alignCast(context));
        self.writes += 1;
        self.start_block = start_block;
        self.block_count = block_count;
        self.byte_count = buffer.len;
        if (self.failure) |failure| return failure;
    }

    fn flush(context: *anyopaque) WriteError!void {
        const self: *TestBackend = @ptrCast(@alignCast(context));
        self.flushes += 1;
        if (self.failure) |failure| return failure;
    }

    fn writableDevice(self: *TestBackend, block_size: u32, block_count: u64) BlockDevice {
        var result = self.device(block_size, block_count);
        result.write_fn = write;
        result.flush_fn = flush;
        return result;
    }
};

test "invalid geometry, buffer and range never reach the backend" {
    var backend: TestBackend = .{};
    var buffer: [8]u8 = undefined;

    try std.testing.expectError(error.InvalidGeometry, backend.device(0, 4).read(0, &buffer));
    try std.testing.expectError(error.InvalidGeometry, backend.device(4, 0).read(0, &buffer));
    try std.testing.expectError(error.InvalidBufferLength, backend.device(4, 4).read(0, buffer[0..5]));
    try std.testing.expectError(error.OutOfBounds, backend.device(4, 4).read(3, &buffer));
    try std.testing.expectError(error.OutOfBounds, backend.device(4, 4).read(5, buffer[0..0]));
    try std.testing.expectEqual(@as(usize, 0), backend.calls);
}

test "capacity and request overflow never reach the backend" {
    var backend: TestBackend = .{};
    var buffer: [2]u8 = undefined;

    try std.testing.expectError(
        error.ArithmeticOverflow,
        backend.device(2, std.math.maxInt(u64)).read(0, &buffer),
    );
    try std.testing.expectError(
        error.ArithmeticOverflow,
        backend.device(1, std.math.maxInt(u64)).read(std.math.maxInt(u64), &buffer),
    );
    try std.testing.expectEqual(@as(usize, 0), backend.calls);
}

test "whole-block read ending at capacity forwards the request and buffer" {
    var backend: TestBackend = .{};
    var buffer: [8]u8 = @splat(0);

    try backend.device(4, 4).read(2, &buffer);
    try std.testing.expectEqual(@as(usize, 1), backend.calls);
    try std.testing.expectEqual(@as(u64, 2), backend.start_block);
    try std.testing.expectEqual(@as(u64, 2), backend.block_count);
    try std.testing.expectEqual(buffer.len, backend.byte_count);
    for (buffer) |byte| try std.testing.expectEqual(@as(u8, 0xa5), byte);
}

test "empty reads permit the end position and do not invoke the backend" {
    var backend: TestBackend = .{};
    var buffer: [0]u8 = .{};

    try backend.device(4, 4).read(0, &buffer);
    try backend.device(4, 4).read(4, &buffer);
    try std.testing.expectEqual(@as(usize, 0), backend.calls);
}

test "backend failure is forwarded unchanged" {
    var backend: TestBackend = .{ .failure = error.MediaFailure };
    var buffer: [4]u8 = undefined;

    try std.testing.expectError(error.MediaFailure, backend.device(4, 4).read(0, &buffer));
    try std.testing.expectEqual(@as(usize, 1), backend.calls);
}

test "write and flush validate geometry and authority before backend calls" {
    var backend: TestBackend = .{};
    const bytes = [_]u8{ 1, 2, 3, 4 };
    try std.testing.expectError(error.InvalidGeometry, backend.writableDevice(0, 4).write(0, &bytes));
    try std.testing.expectError(error.InvalidBufferLength, backend.writableDevice(4, 4).write(0, bytes[0..3]));
    try std.testing.expectError(error.OutOfBounds, backend.writableDevice(4, 4).write(4, &bytes));
    try std.testing.expectError(error.ArithmeticOverflow, backend.writableDevice(1, std.math.maxInt(u64)).write(std.math.maxInt(u64), &bytes));
    try std.testing.expectError(error.ReadOnly, backend.device(4, 4).write(0, &bytes));
    try std.testing.expectError(error.InvalidGeometry, backend.writableDevice(4, 0).flush());
    try std.testing.expectError(error.FlushUnavailable, backend.device(4, 4).flush());
    try std.testing.expectEqual(@as(usize, 0), backend.writes);
    try std.testing.expectEqual(@as(usize, 0), backend.flushes);
    try backend.writableDevice(4, 4).write(4, bytes[0..0]);
    try std.testing.expectEqual(@as(usize, 0), backend.writes);
}

test "whole writes and durability flush route arguments and preserve backend errors" {
    var backend: TestBackend = .{};
    const bytes = [_]u8{ 1, 2, 3, 4 };
    try backend.writableDevice(4, 4).write(3, &bytes);
    try std.testing.expectEqual(@as(u64, 3), backend.start_block);
    try std.testing.expectEqual(@as(u64, 1), backend.block_count);
    try std.testing.expectEqual(bytes.len, backend.byte_count);
    try backend.writableDevice(4, 4).flush();
    try std.testing.expectEqual(@as(usize, 1), backend.flushes);
    backend.failure = error.MediaFailure;
    try std.testing.expectError(error.MediaFailure, backend.writableDevice(4, 4).write(0, &bytes));
    try std.testing.expectError(error.MediaFailure, backend.writableDevice(4, 4).flush());
}
