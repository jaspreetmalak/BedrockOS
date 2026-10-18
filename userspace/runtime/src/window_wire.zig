//! Native window messages; frame grants retain the established configure epoch.
const std = @import("std");
const abi = @import("bedrock64");
const desktop = @import("desktop_wire.zig");
pub const header = @import("window_header");
pub const Config = struct {
    sequence: u32,
    width: u32,
    height: u32,
    screen_width: u32,
    screen_height: u32,
    origin_x: i32,
    origin_y: i32,
    header_content: bool = false,
    header_tabs: bool = false,
    window_id: u16 = 0,
};
pub const Error = desktop.Error || error{ InvalidWindowMessage, InvalidWindowOptions, InvalidHeaderGeometry };
pub const configure = desktop.configure;
pub const frameSequence = desktop.frameSequence;
pub const WindowOptions = struct {
    title: []const u8,
    preferred_width: u32 = 640,
    preferred_height: u32 = 420,
    header_content: bool = false,
    header_tabs: bool = false,
    window_id: u16 = 0,
};
pub fn windowId(flags: u32) u16 {
    return @truncate(flags >> abi.display.window_id_shift);
}
pub fn flagsFor(id: u16, capabilities: u32) u32 {
    return (@as(u32, id) << abi.display.window_id_shift) | capabilities;
}
pub const Status = struct { sequence: u64, workspace: u32, tiled: bool, focused_pid: u64 };
pub fn create(options: WindowOptions) Error!abi.ServiceMessage {
    if (options.title.len == 0 or options.title.len > 16 or options.preferred_width == 0 or options.preferred_height == 0) return error.InvalidWindowOptions;
    const capabilities: u32 = (if (options.header_content or options.header_tabs) abi.display.header_content else 0) | (if (options.header_tabs) abi.display.header_tabs else 0);
    var result: abi.ServiceMessage = .{ .kind = abi.display.create_window, .sequence = 1, .width = options.preferred_width, .height = options.preferred_height, .flags = flagsFor(options.window_id, capabilities) };
    for (options.title, 0..) |byte, i| {
        if (byte < 32 or byte > 126) return error.InvalidWindowOptions;
        result.payload[i] = byte;
    }
    return result;
}
pub fn status(message: *const abi.ServiceMessage) Error!Status {
    if (message.kind != abi.display.window_status or message.width >= 4 or message.height > 1) return error.InvalidWindowMessage;
    for (message.payload[8..]) |byte| if (byte != 0) return error.InvalidWindowMessage;
    return .{ .sequence = message.sequence, .workspace = message.width, .tiled = message.height != 0, .focused_pid = std.mem.readInt(u64, message.payload[0..8], .little) };
}
pub fn decode(message: *const abi.ServiceMessage, server_pid: ?u64) Error!void {
    if (message.kind == abi.display.configure) {
        if (message.peer_app != abi.display.server or message.peer_pid == 0 or message.surface != 0 or message.sequence == 0) return error.InvalidDesktopMessage;
        if (server_pid) |pid| if (message.peer_pid != pid) return error.InvalidDesktopMessage;
        _ = try configuration(message);
        return;
    }
    if (message.kind == abi.display.window_rejected) {
        if (message.flags & ~abi.display.window_id_mask != 0 or message.peer_app != abi.display.server or message.peer_pid == 0 or message.surface != 0 or message.sequence == 0 or message.width != 0 or message.height != 0) return error.InvalidWindowMessage;
        if (server_pid) |pid| if (message.peer_pid != pid) return error.InvalidWindowMessage;
        for (message.payload[8..]) |byte| if (byte != 0) return error.InvalidWindowMessage;
        return;
    }
    if (message.kind != abi.display.window_status) {
        var untagged = message.*;
        untagged.flags &= ~abi.display.window_id_mask;
        return desktop.decode(&untagged, server_pid);
    }
    if (message.flags != 0 or message.peer_app != abi.display.server or message.peer_pid == 0 or message.surface != 0 or message.sequence == 0) return error.InvalidWindowMessage;
    if (server_pid) |pid| if (message.peer_pid != pid) return error.InvalidWindowMessage;
    _ = try status(message);
}
pub fn configuration(message: *const abi.ServiceMessage) Error!Config {
    if (message.flags & ~(abi.display.header_content | abi.display.header_tabs | abi.display.window_id_mask) != 0 or
        (message.flags & abi.display.header_tabs != 0 and message.flags & abi.display.header_content == 0)) return error.InvalidWindowMessage;
    const cfg = try desktop.configuration(message);
    const integrated = message.flags & abi.display.header_content != 0;
    if (integrated and cfg.width != 0) {
        _ = try header.layoutMode(cfg.width, message.flags & abi.display.header_tabs != 0);
        if (cfg.height < header.height) return error.InvalidHeaderGeometry;
    }
    return .{ .sequence = cfg.sequence, .width = cfg.width, .height = cfg.height, .screen_width = cfg.screen_width, .screen_height = cfg.screen_height, .origin_x = cfg.origin_x, .origin_y = cfg.origin_y, .header_content = integrated, .header_tabs = message.flags & abi.display.header_tabs != 0, .window_id = windowId(message.flags) };
}
test "window create is bounded and leaves authenticated fields clear" {
    const message = try create(.{ .title = "Notes", .preferred_width = 600, .preferred_height = 400 });
    try std.testing.expect(message.kind == 9 and message.peer_pid == 0 and message.peer_app == 0 and message.surface == 0 and message.flags == 0);
    try std.testing.expectEqualStrings("Notes", message.payload[0..5]);
    try std.testing.expectError(error.InvalidWindowOptions, create(.{ .title = "12345678901234567" }));
    try std.testing.expectError(error.InvalidWindowOptions, create(.{ .title = "bad\n" }));
}
test "status rejects forged authority and malformed workspace state" {
    var message: abi.ServiceMessage = .{ .kind = abi.display.window_status, .sequence = 1, .peer_pid = 7, .peer_app = abi.display.server, .width = 3, .height = 1 };
    try decode(&message, 7);
    try std.testing.expect((try status(&message)).tiled);
    message.width = 4;
    try std.testing.expectError(error.InvalidWindowMessage, decode(&message, 7));
    message.width = 0;
    message.peer_pid = 8;
    try std.testing.expectError(error.InvalidWindowMessage, decode(&message, 7));
}
test "integrated caption capability is explicit and constrained to configure messages" {
    const t = std.testing;
    const request = try create(.{ .title = "Files", .header_content = true });
    try t.expectEqual(abi.display.header_content, request.flags);
    var message = configure(7, 316, 236, 800, 600, 48, 72);
    message.peer_app = abi.display.server;
    message.peer_pid = 9;
    message.flags = abi.display.header_content;
    try decode(&message, 9);
    const cfg = try configuration(&message);
    try t.expect(cfg.header_content);
    try t.expectEqual(@as(u32, 66), (try header.layout(cfg.width)).accessory.width);
    message.flags = 2;
    try t.expectError(error.InvalidWindowMessage, decode(&message, 9));
    message.flags = abi.display.header_content;
    message.width = 315;
    try t.expectError(error.InvalidHeaderGeometry, decode(&message, 9));
    message.width = 316;
    message.height = 31;
    try t.expectError(error.InvalidHeaderGeometry, decode(&message, 9));
    message.kind = abi.display.close;
    message.width = 0;
    message.height = 0;
    try t.expectError(error.InvalidDesktopMessage, decode(&message, 9));
}

test "window tags and tabs-only capability round trip without widening control flags" {
    const t = std.testing;
    const request = try create(.{ .title = "Files", .header_tabs = true, .window_id = 65535 });
    try t.expectEqual(@as(u16, 65535), windowId(request.flags));
    try t.expectEqual(abi.display.header_content | abi.display.header_tabs, request.flags & ~abi.display.window_id_mask);
    var message = configure(4, 396, 504, 800, 600, 2, 44);
    message.peer_app = abi.display.server;
    message.peer_pid = 9;
    message.flags = request.flags;
    try decode(&message, 9);
    const cfg = try configuration(&message);
    try t.expect(cfg.header_tabs and cfg.header_content and cfg.window_id == 65535);
    message.kind = abi.display.ack;
    message.width = 0;
    message.height = 0;
    message.payload = @splat(0);
    try t.expectError(error.InvalidDesktopMessage, decode(&message, 9));
    message.flags = flagsFor(65535, 0);
    try decode(&message, 9);
    message.kind = abi.display.window_rejected;
    std.mem.writeInt(u64, message.payload[0..8], abi.errno.no_memory, .little);
    try decode(&message, 9);
    message.payload[8] = 1;
    try t.expectError(error.InvalidWindowMessage, decode(&message, 9));
}
