//! Session-lived RAM nodes. The caller authorizes operations and serializes use.
//! Borrowed file bytes must remain immutable and alive until reset.
const std = @import("std");
const secure_clear = @import("secure_clear.zig");

pub const NodeId = enum(u64) { _ };
pub const Kind = enum { directory, mutable_file, borrowed_file };
pub const Domain = enum { system, bundle, container };
pub const Metadata = struct {
    domain: Domain = .system,
    owner: u64 = 0,
    executable: bool = false,
};
pub const Stat = struct { id: NodeId, kind: Kind, metadata: Metadata, size: u64 };
pub const Error = error{
    NotInitialized,
    InvalidNode,
    StaleNode,
    GenerationExhausted,
    InvalidPath,
    PathTooLong,
    InvalidMetadata,
    AlreadyExists,
    NotFound,
    NotDirectory,
    IsDirectory,
    ReadOnly,
    NodeCapacity,
    FileTooLarge,
    ArithmeticOverflow,
    OutOfBounds,
};

/// Capacity includes the root and directory nodes. Nullified slots stay retired
/// until reset; no slot recycling occurs within an epoch.
pub fn RamFs(comptime node_capacity: usize, comptime file_bytes: usize, comptime path_bytes: usize) type {
    if (node_capacity == 0 or node_capacity > std.math.maxInt(u32))
        @compileError("RAM filesystem requires a bounded root/node capacity");
    if (path_bytes == 0) @compileError("RAM filesystem paths must hold the root");
    return struct {
        const Self = @This();
        const Node = struct {
            occupied: bool = false,
            retired: bool = false,
            kind: Kind = .directory,
            metadata: Metadata = .{},
            parent: usize = 0,
            path_length: usize = 0,
            path_buffer: [path_bytes]u8 = @splat(0),
            length: usize = 0,
            borrowed: []const u8 = &.{},
            data: [file_bytes]u8 = @splat(0),
        };
        pub const max_nodes = node_capacity;
        pub const max_path_bytes = path_bytes;
        pub const max_file_bytes = file_bytes;

        generation: u32 = 0,
        nodes: [node_capacity]Node = @splat(.{}),

        /// Initialize in place; avoid a large aggregate on a small kernel stack.
        /// Failure at epoch exhaustion leaves the old session intact.
        pub fn reset(self: *Self) Error!void {
            if (self.generation == std.math.maxInt(u32)) return error.GenerationExhausted;
            @memset(std.mem.asBytes(&self.nodes), 0);
            // Reestablish valid empty slice pointers after clearing the records.
            for (&self.nodes) |*node| node.borrowed = &.{};
            self.generation += 1;
            const node = &self.nodes[0];
            node.occupied = true;
            node.kind = .directory;
            node.path_length = 1;
            node.path_buffer[0] = '/';
        }

        pub fn root(self: *const Self) Error!NodeId {
            if (self.generation == 0) return error.NotInitialized;
            return self.identity(0);
        }

        /// Absolute byte paths must already be canonical. No normalization can
        /// hide an empty component, dot traversal, NUL or trailing separator.
        pub fn lookup(self: *const Self, absolute: []const u8) Error!NodeId {
            if (self.generation == 0) return error.NotInitialized;
            try validatePath(absolute);
            const index = self.find(absolute) orelse return error.NotFound;
            return self.identity(index);
        }

        pub fn mkdir(self: *Self, absolute: []const u8, metadata: Metadata) Error!NodeId {
            return self.insert(absolute, metadata, .directory, &.{});
        }

        pub fn create(self: *Self, absolute: []const u8, metadata: Metadata) Error!NodeId {
            return self.insert(absolute, metadata, .mutable_file, &.{});
        }

        /// Arbitrary borrowed length is independent of mutable-file capacity.
        pub fn addBorrowed(self: *Self, absolute: []const u8, metadata: Metadata, bytes: []const u8) Error!NodeId {
            return self.insert(absolute, metadata, .borrowed_file, bytes);
        }

        pub fn stat(self: *const Self, id: NodeId) Error!Stat {
            const index = try self.slot(id);
            const node = &self.nodes[index];
            return .{ .id = id, .kind = node.kind, .metadata = node.metadata, .size = node.length };
        }

        pub fn size(self: *const Self, id: NodeId) Error!u64 {
            const node = &self.nodes[try self.slot(id)];
            if (node.kind == .directory) return error.IsDirectory;
            return node.length;
        }

        /// Borrowed views are invalidated by writes/truncation/reset; they do
        /// not confer authority. Keep immutable-file source ownership outside.
        pub fn contents(self: *const Self, id: NodeId) Error![]const u8 {
            const node = &self.nodes[try self.slot(id)];
            return switch (node.kind) {
                .directory => error.IsDirectory,
                .mutable_file => node.data[0..node.length],
                .borrowed_file => node.borrowed,
            };
        }

        pub fn path(self: *const Self, id: NodeId) Error![]const u8 {
            const node = &self.nodes[try self.slot(id)];
            return node.path_buffer[0..node.path_length];
        }

        /// EOF reads return zero. Validate arithmetic before touching output.
        pub fn read(self: *const Self, id: NodeId, offset: u64, output: []u8) Error!usize {
            const bytes = try self.contents(id);
            _ = try rangeEnd(offset, output.len);
            if (offset >= bytes.len or output.len == 0) return 0;
            const start: usize = @intCast(offset);
            const count = @min(bytes.len - start, output.len);
            move(output[0..count], bytes[start..][0..count]);
            return count;
        }

        /// A write is whole or fails. Gaps are zero-filled; zero-byte writes do
        /// not extend size. Inputs may overlap the file's currently live bytes.
        pub fn write(self: *Self, id: NodeId, offset: u64, input: []const u8) Error!usize {
            const node = &self.nodes[try self.slot(id)];
            switch (node.kind) {
                .directory => return error.IsDirectory,
                .borrowed_file => return error.ReadOnly,
                .mutable_file => {},
            }
            const until = try rangeEnd(offset, input.len);
            if (until > file_bytes) return error.FileTooLarge;
            if (input.len == 0) return 0;
            const start: usize = @intCast(offset);
            const limit: usize = @intCast(until);
            if (start > node.length) @memset(node.data[node.length..start], 0);
            move(node.data[start..limit], input);
            node.length = @max(node.length, limit);
            return input.len;
        }

        /// Extension and released tails are zeroed, including later reuse.
        pub fn truncate(self: *Self, id: NodeId, new_size: u64) Error!void {
            const node = &self.nodes[try self.slot(id)];
            switch (node.kind) {
                .directory => return error.IsDirectory,
                .borrowed_file => return error.ReadOnly,
                .mutable_file => {},
            }
            if (new_size > file_bytes) return error.FileTooLarge;
            const next: usize = @intCast(new_size);
            @memset(node.data[@min(next, node.length)..@max(next, node.length)], 0);
            node.length = next;
        }

        /// File-only clearing of this backend's full owned allocation, followed
        /// by removal. Tombstones prevent a stale slot/epoch ID from reviving.
        /// The caller authorizes ownership and invalidates borrowed views.
        pub fn nullify(self: *Self, absolute: []const u8) Error!void {
            const node = &self.nodes[try self.slot(try self.lookup(absolute))];
            if (node.kind == .directory) return error.IsDirectory;
            if (node.kind != .mutable_file or node.metadata.domain != .container or node.metadata.owner == 0)
                return error.ReadOnly;
            secure_clear.bytes(std.mem.asBytes(node));
            node.borrowed = &.{};
            node.retired = true;
        }

        /// Enumerate immediate children in stable insertion-slot order. Cursor
        /// is caller-owned; this is a live enumeration, not a snapshot.
        pub fn enumerate(self: *const Self, directory: NodeId, cursor: *usize) Error!?Stat {
            const parent = try self.slot(directory);
            if (self.nodes[parent].kind != .directory) return error.NotDirectory;
            if (cursor.* > node_capacity) return error.OutOfBounds;
            while (cursor.* < node_capacity) {
                const index = cursor.*;
                cursor.* += 1;
                if (index == 0 or !self.nodes[index].occupied or self.nodes[index].parent != parent) continue;
                return try self.stat(self.identity(index));
            }
            return null;
        }

        fn insert(self: *Self, absolute: []const u8, metadata: Metadata, kind: Kind, bytes: []const u8) Error!NodeId {
            if (self.generation == 0) return error.NotInitialized;
            try validatePath(absolute);
            if (metadata.executable and kind != .borrowed_file) return error.InvalidMetadata;
            if (self.find(absolute) != null) return error.AlreadyExists;
            const separator = std.mem.lastIndexOfScalar(u8, absolute, '/').?;
            const parent_path = if (separator == 0) "/" else absolute[0..separator];
            const parent = self.find(parent_path) orelse return error.NotFound;
            if (self.nodes[parent].kind != .directory) return error.NotDirectory;
            const index = for (&self.nodes, 0..) |*node, position| {
                if (!node.occupied and !node.retired) break position;
            } else return error.NodeCapacity;
            // All possible failures precede publication or modification.
            const node = &self.nodes[index];
            @memcpy(node.path_buffer[0..absolute.len], absolute);
            node.path_length = absolute.len;
            node.parent = parent;
            node.kind = kind;
            node.metadata = metadata;
            node.borrowed = bytes;
            node.length = if (kind == .borrowed_file) bytes.len else 0;
            node.occupied = true;
            return self.identity(index);
        }

        fn find(self: *const Self, absolute: []const u8) ?usize {
            for (&self.nodes, 0..) |*node, index| {
                if (node.occupied and std.mem.eql(u8, absolute, node.path_buffer[0..node.path_length])) return index;
            }
            return null;
        }

        fn slot(self: *const Self, id: NodeId) Error!usize {
            if (self.generation == 0) return error.NotInitialized;
            const bits = @backingInt(id);
            const number: u32 = @truncate(bits);
            const epoch: u32 = @intCast(bits >> 32);
            if (number == 0 or number > node_capacity or epoch == 0) return error.InvalidNode;
            if (epoch != self.generation) return error.StaleNode;
            const index: usize = number - 1;
            if (!self.nodes[index].occupied) return error.InvalidNode;
            return index;
        }

        fn identity(self: *const Self, index: usize) NodeId {
            return @fromBackingInt((@as(u64, self.generation) << 32) | @as(u64, @intCast(index + 1)));
        }

        fn validatePath(absolute: []const u8) Error!void {
            if (absolute.len == 0 or absolute[0] != '/' or std.mem.indexOfScalar(u8, absolute, 0) != null)
                return error.InvalidPath;
            if (absolute.len > path_bytes) return error.PathTooLong;
            if (absolute.len == 1) return;
            var start: usize = 1;
            for (absolute[1..], 1..) |byte, index| {
                if (byte != '/') continue;
                try component(absolute[start..index]);
                start = index + 1;
            }
            try component(absolute[start..]);
        }

        fn component(name: []const u8) Error!void {
            if (name.len == 0 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return error.InvalidPath;
        }
    };
}

test "nullify volatile clears the complete mutable allocation and retires its slot" {
    const t = std.testing;
    var fs: RamFs(4, 64, 48) = .{};
    try fs.reset();
    _ = try fs.mkdir("/private", .{ .domain = .container, .owner = 7 });
    const file = try fs.create("/private/secret", .{ .domain = .container, .owner = 7 });
    _ = try fs.write(file, 0, "private-full-allocation-secret");
    const old_slot = @as(u32, @truncate(@backingInt(file))) - 1;
    @memset(fs.nodes[old_slot].data[40..], 0x5a);
    try fs.nullify("/private/secret");
    for (fs.nodes[old_slot].data) |byte| try t.expectEqual(@as(u8, 0), byte);
    for (fs.nodes[old_slot].path_buffer) |byte| try t.expectEqual(@as(u8, 0), byte);
    try t.expect(fs.nodes[old_slot].retired and !fs.nodes[old_slot].occupied);
    try t.expectError(error.NotFound, fs.lookup("/private/secret"));
    try t.expectError(error.InvalidNode, fs.contents(file));
    const replacement = try fs.create("/private/new", .{ .domain = .container, .owner = 7 });
    try t.expect(replacement != file);
    try t.expectError(error.NodeCapacity, fs.create("/private/full", .{ .domain = .container, .owner = 7 }));
    try fs.reset();
    try t.expectError(error.StaleNode, fs.contents(file));
}

test "RAM nullify rejects directories system files borrowed content and missing paths without mutation" {
    const t = std.testing;
    var fs: RamFs(5, 64, 48) = .{};
    try t.expectError(error.NotInitialized, fs.nullify("/secret"));
    try fs.reset();
    _ = try fs.mkdir("/private", .{ .domain = .container, .owner = 7 });
    const system_file = try fs.create("/system", .{});
    _ = try fs.write(system_file, 0, "system-data");
    const borrowed = try fs.addBorrowed("/bundle", .{ .domain = .bundle, .owner = 7 }, "immutable-bundle-secret");
    const before = @import("durable.zig").crc32(std.mem.asBytes(&fs.nodes));
    try t.expectError(error.IsDirectory, fs.nullify("/private"));
    try t.expectError(error.ReadOnly, fs.nullify("/system"));
    try t.expectError(error.ReadOnly, fs.nullify("/bundle"));
    try t.expectError(error.NotFound, fs.nullify("/private/missing"));
    try t.expectEqual(before, @import("durable.zig").crc32(std.mem.asBytes(&fs.nodes)));
    try t.expectEqualStrings("immutable-bundle-secret", try fs.contents(borrowed));
}

fn rangeEnd(offset: u64, length: usize) Error!u64 {
    const count = std.math.cast(u64, length) orelse return error.ArithmeticOverflow;
    return std.math.add(u64, offset, count) catch error.ArithmeticOverflow;
}

/// memmove semantics, including reads/writes that overlap live file data.
fn move(output: []u8, input: []const u8) void {
    if (@intFromPtr(output.ptr) > @intFromPtr(input.ptr) and
        @intFromPtr(output.ptr) - @intFromPtr(input.ptr) < input.len)
        std.mem.copyBackwards(u8, output, input)
    else
        std.mem.copyForwards(u8, output, input);
}

test "canonical paths require existing directory parents and copied names" {
    const t = std.testing;
    var fs: RamFs(5, 8, 16) = .{};
    try t.expectError(error.NotInitialized, fs.lookup("/"));
    try fs.reset();
    try t.expectEqual(try fs.root(), try fs.lookup("/"));
    for ([_][]const u8{ "", "a", "//", "/a/", "/./a", "/a/..", "/a//b", "/a\x00b" }) |path_value|
        try t.expectError(error.InvalidPath, fs.create(path_value, .{}));
    try t.expectError(error.PathTooLong, fs.create("/abcdefghijklmnop", .{}));
    try t.expectError(error.NotFound, fs.create("/missing/a", .{}));
    var name = [_]u8{ '/', 'd' };
    const directory = try fs.mkdir(&name, .{ .domain = .container, .owner = 17 });
    name[1] = 'x';
    try t.expectEqualStrings("/d", try fs.path(directory));
    const file = try fs.create("/d/f", .{ .domain = .container, .owner = 17 });
    try t.expectEqual(file, try fs.lookup("/d/f"));
    try t.expectEqual(@as(u64, 17), (try fs.stat(file)).metadata.owner);
    try t.expectError(error.NotDirectory, fs.create("/d/f/child", .{}));
    try t.expectError(error.AlreadyExists, fs.mkdir("/d", .{}));
}

test "root directories and files share a bounded atomic node capacity" {
    const t = std.testing;
    var fs: RamFs(3, 4, 8) = .{};
    try fs.reset();
    _ = try fs.mkdir("/d", .{});
    const file = try fs.create("/d/file", .{});
    _ = try fs.write(file, 0, "keep");
    const before = fs;
    try t.expectError(error.NodeCapacity, fs.create("/new", .{}));
    try t.expectError(error.AlreadyExists, fs.create("/d/file", .{}));
    try t.expectError(error.InvalidMetadata, fs.create("/new", .{ .executable = true }));
    try t.expectEqualDeep(before, fs);
    var root_only: RamFs(1, 0, 1) = .{};
    try root_only.reset();
    try t.expectEqual(Kind.directory, (try root_only.stat(try root_only.root())).kind);
    try t.expectError(error.AlreadyExists, root_only.mkdir("/", .{}));
}

test "immutable borrowed files retain arbitrary bytes metadata and executable intent" {
    const t = std.testing;
    var fs: RamFs(2, 4, 16) = .{};
    try fs.reset();
    const image: [1024]u8 = @splat(0xa5);
    const file = try fs.addBorrowed("/image", .{ .domain = .bundle, .owner = 29, .executable = true }, &image);
    const info = try fs.stat(file);
    try t.expectEqual(Kind.borrowed_file, info.kind);
    try t.expect(info.metadata.executable);
    try t.expectEqual(@as(u64, image.len), info.size);
    try t.expectEqual(@intFromPtr(&image), @intFromPtr((try fs.contents(file)).ptr));
    try t.expectError(error.ReadOnly, fs.write(file, 0, "mutate"));
    try t.expectError(error.ReadOnly, fs.truncate(file, 0));
    var output: [8]u8 = @splat(0x77);
    try t.expectEqual(@as(usize, 2), try fs.read(file, image.len - 2, &output));
    try t.expectEqualSlices(u8, &[_]u8{ 0xa5, 0xa5, 0x77, 0x77, 0x77, 0x77, 0x77, 0x77 }, &output);
}

test "writes zero holes and enforce whole-operation bounds without changing data" {
    const t = std.testing;
    var fs: RamFs(2, 8, 8) = .{};
    try fs.reset();
    const file = try fs.create("/f", .{});
    try t.expectEqual(@as(usize, 2), try fs.write(file, 3, "ab"));
    try t.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 'a', 'b' }, try fs.contents(file));
    try t.expectEqual(@as(usize, 3), try fs.write(file, 5, "cde"));
    const before = fs;
    try t.expectError(error.FileTooLarge, fs.write(file, 7, "xx"));
    try t.expectError(error.ArithmeticOverflow, fs.write(file, std.math.maxInt(u64), "x"));
    try t.expectError(error.FileTooLarge, fs.write(file, 9, ""));
    try t.expectEqual(@as(usize, 0), try fs.write(file, 8, ""));
    try t.expectEqualDeep(before, fs);
}

