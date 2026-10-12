//! Bedrock data format v1: two CRC-protected copy-on-write snapshot banks.
//! The supplied dedicated block device owns durability. No allocation or host I/O.
const std = @import("std");
const storage = @import("root.zig");
const ramfs = @import("ramfs.zig");
const secure_clear = @import("secure_clear.zig");
pub const sector_size = 512;
pub const bank_blocks = 4096;
pub const disk_bytes = 2 * bank_blocks * sector_size;
pub const magic = "BEDFS001";
pub const version: u32 = 1;
pub const record_header_bytes = 64;
const Header = struct { generation: u64, payload_crc: u32, next_serial: u32 };
pub const Error = error{ NotInitialized, AlreadyMounted, NoValidSnapshot, IncompatibleFormat, UnsupportedFormat, CorruptSnapshot, AmbiguousGeneration, RemountRequired, NullifyVerificationFailed, GenerationExhausted, InvalidMetadata, DirectoryNotEmpty, ReadOnly, NodeCapacity, FileTooLarge, InvalidPath, PathTooLong, NotFound, AlreadyExists, NotDirectory, IsDirectory, InvalidNode, StaleNode, OutOfBounds, ArithmeticOverflow };

pub fn DurableFs(comptime capacity: usize, comptime file_bytes: usize, comptime path_bytes: usize) type {
    if (capacity == 0 or capacity > 65535 or path_bytes < 1 or path_bytes > 65535)
        @compileError("Invalid durable filesystem capacity");
    const record_bytes = record_header_bytes + path_bytes + file_bytes;
    const payload_bytes = capacity * record_bytes;
    if (payload_bytes > (bank_blocks - 1) * sector_size) @compileError("Snapshot exceeds one disk bank");
    return struct {
        const Self = @This();
        const Node = struct {
            occupied: bool = false,
            kind: ramfs.Kind = .directory,
            metadata: ramfs.Metadata = .{},
            serial: u32 = 0,
            parent: usize = 0,
            path_length: usize = 0,
            path_buffer: [path_bytes]u8 = @splat(0),
            length: usize = 0,
            borrowed: []const u8 = &.{},
            data: [file_bytes]u8 = @splat(0),
        };
        pub const max_nodes = capacity;
        pub const max_path_bytes = path_bytes;
        pub const max_file_bytes = file_bytes;
        nodes: [2][capacity]Node = @splat(@splat(.{})),
        live: usize = 0,
        active_disk: usize = 0,
        generation: u64 = 0,
        next_serial: u32 = 1,
        device: storage.BlockDevice = undefined,
        mounted: bool = false,
        poisoned: bool = false,

        /// Destructive, explicit formatting for trusted setup/tests. Production
        /// media is created by make-data-image.py; mount never formats a disk.
        pub fn format(self: *Self, device: storage.BlockDevice) !void {
            if (self.mounted) return error.AlreadyMounted;
            try checkDevice(device);
            self.device = device;
            self.clearBank(0);
            self.clearBank(1);
            const root_node = &self.nodes[0][0];
            root_node.occupied = true;
            root_node.serial = 1;
            root_node.path_length = 1;
            root_node.path_buffer[0] = '/';
            var zeros: [sector_size]u8 = @splat(0);
            try device.write(0, &zeros);
            try device.write(bank_blocks, &zeros);
            try device.flush();
            const payload_crc = try self.writePayload(0, 0);
            try device.flush();
            var header: [sector_size]u8 = undefined;
            self.makeHeader(&header, .{ .generation = 1, .payload_crc = payload_crc, .next_serial = 2 }, 0);
            try device.write(0, &header);
            try device.flush();
            self.live = 0;
            self.active_disk = 0;
            self.generation = 1;
            self.next_serial = 2;
            self.mounted = true;
        }

        /// Keep this instance in kernel-owned storage. A new mount selects the
        /// highest fully valid bank. Node handles never migrate to another fs.
        pub fn mount(self: *Self, device: storage.BlockDevice) !void {
            if (self.mounted) return error.AlreadyMounted;
            try checkDevice(device);
            self.device = device;
            var headers: [2]?Header = @splat(null);
            for (0..2) |bank| {
                var bytes: [sector_size]u8 = undefined;
                try device.read(bank * bank_blocks, &bytes);
                headers[bank] = try self.parseHeader(&bytes, bank);
                if (headers[bank]) |header| {
                    if (!try self.readPayload(bank, header)) headers[bank] = null;
                }
            }
            const chosen: usize = if (headers[0]) |first| blk: {
                if (headers[1]) |second| {
                    if (first.generation == second.generation and
                        (first.payload_crc != second.payload_crc or first.next_serial != second.next_serial))
                        return error.AmbiguousGeneration;
                    if (second.generation > first.generation) break :blk 1;
                }
                break :blk 0;
            } else if (headers[1] != null) 1 else return error.NoValidSnapshot;
            const header = headers[chosen].?;
            self.live = chosen;
            self.active_disk = chosen;
            self.generation = header.generation;
            self.next_serial = header.next_serial;
            self.mounted = true;
            self.poisoned = false;
        }

        pub fn root(self: *const Self) !ramfs.NodeId {
            try self.readable();
            return self.identity(0);
        }
        pub fn lookup(self: *const Self, path_bytes_: []const u8) !ramfs.NodeId {
            try self.readable();
            try validatePath(path_bytes_);
            return self.identity(self.find(self.live, path_bytes_) orelse return error.NotFound);
        }
        pub fn mkdir(self: *Self, path_bytes_: []const u8, metadata: ramfs.Metadata) !ramfs.NodeId {
            return self.insert(path_bytes_, metadata, .directory, &.{});
        }
        pub fn create(self: *Self, path_bytes_: []const u8, metadata: ramfs.Metadata) !ramfs.NodeId {
            return self.insert(path_bytes_, metadata, .mutable_file, &.{});
        }
        pub fn addBorrowed(self: *Self, path_bytes_: []const u8, metadata: ramfs.Metadata, bytes: []const u8) !ramfs.NodeId {
            return self.insert(path_bytes_, metadata, .borrowed_file, bytes);
        }
        pub fn stat(self: *const Self, id: ramfs.NodeId) !ramfs.Stat {
            const node = &self.nodes[self.live][try self.slot(id)];
            return .{ .id = id, .kind = node.kind, .metadata = node.metadata, .size = node.length };
        }
        pub fn path(self: *const Self, id: ramfs.NodeId) ![]const u8 {
            const node = &self.nodes[self.live][try self.slot(id)];
            return node.path_buffer[0..node.path_length];
        }
        pub fn size(self: *const Self, id: ramfs.NodeId) !u64 {
            const node = &self.nodes[self.live][try self.slot(id)];
            if (node.kind == .directory) return error.IsDirectory;
            return node.length;
        }
        /// Mutable views last only until the next successful transaction.
        /// Immutable bundle borrows remain owned by the trusted ROM catalog.
        pub fn contents(self: *const Self, id: ramfs.NodeId) ![]const u8 {
            const node = &self.nodes[self.live][try self.slot(id)];
            return switch (node.kind) {
                .directory => error.IsDirectory,
                .mutable_file => node.data[0..node.length],
                .borrowed_file => node.borrowed,
            };
        }
        pub fn read(self: *const Self, id: ramfs.NodeId, offset: u64, output: []u8) !usize {
            const bytes = try self.contents(id);
            _ = try rangeEnd(offset, output.len);
            if (offset >= bytes.len or output.len == 0) return 0;
            const start: usize = @intCast(offset);
            const count = @min(output.len, bytes.len - start);
            move(output[0..count], bytes[start..][0..count]);
            return count;
        }
        pub fn write(self: *Self, id: ramfs.NodeId, offset: u64, input: []const u8) !usize {
            const index = try self.slot(id);
            const old = &self.nodes[self.live][index];
            if (old.kind == .directory) return error.IsDirectory;
            if (old.kind != .mutable_file) return error.ReadOnly;
            const end = try rangeEnd(offset, input.len);
            if (end > file_bytes) return error.FileTooLarge;
            if (input.len == 0) return 0;
            const stage = try self.beginTransaction();
            const node = &self.nodes[stage][index];
            const start: usize = @intCast(offset);
            if (start > node.length) @memset(node.data[node.length..start], 0);
            move(node.data[start..@intCast(end)], input);
            node.length = @max(node.length, @as(usize, @intCast(end)));
            try self.commit(stage, self.next_serial);
            return input.len;
        }
        pub fn truncate(self: *Self, id: ramfs.NodeId, size_bytes: u64) !void {
            const index = try self.slot(id);
            const old = &self.nodes[self.live][index];
            if (old.kind == .directory) return error.IsDirectory;
            if (old.kind != .mutable_file) return error.ReadOnly;
            if (size_bytes > file_bytes) return error.FileTooLarge;
            if (size_bytes == old.length) return;
            const stage = try self.beginTransaction();
            const node = &self.nodes[stage][index];
            const next: usize = @intCast(size_bytes);
            @memset(node.data[@min(node.length, next)..@max(node.length, next)], 0);
            node.length = next;
            try self.commit(stage, self.next_serial);
        }
        pub fn enumerate(self: *const Self, directory: ramfs.NodeId, cursor: *usize) !?ramfs.Stat {
            const parent = try self.slot(directory);
            if (self.nodes[self.live][parent].kind != .directory) return error.NotDirectory;
            if (cursor.* > capacity) return error.OutOfBounds;
            while (cursor.* < capacity) {
                const index = cursor.*;
                cursor.* += 1;
                const node = &self.nodes[self.live][index];
                if (index == 0 or !node.occupied or node.parent != parent) continue;
                return try self.stat(self.identity(index));
            }
            return null;
        }

        pub fn unlink(self: *Self, path_bytes_: []const u8) !void {
            const index = try self.slot(try self.lookup(path_bytes_));
            const node = &self.nodes[self.live][index];
            if (index == 0 or !persistent(node) or node.metadata.domain != .container) return error.ReadOnly;
            if (node.kind == .directory) for (&self.nodes[self.live]) |*child| {
                if (child.occupied and child.parent == index) return error.DirectoryNotEmpty;
            };
            const stage = try self.beginTransaction();
            clearNode(&self.nodes[stage][index]);
            try self.commit(stage, self.next_serial);
        }

        /// Return success only after both complete logical banks are clean and
        /// verified. This removes a mutable container file, preserving current
        /// other files. Any failure after RAM sanitization requires fresh mount;
        /// the caller must not claim either rollback or completed erasure.
        pub fn nullify(self: *Self, path_bytes_: []const u8) !void {
            const index = try self.slot(try self.lookup(path_bytes_));
            const node = &self.nodes[self.live][index];
            if (node.kind == .directory) return error.IsDirectory;
            if (node.kind != .mutable_file or node.metadata.domain != .container or !persistent(node))
                return error.ReadOnly;
            if (self.generation > std.math.maxInt(u64) - 2) return error.GenerationExhausted;

            const stage = 1 - self.live;
            // Do not merely overwrite historical RAM with an optimized copy.
            // First emit volatile clearing stores, then rebuild from current
            // nodes and normalize all unused path/data tails.
            errdefer self.poisoned = true;
            self.secureClearBank(stage);
            @memcpy(self.nodes[stage][0..], self.nodes[self.live][0..]);
            secureClearNode(&self.nodes[stage][index]);
            self.sanitizeBank(stage);
            self.secureClearBank(self.live);
            @memcpy(self.nodes[self.live][0..], self.nodes[stage][0..]);

            try self.commitNullify(stage);
            // The first sanitized bank is verified before the former active
            // bank can be overwritten. Both RAM copies already contain the
            // same clean current tree, including trusted bundle overlays.
            try self.commitNullify(1 - self.live);
        }

        /// Rename preserves node identities and updates the complete subtree.
        /// Existing destinations are rejected; no implicit replacement/unlink.
        pub fn rename(self: *Self, source: []const u8, destination: []const u8) !void {
            const index = try self.slot(try self.lookup(source));
            try validatePath(destination);
            const node = &self.nodes[self.live][index];
            if (index == 0 or !persistent(node) or node.metadata.domain != .container) return error.ReadOnly;
            if (std.mem.eql(u8, source, destination)) return;
            if (self.find(self.live, destination) != null) return error.AlreadyExists;
            if (within(destination, source)) return error.InvalidPath;
            const parent = try self.parentFor(self.live, destination);
            try sameContainer(node.metadata, self.nodes[self.live][parent].metadata);
            for (&self.nodes[self.live]) |*child| {
                if (!child.occupied or !within(child.path_buffer[0..child.path_length], source)) continue;
                if (destination.len + child.path_length - source.len > path_bytes) return error.PathTooLong;
                try sameContainer(node.metadata, child.metadata);
            }
            const stage = try self.beginTransaction();
            for (&self.nodes[stage]) |*child| {
                if (!child.occupied or !within(child.path_buffer[0..child.path_length], source)) continue;
                const tail_length = child.path_length - source.len;
                move(child.path_buffer[destination.len .. destination.len + tail_length], child.path_buffer[source.len..child.path_length]);
                @memcpy(child.path_buffer[0..destination.len], destination);
                child.path_length = destination.len + tail_length;
                @memset(child.path_buffer[child.path_length..], 0);
            }
            self.nodes[stage][index].parent = parent;
            try self.commit(stage, self.next_serial);
        }

        /// Atomic recursive copy. Every copied node belongs to the destination
        /// container; immutable executable flags are never copied into it.
        pub fn copy(self: *Self, source: []const u8, destination: []const u8, metadata: ramfs.Metadata) !ramfs.NodeId {
            _ = try self.lookup(source);
            try validatePath(destination);
            if (metadata.domain != .container or metadata.owner == 0 or metadata.executable) return error.InvalidMetadata;
            if (self.find(self.live, destination) != null) return error.AlreadyExists;
            if (within(destination, source)) return error.InvalidPath;
            const parent = try self.parentFor(self.live, destination);
            try sameContainer(metadata, self.nodes[self.live][parent].metadata);
            var source_indices: [capacity]usize = undefined;
            var targets: [capacity]usize = undefined;
            var count: usize = 0;
            for (&self.nodes[self.live], 0..) |*node, index| {
                if (!node.occupied or !within(node.path_buffer[0..node.path_length], source)) continue;
                if (destination.len + node.path_length - source.len > path_bytes) return error.PathTooLong;
                if (node.kind != .directory and node.length > file_bytes) return error.FileTooLarge;
                source_indices[count] = index;
                count += 1;
            }
            var available: usize = 0;
            for (&self.nodes[self.live], 0..) |*node, index| {
                if (node.occupied) continue;
                if (available < count) targets[available] = index;
                available += 1;
            }
            if (available < count) return error.NodeCapacity;
            if (self.next_serial == 0 or @as(u64, self.next_serial) + count - 1 > std.math.maxInt(u32)) return error.GenerationExhausted;
            const stage = try self.beginTransaction();
            var serial = self.next_serial;
            var root_target: usize = undefined;
            for (source_indices[0..count], targets[0..count]) |from, to| {
                const original = &self.nodes[self.live][from];
                const target = &self.nodes[stage][to];
                clearNode(target);
                target.occupied = true;
                target.kind = if (original.kind == .directory) .directory else .mutable_file;
                target.metadata = metadata;
                target.serial = try issueSerial(&serial);
                target.length = original.length;
                target.path_length = destination.len + original.path_length - source.len;
                @memcpy(target.path_buffer[0..destination.len], destination);
                @memcpy(target.path_buffer[destination.len..target.path_length], original.path_buffer[source.len..original.path_length]);
                if (original.path_length == source.len) {
                    root_target = to;
                    target.parent = parent;
                } else {
                    target.parent = for (source_indices[0..count], targets[0..count]) |ancestor, new_parent| {
                        if (ancestor == original.parent) break new_parent;
                    } else return error.CorruptSnapshot;
                }
                if (target.kind != .directory) {
                    const bytes = if (original.kind == .borrowed_file) original.borrowed else original.data[0..original.length];
                    @memcpy(target.data[0..bytes.len], bytes);
                }
            }
            try self.commit(stage, serial);
            return self.identity(root_target);
        }

        fn insert(self: *Self, path_bytes_: []const u8, metadata: ramfs.Metadata, kind: ramfs.Kind, bytes: []const u8) !ramfs.NodeId {
            try self.readable();
            try validatePath(path_bytes_);
            const overlay = bundlePath(path_bytes_);
            if (metadata.executable and kind != .borrowed_file or
                kind == .borrowed_file and (!overlay or metadata.domain != .bundle or metadata.owner == 0) or
                kind == .mutable_file and (overlay or metadata.domain != .container or metadata.owner == 0) or
                metadata.domain == .bundle and !overlay or metadata.domain == .container and metadata.owner == 0 or
                metadata.domain == .system and metadata.owner != 0)
                return error.InvalidMetadata;
            if (self.find(self.live, path_bytes_) != null) return error.AlreadyExists;
            const parent = try self.parentFor(self.live, path_bytes_);
            if (!overlay and !persistent(&self.nodes[self.live][parent])) return error.InvalidMetadata;
            const index = for (&self.nodes[self.live], 0..) |*node, slot_index| {
                if (!node.occupied) break slot_index;
            } else return error.NodeCapacity;
            var serial = self.next_serial;
            const issued = try issueSerial(&serial);
            const stage = if (overlay) self.live else try self.beginTransaction();
            const node = &self.nodes[stage][index];
            clearNode(node);
            node.occupied = true;
            node.kind = kind;
            node.metadata = metadata;
            node.serial = issued;
            node.parent = parent;
            node.path_length = path_bytes_.len;
            @memcpy(node.path_buffer[0..path_bytes_.len], path_bytes_);
            node.borrowed = bytes;
            node.length = if (kind == .borrowed_file) bytes.len else 0;
            if (overlay) self.next_serial = serial else try self.commit(stage, serial);
            return self.identity(index);
        }
        fn readable(self: *const Self) !void {
            if (!self.mounted) return error.NotInitialized;
            if (self.poisoned) return error.RemountRequired;
        }
        fn slot(self: *const Self, id: ramfs.NodeId) !usize {
            try self.readable();
            const raw = @backingInt(id);
            const position: u32 = @truncate(raw);
            const serial: u32 = @truncate(raw >> 32);
            if (position == 0 or position > capacity or serial == 0) return error.InvalidNode;
            const node = &self.nodes[self.live][position - 1];
            if (!node.occupied or node.serial != serial) return error.StaleNode;
            return position - 1;
        }
        fn identity(self: *const Self, index: usize) ramfs.NodeId {
            return @fromBackingInt((@as(u64, self.nodes[self.live][index].serial) << 32) | (index + 1));
        }
        fn find(self: *const Self, bank: usize, bytes: []const u8) ?usize {
            for (&self.nodes[bank], 0..) |*node, index|
                if (node.occupied and std.mem.eql(u8, bytes, node.path_buffer[0..node.path_length])) return index;
            return null;
        }
        fn parentFor(self: *const Self, bank: usize, path_bytes_: []const u8) !usize {
            const separator = std.mem.lastIndexOfScalar(u8, path_bytes_, '/').?;
            const parent_path = if (separator == 0) "/" else path_bytes_[0..separator];
            const parent = self.find(bank, parent_path) orelse return error.NotFound;
            if (self.nodes[bank][parent].kind != .directory) return error.NotDirectory;
            return parent;
        }
        fn beginTransaction(self: *Self) !usize {
            try self.readable();
            if (self.generation == std.math.maxInt(u64)) return error.GenerationExhausted;
            const stage = 1 - self.live;
            @memcpy(self.nodes[stage][0..], self.nodes[self.live][0..]);
            return stage;
        }
        fn commit(self: *Self, stage: usize, serial: u32) !void {
            const target = 1 - self.active_disk;
            // Any I/O failure after writes begin requires recovery. Header/final
            // flush failure may mean a complete new snapshot already committed.
            errdefer self.poisoned = true;
            const payload_crc = try self.writePayload(stage, target);
            try self.device.flush();
            var header: [sector_size]u8 = undefined;
            const next: Header = .{ .generation = self.generation + 1, .payload_crc = payload_crc, .next_serial = serial };
            self.makeHeader(&header, next, target);
            try self.device.write(target * bank_blocks, &header);
            try self.device.flush();
            self.active_disk = target;
            self.live = stage;
            self.generation = next.generation;
            self.next_serial = serial;
        }
        fn clearBank(self: *Self, bank: usize) void {
            for (&self.nodes[bank]) |*node| clearNode(node);
        }
        fn secureClearBank(self: *Self, bank: usize) void {
            secure_clear.bytes(std.mem.asBytes(&self.nodes[bank]));
            for (&self.nodes[bank]) |*node| node.borrowed = &.{};
        }
        fn secureClearNode(node: *Node) void {
            secure_clear.bytes(std.mem.asBytes(node));
            node.borrowed = &.{};
        }
        fn sanitizeBank(self: *Self, bank: usize) void {
            for (&self.nodes[bank]) |*node| {
                if (!node.occupied) {
                    secureClearNode(node);
                    continue;
                }
                secure_clear.bytes(node.path_buffer[node.path_length..]);
                const kept = if (node.kind == .mutable_file) node.length else 0;
                secure_clear.bytes(node.data[kept..]);
            }
        }
        fn commitNullify(self: *Self, stage: usize) !void {
            const target = 1 - self.active_disk;
            const payload_crc = try self.transferPayload(stage, target, false);
            try self.transferTail(target, false);
            try self.device.flush();
            var expected: [sector_size]u8 = undefined;
            const next: Header = .{ .generation = self.generation + 1, .payload_crc = payload_crc, .next_serial = self.next_serial };
            self.makeHeader(&expected, next, target);
            try self.device.write(target * bank_blocks, &expected);
            try self.device.flush();
            var actual: [sector_size]u8 = undefined;
            defer secure_clear.bytes(&actual);
            try self.device.read(target * bank_blocks, &actual);
            if (!std.mem.eql(u8, &expected, &actual)) return error.NullifyVerificationFailed;
            _ = try self.transferPayload(stage, target, true);
            try self.transferTail(target, true);
            self.active_disk = target;
            self.live = stage;
            self.generation = next.generation;
        }
        fn transferTail(self: *Self, bank: usize, comptime verify: bool) !void {
            const first = 1 + (payload_bytes + sector_size - 1) / sector_size;
            var block: usize = first;
            var actual: [8 * sector_size]u8 = undefined;
            defer if (verify) secure_clear.bytes(&actual);
            while (block < bank_blocks) {
                const count: usize = @min(@as(usize, 8), bank_blocks - block);
                const bytes = count * sector_size;
                if (verify) {
                    try self.device.read(bank * bank_blocks + block, actual[0..bytes]);
                    for (actual[0..bytes]) |byte| if (byte != 0) return error.NullifyVerificationFailed;
                } else try self.device.write(bank * bank_blocks + block, zero_chunk[0..bytes]);
                block += count;
            }
        }
        fn clearNode(node: *Node) void {
            @memset(std.mem.asBytes(node), 0);
            node.borrowed = &.{};
        }
        fn persistent(node: *const Node) bool {
            return node.occupied and node.kind != .borrowed_file and !bundlePath(node.path_buffer[0..node.path_length]);
        }
        fn makeHeader(_: *const Self, bytes: *[sector_size]u8, header: Header, bank: usize) void {
            @memset(bytes, 0);
            @memcpy(bytes[0..8], magic);
            put(bytes[8..12], version);
            put(bytes[12..16], sector_size);
            put(bytes[16..24], header.generation);
            put(bytes[24..32], 2 * bank_blocks);
            put(bytes[32..36], bank_blocks);
            put(bytes[36..40], capacity);
            put(bytes[40..44], file_bytes);
            put(bytes[44..48], path_bytes);
            put(bytes[48..56], payload_bytes);
            put(bytes[56..60], header.payload_crc);
            put(bytes[64..68], header.next_serial);
            put(bytes[68..72], bank);
            put(bytes[60..64], crc32(bytes));
        }
        fn parseHeader(_: *const Self, bytes: *[sector_size]u8, bank: usize) !?Header {
            if (!std.mem.eql(u8, bytes[0..8], magic)) return null;
            const expected = get(bytes[60..64]);
            @memset(bytes[60..64], 0);
            if (crc32(bytes) != expected) return null;
            if (get(bytes[8..12]) != version) return error.UnsupportedFormat;
            if (get(bytes[12..16]) != sector_size or get(bytes[24..32]) != 2 * bank_blocks or
                get(bytes[32..36]) != bank_blocks or get(bytes[36..40]) != capacity or
                get(bytes[40..44]) != file_bytes or get(bytes[44..48]) != path_bytes or
                get(bytes[48..56]) != payload_bytes) return error.IncompatibleFormat;
            if (get(bytes[68..72]) != bank or get(bytes[16..24]) == 0) return null;
            for (bytes[72..]) |byte| if (byte != 0) return null;
            return .{ .generation = get(bytes[16..24]), .payload_crc = @intCast(get(bytes[56..60])), .next_serial = @intCast(get(bytes[64..68])) };
        }
        fn writePayload(self: *Self, memory_bank: usize, disk_bank: usize) !u32 {
            return self.transferPayload(memory_bank, disk_bank, false);
        }
        fn transferPayload(self: *Self, memory_bank: usize, disk_bank: usize, verify: bool) !u32 {
            var writer: Writer = .{ .device = self.device, .block = disk_bank * bank_blocks + 1, .verify = verify };
            for (&self.nodes[memory_bank]) |*node| {
                var header: [record_header_bytes]u8 = @splat(0);
                const keep = persistent(node);
                if (keep) {
                    header[0] = 1;
                    header[1] = if (node.kind == .directory) 1 else 2;
                    header[2] = @intCast(@backingInt(node.metadata.domain));
                    put(header[4..8], node.serial);
                    put(header[8..16], node.metadata.owner);
                    put(header[16..20], node.parent);
                    put(header[20..24], node.path_length);
                    put(header[24..32], node.length);
                }
                try writer.bytes(&header);
                for (0..path_bytes) |index| try writer.byte(if (keep and index < node.path_length) node.path_buffer[index] else 0);
                for (0..file_bytes) |index| try writer.byte(if (keep and node.kind == .mutable_file and index < node.length) node.data[index] else 0);
            }
            return writer.finish();
        }
        fn readPayload(self: *Self, bank: usize, header: Header) !bool {
            self.clearBank(bank);
            var reader: Reader = .{ .device = self.device, .block = bank * bank_blocks + 1 };
            for (&self.nodes[bank]) |*node| {
                var record: [record_header_bytes]u8 = undefined;
                for (&record) |*byte| byte.* = try reader.byte();
                if (!decodeRecord(node, &record, header.next_serial)) return false;
                for (0..path_bytes) |index| {
                    const byte = try reader.byte();
                    if (node.occupied and index < node.path_length) node.path_buffer[index] = byte else if (byte != 0) return false;
                }
                for (0..file_bytes) |index| {
                    const byte = try reader.byte();
                    if (node.occupied and node.kind == .mutable_file and index < node.length) node.data[index] = byte else if (byte != 0) return false;
                }
            }
            if (~reader.crc != header.payload_crc) return false;
            return self.validSnapshot(bank);
        }
        fn decodeRecord(node: *Node, record: *const [record_header_bytes]u8, serial_limit: u32) bool {
            if (record[0] == 0) {
                for (record) |byte| if (byte != 0) return false;
                return true;
            }
            if (record[0] != 1 or record[3] != 0) return false;
            for (record[32..]) |byte| if (byte != 0) return false;
            node.kind = switch (record[1]) {
                1 => .directory,
                2 => .mutable_file,
                else => return false,
            };
            node.metadata.domain = switch (record[2]) {
                0 => .system,
                2 => .container,
                else => return false,
            };
            node.serial = @intCast(get(record[4..8]));
            node.metadata.owner = get(record[8..16]);
            const parent = get(record[16..20]);
            const path_length = get(record[20..24]);
            const length = get(record[24..32]);
            if (node.serial == 0 or serial_limit != 0 and node.serial >= serial_limit or parent >= capacity or
                path_length == 0 or path_length > path_bytes or length > file_bytes or
                node.kind == .directory and length != 0 or node.kind == .mutable_file and node.metadata.domain != .container or
                node.metadata.domain == .container and node.metadata.owner == 0 or node.metadata.domain == .system and node.metadata.owner != 0)
                return false;
            node.parent = @intCast(parent);
            node.path_length = @intCast(path_length);
            node.length = @intCast(length);
            node.occupied = true;
            return true;
        }
        fn validSnapshot(self: *const Self, bank: usize) bool {
            const root_node = &self.nodes[bank][0];
            if (!root_node.occupied or root_node.kind != .directory or root_node.metadata.domain != .system or
                root_node.metadata.owner != 0 or root_node.serial != 1 or root_node.parent != 0 or !std.mem.eql(u8, root_node.path_buffer[0..root_node.path_length], "/")) return false;
            for (&self.nodes[bank], 0..) |*node, index| {
                if (!node.occupied) continue;
                const path_bytes_ = node.path_buffer[0..node.path_length];
                validatePath(path_bytes_) catch return false;
                if (bundlePath(path_bytes_)) return false;
                for (self.nodes[bank][0..index]) |*other| if (other.occupied and
                    (node.serial == other.serial or std.mem.eql(u8, path_bytes_, other.path_buffer[0..other.path_length]))) return false;
                if (index == 0) continue;
                const parent = &self.nodes[bank][node.parent];
                if (!parent.occupied or parent.kind != .directory or node.parent == index) return false;
                const separator = std.mem.lastIndexOfScalar(u8, path_bytes_, '/').?;
                const expected_parent = if (separator == 0) "/" else path_bytes_[0..separator];
                if (!std.mem.eql(u8, expected_parent, parent.path_buffer[0..parent.path_length])) return false;
            }
            return true;
        }
        fn validatePath(bytes: []const u8) !void {
            if (bytes.len == 0 or bytes[0] != '/' or std.mem.indexOfScalar(u8, bytes, 0) != null) return error.InvalidPath;
            if (bytes.len > path_bytes) return error.PathTooLong;
            if (bytes.len == 1) return;
            var start: usize = 1;
            for (bytes[1..], 1..) |byte, index| {
                if (byte != '/') continue;
                try component(bytes[start..index]);
                start = index + 1;
            }
            try component(bytes[start..]);
        }
    };
}

