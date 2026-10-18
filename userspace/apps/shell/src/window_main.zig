//! Native protected shell: two launch chips and live workspace/window status.
const std = @import("std");
const builtin = @import("builtin");
const rt = @import("userspace_runtime");
const abi = @import("bedrock64");
const shell = @import("desktop_shell");
const ui = shell.axisui;
pub const panic = std.debug.FullPanic(rt.panic);
var backdrop_colors: [16000]u32 = undefined;
var backdrop_scratch: [16000]u32 = undefined;
var backdrop: ?ui.Backdrop = null;
var state: rt.window_wire.Status = .{ .sequence = 0, .workspace = 0, .tiled = false, .focused_pid = 0 };
const architecture = switch (builtin.cpu.arch) {
    .x86_64 => "x86_64",
    .aarch64 => "ARM64",
    .riscv64 => "RISC-V64",
    else => unreachable,
};
fn text(screen: *ui.Surface, x: u32, y: u32, bytes: []const u8, color: ui.Color) void {
    ui.font.paint(screen, bytes, @intCast(x), @intCast(y), color, 1) catch rt.exit(99);
}
fn chipRect(app_id: u64, width: u32, height: u32) ui.Rect {
    const left: u32 = @min(width, if (app_id == abi.display.files) @as(u32, 94) else 180);
    return .{ .x = @intCast(left), .y = 0, .width = @min(width - left, 72), .height = @min(height, shell.bar_height) };
}
fn draw(session: *rt.window_client.Session) void {
    const cfg = session.config.?;
    const pixels = session.map();
    var screen = ui.Surface.init(pixels, cfg.screen_width, cfg.screen_height, cfg.screen_width, .{ .red = 0xff0000, .green = 0xff00, .blue = 0xff }) catch rt.exit(99);
    shell.renderWallpaper(&screen) catch rt.exit(99);
    if (backdrop == null) backdrop = ui.Backdrop.build(&screen, &backdrop_colors, &backdrop_scratch) catch rt.exit(99);
    screen.setBackdrop(&backdrop.?, .{ .x = 0, .y = 0 }) catch rt.exit(99);
    screen.materialRect(0, 0, cfg.screen_width, shell.bar_height, .{ .tint = ui.materials.glass.sidebar.tint, .opacity = 108 });
    const text_y: u32 = @intCast(ui.font.controlOriginY(0, shell.bar_height, 1) catch rt.exit(99));
    const label_color = ui.Color.rgb(218, 223, 235);
    const quiet_color = ui.Color.rgb(150, 158, 177);
    text(&screen, 17, text_y, "Bedrock", label_color);
    for ([_]struct { id: u64, label: []const u8, x: u32, ink: ui.Color }{
        .{ .id = abi.display.files, .label = "Files", .x = 94, .ink = label_color },
        .{ .id = abi.display.notes, .label = "Notes", .x = 180, .ink = label_color },
    }) |chip| {
        screen.roundedMaterialRect(@intCast(chip.x), 4, 72, 28, 12, ui.materials.glass.control);
        screen.roundedBorder(@intCast(chip.x), 4, 72, 28, 12, ui.materials.glass.edge, 1, 24);
        const label_width = (ui.font.measure(chip.label, 1) catch rt.exit(99)).width;
        text(&screen, chip.x + (72 - @min(72, label_width)) / 2, text_y, chip.label, chip.ink);
    }
    for (0..4) |index| {
        const x: u32 = 270 + @as(u32, @intCast(index)) * 30;
        const selected = state.workspace == index;
        const label = [_]u8{@as(u8, @intCast(index)) + '1'};
        const label_width = (ui.font.measure(&label, 1) catch rt.exit(99)).width;
        text(&screen, x + (26 - @min(26, label_width)) / 2, text_y, &label, if (selected) label_color else quiet_color);
        if (selected) screen.roundedRect(@intCast(x + 10), 29, 6, 3, 1, ui.Color.rgb(183, 164, 185));
    }
    text(&screen, 410, text_y, if (state.tiled) "Tiled" else "Floating", quiet_color);
    const architecture_width = (ui.font.measure(architecture, 1) catch rt.exit(99)).width;
    text(&screen, cfg.screen_width - architecture_width - 17, text_y, architecture, quiet_color);
    session.submit();
}
export fn bedrock_user_main(parent: u64, inherited: u64, argument: u64) callconv(.c) noreturn {
    rt.markEntry();
    const info = rt.startup(parent, inherited, argument) catch rt.exit(99);
    rt.expect(parent != 0 and inherited == 0 and argument == 0 and info.app_id == abi.display.shell);
    rt.expect(std.mem.eql(u8, rt.startup_record.argument(info, 0) orelse "", "org.bedrock.shell"));
    rt.expect(std.mem.eql(u8, rt.startup_record.environment(info, "BEDROCK_ROLE") orelse "", "shell"));
    var session = rt.window_client.Session.connect();
    session.awaitConfiguration();
    rt.write("[window-shell] protected shell ready\n");
    var startup_frames: u8 = 3;
    var pressed: u64 = 0;
    while (true) {
        for (0..32) |_| {
            const incoming = session.poll() orelse break;
            switch (incoming) {
                .input => |raw| {
                    const event = ui.Event.decode(raw) catch rt.exit(99);
                    const cfg = session.config.?;
                    var hit: u64 = 0;
                    for ([_]u64{ abi.display.files, abi.display.notes }) |id|
                        if (chipRect(id, cfg.width, cfg.height).contains(.{ .x = event.x, .y = event.y })) {
                            hit = id;
                        };
                    var launch: u64 = 0;
                    if (event.kind == .pointer_down and event.code == @backingInt(ui.input.Button.left)) pressed = hit;
                    if (event.kind == .pointer_up and event.code == @backingInt(ui.input.Button.left)) {
                        if (pressed != 0 and pressed == hit) launch = hit;
                        pressed = 0;
                    }
                    if (event.kind == .key_down and event.modifiers & ui.input.modifiers.super != 0) {
                        if (event.code == 'e' or event.code == 'E' or event.code == 13) launch = abi.display.files;
                        if (event.code == 'n' or event.code == 'N') launch = abi.display.notes;
                    }
                    if (launch != 0) {
                        session.launch(launch);
                        rt.write(if (launch == abi.display.files) "[window-shell] Files launch requested\n" else "[window-shell] Notes launch requested\n");
                    }
                    if (event.kind == .redraw) {
                        session.dirty = true;
                        if (event.code == 1) pressed = 0;
                    }
                },
                .status => |latest| state = latest,
                .configured => pressed = 0,
                .closed => session.close(),
                .rejected => rt.exit(99),
                .acknowledged => {},
            }
        }
        if (session.config.?.width != 0 and session.in_flight == null and (session.dirty or startup_frames != 0)) {
            draw(&session);
            if (startup_frames != 0) startup_frames -= 1;
        }
        rt.expect(rt.syscall(abi.syscall.sleep, 1, 0, 0) == 0);
    }
}
