//! Bounded named service connections with trusted peer provenance. Root selects
//! service roles, resolves task-local handles, and serializes all operations.
//! Surface attachment references are already retained by root; queue removal
//! returns each reference exactly once for root to release after PTE revocation.
const std = @import("std");
const surface = @import("surface.zig");
pub const Identity = surface.Identity;
pub const ReadAttachment = surface.ReadGrant;
pub const display_service: u64 = 1;
pub const payload_capacity = 64;
pub const endpoint_tag: u64 = 1 << 63;
pub fn isEndpoint(id: u64) bool {
    return id & endpoint_tag != 0;
}
pub const Message = struct {
    connection: u64 = 0,
    sender: Identity = .{ .pid = 0, .app_id = 0 },
    payload: [payload_capacity]u8 = @splat(0),
    length: u8 = 0,
    attachment: ?ReadAttachment = null,
    closed: bool = false,
    pub fn bytes(self: *const Message) []const u8 {
        return self.payload[0..self.length];
    }
};
pub const Peer = struct { client: Identity, service: Identity, endpoint: u64 };

fn Queue(comptime capacity: usize) type {
    return struct {
        const Self = @This();
        head: usize = 0,
        count: usize = 0,
        messages: [capacity]Message = @splat(.{}),
        fn push(self: *Self, message: Message) !void {
            if (self.count == capacity) return error.WouldBlock;
            self.messages[(self.head + self.count) % capacity] = message;
            self.count += 1;
        }
        fn peek(self: *const Self) ?Message {
            if (self.count == 0) return null;
            return self.messages[self.head];
        }
        fn pop(self: *Self) ?Message {
            const message = self.peek() orelse return null;
            self.messages[self.head] = .{};
            self.head = (self.head + 1) % capacity;
            self.count -= 1;
            return message;
        }
        fn discard(self: *Self, delta: anytype) void {
            while (self.pop()) |message| recordDrop(delta, message);
        }
        fn remove(self: *Self, connection: u64, delta: anytype) void {
            const count = self.count;
            for (0..count) |_| {
                const message = self.pop().?;
                if (message.connection == connection) recordDrop(delta, message) else self.push(message) catch unreachable;
            }
        }
    };
}
fn recordDrop(delta: anytype, message: Message) void {
    delta.messages += 1;
    delta.bytes += message.length;
    if (message.attachment) |attachment| {
        // Only the bounded request queue holds attachments.
        std.debug.assert(delta.count < delta.dropped.len);
        delta.dropped[delta.count] = attachment;
        delta.count += 1;
    }
}