fn checkDevice(device: storage.BlockDevice) !void {
    if (device.block_size != sector_size or device.block_count < 2 * bank_blocks) return error.InvalidGeometry;
    if (device.write_fn == null) return error.ReadOnly;
    if (device.flush_fn == null) return error.FlushUnavailable;
    // Exercise the shared geometry/overflow validator without any backend I/O.
    var empty: [0]u8 = .{};
    try device.read(0, &empty);
}
fn bundlePath(path: []const u8) bool {
    return std.mem.eql(u8, path, "/bundle") or std.mem.startsWith(u8, path, "/bundle/");
}
fn within(path: []const u8, parent: []const u8) bool {
    if (std.mem.eql(u8, parent, "/")) return path.len != 0 and path[0] == '/';
    return std.mem.eql(u8, path, parent) or path.len > parent.len and std.mem.startsWith(u8, path, parent) and path[parent.len] == '/';
}
fn sameContainer(a: ramfs.Metadata, b: ramfs.Metadata) !void {
    if (a.domain != .container or b.domain != .container or a.owner == 0 or a.owner != b.owner or a.executable or b.executable)
        return error.InvalidMetadata;
}
fn component(bytes: []const u8) !void {
    if (bytes.len == 0 or std.mem.eql(u8, bytes, ".") or std.mem.eql(u8, bytes, "..")) return error.InvalidPath;
}
fn issueSerial(next: *u32) !u32 {
    if (next.* == 0) return error.GenerationExhausted;
    const issued = next.*;
    next.* = if (issued == std.math.maxInt(u32)) 0 else issued + 1;
    return issued;
}
fn rangeEnd(offset: u64, length: usize) !u64 {
    return std.math.add(u64, offset, std.math.cast(u64, length) orelse return error.ArithmeticOverflow) catch error.ArithmeticOverflow;
}
fn move(output: []u8, input: []const u8) void {
    if (@intFromPtr(output.ptr) > @intFromPtr(input.ptr) and @intFromPtr(output.ptr) - @intFromPtr(input.ptr) < input.len)
        std.mem.copyBackwards(u8, output, input)
    else
        std.mem.copyForwards(u8, output, input);
}
fn put(bytes: []u8, value: u64) void {
    for (bytes, 0..) |*byte, index| byte.* = @truncate(value >> @intCast(index * 8));
}
fn get(bytes: []const u8) u64 {
    var value: u64 = 0;
    for (bytes, 0..) |byte, index| value |= @as(u64, byte) << @intCast(index * 8);
    return value;
}
const crc_table = blk: {
    @setEvalBranchQuota(5000);
    var table: [256]u32 = undefined;
    for (&table, 0..) |*entry, index| {
        var value: u32 = @intCast(index);
        for (0..8) |_| value = if (value & 1 != 0) (value >> 1) ^ 0xedb8_8320 else value >> 1;
        entry.* = value;
    }
    break :blk table;
};
fn update(crc: u32, byte: u8) u32 {
    return crc_table[@as(u8, @truncate(crc)) ^ byte] ^ (crc >> 8);
}
pub fn crc32(bytes: []const u8) u32 {
    var crc: u32 = 0xffff_ffff;
    for (bytes) |byte| crc = update(crc, byte);
    return ~crc;
}
const Writer = struct {
    device: storage.BlockDevice,
    block: u64,
    buffer: [sector_size]u8 = @splat(0),
    used: usize = 0,
    crc: u32 = 0xffff_ffff,
    verify: bool = false,
    fn transfer(self: *Writer) !void {
        if (self.verify) {
            var actual: [sector_size]u8 = undefined;
            defer secure_clear.bytes(&actual);
            try self.device.read(self.block, &actual);
            if (!std.mem.eql(u8, &actual, &self.buffer)) return error.NullifyVerificationFailed;
        } else try self.device.write(self.block, &self.buffer);
    }
    fn byte(self: *Writer, value: u8) !void {
        self.crc = update(self.crc, value);
        self.buffer[self.used] = value;
        self.used += 1;
        if (self.used == sector_size) {
            try self.transfer();
            self.block += 1;
            self.used = 0;
        }
    }
    fn bytes(self: *Writer, values: []const u8) !void {
        for (values) |value| try self.byte(value);
    }
    fn finish(self: *Writer) !u32 {
        if (self.used != 0) {
            @memset(self.buffer[self.used..], 0);
            try self.transfer();
        }
        return ~self.crc;
    }
};
const zero_chunk: [8 * sector_size]u8 = @splat(0);
const Reader = struct {
    device: storage.BlockDevice,
    block: u64,
    buffer: [sector_size]u8 = undefined,
    used: usize = sector_size,
    crc: u32 = 0xffff_ffff,
    fn byte(self: *Reader) !u8 {
        if (self.used == sector_size) {
            try self.device.read(self.block, &self.buffer);
            self.block += 1;
            self.used = 0;
        }
        const value = self.buffer[self.used];
        self.used += 1;
        self.crc = update(self.crc, value);
        return value;
    }
};

