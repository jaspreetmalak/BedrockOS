//! Allocation-free 2D graphics commands. Providers own authorization, resource
//! lifetime and execution. Importing Anvil does not discover or grant a GPU.
const std = @import("std");

pub const max_commands: usize = 64;
pub const max_texture_dimension: u32 = 16384;
pub const Format = enum { xrgb8888, xbgr8888 };
pub const Acceleration = enum { software, hardware };

/// An opaque, provider-local resource token. Possession is not authorization.
pub const Texture = struct {
    token: u64,

    pub fn validate(self: Texture) !void {
        if (self.token == 0) return error.InvalidTexture;
    }
};

pub const Extent = struct {
    width: u32,
    height: u32,

    pub fn validate(self: Extent) !void {
        if (self.width == 0 or self.height == 0) return error.EmptyExtent;
        const pixels = std.math.mul(usize, self.width, self.height) catch return error.Overflow;
        _ = std.math.mul(usize, pixels, @sizeOf(u32)) catch return error.Overflow;
    }
};

pub const Point = struct { x: u32, y: u32 };

pub const Rect = struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,

    pub fn validate(self: Rect) !void {
        try (Extent{ .width = self.width, .height = self.height }).validate();
        _ = std.math.add(u32, self.x, self.width) catch return error.Overflow;
        _ = std.math.add(u32, self.y, self.height) catch return error.Overflow;
    }

    /// Checked half-open bounds. No clipping or wrapping is implicit.
    pub fn fits(self: Rect, extent: Extent) !bool {
        try self.validate();
        try extent.validate();
        return self.x + self.width <= extent.width and self.y + self.height <= extent.height;
    }
};

pub const Fill = struct {
    target: Texture,
    rect: Rect,
    /// Canonical 0x00RRGGBB. Alpha and reserved high bits must be zero.
    color: u32,
};

pub const Copy = struct {
    source: Texture,
    target: Texture,
    source_rect: Rect,
    destination: Point,

    pub fn destinationRect(self: Copy) Rect {
        return .{
            .x = self.destination.x,
            .y = self.destination.y,
            .width = self.source_rect.width,
            .height = self.source_rect.height,
        };
    }
};

/// Commands execute in order. A same-texture copy has memmove semantics even
/// when its source and destination overlap. There is no scaling or blending.
pub const Command = union(enum) { fill: Fill, copy: Copy };

/// Schema checks only. Providers must additionally resolve authority and all
/// actual resource bounds for the complete batch before changing any pixels.
pub fn validateCommand(command: Command) !void {
    switch (command) {
        .fill => |fill| {
            try fill.target.validate();
            try fill.rect.validate();
            if (fill.color & 0xff00_0000 != 0) return error.InvalidColor;
        },
        .copy => |copy| {
            try copy.source.validate();
            try copy.target.validate();
            try copy.source_rect.validate();
            try copy.destinationRect().validate();
        },
    }
}

pub fn validateCommands(commands: []const Command) !void {
    if (commands.len == 0) return error.EmptyBatch;
    if (commands.len > max_commands) return error.TooManyCommands;
    for (commands) |command| try validateCommand(command);
}

/// Caller-owned command storage. Failed appends leave storage and length
/// unchanged. Reset is safe after submit returns: async providers copy commands.
pub const Batch = struct {
    storage: []Command,
    len: usize = 0,

    pub fn init(storage: []Command) !Batch {
        if (storage.len > max_commands) return error.TooManyCommands;
        return .{ .storage = storage };
    }

    pub fn append(self: *Batch, command: Command) !void {
        try validateCommand(command);
        if (self.len >= self.storage.len) return error.BufferTooSmall;
        self.storage[self.len] = command;
        self.len += 1;
    }

    pub fn appendSlice(self: *Batch, commands_to_append: []const Command) !void {
        if (commands_to_append.len == 0) return;
        try validateCommands(commands_to_append);
        if (self.len > self.storage.len or commands_to_append.len > self.storage.len - self.len) return error.BufferTooSmall;
        const output = self.storage[self.len..][0..commands_to_append.len];
        if (@intFromPtr(output.ptr) > @intFromPtr(commands_to_append.ptr)) {
            std.mem.copyBackwards(Command, output, commands_to_append);
        } else {
            std.mem.copyForwards(Command, output, commands_to_append);
        }
        self.len += commands_to_append.len;
    }

    pub fn commands(self: *const Batch) []const Command {
        return self.storage[0..self.len];
    }

    pub fn reset(self: *Batch) void {
        self.len = 0;
    }
};

