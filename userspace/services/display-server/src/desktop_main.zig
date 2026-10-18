//! Native user-space desktop compositor. Clients supply bounded RO snapshots;
//! this process owns caches, window policy, focused input and composed scanout.
const std = @import("std");
const builtin = @import("builtin");
const ui = @import("axisui");
const windows = @import("window_server");
const shell = @import("desktop_shell");
const runtime = @import("userspace_runtime");
const abi = @import("bedrock64");
const policy_module = @import("desktop_policy.zig");
const Policy = policy_module.Policy;
const files_index = policy_module.files_index;
const shell_index = policy_module.shell_index;
pub const panic = std.debug.FullPanic(runtime.panic);

const State = enum(u64) { ready = 1, minimized = 2, closed = 3, relaunched = 4, maximized = 5, fullscreen = 6, restored = 7 };
const Outbound = struct {
    ack: ?abi.ServiceMessage = null,
    configure: bool = false,
    close: bool = false,
    events: ui.Queue(32) = .{},
    fn push(self: *Outbound, event: ui.Event) void {
        policy_module.queueInput(&self.events, event);
    }
};
var policy: Policy = undefined;
var outputs: [2]Outbound = .{ .{}, .{} };
var caches: [2]ui.Surface = undefined;
var screen: ui.Surface = undefined;
var screen_token: u64 = 0;
var backdrop: ui.Backdrop = undefined;
var blur_colors: [160 * 100]u32 = undefined;
var blur_scratch: [160 * 100]u32 = undefined;
var workspace: ui.Workspace = undefined;
var heartbeat: abi.DesktopHeartbeat = .{};
var dirty = true;
var tick: u64 = 0;
var control_sequence: u64 = 0;
var initial_ready = false;
var pending_window_state: ?State = null;
var pending_closed_state = false;
var relaunch_state = false;