// The model separates volatile device writes from flushed media, and can fail
// each commit boundary. Tests never open a host disk or use physical pointers.
const TestDisk = struct {
    bytes: []u8,
    stable: []u8,
    writes: usize = 0,
    flushes: usize = 0,
    reads: usize = 0,
    last_read_block: ?u64 = null,
    ignored_writes: usize = 0,
    fail_write_after: ?usize = null,
    fail_flush_after: ?usize = null,
    fail_read_after: ?usize = null,
    ignore_write_after: ?usize = null,
    persist_failed_flush: bool = false,

    fn init() !TestDisk {
        const bytes = try std.testing.allocator.alloc(u8, disk_bytes);
        errdefer std.testing.allocator.free(bytes);
        const stable = try std.testing.allocator.alloc(u8, disk_bytes);
        @memset(bytes, 0);
        @memset(stable, 0);
        return .{ .bytes = bytes, .stable = stable };
    }
    fn deinit(self: *TestDisk) void {
        std.testing.allocator.free(self.bytes);
        std.testing.allocator.free(self.stable);
    }
    fn device(self: *TestDisk) storage.BlockDevice {
        return .{ .context = self, .read_fn = readBlocks, .write_fn = writeBlocks, .flush_fn = flushBlocks, .block_size = sector_size, .block_count = 2 * bank_blocks };
    }
    fn readBlocks(context: *anyopaque, block: u64, count: u64, output: []u8) !void {
        const self: *TestDisk = @ptrCast(@alignCast(context));
        if (self.fail_read_after) |remaining| {
            if (remaining == 0) return error.InjectedReadFailure;
            self.fail_read_after = remaining - 1;
        }
        const start: usize = @intCast(block * sector_size);
        if (count * sector_size != output.len or start > self.bytes.len or output.len > self.bytes.len - start) return error.TestBounds;
        @memcpy(output, self.bytes[start..][0..output.len]);
        self.reads += 1;
        self.last_read_block = block;
    }
    fn writeBlocks(context: *anyopaque, block: u64, count: u64, input: []const u8) !void {
        const self: *TestDisk = @ptrCast(@alignCast(context));
        if (self.fail_write_after) |remaining| {
            if (remaining == 0) return error.InjectedWriteFailure;
            self.fail_write_after = remaining - 1;
        }
        if (self.ignore_write_after) |remaining| {
            if (remaining == 0) {
                self.ignore_write_after = null;
                self.ignored_writes += 1;
                self.writes += 1;
                return;
            }
            self.ignore_write_after = remaining - 1;
        }
        const start: usize = @intCast(block * sector_size);
        if (count * sector_size != input.len or start > self.bytes.len or input.len > self.bytes.len - start) return error.TestBounds;
        @memcpy(self.bytes[start..][0..input.len], input);
        self.writes += 1;
    }
    fn flushBlocks(context: *anyopaque) !void {
        const self: *TestDisk = @ptrCast(@alignCast(context));
        if (self.fail_flush_after) |remaining| {
            if (remaining == 0) {
                if (self.persist_failed_flush) @memcpy(self.stable, self.bytes);
                return error.InjectedFlushFailure;
            }
            self.fail_flush_after = remaining - 1;
        }
        @memcpy(self.stable, self.bytes);
        self.flushes += 1;
    }
    fn crash(self: *TestDisk) void {
        @memcpy(self.bytes, self.stable);
        self.fail_write_after = null;
        self.fail_flush_after = null;
        self.fail_read_after = null;
        self.ignore_write_after = null;
        self.persist_failed_flush = false;
    }
};

