//! Protected compositor: native backdrop, window policy and authenticated IPC.
const std = @import("std");
const ui = @import("axisui");
const runtime = @import("userspace_runtime");
const abi = @import("bedrock64");
const Policy = @import("policy.zig").Policy;
pub const panic = std.debug.FullPanic(runtime.panic);
const Heartbeat = extern struct { server_pid: u64, frames_a: u64 = 0, frames_b: u64 = 0, closed_a: u64 = 0, presents: u64 = 0 };
var workspace: ui.Workspace = undefined;
fn background(surface: *ui.Surface) void {
    for (0..surface.height) |row| {
        const blend: u8 = @intCast(row * 12 / surface.height);
        surface.fillRect(0, @intCast(row), surface.width, 1, surface.encode(ui.Color.rgb(40 + blend, 43 + blend, 55 + blend)));
    }
    const items = [_]ui.View{
        ui.Text("Bedrock").frame(100, 28).foreground(ui.Color.rgb(212, 149, 173)),
        ui.Text("Protected desktop").foreground(ui.Color.rgb(228, 223, 213)),
        ui.Spacer(),
        ui.Text("AxisUI / user compositor").foreground(ui.Color.rgb(139, 174, 192)),
    };
    ui.renderWithWorkspace(surface, &workspace, ui.HStack(&items).frame(null, 36).padding(6).gap(12).background(ui.Color.rgb(30, 32, 42))) catch runtime.exit(99);
}
fn expectedDisconnect(value: u64) bool {
    return value == abi.errno.bad_descriptor or value == abi.errno.broken_pipe or value == abi.errno.no_process;
}
fn reply(endpoint: u64, message: *const abi.ServiceMessage) bool {
    const result = runtime.serviceSend(endpoint, message);
    if (result == 0 or expectedDisconnect(result)) return true;
    runtime.expect(result == abi.errno.again);
    return false;
}
export fn bedrock_user_main(parent: u64, inherited: u64, argument: u64) callconv(.c) noreturn {
    runtime.markEntry();
    const info = runtime.startup(parent, inherited, argument) catch runtime.exit(99);
    runtime.expect(parent != 0 and inherited != 0 and argument == 0 and info.app_id == abi.display.server);
    runtime.expect(std.mem.eql(u8, runtime.startup_record.environment(info, "BEDROCK_ROLE") orelse "", "display-server"));
    const endpoint = runtime.success(runtime.serviceOpen(abi.display.service));
    var display: abi.DisplayInfo = .{};
    runtime.expect(runtime.displayInfo(&display) == 0 and display.width >= 800 and display.height >= 600 and display.format == abi.display.format and display.reserved == 0);
    const creation: abi.SurfaceCreate = .{ .width = display.width, .height = display.height };
    const backdrop = runtime.success(runtime.surfaceCreate(&creation));
    const address = runtime.success(runtime.surfaceMap(backdrop, 3, true));
    const pixels = runtime.display_wire.pixels(address, 3, display.width, display.height) catch runtime.exit(99);
    var screen = ui.Surface.init(pixels, display.width, display.height, display.width, .{ .red = 0xff0000, .green = 0xff00, .blue = 0xff }) catch runtime.exit(99);
    background(&screen);
    const fill: abi.PresentRequest = .{ .surface_token = backdrop, .x = 0, .y = 0, .width = display.width, .height = display.height, .sequence = 1 };
    runtime.expect(runtime.displayPresent(&fill) == 0);
    var policy: Policy = .{};
    var pending_acks: [2]?abi.ServiceMessage = @splat(null);
    var heartbeat: Heartbeat = .{ .server_pid = info.pid };
    runtime.write("[display-server] protected compositor ready\n");
    while (true) {
        for (&pending_acks) |*pending| {
            if (pending.*) |ack| if (reply(endpoint, &ack)) {
                pending.* = null;
            };
        }
        for (0..32) |_| {
            var message: abi.ServiceMessage = .{};
            const received = runtime.serviceReceive(endpoint, &message);
            if (received == abi.errno.again) break;
            runtime.expect(received == 0);
            runtime.display_wire.validateServer(&message) catch {
                // An untrusted client's control data cannot stop the display
                // service. A delivered read grant must still be retired.
                if (message.surface != 0) _ = runtime.surfaceRelease(message.surface);
                continue;
            };
            if (message.kind == abi.display.heartbeat) continue;
            if (message.kind == abi.display.peer_closed) {
                const index = policy.close(message.peer_app, message.peer_pid) catch continue;
                pending_acks[index] = null;
                if (index == 0) heartbeat.closed_a += 1;
                continue;
            }
            const client_index: usize = if (message.peer_app == abi.display.client_a) 0 else 1;
            if (pending_acks[client_index] != null) {
                // The client violated one frame in flight. Release this
                // snapshot instead of blocking the other window on its queue.
                runtime.expect(runtime.surfaceRelease(message.surface) == 0);
                continue;
            }
            const index = policy.frame(&message) catch {
                runtime.expect(runtime.surfaceRelease(message.surface) == 0);
                continue;
            };
            const mapped = runtime.success(runtime.surfaceMap(message.surface, 0, false));
            _ = runtime.display_wire.pixels(mapped, 0, message.width, message.height) catch runtime.exit(99);
            const window = policy.windows[index];
            const present: abi.PresentRequest = .{ .surface_token = message.surface, .x = window.x, .y = window.y, .width = message.width, .height = message.height, .sequence = message.sequence };
            runtime.expect(runtime.displayPresent(&present) == 0);
            runtime.expect(runtime.surfaceRelease(message.surface) == 0);
            if (index == 0) heartbeat.frames_a += 1 else heartbeat.frames_b += 1;
            heartbeat.presents += 1;
            const ack: abi.ServiceMessage = .{ .kind = abi.display.ack, .peer_pid = message.peer_pid, .peer_app = message.peer_app, .sequence = message.sequence };
            if (!reply(endpoint, &ack)) pending_acks[index] = ack;
        }
        for (0..16) |_| {
            var input: abi.DisplayInput = .{};
            const received = runtime.displayInput(&input);
            if (received == abi.errno.again) break;
            runtime.expect(received == 0);
            runtime.display_wire.validateInput(&input) catch runtime.exit(99);
            const target = policy.input(&input) orelse continue;
            const event: ui.Event = .{ .kind = @fromBackingInt(@as(u8, @intCast(input.kind))), .code = @intCast(input.code), .modifiers = @intCast(input.modifiers), .x = @intCast(@max(-32768, @min(32767, @as(i64, input.x) - target.x))), .y = @intCast(@max(-32768, @min(32767, @as(i64, input.y) - target.y))) };
            var routed: abi.ServiceMessage = .{ .kind = abi.display.input, .peer_pid = target.pid, .peer_app = target.app, .sequence = input.sequence };
            std.mem.writeInt(u64, routed.payload[0..8], event.encode(), .little);
            if (!reply(endpoint, &routed)) runtime.write("[display-server] input backlog rejected\n");
        }
        const sent = runtime.writeFd(inherited, std.mem.asBytes(&heartbeat));
        runtime.expect(sent == @sizeOf(Heartbeat) or sent == abi.errno.again);
        runtime.expect(runtime.syscall(abi.syscall.sleep, 1, 0, 0) == 0);
    }
}
