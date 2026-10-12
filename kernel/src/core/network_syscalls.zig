//! Checked application socket boundary. Runtime injection supports native tests.
const std = @import("std");
const abi = @import("bedrock64");
const security = @import("security");
const kit = @import("networkkit");
const user = @import("user_memory.zig");
pub const Live = Boundary(@import("network_runtime.zig"));

pub fn Boundary(comptime Runtime: type) type {
    return struct {
        pub fn serve(profile: security.sandbox.Profile, handles: anytype, budget: *security.quotas.Budget, regions: []const user.Region, number: u64, arg0: u64, arg1: u64, arg2: u64) !u64 {
            if (!profile.mayRequest(.network_client)) return error.PermissionDenied;
            switch (number) {
                abi.syscall.udp_open => {
                    if (arg1 != 0 or arg2 != 0) return error.InvalidRequest;
                    var request: abi.UdpConnect = undefined;
                    try copyin(regions, arg0, std.mem.asBytes(&request));
                    if (request.reserved != 0) return error.InvalidRequest;
                    const peer = try kit.Endpoint.init(.{ .bytes = request.address }, request.port);
                    var free = false;
                    for (handles.slots) |slot| if (!slot.retired and slot.grant == null) {
                        free = true;
                        break;
                    };
                    if (!free) return error.TableFull;
                    try budget.reserve(.{ .handles = 1 });
                    errdefer budget.release(.{ .handles = 1 }) catch @panic("UDP handle quota rollback");
                    const object = try Runtime.open(peer);
                    errdefer Runtime.close(object) catch @panic("UDP endpoint rollback");
                    const grant: security.handles.Grant = .{ .kind = .socket, .object_id = object, .rights = security.handles.rights.connect | security.handles.rights.send | security.handles.rights.receive };
                    try profile.authorizeGrant(grant, .network_client);
                    return @backingInt(try handles.insert(grant));
                },
                abi.syscall.udp_send => {
                    const grant = try handles.resolve(@fromBackingInt(arg0), .socket, security.handles.rights.send);
                    try profile.authorizeGrant(grant, .network_client);
                    if (arg2 > kit.max_datagram) return error.MessageTooLarge;
                    var bytes: [kit.max_datagram]u8 = undefined;
                    const length: usize = @intCast(arg2);
                    try copyin(regions, arg1, bytes[0..length]);
                    const sent = try Runtime.send(grant.object_id, bytes[0..length]);
                    if (sent != length) return error.NetworkUnavailable;
                    return sent;
                },
                abi.syscall.udp_receive => {
                    const grant = try handles.resolve(@fromBackingInt(arg0), .socket, security.handles.rights.receive);
                    try profile.authorizeGrant(grant, .network_client);
                    if (arg2 > kit.max_datagram) return error.MessageTooLarge;
                    const capacity: usize = @intCast(arg2);
                    // Validate the entire requested buffer before inspecting or
                    // consuming a datagram. Zero capacity needs no pointer.
                    const physical = if (capacity != 0) try user.translateWrite(regions, arg1, capacity) else 0;
                    const length = (try Runtime.peek(grant.object_id)) orelse return error.WouldBlock;
                    if (length > capacity) return error.BufferTooSmall;
                    var bytes: [kit.max_datagram]u8 = undefined;
                    const received = try Runtime.receive(grant.object_id, bytes[0..capacity]);
                    if (received != length) return error.NetworkUnavailable;
                    if (received != 0) {
                        const destination: [*]volatile u8 = @ptrFromInt(physical);
                        for (bytes[0..received], 0..) |byte, index| destination[index] = byte;
                    }
                    return received;
                },
                else => return error.UnsupportedSyscall,
            }
        }
        /// The caller resolves the current process table; no entitlement is
        /// needed merely to release already-owned resources after revocation.
        pub fn close(handles: anytype, budget: *security.quotas.Budget, token: security.handles.Token) !void {
            const grant = try handles.resolve(token, .socket, 0);
            try Runtime.close(grant.object_id);
            try handles.close(token);
            try budget.release(.{ .handles = 1 });
        }
    };
}
fn copyin(regions: []const user.Region, address: u64, bytes: []u8) !void {
    if (bytes.len == 0) return;
    const physical = try user.translateRead(regions, address, bytes.len);
    const source: [*]const volatile u8 = @ptrFromInt(physical);
    for (bytes, 0..) |*byte, index| byte.* = source[index];
}

const Fake = struct {
    var live: bool = false;
    var queued: bool = false;
    var opened: usize = 0;
    var sent: usize = 0;
    var unavailable: bool = false;
    fn reset() void {
        live = false;
        queued = false;
        opened = 0;
        sent = 0;
        unavailable = false;
    }
    pub fn open(_: kit.Endpoint) !u64 {
        if (unavailable) return error.NetworkUnavailable;
        live = true;
        opened += 1;
        return 1;
    }
    pub fn close(_: u64) !void {
        live = false;
        queued = false;
    }
    pub fn send(_: u64, bytes: []const u8) !usize {
        sent += 1;
        return bytes.len;
    }
    pub fn peek(_: u64) !?usize {
        return if (queued) 4 else null;
    }
    pub fn receive(_: u64, bytes: []u8) !usize {
        @memcpy(bytes[0..4], "echo");
        queued = false;
        return 4;
    }
};
const TestBoundary = Boundary(Fake);
const TestHandles = security.handles.GenerationTable(2, 0x3fff_ffff);
fn testProfile(allowed: bool) !security.sandbox.Profile {
    const permission = security.sandbox.bit(.network_client);
    return security.sandbox.Profile.init(1, permission, if (allowed) permission else 0);
}

