//! Bounded app-scoped VFS. The kernel selects the current process's Files and
//! trusted Profile; neither an app ID nor a backend path comes from user input.
//! Storage and tables have no heap dependencies. Callers serialize operations.
const std = @import("std");
const filesystem = @import("filesystem");
const security = @import("security");

pub const Profile = security.sandbox.Profile;
pub const Descriptor = enum(u64) { _ };
pub const descriptor_tag: u64 = 1 << 63;
pub const max_generation: u32 = 0x7fff_ffff;
pub const max_path: usize = 128;
pub const OpenFlags = struct {
    read: bool = false,
    write: bool = false,
    create: bool = false,
    truncate: bool = false,
};
pub const Whence = enum { start, current, end };
pub const Stat = struct { size: u64, read_only: bool, executable: bool };
pub const DirectoryEntry = struct {
    name: [96]u8 = @splat(0),
    name_len: u8 = 0,
    kind: enum { directory, file },
    size: u64,
    read_only: bool,
};
pub const Error = error{
    InvalidPath,
    PathTooLong,
    InvalidOpenFlags,
    InvalidDescriptor,
    StaleDescriptor,
    FileTableFull,
    PermissionDenied,
    NotFile,
    NotExecutable,
    OffsetOverflow,
};

const Domain = filesystem.ramfs.Domain;
const Metadata = filesystem.ramfs.Metadata;
const NodeId = filesystem.ramfs.NodeId;
const Resolved = struct {
    domain: Domain,
    bytes: [max_path]u8 = undefined,
    length: usize,

    fn path(self: *const Resolved) []const u8 {
        return self.bytes[0..self.length];
    }
};

