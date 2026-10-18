//! Surface leases, authenticated service queues and checked scanout. Called
//! only from the serialized kernel continuation, with user roots inactive.
const std = @import("std");
const protocol = @import("boot_protocol");
const abi = @import("bedrock64");
const security = @import("security");
const memory = @import("memory_init");
const arch = @import("isolation_arch");
const contract = @import("isolation_contract");
const user = @import("user_memory.zig");
const surfaces = @import("surface.zig");
const services = @import("service_ipc.zig");
const policy = @import("application_policy.zig");
const disk = @import("storage_runtime.zig");
const virtio = @import("virtio");
const gpu_backend = @import("gpu_backend");
const present_region = @import("present_region.zig");
const options = @import("kernel_options");
const window_messages = @import("window_message_policy.zig");
pub const Grants = security.handles.GenerationTable(16, 0x3fff_ffff);
pub const Shared = struct { object: u64 = 0, token: security.handles.Token = @fromBackingInt(0), mapping: contract.SharedMapping = .{} };
pub const Client = struct {
    identity: surfaces.Identity,
    profile: security.sandbox.Profile,
    space: contract.AddressSpace,
    handles: *Grants,
    shared: *[contract.shared_surface_slots]Shared,
};
const Owner = memory.ownership.Owner(1);
const surface_capacity = if (options.window_runtime) 16 else if (options.desktop_runtime) 8 else 4;
const SurfaceRegistry = surfaces.Registry(surface_capacity);
const Bus = services.Registry(2, 4, 16);
const Allocation = struct { object: u64, owner: Owner, backing: surfaces.Backing, app: u64, window_id: u16 };
pub const Metrics = struct { frames_a: u64 = 0, frames_b: u64 = 0, frames_shell: u64 = 0, frames_files: u64 = 0, frames_notes: u64 = 0, reclaimed_a: usize = 0, rw_revoked: u64 = 0, ro_released: u64 = 0, presented: u64 = 0, input_events: u64 = 0 };
pub const Manager = struct {
    registry: SurfaceRegistry = .{},
    bus: Bus = .{},
    allocations: [surface_capacity]?Allocation = @splat(null),
    framebuffer: protocol.Framebuffer = .{},
    graphics: gpu_backend.Driver = .{},
    budget: *security.quotas.Budget = undefined,
    write: *const fn ([]const u8) void = undefined,
    decoder: virtio.Decoder = undefined,
    metrics: Metrics = .{},
    sequences: [surface_capacity]u64 = @splat(0),
    initialized: bool = false,
    finish_requested: bool = false,

    /// Retained snapshots whose producer exited do not count as live windows.
    pub fn producerCount(self: *Manager, app: u64) !usize {
        var count: usize = 0;
        for (self.allocations) |allocation| if (allocation) |live| {
            const snapshot = try self.registry.get(live.object);
            if (live.app == app and snapshot.owner_alive) count += 1;
        };
        return count;
    }

    pub fn initialize(self: *Manager, info: *const protocol.BootInfo, budget: *security.quotas.Budget, write: *const fn ([]const u8) void) !void {
        if (self.initialized) return error.DisplayAlreadyInitialized;
        try info.framebuffer.validate();
        if (info.framebuffer.base == 0 or info.framebuffer.width < 800 or info.framebuffer.height < 600 or info.framebuffer.width > 1280 or info.framebuffer.height > 800)
            return error.UnsupportedDisplayGeometry;
        self.framebuffer = info.framebuffer;
        try self.graphics.initialize(info.framebuffer);
        self.budget = budget;
        self.write = write;
        self.decoder = try virtio.Decoder.init(info.framebuffer.width, info.framebuffer.height);
        self.initialized = true;
        write("[kernel] Anvil backend=software hardware_acceleration=0\n");
        write("[kernel] protected surface broker ready\n");
    }
    fn server(client: Client) bool {
        return client.profile.app_id == policy.display_server_id and client.profile.mayRequest(.display_service);
    }
    fn allowed(client: Client) bool {
        return server(client) or client.profile.mayRequest(.display_client);
    }
    fn service(self: *Manager) !surfaces.Identity {
        return self.bus.serviceOwner(try self.bus.findService(services.display_service));
    }
    fn addHandle(self: *Manager, client: Client, grant: security.handles.Grant, source: security.sandbox.Source) !security.handles.Token {
        try client.profile.authorizeGrant(grant, source);
        try self.budget.reserve(.{ .handles = 1 });
        errdefer self.budget.release(.{ .handles = 1 }) catch @panic("display handle rollback");
        return client.handles.insert(grant);
    }
    fn removeHandle(self: *Manager, client: Client, token: security.handles.Token) !void {
        try client.handles.close(token);
        try self.budget.release(.{ .handles = 1 });
    }
    fn surfaceGrant(client: Client, token: u64, rights: u64) !security.handles.Grant {
        return client.handles.resolve(@fromBackingInt(token), .surface, rights);
    }
    fn serviceGrant(client: Client, token: u64, rights: u64) !security.handles.Grant {
        return client.handles.resolve(@fromBackingInt(token), .service, rights);
    }
    fn copyIn(comptime T: type, regions: []const user.Region, address: u64) !T {
        const physical = try user.translateRead(regions, address, @sizeOf(T));
        var value: T = undefined;
        const source: [*]const volatile u8 = @ptrFromInt(physical);
        for (std.mem.asBytes(&value), 0..) |*byte, index| byte.* = source[index];
        return value;
    }
    fn copyOut(comptime T: type, regions: []const user.Region, address: u64, value: *const T) !void {
        const physical = try user.translateWrite(regions, address, @sizeOf(T));
        const target: [*]volatile u8 = @ptrFromInt(physical);
        for (std.mem.asBytes(value), 0..) |byte, index| target[index] = byte;
    }
    fn mappedSlot(client: Client, object: u64) ?usize {
        for (client.shared, 0..) |slot, index| if (slot.object == object) return index;
        return null;
    }
    fn unmap(self: *Manager, client: Client, slot: usize) !void {
        const shared = client.shared[slot];
        if (shared.object == 0) return error.InvalidSurface;
        try arch.unmapShared(client.space, slot);
        client.shared[slot] = .{};
        if (shared.mapping.writable) {
            try self.registry.writerUnmapped(shared.object, client.identity);
            self.metrics.rw_revoked += 1;
        } else {
            try self.registry.releaseReader(shared.object, client.identity);
            try self.removeHandle(client, shared.token);
            self.metrics.ro_released += 1;
            try self.collect(shared.object);
        }
    }
    fn collect(self: *Manager, object: u64) !void {
        const snapshot = try self.registry.get(object);
        if (snapshot.owner_alive) return;
        if (try self.registry.collect(object)) |backing| try self.releaseBacking(object, backing);
    }
    fn releaseBacking(self: *Manager, object: u64, backing: surfaces.Backing) !void {
        const slot: usize = @intCast(@as(u32, @truncate(object)) - 1);
        var allocation = self.allocations[slot] orelse return error.SurfaceOwnershipLost;
        if (allocation.object != object or allocation.backing.base != backing.base or allocation.backing.pages != backing.pages) return error.SurfaceOwnershipLost;
        try allocation.owner.releaseAll();
        try self.budget.release(.{ .memory_pages = backing.pages });
        self.allocations[slot] = null;
        self.sequences[slot] = 0;
        if (allocation.app == policy.surface_one_id) {
            self.metrics.reclaimed_a += 1;
            self.write("[kernel] surface A generation reclaimed; surface B retained\n");
        }
    }
    fn closeSurface(self: *Manager, client: Client, token: security.handles.Token) !void {
        const grant = try client.handles.resolve(token, .surface, 0);
        const snapshot = try self.registry.get(grant.object_id);
        if (mappedSlot(client, grant.object_id)) |slot| {
            const writable = client.shared[slot].mapping.writable;
            try self.unmap(client, slot);
            if (!writable) return;
        }
        if (grant.rights & security.handles.rights.write != 0) {
            if (try self.registry.dropOwner(grant.object_id, client.identity)) |backing| try self.releaseBacking(grant.object_id, backing);
        } else {
            if (!snapshot.consumer.eql(client.identity)) return error.PermissionDenied;
            try self.registry.releaseRead(grant.object_id, client.identity);
            try self.collect(grant.object_id);
        }
        try self.removeHandle(client, token);
    }
    fn dropped(self: *Manager, closed: Bus.Closed) !void {
        try self.budget.release(.{ .ipc_bytes = closed.bytes });
        for (closed.dropped[0..closed.count]) |grant| {
            try self.registry.releaseRead(grant.object, grant.consumer);
            try self.collect(grant.object);
        }
    }
    fn closeService(self: *Manager, client: Client, token: security.handles.Token) !void {
        const grant = try client.handles.resolve(token, .service, 0);
        const closed = if (services.isEndpoint(grant.object_id)) try self.bus.closeService(grant.object_id, client.identity) else try self.bus.closeClient(grant.object_id, client.identity);
        try self.dropped(closed);
        try self.removeHandle(client, token);
    }
    pub fn close(self: *Manager, client: Client, token: security.handles.Token, kind: security.handles.ObjectKind) !void {
        return switch (kind) {
            .surface => self.closeSurface(client, token),
            .service => self.closeService(client, token),
            else => error.WrongObjectKind,
        };
    }
    /// Called before destroying a task's private root. Snapshot refs already
    /// delivered to another task remain valid until that task releases them.
    pub fn detach(self: *Manager, client: Client) !void {
        // Revoke every PTE first, then discard endpoints and owner handles.
        for (0..client.shared.len) |slot| if (client.shared[slot].object != 0) try self.unmap(client, slot);
        for ([_]security.handles.ObjectKind{ .service, .surface }) |kind| {
            for (client.handles.slots, 0..) |entry, index| {
                const grant = entry.grant orelse continue;
                if (grant.kind != kind) continue;
                const token: security.handles.Token = @fromBackingInt((@as(u64, entry.generation) << 32) | (index + 1));
                self.close(client, token, kind) catch |err| {
                    // Service death retires all connection IDs immediately.
                    // Their remaining task-local handles hold no queue refs.
                    if (kind != .service or (err != error.StaleConnection and err != error.StaleService and err != error.InvalidConnection and err != error.InvalidService and err != error.ConnectionClosed and err != error.ServiceClosed)) return err;
                    try self.removeHandle(client, token);
                };
            }
        }
    }
    fn submit(self: *Manager, client: Client, token: u64, endpoint: u64, sequence: u64) !u64 {
        if (sequence == 0) return error.InvalidSurfaceTransition;
        const grant = try surfaceGrant(client, token, security.handles.rights.write | security.handles.rights.send);
        const channel = try serviceGrant(client, endpoint, security.handles.rights.send);
        const peer = try self.bus.getConnection(channel.object_id);
        if (!peer.client.eql(client.identity)) return error.PermissionDenied;
        const snapshot = try self.registry.get(grant.object_id);
        if (!snapshot.owner.eql(client.identity) or !snapshot.consumer.eql(peer.service)) return error.PermissionDenied;
        const object_slot: usize = @intCast(@as(u32, @truncate(grant.object_id)) - 1);
        const allocation = self.allocations[object_slot] orelse return error.SurfaceOwnershipLost;
        if (allocation.object != grant.object_id) return error.SurfaceOwnershipLost;
        if (sequence <= self.sequences[object_slot]) return error.InvalidSurfaceTransition;
        if (!try self.bus.canSendClient(channel.object_id, client.identity)) return error.WouldBlock;
        try self.budget.reserve(.{ .ipc_bytes = @sizeOf(abi.ServiceMessage) });
        errdefer self.budget.release(.{ .ipc_bytes = @sizeOf(abi.ServiceMessage) }) catch @panic("surface queue rollback");
        const slot = mappedSlot(client, grant.object_id) orelse return error.SurfaceMappingActive;
        if (!client.shared[slot].mapping.writable) return error.PermissionDenied;
        try self.unmap(client, slot);
        try self.registry.submit(grant.object_id, client.identity);
        const read = try self.registry.retainRead(grant.object_id, client.identity, peer.service);
        const message: abi.ServiceMessage = .{ .kind = abi.display.frame, .flags = window_messages.frameFlags(allocation.window_id), .sequence = sequence, .width = snapshot.geometry.width, .height = snapshot.geometry.height };
        self.bus.sendClient(channel.object_id, client.identity, std.mem.asBytes(&message), read) catch @panic("preflighted surface enqueue failed");
        self.sequences[object_slot] = sequence;
        if (client.identity.app_id == policy.shell_id) self.metrics.frames_shell += 1;
        if (client.identity.app_id == policy.files_id) self.metrics.frames_files += 1;
        if (client.identity.app_id == policy.notes_id) self.metrics.frames_notes += 1;
        return 0;
    }
    fn send(self: *Manager, client: Client, endpoint: u64, address: u64, length: u64, regions: []const user.Region) !u64 {
        if (length != @sizeOf(abi.ServiceMessage)) return error.MessageTooLarge;
        const grant = try serviceGrant(client, endpoint, security.handles.rights.send);
        var message = try copyIn(abi.ServiceMessage, regions, address);
        if (message.surface != 0) return error.PermissionDenied;
        try window_messages.validateFlags(options.window_runtime, server(client), client.identity.app_id, &message);
        try self.budget.reserve(.{ .ipc_bytes = length });
        errdefer self.budget.release(.{ .ipc_bytes = length }) catch @panic("service send rollback");
        if (server(client)) {
            if (message.kind == abi.display.configure) {
                if (!options.desktop_runtime or message.sequence == 0 or message.width > self.framebuffer.width or message.height > self.framebuffer.height or ((message.width == 0) != (message.height == 0))) return error.PermissionDenied;
            } else if (message.kind == abi.display.window_status) {
                if (!options.window_runtime or message.peer_app != policy.shell_id or message.sequence == 0 or message.width >= 4 or message.height > 1) return error.PermissionDenied;
                for (message.payload[8..]) |byte| if (byte != 0) return error.PermissionDenied;
            } else if (message.kind == abi.display.window_rejected) {
                if (!options.window_runtime or message.peer_app == policy.shell_id) return error.PermissionDenied;
                try window_messages.validateRejected(&message);
            } else {
                if (message.width != 0 or message.height != 0) return error.PermissionDenied;
                if (message.kind != abi.display.ack and message.kind != abi.display.input and (!options.desktop_runtime or message.kind != abi.display.close)) return error.PermissionDenied;
            }
            const target = for (0..4) |index| {
                const connection = self.bus.connectionAt(index) orelse continue;
                const peer = try self.bus.getConnection(connection);
                if (peer.endpoint == grant.object_id and peer.client.pid == message.peer_pid and peer.client.app_id == message.peer_app) break connection;
            } else return error.StaleConnection;
            message.peer_pid = 0;
            message.peer_app = 0;
            try self.bus.sendReply(grant.object_id, client.identity, target, std.mem.asBytes(&message));
        } else {
            if (message.peer_pid != 0 or message.peer_app != 0) return error.PermissionDenied;
            if (message.sequence == 0) return error.InvalidSurfaceTransition;
            if (message.kind == abi.display.create_window or message.kind == abi.display.resize_window) {
                if (!options.window_runtime or client.identity.app_id == policy.shell_id or message.width == 0 or message.height == 0 or message.width > self.framebuffer.width or message.height > self.framebuffer.height) return error.PermissionDenied;
                var terminated = false;
                for (message.payload) |byte| {
                    if (message.kind == abi.display.resize_window) {
                        if (byte != 0) return error.PermissionDenied;
                    } else if (byte == 0) terminated = true else if (terminated or byte < 32 or byte > 126) return error.PermissionDenied;
                }
                if (message.kind == abi.display.create_window and message.payload[0] == 0) return error.PermissionDenied;
            } else if (message.kind == abi.display.move_window) {
                if (!options.window_runtime or client.identity.app_id == policy.shell_id) return error.PermissionDenied;
                try window_messages.validateMove(&message);
            } else {
                if (message.width != 0 or message.height != 0) return error.PermissionDenied;
                if (message.kind == abi.display.launch) {
                    if (!options.desktop_runtime or client.identity.app_id != policy.shell_id) return error.PermissionDenied;
                    if (options.window_runtime and message.sequence != 1 and message.sequence != policy.files_id and message.sequence != policy.notes_id) return error.PermissionDenied;
                } else if (message.kind != abi.display.heartbeat and
                    (!options.window_runtime or client.identity.app_id == policy.shell_id or (message.kind != abi.display.focus_window and message.kind != abi.display.close_window and message.kind != abi.display.retire_window))) return error.PermissionDenied;
                for (message.payload) |byte| if (byte != 0) return error.PermissionDenied;
            }
            try self.bus.sendClient(grant.object_id, client.identity, std.mem.asBytes(&message), null);
        }
        return 0;
    }
    fn receive(self: *Manager, client: Client, endpoint: u64, address: u64, length: u64, regions: []const user.Region) !u64 {
        if (length != @sizeOf(abi.ServiceMessage)) return error.MessageTooLarge;
        _ = try user.translateWrite(regions, address, length);
        const grant = try serviceGrant(client, endpoint, security.handles.rights.receive);
        const pending = (if (server(client)) try self.bus.peekService(grant.object_id, client.identity) else try self.bus.peekClient(grant.object_id, client.identity)) orelse return error.WouldBlock;
        var message: abi.ServiceMessage = if (pending.closed) .{ .kind = abi.display.peer_closed } else std.mem.bytesToValue(abi.ServiceMessage, &pending.payload);
        if (!pending.closed and pending.length != @sizeOf(abi.ServiceMessage)) return error.MessageTooLarge;
        message.peer_pid = pending.sender.pid;
        message.peer_app = pending.sender.app_id;
        var inserted: ?security.handles.Token = null;
        errdefer if (inserted) |token| self.removeHandle(client, token) catch @panic("surface receive rollback");
        if (pending.attachment) |read| {
            if (!server(client) or read.rights != 1 or !read.consumer.eql(client.identity)) return error.PermissionDenied;
            const snapshot = try self.registry.get(read.object);
            const token = try self.addHandle(client, .{ .kind = .surface, .object_id = read.object, .rights = security.handles.rights.read }, .display_snapshot);
            inserted = token;
            message.surface = @backingInt(token);
            message.width = snapshot.geometry.width;
            message.height = snapshot.geometry.height;
        }
        try copyOut(abi.ServiceMessage, regions, address, &message);
        _ = if (server(client)) try self.bus.receiveService(grant.object_id, client.identity) else try self.bus.receiveClient(grant.object_id, client.identity);
        try self.budget.release(.{ .ipc_bytes = pending.length });
        return 0;
    }
    fn present(self: *Manager, client: Client, request: abi.PresentRequest) !void {
        if (!server(client)) return error.PermissionDenied;
        const grant = try surfaceGrant(client, request.surface_token, security.handles.rights.read);
        const snapshot = try self.registry.get(grant.object_id);
        const slot = mappedSlot(client, grant.object_id) orelse return error.SurfaceMappingActive;
        if (snapshot.owner.eql(client.identity)) {
            if (!client.shared[slot].mapping.writable or snapshot.state != .writing) return error.PermissionDenied;
        } else if (client.shared[slot].mapping.writable or snapshot.state != .reading or !snapshot.consumer.eql(client.identity)) return error.PermissionDenied;
        if (request.sequence == 0) return error.InvalidGeometry;
        const region = try present_region.resolve(.{ .width = self.framebuffer.width, .height = self.framebuffer.height, .stride = self.framebuffer.pixels_per_scanline }, .{ .width = snapshot.geometry.width, .height = snapshot.geometry.height }, .{ .x = request.x, .y = request.y, .width = request.width, .height = request.height }, .{ .window_runtime = options.window_runtime, .source_owned = snapshot.owner.eql(client.identity) });
        const source: [*]const volatile u32 = @ptrFromInt(snapshot.backing.base);
        // Authorization, lease state and checked ROI resolution above remain
        // the boundary. Anvil receives only the broker's validated physical view.
        _ = try self.graphics.present(.{
            .pixels = @constCast(source[0 .. @as(usize, snapshot.geometry.width) * snapshot.geometry.height]),
            .width = snapshot.geometry.width,
            .height = snapshot.geometry.height,
            .stride = snapshot.geometry.width,
            .format = .xrgb8888,
            .access = .read_only,
        }, .{
            .x = @intCast(region.source_offset % region.source_stride),
            .y = @intCast(region.source_offset / region.source_stride),
            .width = @intCast(region.width),
            .height = @intCast(region.height),
        }, .{ .x = @intCast(request.x), .y = @intCast(request.y) });
        if (self.metrics.presented == 0) self.write("[kernel] Anvil first presentation completed\n");
        self.metrics.presented += 1;
        if (snapshot.owner.app_id == policy.surface_one_id) self.metrics.frames_a += 1;
        if (snapshot.owner.app_id == policy.surface_two_id) self.metrics.frames_b += 1;
    }
    fn input(self: *Manager) !abi.DisplayInput {
        for (0..disk.input_count) |index| {
            var device = &disk.inputs[index];
            for (0..16) |_| {
                if (self.decoder.count > 28) break;
                const event = (try device.poll()) orelse break;
                try self.decoder.feed(event, device.abs_x, device.abs_y);
            }
        }
        const raw = self.decoder.pop() orelse return error.WouldBlock;
        self.metrics.input_events += 1;
        if (@as(u8, @truncate(raw)) == 4 and @as(u16, @truncate(raw >> 16)) == (if (options.desktop_runtime) @as(u16, 0x10c) else @as(u16, 0x10b))) self.finish_requested = true;
        return .{ .kind = @as(u8, @truncate(raw)), .modifiers = @as(u8, @truncate(raw >> 8)), .code = @as(u16, @truncate(raw >> 16)), .x = @as(i16, @bitCast(@as(u16, @truncate(raw >> 32)))), .y = @as(i16, @bitCast(@as(u16, @truncate(raw >> 48)))), .sequence = self.metrics.input_events };
    }
    pub fn execute(self: *Manager, client: Client, number: u64, arg0: u64, arg1: u64, arg2: u64, regions: []const user.Region) !u64 {
        if (!self.initialized) return error.NotSupported;
        if (!allowed(client)) return error.PermissionDenied;
        switch (number) {
            abi.syscall.surface_create => {
                if (arg1 != 0 or arg2 != 0) return error.InvalidGeometry;
                const request = try copyIn(abi.SurfaceCreate, regions, arg0);
                if (request.format != abi.display.format) return error.InvalidGeometry;
                const window_id = try window_messages.surfaceWindowId(options.window_runtime, server(client), client.identity.app_id, request.reserved);
                const geometry: surfaces.Geometry = .{ .width = request.width, .height = request.height };
                const pages = try geometry.pages();
                if (!server(client)) {
                    if (options.desktop_runtime) {
                        if ((!options.window_runtime and client.identity.app_id != policy.files_id and client.identity.app_id != policy.shell_id) or request.width != self.framebuffer.width or request.height != self.framebuffer.height) return error.InvalidGeometry;
                    } else if (request.width > 320 or request.height > 240) return error.SurfaceTooLarge;
                }
                var owner_count: usize = 0;
                for (self.allocations) |allocation| if (allocation) |live| {
                    const snapshot = try self.registry.get(live.object);
                    if (snapshot.owner_alive and snapshot.owner.eql(client.identity)) {
                        owner_count += 1;
                        if (options.window_runtime and client.identity.app_id == policy.files_id and live.window_id == window_id) return error.SurfaceBusy;
                    }
                };
                if (owner_count >= window_messages.producerLimit(options.window_runtime, options.desktop_runtime, server(client), client.identity.app_id)) return error.SurfaceCapacity;
                const consumer = try self.service();
                try self.budget.reserve(.{ .memory_pages = pages });
                errdefer self.budget.release(.{ .memory_pages = pages }) catch @panic("surface pages rollback");
                var owner = try Owner.init(memory.allocator().?, try memory.newOwnerId());
                errdefer owner.releaseAll() catch @panic("surface frames rollback");
                const ticket = try owner.allocate(pages, 1);
                const range = try owner.resolve(ticket);
                memory.clearRange(range);
                const backing: surfaces.Backing = .{ .base = range.base, .pages = pages };
                const object = try self.registry.create(client.identity, consumer, geometry, backing);
                errdefer {
                    _ = self.registry.dropOwner(object, client.identity) catch @panic("surface object rollback");
                }
                const token = try self.addHandle(client, .{ .kind = .surface, .object_id = object, .rights = security.handles.rights.read | security.handles.rights.write | security.handles.rights.send }, .{ .private_surface = client.identity.app_id });
                self.allocations[@as(u32, @truncate(object)) - 1] = .{ .object = object, .owner = owner, .backing = backing, .app = client.identity.app_id, .window_id = window_id };
                return @backingInt(token);
            },
            abi.syscall.surface_map => {
                if (arg1 >= contract.shared_surface_slots or arg2 > 1) return error.InvalidGeometry;
                const slot: usize = @intCast(arg1);
                if (client.shared[slot].object != 0) return error.SurfaceBusy;
                const writable = arg2 == 1;
                const grant = try surfaceGrant(client, arg0, if (writable) security.handles.rights.write else security.handles.rights.read);
                if (!writable and !server(client)) return error.PermissionDenied;
                const mapping = if (writable) try self.registry.acquireWriter(grant.object_id, client.identity) else try self.registry.acquireReader(grant.object_id, client.identity);
                errdefer if (writable) self.registry.cancelWriter(grant.object_id, client.identity) catch @panic("surface writer rollback") else self.registry.cancelReader(grant.object_id, client.identity) catch @panic("surface reader rollback");
                try arch.mapShared(client.space, slot, mapping.backing.base, mapping.backing.pages, writable);
                errdefer arch.unmapShared(client.space, slot) catch @panic("surface PTE rollback");
                if (writable) try self.registry.writerMapped(grant.object_id, client.identity) else try self.registry.readerMapped(grant.object_id, client.identity);
                client.shared[slot] = .{ .object = grant.object_id, .token = @fromBackingInt(arg0), .mapping = .{ .physical = mapping.backing.base, .pages = mapping.backing.pages, .writable = writable } };
                return contract.shared_surface_base + arg1 * contract.shared_surface_stride;
            },
            abi.syscall.surface_unmap => {
                if (arg1 != 0 or arg2 != 0) return error.InvalidGeometry;
                const grant = try surfaceGrant(client, arg0, 0);
                try self.unmap(client, mappedSlot(client, grant.object_id) orelse return error.InvalidSurface);
                return 0;
            },
            abi.syscall.surface_submit => return self.submit(client, arg0, arg1, arg2),
            abi.syscall.surface_release => {
                if (!server(client)) return error.PermissionDenied;
                if (arg1 != 0 or arg2 != 0) return error.InvalidGeometry;
                const token: security.handles.Token = @fromBackingInt(arg0);
                const grant = try client.handles.resolve(token, .surface, security.handles.rights.read);
                if (grant.rights & security.handles.rights.write != 0) return error.PermissionDenied;
                try self.closeSurface(client, token);
                return 0;
            },
            abi.syscall.surface_close => {
                if (arg1 != 0 or arg2 != 0) return error.InvalidGeometry;
                try self.closeSurface(client, @fromBackingInt(arg0));
                return 0;
            },
            abi.syscall.service_open => {
                if (!server(client)) return error.PermissionDenied;
                if (arg1 != 0 or arg2 != 0) return error.InvalidGeometry;
                const object = try self.bus.open(arg0, client.identity);
                errdefer {
                    _ = self.bus.closeService(object, client.identity) catch @panic("service open rollback");
                }
                return @backingInt(try self.addHandle(client, .{ .kind = .service, .object_id = object, .rights = security.handles.rights.send | security.handles.rights.receive }, .display_service));
            },
            abi.syscall.service_connect => {
                if (server(client)) return error.PermissionDenied;
                if (arg1 != 0 or arg2 != 0) return error.InvalidGeometry;
                if (options.window_runtime) for (0..4) |index| {
                    const connection = self.bus.connectionAt(index) orelse continue;
                    if ((try self.bus.getConnection(connection)).client.eql(client.identity)) return error.Busy;
                };
                const object = try self.bus.connect(arg0, client.identity);
                errdefer {
                    _ = self.bus.closeClient(object, client.identity) catch @panic("service connect rollback");
                }
                return @backingInt(try self.addHandle(client, .{ .kind = .service, .object_id = object, .rights = security.handles.rights.send | security.handles.rights.receive }, .display_service));
            },
            abi.syscall.service_send => return self.send(client, arg0, arg1, arg2, regions),
            abi.syscall.service_receive => return self.receive(client, arg0, arg1, arg2, regions),
            abi.syscall.service_close => {
                if (arg1 != 0 or arg2 != 0) return error.InvalidGeometry;
                try self.closeService(client, @fromBackingInt(arg0));
                return 0;
            },
            abi.syscall.display_present => {
                if (!server(client)) return error.PermissionDenied;
                if (arg1 != 0 or arg2 != 0) return error.InvalidGeometry;
                try self.present(client, try copyIn(abi.PresentRequest, regions, arg0));
                return 0;
            },
            abi.syscall.display_info => {
                if (!server(client)) return error.PermissionDenied;
                if (arg1 != 0 or arg2 != 0) return error.InvalidGeometry;
                const value: abi.DisplayInfo = .{ .width = self.framebuffer.width, .height = self.framebuffer.height, .format = abi.display.format };
                try copyOut(abi.DisplayInfo, regions, arg0, &value);
                return 0;
            },
            abi.syscall.display_input => {
                if (!server(client)) return error.PermissionDenied;
                if (arg1 != 0 or arg2 != 0) return error.InvalidGeometry;
                _ = try user.translateWrite(regions, arg0, @sizeOf(abi.DisplayInput));
                const value = try self.input();
                try copyOut(abi.DisplayInput, regions, arg0, &value);
                return 0;
            },
            else => return error.NotSupported,
        }
    }
};
