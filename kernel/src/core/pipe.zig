//! Bounded byte-stream pipes. The single-CPU kernel owns synchronization,
//! descriptor authority and quota charges; this module owns FIFO/ref lifetimes.
const std = @import("std");
pub const read_right: u64 = 1;
pub const write_right: u64 = 2;
pub const descriptor_tag: u64 = 1 << 62;
pub const Grant = struct { object: u64, rights: u64 };
pub const Descriptor = enum(u64) { _ };

pub fn Pipes(comptime capacity: usize, comptime buffer_size: usize) type {
    return struct {
        const Self = @This();
        const Entry = struct {
            generation: u32 = 1,
            retired: bool = false,
            live: bool = false,
            readers: usize = 0,
            writers: usize = 0,
            head: usize = 0,
            length: usize = 0,
            bytes: [buffer_size]u8 = @splat(0),
        };
        entries: [capacity]Entry = @splat(.{}),

        pub fn create(self: *Self) !u64 {
            if (comptime capacity == 0 or buffer_size == 0) return error.PipeCapacity;
            for (&self.entries, 0..) |*entry, index| {
                if (entry.live or entry.retired) continue;
                entry.live = true;
                entry.head = 0;
                entry.length = 0;
                entry.readers = 0;
                entry.writers = 0;
                @memset(&entry.bytes, 0);
                return (@as(u64, entry.generation) << 32) | (index + 1);
            }
            return error.PipeCapacity;
        }

        fn resolve(self: *Self, object: u64) !*Entry {
            const slot: u32 = @truncate(object);
            const generation: u32 = @truncate(object >> 32);
            if (slot == 0 or slot > capacity or generation == 0) return error.InvalidPipe;
            if (comptime capacity == 0) return error.InvalidPipe;
            const entry = &self.entries[slot - 1];
            if (!entry.live or entry.generation != generation) return error.InvalidPipe;
            return entry;
        }

        pub fn retain(self: *Self, grant: Grant) !void {
            try validRights(grant.rights);
            const entry = try self.resolve(grant.object);
            const readers = try std.math.add(usize, entry.readers, @intFromBool(grant.rights & read_right != 0));
            const writers = try std.math.add(usize, entry.writers, @intFromBool(grant.rights & write_right != 0));
            entry.readers = readers;
            entry.writers = writers;
        }

        /// Returns discarded bytes so the caller can release their charge.
        pub fn release(self: *Self, grant: Grant) !usize {
            try validRights(grant.rights);
            const entry = try self.resolve(grant.object);
            if (grant.rights & read_right != 0 and entry.readers == 0 or
                grant.rights & write_right != 0 and entry.writers == 0) return error.PipeReferenceUnderflow;
            if (grant.rights & read_right != 0) entry.readers -= 1;
            if (grant.rights & write_right != 0) entry.writers -= 1;
            var discarded: usize = 0;
            if (entry.readers == 0) {
                discarded = entry.length;
                entry.length = 0;
                entry.head = 0;
                @memset(&entry.bytes, 0);
            }
            if (entry.readers == 0 and entry.writers == 0) recycle(entry);
            return discarded;
        }

        /// Roll back construction before any descriptor refers to this object.
        pub fn abandon(self: *Self, object: u64) !void {
            const entry = try self.resolve(object);
            if (entry.readers != 0 or entry.writers != 0 or entry.length != 0) return error.PipeStillReferenced;
            recycle(entry);
        }

        fn recycle(entry: *Entry) void {
            entry.live = false;
            if (entry.generation == std.math.maxInt(u32)) entry.retired = true else entry.generation += 1;
        }

        pub fn read(self: *Self, grant: Grant, output: []u8) !usize {
            if (grant.rights & read_right == 0) return error.PermissionDenied;
            const entry = try self.resolve(grant.object);
            if (output.len == 0) return 0;
            if (entry.length == 0) return if (entry.writers == 0) 0 else error.WouldBlock;
            if (comptime buffer_size == 0) return error.PipeCapacity;
            const length = @min(output.len, entry.length);
            for (output[0..length], 0..) |*byte, index| byte.* = entry.bytes[(entry.head + index) % buffer_size];
            for (0..length) |index| entry.bytes[(entry.head + index) % buffer_size] = 0;
            entry.head = (entry.head + length) % buffer_size;
            entry.length -= length;
            return length;
        }

        /// Writes up to buffer_size bytes atomically, or leaves FIFO unchanged.
        pub fn write(self: *Self, grant: Grant, input: []const u8) !usize {
            if (grant.rights & write_right == 0) return error.PermissionDenied;
            const entry = try self.resolve(grant.object);
            if (entry.readers == 0) return error.ChannelClosed;
            if (input.len > buffer_size) return error.MessageTooLarge;
            if (input.len > buffer_size - entry.length) return error.WouldBlock;
            if (comptime buffer_size == 0) return 0;
            for (input, 0..) |byte, index| entry.bytes[(entry.head + entry.length + index) % buffer_size] = byte;
            entry.length += input.len;
            return input.len;
        }

        pub fn liveCount(self: *const Self) usize {
            var count: usize = 0;
            for (self.entries) |entry| count += @intFromBool(entry.live);
            return count;
        }
    };
}