/// Production uses filesystem.durable.DurableFs(32, 4096, 128); RamFs remains
/// useful for portable tests. Keep this object in retained kernel storage.
/// Mount/reset are trusted startup operations, never used with live descriptors.
pub fn Vfs(comptime Backend: type) type {
    return struct {
        const Self = @This();
        fs: Backend = .{},

        pub fn reset(self: *Self) !void {
            try self.fs.reset();
        }

        pub fn mount(self: *Self, device: filesystem.BlockDevice) !void {
            try self.fs.mount(device);
        }

        /// Trusted launch setup. Borrowed bytes must remain immutable and alive
        /// until the entire VFS lifetime ends. User requests cannot mount files.
        pub fn mountBundle(self: *Self, profile: Profile, path: []const u8, bytes: []const u8, executable: bool) !void {
            const resolved = try resolve(profile, path);
            if (resolved.domain != .bundle) return error.PermissionDenied;
            try self.ensureNamespace(profile.app_id, .bundle);
            const metadata: Metadata = .{ .domain = .bundle, .owner = profile.app_id, .executable = executable };
            try self.ensureParents(resolved.path(), metadata);
            _ = try self.fs.addBorrowed(resolved.path(), metadata, bytes);
        }

        pub fn prepareContainer(self: *Self, app_id: u64) !void {
            if (app_id == 0) return error.InvalidAppIdentity;
            try self.ensureNamespace(app_id, .container);
        }

        pub fn mountContainer(self: *Self, profile: Profile) !void {
            try validateProfile(profile);
            try self.prepareContainer(profile.app_id);
        }

        pub fn mkdir(self: *Self, profile: Profile, path: []const u8) !void {
            const resolved = try resolve(profile, path);
            try mutableNamespace(profile, resolved.domain);
            try self.checkParent(profile, &resolved);
            _ = try self.fs.mkdir(resolved.path(), .{ .domain = .container, .owner = profile.app_id });
        }

        /// Copied basename; no borrowed pointers escape a snapshot transaction.
        /// Cursor is an insertion-slot position and should reset after mutation.
        pub fn list(self: *Self, profile: Profile, path: []const u8, cursor: *usize) !?DirectoryEntry {
            const resolved = try resolveDirectory(profile, path);
            try authorize(profile, resolved.domain, 0);
            const parent = try self.fs.lookup(resolved.path());
            const parent_stat = try self.checkedAnyNode(profile, resolved.domain, parent);
            if (parent_stat.kind != .directory) return error.NotDirectory;
            const entry = (try self.fs.enumerate(parent, cursor)) orelse return null;
            _ = try self.checkedAnyNode(profile, resolved.domain, entry.id);
            const full_path = try self.fs.path(entry.id);
            const separator = std.mem.lastIndexOfScalar(u8, full_path, '/').?;
            const name = full_path[separator + 1 ..];
            if (name.len > 96) return error.PathTooLong;
            var result: DirectoryEntry = .{
                .kind = if (entry.kind == .directory) .directory else .file,
                .size = entry.size,
                .read_only = resolved.domain == .bundle or entry.kind == .borrowed_file,
                .name_len = @intCast(name.len),
            };
            @memcpy(result.name[0..name.len], name);
            return result;
        }

        pub fn copy(self: *Self, profile: Profile, source: []const u8, destination: []const u8) !void {
            const from = try resolve(profile, source);
            const to = try resolve(profile, destination);
            // Check both namespace authorities before probing either existence.
            try authorize(profile, from.domain, security.handles.rights.read);
            try mutableNamespace(profile, to.domain);
            const node = try self.fs.lookup(from.path());
            try self.verifyTree(profile, from.domain, node);
            try self.checkParent(profile, &to);
            if (comptime !@hasDecl(Backend, "copy")) return error.NotSupported;
            _ = try self.fs.copy(from.path(), to.path(), .{ .domain = .container, .owner = profile.app_id });
        }

        pub fn rename(self: *Self, profile: Profile, source: []const u8, destination: []const u8) !void {
            const from = try resolve(profile, source);
            const to = try resolve(profile, destination);
            try mutableNamespace(profile, from.domain);
            try mutableNamespace(profile, to.domain);
            const node = try self.fs.lookup(from.path());
            try self.verifyTree(profile, from.domain, node);
            try self.checkParent(profile, &to);
            if (comptime !@hasDecl(Backend, "rename")) return error.NotSupported;
            try self.fs.rename(from.path(), to.path());
        }

        pub fn unlink(self: *Self, profile: Profile, path: []const u8) !void {
            const resolved = try resolve(profile, path);
            try mutableNamespace(profile, resolved.domain);
            const node = try self.fs.lookup(resolved.path());
            try self.verifyTree(profile, resolved.domain, node);
            if (comptime !@hasDecl(Backend, "unlink")) return error.NotSupported;
            try self.fs.unlink(resolved.path());
        }

        /// A file-scoped logical overwrite/delete. The backend supplies the
        /// two-bank scrub; this never authorizes whole-device sanitization.
        pub fn nullify(self: *Self, profile: Profile, path: []const u8) !void {
            const resolved = try resolve(profile, path);
            try mutableNamespace(profile, resolved.domain);
            const node = try self.fs.lookup(resolved.path());
            const found = try self.checkedNode(profile, resolved.domain, node);
            if (found.kind != .mutable_file) return error.ReadOnly;
            if (comptime !@hasDecl(Backend, "nullify")) return error.NotSupported;
            try self.fs.nullify(resolved.path());
        }

        /// Whole-image borrow for the trusted executable loader, independent of
        /// file-descriptor allocation and current file offsets. Mutable files
        /// are never executable in this first profile.
        pub fn execPath(self: *Self, profile: Profile, path: []const u8) ![]const u8 {
            const resolved = try resolve(profile, path);
            try authorize(profile, resolved.domain, security.handles.rights.read);
            if (resolved.domain != .bundle) return error.PermissionDenied;
            const node = try self.fs.lookup(resolved.path());
            const node_stat = try self.checkedNode(profile, resolved.domain, node);
            if (node_stat.kind != .borrowed_file or !node_stat.metadata.executable) return error.NotExecutable;
            return self.fs.contents(node);
        }

        fn checkedNode(self: *Self, profile: Profile, domain: Domain, node: NodeId) !filesystem.ramfs.Stat {
            const node_stat = try self.checkedAnyNode(profile, domain, node);
            if (node_stat.kind == .directory) return error.NotFile;
            return node_stat;
        }

        fn checkedAnyNode(self: *Self, profile: Profile, domain: Domain, node: NodeId) !filesystem.ramfs.Stat {
            try authorize(profile, domain, 0);
            const node_stat = try self.fs.stat(node);
            if (node_stat.metadata.domain != domain or node_stat.metadata.owner != profile.app_id)
                return error.PermissionDenied;
            return node_stat;
        }

        fn checkParent(self: *Self, profile: Profile, path: *const Resolved) !void {
            const full = path.path();
            const separator = std.mem.lastIndexOfScalar(u8, full, '/').?;
            const parent = try self.fs.lookup(full[0..separator]);
            if ((try self.checkedAnyNode(profile, path.domain, parent)).kind != .directory) return error.NotDirectory;
        }

        fn verifyTree(self: *Self, profile: Profile, domain: Domain, root_node: NodeId) !void {
            var pending: [Backend.max_nodes]NodeId = undefined;
            var length: usize = 1;
            var visited: usize = 0;
            pending[0] = root_node;
            while (length != 0) {
                length -= 1;
                const node = pending[length];
                visited += 1;
                if (visited > Backend.max_nodes) return error.InvalidMetadata;
                const node_stat = try self.checkedAnyNode(profile, domain, node);
                if (node_stat.kind != .directory) continue;
                var cursor: usize = 0;
                while (try self.fs.enumerate(node, &cursor)) |child| {
                    if (length == pending.len) return error.InvalidMetadata;
                    pending[length] = child.id;
                    length += 1;
                }
            }
        }

        fn ensureNamespace(self: *Self, app_id: u64, domain: Domain) !void {
            const prefix: []const u8 = switch (domain) {
                .bundle => "/bundle",
                .container => "/container",
                else => return error.PermissionDenied,
            };
            try self.ensureDirectory(prefix, .{});
            var root: [max_path]u8 = undefined;
            @memcpy(root[0..prefix.len], prefix);
            root[prefix.len] = '/';
            encodeAppId(root[prefix.len + 1 ..][0..16], app_id);
            try self.ensureDirectory(root[0 .. prefix.len + 17], .{ .domain = domain, .owner = app_id });
        }

        fn ensureParents(self: *Self, path: []const u8, metadata: Metadata) !void {
            // Namespace and app root already exist; nested bundle directories
            // have the same owner but are not executable themselves.
            var directory_metadata = metadata;
            directory_metadata.executable = false;
            const scoped_start: usize = (if (metadata.domain == .bundle) @as(usize, 7) else 10) + 17;
            for (path[scoped_start..], scoped_start..) |byte, index| {
                if (byte == '/') try self.ensureDirectory(path[0..index], directory_metadata);
            }
        }

        fn ensureDirectory(self: *Self, path: []const u8, metadata: Metadata) !void {
            _ = self.fs.mkdir(path, metadata) catch |err| {
                if (err != error.AlreadyExists) return err;
                const found = try self.fs.lookup(path);
                const node_stat = try self.fs.stat(found);
                if (node_stat.kind != .directory or node_stat.metadata.domain != metadata.domain or
                    node_stat.metadata.owner != metadata.owner or node_stat.metadata.executable)
                    return error.PermissionDenied;
                return;
            };
        }
    };
}

