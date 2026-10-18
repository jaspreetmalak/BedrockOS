//! Native AxisUI client. Pixels belong to its mapped capability, never GOP.
const std = @import("std");
const ui = @import("axisui");
const runtime = @import("userspace_runtime");
const abi = @import("bedrock64");
pub const panic = std.debug.FullPanic(runtime.panic);
var workspace: ui.Workspace = undefined;

fn paint(surface: *ui.Surface, app: u64, frame: u64, clicks: u64, toggled: bool) void {
    const base = ui.Color.rgb(30, 32, 42);
    const accent = if (toggled) ui.Color.rgb(168, 197, 165) else if (app == abi.display.client_a) ui.Color.rgb(212, 149, 173) else ui.Color.rgb(139, 174, 192);
    surface.fillRect(0, 0, 320, 240, surface.encode(base));
    var label_buffer: [64]u8 = undefined;
    const label = std.fmt.bufPrint(&label_buffer, "Frame {d} / Clicks {d}", .{ frame, clicks }) catch runtime.exit(99);
    const title = if (app == abi.display.client_a) "Surface A" else "Surface B";
    const header_items = [_]ui.View{ ui.Text(title).foreground(accent), ui.Spacer(), ui.Text("LIVE").foreground(accent) };
    const content = [_]ui.View{
        ui.HStack(&header_items).frame(296, 28).gap(8).padding(4).background(ui.Color.rgb(38, 40, 52)),
        ui.Text("Native AxisUI").scale(2).foreground(ui.Color.rgb(228, 223, 213)),
        ui.Text("Private pixels / protected app").foreground(ui.Color.rgb(153, 158, 174)),
        ui.Text(label).foreground(accent),
        ui.Spacer(),
        ui.Text("Toggle accent").frame(140, 32).padding(8).background(ui.Color.rgb(50, 53, 67)).foreground(accent).cornerRadius(6),
    };
    ui.renderWithWorkspace(surface, &workspace, ui.VStack(&content).frame(320, 240).padding(12).gap(12).border(accent, 2)) catch runtime.exit(99);
}

export fn bedrock_user_main(parent: u64, inherited: u64, argument: u64) callconv(.c) noreturn {
    runtime.markEntry();
    const info = runtime.startup(parent, inherited, argument) catch runtime.exit(99);
    runtime.expect(parent != 0 and inherited == 0 and argument <= 2);
    runtime.expect(info.app_id == abi.display.client_a or info.app_id == abi.display.client_b);
    runtime.expect(std.mem.eql(u8, runtime.startup_record.environment(info, "BEDROCK_ROLE") orelse "", "surface-client"));
    var forbidden: abi.DisplayInfo = .{};
    runtime.expect(runtime.displayInfo(&forbidden) == abi.errno.permission);
    runtime.expect(runtime.serviceOpen(abi.display.service) == abi.errno.permission);
    runtime.expect(runtime.spawnApp(abi.display.server, 0, 0) == abi.errno.permission);
    const endpoint = runtime.success(runtime.serviceConnect(abi.display.service));
    const request: abi.SurfaceCreate = .{ .width = 320, .height = 240 };
    const token = runtime.success(runtime.surfaceCreate(&request));
    runtime.expect(runtime.surfaceMap(token, 0, false) == abi.errno.permission);
    runtime.expect(runtime.surfaceMap(token, 4, true) == abi.errno.invalid);
    runtime.expect(runtime.surfaceMap(0, 0, true) == abi.errno.bad_descriptor);
    var forged: abi.ServiceMessage = .{ .kind = abi.display.heartbeat, .peer_pid = info.pid, .sequence = 1 };
    runtime.expect(runtime.serviceSend(endpoint, &forged) == abi.errno.permission);
    forged.peer_pid = 0;
    forged.surface = token;
    runtime.expect(runtime.serviceSend(endpoint, &forged) == abi.errno.permission);
    const forbidden_present: abi.PresentRequest = .{ .surface_token = token, .x = 0, .y = 0, .width = 320, .height = 240, .sequence = 1 };
    runtime.expect(runtime.displayPresent(&forbidden_present) == abi.errno.permission);
    var server_pid: ?u64 = null;
    var clicks: u64 = 0;
    var toggled = false;
    var sequence: u64 = 1;
    while (true) {
        const address = runtime.success(runtime.surfaceMap(token, 0, true));
        const pixels = runtime.display_wire.pixels(address, 0, 320, 240) catch runtime.exit(99);
        var surface = ui.Surface.init(pixels, 320, 240, 320, .{ .red = 0xff0000, .green = 0xff00, .blue = 0xff }) catch runtime.exit(99);
        paint(&surface, info.app_id, sequence, clicks, toggled);
        while (true) {
            const sent = runtime.surfaceSubmit(token, endpoint, sequence);
            if (sent == 0) break;
            runtime.expect(sent == abi.errno.again);
            runtime.expect(runtime.syscall(abi.syscall.sleep, 1, 0, 0) == 0);
        }
        var acknowledged = false;
        while (!acknowledged) {
            var message: abi.ServiceMessage = .{};
            const received = runtime.serviceReceive(endpoint, &message);
            if (received == abi.errno.again) {
                runtime.expect(runtime.syscall(abi.syscall.sleep, 1, 0, 0) == 0);
                continue;
            }
            runtime.expect(received == 0);
            runtime.display_wire.validateClient(&message, server_pid) catch runtime.exit(99);
            server_pid = message.peer_pid;
            if (message.kind == abi.display.ack) {
                runtime.expect(message.sequence == sequence);
                acknowledged = true;
            } else {
                const event = ui.Event.decode(std.mem.readInt(u64, message.payload[0..8], .little)) catch runtime.exit(99);
                if (event.kind == .pointer_up and event.code == @backingInt(ui.input.Button.left) and event.x >= 12 and event.x < 152 and event.y >= 196 and event.y < 228) {
                    toggled = !toggled;
                    clicks += 1;
                    runtime.write("[display-client] focused input accepted\n");
                }
            }
        }
        if (sequence == 3 and info.app_id == abi.display.client_a) {
            if (argument == 1) {
                runtime.write("[display-client] surface A fault requested\n");
                // ACK releases the server's read lease, but never restores
                // our old mapping. Only an explicit fresh map can do that.
                runtime.invalidReadAt(address);
            }
            if (argument == 2) {
                runtime.expect(runtime.surfaceClose(token) == 0 and runtime.serviceClose(endpoint) == 0);
                runtime.write("[display-client] surface A restart verified\n");
                runtime.exit(23);
            }
        }
        sequence += 1;
        runtime.expect(runtime.syscall(abi.syscall.sleep, if (info.app_id == abi.display.client_b) 12 else 2, 0, 0) == 0);
    }
}