pub fn Registry(comptime endpoint_capacity: usize, comptime connection_capacity: usize, comptime queue_capacity: usize) type {
    return GenerationRegistry(endpoint_capacity, connection_capacity, queue_capacity, 0x7fff_ffff);
}
pub fn GenerationRegistry(comptime endpoint_capacity: usize, comptime connection_capacity: usize, comptime queue_capacity: usize, comptime last_generation: u32) type {
    if (endpoint_capacity == 0 or connection_capacity == 0 or queue_capacity == 0 or endpoint_capacity > std.math.maxInt(u32) or connection_capacity > std.math.maxInt(u32) or last_generation == 0 or last_generation > 0x7fff_ffff)
        @compileError("Service registry requires positive bounded capacities and generations");
    return struct {
        const Self = @This();
        const Endpoint = struct {
            generation: u32 = 1,
            live: bool = false,
            retired: bool = false,
            name: u64 = 0,
            owner: Identity = .{ .pid = 0, .app_id = 0 },
            requests: Queue(queue_capacity) = .{},
            closures: Queue(connection_capacity) = .{},
        };
        const Connection = struct {
            generation: u32 = 1,
            live: bool = false,
            retired: bool = false,
            endpoint: u64 = 0,
            owner: Identity = .{ .pid = 0, .app_id = 0 },
            replies: Queue(queue_capacity) = .{},
        };
        pub const Closed = struct {
            dropped: [queue_capacity]ReadAttachment = undefined,
            count: usize = 0,
            messages: usize = 0,
            bytes: usize = 0,
            serviceIdentity: Identity = .{ .pid = 0, .app_id = 0 },
            clientIdentity: Identity = .{ .pid = 0, .app_id = 0 },
            connection: u64 = 0,
        };
        endpoints: [endpoint_capacity]Endpoint = @splat(.{}),
        connections: [connection_capacity]Connection = @splat(.{}),

        fn encode(index: usize, generation: u32) u64 {
            return (@as(u64, generation) << 32) | (index + 1);
        }
        fn endpoint(self: *Self, id: u64) !*Endpoint {
            if (!isEndpoint(id)) return error.WrongServiceObjectKind;
            const slot: u32 = @truncate(id);
            const generation: u32 = @truncate((id & ~endpoint_tag) >> 32);
            if (slot == 0 or slot > endpoint_capacity or generation == 0 or generation > last_generation) return error.InvalidService;
            const entry = &self.endpoints[slot - 1];
            if (!entry.live or entry.retired or entry.generation != generation) return error.ServiceClosed;
            return entry;
        }
        fn connection(self: *Self, id: u64) !*Connection {
            if (isEndpoint(id)) return error.WrongServiceObjectKind;
            const slot: u32 = @truncate(id);
            const generation: u32 = @truncate(id >> 32);
            if (slot == 0 or slot > connection_capacity or generation == 0 or generation > last_generation) return error.InvalidConnection;
            const entry = &self.connections[slot - 1];
            if (!entry.live or entry.retired or entry.generation != generation) return error.ConnectionClosed;
            return entry;
        }
        fn authorize(actual: Identity, caller: Identity) !void {
            if (!actual.eql(caller)) return error.PermissionDenied;
        }
        /// Root checks the trusted installed role before this call. Applications
        /// cannot select an owner identity or register an arbitrary named service.
        pub fn open(self: *Self, name: u64, owner: Identity) !u64 {
            if (name != display_service) return error.InvalidServiceName;
            if (!owner.valid()) return error.InvalidServiceIdentity;
            for (self.endpoints) |entry| if (entry.live and entry.name == name) return error.ServiceAlreadyRegistered;
            for (&self.endpoints, 0..) |*entry, index| {
                if (entry.live or entry.retired) continue;
                entry.live = true;
                entry.name = name;
                entry.owner = owner;
                entry.requests = .{};
                entry.closures = .{};
                return endpoint_tag | encode(index, entry.generation);
            }
            return error.ServiceCapacity;
        }
        pub fn endpointAt(self: *const Self, index: usize) ?u64 {
            if (index >= endpoint_capacity or !self.endpoints[index].live) return null;
            return endpoint_tag | encode(index, self.endpoints[index].generation);
        }
        pub fn connectionAt(self: *const Self, index: usize) ?u64 {
            if (index >= connection_capacity or !self.connections[index].live) return null;
            return encode(index, self.connections[index].generation);
        }
        pub fn serviceOwner(self: *Self, id: u64) !Identity {
            return (try self.endpoint(id)).owner;
        }
        pub fn getConnection(self: *Self, id: u64) !Peer {
            const entry = try self.connection(id);
            return .{ .client = entry.owner, .service = (try self.endpoint(entry.endpoint)).owner, .endpoint = entry.endpoint };
        }
        pub fn findService(self: *Self, name: u64) !u64 {
            if (name != display_service) return error.InvalidServiceName;
            for (self.endpoints, 0..) |entry, index| if (entry.live and entry.name == name) return endpoint_tag | encode(index, entry.generation);
            return error.ServiceUnavailable;
        }
        pub fn connect(self: *Self, name: u64, owner: Identity) !u64 {
            if (!owner.valid()) return error.InvalidClientIdentity;
            const service = try self.findService(name);
            const target = try self.endpoint(service);
            var live_for_endpoint: usize = 0;
            for (self.connections) |entry| if (entry.live and entry.endpoint == service) {
                live_for_endpoint += 1;
            };
            // Reserve a close-notification slot for every live connection. This
            // guarantees closure remains possible when ordinary queues are full.
            if (target.closures.count + live_for_endpoint == connection_capacity) return error.WouldBlock;
            for (&self.connections, 0..) |*entry, index| {
                if (entry.live or entry.retired) continue;
                entry.live = true;
                entry.endpoint = service;
                entry.owner = owner;
                entry.replies = .{};
                return encode(index, entry.generation);
            }
            return error.ConnectionCapacity;
        }
        pub fn canSendClient(self: *Self, id: u64, caller: Identity) !bool {
            const entry = try self.connection(id);
            try authorize(entry.owner, caller);
            return (try self.endpoint(entry.endpoint)).requests.count < queue_capacity;
        }
        pub fn sendClient(self: *Self, id: u64, caller: Identity, bytes: []const u8, attachment: ?ReadAttachment) !void {
            const entry = try self.connection(id);
            try authorize(entry.owner, caller);
            const target = try self.endpoint(entry.endpoint);
            if (bytes.len > payload_capacity) return error.MessageTooLarge;
            if (attachment) |item| {
                if (item.object == 0 or item.rights != 1 or !item.owner.eql(entry.owner) or !item.consumer.eql(target.owner)) return error.InvalidSurfaceAttachment;
            }
            var message: Message = .{ .connection = id, .sender = entry.owner, .length = @intCast(bytes.len), .attachment = attachment };
            @memcpy(message.payload[0..bytes.len], bytes);
            try target.requests.push(message);
        }
        pub fn peekService(self: *Self, id: u64, caller: Identity) !?Message {
            const entry = try self.endpoint(id);
            try authorize(entry.owner, caller);
            return entry.closures.peek() orelse entry.requests.peek();
        }
        /// Root preflights copyout/handle capacity before consuming. An attachment
        /// reference moves from this queue to the service's task-local handle.
        pub fn receiveService(self: *Self, id: u64, caller: Identity) !?Message {
            const entry = try self.endpoint(id);
            try authorize(entry.owner, caller);
            return entry.closures.pop() orelse entry.requests.pop();
        }
        pub fn sendReply(self: *Self, id: u64, caller: Identity, peer: u64, bytes: []const u8) !void {
            const source = try self.endpoint(id);
            try authorize(source.owner, caller);
            const target = try self.connection(peer);
            if (target.endpoint != id) return error.PermissionDenied;
            if (bytes.len > payload_capacity) return error.MessageTooLarge;
            var message: Message = .{ .connection = peer, .sender = source.owner, .length = @intCast(bytes.len) };
            @memcpy(message.payload[0..bytes.len], bytes);
            try target.replies.push(message);
        }
        pub fn peekClient(self: *Self, id: u64, caller: Identity) !?Message {
            const entry = try self.connection(id);
            try authorize(entry.owner, caller);
            _ = try self.endpoint(entry.endpoint);
            return entry.replies.peek();
        }
        pub fn receiveClient(self: *Self, id: u64, caller: Identity) !?Message {
            const entry = try self.connection(id);
            try authorize(entry.owner, caller);
            _ = try self.endpoint(entry.endpoint);
            return entry.replies.pop();
        }
        pub fn closeClient(self: *Self, id: u64, caller: Identity) !Closed {
            const entry = try self.connection(id);
            try authorize(entry.owner, caller);
            const target = try self.endpoint(entry.endpoint);
            var closed: Closed = .{ .connection = id, .clientIdentity = entry.owner, .serviceIdentity = target.owner };
            target.requests.remove(id, &closed);
            entry.replies.discard(&closed);
            // connect reserved this separate queue slot. No ordinary request
            // backpressure can prevent peer closure or invalidate its provenance.
            target.closures.push(.{ .connection = id, .sender = entry.owner, .closed = true }) catch unreachable;
            recycleConnection(entry);
            return closed;
        }
        pub fn closeService(self: *Self, id: u64, caller: Identity) !Closed {
            const entry = try self.endpoint(id);
            try authorize(entry.owner, caller);
            var closed: Closed = .{ .serviceIdentity = entry.owner };
            entry.requests.discard(&closed);
            entry.closures.discard(&closed);
            for (&self.connections) |*peer| {
                if (!peer.live or peer.endpoint != id) continue;
                peer.replies.discard(&closed);
                recycleConnection(peer);
            }
            const generation = entry.generation;
            entry.* = .{ .generation = generation, .retired = generation == last_generation };
            if (!entry.retired) entry.generation += 1;
            return closed;
        }
        fn recycleConnection(entry: *Connection) void {
            const generation = entry.generation;
            entry.* = .{ .generation = generation, .retired = generation == last_generation };
            if (!entry.retired) entry.generation += 1;
        }
        pub fn endpointCount(self: *const Self) usize {
            var count: usize = 0;
            for (self.endpoints) |entry| count += @intFromBool(entry.live);
            return count;
        }
        pub fn connectionCount(self: *const Self) usize {
            var count: usize = 0;
            for (self.connections) |entry| count += @intFromBool(entry.live);
            return count;
        }
        pub fn liveCount(self: *const Self) usize {
            return self.endpointCount() + self.connectionCount();
        }
        pub fn queuedCount(self: *const Self) usize {
            var count: usize = 0;
            for (self.endpoints) |entry| count += entry.requests.count + entry.closures.count;
            for (self.connections) |entry| count += entry.replies.count;
            return count;
        }
    };
}