/// One instance per process lifetime. The owner is bound from trusted launch
/// provenance. Do not reset/copy this table to revive an issued descriptor.
pub fn Files(comptime capacity: usize) type {
    if (capacity > std.math.maxInt(u32)) @compileError("File capacity exceeds descriptor slot encoding");
    return struct {
        const Self = @This();
        const Entry = struct {
            node: ?NodeId = null,
            domain: Domain = .system,
            readable: bool = false,
            writable: bool = false,
            offset: u64 = 0,
            generation: u32 = 1,
            retired: bool = false,
        };
        owner: u64,
        entries: [capacity]Entry = @splat(Entry{}),

        pub fn init(profile: Profile) !Self {
            try validateProfile(profile);
            return .{ .owner = profile.app_id };
        }

        pub fn open(self: *Self, vfs: anytype, profile: Profile, path: []const u8, flags: OpenFlags) !Descriptor {
            if (comptime capacity == 0) return error.FileTableFull;
            try self.checkProfile(profile);
            const resolved = try resolve(profile, path);
            if ((!flags.read and !flags.write) or ((flags.create or flags.truncate) and !flags.write))
                return error.InvalidOpenFlags;
            const rights = requestedRights(flags);
            try authorize(profile, resolved.domain, rights);
            if (resolved.domain == .bundle and (flags.write or flags.create or flags.truncate))
                return error.PermissionDenied;
            // Find a slot before create/truncate: table exhaustion cannot
            // leave a new file or destructively change an existing file.
            const index = self.freeSlot() orelse return error.FileTableFull;
            const node = vfs.fs.lookup(resolved.path()) catch |err| blk: {
                if (err != error.NotFound or !flags.create) return err;
                try vfs.checkParent(profile, &resolved);
                break :blk try vfs.fs.create(resolved.path(), .{ .domain = resolved.domain, .owner = profile.app_id });
            };
            const node_stat = try vfs.checkedNode(profile, resolved.domain, node);
            if (flags.write and node_stat.kind != .mutable_file) return error.PermissionDenied;
            if (flags.truncate) try vfs.fs.truncate(node, 0);
            const generation = self.entries[index].generation;
            self.entries[index] = .{
                .node = node,
                .domain = resolved.domain,
                .readable = flags.read,
                .writable = flags.write,
                .generation = generation,
            };
            return encode(index, generation);
        }

        pub fn read(self: *Self, vfs: anytype, profile: Profile, descriptor: Descriptor, output: []u8) !usize {
            const entry = try self.checkedEntry(vfs, profile, descriptor, security.handles.rights.read);
            const count_read = try vfs.fs.read(entry.node.?, entry.offset, output);
            entry.offset += @intCast(count_read);
            return count_read;
        }

        pub fn write(self: *Self, vfs: anytype, profile: Profile, descriptor: Descriptor, bytes: []const u8) !usize {
            const entry = try self.checkedEntry(vfs, profile, descriptor, security.handles.rights.write);
            const requested_end = @addWithOverflow(entry.offset, @as(u64, @intCast(bytes.len)));
            if (requested_end[1] != 0) return error.OffsetOverflow;
            const count_written = try vfs.fs.write(entry.node.?, entry.offset, bytes);
            entry.offset += @intCast(count_written);
            return count_written;
        }

        pub fn seek(self: *Self, vfs: anytype, profile: Profile, descriptor: Descriptor, offset: i64, whence: Whence) !u64 {
            const entry = try self.checkedEntry(vfs, profile, descriptor, security.handles.rights.seek);
            const base: u64 = switch (whence) {
                .start => 0,
                .current => entry.offset,
                .end => try vfs.fs.size(entry.node.?),
            };
            const next = try shiftedOffset(base, offset);
            // Successful offsets use a signed native file-position range. This
            // also keeps opaque success values out of unsigned errno space.
            if (next > std.math.maxInt(i64)) return error.OffsetOverflow;
            entry.offset = next;
            return next;
        }

        pub fn stat(self: *Self, vfs: anytype, profile: Profile, descriptor: Descriptor) !Stat {
            const entry = try self.checkedEntry(vfs, profile, descriptor, 0);
            const node_stat = try vfs.fs.stat(entry.node.?);
            return .{
                .size = node_stat.size,
                .read_only = node_stat.kind != .mutable_file,
                .executable = entry.domain == .bundle and node_stat.kind == .borrowed_file and node_stat.metadata.executable,
            };
        }

        /// A read-authorized descriptor can supply immutable bundle executable
        /// bytes without moving its ordinary I/O offset.
        pub fn execRead(self: *Self, vfs: anytype, profile: Profile, descriptor: Descriptor) ![]const u8 {
            const entry = try self.checkedEntry(vfs, profile, descriptor, security.handles.rights.read);
            if (entry.domain != .bundle) return error.PermissionDenied;
            const node_stat = try vfs.fs.stat(entry.node.?);
            if (node_stat.kind != .borrowed_file or !node_stat.metadata.executable) return error.NotExecutable;
            return vfs.fs.contents(entry.node.?);
        }

        pub fn close(self: *Self, profile: Profile, descriptor: Descriptor) !void {
            try self.checkProfile(profile);
            const index = try self.descriptorSlot(descriptor);
            self.clearSlot(index);
        }

        pub fn count(self: *const Self) usize {
            var total: usize = 0;
            for (self.entries) |entry| if (entry.node != null) {
                total += 1;
            };
            return total;
        }

        /// Trusted exit cleanup, including entries whose backing node has been
        /// invalidated. The caller releases this many per-app handle charges.
        pub fn closeAll(self: *Self) usize {
            var total: usize = 0;
            for (self.entries, 0..) |entry, index| {
                if (entry.node == null) continue;
                self.clearSlot(index);
                total += 1;
            }
            return total;
        }

        fn checkProfile(self: *const Self, profile: Profile) !void {
            try validateProfile(profile);
            if (self.owner == 0 or self.owner != profile.app_id) return error.PermissionDenied;
        }

        fn checkedEntry(self: *Self, vfs: anytype, profile: Profile, descriptor: Descriptor, required: security.handles.Rights) !*Entry {
            try self.checkProfile(profile);
            const index = try self.descriptorSlot(descriptor);
            const entry = &self.entries[index];
            if ((required & security.handles.rights.read != 0 and !entry.readable) or
                (required & security.handles.rights.write != 0 and !entry.writable))
                return error.PermissionDenied;
            try authorize(profile, entry.domain, entryRights(entry.*));
            const node_stat = try vfs.checkedNode(profile, entry.domain, entry.node.?);
            if (entry.writable and node_stat.kind != .mutable_file) return error.PermissionDenied;
            return entry;
        }

        fn freeSlot(self: *const Self) ?usize {
            for (self.entries, 0..) |entry, index| if (entry.node == null and !entry.retired) return index;
            return null;
        }

        fn descriptorSlot(self: *const Self, descriptor: Descriptor) !usize {
            if (comptime capacity == 0) return error.InvalidDescriptor;
            const bits = @backingInt(descriptor);
            if (bits & descriptor_tag == 0) return error.InvalidDescriptor;
            const slot: u32 = @truncate(bits);
            const generation: u32 = @intCast((bits >> 32) & max_generation);
            if (slot == 0 or generation == 0 or slot > capacity) return error.InvalidDescriptor;
            const index: usize = slot - 1;
            const entry = self.entries[index];
            if (entry.retired or entry.node == null or entry.generation != generation) return error.StaleDescriptor;
            return index;
        }

        fn clearSlot(self: *Self, index: usize) void {
            if (comptime capacity == 0) return;
            const generation = self.entries[index].generation;
            self.entries[index] = if (generation == max_generation)
                .{ .generation = generation, .retired = true }
            else
                .{ .generation = generation + 1 };
        }

        fn encode(index: usize, generation: u32) Descriptor {
            return @fromBackingInt(descriptor_tag | (@as(u64, generation) << 32) | @as(u64, @intCast(index + 1)));
        }

        fn entryRights(entry: Entry) security.handles.Rights {
            return security.handles.rights.seek |
                (if (entry.readable) security.handles.rights.read else @as(u64, 0)) |
                (if (entry.writable) security.handles.rights.write else @as(u64, 0));
        }
    };
}

