//! Installed desktop messages; the earlier surface demo keeps its own decoder.
const std = @import("std");
const abi = @import("bedrock64");
pub const Error = error{ InvalidDesktopMessage, InvalidDesktopGeometry, StaleConfigure, InvalidFrameSequence };
pub const Config = struct { sequence: u32, width: u32, height: u32, screen_width: u32, screen_height: u32, origin_x: i32, origin_y: i32 };
fn zero(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != 0) return false;
    return true;
}
pub fn decode(message: *const abi.ServiceMessage, server_pid: ?u64) Error!void {
    if (message.flags != 0 or message.peer_app != abi.display.server or message.peer_pid == 0 or message.surface != 0 or message.sequence == 0) return error.InvalidDesktopMessage;
    if (server_pid) |pid| if (message.peer_pid != pid) return error.InvalidDesktopMessage;
    switch (message.kind) {
        abi.display.configure => _ = try configuration(message),
        abi.display.input => {
            if (message.width != 0 or message.height != 0 or !zero(message.payload[8..])) return error.InvalidDesktopMessage;
            const raw = std.mem.readInt(u64, message.payload[0..8], .little);
            if (@as(u8, @truncate(raw)) == 0 or @as(u8, @truncate(raw)) > 8 or @as(u8, @truncate(raw >> 8)) & ~@as(u8, 31) != 0) return error.InvalidDesktopMessage;
        },
        abi.display.ack, abi.display.close => if (message.width != 0 or message.height != 0 or !zero(&message.payload)) return error.InvalidDesktopMessage,
        else => return error.InvalidDesktopMessage,
    }
}
pub fn configuration(message: *const abi.ServiceMessage) Error!Config {
    if (message.kind != abi.display.configure or message.sequence == 0 or message.sequence > std.math.maxInt(u32)) return error.InvalidDesktopMessage;
    const screen_width = std.mem.readInt(u32, message.payload[0..4], .little);
    const screen_height = std.mem.readInt(u32, message.payload[4..8], .little);
    const x = std.mem.readInt(i32, message.payload[8..12], .little);
    const y = std.mem.readInt(i32, message.payload[12..16], .little);
    if (screen_width < 800 or screen_width > 1280 or screen_height < 600 or screen_height > 800 or
        ((message.width == 0) != (message.height == 0)) or message.width > screen_width or message.height > screen_height or x < 0 or y < 0 or
        @as(u64, @intCast(x)) + message.width > screen_width or @as(u64, @intCast(y)) + message.height > screen_height) return error.InvalidDesktopGeometry;
    return .{ .sequence = @intCast(message.sequence), .width = message.width, .height = message.height, .screen_width = screen_width, .screen_height = screen_height, .origin_x = x, .origin_y = y };
}
pub fn configure(sequence: u32, width: u32, height: u32, screen_width: u32, screen_height: u32, origin_x: i32, origin_y: i32) abi.ServiceMessage {
    var result: abi.ServiceMessage = .{ .kind = abi.display.configure, .sequence = sequence, .width = width, .height = height };
    std.mem.writeInt(u32, result.payload[0..4], screen_width, .little);
    std.mem.writeInt(u32, result.payload[4..8], screen_height, .little);
    std.mem.writeInt(i32, result.payload[8..12], origin_x, .little);
    std.mem.writeInt(i32, result.payload[12..16], origin_y, .little);
    return result;
}
pub fn frameSequence(configure_sequence: u32, counter: u32) Error!u64 {
    if (configure_sequence == 0 or counter == 0) return error.InvalidFrameSequence;
    return (@as(u64, configure_sequence) << 32) | counter;
}
test "desktop configure bounds and encoded frame epoch are explicit" {
    var message = configure(7, 720, 400, 1280, 800, 20, 70);
    message.peer_app = abi.display.server;
    message.peer_pid = 9;
    try decode(&message, 9);
    const cfg = try configuration(&message);
    try std.testing.expectEqual(@as(i32, 20), cfg.origin_x);
    try std.testing.expectEqual(@as(u64, 0x700000001), try frameSequence(cfg.sequence, 1));
    message.width = 1280;
    try std.testing.expectError(error.InvalidDesktopGeometry, decode(&message, 9));
    message.width = 720;
    message.sequence = @as(u64, std.math.maxInt(u32)) + 1;
    try std.testing.expectError(error.InvalidDesktopMessage, decode(&message, 9));
}
test "desktop rejects forged sender and reserved bytes in input and close" {
    var message: abi.ServiceMessage = .{ .kind = abi.display.close, .peer_pid = 8, .peer_app = abi.display.server, .sequence = 1 };
    try decode(&message, 8);
    message.payload[0] = 1;
    try std.testing.expectError(error.InvalidDesktopMessage, decode(&message, 8));
    message.payload[0] = 0;
    message.peer_app = abi.display.shell;
    try std.testing.expectError(error.InvalidDesktopMessage, decode(&message, 8));
    try std.testing.expectError(error.InvalidFrameSequence, frameSequence(0, 1));
}
test "hidden configuration carries the same screen and cannot have a partial viewport" {
    var message = configure(3, 0, 0, 1280, 800, 160, 72);
    const cfg = try configuration(&message);
    try std.testing.expectEqual(@as(u32, 0), cfg.width);
    message.height = 10;
    try std.testing.expectError(error.InvalidDesktopGeometry, configuration(&message));
}