const TestFs = DurableFs(12, 64, 96);
const private_metadata: ramfs.Metadata = .{ .domain = .container, .owner = 1 };
const nullify_secret = "nullify-current-secret-90123";
const nullify_history = "nullify-previous-secret-45678";
const nullify_orphan = "nullify-old-unlinked-secret-24680";
const test_payload_blocks = (TestFs.max_nodes * (record_header_bytes + TestFs.max_path_bytes + TestFs.max_file_bytes) + sector_size - 1) / sector_size;
const test_tail_batches = (bank_blocks - 1 - test_payload_blocks + 7) / 8;
const test_nullify_calls_per_bank = test_payload_blocks + test_tail_batches + 1;

fn seedNullify(fs: *TestFs, disk: *TestDisk) !void {
    const target = try seed(fs, disk);
    _ = try fs.write(target, 0, nullify_secret);
    const kept = try fs.create("/container/one/kept", private_metadata);
    _ = try fs.write(kept, 0, "other-current-file");
}
fn expectNullifyRamClean(fs: *const TestFs) !void {
    const bytes = std.mem.asBytes(&fs.nodes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, nullify_secret) == null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, nullify_history) == null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, nullify_orphan) == null);
}
fn expectNullifyRecovery(disk: *TestDisk) !void {
    disk.crash();
    var reopened: TestFs = .{};
    try reopened.mount(disk.device());
    try std.testing.expectEqualStrings("other-current-file", try reopened.contents(try reopened.lookup("/container/one/kept")));
    if (reopened.lookup("/container/one/note")) |target| {
        try std.testing.expectEqualStrings(nullify_secret, try reopened.contents(target));
    } else |err| try std.testing.expectEqual(error.NotFound, err);
}
fn expectNullifyPoisoned(fs: *TestFs) !void {
    try std.testing.expect(fs.poisoned);
    try std.testing.expectError(error.RemountRequired, fs.root());
    try expectNullifyRamClean(fs);
}