fn validateProfile(profile: Profile) !void {
    _ = try Profile.init(profile.app_id, profile.permissions, profile.permissions);
}

fn authorize(profile: Profile, domain: Domain, rights: security.handles.Rights) !void {
    const source: security.sandbox.Source = switch (domain) {
        .bundle => .{ .app_bundle = profile.app_id },
        .container => .{ .private_container = profile.app_id },
        else => return error.PermissionDenied,
    };
    try profile.authorizeGrant(.{ .kind = .file, .object_id = 1, .rights = rights }, source);
}

fn mutableNamespace(profile: Profile, domain: Domain) !void {
    try authorize(profile, domain, security.handles.rights.write);
    if (domain != .container) return error.PermissionDenied;
}

fn resolveDirectory(profile: Profile, path: []const u8) !Resolved {
    if (!std.mem.eql(u8, path, "/container") and !std.mem.eql(u8, path, "/bundle")) return resolve(profile, path);
    try validateProfile(profile);
    var result: Resolved = .{
        .domain = if (std.mem.eql(u8, path, "/container")) .container else .bundle,
        .length = path.len + 17,
    };
    @memcpy(result.bytes[0..path.len], path);
    result.bytes[path.len] = '/';
    encodeAppId(result.bytes[path.len + 1 ..][0..16], profile.app_id);
    return result;
}

fn requestedRights(flags: OpenFlags) security.handles.Rights {
    return security.handles.rights.seek |
        (if (flags.read) security.handles.rights.read else @as(u64, 0)) |
        (if (flags.write) security.handles.rights.write else @as(u64, 0));
}

fn resolve(profile: Profile, path: []const u8) !Resolved {
    try validateProfile(profile);
    if (path.len == 0 or path[0] != '/') return error.InvalidPath;
    if (path.len > max_path) return error.PathTooLong;
    const prefix: []const u8, const domain: Domain = if (std.mem.startsWith(u8, path, "/bundle/"))
        .{ "/bundle", .bundle }
    else if (std.mem.startsWith(u8, path, "/container/"))
        .{ "/container", .container }
    else
        return error.PermissionDenied;
    var start: usize = 1;
    for (path, 0..) |byte, index| {
        if (byte == '\\' or byte < 0x20 or byte == 0x7f) return error.PermissionDenied;
        if (index == 0 or byte != '/') continue;
        try component(path[start..index]);
        start = index + 1;
    }
    try component(path[start..]);
    const relative = path[prefix.len + 1 ..];
    const length = prefix.len + 17 + 1 + relative.len;
    if (length > max_path) return error.PathTooLong;
    var resolved: Resolved = .{ .domain = domain, .length = length };
    @memcpy(resolved.bytes[0..prefix.len], prefix);
    resolved.bytes[prefix.len] = '/';
    encodeAppId(resolved.bytes[prefix.len + 1 ..][0..16], profile.app_id);
    resolved.bytes[prefix.len + 17] = '/';
    @memcpy(resolved.bytes[prefix.len + 18 .. length], relative);
    return resolved;
}

