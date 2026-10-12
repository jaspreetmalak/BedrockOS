//! Protected connected-UDP acceptance through the public native framework.
const std = @import("std");
const kit = @import("networkkit");
const rt = @import("userspace_runtime");
const abi = @import("bedrock64");
pub const panic = std.debug.FullPanic(rt.panic);
const attempts = 128;
var received: [kit.max_datagram]u8 = undefined;

noinline fn tick() void {
    rt.expect(rt.syscall(abi.syscall.sleep, 1, 0, 0) == 0);
}

noinline fn transmit(connection: *kit.Connection, message: []const u8) void {
    for (0..attempts) |_| {
        const count = connection.send(message) catch |err| switch (err) {
            error.WouldBlock => {
                tick();
                continue;
            },
            else => rt.exit(99),
        };
        rt.expect(count == message.len);
        return;
    }
    rt.exit(99);
}

noinline fn receive(connection: *kit.Connection, wanted: []const u8) void {
    for (0..attempts) |_| {
        const count = connection.receive(&received) catch |err| switch (err) {
            error.WouldBlock => {
                tick();
                continue;
            },
            else => rt.exit(99),
        };
        rt.expect(count == wanted.len and std.mem.eql(u8, received[0..count], wanted));
        return;
    }
    rt.exit(99);
}

noinline fn shortReceive(connection: *kit.Connection) void {
    for (0..attempts) |_| {
        _ = connection.receive(received[0..1]) catch |err| switch (err) {
            error.BufferTooSmall => return,
            error.WouldBlock => {
                tick();
                continue;
            },
            else => rt.exit(99),
        };
        rt.exit(99);
    }
    rt.exit(99);
}

noinline fn badKind(value: u64) void {
    rt.expect(value == abi.errno.permission or value == abi.errno.bad_descriptor);
}

export fn bedrock_user_main(parent_pid: u64, inherited_token: u64, launch_arg: u64) callconv(.c) noreturn {
    _ = parent_pid;
    rt.markEntry();
    rt.expect(inherited_token == 0);
    if (launch_arg == 0) {
        rt.write("[user] NetworkKit echo skipped (no host port)\n");
        rt.exit(44);
    }
    rt.expect(launch_arg <= std.math.maxInt(u16));
    const address = comptime kit.IPv4.parse("10.0.2.2") catch unreachable;
    const endpoint = kit.Endpoint.init(address, @intCast(launch_arg)) catch rt.exit(99);
    var connection = kit.Connection.connect(rt.network.provider(), endpoint) catch rt.exit(99);
    const token = connection.handle;

    // The checked syscall boundary rejects malformed authority and input before
    // emitting data; framework size checks alone do not establish isolation.
    var request: abi.UdpConnect = .{ .address = address.bytes, .port = endpoint.port, .reserved = 1 };
    rt.expect(rt.syscall(abi.syscall.udp_open, abi.guard, 0, 0) == abi.errno.fault);
    rt.expect(rt.syscall(abi.syscall.udp_open, @intFromPtr(&request), 0, 0) == abi.errno.invalid);
    request.reserved = 0;
    rt.expect(rt.syscall(abi.syscall.udp_open, @intFromPtr(&request), 1, 0) == abi.errno.invalid);
    rt.expect(rt.syscall(abi.syscall.udp_send, token, abi.code, kit.max_datagram + 1) == abi.errno.message_size);
    rt.expect(rt.syscall(abi.syscall.udp_send, token, abi.guard, 1) == abi.errno.fault);
    badKind(rt.syscall(abi.syscall.udp_send, 1, 0, 0));
    badKind(rt.syscall(abi.syscall.udp_receive, 1, @intFromPtr(&received), received.len));

    const first = "NetworkKit echo one";
    transmit(&connection, first);
    // Wait until a real nonempty response is queued, proving short capacity and
    // denied copyout leave that exact message available for the whole receive.
    shortReceive(&connection);
    rt.expect(rt.syscall(abi.syscall.udp_receive, token, abi.code, received.len) == abi.errno.fault);
    rt.expect(rt.syscall(abi.syscall.udp_receive, token, abi.guard, 1) == abi.errno.fault);
    receive(&connection, first);
    const second = "NetworkKit different reply";
    transmit(&connection, second);
    receive(&connection, second);
    rt.write("[user] NetworkKit UDP echo verified\n");

    connection.close() catch rt.exit(99);
    rt.expect(rt.syscall(abi.syscall.udp_send, token, 0, 0) == abi.errno.bad_descriptor);
    rt.expect(rt.syscall(abi.syscall.udp_receive, token, @intFromPtr(&received), received.len) == abi.errno.bad_descriptor);
    rt.expect(rt.close(token) == abi.errno.bad_descriptor);
    rt.write("[user] NetworkKit authority checks passed\n");

    var zero = kit.Connection.connect(rt.network.provider(), endpoint) catch rt.exit(99);
    rt.expect(zero.handle != token);
    transmit(&zero, "");
    receive(&zero, "");
    zero.close() catch rt.exit(99);
    rt.write("[user] NetworkKit zero datagram verified\n");
    // Leave one live connection deliberately: the kernel must reclaim its
    // socket, grant and quota when this protected process exits.
    const armed = kit.Connection.connect(rt.network.provider(), endpoint) catch rt.exit(99);
    rt.expect(armed.handle != 0);
    rt.write("[user] NetworkKit exit cleanup armed\n");
    rt.exit(44);
}
