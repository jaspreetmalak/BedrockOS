//! Serialized surface ownership policy. Root owns physical allocations and PTE
//! updates; every *Mapped/*Unmapped call confirms a completed root operation.
//! The registry never maps memory, touches pixels or accepts user-supplied IDs
//! as authority. Resolve a task-local surface handle before entering this API.
const std = @import("std");
pub const Identity = struct {
    pid: u64,
    app_id: u64,
    pub fn valid(self: Identity) bool {
        return self.pid != 0 and self.app_id != 0;
    }
    pub fn eql(self: Identity, other: Identity) bool {
        return self.pid == other.pid and self.app_id == other.app_id;
    }
};
pub const Backing = struct { base: u64, pages: u16 };
pub const Geometry = struct {
    width: u32,
    height: u32,
    pub fn stride(self: Geometry) !u32 {
        try self.validate();
        return std.math.mul(u32, self.width, 4) catch error.SurfaceTooLarge;
    }
    pub fn bytes(self: Geometry) !u64 {
        return std.math.mul(u64, try self.stride(), self.height) catch error.SurfaceTooLarge;
    }
    pub fn pages(self: Geometry) !u16 {
        const size = try self.bytes();
        if (size > 4 * 1024 * 1024) return error.SurfaceTooLarge;
        return @intCast((size + 4095) / 4096);
    }
    pub fn validate(self: Geometry) !void {
        if (self.width == 0 or self.height == 0 or self.width > 1280 or self.height > 800) return error.InvalidGeometry;
    }
};
pub const Mapping = struct { backing: Backing, writable: bool, width: u32, height: u32 };
pub const State = enum { idle, writer_reserved, writing, writer_ready, submitted, reader_reserved, reading };
pub const ReadGrant = struct { object: u64, rights: u64 = 1, owner: Identity, consumer: Identity };
pub const Snapshot = struct {
    owner: Identity,
    consumer: Identity,
    owner_alive: bool,
    state: State,
    submitted: bool,
    read_refs: u32,
    backing: Backing,
    geometry: Geometry,
};