fn component(bytes: []const u8) !void {
    if (bytes.len == 0 or std.mem.eql(u8, bytes, ".") or std.mem.eql(u8, bytes, ".."))
        return error.PermissionDenied;
}

fn encodeAppId(output: []u8, app_id: u64) void {
    const digits = "0123456789abcdef";
    for (output, 0..) |*byte, index| {
        const shift: u6 = @intCast((15 - index) * 4);
        byte.* = digits[@as(usize, @intCast((app_id >> shift) & 0xf))];
    }
}

fn shiftedOffset(base: u64, delta: i64) !u64 {
    if (delta >= 0) {
        const sum = @addWithOverflow(base, @as(u64, @intCast(delta)));
        if (sum[1] != 0) return error.OffsetOverflow;
        return sum[0];
    }
    const magnitude: u64 = @as(u64, @intCast(-(delta + 1))) + 1;
    if (magnitude > base) return error.OffsetOverflow;
    return base - magnitude;
}

const TestFs = filesystem.ramfs.RamFs(32, 64, 128);
const TestVfs = Vfs(TestFs);
fn testProfile(app_id: u64) Profile {
    return Profile.init(app_id, 0, 0) catch unreachable;
}

test "virtual paths reject traversal and namespace prefix confusion before creation" {
    const t = std.testing;
    var storage: TestVfs = .{};
    try storage.reset();
    const profile = testProfile(7);
    try storage.mountContainer(profile);
    var files = try Files(8).init(profile);
    for ([_][]const u8{
        "/kernel/secret",            "/private/7/data",              "/other/data",      "/container2/file", "/bundle-private/file",
        "/container/../bundle/init", "/container/./file",            "/container//file", "/container/file/", "/container/with\\separator",
        "/container/nul\x00suffix",  "/container/control\x1fsuffix",
    }) |path| {
        try t.expectError(error.PermissionDenied, files.open(&storage, profile, path, .{ .write = true, .create = true }));
    }
    try t.expectError(error.InvalidPath, files.open(&storage, profile, "relative", .{ .read = true }));
    try t.expectEqual(@as(usize, 0), files.count());
}

test "containers and bundles resolve only in the current trusted app domain" {
    const t = std.testing;
    var storage: TestVfs = .{};
    try storage.reset();
    const alice = testProfile(7);
    const bob = testProfile(8);
    try storage.mountContainer(alice);
    try storage.mountContainer(bob);
    try storage.mountBundle(alice, "/bundle/init", "alice-code", true);
    var a = try Files(4).init(alice);
    var b = try Files(4).init(bob);
    const ad = try a.open(&storage, alice, "/container/same", .{ .read = true, .write = true, .create = true });
    const bd = try b.open(&storage, bob, "/container/same", .{ .read = true, .write = true, .create = true });
    _ = try a.write(&storage, alice, ad, "A");
    _ = try b.write(&storage, bob, bd, "B");
    _ = try a.seek(&storage, alice, ad, 0, .start);
    _ = try b.seek(&storage, bob, bd, 0, .start);
    var byte: [1]u8 = undefined;
    _ = try a.read(&storage, alice, ad, &byte);
    try t.expectEqual(@as(u8, 'A'), byte[0]);
    _ = try b.read(&storage, bob, bd, &byte);
    try t.expectEqual(@as(u8, 'B'), byte[0]);
    try t.expectError(error.PermissionDenied, a.read(&storage, bob, ad, &byte));
    try t.expectError(error.PermissionDenied, a.open(&storage, bob, "/container/missing", .{ .read = true }));
    try t.expectError(error.NotFound, storage.execPath(bob, "/bundle/init"));
    try t.expectError(error.PermissionDenied, a.close(bob, ad));
    try t.expectEqual(@as(usize, 1), a.count());
}

test "bundle mutation is denied before existence disclosure and mutable execution is denied" {
    const t = std.testing;
    var storage: TestVfs = .{};
    try storage.reset();
    const profile = testProfile(7);
    try storage.mountContainer(profile);
    try storage.mountBundle(profile, "/bundle/bin/init", "ELF", true);
    try storage.mountBundle(profile, "/bundle/note", "text", false);
    var files = try Files(8).init(profile);
    for ([_][]const u8{ "/bundle/bin/init", "/bundle/missing" }) |path|
        try t.expectError(error.PermissionDenied, files.open(&storage, profile, path, .{ .write = true, .create = true, .truncate = true }));
    try t.expectEqualStrings("ELF", try storage.execPath(profile, "/bundle/bin/init"));
    try t.expectError(error.NotExecutable, storage.execPath(profile, "/bundle/note"));
    try t.expectError(error.PermissionDenied, storage.execPath(profile, "/container/not-present"));
    const fd = try files.open(&storage, profile, "/bundle/bin/init", .{ .read = true });
    var byte: [1]u8 = undefined;
    _ = try files.read(&storage, profile, fd, &byte);
    try t.expectEqual(@as(u8, 'E'), byte[0]);
    try t.expectEqualStrings("ELF", try files.execRead(&storage, profile, fd));
    _ = try files.read(&storage, profile, fd, &byte);
    try t.expectEqual(@as(u8, 'L'), byte[0]);
    try t.expect((try files.stat(&storage, profile, fd)).read_only);
    try t.expectError(error.PermissionDenied, files.write(&storage, profile, fd, "bad"));
    const mutable = try files.open(&storage, profile, "/container/code", .{ .read = true, .write = true, .create = true });
    _ = try files.write(&storage, profile, mutable, "ELF");
    try t.expectError(error.PermissionDenied, files.execRead(&storage, profile, mutable));
}

