//! Pure checks shared by the authenticated display broker and native tests.
//! Window IDs select an owning process's window; they never identify a peer.
const std = @import("std");
const abi = @import("bedrock64");

pub fn validateFlags(window_runtime: bool, is_server: bool, app: u64, message: *const abi.ServiceMessage) !void {
    const capabilities = window_runtime and
        ((is_server and message.kind == abi.display.configure and message.peer_app != abi.display.shell) or
            (!is_server and message.kind == abi.display.create_window and app != abi.display.shell));
    const tagged = window_runtime and if (is_server)
        message.peer_app == abi.display.files and switch (message.kind) {
            abi.display.ack, abi.display.input, abi.display.close, abi.display.configure, abi.display.window_rejected => true,
            else => false,
        }
    else
        app == abi.display.files and switch (message.kind) {
            abi.display.create_window, abi.display.resize_window, abi.display.focus_window, abi.display.close_window, abi.display.move_window, abi.display.retire_window => true,
            else => false,
        };
    const mask: u32 = (if (capabilities) abi.display.header_content | abi.display.header_tabs else 0) |
        (if (tagged) abi.display.window_id_mask else 0);
    if (message.flags & ~mask != 0 or
        (message.flags & abi.display.header_tabs != 0 and message.flags & abi.display.header_content == 0)) return error.PermissionDenied;
}
pub fn surfaceWindowId(window_runtime: bool, is_server: bool, app: u64, reserved: u32) !u16 {
    if (reserved > std.math.maxInt(u16) or (reserved != 0 and (!window_runtime or is_server or app != abi.display.files))) return error.InvalidGeometry;
    return @intCast(reserved);
}
pub fn frameFlags(window_id: u16) u32 {
    return @as(u32, window_id) << abi.display.window_id_shift;
}
pub fn producerLimit(window_runtime: bool, desktop_runtime: bool, is_server: bool, app: u64) usize {
    if (desktop_runtime and is_server) return if (window_runtime) 6 else 3;
    return if (window_runtime and app == abi.display.files) 4 else 1;
}
pub fn validateMove(message: *const abi.ServiceMessage) !void {
    if (message.sequence == 0 or message.width != 0 or message.height != 0) return error.PermissionDenied;
    for (message.payload[8..]) |byte| if (byte != 0) return error.PermissionDenied;
}
pub const validateRejected = validateMove;
pub fn sceneSurfaceCount(files: usize, notes: usize) !usize {
    if (files > 4 or notes > 1) return error.SurfaceCapacity;
    return 2 + 2 * (files + notes); // Scene, shell producer, cache+producer/window.
}

test "window tags stay scoped to Files directions kinds and window runtime" {
    var message: abi.ServiceMessage = .{ .kind = abi.display.create_window, .flags = frameFlags(7) | abi.display.header_content | abi.display.header_tabs };
    try validateFlags(true, false, abi.display.files, &message);
    try std.testing.expectError(error.PermissionDenied, validateFlags(false, false, abi.display.files, &message));
    try std.testing.expectError(error.PermissionDenied, validateFlags(true, false, abi.display.notes, &message));
    message.flags = abi.display.header_tabs;
    try std.testing.expectError(error.PermissionDenied, validateFlags(true, false, abi.display.files, &message));
    message.flags = frameFlags(7);
    for ([_]u32{ abi.display.resize_window, abi.display.focus_window, abi.display.close_window, abi.display.move_window, abi.display.retire_window }) |kind| {
        message.kind = kind;
        try validateFlags(true, false, abi.display.files, &message);
    }
    message.kind = abi.display.heartbeat;
    try std.testing.expectError(error.PermissionDenied, validateFlags(true, false, abi.display.files, &message));
    for ([_]u32{ abi.display.ack, abi.display.input, abi.display.close, abi.display.configure, abi.display.window_rejected }) |kind| {
        message.kind = kind;
        message.peer_app = abi.display.files;
        try validateFlags(true, true, abi.display.server, &message);
        message.peer_app = abi.display.notes;
        try std.testing.expectError(error.PermissionDenied, validateFlags(true, true, abi.display.server, &message));
    }
    message.kind = abi.display.configure;
    message.flags = abi.display.header_content | abi.display.header_tabs;
    try validateFlags(true, true, abi.display.server, &message);
    message.kind = abi.display.ack;
    try std.testing.expectError(error.PermissionDenied, validateFlags(true, true, abi.display.server, &message));
}
test "surface window IDs quotas and scene accounting remain bounded" {
    try std.testing.expectEqual(@as(u16, 65535), try surfaceWindowId(true, false, abi.display.files, 65535));
    for ([_]u64{ abi.display.notes, abi.display.shell, abi.display.server }) |app| try std.testing.expectError(error.InvalidGeometry, surfaceWindowId(true, false, app, 1));
    try std.testing.expectError(error.InvalidGeometry, surfaceWindowId(true, true, abi.display.files, 1));
    try std.testing.expectError(error.InvalidGeometry, surfaceWindowId(false, false, abi.display.files, 1));
    try std.testing.expectError(error.InvalidGeometry, surfaceWindowId(true, false, abi.display.files, 65536));
    try std.testing.expectEqual(@as(usize, 4), producerLimit(true, true, false, abi.display.files));
    try std.testing.expectEqual(@as(usize, 1), producerLimit(true, true, false, abi.display.notes));
    try std.testing.expectEqual(@as(usize, 6), producerLimit(true, true, true, abi.display.server));
    try std.testing.expectEqual(@as(usize, 3), producerLimit(false, true, true, abi.display.server));
    try std.testing.expectEqual(@as(usize, 6), try sceneSurfaceCount(1, 1));
    try std.testing.expectEqual(@as(usize, 12), try sceneSurfaceCount(4, 1));
    try std.testing.expectEqual(@as(usize, 4), try sceneSurfaceCount(1, 0));
    try std.testing.expectError(error.SurfaceCapacity, sceneSurfaceCount(5, 0));
}
test "move coordinates and rejection reasons cannot carry extra payload or dimensions" {
    var message: abi.ServiceMessage = .{ .sequence = 1 };
    std.mem.writeInt(i32, message.payload[0..4], -120, .little);
    std.mem.writeInt(i32, message.payload[4..8], 900, .little);
    try validateMove(&message);
    try validateRejected(&message);
    message.payload[8] = 1;
    try std.testing.expectError(error.PermissionDenied, validateMove(&message));
    try std.testing.expectError(error.PermissionDenied, validateRejected(&message));
    message.payload[8] = 0;
    message.width = 1;
    try std.testing.expectError(error.PermissionDenied, validateMove(&message));
    message.width = 0;
    message.sequence = 0;
    try std.testing.expectError(error.PermissionDenied, validateRejected(&message));
}