test "nullify reconstructs both complete banks and RAM histories while preserving current other owners" {
    const t = std.testing;
    var disk = try TestDisk.init();
    defer disk.deinit();
    var fs: TestFs = .{};
    try seedNullify(&fs, &disk);
    const target = try fs.lookup("/container/one/note");
    _ = try fs.write(target, 0, nullify_history);
    try fs.rename("/container/one/note", "/container/one/erased-renamed-file");
    _ = try fs.write(target, 0, nullify_secret);
    const second_owner: ramfs.Metadata = .{ .domain = .container, .owner = 2 };
    _ = try fs.mkdir("/container/two", second_owner);
    const other = try fs.create("/container/two/kept", second_owner);
    _ = try fs.write(other, 0, "other-owner-survives");
    const removed = try fs.create("/container/one/ordinary-removed", private_metadata);
    _ = try fs.write(removed, 0, nullify_orphan);
    try fs.unlink("/container/one/ordinary-removed");
    // Ordinary unlink leaves its prior bytes in the older valid snapshot.
    try t.expect(std.mem.indexOf(u8, disk.stable, nullify_orphan) != null);
    // Include earlier renamed/reused/invalid-slot remnants and unused sector
    // tails which ordinary CoW transactions do not rewrite.
    for (0..2) |bank| {
        const tail = bank * bank_blocks * sector_size + (bank_blocks - 1) * sector_size;
        @memcpy(disk.bytes[tail..][0..nullify_history.len], nullify_history);
        @memcpy(disk.stable[tail..][0..nullify_history.len], nullify_history);
    }
    @memcpy(fs.nodes[1 - fs.live][11].data[0..nullify_orphan.len], nullify_orphan);
    const generation = fs.generation;
    try fs.nullify("/container/one/erased-renamed-file");
    try t.expectEqual(generation + 2, fs.generation);
    for ([_][]const u8{ nullify_secret, nullify_history, nullify_orphan, "/container/one/erased-renamed-file" }) |pattern| {
        try t.expect(std.mem.indexOf(u8, disk.bytes, pattern) == null);
        try t.expect(std.mem.indexOf(u8, disk.stable, pattern) == null);
    }
    try expectNullifyRamClean(&fs);
    try t.expectError(error.StaleNode, fs.stat(target));
    try t.expectEqualStrings("other-current-file", try fs.contents(try fs.lookup("/container/one/kept")));
    try t.expectEqualStrings("other-owner-survives", try fs.contents(other));
    for (0..2) |chosen| {
        const other_header = (1 - chosen) * bank_blocks * sector_size;
        var saved: [sector_size]u8 = undefined;
        @memcpy(&saved, disk.bytes[other_header..][0..sector_size]);
        @memset(disk.bytes[other_header..][0..sector_size], 0);
        var reopened: TestFs = .{};
        try reopened.mount(disk.device());
        try t.expectError(error.NotFound, reopened.lookup("/container/one/erased-renamed-file"));
        try t.expectEqualStrings("other-owner-survives", try reopened.contents(try reopened.lookup("/container/two/kept")));
        @memcpy(disk.bytes[other_header..][0..sector_size], &saved);
    }
    // Corrupting the newest header falls back to a second clean valid bank.
    disk.bytes[fs.active_disk * bank_blocks * sector_size] ^= 0xff;
    var fallback: TestFs = .{};
    try fallback.mount(disk.device());
    try t.expectError(error.NotFound, fallback.lookup("/container/one/erased-renamed-file"));
}