test "read write seek EOF and sparse gaps preserve offsets on rejected operations" {
    const t = std.testing;
    var storage: TestVfs = .{};
    try storage.reset();
    const profile = testProfile(7);
    try storage.mountContainer(profile);
    var files = try Files(2).init(profile);
    const fd = try files.open(&storage, profile, "/container/data", .{ .read = true, .write = true, .create = true });
    try t.expectEqual(@as(usize, 3), try files.write(&storage, profile, fd, "abc"));
    try t.expectEqual(@as(u64, 6), try files.seek(&storage, profile, fd, 3, .end));
    _ = try files.write(&storage, profile, fd, "z");
    try t.expectEqual(@as(u64, 7), (try files.stat(&storage, profile, fd)).size);
    try t.expectError(error.OffsetOverflow, files.seek(&storage, profile, fd, -8, .current));
    try t.expectEqual(@as(u64, 7), try files.seek(&storage, profile, fd, 0, .current));
    _ = try files.seek(&storage, profile, fd, 0, .start);
    var buffer: [10]u8 = @splat(0xff);
    try t.expectEqual(@as(usize, 7), try files.read(&storage, profile, fd, &buffer));
    try t.expectEqualSlices(u8, &.{ 'a', 'b', 'c', 0, 0, 0, 'z' }, buffer[0..7]);
    try t.expectEqual(@as(u8, 0xff), buffer[7]);
    try t.expectEqual(@as(usize, 0), try files.read(&storage, profile, fd, &buffer));
    _ = try files.seek(&storage, profile, fd, 63, .start);
    try t.expectError(error.FileTooLarge, files.write(&storage, profile, fd, "xx"));
    try t.expectEqual(@as(u64, 63), try files.seek(&storage, profile, fd, 0, .current));
    try t.expectEqual(@as(u64, 7), (try files.stat(&storage, profile, fd)).size);
    const huge: i64 = std.math.maxInt(i64);
    try t.expectEqual(@as(u64, @intCast(huge)), try files.seek(&storage, profile, fd, huge, .start));
    try t.expectError(error.OffsetOverflow, files.seek(&storage, profile, fd, 1, .current));
    try t.expectError(error.OffsetOverflow, files.seek(&storage, profile, fd, huge, .current));
    try t.expectError(error.OffsetOverflow, files.seek(&storage, profile, fd, huge, .end));
    try t.expectEqual(@as(u64, @intCast(huge)), try files.seek(&storage, profile, fd, 0, .current));
    try t.expectEqual(@as(u64, 7), (try files.stat(&storage, profile, fd)).size);
    try files.close(profile, fd);
    const truncated = try files.open(&storage, profile, "/container/data", .{ .read = true, .write = true, .truncate = true });
    try t.expectEqual(@as(u64, 0), (try files.stat(&storage, profile, truncated)).size);
    try t.expectEqual(@as(u64, 0), try files.seek(&storage, profile, truncated, 0, .current));
}

test "descriptor generations close cleanup and exhausted capacity prevent mutation" {
    const t = std.testing;
    var storage: TestVfs = .{};
    try storage.reset();
    const profile = testProfile(7);
    try storage.mountContainer(profile);
    var files = try Files(1).init(profile);
    const first = try files.open(&storage, profile, "/container/existing", .{ .read = true, .write = true, .create = true });
    _ = try files.write(&storage, profile, first, "keep");
    try t.expect(@backingInt(first) & descriptor_tag != 0);
    try t.expectError(error.FileTableFull, files.open(&storage, profile, "/container/existing", .{ .write = true, .truncate = true }));
    try t.expectError(error.FileTableFull, files.open(&storage, profile, "/container/new", .{ .write = true, .create = true }));
    try t.expectEqual(@as(u64, 4), (try files.stat(&storage, profile, first)).size);
    try files.close(profile, first);
    try t.expectError(error.StaleDescriptor, files.close(profile, first));
    const second = try files.open(&storage, profile, "/container/existing", .{ .read = true });
    try t.expect(@backingInt(first) != @backingInt(second));
    try t.expectError(error.NotFound, storage.fs.lookup("/container/0000000000000007/new"));
    try t.expectEqual(@as(usize, 1), files.closeAll());
    try t.expectEqual(@as(usize, 0), files.closeAll());
    try t.expectError(error.StaleDescriptor, files.stat(&storage, profile, second));
}

test "each operation rechecks node provenance and descriptor rights" {
    const t = std.testing;
    var storage: TestVfs = .{};
    try storage.reset();
    const alice = testProfile(7);
    const bob = testProfile(8);
    try storage.mountContainer(alice);
    try storage.mountContainer(bob);
    var a = try Files(2).init(alice);
    var b = try Files(1).init(bob);
    const fd = try a.open(&storage, alice, "/container/a", .{ .read = true, .write = true, .create = true });
    _ = try b.open(&storage, bob, "/container/b", .{ .read = true, .write = true, .create = true });
    a.entries[0].node = b.entries[0].node;
    var byte: [1]u8 = undefined;
    try t.expectError(error.PermissionDenied, a.read(&storage, alice, fd, &byte));
    try t.expectError(error.PermissionDenied, a.write(&storage, alice, fd, "x"));
    try t.expectError(error.PermissionDenied, a.seek(&storage, alice, fd, 0, .start));
    try t.expectError(error.PermissionDenied, a.stat(&storage, alice, fd));
    try t.expectError(error.PermissionDenied, a.execRead(&storage, alice, fd));
    try t.expectEqual(@as(u64, 0), a.entries[0].offset);
    // Cleanup must remain possible even when a trusted backing node is stale.
    try t.expectEqual(@as(usize, 1), a.closeAll());
}