test "EOF partial reads and overflow leave unfilled output bytes unchanged" {
    const t = std.testing;
    var fs: RamFs(2, 8, 8) = .{};
    try fs.reset();
    const file = try fs.create("/f", .{});
    _ = try fs.write(file, 0, "abcd");
    var output: [6]u8 = @splat(0x77);
    try t.expectEqual(@as(usize, 2), try fs.read(file, 2, &output));
    try t.expectEqualSlices(u8, &[_]u8{ 'c', 'd', 0x77, 0x77, 0x77, 0x77 }, &output);
    const before = output;
    try t.expectEqual(@as(usize, 0), try fs.read(file, 4, &output));
    try t.expectEqual(@as(usize, 0), try fs.read(file, 500, &output));
    try t.expectError(error.ArithmeticOverflow, fs.read(file, std.math.maxInt(u64), &output));
    try t.expectEqualSlices(u8, &before, &output);
    try t.expectEqual(@as(usize, 0), try fs.read(file, std.math.maxInt(u64), output[0..0]));
}

test "truncation clears released bytes and extension cannot reveal old contents" {
    const t = std.testing;
    var fs: RamFs(2, 8, 8) = .{};
    try fs.reset();
    const file = try fs.create("/f", .{});
    _ = try fs.write(file, 0, "abcdefgh");
    const before = fs;
    try t.expectError(error.FileTooLarge, fs.truncate(file, 9));
    try t.expectEqualDeep(before, fs);
    try fs.truncate(file, 2);
    for (fs.nodes[1].data[2..]) |byte| try t.expectEqual(@as(u8, 0), byte);
    try fs.truncate(file, 8);
    try t.expectEqualSlices(u8, &[_]u8{ 'a', 'b', 0, 0, 0, 0, 0, 0 }, try fs.contents(file));
    try fs.truncate(file, 0);
    _ = try fs.write(file, 7, "z");
    try t.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 0, 0, 0, 0, 'z' }, try fs.contents(file));
}