pub const Capabilities = struct { fill: bool = false, copy: bool = false };
pub const Formats = struct { xrgb8888: bool = true, xbgr8888: bool = true };

pub const DeviceInfo = struct {
    /// Borrowed for the queue lifetime; report the executing backend accurately.
    name: []const u8,
    acceleration: Acceleration,
    capabilities: Capabilities,
    max_texture_extent: Extent,
    formats: Formats = .{},

    pub fn validate(self: DeviceInfo) !void {
        if (self.name.len == 0) return error.InvalidDeviceInfo;
        if (!self.formats.xrgb8888 and !self.formats.xbgr8888) return error.InvalidDeviceInfo;
        try self.max_texture_extent.validate();
        if (self.max_texture_extent.width > max_texture_dimension or
            self.max_texture_extent.height > max_texture_dimension) return error.InvalidDeviceInfo;
    }
};

/// Zero is the initial completed value; submitted fences are nonzero. A fence
/// belongs to one queue and cannot be used as a fence for another provider.
pub const Fence = struct { sequence: u64 };

pub const Provider = struct {
    context: *anyopaque,
    info: *const fn (*anyopaque) anyerror!DeviceInfo,
    /// Validate the complete batch, including authorization and bounds, before
    /// writes. Success accepts the exact sequence; errors must not accept work.
    /// Commands may be borrowed only during this call. An async implementation
    /// copies them before returning. Texture storage stays alive until completed.
    submit: *const fn (*anyopaque, u64, []const Command) anyerror!Fence,
    /// Largest completed sequence, zero initially. Completion means all earlier
    /// submissions are finished and their writes are visible to the caller.
    completed: *const fn (*anyopaque) anyerror!Fence,
};

/// A serialized, single-owner view of one provider queue. Keep its provider and
/// resource context alive; copying this struct does not create a new queue.
/// The provider must be dedicated to this Queue, including its sequence domain.
pub const Queue = struct {
    provider: Provider,
    device: DeviceInfo,
    last_submitted: u64 = 0,
    last_completed: u64 = 0,
    poisoned: bool = false,

    pub fn init(provider: Provider) !Queue {
        const device = try provider.info(provider.context);
        try device.validate();
        return .{ .provider = provider, .device = device };
    }

    pub fn submit(self: *Queue, sequence: u64, commands_to_submit: []const Command) !Fence {
        if (self.poisoned) return error.InvalidProviderResult;
        if (sequence == 0 or sequence <= self.last_submitted) return error.InvalidSequence;
        try validateCommands(commands_to_submit);
        for (commands_to_submit) |command| {
            switch (command) {
                .fill => |fill| {
                    if (!self.device.capabilities.fill) return error.UnsupportedOperation;
                    if (!try fill.rect.fits(self.device.max_texture_extent)) return error.OutOfBounds;
                },
                .copy => |copy| {
                    if (!self.device.capabilities.copy) return error.UnsupportedOperation;
                    if (!try copy.source_rect.fits(self.device.max_texture_extent) or
                        !try copy.destinationRect().fits(self.device.max_texture_extent)) return error.OutOfBounds;
                },
            }
        }
        const fence = try self.provider.submit(self.provider.context, sequence, commands_to_submit);
        if (fence.sequence != sequence) {
            self.poisoned = true;
            return error.InvalidProviderResult;
        }
        self.last_submitted = sequence;
        return fence;
    }

    pub fn completed(self: *Queue) !Fence {
        if (self.poisoned) return error.InvalidProviderResult;
        const fence = try self.provider.completed(self.provider.context);
        if (fence.sequence < self.last_completed or fence.sequence > self.last_submitted) {
            self.poisoned = true;
            return error.InvalidProviderResult;
        }
        self.last_completed = fence.sequence;
        return fence;
    }

    pub fn isComplete(self: *Queue, fence: Fence) !bool {
        if (fence.sequence == 0 or fence.sequence > self.last_submitted) return error.InvalidFence;
        return (try self.completed()).sequence >= fence.sequence;
    }
};

test {
    _ = @import("tests.zig");
}