test "invalid flags malformed tokens corrupt profiles and generation retirement fail closed" {
    const t = std.testing;
    var storage: TestVfs = .{};
    try storage.reset();
    const profile = testProfile(7);
    try storage.mountContainer(profile);
    var files = try Files(1).init(profile);
    try t.expectError(error.InvalidOpenFlags, files.open(&storage, profile, "/container/a", .{}));
    try t.expectError(error.InvalidOpenFlags, files.open(&storage, profile, "/container/a", .{ .read = true, .create = true }));
    try t.expectError(error.InvalidOpenFlags, files.open(&storage, profile, "/container/a", .{ .read = true, .truncate = true }));
    try t.expectError(error.InvalidAppIdentity, Files(1).init(.{ .app_id = 0 }));
    try t.expectError(error.InvalidPermissions, Files(1).init(.{ .app_id = 7, .permissions = 1 << 31 }));
    files.entries[0].generation = max_generation;
    const fd = try files.open(&storage, profile, "/container/a", .{ .read = true, .write = true, .create = true });
    for ([_]u64{ 0, 1, 0x1_0000_0001, 1 << 62, descriptor_tag, descriptor_tag | 1, descriptor_tag | (1 << 32) | 2 }) |raw|
        try t.expectError(error.InvalidDescriptor, files.close(profile, @fromBackingInt(raw)));
    try files.close(profile, fd);
    try t.expectError(error.StaleDescriptor, files.close(profile, fd));
    try t.expectError(error.FileTableFull, files.open(&storage, profile, "/container/a", .{ .read = true }));
    var empty = try Files(0).init(profile);
    try t.expectError(error.FileTableFull, empty.open(&storage, profile, "/container/a", .{ .read = true }));
    try t.expectEqual(@as(usize, 0), empty.closeAll());
}

test "directory listing and creation stay within the current app virtual roots" {
    const t = std.testing;
    var storage: TestVfs = .{};
    try storage.reset();
    const alice = testProfile(1);
    const bob = testProfile(2);
    try storage.mountContainer(alice);
    try storage.mountContainer(bob);
    try storage.mkdir(alice, "/container/docs");
    try storage.mkdir(bob, "/container/private");
    try storage.mountBundle(alice, "/bundle/readme", "info", false);
    var cursor: usize = 0;
    const entry = (try storage.list(alice, "/container", &cursor)).?;
    try t.expectEqualStrings("docs", entry.name[0..entry.name_len]);
    try t.expect(entry.kind == .directory and !entry.read_only);
    try t.expect((try storage.list(alice, "/container", &cursor)) == null);
    cursor = 0;
    const bundled = (try storage.list(alice, "/bundle", &cursor)).?;
    try t.expectEqualStrings("readme", bundled.name[0..bundled.name_len]);
    try t.expect(bundled.kind == .file and bundled.read_only and bundled.size == 4);
    try t.expectError(error.PermissionDenied, storage.mkdir(alice, "/bundle/forbidden"));
    try t.expectError(error.PermissionDenied, storage.list(alice, "/private/2", &cursor));
    try t.expectError(error.PermissionDenied, storage.mkdir(alice, "/container/../2/escape"));
    try t.expectError(error.NotFound, storage.fs.lookup("/container/0000000000000002/docs"));
}

test "mutating paths preflight all namespace and descendant authority" {
    const t = std.testing;
    var storage: TestVfs = .{};
    try storage.reset();
    const profile = testProfile(1);
    try storage.mountContainer(profile);
    try storage.mkdir(profile, "/container/tree");
    _ = try storage.fs.create("/container/0000000000000001/tree/foreign", .{ .domain = .container, .owner = 2 });
    try t.expectError(error.PermissionDenied, storage.copy(profile, "/container/tree", "/container/copied"));
    try t.expectError(error.PermissionDenied, storage.rename(profile, "/container/tree", "/container/moved"));
    try t.expectError(error.PermissionDenied, storage.unlink(profile, "/container/tree"));
    try t.expectError(error.PermissionDenied, storage.copy(profile, "/container/missing", "/bundle/destination"));
    try t.expectError(error.PermissionDenied, storage.rename(profile, "/bundle/missing", "/container/destination"));
    try t.expectError(error.PermissionDenied, storage.unlink(profile, "/bundle/missing"));
    try t.expectError(error.NotFound, storage.fs.lookup("/container/0000000000000001/copied"));
    // A trusted malformed parent record must not authorize a new child.
    _ = try storage.fs.mkdir("/container/0000000000000001/foreign-dir", .{ .domain = .container, .owner = 2 });
    var files = try Files(2).init(profile);
    try t.expectError(error.PermissionDenied, files.open(&storage, profile, "/container/foreign-dir/new", .{ .write = true, .create = true }));
    try t.expectEqual(@as(usize, 0), files.count());
    try t.expectError(error.NotFound, storage.fs.lookup("/container/0000000000000001/foreign-dir/new"));
}