test "overlapping live file reads and writes use memmove semantics" {
    const t = std.testing;
    var fs: RamFs(2, 8, 8) = .{};
    try fs.reset();
    const file = try fs.create("/f", .{});
    _ = try fs.write(file, 0, "abcd");
    _ = try fs.write(file, 2, try fs.contents(file));
    try t.expectEqualStrings("ababcd", try fs.contents(file));
    _ = try fs.read(file, 2, fs.nodes[1].data[0..4]);
    try t.expectEqualStrings("abcdcd", try fs.contents(file));
}

test "directory enumeration returns only immediate children and preserves rejected cursor" {
    const t = std.testing;
    var fs: RamFs(6, 8, 16) = .{};
    try fs.reset();
    const directory = try fs.mkdir("/d", .{});
    const first = try fs.create("/d/a", .{});
    const subdirectory = try fs.mkdir("/d/sub", .{});
    _ = try fs.create("/d/sub/b", .{});
    _ = try fs.create("/other", .{});
    var cursor: usize = 0;
    try t.expectEqual(first, (try fs.enumerate(directory, &cursor)).?.id);
    try t.expectEqual(subdirectory, (try fs.enumerate(directory, &cursor)).?.id);
    try t.expectEqual(@as(?Stat, null), try fs.enumerate(directory, &cursor));
    try t.expectEqual(@as(?Stat, null), try fs.enumerate(directory, &cursor));
    cursor = 0;
    try t.expectError(error.NotDirectory, fs.enumerate(first, &cursor));
    try t.expectEqual(@as(usize, 0), cursor);
    cursor = 7;
    try t.expectError(error.OutOfBounds, fs.enumerate(directory, &cursor));
    try t.expectEqual(@as(usize, 7), cursor);
    try t.expectError(error.IsDirectory, fs.contents(directory));
    try t.expectError(error.IsDirectory, fs.read(directory, 0, &.{}));
    try t.expectError(error.IsDirectory, fs.write(directory, 0, ""));
    try t.expectError(error.IsDirectory, fs.truncate(directory, 0));
}

