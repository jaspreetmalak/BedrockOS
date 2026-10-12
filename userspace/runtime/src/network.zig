//! Public NetworkKit provider backed by checked Bedrock64 socket syscalls.
const kit = @import("networkkit");
const runtime = @import("root.zig");
const abi = @import("bedrock64");
var context: u8 = 0;
pub fn provider() kit.Provider {
    return .{ .context = &context, .open = open, .send = send, .receive = receive, .close = close };
}
fn checked(value: u64) !u64 {
    if (!abi.isError(value)) return value;
    return switch (value) {
        abi.errno.again => error.WouldBlock,
        abi.errno.message_size => error.BufferTooSmall,
        abi.errno.permission => error.PermissionDenied,
        abi.errno.bad_descriptor => error.BadHandle,
        abi.errno.fault => error.InvalidBuffer,
        abi.errno.no_memory => error.Capacity,
        abi.errno.network_unavailable => error.NetworkUnavailable,
        abi.errno.invalid => error.InvalidEndpoint,
        else => error.IOError,
    };
}
fn open(_: *anyopaque, endpoint: kit.Endpoint) !u64 {
    try endpoint.validate();
    const request: abi.UdpConnect = .{ .address = endpoint.address.bytes, .port = endpoint.port };
    return checked(runtime.syscall(abi.syscall.udp_open, @intFromPtr(&request), 0, 0));
}
fn send(_: *anyopaque, handle: u64, bytes: []const u8) !usize {
    if (bytes.len > kit.max_datagram) return error.DatagramTooLarge;
    return @intCast(try checked(runtime.syscall(abi.syscall.udp_send, handle, @intFromPtr(bytes.ptr), bytes.len)));
}
fn receive(_: *anyopaque, handle: u64, output: []u8) !usize {
    return @intCast(try checked(runtime.syscall(abi.syscall.udp_receive, handle, @intFromPtr(output.ptr), @min(output.len, kit.max_datagram))));
}
fn close(_: *anyopaque, handle: u64) !void {
    _ = try checked(runtime.syscall(abi.syscall.close, handle, 0, 0));
}