fn expectedDisconnect(result: u64) bool {
    return result == abi.errno.bad_descriptor or result == abi.errno.broken_pipe or result == abi.errno.no_process;
}
fn send(endpoint: u64, message: *const abi.ServiceMessage) bool {
    const result = runtime.serviceSend(endpoint, message);
    if (result == 0 or expectedDisconnect(result)) return true;
    runtime.expect(result == abi.errno.again);
    return false;
}
fn nextControlSequence() u64 {
    runtime.expect(control_sequence < std.math.maxInt(u64));
    control_sequence += 1;
    return control_sequence;
}
fn logPid(label: []const u8, pid: u64) void {
    var buffer: [100]u8 = undefined;
    runtime.write(std.fmt.bufPrint(&buffer, "{s}{x}\n", .{ label, pid }) catch runtime.exit(99));
}
fn createSurface(display: abi.DisplayInfo, slot: u64) struct { token: u64, surface: ui.Surface } {
    const creation: abi.SurfaceCreate = .{ .width = display.width, .height = display.height };
    const token = runtime.success(runtime.surfaceCreate(&creation));
    const address = runtime.success(runtime.surfaceMap(token, slot, true));
    const pixels = runtime.display_wire.pixels(address, slot, display.width, display.height) catch runtime.exit(99);
    const surface = ui.Surface.init(pixels, display.width, display.height, display.width, .{ .red = 0xff0000, .green = 0xff00, .blue = 0xff }) catch runtime.exit(99);
    return .{ .token = token, .surface = surface };
}
fn flush(endpoint: u64) void {
    for (&outputs, 0..) |*out, i| {
        const peer = policy.peers[i];
        if (peer.pid == 0) continue;
        if (out.close) {
            const close: abi.ServiceMessage = .{ .kind = abi.display.close, .peer_pid = peer.pid, .peer_app = peer.app, .sequence = nextControlSequence() };
            if (!send(endpoint, &close)) continue;
            out.close = false;
            out.configure = false;
            out.events.clear();
        }
        if (out.configure) {
            const configuration = policy.configurationMessage(i);
            if (!send(endpoint, &configuration)) continue;
            out.configure = false;
        }
        // Publish invalidation before acknowledging an older snapshot. A
        // current frame's ACK is flushed only after composing and presenting.
        // Obsolete snapshots still get their exact ACK so clients can retire.
        if (out.ack) |ack| {
            if (!send(endpoint, &ack)) continue;
            out.ack = null;
        }
        for (0..8) |_| {
            if (out.events.len == 0) break;
            var message: abi.ServiceMessage = .{ .kind = abi.display.input, .peer_pid = peer.pid, .peer_app = peer.app, .sequence = nextControlSequence() };
            std.mem.writeInt(u64, message.payload[0..8], out.events.records[out.events.head], .little);
            if (!send(endpoint, &message)) break;
            _ = out.events.pop();
        }
    }
}
fn applyChange(change: policy_module.Change) void {
    if (change.configure_files) {
        outputs[files_index].configure = true;
        outputs[files_index].events.clear();
    }
    if (change.close_files) {
        outputs[files_index].close = true;
        outputs[files_index].configure = false;
        outputs[files_index].events.clear();
    }
    if (change.routed) |routed| outputs[routed.index].push(routed.event);
    dirty = dirty or change.compose;
    if (change.minimized) {
        pending_window_state = .minimized;
        logPid("[desktop-server] Files minimized pid=", policy.peers[files_index].pid);
    }
    if (change.restored) {
        pending_window_state = .restored;
        logPid("[desktop-server] Files restored pid=", policy.peers[files_index].pid);
    }
}
fn receive(message: *const abi.ServiceMessage) void {
    if (message.kind == abi.display.frame) {
        // Retire every read lease, including malformed and obsolete frames.
        // Only a bound peer gets an ACK addressed to its authenticated PID.
        const peer_index: ?usize = policy.boundPeer(message.peer_app, message.peer_pid) catch null;
        if (message.surface != 0) {
            if (policy.frame(message)) |i| {
                if (outputs[i].ack == null) {
                    const address = runtime.success(runtime.surfaceMap(message.surface, 0, false));
                    const pixels = runtime.display_wire.pixels(address, 0, message.width, message.height) catch runtime.exit(99);
                    policy_module.copyViewport(caches[i].pixels, pixels, policy.peers[i].configuration.?) catch runtime.exit(99);
                    policy.commitFrame(i, message.sequence);
                    if (i == files_index) heartbeat.files_frames += 1 else heartbeat.shell_frames += 1;
                    dirty = true;
                }
            } else |_| {}
            runtime.expect(runtime.surfaceRelease(message.surface) == 0);
        }
        if (peer_index) |i| {
            if (message.sequence != 0 and outputs[i].ack == null) {
                outputs[i].ack = .{ .kind = abi.display.ack, .peer_pid = message.peer_pid, .peer_app = message.peer_app, .sequence = message.sequence };
            }
        }
        return;
    }
    policy_module.controlMessage(message) catch {
        if (message.surface != 0) _ = runtime.surfaceRelease(message.surface);
        return;
    };
    switch (message.kind) {
        abi.display.heartbeat => {
            const prior_pid = policy.peers[Policy.index(message.peer_app) catch unreachable].pid;
            const i = policy.hello(message.peer_app, message.peer_pid) catch return;
            if (prior_pid == 0) {
                outputs[i] = .{ .configure = true };
                if (i == files_index) {
                    heartbeat.files_frames = 0;
                    relaunch_state = initial_ready;
                    // The old generation is already retired. A new hello can
                    // race its diagnostic when init restarts a crashed client.
                    pending_closed_state = false;
                }
                dirty = true;
            }
        },
        abi.display.peer_closed => {
            const i = policy.closed(message.peer_app, message.peer_pid) catch return;
            outputs[i] = .{};
            if (i == files_index) {
                heartbeat.files_frames = 0;
                pending_closed_state = true;
                pending_window_state = null;
                logPid("[desktop-server] Files disconnected pid=", message.peer_pid);
            } else heartbeat.shell_frames = 0;
            dirty = true;
        },
        abi.display.launch => applyChange(policy.launch(message.peer_app, message.peer_pid) catch return),
        else => unreachable,
    }
}
fn pollInput() void {
    for (0..16) |_| {
        var input: abi.DisplayInput = .{};
        const received = runtime.displayInput(&input);
        if (received == abi.errno.again) break;
        runtime.expect(received == 0);
        runtime.display_wire.validateInput(&input) catch runtime.exit(99);
        const event: ui.Event = .{ .kind = @fromBackingInt(@as(u8, @intCast(input.kind))), .code = @intCast(input.code), .modifiers = @intCast(input.modifiers), .x = @intCast(std.math.clamp(input.x, -32768, 32767)), .y = @intCast(std.math.clamp(input.y, -32768, 32767)) };
        const prior_mode = policy.window.mode;
        applyChange(policy.input(event, tick) catch runtime.exit(99));
        if (prior_mode != policy.window.mode) {
            pending_window_state = if (prior_mode == .fullscreen) .restored else switch (policy.window.mode) {
                .maximized => .maximized,
                .fullscreen => .fullscreen,
                .floating => .restored,
            };
        }
    }
}
fn copyBackground() void {
    for (0..screen.height) |y| for (0..screen.width) |x| {
        const offset = y * @as(usize, screen.stride) + x;
        screen.pixels[offset] = caches[shell_index].pixels[offset];
    };
}
fn compose() void {
    copyBackground();
    if (policy.window.visible and !policy.window.closed) {
        const frame = policy.window.frame();
        if (policy.window.mode != .fullscreen) {
            fill(.{ .x = frame.x + 5, .y = frame.y + 7, .width = frame.width, .height = frame.height }, ui.Color.rgb(36, 38, 47));
            fill(.{ .x = frame.x + 2, .y = frame.y + 3, .width = frame.width, .height = frame.height }, ui.Color.rgb(31, 33, 41));
        }
        fill(frame, if (policy.window.focused) ui.Color.rgb(84, 75, 89) else ui.Color.rgb(60, 63, 74));
        const border = policy.window.borderWidth();
        frost(.{ .x = frame.x + @as(i32, @intCast(border)), .y = frame.y + @as(i32, @intCast(border)), .width = frame.width - border * 2, .height = frame.height - border * 2 }, .{ .tint = ui.Color.rgb(26, 27, 35), .opacity = 178 });
        if (policy.peers[files_index].cache_valid) {
            policy_module.blitViewport(screen.pixels, caches[files_index].pixels, policy.peers[files_index].configuration.?) catch runtime.exit(99);
        }
        drawChrome();
    }
    ui.drawCursor(&screen, policy.cursor, ui.Color.rgb(222, 232, 241)) catch runtime.exit(99);
    runtime.expect(heartbeat.presents < std.math.maxInt(u64));
    heartbeat.presents += 1;
    const present: abi.PresentRequest = .{ .surface_token = screen_token, .x = 0, .y = 0, .width = screen.width, .height = screen.height, .sequence = heartbeat.presents };
    runtime.expect(runtime.displayPresent(&present) == 0);
    dirty = false;
}
fn stateReport(state: State) bool {
    const result = runtime.syscall(abi.syscall.desktop_state, @backingInt(state), 0, 0);
    runtime.expect(result == 0 or result == abi.errno.again);
    return result == 0;
}
fn reportStates() void {
    if (pending_closed_state and stateReport(.closed)) pending_closed_state = false;
    const both_frames = policy.peers[files_index].cache_valid and policy.peers[shell_index].cache_valid;
    if (!initial_ready and both_frames and stateReport(.ready)) {
        initial_ready = true;
    } else if (relaunch_state and both_frames and stateReport(.relaunched)) relaunch_state = false;
    if (pending_window_state) |state| {
        if (policy.peers[files_index].pid != 0 and (state == .minimized or policy.peers[files_index].cache_valid) and
            stateReport(state)) pending_window_state = null;
    }
}
fn drawChrome() void {
    const window = policy.window;
    const title = window.title();
    frost(title, .{ .tint = ui.Color.rgb(29, 31, 41), .opacity = 180 });
    const label: []const u8 = if (window.hovered) |control| switch (control) {
        .close => "Close Files",
        .minimize => "Minimize",
        .maximize => if (window.mode == .maximized) "Restore" else "Maximize",
        .fullscreen => if (window.mode == .fullscreen) "Exit full screen" else "Full screen",
    } else "Files";
    text(title.x + @as(i32, @intCast((title.width - @as(u32, @intCast(label.len)) * ui.font.advance) / 2)), title.y + 12, label, ui.Color.rgb(225, 221, 228));
    for (window.controls()) |item| {
        const rect = item.rect;
        const cx = rect.x + @as(i32, @intCast(rect.width / 2));
        const cy = rect.y + @as(i32, @intCast(rect.height / 2));
        if (window.hovered == item.control or window.pressed_control == item.control)
            fill(.{ .x = rect.x + 1, .y = rect.y + 1, .width = rect.width - 2, .height = rect.height - 2 }, ui.Color.rgb(48, 49, 62));
        const ink = ui.Color.rgb(32, 34, 44);
        switch (item.control) {
            .close => {
                circle(cx, cy, 6, ui.Color.rgb(213, 150, 172));
                text(cx - 2, cy - 4, "x", ink);
            },
            .minimize => {
                circle(cx, cy, 6, ui.Color.rgb(225, 209, 172));
                fill(.{ .x = cx - 3, .y = cy, .width = 6, .height = 1 }, ink);
            },
            .maximize => {
                circle(cx, cy, 6, ui.Color.rgb(143, 177, 197));
                fill(.{ .x = cx - 3, .y = cy - 3, .width = 7, .height = 7 }, ink);
                fill(.{ .x = cx - 2, .y = cy - 2, .width = 5, .height = 5 }, ui.Color.rgb(143, 177, 197));
            },
            .fullscreen => {
                const icon = ui.Color.rgb(155, 159, 179);
                for ([_]i32{ -1, 1 }) |dx| for ([_]i32{ -1, 1 }) |dy| {
                    const corner_x = cx + dx * 4;
                    const corner_y = cy + dy * 4;
                    fill(.{ .x = corner_x - @as(i32, if (dx < 0) 0 else 3), .y = corner_y, .width = 4, .height = 1 }, icon);
                    fill(.{ .x = corner_x, .y = corner_y - @as(i32, if (dy < 0) 0 else 3), .width = 1, .height = 4 }, icon);
                };
            },
        }
    }
    fill(.{ .x = title.x, .y = title.y + @as(i32, @intCast(title.height)) - 1, .width = title.width, .height = 1 }, ui.Color.rgb(48, 50, 62));
}
fn fill(rect: ui.Rect, color: ui.Color) void {
    if (rect.x < 0 or rect.y < 0) return;
    screen.fillRect(@intCast(rect.x), @intCast(rect.y), rect.width, rect.height, screen.encode(color));
}
fn frost(rect: ui.Rect, material: ui.Material) void {
    if (rect.x < 0 or rect.y < 0) return;
    screen.materialRect(@intCast(rect.x), @intCast(rect.y), rect.width, rect.height, material);
}
fn circle(cx: i32, cy: i32, radius: i32, color: ui.Color) void {
    const pixel = screen.encode(color);
    var dy = -radius;
    while (dy <= radius) : (dy += 1) {
        var dx = -radius;
        while (dx <= radius) : (dx += 1) {
            if (dx * dx + dy * dy <= radius * radius and cx + dx >= 0 and cy + dy >= 0)
                screen.putPixel(@intCast(cx + dx), @intCast(cy + dy), pixel);
        }
    }
}
fn text(x: i32, y: i32, value: []const u8, color: ui.Color) void {
    const pixel = screen.encode(color);
    for (value, 0..) |byte, index| {
        const glyph = ui.font.glyph(byte);
        for (glyph, 0..) |row, gy| for (0..ui.font.glyph_width) |gx| {
            if (row & (@as(u8, 1) << @as(u3, @intCast(ui.font.glyph_width - 1 - gx))) == 0) continue;
            const px = x + @as(i32, @intCast(index * ui.font.advance + gx));
            const py = y + @as(i32, @intCast(gy + ui.font.offset_y));
            if (px >= 0 and py >= 0) screen.putPixel(@intCast(px), @intCast(py), pixel);
        };
    }
}
export fn bedrock_user_main(parent: u64, inherited: u64, argument: u64) callconv(.c) noreturn {
    runtime.markEntry();
    const startup = runtime.startup(parent, inherited, argument) catch runtime.exit(99);
    runtime.expect(parent != 0 and inherited != 0 and argument == 0 and startup.app_id == abi.display.server);
    runtime.expect(std.mem.eql(u8, runtime.startup_record.environment(startup, "BEDROCK_ROLE") orelse "", "display-server"));
    const endpoint = runtime.success(runtime.serviceOpen(abi.display.service));
    var display: abi.DisplayInfo = .{};
    runtime.expect(runtime.displayInfo(&display) == 0 and display.width >= 800 and display.width <= 1280 and
        display.height >= 600 and display.height <= 800 and display.format == abi.display.format and display.reserved == 0);
    policy = Policy.init(display.width, display.height) catch runtime.exit(99);
    caches[files_index] = createSurface(display, 1).surface;
    caches[shell_index] = createSurface(display, 2).surface;
    const composed = createSurface(display, 3);
    screen = composed.surface;
    screen_token = composed.token;
    // Cache wallpaper before any chrome, bar, app pixels or pointer are drawn.
    shell.renderWallpaper(&screen) catch runtime.exit(99);
    const count = ui.Backdrop.requiredLen(display.width, display.height) catch runtime.exit(99);
    backdrop = ui.Backdrop.build(&screen, blur_colors[0..count], blur_scratch[0..count]) catch runtime.exit(99);
    screen.setBackdrop(&backdrop, .{ .x = 0, .y = 0 }) catch runtime.exit(99);
    caches[shell_index].setBackdrop(&backdrop, .{ .x = 0, .y = 0 }) catch runtime.exit(99);
    for (0..screen.height) |y| for (0..screen.width) |x| {
        const offset = y * @as(usize, screen.stride) + x;
        caches[shell_index].pixels[offset] = screen.pixels[offset];
    };
    shell.renderBarWithWorkspace(&caches[shell_index], &workspace, @tagName(builtin.cpu.arch)) catch runtime.exit(99);
    heartbeat.server_pid = startup.pid;
    compose();
    runtime.write("[desktop-server] native desktop compositor ready\n");
    while (true) {
        flush(endpoint);
        for (0..32) |_| {
            var message: abi.ServiceMessage = .{};
            const result = runtime.serviceReceive(endpoint, &message);
            if (result == abi.errno.again) break;
            runtime.expect(result == 0);
            receive(&message);
        }
        pollInput();
        if (dirty) compose();
        flush(endpoint);
        reportStates();
        heartbeat.shell_pid = policy.peers[shell_index].pid;
        heartbeat.files_pid = policy.peers[files_index].pid;
        heartbeat.launch_requests = policy.launch_requests;
        heartbeat.files_closed = policy.files_closed;
        heartbeat.configure_sequence = policy.configure_sequence;
        const sent = runtime.writeFd(inherited, std.mem.asBytes(&heartbeat));
        runtime.expect(sent == @sizeOf(abi.DesktopHeartbeat) or sent == abi.errno.again);
        runtime.expect(runtime.syscall(abi.syscall.sleep, 1, 0, 0) == 0);
        tick +%= 1;
    }
}