test "nullify preserves an explicitly copied current file rather than erasing equal content elsewhere" {
    const t = std.testing;
    var disk = try TestDisk.init();
    defer disk.deinit();
    var fs: TestFs = .{};
    try seedNullify(&fs, &disk);
    _ = try fs.copy("/container/one/note", "/container/one/retained-copy", private_metadata);
    try fs.nullify("/container/one/note");
    disk.crash();
    var reopened: TestFs = .{};
    try reopened.mount(disk.device());
    try t.expectError(error.NotFound, reopened.lookup("/container/one/note"));
    try t.expectEqualStrings(nullify_secret, try reopened.contents(try reopened.lookup("/container/one/retained-copy")));
}

test "nullify removes actual prior content versions and retained pre-rename paths" {
    const t = std.testing;
    for ([_]bool{ false, true }) |renamed| {
        var disk = try TestDisk.init();
        defer disk.deinit();
        var fs: TestFs = .{};
        try seedNullify(&fs, &disk);
        _ = try fs.write(try fs.lookup("/container/one/note"), 0, nullify_history);
        try t.expect(std.mem.indexOf(u8, disk.stable, nullify_secret) != null);
        try t.expect(std.mem.indexOf(u8, disk.stable, nullify_history) != null);
        if (renamed) try fs.rename("/container/one/note", "/container/one/renamed-secret");
        const path_bytes_ = if (renamed) "/container/one/renamed-secret" else "/container/one/note";
        try fs.nullify(path_bytes_);
        for ([_][]const u8{ nullify_secret, nullify_history, "/container/one/note", "/container/one/renamed-secret" }) |pattern|
            try t.expect(std.mem.indexOf(u8, disk.stable, pattern) == null);
        try expectNullifyRamClean(&fs);
        disk.crash();
        var reopened: TestFs = .{};
        try reopened.mount(disk.device());
        try t.expectError(error.NotFound, reopened.lookup(path_bytes_));
        try t.expectEqualStrings("other-current-file", try reopened.contents(try reopened.lookup("/container/one/kept")));
    }
}

test "nullify failure coverage spans each payload sector tail batches header flush and readback in both phases" {
    const t = std.testing;
    // Exercise every payload-sector boundary and first/middle/final identical
    // tail batches. Exhausting thousands of redundant sectors adds no state
    // transition; both phases and every distinct header/flush/read path matter.
    const write_positions = [_]usize{ 0, 1, 2, 3, 4, 5, test_payload_blocks, test_payload_blocks + test_tail_batches / 2, test_payload_blocks + test_tail_batches - 1, test_nullify_calls_per_bank - 1 };
    const read_positions = [_]usize{ 0, 1, 2, 3, 4, 5, 6, 1 + test_payload_blocks, 1 + test_payload_blocks + test_tail_batches / 2, test_nullify_calls_per_bank - 1 };
    for (0..2) |phase| {
        for (write_positions) |position| {
            var disk = try TestDisk.init();
            defer disk.deinit();
            var fs: TestFs = .{};
            try seedNullify(&fs, &disk);
            disk.fail_write_after = phase * test_nullify_calls_per_bank + position;
            try t.expectError(error.InjectedWriteFailure, fs.nullify("/container/one/note"));
            try expectNullifyPoisoned(&fs);
            try expectNullifyRecovery(&disk);
        }
        for (read_positions) |position| {
            var disk = try TestDisk.init();
            defer disk.deinit();
            var fs: TestFs = .{};
            try seedNullify(&fs, &disk);
            const old_bank = fs.active_disk;
            const original_crc = crc32(disk.stable[old_bank * bank_blocks * sector_size ..][0 .. bank_blocks * sector_size]);
            disk.fail_read_after = phase * test_nullify_calls_per_bank + position;
            try t.expectError(error.InjectedReadFailure, fs.nullify("/container/one/note"));
            try expectNullifyPoisoned(&fs);
            if (phase == 0) try t.expectEqual(original_crc, crc32(disk.stable[old_bank * bank_blocks * sector_size ..][0 .. bank_blocks * sector_size]));
            try expectNullifyRecovery(&disk);
        }
    }
    for (0..4) |position| for ([_]bool{ false, true }) |persist| {
        var disk = try TestDisk.init();
        defer disk.deinit();
        var fs: TestFs = .{};
        try seedNullify(&fs, &disk);
        disk.fail_flush_after = position;
        disk.persist_failed_flush = persist;
        try t.expectError(error.InjectedFlushFailure, fs.nullify("/container/one/note"));
        try expectNullifyPoisoned(&fs);
        try expectNullifyRecovery(&disk);
    };
}