pub fn Descriptors(comptime capacity: usize) type {
    return struct {
        const Self = @This();
        const Slot = struct { generation: u32 = 1, retired: bool = false, grant: ?Grant = null };
        app_id: u64 = 0,
        slots: [capacity]Slot = @splat(.{}),

        pub fn init(app_id: u64) !Self {
            if (app_id == 0) return error.PermissionDenied;
            return .{ .app_id = app_id };
        }
        pub fn insert(self: *Self, app_id: u64, grant: Grant) !Descriptor {
            if (app_id != self.app_id or app_id == 0) return error.PermissionDenied;
            try validRights(grant.rights);
            if (grant.object == 0) return error.InvalidPipe;
            for (&self.slots, 0..) |*slot, index| {
                if (slot.grant != null or slot.retired) continue;
                slot.grant = grant;
                return @fromBackingInt(descriptor_tag | (@as(u64, slot.generation) << 32) | (index + 1));
            }
            return error.TableFull;
        }
        fn slotFor(self: *const Self, app_id: u64, descriptor: Descriptor) !usize {
            if (app_id != self.app_id or app_id == 0) return error.PermissionDenied;
            const raw = @backingInt(descriptor);
            if (raw & (3 << 62) != descriptor_tag) return error.InvalidToken;
            const slot: u32 = @truncate(raw);
            const generation: u32 = @intCast((raw >> 32) & 0x3fff_ffff);
            if (slot == 0 or slot > capacity or generation == 0) return error.InvalidToken;
            if (comptime capacity == 0) return error.InvalidToken;
            const entry = &self.slots[slot - 1];
            if (entry.grant == null or entry.generation != generation) return error.StaleToken;
            return slot - 1;
        }
        pub fn resolve(self: *const Self, app_id: u64, descriptor: Descriptor, rights: u64) !Grant {
            if (comptime capacity == 0) return error.InvalidToken;
            const index = try self.slotFor(app_id, descriptor);
            const grant = self.slots[index].grant.?;
            if (rights & ~grant.rights != 0) return error.PermissionDenied;
            return grant;
        }
        pub fn close(self: *Self, app_id: u64, descriptor: Descriptor) !Grant {
            if (comptime capacity == 0) return error.InvalidToken;
            const index = try self.slotFor(app_id, descriptor);
            const slot = &self.slots[index];
            const grant = slot.grant.?;
            slot.grant = null;
            if (slot.generation == 0x3fff_ffff) slot.retired = true else slot.generation += 1;
            return grant;
        }
        pub fn tokenAt(self: *const Self, index: usize) ?Descriptor {
            if (index >= capacity or self.slots[index].grant == null) return null;
            return @fromBackingInt(descriptor_tag | (@as(u64, self.slots[index].generation) << 32) | (index + 1));
        }
        pub fn count(self: *const Self) usize {
            var result: usize = 0;
            for (self.slots) |slot| result += @intFromBool(slot.grant != null);
            return result;
        }
    };
}