test "durable VFS mutations preserve app ownership and invalidate deleted descriptors" {
    const t = std.testing;
    const Disk = struct {
        bytes: []u8,
        fn read(context: *anyopaque, block: u64, count: u64, output: []u8) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (count * 512 != output.len) return error.InvalidTestRequest;
            const start: usize = @intCast(block * 512);
            @memcpy(output, self.bytes[start..][0..output.len]);
        }
        fn write(context: *anyopaque, block: u64, count: u64, input: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (count * 512 != input.len) return error.InvalidTestRequest;
            const start: usize = @intCast(block * 512);
            @memcpy(self.bytes[start..][0..input.len], input);
        }
        fn flush(_: *anyopaque) !void {}
        fn device(self: *@This()) filesystem.BlockDevice {
            return .{ .context = self, .read_fn = read, .write_fn = write, .flush_fn = flush, .block_size = 512, .block_count = 8192 };
        }
    };
    var disk: Disk = .{ .bytes = try t.allocator.alloc(u8, filesystem.durable.disk_bytes) };
    defer t.allocator.free(disk.bytes);
    @memset(disk.bytes, 0);
    const PersistentVfs = Vfs(filesystem.durable.DurableFs(32, 64, 128));
    var storage: PersistentVfs = .{};
    try storage.fs.format(disk.device());
    const profile = testProfile(1);
    const other = testProfile(2);
    try storage.mountContainer(profile);
    try storage.mountContainer(other);
    try storage.mountBundle(profile, "/bundle/readme", "immutable", false);
    try storage.mkdir(profile, "/container/docs");
    var files = try Files(2).init(profile);
    const original = try files.open(&storage, profile, "/container/docs/note", .{ .read = true, .write = true, .create = true });
    _ = try files.write(&storage, profile, original, "persistent");
    try storage.copy(profile, "/container/docs", "/container/copied");
    try storage.rename(profile, "/container/docs", "/container/moved");
    try t.expectEqual(@as(u64, 10), (try files.stat(&storage, profile, original)).size);
    try storage.unlink(profile, "/container/moved/note");
    var output: [16]u8 = undefined;
    try t.expectError(error.StaleNode, files.read(&storage, profile, original, &output));
    try t.expectEqual(@as(u64, 10), files.entries[0].offset);
    const reused = try files.open(&storage, profile, "/container/moved/new", .{ .read = true, .write = true, .create = true });
    try t.expectError(error.StaleNode, files.write(&storage, profile, original, "leak"));
    try t.expectEqual(@as(u64, 0), (try files.stat(&storage, profile, reused)).size);
    try t.expectError(error.PermissionDenied, storage.nullify(profile, "/bundle/readme"));
    try t.expectError(error.PermissionDenied, storage.nullify(profile, "/container/../0000000000000002/private"));
    try t.expectError(error.NotFile, storage.nullify(profile, "/container/moved"));
    _ = try files.write(&storage, profile, reused, "VFS-nullify-secret-83917");
    try storage.nullify(profile, "/container/moved/new");
    try t.expectError(error.StaleNode, files.read(&storage, profile, reused, &output));
    try t.expectError(error.NotFound, storage.fs.lookup("/container/0000000000000001/moved/new"));
    try t.expect(std.mem.indexOf(u8, disk.bytes, "VFS-nullify-secret-83917") == null);
    try files.close(profile, original);
    try files.close(profile, reused);
    var reopened: PersistentVfs = .{};
    try reopened.mount(disk.device());
    try reopened.mountContainer(profile);
    try reopened.mountContainer(other);
    try t.expectError(error.NotFound, reopened.fs.lookup("/container/0000000000000001/moved/new"));
    var fresh = try Files(2).init(profile);
    const restored = try fresh.open(&reopened, profile, "/container/copied/note", .{ .read = true });
    try t.expectEqual(@as(usize, 10), try fresh.read(&reopened, profile, restored, &output));
    try t.expectEqualStrings("persistent", output[0..10]);
    var unrelated = try Files(2).init(other);
    try t.expectError(error.NotFound, unrelated.open(&reopened, other, "/container/copied/note", .{ .read = true }));
    try t.expectError(error.NotFound, reopened.execPath(profile, "/bundle/readme"));
    try reopened.mountBundle(profile, "/bundle/readme", "immutable", true);
    try t.expectEqualStrings("immutable", try reopened.execPath(profile, "/bundle/readme"));
    try t.expectError(error.PermissionDenied, reopened.execPath(profile, "/container/copied/note"));
}

test "nullify rejects foreign metadata and leaves other app files intact" {
    const t = std.testing;
    var storage: TestVfs = .{};
    try storage.reset();
    const profile = testProfile(1);
    const other = testProfile(2);
    try storage.mountContainer(profile);
    try storage.mountContainer(other);
    try storage.mountBundle(profile, "/bundle/note", "immutable", false);
    _ = try storage.fs.create("/container/0000000000000001/foreign", .{ .domain = .container, .owner = 2 });
    try t.expectError(error.PermissionDenied, storage.nullify(profile, "/container/foreign"));
    try t.expectError(error.PermissionDenied, storage.nullify(profile, "/bundle/note"));
    try storage.mkdir(profile, "/container/folder");
    try t.expectError(error.NotFile, storage.nullify(profile, "/container/folder"));
    var mine = try Files(1).init(profile);
    var theirs = try Files(1).init(other);
    const a = try mine.open(&storage, profile, "/container/note", .{ .read = true, .write = true, .create = true });
    const b = try theirs.open(&storage, other, "/container/note", .{ .read = true, .write = true, .create = true });
    _ = try mine.write(&storage, profile, a, "remove me");
    _ = try theirs.write(&storage, other, b, "keep me");
    try storage.nullify(profile, "/container/note");
    var output: [16]u8 = undefined;
    try t.expectError(error.InvalidNode, mine.read(&storage, profile, a, &output));
    _ = try theirs.seek(&storage, other, b, 0, .start);
    try t.expectEqual(@as(usize, 7), try theirs.read(&storage, other, b, &output));
    try t.expectEqualStrings("keep me", output[0..7]);
    try t.expectError(error.NotFound, storage.fs.lookup("/container/0000000000000001/note"));
}