test "nullify detects silent ignored writes with exact header payload padding and tail readback" {
    const t = std.testing;
    const payload_bytes = TestFs.max_nodes * (record_header_bytes + TestFs.max_path_bytes + TestFs.max_file_bytes);
    const cases = [_]struct { position: usize, block_offset: usize, padding_only: bool = false, header: bool = false }{
        .{ .position = 0, .block_offset = 1 },
        .{ .position = test_payload_blocks - 1, .block_offset = test_payload_blocks, .padding_only = true },
        .{ .position = test_payload_blocks, .block_offset = 1 + test_payload_blocks },
        .{ .position = test_nullify_calls_per_bank - 1, .block_offset = 0, .header = true },
    };
    for (0..2) |phase| for (cases) |case| {
        var disk = try TestDisk.init();
        defer disk.deinit();
        var fs: TestFs = .{};
        try seedNullify(&fs, &disk);
        const initial_generation = fs.generation;
        const target_bank = if (phase == 0) 1 - fs.active_disk else fs.active_disk;
        // Populate all candidate skipped sectors, including padding/tail, with
        // stale bytes. A correct rewrite must replace each with exact encoding.
        const at = target_bank * bank_blocks * sector_size + case.block_offset * sector_size;
        if (case.padding_only) {
            // The last payload record belongs to an unused node. Its encoded
            // bytes are already correct; only bytes OUTSIDE the CRC payload
            // are dirty. Header/payload CRC validation alone would accept it.
            try t.expect(!fs.nodes[fs.live][TestFs.max_nodes - 1].occupied);
            @memset(disk.bytes[at..][0..sector_size], 0);
            @memset(disk.stable[at..][0..sector_size], 0);
            const padding_start = payload_bytes % sector_size;
            try t.expect(padding_start != 0);
            @memset(disk.bytes[at + padding_start .. at + sector_size], 0x5a);
            @memset(disk.stable[at + padding_start .. at + sector_size], 0x5a);
        } else {
            @memset(disk.bytes[at..][0..sector_size], 0x5a);
            @memset(disk.stable[at..][0..sector_size], 0x5a);
        }
        const old_bank = fs.active_disk;
        const original_crc = crc32(disk.stable[old_bank * bank_blocks * sector_size ..][0 .. bank_blocks * sector_size]);
        disk.ignore_write_after = phase * test_nullify_calls_per_bank + case.position;
        try t.expectError(error.NullifyVerificationFailed, fs.nullify("/container/one/note"));
        try t.expectEqual(@as(usize, 1), disk.ignored_writes);
        try t.expect(disk.ignore_write_after == null);
        const expected_read_block: u64 = @intCast(target_bank * bank_blocks + case.block_offset);
        try t.expectEqual(expected_read_block, disk.last_read_block.?);
        if (!case.header) {
            var header: [sector_size]u8 = undefined;
            const start = target_bank * bank_blocks * sector_size;
            @memcpy(&header, disk.bytes[start..][0..sector_size]);
            const parsed = (try fs.parseHeader(&header, target_bank)).?;
            try t.expectEqual(initial_generation + phase + 1, parsed.generation);
            if (case.padding_only or case.block_offset > test_payload_blocks)
                try t.expectEqual(parsed.payload_crc, crc32(disk.bytes[start + sector_size ..][0..payload_bytes]));
        }
        try expectNullifyPoisoned(&fs);
        if (phase == 0) try t.expectEqual(original_crc, crc32(disk.stable[old_bank * bank_blocks * sector_size ..][0 .. bank_blocks * sector_size]));
        try expectNullifyRecovery(&disk);
    };
}

test "nullify preflights two generations and rejects nonfiles before any RAM or device mutation" {
    const t = std.testing;
    var disk = try TestDisk.init();
    defer disk.deinit();
    var fs: TestFs = .{};
    try seedNullify(&fs, &disk);
    _ = try fs.mkdir("/bundle", .{ .domain = .bundle, .owner = 1 });
    _ = try fs.addBorrowed("/bundle/immutable", .{ .domain = .bundle, .owner = 1 }, "immutable-secret");
    const writes = disk.writes;
    const flushes = disk.flushes;
    const reads = disk.reads;
    const ram_crc = crc32(std.mem.asBytes(&fs.nodes));
    const media_crc = crc32(disk.stable);
    try t.expectError(error.IsDirectory, fs.nullify("/container/one"));
    try t.expectError(error.ReadOnly, fs.nullify("/bundle/immutable"));
    try t.expectError(error.NotFound, fs.nullify("/container/one/missing"));
    for ([_]u64{ std.math.maxInt(u64) - 1, std.math.maxInt(u64) }) |generation| {
        fs.generation = generation;
        try t.expectError(error.GenerationExhausted, fs.nullify("/container/one/note"));
    }
    try t.expectEqual(writes, disk.writes);
    try t.expectEqual(flushes, disk.flushes);
    try t.expectEqual(reads, disk.reads);
    try t.expectEqual(ram_crc, crc32(std.mem.asBytes(&fs.nodes)));
    try t.expectEqual(media_crc, crc32(disk.stable));
    try t.expect(!fs.poisoned);
    fs.generation = std.math.maxInt(u64) - 2;
    try fs.nullify("/container/one/note");
    try t.expectEqual(std.math.maxInt(u64), fs.generation);
}
fn seed(fs: *TestFs, disk: *TestDisk) !ramfs.NodeId {
    try fs.format(disk.device());
    _ = try fs.mkdir("/container", .{});
    _ = try fs.mkdir("/container/one", private_metadata);
    const file = try fs.create("/container/one/note", private_metadata);
    _ = try fs.write(file, 0, "old");
    return file;
}

test "durable reopen retains directories ownership gaps and committed bytes" {
    const t = std.testing;
    var disk = try TestDisk.init();
    defer disk.deinit();
    var fs: TestFs = .{};
    const file = try seed(&fs, &disk);
    _ = try fs.write(file, 6, "new");
    try fs.truncate(file, 12);
    disk.crash();
    var reopened: TestFs = .{};
    try reopened.mount(disk.device());
    const restored = try reopened.lookup("/container/one/note");
    try t.expectEqualSlices(u8, &.{ 'o', 'l', 'd', 0, 0, 0, 'n', 'e', 'w', 0, 0, 0 }, try reopened.contents(restored));
    try t.expectEqual(@as(u64, 1), (try reopened.stat(restored)).metadata.owner);
    var cursor: usize = 0;
    try t.expectEqual(restored, (try reopened.enumerate(try reopened.lookup("/container/one"), &cursor)).?.id);
    try t.expect((try reopened.enumerate(try reopened.lookup("/container/one"), &cursor)) == null);
    try t.expectError(error.AlreadyMounted, reopened.mount(disk.device()));
}

test "each failed commit boundary keeps recovery atomic and poisons live instance" {
    const t = std.testing;
    for (0..4) |failure| {
        var disk = try TestDisk.init();
        defer disk.deinit();
        var fs: TestFs = .{};
        const file = try seed(&fs, &disk);
        const old_bank = fs.active_disk;
        const old_crc = crc32(disk.stable[old_bank * bank_blocks * sector_size ..][0 .. bank_blocks * sector_size]);
        switch (failure) {
            0 => disk.fail_write_after = 0,
            1 => disk.fail_flush_after = 0,
            2 => disk.fail_write_after = (TestFs.max_nodes * (record_header_bytes + TestFs.max_path_bytes + TestFs.max_file_bytes) + sector_size - 1) / sector_size,
            3 => {
                disk.fail_flush_after = 1;
                disk.persist_failed_flush = true;
            },
            else => unreachable,
        }
        if (failure == 0 or failure == 2)
            try t.expectError(error.InjectedWriteFailure, fs.write(file, 0, "new"))
        else
            try t.expectError(error.InjectedFlushFailure, fs.write(file, 0, "new"));
        try t.expectError(error.RemountRequired, fs.contents(file));
        try t.expectError(error.RemountRequired, fs.create("/container/one/other", private_metadata));
        try t.expectEqual(old_crc, crc32(disk.stable[old_bank * bank_blocks * sector_size ..][0 .. bank_blocks * sector_size]));
        disk.crash();
        var reopened: TestFs = .{};
        try reopened.mount(disk.device());
        try t.expectEqualStrings(if (failure == 3) "new" else "old", try reopened.contents(try reopened.lookup("/container/one/note")));
    }
}

test "snapshot CRC corruption falls back to older bank and never formats bad media" {
    const t = std.testing;
    var disk = try TestDisk.init();
    defer disk.deinit();
    var fs: TestFs = .{};
    const file = try seed(&fs, &disk);
    _ = try fs.write(file, 0, "new");
    const file_slot: usize = @intCast((@backingInt(file) & 0xffff_ffff) - 1);
    const data_offset = sector_size + file_slot * (record_header_bytes + TestFs.max_path_bytes + TestFs.max_file_bytes) + record_header_bytes + TestFs.max_path_bytes;
    // Alter only a valid file byte: semantic validation still succeeds, so the
    // payload CRC itself must reject the newest candidate.
    disk.stable[fs.active_disk * bank_blocks * sector_size + data_offset] ^= 1;
    disk.crash();
    var recovered: TestFs = .{};
    try recovered.mount(disk.device());
    try t.expectEqualStrings("old", try recovered.contents(try recovered.lookup("/container/one/note")));
    disk.stable[(1 - fs.active_disk) * bank_blocks * sector_size + data_offset] ^= 1;
    disk.crash();
    const writes = disk.writes;
    var rejected: TestFs = .{};
    try t.expectError(error.NoValidSnapshot, rejected.mount(disk.device()));
    try t.expectEqual(writes, disk.writes);
}