fn validRights(rights: u64) !void {
    if (rights == 0 or rights & ~(read_right | write_right) != 0) return error.PermissionDenied;
}

test "pipe FIFO wraps, full writes are atomic, last writer gives buffered data then EOF" {
    var pool: Pipes(1, 4) = .{};
    const id = try pool.create();
    const reader: Grant = .{ .object = id, .rights = read_right };
    const writer: Grant = .{ .object = id, .rights = write_right };
    try pool.retain(reader);
    try pool.retain(writer);
    var out: [4]u8 = undefined;
    try std.testing.expectError(error.WouldBlock, pool.read(reader, &out));
    try std.testing.expectEqual(@as(usize, 3), try pool.write(writer, "abc"));
    try std.testing.expectError(error.WouldBlock, pool.write(writer, "de"));
    try std.testing.expectEqual(@as(usize, 2), try pool.read(reader, out[0..2]));
    try std.testing.expectEqualStrings("ab", out[0..2]);
    _ = try pool.write(writer, "def");
    _ = try pool.release(writer);
    try std.testing.expectEqual(@as(usize, 4), try pool.read(reader, &out));
    try std.testing.expectEqualStrings("cdef", &out);
    try std.testing.expectEqual(@as(usize, 0), try pool.read(reader, &out));
    _ = try pool.release(reader);
    try std.testing.expectEqual(@as(usize, 0), pool.liveCount());
    try std.testing.expectError(error.InvalidPipe, pool.read(reader, &out));
    try std.testing.expect(try pool.create() != id);
}

test "last reader discards bytes, closes peer and releases exact queued charge" {
    var pool: Pipes(1, 4) = .{};
    const id = try pool.create();
    const r: Grant = .{ .object = id, .rights = read_right };
    const w: Grant = .{ .object = id, .rights = write_right };
    try pool.retain(r);
    try pool.retain(w);
    _ = try pool.write(w, "abc");
    try std.testing.expectEqual(@as(usize, 3), try pool.release(r));
    try std.testing.expectError(error.ChannelClosed, pool.write(w, "x"));
    try std.testing.expectEqual(@as(usize, 0), try pool.release(w));
    try std.testing.expectError(error.InvalidPipe, pool.release(w));
}

test "pipe descriptors bind identity and retain only existing rights" {
    var table = try Descriptors(2).init(7);
    const original = try table.insert(7, .{ .object = 9, .rights = read_right });
    try std.testing.expectError(error.PermissionDenied, table.resolve(8, original, read_right));
    try std.testing.expectError(error.PermissionDenied, table.resolve(7, original, write_right));
    try std.testing.expectError(error.InvalidToken, table.resolve(7, @fromBackingInt(1), 0));
    _ = try table.close(7, original);
    const replacement = try table.insert(7, .{ .object = 9, .rights = write_right });
    try std.testing.expect(original != replacement);
    try std.testing.expectError(error.StaleToken, table.resolve(7, original, 0));
    table.slots[0].generation = 0x3fff_ffff;
    _ = try table.close(7, table.tokenAt(0).?);
    try std.testing.expect(table.slots[0].retired);
    _ = try table.insert(7, .{ .object = 9, .rights = read_right });
    try std.testing.expectError(error.TableFull, table.insert(7, .{ .object = 9, .rights = read_right }));
    var empty = try Descriptors(0).init(7);
    try std.testing.expectError(error.TableFull, empty.insert(7, .{ .object = 9, .rights = read_right }));
    try std.testing.expectError(error.InvalidToken, empty.resolve(7, original, 0));
    var no_pipes: Pipes(0, 0) = .{};
    try std.testing.expectError(error.PipeCapacity, no_pipes.create());
}
