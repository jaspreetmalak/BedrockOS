//! The protected shell owns the bar and public wallpaper, never device scanout.
const std = @import("std");
const builtin = @import("builtin");
const rt = @import("userspace_runtime");
const abi = @import("bedrock64");
const shell = @import("desktop_shell");
const ui = shell.axisui;
pub const panic = std.debug.FullPanic(rt.panic);
var workspace: ui.Workspace = undefined;
var backdrop_colors: [16000]u32 = undefined;
var backdrop_scratch: [16000]u32 = undefined;
var backdrop: ?ui.Backdrop = null;
const architecture = switch (builtin.cpu.arch) {
    .x86_64 => "x86_64",
    .aarch64 => "ARM64",
    .riscv64 => "RISC-V64",
    else => unreachable,
};
fn draw(session: *rt.desktop_client.Session) void {
    const cfg = session.config.?;
    const pixels = session.map();
    var screen = ui.Surface.init(pixels, cfg.screen_width, cfg.screen_height, cfg.screen_width, .{ .red = 0xff0000, .green = 0xff00, .blue = 0xff }) catch rt.exit(99);
    if (backdrop == null) {
        shell.renderWallpaper(&screen) catch rt.exit(99);
        backdrop = ui.Backdrop.build(&screen, &backdrop_colors, &backdrop_scratch) catch rt.exit(99);
    }
    screen.setBackdrop(&backdrop.?, .{ .x = 0, .y = 0 }) catch rt.exit(99);
    shell.renderWithWorkspace(&screen, &workspace, architecture) catch rt.exit(99);
    session.submit();
}
export fn bedrock_user_main(parent: u64, inherited: u64, argument: u64) callconv(.c) noreturn {
    rt.markEntry();
    const info = rt.startup(parent, inherited, argument) catch rt.exit(99);
    rt.expect(parent != 0 and inherited == 0 and argument == 0 and info.app_id == abi.display.shell);
    rt.expect(std.mem.eql(u8, rt.startup_record.argument(info, 0) orelse "", "org.bedrock.shell"));
    rt.expect(std.mem.eql(u8, rt.startup_record.environment(info, "BEDROCK_ROLE") orelse "", "shell"));
    var session = rt.desktop_client.Session.connect();
    session.awaitConfiguration();
    rt.write("[desktop-shell] protected shell ready\n");
    var startup_frames: u8 = 3;
    var launch_pressed = false;
    while (true) {
        for (0..32) |_| {
            const incoming = session.poll() orelse break;
            switch (incoming) {
                .input => |raw| {
                    const event = ui.Event.decode(raw) catch rt.exit(99);
                    const cfg = session.config.?;
                    const inside = shell.launchRect(cfg.width, cfg.height).contains(.{ .x = event.x, .y = event.y });
                    var launch = false;
                    if (event.kind == .pointer_down and event.code == @backingInt(ui.input.Button.left)) launch_pressed = inside;
                    if (event.kind == .pointer_up and event.code == @backingInt(ui.input.Button.left)) {
                        launch = launch_pressed and inside;
                        launch_pressed = false;
                    }
                    if (event.kind == .key_down and event.modifiers & ui.input.modifiers.super != 0 and (event.code == 'e' or event.code == 'E' or event.code == 13)) launch = true;
                    if (launch) {
                        session.launch();
                        rt.write("[desktop-shell] Files launch requested\n");
                    }
                    if (event.kind == .redraw) {
                        session.dirty = true;
                        if (event.code == 1) launch_pressed = false;
                    }
                },
                .configured => launch_pressed = false,
                .closed => session.close(),
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