pub fn Registry(comptime capacity: usize) type {
    return GenerationRegistry(capacity, std.math.maxInt(u32));
}
pub fn GenerationRegistry(comptime capacity: usize, comptime last_generation: u32) type {
    if (capacity > std.math.maxInt(u32) or last_generation == 0) @compileError("Invalid surface registry bounds");
    return struct {
        const Self = @This();
        const Entry = struct {
            generation: u32 = 1,
            live: bool = false,
            retired: bool = false,
            owner: Identity = .{ .pid = 0, .app_id = 0 },
            consumer: Identity = .{ .pid = 0, .app_id = 0 },
            owner_alive: bool = false,
            state: State = .idle,
            read_refs: u32 = 0,
            backing: Backing = .{ .base = 0, .pages = 0 },
            geometry: Geometry = .{ .width = 0, .height = 0 },
        };
        entries: [capacity]Entry = @splat(.{}),

        pub fn create(self: *Self, owner: Identity, consumer: Identity, geometry: Geometry, backing: Backing) !u64 {
            if (!owner.valid() or !consumer.valid() or (owner.pid == consumer.pid and owner.app_id != consumer.app_id)) return error.InvalidSurfaceIdentity;
            const pages = try geometry.pages();
            if (backing.base == 0 or backing.base % 4096 != 0 or backing.pages != pages or backing.pages > 1024) return error.InvalidSurfaceBacking;
            const limit = try std.math.add(u64, backing.base, @as(u64, backing.pages) * 4096);
            for (self.entries) |entry| if (entry.live and backing.base < entry.backing.base + @as(u64, entry.backing.pages) * 4096 and entry.backing.base < limit)
                return error.SurfaceBackingOverlap;
            for (&self.entries, 0..) |*entry, index| {
                if (entry.live or entry.retired) continue;
                entry.live = true;
                entry.owner = owner;
                entry.consumer = consumer;
                entry.owner_alive = true;
                entry.state = .idle;
                entry.read_refs = 0;
                entry.backing = backing;
                entry.geometry = geometry;
                return encode(index, entry.generation);
            }
            return error.SurfaceCapacity;
        }
        fn encode(index: usize, generation: u32) u64 {
            return (@as(u64, generation) << 32) | (index + 1);
        }
        fn resolve(self: *Self, id: u64) !*Entry {
            const slot: u32 = @truncate(id);
            const generation: u32 = @truncate(id >> 32);
            if (slot == 0 or slot > capacity or generation == 0 or generation > last_generation) return error.InvalidSurface;
            if (comptime capacity == 0) return error.InvalidSurface;
            const entry = &self.entries[slot - 1];
            if (!entry.live or entry.retired or entry.generation != generation) return error.StaleSurface;
            return entry;
        }
        fn owned(entry: *const Entry, owner: Identity) !void {
            if (!entry.owner.eql(owner)) return error.PermissionDenied;
            if (!entry.owner_alive) return error.SurfaceOwnerExited;
        }
        fn consumed(entry: *const Entry, consumer: Identity) !void {
            if (!entry.consumer.eql(consumer)) return error.PermissionDenied;
        }
        fn mapping(entry: *const Entry, writable: bool) Mapping {
            return .{ .backing = entry.backing, .writable = writable, .width = entry.geometry.width, .height = entry.geometry.height };
        }
        pub fn get(self: *Self, id: u64) !Snapshot {
            const entry = try self.resolve(id);
            return .{ .owner = entry.owner, .consumer = entry.consumer, .owner_alive = entry.owner_alive, .state = entry.state, .submitted = entry.state == .submitted or entry.state == .reader_reserved or entry.state == .reading, .read_refs = entry.read_refs, .backing = entry.backing, .geometry = entry.geometry };
        }
        pub fn objectAt(self: *const Self, index: usize) ?u64 {
            if (index >= capacity or !self.entries[index].live) return null;
            return encode(index, self.entries[index].generation);
        }
        pub fn backingFor(self: *Self, id: u64, caller: Identity) !Backing {
            const entry = try self.resolve(id);
            if (entry.owner.eql(caller)) {
                try owned(entry, caller);
            } else {
                try consumed(entry, caller);
                if (entry.read_refs == 0) return error.PermissionDenied;
            }
            return entry.backing;
        }
        /// Reserves mapping intent before root changes an inactive address space.
        pub fn acquireWriter(self: *Self, id: u64, owner: Identity) !Mapping {
            const entry = try self.resolve(id);
            try owned(entry, owner);
            if ((entry.state != .idle and entry.state != .writer_ready) or entry.read_refs != 0) return error.SurfaceBusy;
            entry.state = .writer_reserved;
            return mapping(entry, true);
        }
        pub fn writerMapped(self: *Self, id: u64, owner: Identity) !void {
            const entry = try self.resolve(id);
            try owned(entry, owner);
            if (entry.state != .writer_reserved) return error.InvalidSurfaceTransition;
            entry.state = .writing;
        }
        pub fn cancelWriter(self: *Self, id: u64, owner: Identity) !void {
            const entry = try self.resolve(id);
            try owned(entry, owner);
            if (entry.state != .writer_reserved) return error.InvalidSurfaceTransition;
            entry.state = .idle;
        }
        /// Root has revoked every producer RW alias and invalidated its TLB.
        pub fn writerUnmapped(self: *Self, id: u64, owner: Identity) !void {
            const entry = try self.resolve(id);
            try owned(entry, owner);
            if (entry.state != .writing) return error.InvalidSurfaceTransition;
            entry.state = .writer_ready;
        }
        pub fn submit(self: *Self, id: u64, owner: Identity) !void {
            const entry = try self.resolve(id);
            try owned(entry, owner);
            if (entry.state != .writer_ready or entry.read_refs != 0) return error.InvalidSurfaceTransition;
            entry.state = .submitted;
        }
        /// Queue capacity is checked first by root. Unexpected enqueue failure
        /// can undo submission only before any read authority escapes.
        pub fn cancelSubmit(self: *Self, id: u64, owner: Identity) !void {
            const entry = try self.resolve(id);
            try owned(entry, owner);
            if (entry.state != .submitted or entry.read_refs != 0) return error.SurfaceBusy;
            entry.state = .writer_ready;
        }
        pub fn retainRead(self: *Self, id: u64, owner: Identity, consumer: Identity) !ReadGrant {
            const entry = try self.resolve(id);
            try owned(entry, owner);
            try consumed(entry, consumer);
            if (entry.state != .submitted) return error.SurfaceNotSubmitted;
            if (entry.read_refs == 64) return error.SurfaceReferenceCapacity;
            entry.read_refs += 1;
            return .{ .object = id, .owner = entry.owner, .consumer = entry.consumer };
        }
        pub fn acquireReader(self: *Self, id: u64, consumer: Identity) !Mapping {
            const entry = try self.resolve(id);
            try consumed(entry, consumer);
            if (entry.state != .submitted or entry.read_refs == 0) return error.SurfaceNotSubmitted;
            entry.state = .reader_reserved;
            return mapping(entry, false);
        }
        pub fn readerMapped(self: *Self, id: u64, consumer: Identity) !void {
            const entry = try self.resolve(id);
            try consumed(entry, consumer);
            if (entry.state != .reader_reserved) return error.InvalidSurfaceTransition;
            entry.state = .reading;
        }
        pub fn cancelReader(self: *Self, id: u64, consumer: Identity) !void {
            const entry = try self.resolve(id);
            try consumed(entry, consumer);
            if (entry.state != .reader_reserved) return error.InvalidSurfaceTransition;
            entry.state = .submitted;
        }
        /// Root has revoked the consumer RO alias; consumes that mapping's grant.
        pub fn releaseReader(self: *Self, id: u64, consumer: Identity) !void {
            const entry = try self.resolve(id);
            try consumed(entry, consumer);
            if (entry.state != .reading or entry.read_refs == 0) return error.InvalidSurfaceTransition;
            entry.state = .submitted;
            entry.read_refs -= 1;
            if (entry.read_refs == 0) entry.state = .idle;
        }
        /// Discard a queued/handle reference. A mapped reader must retain one
        /// reference until root revokes its alias with releaseReader.
        pub fn releaseRead(self: *Self, id: u64, consumer: Identity) !void {
            const entry = try self.resolve(id);
            try consumed(entry, consumer);
            if (entry.read_refs == 0) return error.SurfaceReferenceUnderflow;
            if (entry.read_refs == 1 and (entry.state == .reading or entry.state == .reader_reserved)) return error.SurfaceMappingActive;
            entry.read_refs -= 1;
            if (entry.read_refs == 0) entry.state = .idle;
        }
        /// Producer exit does not invalidate an already transferred snapshot.
        /// Root first cancels/revokes producer mappings. The last remaining
        /// snapshot grant keeps its allocation retained until collect succeeds.
        pub fn dropOwner(self: *Self, id: u64, owner: Identity) !?Backing {
            const entry = try self.resolve(id);
            if (!entry.owner.eql(owner)) return error.PermissionDenied;
            if (entry.state == .writing or entry.state == .writer_reserved) return error.SurfaceMappingActive;
            entry.owner_alive = false;
            if (entry.state == .writer_ready) entry.state = .idle;
            return self.collect(id);
        }
        pub fn collect(self: *Self, id: u64) !?Backing {
            const entry = try self.resolve(id);
            if (entry.owner_alive) return error.SurfaceOwnerAlive;
            if (entry.read_refs != 0 or entry.state == .writing or entry.state == .writer_reserved or entry.state == .reading or entry.state == .reader_reserved) return null;
            const backing = entry.backing;
            const generation = entry.generation;
            entry.* = .{ .generation = generation, .retired = generation == last_generation };
            if (!entry.retired) entry.generation += 1;
            return backing;
        }
        pub fn liveCount(self: *const Self) usize {
            var count: usize = 0;
            for (self.entries) |entry| count += @intFromBool(entry.live);
            return count;
        }
    };
}