const server: Identity = .{ .pid = 0x100000001, .app_id = 104 };
const alice: Identity = .{ .pid = 0x100000002, .app_id = 102 };
const bob: Identity = .{ .pid = 0x100000003, .app_id = 103 };
fn grant(object: u64, owner: Identity) ReadAttachment {
    return .{ .object = object, .owner = owner, .consumer = server };
}
test "service queues copy metadata and authenticate both peer identities" {
    var registry: Registry(2, 4, 16) = .{};
    const endpoint = try registry.open(display_service, server);
    const client = try registry.connect(display_service, alice);
    var payload = [_]u8{ 1, 2, 3 };
    try registry.sendClient(client, alice, &payload, grant(99, alice));
    @memset(&payload, 7);
    const peek = (try registry.peekService(endpoint, server)).?;
    try std.testing.expect(peek.sender.eql(alice) and peek.connection == client and !peek.closed);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, peek.bytes());
    const received = (try registry.receiveService(endpoint, server)).?;
    try std.testing.expectEqual(@as(u64, 99), received.attachment.?.object);
    try std.testing.expect(try registry.peekService(endpoint, server) == null);
    try registry.sendReply(endpoint, server, client, "ack");
    const reply = (try registry.receiveClient(client, alice)).?;
    try std.testing.expect(reply.sender.eql(server) and reply.attachment == null);
    try std.testing.expectEqualStrings("ack", reply.bytes());
}
test "foreign client or service and widened surface attachments are rejected without enqueue" {
    var registry: Registry(2, 4, 2) = .{};
    const endpoint = try registry.open(display_service, server);
    const client = try registry.connect(display_service, alice);
    try std.testing.expectError(error.PermissionDenied, registry.sendClient(client, bob, "x", null));
    try std.testing.expectError(error.PermissionDenied, registry.receiveClient(client, bob));
    try std.testing.expectError(error.PermissionDenied, registry.receiveService(endpoint, alice));
    try std.testing.expectError(error.PermissionDenied, registry.closeClient(client, bob));
    try std.testing.expectError(error.PermissionDenied, registry.closeService(endpoint, alice));
    var attachment = grant(1, alice);
    attachment.rights = 3;
    try std.testing.expectError(error.InvalidSurfaceAttachment, registry.sendClient(client, alice, "x", attachment));
    attachment = grant(1, bob);
    try std.testing.expectError(error.InvalidSurfaceAttachment, registry.sendClient(client, alice, "x", attachment));
    attachment = grant(1, alice);
    attachment.consumer = bob;
    try std.testing.expectError(error.InvalidSurfaceAttachment, registry.sendClient(client, alice, "x", attachment));
    try std.testing.expectEqual(@as(usize, 0), registry.queuedCount());
}
test "queue backpressure preserves FIFO and receive peek retains messages until copyout is ready" {
    var registry: Registry(2, 4, 2) = .{};
    const endpoint = try registry.open(display_service, server);
    const client = try registry.connect(display_service, alice);
    try registry.sendClient(client, alice, "one", null);
    try registry.sendClient(client, alice, "two", null);
    try std.testing.expect(!try registry.canSendClient(client, alice));
    try std.testing.expectError(error.WouldBlock, registry.sendClient(client, alice, "three", null));
    try std.testing.expectEqualStrings("one", (try registry.peekService(endpoint, server)).?.bytes());
    try std.testing.expectEqualStrings("one", (try registry.receiveService(endpoint, server)).?.bytes());
    try registry.sendClient(client, alice, "three", null);
    try std.testing.expectEqualStrings("two", (try registry.receiveService(endpoint, server)).?.bytes());
    try std.testing.expectEqualStrings("three", (try registry.receiveService(endpoint, server)).?.bytes());
    try registry.sendReply(endpoint, server, client, "one");
    try registry.sendReply(endpoint, server, client, "two");
    try std.testing.expectError(error.WouldBlock, registry.sendReply(endpoint, server, client, "three"));
    try std.testing.expectEqual(@as(usize, 2), registry.queuedCount());
}
test "closing a client drops only its queued read grants and delivers closure even while another client fills the queue" {
    var registry: Registry(2, 4, 2) = .{};
    const endpoint = try registry.open(display_service, server);
    const first = try registry.connect(display_service, alice);
    const second = try registry.connect(display_service, bob);
    try registry.sendClient(second, bob, "b1", grant(1, bob));
    try registry.sendClient(second, bob, "b2", grant(2, bob));
    const closed = try registry.closeClient(first, alice);
    try std.testing.expectEqual(@as(usize, 0), closed.count);
    const notification = (try registry.receiveService(endpoint, server)).?;
    try std.testing.expect(notification.closed and notification.sender.eql(alice) and notification.connection == first);
    try std.testing.expectError(error.ConnectionClosed, registry.sendReply(endpoint, server, first, "ack"));
    try std.testing.expectEqualStrings("b1", (try registry.peekService(endpoint, server)).?.bytes());
    const dropped = try registry.closeClient(second, bob);
    try std.testing.expectEqual(@as(usize, 2), dropped.count);
    try std.testing.expectEqual(@as(usize, 4), dropped.bytes);
    try std.testing.expectEqual(@as(u64, 1), dropped.dropped[0].object);
    try std.testing.expectEqual(@as(u64, 2), dropped.dropped[1].object);
    try std.testing.expectEqual(@as(usize, 0), registry.connectionCount());
}
test "unread close notifications bound reconnects and never revive old connection identities" {
    var registry: Registry(1, 1, 1) = .{};
    const endpoint = try registry.open(display_service, server);
    const old = try registry.connect(display_service, alice);
    _ = try registry.closeClient(old, alice);
    try std.testing.expectError(error.WouldBlock, registry.connect(display_service, bob));
    _ = (try registry.receiveService(endpoint, server)).?;
    const next = try registry.connect(display_service, bob);
    try std.testing.expect(next != old);
    try std.testing.expectError(error.ConnectionClosed, registry.receiveClient(old, alice));
    try std.testing.expectError(error.PermissionDenied, registry.receiveClient(next, alice));
}
test "service exit returns queued read references once and invalidates every client before registration reincarnation" {
    var registry: Registry(2, 4, 2) = .{};
    const endpoint = try registry.open(display_service, server);
    const first = try registry.connect(display_service, alice);
    const second = try registry.connect(display_service, bob);
    try registry.sendClient(first, alice, "a", grant(1, alice));
    try registry.sendClient(second, bob, "b", grant(2, bob));
    try registry.sendReply(endpoint, server, first, "reply");
    const closed = try registry.closeService(endpoint, server);
    try std.testing.expectEqual(@as(usize, 2), closed.count);
    try std.testing.expectEqual(@as(usize, 3), closed.messages);
    try std.testing.expectEqual(@as(usize, 7), closed.bytes);
    try std.testing.expectEqual(@as(usize, 0), registry.liveCount());
    try std.testing.expectEqual(@as(usize, 0), registry.queuedCount());
    try std.testing.expectError(error.ConnectionClosed, registry.sendClient(first, alice, "x", null));
    try std.testing.expectError(error.ServiceClosed, registry.receiveService(endpoint, server));
    const newer = try registry.open(display_service, bob);
    try std.testing.expect(newer != endpoint);
    try std.testing.expectError(error.ServiceClosed, registry.closeService(endpoint, server));
}
test "surface queue close followed by producer exit returns physical backing exactly once" {
    var surfaces: surface.Registry(1) = .{};
    const object = try surfaces.create(alice, server, .{ .width = 32, .height = 32 }, .{ .base = 0x100000, .pages = 1 });
    _ = try surfaces.acquireWriter(object, alice);
    try surfaces.writerMapped(object, alice);
    try surfaces.writerUnmapped(object, alice);
    try surfaces.submit(object, alice);
    const attachment = try surfaces.retainRead(object, alice, server);
    var services: Registry(1, 1, 1) = .{};
    _ = try services.open(display_service, server);
    const client = try services.connect(display_service, alice);
    try services.sendClient(client, alice, "frame", attachment);
    try std.testing.expect(try surfaces.dropOwner(object, alice) == null);
    const closed = try services.closeClient(client, alice);
    try std.testing.expectEqual(@as(usize, 1), closed.count);
    for (closed.dropped[0..closed.count]) |dropped| try surfaces.releaseRead(dropped.object, dropped.consumer);
    try std.testing.expectEqual(@as(u64, 0x100000), (try surfaces.collect(object)).?.base);
    try std.testing.expectError(error.StaleSurface, surfaces.collect(object));
}
test "invalid names oversized payloads registry capacity and exhausted generations fail closed" {
    var registry: GenerationRegistry(1, 1, 1, 1) = .{};
    try std.testing.expectError(error.InvalidServiceName, registry.open(2, server));
    const endpoint = try registry.open(display_service, server);
    try std.testing.expectError(error.ServiceAlreadyRegistered, registry.open(display_service, bob));
    const client = try registry.connect(display_service, alice);
    const oversized: [65]u8 = @splat(1);
    try std.testing.expectError(error.MessageTooLarge, registry.sendClient(client, alice, &oversized, null));
    try std.testing.expectError(error.WouldBlock, registry.connect(display_service, bob));
    _ = try registry.closeClient(client, alice);
    _ = (try registry.receiveService(endpoint, server)).?;
    try std.testing.expectError(error.ConnectionCapacity, registry.connect(display_service, bob));
    _ = try registry.closeService(endpoint, server);
    try std.testing.expectError(error.ServiceCapacity, registry.open(display_service, server));
}
test "endpoint and client object namespaces remain distinct even for a service self connection" {
    var registry: Registry(1, 1, 1) = .{};
    const endpoint = try registry.open(display_service, server);
    const client = try registry.connect(display_service, server);
    try std.testing.expect(isEndpoint(endpoint) and !isEndpoint(client) and endpoint != client);
    try std.testing.expectError(error.WrongServiceObjectKind, registry.receiveService(client, server));
    try std.testing.expectError(error.WrongServiceObjectKind, registry.receiveClient(endpoint, server));
    try std.testing.expectError(error.WrongServiceObjectKind, registry.closeService(client, server));
    try std.testing.expectError(error.WrongServiceObjectKind, registry.closeClient(endpoint, server));
    try registry.sendClient(client, server, "self", null);
    try std.testing.expectEqualStrings("self", (try registry.receiveService(endpoint, server)).?.bytes());
}