test "UDP failure rollback bad send pointers and wrong object kinds preserve quotas and queues" {
    Fake.reset();
    var handles: TestHandles = .{};
    var budget = security.quotas.Budget.init(.{ .handles = 2 });
    var request: abi.UdpConnect = .{ .address = .{ 10, 0, 2, 2 }, .port = 32123 };
    const maps = [_]user.Region{.{ .virtual = 0x1000, .physical = @intFromPtr(&request), .length = @sizeOf(abi.UdpConnect) }};
    const profile = try testProfile(true);
    Fake.unavailable = true;
    try std.testing.expectError(error.NetworkUnavailable, TestBoundary.serve(profile, &handles, &budget, &maps, abi.syscall.udp_open, 0x1000, 0, 0));
    try std.testing.expectEqual(@as(u64, 0), budget.used.handles);
    try std.testing.expectEqual(@as(usize, 0), Fake.opened);
    Fake.unavailable = false;
    const token = try TestBoundary.serve(profile, &handles, &budget, &maps, abi.syscall.udp_open, 0x1000, 0, 0);
    try std.testing.expectError(error.InvalidUserRange, TestBoundary.serve(profile, &handles, &budget, &maps, abi.syscall.udp_send, token, 0x2000, 4));
    const file = try handles.insert(.{ .kind = .file, .object_id = 1, .rights = security.handles.rights.write });
    try std.testing.expectError(error.WrongObjectKind, TestBoundary.serve(profile, &handles, &budget, &maps, abi.syscall.udp_send, @backingInt(file), 0x1000, 4));
    try std.testing.expectEqual(@as(usize, 0), Fake.sent);
    try std.testing.expectEqual(@as(u64, 1), budget.used.handles);
    try TestBoundary.close(&handles, &budget, @fromBackingInt(token));
    try std.testing.expectEqual(@as(u64, 0), budget.used.handles);
}
test "UDP broker preflight denies authority invalid requests and full handles before endpoint allocation" {
    Fake.reset();
    var handles: TestHandles = .{};
    var budget = security.quotas.Budget.init(.{ .handles = 2 });
    var request: abi.UdpConnect = .{ .address = .{ 10, 0, 2, 2 }, .port = 32123 };
    const maps = [_]user.Region{.{ .virtual = 0x1000, .physical = @intFromPtr(&request), .length = @sizeOf(abi.UdpConnect) }};
    const denied = try testProfile(false);
    const allowed = try testProfile(true);
    try std.testing.expectError(error.PermissionDenied, TestBoundary.serve(denied, &handles, &budget, &maps, abi.syscall.udp_open, 0x1000, 0, 0));
    try std.testing.expectError(error.InvalidRequest, TestBoundary.serve(allowed, &handles, &budget, &maps, abi.syscall.udp_open, 0x1000, 1, 0));
    request.reserved = 1;
    try std.testing.expectError(error.InvalidRequest, TestBoundary.serve(allowed, &handles, &budget, &maps, abi.syscall.udp_open, 0x1000, 0, 0));
    request.reserved = 0;
    _ = try handles.insert(.{ .kind = .file, .object_id = 1, .rights = 0 });
    _ = try handles.insert(.{ .kind = .file, .object_id = 2, .rights = 0 });
    try std.testing.expectError(error.TableFull, TestBoundary.serve(allowed, &handles, &budget, &maps, abi.syscall.udp_open, 0x1000, 0, 0));
    try std.testing.expectEqual(@as(usize, 0), Fake.opened);
    try std.testing.expectEqual(@as(u64, 0), budget.used.handles);
}
test "UDP receive prevalidates permissions and capacity preserving queued datagram and close charge" {
    Fake.reset();
    var handles: TestHandles = .{};
    var budget = security.quotas.Budget.init(.{ .handles = 2 });
    var request: abi.UdpConnect = .{ .address = .{ 10, 0, 2, 2 }, .port = 32123 };
    var output: [8]u8 = @splat(0x55);
    const maps = [_]user.Region{ .{ .virtual = 0x1000, .physical = @intFromPtr(&request), .length = @sizeOf(abi.UdpConnect) }, .{ .virtual = 0x2000, .physical = @intFromPtr(&output), .length = output.len, .writable = true } };
    const profile = try testProfile(true);
    const token = try TestBoundary.serve(profile, &handles, &budget, &maps, abi.syscall.udp_open, 0x1000, 0, 0);
    Fake.queued = true;
    try std.testing.expectError(error.InvalidUserRange, TestBoundary.serve(profile, &handles, &budget, &maps, abi.syscall.udp_receive, token, 0x3000, 8));
    try std.testing.expectError(error.InvalidUserRange, TestBoundary.serve(profile, &handles, &budget, &maps, abi.syscall.udp_receive, token, 0x1000, 8));
    try std.testing.expectError(error.BufferTooSmall, TestBoundary.serve(profile, &handles, &budget, &maps, abi.syscall.udp_receive, token, 0x2000, 2));
    try std.testing.expect(Fake.queued);
    try std.testing.expectEqualSlices(u8, &@as([8]u8, @splat(0x55)), &output);
    try std.testing.expectEqual(@as(u64, 4), try TestBoundary.serve(profile, &handles, &budget, &maps, abi.syscall.udp_receive, token, 0x2000, 8));
    try std.testing.expectEqualStrings("echo", output[0..4]);
    try std.testing.expect(!Fake.queued);
    try TestBoundary.close(&handles, &budget, @fromBackingInt(token));
    try std.testing.expect(!Fake.live);
    try std.testing.expectEqual(@as(u64, 0), budget.used.handles);
    try std.testing.expectError(error.StaleToken, TestBoundary.close(&handles, &budget, @fromBackingInt(token)));
}