const producer: Identity = .{ .pid = 0x100000001, .app_id = 102 };
const renderer: Identity = .{ .pid = 0x100000002, .app_id = 104 };
const foreign: Identity = .{ .pid = 0x100000003, .app_id = 102 };
fn fixture(registry: anytype) !u64 {
    return registry.create(producer, renderer, .{ .width = 32, .height = 32 }, .{ .base = 0x100000, .pages = 1 });
}
fn publish(registry: anytype, id: u64) !ReadGrant {
    _ = try registry.acquireWriter(id, producer);
    try registry.writerMapped(id, producer);
    try registry.writerUnmapped(id, producer);
    try registry.submit(id, producer);
    return registry.retainRead(id, producer, renderer);
}
test "snapshot permissions require producer revocation before publication and reader revocation before reuse" {
    var registry: Registry(4) = .{};
    const id = try fixture(&registry);
    const writer = try registry.acquireWriter(id, producer);
    try std.testing.expect(writer.writable);
    try std.testing.expectError(error.InvalidSurfaceTransition, registry.submit(id, producer));
    try registry.writerMapped(id, producer);
    try std.testing.expectError(error.InvalidSurfaceTransition, registry.submit(id, producer));
    try registry.writerUnmapped(id, producer);
    try registry.submit(id, producer);
    const grant = try registry.retainRead(id, producer, renderer);
    try std.testing.expectEqual(@as(u64, 1), grant.rights);
    const reader = try registry.acquireReader(id, renderer);
    try std.testing.expect(!reader.writable);
    try registry.readerMapped(id, renderer);
    try std.testing.expectError(error.SurfaceMappingActive, registry.releaseRead(id, renderer));
    try std.testing.expectError(error.SurfaceBusy, registry.acquireWriter(id, producer));
    try registry.releaseReader(id, renderer);
    _ = try registry.acquireWriter(id, producer);
}
test "foreign PID same app and foreign app same PID never authorize surface access" {
    var registry: Registry(1) = .{};
    const id = try fixture(&registry);
    try std.testing.expectError(error.PermissionDenied, registry.acquireWriter(id, foreign));
    try std.testing.expectError(error.PermissionDenied, registry.backingFor(id, foreign));
    try std.testing.expectError(error.PermissionDenied, registry.acquireWriter(id, .{ .pid = producer.pid, .app_id = 103 }));
    try std.testing.expectError(error.PermissionDenied, registry.backingFor(id, renderer));
    _ = try publish(&registry, id);
    try std.testing.expectError(error.PermissionDenied, registry.acquireReader(id, foreign));
    try std.testing.expectError(error.PermissionDenied, registry.retainRead(id, producer, foreign));
    try std.testing.expectError(error.PermissionDenied, registry.dropOwner(id, foreign));
}
test "producer crash retains submitted buffers until the consumer releases every snapshot reference" {
    var registry: Registry(1) = .{};
    const id = try fixture(&registry);
    _ = try publish(&registry, id);
    _ = try registry.retainRead(id, producer, renderer);
    try std.testing.expect(try registry.dropOwner(id, producer) == null);
    try std.testing.expectError(error.SurfaceOwnerExited, registry.acquireWriter(id, producer));
    _ = try registry.acquireReader(id, renderer);
    try registry.readerMapped(id, renderer);
    try registry.releaseRead(id, renderer);
    try std.testing.expect(try registry.collect(id) == null);
    try registry.releaseReader(id, renderer);
    const freed = (try registry.collect(id)).?;
    try std.testing.expectEqual(@as(u64, 0x100000), freed.base);
    try std.testing.expectEqual(@as(usize, 0), registry.liveCount());
    try std.testing.expectError(error.StaleSurface, registry.collect(id));
    const new_id = try fixture(&registry);
    try std.testing.expect(new_id != id);
    try std.testing.expectError(error.StaleSurface, registry.get(id));
}
test "mapping failure and unexpected queue failure roll back without granting read or freeing live backing" {
    var registry: Registry(1) = .{};
    const id = try fixture(&registry);
    _ = try registry.acquireWriter(id, producer);
    try std.testing.expectError(error.SurfaceMappingActive, registry.dropOwner(id, producer));
    try registry.cancelWriter(id, producer);
    try std.testing.expectError(error.SurfaceOwnerAlive, registry.collect(id));
    _ = try registry.acquireWriter(id, producer);
    try registry.writerMapped(id, producer);
    try registry.writerUnmapped(id, producer);
    try registry.submit(id, producer);
    try registry.cancelSubmit(id, producer);
    try registry.submit(id, producer);
    _ = try registry.retainRead(id, producer, renderer);
    try std.testing.expectError(error.SurfaceBusy, registry.cancelSubmit(id, producer));
    _ = try registry.acquireReader(id, renderer);
    try registry.cancelReader(id, renderer);
    try registry.releaseRead(id, renderer);
    _ = (try registry.dropOwner(id, producer)).?;
}
test "geometry backing overlap capacity and generation exhaustion fail without slot revival" {
    for ([_]Geometry{ .{ .width = 0, .height = 1 }, .{ .width = 1281, .height = 1 }, .{ .width = 1, .height = 801 }, .{ .width = std.math.maxInt(u32), .height = std.math.maxInt(u32) } }) |geometry|
        try std.testing.expectError(error.InvalidGeometry, geometry.pages());
    try std.testing.expectEqual(@as(u16, 1000), try (Geometry{ .width = 1280, .height = 800 }).pages());
    var registry: GenerationRegistry(1, 2) = .{};
    try std.testing.expectError(error.InvalidSurfaceBacking, registry.create(producer, renderer, .{ .width = 32, .height = 32 }, .{ .base = 0x100001, .pages = 1 }));
    const first = try fixture(&registry);
    try std.testing.expectError(error.SurfaceBackingOverlap, fixture(&registry));
    _ = (try registry.dropOwner(first, producer)).?;
    const last = try fixture(&registry);
    try std.testing.expectError(error.StaleSurface, registry.acquireWriter(first, producer));
    _ = (try registry.dropOwner(last, producer)).?;
    try std.testing.expectError(error.SurfaceCapacity, fixture(&registry));
}
test "trusted service can own a private background surface while conflicting app provenance is rejected" {
    var registry: Registry(1) = .{};
    const geometry: Geometry = .{ .width = 32, .height = 32 };
    const backing: Backing = .{ .base = 0x100000, .pages = 1 };
    try std.testing.expectError(error.InvalidSurfaceIdentity, registry.create(renderer, .{ .pid = renderer.pid, .app_id = 103 }, geometry, backing));
    const id = try registry.create(renderer, renderer, geometry, backing);
    _ = try registry.acquireWriter(id, renderer);
    try registry.writerMapped(id, renderer);
    try std.testing.expectEqual(backing.base, (try registry.backingFor(id, renderer)).base);
    try std.testing.expectError(error.SurfaceMappingActive, registry.dropOwner(id, renderer));
    try registry.writerUnmapped(id, renderer);
    try std.testing.expectEqual(backing.base, (try registry.dropOwner(id, renderer)).?.base);
}