test "reset clears storage and invalidates all previous node identities" {
    const t = std.testing;
    var fs: RamFs(3, 8, 8) = .{};
    try fs.reset();
    const old_root = try fs.root();
    const old = try fs.create("/old", .{});
    _ = try fs.write(old, 0, "secret");
    try fs.reset();
    try t.expectError(error.StaleNode, fs.stat(old));
    try t.expectError(error.StaleNode, fs.stat(old_root));
    try t.expectError(error.NotFound, fs.lookup("/old"));
    for (&fs.nodes) |*node| for (node.data) |byte| try t.expectEqual(@as(u8, 0), byte);
    const replacement = try fs.create("/new", .{});
    try t.expect(replacement != old);
    try t.expectError(error.InvalidNode, fs.stat(@fromBackingInt(0)));
    try t.expectError(error.InvalidNode, fs.stat(@fromBackingInt((@as(u64, fs.generation) << 32) | 3)));
}

test "generation exhaustion is atomic and cannot revive an earlier session" {
    const t = std.testing;
    var fs: RamFs(2, 8, 8) = .{};
    try fs.reset();
    const file = try fs.create("/f", .{});
    _ = try fs.write(file, 0, "live");
    fs.generation = std.math.maxInt(u32);
    const before = fs;
    try t.expectError(error.GenerationExhausted, fs.reset());
    try t.expectEqualDeep(before, fs);
}
