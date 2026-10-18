//! Pure validation of authenticated display service records and mapping bounds.
const std = @import("std");
const abi = @import("bedrock64");
pub const Error = error{ InvalidMessage, InvalidMapping, InvalidGeometry, InvalidInput };
fn zero(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != 0) return false;
    return true;
}
pub fn pixels(address: u64, slot: u64, width: u32, height: u32) Error![]volatile u32 {
    if (slot >= abi.display.map_slots or address != abi.display.map_base + slot * abi.display.map_stride) return error.InvalidMapping;
    const count = @as(u64, width) * height;
    if (width == 0 or height == 0 or count > abi.display.map_stride / 4) return error.InvalidGeometry;
    const result: [*]volatile u32 = @ptrFromInt(address);
    return result[0..@intCast(count)];
}
pub fn validateClient(message: *const abi.ServiceMessage, server_pid: ?u64) Error!void {
    if (message.flags != 0 or message.peer_pid == 0 or message.peer_app != abi.display.server or message.surface != 0 or
        message.width != 0 or message.height != 0 or message.sequence == 0) return error.InvalidMessage;
    if (server_pid) |pid| if (message.peer_pid != pid) return error.InvalidMessage;
    switch (message.kind) {
        abi.display.ack => if (!zero(&message.payload)) return error.InvalidMessage,
        abi.display.input => if (!zero(message.payload[8..])) return error.InvalidMessage,
        else => return error.InvalidMessage,
    }
}
pub fn validateServer(message: *const abi.ServiceMessage) Error!void {
    if (message.flags != 0 or message.peer_pid == 0 or
        (message.peer_app != abi.display.client_a and message.peer_app != abi.display.client_b) or !zero(&message.payload)) return error.InvalidMessage;
    switch (message.kind) {
        abi.display.frame => if (message.surface == 0 or message.sequence == 0 or message.width != 320 or message.height != 240) return error.InvalidMessage,
        abi.display.peer_closed => if (message.surface != 0 or message.width != 0 or message.height != 0) return error.InvalidMessage,
        abi.display.heartbeat => if (message.surface != 0 or message.width != 0 or message.height != 0 or message.sequence == 0) return error.InvalidMessage,
        else => return error.InvalidMessage,
    }
}
pub fn validateInput(event: *const abi.DisplayInput) Error!void {
    if (event.kind == 0 or event.kind > 8 or event.code > 65535 or event.modifiers & ~@as(u32, 31) != 0 or event.reserved != 0 or event.sequence == 0)
        return error.InvalidInput;
}
test "client rejects forged service peers surfaces and unused payload" {
    var message: abi.ServiceMessage = .{ .kind = abi.display.ack, .peer_pid = 9, .peer_app = abi.display.server, .sequence = 1 };
    try validateClient(&message, 9);
    message.peer_app = abi.display.client_a;
    try std.testing.expectError(error.InvalidMessage, validateClient(&message, 9));
    message.peer_app = abi.display.server;
    message.surface = 7;
    try std.testing.expectError(error.InvalidMessage, validateClient(&message, 9));
    message.surface = 0;
    message.payload[0] = 1;
    try std.testing.expectError(error.InvalidMessage, validateClient(&message, 9));
    message.payload[0] = 0;
    try std.testing.expectError(error.InvalidMessage, validateClient(&message, 8));
}
test "server rejects wrong app identities and malformed frame dimensions" {
    var message: abi.ServiceMessage = .{ .kind = abi.display.frame, .peer_pid = 3, .peer_app = abi.display.client_b, .surface = 11, .sequence = 1, .width = 320, .height = 240 };
    try validateServer(&message);
    message.width = 321;
    try std.testing.expectError(error.InvalidMessage, validateServer(&message));
    message.width = 320;
    message.kind = abi.display.peer_closed;
    try std.testing.expectError(error.InvalidMessage, validateServer(&message));
    message.surface = 0;
    message.width = 0;
    message.height = 0;
    try validateServer(&message);
    message.kind = abi.display.heartbeat;
    try validateServer(&message);
    message.peer_app = 999;
    try std.testing.expectError(error.InvalidMessage, validateServer(&message));
}
test "mapped pixels reject slot aliasing and oversized geometry" {
    _ = try pixels(abi.display.map_base, 0, 320, 240);
    try std.testing.expectError(error.InvalidMapping, pixels(abi.display.map_base, 1, 320, 240));
    try std.testing.expectError(error.InvalidMapping, pixels(abi.display.map_base, 4, 320, 240));
    try std.testing.expectError(error.InvalidGeometry, pixels(abi.display.map_base, 0, 0, 240));
    try std.testing.expectError(error.InvalidGeometry, pixels(abi.display.map_base, 0, 65535, 65535));
}
test "input validation rejects unknown kinds reserved bits and zero sequence" {
    var event: abi.DisplayInput = .{ .kind = 1, .sequence = 1 };
    try validateInput(&event);
    event.kind = 9;
    try std.testing.expectError(error.InvalidInput, validateInput(&event));
    event.kind = 1;
    event.modifiers = 32;
    try std.testing.expectError(error.InvalidInput, validateInput(&event));
}
