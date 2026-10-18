//! Native multi-window compositor with retained scene pixels and bounded cursor
//! damage. Shell snapshots retain only their 36-row bar.
const std = @import("std");
const builtin = @import("builtin");
const ui = @import("axisui");
const windows = @import("window_server");
const shell = @import("desktop_shell");
const runtime = @import("userspace_runtime");
const abi = @import("bedrock64");
const rules = @import("window_policy.zig");
const glass = @import("glass_frame.zig");
const cursor = @import("cursor_layer.zig");
const frame_fill = @import("frame_fill.zig");
const wallpaper = @import("wallpaper_cache.zig");
const retained = @import("retained_frame.zig");
const system_bar = shell.system_bar;
// Trusted system menu definitions are configurable independently of app menus.
// The command dispatcher below retains authority for every resulting action.
const system_config: system_bar.Config = .{};
var system_state: system_bar.State = .{};
var system_clock: system_bar.Clock = .{};
var last_clock_minute: ?i64 = null;
// Caller-owned scratch avoids large by-value snapshots on the 16KiB stack.
var corner_snapshot: glass.Corners = undefined;
const Policy = rules.Policy;
pub const panic = std.debug.FullPanic(runtime.panic);
const Ack = struct { sequence: u64, present: u64 };
const Outbound = struct {
    acks: [8]Ack = undefined,
    ack_head: usize = 0,
    ack_len: usize = 0,
    configure: bool = false,
    close: bool = false,
    events: ui.Queue(32) = .{},
    fn push(self: *Outbound, event: ui.Event) void {
        rules.queueInput(&self.events, event);
    }
    fn acknowledge(self: *Outbound, sequence: u64, present: u64) void {
        for (0..self.ack_len) |n| if (self.acks[(self.ack_head + n) % self.acks.len].sequence == sequence) return;
        runtime.expect(self.ack_len < self.acks.len);
        self.acks[(self.ack_head + self.ack_len) % self.acks.len] = .{ .sequence = sequence, .present = present };
        self.ack_len += 1;
    }
};
var policy: Policy = undefined;
var outputs: [rules.capacity + 1]Outbound = @splat(.{});
var cache_tokens: [rules.capacity]u64 = @splat(0);
// Presentation may reuse authenticated local pixels during a translation.
// Epoch acceptance and frame ACKs remain governed by Policy.cache_valid.
var retained_frames: [rules.capacity]retained.Frame = @splat(.{});
var scene: ui.Surface = undefined;
var scene_token: u64 = 0;
var backdrop: ui.Backdrop = undefined;
var blur_colors: [160 * 100]u32 = undefined;
// Blur construction ends before the lossless wallpaper cache is built. Reuse
// its temporary memory so both phases fit the existing 512KiB data allowance.
var background_storage: union { blur: [160 * 100]u32, cache: wallpaper.Cache } = undefined;
// Tightly packed rows, using the actual display width. Never retain a Shell
// full-screen cache: the data image stays within the existing 128-page cap.
var shell_bar: [1280 * 36]u32 = undefined;
var workspace: ui.Workspace = undefined;
var heartbeat: abi.WindowHeartbeat = .{};
var pending_states: [16]?rules.State = @splat(null);
var status_pending = true;
var dirty = true;
var cursor_dirty = false;
var cursor_layer: cursor.Layer = .{};
// Scanout submissions include small cursor regions. The full-scene counter in
// heartbeat remains the frame-ACK fence and never advances on cursor-only work.
var present_sequence: u64 = 0;
var control_sequence: u64 = 0;
var initial_ready = false;
var app_seen: [2]bool = @splat(false);
var relaunch_pending: [2]bool = @splat(false);
var rejected_windows: [8]?abi.ServiceMessage = @splat(null);

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
fn logPeer(label: []const u8, app: u64, pid: u64) void {
    var buffer: [160]u8 = undefined;
    runtime.write(std.fmt.bufPrint(&buffer, "[window-server] {s} app={d} pid={d}\n", .{ label, app, pid }) catch runtime.exit(99));
}
fn logConfigure(i: usize) void {
    const peer = policy.peers[i];
    const cfg = peer.configuration.?;
    const frame = if (i < rules.capacity) policy.entries[i].window.frame() else ui.Rect{ .x = 0, .y = 0, .width = scene.width, .height = scene.height };
    var buffer: [320]u8 = undefined;
    runtime.write(std.fmt.bufPrint(&buffer, "[window-server] configured app={d} pid={d} epoch={d} frame_x={d} frame_y={d} frame_w={d} frame_h={d} visible={d} mode={s} header_content={d} window_id={d} header_tabs={d}\n", .{
        peer.app, peer.pid, cfg.sequence, frame.x, frame.y, frame.width, frame.height, @intFromBool(i == rules.shell_index or policy.visible(i)), if (i < rules.capacity) @tagName(policy.entries[i].window.mode) else "fullscreen", @intFromBool(cfg.header_content), peer.window_id, @intFromBool(cfg.header_tabs),
    }) catch runtime.exit(99));
}
fn createSurface(display: abi.DisplayInfo, slot: u64) struct { token: u64, surface: ui.Surface } {
    const creation: abi.SurfaceCreate = .{ .width = display.width, .height = display.height };
    const token = runtime.success(runtime.surfaceCreate(&creation));
    const address = runtime.success(runtime.surfaceMap(token, slot, true));
    const pixels = runtime.display_wire.pixels(address, slot, display.width, display.height) catch runtime.exit(99);
    return .{ .token = token, .surface = ui.Surface.init(pixels, display.width, display.height, display.width, .{ .red = 0xff0000, .green = 0xff00, .blue = 0xff }) catch runtime.exit(99) };
}
fn ensureCache(i: usize) bool {
    if (cache_tokens[i] != 0) return true;
    const creation: abi.SurfaceCreate = .{ .width = scene.width, .height = scene.height };
    const token = runtime.surfaceCreate(&creation);
    if (abi.isError(token)) return false;
    const address = runtime.surfaceMap(token, 1, true);
    if (abi.isError(address)) {
        runtime.expect(runtime.surfaceClose(token) == 0);
        return false;
    }
    runtime.expect(runtime.surfaceUnmap(token) == 0);
    cache_tokens[i] = token;
    return true;
}
fn cacheSurface(i: usize) ui.Surface {
    runtime.expect(cache_tokens[i] != 0);
    const address = runtime.success(runtime.surfaceMap(cache_tokens[i], 1, true));
    const pixels = runtime.display_wire.pixels(address, 1, scene.width, scene.height) catch runtime.exit(99);
    return ui.Surface.init(pixels, scene.width, scene.height, scene.width, scene.masks) catch runtime.exit(99);
}
fn closeCache(i: usize) void {
    retained_frames[i].invalidate();
    if (cache_tokens[i] != 0) runtime.expect(runtime.surfaceClose(cache_tokens[i]) == 0);
    cache_tokens[i] = 0;
}
fn rejectWindow(message: *const abi.ServiceMessage) void {
    for (&rejected_windows) |*pending| if (pending.* == null) {
        var response: abi.ServiceMessage = .{ .kind = abi.display.window_rejected, .flags = runtime.window_wire.flagsFor(runtime.window_wire.windowId(message.flags), 0), .peer_app = message.peer_app, .peer_pid = message.peer_pid, .sequence = nextControlSequence() };
        std.mem.writeInt(u64, response.payload[0..8], abi.errno.no_memory, .little);
        pending.* = response;
        return;
    };
}
fn flush(endpoint: u64) void {
    for (&outputs, 0..) |*out, i| {
        const peer = policy.peers[i];
        if (peer.pid == 0) continue;
        if (out.close) {
            const close: abi.ServiceMessage = .{ .kind = abi.display.close, .flags = runtime.window_wire.flagsFor(peer.window_id, 0), .peer_pid = peer.pid, .peer_app = peer.app, .sequence = nextControlSequence() };
            if (!send(endpoint, &close)) continue;
            out.close = false;
            out.configure = false;
            out.events.clear();
        }
        if (out.configure) {
            const configuration = policy.configurationMessage(i);
            if (!send(endpoint, &configuration)) continue;
            out.configure = false;
            logConfigure(i);
        }
        // Epoch invalidation precedes obsolete-frame ACKs. Valid snapshots can
        // retire only after their cache has participated in a composed present.
        while (out.ack_len != 0) {
            const pending = out.acks[out.ack_head];
            if (pending.present > heartbeat.presents) break;
            const ack: abi.ServiceMessage = .{ .kind = abi.display.ack, .flags = runtime.window_wire.flagsFor(peer.window_id, 0), .peer_pid = peer.pid, .peer_app = peer.app, .sequence = pending.sequence };
            if (!send(endpoint, &ack)) break;
            out.ack_head = (out.ack_head + 1) % out.acks.len;
            out.ack_len -= 1;
        }
        for (0..8) |_| {
            if (out.events.len == 0) break;
            var message: abi.ServiceMessage = .{ .kind = abi.display.input, .flags = runtime.window_wire.flagsFor(peer.window_id, 0), .peer_pid = peer.pid, .peer_app = peer.app, .sequence = nextControlSequence() };
            std.mem.writeInt(u64, message.payload[0..8], out.events.records[out.events.head], .little);
            if (!send(endpoint, &message)) break;
            _ = out.events.pop();
        }
    }
    for (&rejected_windows) |*pending| if (pending.*) |response| {
        if (send(endpoint, &response)) pending.* = null;
    };
    const shell_peer = policy.peers[rules.shell_index];
    if (status_pending and shell_peer.pid != 0) {
        var status: abi.ServiceMessage = .{ .kind = abi.display.window_status, .peer_pid = shell_peer.pid, .peer_app = shell_peer.app, .sequence = nextControlSequence(), .width = policy.workspace, .height = @intFromBool(policy.tiled[policy.workspace]) };
        std.mem.writeInt(u64, status.payload[0..8], policy.focusedPid(), .little);
        if (send(endpoint, &status)) status_pending = false;
    }
}
fn receiveCapacity() bool {
    for (outputs) |out| if (out.ack_len == out.acks.len) return false;
    return true;
}
fn queueState(state: rules.State) void {
    for (&pending_states) |*pending| if (pending.*) |old| {
        if (old.code == state.code and (old.app == state.app or state.code == 11)) {
            pending.* = state;
            return;
        }
    };
    for (&pending_states) |*pending| if (pending.* == null) {
        pending.* = state;
        return;
    };
    // Repeated motions are coalesced above; at most the bounded window registry
    // can produce state transitions between two reports.
    runtime.exit(99);
}
fn applyChange(change: rules.Change) void {
    for (&outputs, 0..) |*out, i| {
        if (change.configure & rules.bit(i) != 0) {
            out.configure = true;
            out.events.clear();
        }
        if (change.close & rules.bit(i) != 0) {
            out.close = true;
            out.configure = false;
            out.events.clear();
        }
        if (change.redraw & rules.bit(i) != 0 and !out.close and !out.configure) out.push(.{ .kind = .redraw, .code = 1 });
    }
    if (change.routed) |routed| outputs[routed.index].push(routed.event);
    for (change.states) |state| if (state) |value| queueState(value);
    dirty = dirty or change.compose;
    cursor_dirty = cursor_dirty or change.cursor;
    status_pending = status_pending or change.status;
}
fn resetAppFrames(app: u64) void {
    if (app == abi.display.files) heartbeat.files_frames = 0;
    if (app == rules.notes_app) heartbeat.notes_frames = 0;
}
fn receive(message: *const abi.ServiceMessage) void {
    if (message.kind == abi.display.frame) {
        const peer_index: ?usize = policy.boundWindow(message.peer_app, message.peer_pid, runtime.window_wire.windowId(message.flags)) catch null;
        var required_present = heartbeat.presents;
        if (message.surface != 0) {
            if (policy.frame(message)) |i| {
                if (outputs[i].ack_len == 0) {
                    const address = runtime.success(runtime.surfaceMap(message.surface, 0, false));
                    const pixels = runtime.display_wire.pixels(address, 0, message.width, message.height) catch runtime.exit(99);
                    if (i == rules.shell_index) {
                        const count = @as(usize, scene.width) * shell.bar_height;
                        for (0..count) |offset| shell_bar[offset] = pixels[offset];
                    } else {
                        const cache = cacheSurface(i);
                        rules.copyViewport(cache.pixels, pixels, policy.peers[i].configuration.?) catch runtime.exit(99);
                        runtime.expect(runtime.surfaceUnmap(cache_tokens[i]) == 0);
                    }
                    policy.commitFrame(i, message.sequence);
                    if (i < rules.capacity) retained_frames[i].remember(message.peer_app, message.peer_pid, policy.peers[i].configuration.?);
                    if (i == rules.shell_index) heartbeat.shell_frames += 1;
                    if (message.peer_app == abi.display.files) heartbeat.files_frames += 1;
                    if (message.peer_app == rules.notes_app) heartbeat.notes_frames += 1;
                    dirty = true;
                    required_present += 1;
                }
            } else |_| {}
            runtime.expect(runtime.surfaceRelease(message.surface) == 0);
        }
        if (peer_index) |i| if (message.sequence != 0) outputs[i].acknowledge(message.sequence, required_present);
        return;
    }
    if (message.kind == abi.display.create_window) {
        const before = policy.slotForWindow(message.peer_app, message.peer_pid, runtime.window_wire.windowId(message.flags));
        const fresh_process = policy.appPid(message.peer_app) == 0;
        const slot = policy.createSlot(message) catch {
            rejectWindow(message);
            return;
        };
        if (!ensureCache(slot)) {
            rejectWindow(message);
            return;
        }
        const change = policy.create(message) catch {
            logPeer("create rejected", message.peer_app, message.peer_pid);
            if (before == null) closeCache(slot);
            rejectWindow(message);
            return;
        };
        if (before == null) {
            const i = policy.boundWindow(message.peer_app, message.peer_pid, runtime.window_wire.windowId(message.flags)) catch unreachable;
            retained_frames[i].invalidate();
            outputs[i] = .{};
            if (fresh_process) {
                resetAppFrames(message.peer_app);
                if (Policy.appIndex(message.peer_app)) |a| {
                    relaunch_pending[a] = app_seen[a];
                    app_seen[a] = true;
                } else |_| {}
            }
            logPeer("window created", message.peer_app, message.peer_pid);
        }
        applyChange(change);
        return;
    }
    if (message.kind == abi.display.resize_window or message.kind == abi.display.focus_window or message.kind == abi.display.close_window or message.kind == abi.display.move_window or message.kind == abi.display.retire_window) {
        const index = policy.boundWindow(message.peer_app, message.peer_pid, runtime.window_wire.windowId(message.flags)) catch return;
        const change = policy.request(message) catch {
            logPeer("request rejected", message.peer_app, message.peer_pid);
            return;
        };
        if (message.kind == abi.display.retire_window) {
            closeCache(index);
            outputs[index] = .{};
            var bytes: [160]u8 = undefined;
            runtime.write(std.fmt.bufPrint(&bytes, "[window-server] window retired app={d} pid={d} window_id={d}\n", .{ message.peer_app, message.peer_pid, runtime.window_wire.windowId(message.flags) }) catch runtime.exit(99));
        }
        applyChange(change);
        return;
    }
    rules.controlMessage(message) catch {
        if (message.surface != 0) _ = runtime.surfaceRelease(message.surface);
        return;
    };
    switch (message.kind) {
        abi.display.heartbeat => {
            const fresh = policy.helloShell(message.peer_app, message.peer_pid) catch return;
            if (fresh) {
                outputs[rules.shell_index] = .{ .configure = true };
                status_pending = true;
                dirty = true;
                logPeer("shell authenticated", message.peer_app, message.peer_pid);
            }
        },
        abi.display.peer_closed => {
            var disconnected: [rules.capacity + 1]bool = @splat(false);
            for (policy.peers, 0..) |peer, i| disconnected[i] = peer.app == message.peer_app and peer.pid == message.peer_pid;
            const change = policy.closed(message.peer_app, message.peer_pid) catch return;
            for (disconnected, 0..) |closed, i| if (closed) {
                outputs[i] = .{};
                if (i < rules.capacity) closeCache(i);
            };
            for (&pending_states) |*pending| if (pending.*) |state| if (state.app == message.peer_app) {
                pending.* = null;
            };
            resetAppFrames(message.peer_app);
            if (message.peer_app == abi.display.shell) heartbeat.shell_frames = 0;
            logPeer("peer disconnected", message.peer_app, message.peer_pid);
            applyChange(change);
        },
        abi.display.launch => {
            const before = policy.launch_requests;
            applyChange(policy.launch(message.peer_app, message.peer_pid, message.sequence) catch return);
            if (!std.meta.eql(before, policy.launch_requests)) logPeer("launch forwarded", if (message.sequence == 1) abi.display.files else message.sequence, message.peer_pid);
        },
        else => unreachable,
    }
}
fn pollInput() void {
    // Double-click age follows the observed hardware-quantum clock. Composition
    // can take many quanta, so compositor loop counts are not elapsed time.
    const tick = runtime.success(runtime.syscall(abi.syscall.clock_ticks, 0, 0, 0));
    for (0..16) |_| {
        var input: abi.DisplayInput = .{};
        const received = runtime.displayInput(&input);
        if (received == abi.errno.again) break;
        runtime.expect(received == 0);
        runtime.display_wire.validateInput(&input) catch runtime.exit(99);
        const event: ui.Event = .{ .kind = @fromBackingInt(@as(u8, @intCast(input.kind))), .code = @intCast(input.code), .modifiers = @intCast(input.modifiers), .x = @intCast(std.math.clamp(input.x, -32768, 32767)), .y = @intCast(std.math.clamp(input.y, -32768, 32767)) };
        if (!hasFullscreen()) {
            const previously_open = system_state.panel_open or system_state.menu.open_group != null;
            const result = system_state.handleWithConfig(scene.width, scene.height, event, system_config) catch runtime.exit(99);
            if (result.changed) dirty = true;
            if (result.command) |command| systemCommand(command);
            if (!previously_open and (system_state.panel_open or system_state.menu.open_group != null)) applyChange(policy.cancelGestures());
            if (result.consumed) {
                applyChange(policy.observeInput(event));
                continue;
            }
        }
        applyChange(policy.input(event, tick) catch runtime.exit(99));
        if (hasFullscreen()) system_state.close();
    }
}
fn hasFullscreen() bool {
    for (policy.entries, 0..) |entry, i| if (policy.visible(i) and entry.window.mode == .fullscreen) return true;
    return false;
}
fn systemCommand(command: u32) void {
    const ids = system_bar.commands;
    if (command == ids.controls) {
        system_state.panel_open = true;
        dirty = true;
    } else if (command >= ids.workspace_first and command < ids.workspace_first + 4) {
        applyChange(policy.switchWorkspace(@intCast(command - ids.workspace_first), false) catch runtime.exit(99));
    } else if (command == ids.floating or command == ids.tiled) {
        applyChange(policy.setTiled(command == ids.tiled) catch runtime.exit(99));
    } else if (command >= ids.dim_first and command < ids.dim_first + 4) {
        const values = [_]u8{ 64, 128, 192, 255 };
        system_state.dim = values[command - ids.dim_first];
        dirty = true;
    } else if (command == ids.files or command == ids.notes) {
        const peer = policy.peers[rules.shell_index];
        if (peer.pid != 0) applyChange(policy.launch(peer.app, peer.pid, if (command == ids.files) abi.display.files else rules.notes_app) catch runtime.exit(99));
    }
    var buffer: [80]u8 = undefined;
    runtime.write(std.fmt.bufPrint(&buffer, "[window-server] system menu command={d}\n", .{command}) catch runtime.exit(99));
}
fn pollClock() void {
    var snapshot: abi.ClockTime = .{};
    runtime.expect(runtime.clockRead(&snapshot) == 0);
    const available = snapshot.isAvailable();
    const seconds = snapshot.seconds + (if (snapshot.flags & abi.clock_flags.utc != 0) @as(i64, snapshot.utc_offset_minutes) * 60 else 0);
    const minute = if (available) @divFloor(seconds, 60) else @as(i64, 0);
    if (last_clock_minute == null or last_clock_minute.? != minute or system_clock.available != available) {
        system_clock = .{ .available = available, .seconds = seconds };
        last_clock_minute = minute;
        dirty = true;
        var buffer: [160]u8 = undefined;
        runtime.write(std.fmt.bufPrint(&buffer, "[window-server] clock local_seconds={d} available={d} observed_ticks={d}\n", .{ seconds, @intFromBool(available), snapshot.observed_ticks }) catch runtime.exit(99));
    }
}
fn copyBar() void {
    const count = @as(usize, scene.width) * shell.bar_height;
    for (0..count) |offset| scene.pixels[offset] = shell_bar[offset];
}
fn compose() void {
    // The immutable frost source was built from this pure procedural wallpaper.
    // Scene pixels never become a backdrop source and cannot leak app content.
    cursor_layer.invalidate();
    background_storage.cache.paint(&scene) catch {
        shell.renderWallpaper(&scene) catch runtime.exit(99);
    };
    copyBar();
    for (policy.z_order) |i| {
        if (!policy.visible(i)) continue;
        const window = policy.entries[i].window;
        const frame = window.frame();
        const floating = window.mode == .floating and !policy.tiled[policy.workspace];
        if (floating) glass.shadow(&scene, frame);
        if (floating) corner_snapshot.capture(&scene, frame);
        const border = window.borderWidth();
        const peer = policy.peers[i];
        const cached = retained_frames[i].compatible(peer.app, peer.pid, peer.configuration.?);
        frame_fill.fill(&scene, frame, border, cached);
        drawChrome(i);
        if (cached) {
            const cache = cacheSurface(i);
            rules.blitViewport(scene.pixels, cache.pixels, policy.peers[i].configuration.?) catch runtime.exit(99);
            runtime.expect(runtime.surfaceUnmap(cache_tokens[i]) == 0);
        }
        if (floating) corner_snapshot.finish(&scene);
        if (window.mode != .fullscreen) scene.roundedBorder(frame.x, frame.y, frame.width, frame.height, if (floating) glass.radius else 0, ui.materials.glass.edge, 1, if (window.focused) 46 else 22);
    }
    if (!hasFullscreen()) system_bar.drawWithConfig(&scene, &system_state, system_clock, policy.workspace, policy.tiled[policy.workspace], system_config) catch runtime.exit(99);
    if (system_state.dim != 255) {
        for (0..@as(usize, scene.width) * scene.height) |offset| {
            const pixel = scene.pixels[offset];
            const red = ((pixel >> 16) & 255) * @as(u32, system_state.dim) / 255;
            const green = ((pixel >> 8) & 255) * @as(u32, system_state.dim) / 255;
            const blue = (pixel & 255) * @as(u32, system_state.dim) / 255;
            scene.pixels[offset] = red << 16 | green << 8 | blue;
        }
    }
    _ = cursor_layer.paint(&scene, policy.cursor, system_state.dim) catch runtime.exit(99);
    runtime.expect(heartbeat.presents < std.math.maxInt(u64));
    presentRegion(.{ .x = 0, .y = 0, .width = scene.width, .height = scene.height });
    heartbeat.presents += 1;
    dirty = false;
    cursor_dirty = false;
}
fn presentRegion(rect: ui.Rect) void {
    runtime.expect(present_sequence < std.math.maxInt(u64));
    present_sequence += 1;
    const present: abi.PresentRequest = .{ .surface_token = scene_token, .x = rect.x, .y = rect.y, .width = rect.width, .height = rect.height, .sequence = present_sequence };
    runtime.expect(runtime.displayPresent(&present) == 0);
}
fn composeCursor() void {
    const damage = cursor_layer.paint(&scene, policy.cursor, system_state.dim) catch runtime.exit(99);
    // Keep these separate: a jump across the display must still copy at most
    // two 6x18 patches, rather than a nearly fullscreen bounding rectangle.
    if (damage.old) |rect| presentRegion(rect);
    if (damage.new) |rect| presentRegion(rect);
    cursor_dirty = false;
}
fn hasFrames(app: u64) bool {
    const i = policy.slotForApp(app) orelse return false;
    return policy.peers[i].pid != 0 and policy.peers[i].cache_valid;
}
fn stateReport(state: rules.State) bool {
    const result = runtime.windowState(state.code, state.app, state.aux);
    runtime.expect(result == 0 or result == abi.errno.again);
    return result == 0;
}
fn reportStates() void {
    if (!initial_ready and policy.peers[rules.shell_index].cache_valid and hasFrames(abi.display.files) and hasFrames(rules.notes_app) and stateReport(.{ .code = 1 })) initial_ready = true;
    for (&relaunch_pending, 0..) |*pending, a| {
        const app = if (a == 0) abi.display.files else rules.notes_app;
        if (pending.* and hasFrames(app) and stateReport(.{ .code = 4, .app = app })) pending.* = false;
    }
    for (&pending_states) |*pending| if (pending.*) |state| {
        if (state.code == 3) {
            if (policy.slotForApp(state.app)) |i| if (policy.peers[i].pid != 0) {
                pending.* = null;
                continue;
            };
        } else if (state.app != 0) {
            const i = policy.slotForApp(state.app) orelse {
                pending.* = null;
                continue;
            };
            if (policy.peers[i].pid == 0) {
                pending.* = null;
                continue;
            }
            if (state.code != 2 and state.code != 11 and !policy.peers[i].cache_valid) continue;
        }
        if (stateReport(state)) pending.* = null;
    };
}
fn drawChrome(i: usize) void {
    const window = policy.entries[i].window;
    const title = window.title();
    const layout = windows.header.layoutMode(title.width, window.header_tabs) catch runtime.exit(99);
    fill(title, ui.Color.rgb(20, 21, 26));
    const title_bytes = policy.entries[i].title;
    var title_len = std.mem.indexOfScalar(u8, &title_bytes, 0) orelse title_bytes.len;
    while (title_len != 0 and (ui.font.measure(title_bytes[0..title_len], 1) catch runtime.exit(99)).width > layout.title.width) title_len -= 1;
    const title_y = if (scene.legacy_text) title.y + 8 else ui.font.controlOriginY(title.y, title.height, 1) catch runtime.exit(99);
    ui.font.paint(&scene, title_bytes[0..title_len], title.x + layout.title.x, title_y, if (window.focused) ui.Color.rgb(228, 230, 237) else ui.Color.rgb(164, 169, 183), 1) catch runtime.exit(99);
    for (window.controls()) |item| {
        const rect = item.rect;
        if (rect.width == 0) continue;
        const cx = rect.x + @as(i32, @intCast(rect.width / 2));
        const cy = rect.y + @as(i32, @intCast(rect.height / 2));
        const pressed = window.pressed_control == item.control;
        const active = pressed or window.hovered == item.control;
        if (active) {
            if (item.control == .close) {
                fill(rect, if (pressed) ui.Color.rgb(155, 31, 22) else ui.Color.rgb(196, 43, 28));
            } else frost(rect, .{ .tint = ui.Color.rgb(110, 116, 133), .opacity = if (pressed) 144 else 88 });
        }
        const ink = if (active and item.control == .close) ui.Color.rgb(255, 255, 255) else if (window.focused) ui.Color.rgb(217, 221, 232) else ui.Color.rgb(151, 159, 176);
        const icon: ui.Icon = switch (item.control) {
            .close => .close,
            .minimize => .minimize,
            .maximize => if (window.mode == .maximized) .restore else .maximize,
            .fullscreen => unreachable,
        };
        ui.icons.draw(&scene, icon, .{ .x = cx - 8, .y = cy - 8 }, ink, 1) catch runtime.exit(99);
    }
}
fn fill(rect: ui.Rect, color: ui.Color) void {
    if (rect.x < 0 or rect.y < 0) return;
    scene.fillRect(@intCast(rect.x), @intCast(rect.y), rect.width, rect.height, scene.encode(color));
}
fn frost(rect: ui.Rect, material: ui.Material) void {
    if (rect.x < 0 or rect.y < 0) return;
    scene.materialRect(@intCast(rect.x), @intCast(rect.y), rect.width, rect.height, material);
}
export fn bedrock_user_main(parent: u64, inherited: u64, argument: u64) callconv(.c) noreturn {
    runtime.markEntry();
    const startup = runtime.startup(parent, inherited, argument) catch runtime.exit(99);
    runtime.expect(parent != 0 and inherited != 0 and argument == 0 and startup.app_id == abi.display.server);
    runtime.expect(std.mem.eql(u8, runtime.startup_record.environment(startup, "BEDROCK_ROLE") orelse "", "display-server"));
    const endpoint = runtime.success(runtime.serviceOpen(abi.display.service));
    var display: abi.DisplayInfo = .{};
    runtime.expect(runtime.displayInfo(&display) == 0 and display.width >= 800 and display.width <= 1280 and display.height >= 600 and display.height <= 800 and display.format == abi.display.format and display.reserved == 0);
    policy = Policy.init(display.width, display.height) catch runtime.exit(99);
    const composed = createSurface(display, 3);
    scene = composed.surface;
    scene_token = composed.token;
    shell.renderWallpaper(&scene) catch runtime.exit(99);
    const count = ui.Backdrop.requiredLen(display.width, display.height) catch runtime.exit(99);
    backdrop = ui.Backdrop.build(&scene, blur_colors[0..count], background_storage.blur[0..count]) catch runtime.exit(99);
    {
        var heap = runtime.appHeap(startup);
        const allocator = heap.allocator();
        const hash = allocator.create([wallpaper.hash_capacity]u16) catch runtime.exit(99);
        defer allocator.destroy(hash);
        background_storage.cache.build(&scene, hash) catch {};
        runtime.write(if (background_storage.cache.valid) "[window-server] wallpaper cache ready lossless=1\n" else "[window-server] wallpaper cache unavailable fallback=procedural\n");
    }
    scene.setBackdrop(&backdrop, .{ .x = 0, .y = 0 }) catch runtime.exit(99);
    shell.renderBarWithWorkspace(&scene, &workspace, @tagName(builtin.cpu.arch)) catch runtime.exit(99);
    for (0..@as(usize, display.width) * shell.bar_height) |offset| shell_bar[offset] = scene.pixels[offset];
    heartbeat.server_pid = startup.pid;
    pollClock();
    compose();
    runtime.write("[window-server] native window compositor ready lazy_caches=6 scene=1 shell_bar_rows=36\n");
    while (true) {
        flush(endpoint);
        for (0..32) |_| {
            if (!receiveCapacity()) break;
            var message: abi.ServiceMessage = .{};
            const result = runtime.serviceReceive(endpoint, &message);
            if (result == abi.errno.again) break;
            runtime.expect(result == 0);
            receive(&message);
        }
        pollInput();
        pollClock();
        if (dirty) compose() else if (cursor_dirty) composeCursor();
        flush(endpoint);
        reportStates();
        heartbeat.shell_pid = policy.peers[rules.shell_index].pid;
        heartbeat.files_pid = policy.appPid(abi.display.files);
        heartbeat.notes_pid = policy.appPid(rules.notes_app);
        heartbeat.files_closed = policy.closed_counts[0];
        heartbeat.notes_closed = policy.closed_counts[1];
        heartbeat.files_launch_requests = policy.launch_requests[0];
        heartbeat.notes_launch_requests = policy.launch_requests[1];
        heartbeat.configure_sequence = policy.configure_sequence;
        heartbeat.workspace = policy.workspace;
        heartbeat.tiled = @intFromBool(policy.tiled[policy.workspace]);
        heartbeat.focused_pid = policy.focusedPid();
        const sent = runtime.writeFd(inherited, std.mem.asBytes(&heartbeat));
        runtime.expect(sent == @sizeOf(abi.WindowHeartbeat) or sent == abi.errno.again);
        runtime.expect(runtime.syscall(abi.syscall.sleep, 1, 0, 0) == 0);
    }
}