test "atomic subtree copy rename delete and reuse keep node identities honest" {
    const t = std.testing;
    var disk = try TestDisk.init();
    defer disk.deinit();
    var fs: TestFs = .{};
    const file = try seed(&fs, &disk);
    const before_root_copy = disk.writes;
    try t.expectError(error.InvalidPath, fs.copy("/", "/container/one/root-copy", private_metadata));
    try t.expectEqual(before_root_copy, disk.writes);
    try t.expectError(error.NotFound, fs.lookup("/container/one/root-copy"));
    _ = try fs.mkdir("/container/one/tree", private_metadata);
    const original = try fs.create("/container/one/tree/note", private_metadata);
    _ = try fs.write(original, 0, "old");
    _ = try fs.copy("/container/one/tree", "/container/one/copy", private_metadata);
    const duplicate = try fs.lookup("/container/one/copy/note");
    try t.expect(duplicate != file);
    try t.expectEqualStrings("old", try fs.contents(duplicate));
    try fs.rename("/container/one/copy", "/container/one/moved");
    try t.expectEqual(duplicate, try fs.lookup("/container/one/moved/note"));
    try t.expectError(error.NotFound, fs.lookup("/container/one/copy/note"));
    try t.expectError(error.DirectoryNotEmpty, fs.unlink("/container/one/moved"));
    try t.expectError(error.InvalidPath, fs.rename("/container/one/moved", "/container/one/moved/inside"));
    try t.expectError(error.AlreadyExists, fs.rename("/container/one/moved/note", "/container/one/note"));
    try fs.unlink("/container/one/moved/note");
    try t.expectError(error.StaleNode, fs.read(duplicate, 0, &.{}));
    const reused = try fs.create("/container/one/moved/new", private_metadata);
    try t.expect(reused != duplicate);
    try t.expectError(error.StaleNode, fs.write(duplicate, 0, "leak"));
    try fs.unlink("/container/one/moved/new");
    try fs.unlink("/container/one/moved");
    disk.crash();
    var reopened: TestFs = .{};
    try reopened.mount(disk.device());
    try t.expectError(error.NotFound, reopened.lookup("/container/one/moved"));
    try t.expectEqualStrings("old", try reopened.contents(try reopened.lookup("/container/one/note")));
}

test "immutable bundle overlay is rebuilt while copies into containers persist" {
    const t = std.testing;
    var disk = try TestDisk.init();
    defer disk.deinit();
    var fs: TestFs = .{};
    _ = try seed(&fs, &disk);
    _ = try fs.mkdir("/bundle", .{});
    _ = try fs.mkdir("/bundle/one", .{ .domain = .bundle, .owner = 1 });
    const executable = try fs.addBorrowed("/bundle/one/elf", .{ .domain = .bundle, .owner = 1, .executable = true }, "ELF");
    try t.expectError(error.ReadOnly, fs.write(executable, 0, "bad"));
    try t.expectError(error.ReadOnly, fs.unlink("/bundle/one/elf"));
    const copied = try fs.copy("/bundle/one/elf", "/container/one/copied", private_metadata);
    try t.expect(!(try fs.stat(copied)).metadata.executable);
    disk.crash();
    var reopened: TestFs = .{};
    try reopened.mount(disk.device());
    try t.expectError(error.NotFound, reopened.lookup("/bundle"));
    try t.expectEqualStrings("ELF", try reopened.contents(try reopened.lookup("/container/one/copied")));
}

test "bounds path and generation failures reject before disk or visible mutation" {
    const t = std.testing;
    var disk = try TestDisk.init();
    defer disk.deinit();
    var fs: TestFs = .{};
    const file = try seed(&fs, &disk);
    const writes = disk.writes;
    try t.expectError(error.FileTooLarge, fs.write(file, 64, "x"));
    try t.expectError(error.ArithmeticOverflow, fs.write(file, std.math.maxInt(u64), "xx"));
    try t.expectError(error.FileTooLarge, fs.truncate(file, 65));
    try t.expectError(error.InvalidPath, fs.create("/container/one/../x", private_metadata));
    try t.expectError(error.InvalidMetadata, fs.mkdir("/invalid", .{ .owner = 1 }));
    try t.expectError(error.InvalidMetadata, fs.create("/container/one/x", .{ .domain = .container }));
    try t.expectError(error.InvalidMetadata, fs.create("/container/one/x", .{ .domain = .container, .owner = 1, .executable = true }));
    try t.expectEqual(writes, disk.writes);
    try t.expectEqualStrings("old", try fs.contents(file));
    fs.next_serial = std.math.maxInt(u32);
    const last = try fs.create("/container/one/last", private_metadata);
    try t.expectEqual(@as(u64, std.math.maxInt(u32)), @backingInt(last) >> 32);
    const after_last = disk.writes;
    try t.expectError(error.GenerationExhausted, fs.create("/container/one/exhausted", private_metadata));
    try t.expectEqual(after_last, disk.writes);
    fs.generation = std.math.maxInt(u64);
    try t.expectError(error.GenerationExhausted, fs.write(file, 0, "new"));
    try t.expectEqualStrings("old", try fs.contents(file));
}

test "copy preflight capacity and owner failures leave complete source intact" {
    const t = std.testing;
    var disk = try TestDisk.init();
    defer disk.deinit();
    var fs: DurableFs(5, 8, 48) = .{};
    try fs.format(disk.device());
    _ = try fs.mkdir("/one", private_metadata);
    _ = try fs.mkdir("/one/tree", private_metadata);
    const file = try fs.create("/one/tree/file", private_metadata);
    _ = try fs.write(file, 0, "payload");
    _ = try fs.mkdir("/other", .{ .domain = .container, .owner = 2 });
    const writes = disk.writes;
    try t.expectError(error.NodeCapacity, fs.copy("/one/tree", "/one/duplicate", private_metadata));
    try t.expectError(error.InvalidMetadata, fs.rename("/one/tree/file", "/other/file"));
    try t.expectEqual(writes, disk.writes);
    try t.expectError(error.NotFound, fs.lookup("/one/duplicate"));
    try t.expectEqualStrings("payload", try fs.contents(file));
}

test "mount requires exact compatible bounded writable media and valid header" {
    const t = std.testing;
    var disk = try TestDisk.init();
    defer disk.deinit();
    var fs: TestFs = .{};
    var device = disk.device();
    device.block_size = 1024;
    try t.expectError(error.InvalidGeometry, fs.mount(device));
    device = disk.device();
    device.block_count -= 1;
    try t.expectError(error.InvalidGeometry, fs.mount(device));
    device = disk.device();
    device.write_fn = null;
    try t.expectError(error.ReadOnly, fs.mount(device));
    device = disk.device();
    device.flush_fn = null;
    try t.expectError(error.FlushUnavailable, fs.mount(device));
    try t.expectError(error.NoValidSnapshot, fs.mount(disk.device()));
    try fs.format(disk.device());
    var incompatible: DurableFs(13, 64, 96) = .{};
    try t.expectError(error.IncompatibleFormat, incompatible.mount(disk.device()));
    put(disk.bytes[8..12], version + 1);
    @memset(disk.bytes[60..64], 0);
    put(disk.bytes[60..64], crc32(disk.bytes[0..sector_size]));
    var unsupported: TestFs = .{};
    try t.expectError(error.UnsupportedFormat, unsupported.mount(disk.device()));
    try t.expectEqual(@as(u32, 0xcbf4_3926), crc32("123456789"));
}

test "valid CRC never substitutes for bounded record and tree validation" {
    const t = std.testing;
    var disk = try TestDisk.init();
    defer disk.deinit();
    var fs: TestFs = .{};
    try fs.format(disk.device());
    const payload_size = TestFs.max_nodes * (record_header_bytes + TestFs.max_path_bytes + TestFs.max_file_bytes);
    const original = try t.allocator.dupe(u8, disk.bytes[0 .. sector_size + payload_size]);
    defer t.allocator.free(original);
    for (0..6) |bad_field| {
        @memcpy(disk.bytes[0..original.len], original);
        const record = disk.bytes[sector_size..][0..record_header_bytes];
        switch (bad_field) {
            0 => put(record[16..20], TestFs.max_nodes),
            1 => put(record[20..24], TestFs.max_path_bytes + 1),
            2 => put(record[24..32], TestFs.max_file_bytes + 1),
            3 => record[32] = 1,
            4 => put(record[8..16], 1), // system-domain owner must be zero
            5 => {
                put(record[4..8], 2); // root identity is permanently serial 1
                put(disk.bytes[64..68], 3);
            },
            else => unreachable,
        }
        put(disk.bytes[56..60], crc32(disk.bytes[sector_size..][0..payload_size]));
        @memset(disk.bytes[60..64], 0);
        put(disk.bytes[60..64], crc32(disk.bytes[0..sector_size]));
        const writes = disk.writes;
        var rejected: TestFs = .{};
        try t.expectError(error.NoValidSnapshot, rejected.mount(disk.device()));
        try t.expectEqual(writes, disk.writes);
    }
}
