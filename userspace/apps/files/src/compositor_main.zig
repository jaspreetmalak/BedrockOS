//! Files owns its pixels and private storage; the compositor owns window policy.
const std = @import("std");
const rt = @import("userspace_runtime");
const abi = @import("bedrock64");
const app = @import("files_app");
const shell = @import("desktop_shell");
const provider = @import("checked_provider.zig");
const ui = app.axisui;
pub const panic = std.debug.FullPanic(rt.panic);
var model: app.Model = .{};
var workspace: app.Workspace = undefined;
var provider_context: u8 = 0;
var backdrop_colors: [16000]u32 = undefined;
var backdrop_scratch: [16000]u32 = undefined;
var backdrop: ?ui.Backdrop = null;

fn seed() void {
    for ([_][]const u8{ "/container/Documents", "/container/Downloads" }) |path| {
        const result = rt.syscall(abi.syscall.mkdir, @intFromPtr(path.ptr), path.len, 0);
        rt.expect(result == 0 or result == abi.errno.exists);
    }
    app.Model.ensureDesktop(provider.provider(&provider_context));
    const marker = rt.open("/container/.initialized", abi.open_flags.read);
    if (!abi.isError(marker)) {
        rt.expect(rt.close(marker) == 0);
        return;
    }
    rt.expect(marker == abi.errno.no_entry);
    const welcome = "Welcome to Bedrock.\nDrag this file into Downloads.\nCtrl-drag copies; F2 renames.\nYour files survive reboot.\n";
    const file = rt.success(rt.open("/container/Documents/welcome.txt", abi.open_flags.write | abi.open_flags.create));
    rt.expect(rt.writeFd(file, welcome) == welcome.len and rt.close(file) == 0);
    const initialized = rt.success(rt.open("/container/.initialized", abi.open_flags.write | abi.open_flags.create));
    rt.expect(rt.close(initialized) == 0);
}
fn checkAuthority(session: *const rt.desktop_client.Session) void {
    var display: abi.DisplayInfo = .{};
    var input: abi.DisplayInput = .{};
    const present: abi.PresentRequest = .{ .surface_token = session.token, .x = 0, .y = 0, .width = 1, .height = 1, .sequence = 1 };
    rt.expect(rt.displayInfo(&display) == abi.errno.permission and rt.displayInput(&input) == abi.errno.permission and rt.displayPresent(&present) == abi.errno.permission);
    rt.expect(rt.serviceOpen(abi.display.service) == abi.errno.permission);
    rt.expect(rt.desktopState(1) == abi.errno.permission and rt.spawnApp(abi.display.shell, 0, 0) == abi.errno.permission);
    rt.expect(rt.surfaceMap(session.token, 0, false) == abi.errno.permission);
    var forged: abi.ServiceMessage = .{ .kind = abi.display.heartbeat, .sequence = 1, .peer_pid = 1 };
    rt.expect(rt.serviceSend(session.endpoint, &forged) == abi.errno.permission);
    forged.peer_pid = 0;
    forged.surface = session.token;
    rt.expect(rt.serviceSend(session.endpoint, &forged) == abi.errno.permission);
    const launch: abi.ServiceMessage = .{ .kind = abi.display.launch, .sequence = 1 };
    rt.expect(rt.serviceSend(session.endpoint, &launch) == abi.errno.permission);
    rt.write("[desktop-files] display and raw input authority denied\n");
    const traversal = rt.open("/container/../0000000000000001/note.txt", abi.open_flags.read);
    rt.expect(traversal == abi.errno.permission or traversal == abi.errno.invalid);
    rt.expect(rt.open("/private/107/container/session.txt", abi.open_flags.read) == abi.errno.permission);
    const bundle = "/bundle/main.elf";
    rt.expect(rt.open(bundle, abi.open_flags.write) == abi.errno.permission);
    rt.expect(rt.syscall(abi.syscall.nullify, @intFromPtr(bundle.ptr), bundle.len, 0) == abi.errno.permission);
    rt.expect(rt.syscall(abi.syscall.nullify, 0x1000, 1, 0) == abi.errno.fault);
    rt.expect(rt.syscall(abi.syscall.nullify, @intFromPtr(bundle.ptr), bundle.len, 1) == abi.errno.invalid);
    const home = "/container/Documents";
    rt.expect(rt.syscall(abi.syscall.nullify, @intFromPtr(home.ptr), home.len, 0) == abi.errno.invalid);
    rt.write("[user] Nullify namespace authority checks passed\n");
    for ([_]u64{ abi.syscall.udp_open, abi.syscall.udp_send, abi.syscall.udp_receive }) |number| rt.expect(rt.syscall(number, 0, 0, 0) == abi.errno.permission);
    rt.write("[user] Files network access denied\n");
    for ([_]u64{ abi.syscall.wifi_status, abi.syscall.wifi_scan_start, abi.syscall.wifi_scan_read, abi.syscall.wifi_join, abi.syscall.wifi_disconnect, abi.syscall.wifi_enable }) |number| rt.expect(rt.syscall(number, 0, 0, 0) == abi.errno.permission);
    rt.write("[user] Files Wi-Fi control denied\n");
    const file = rt.success(rt.open(bundle, abi.open_flags.read));
    const readonly = "readonly";
    rt.expect(rt.syscall(abi.syscall.read, file, @intFromPtr(readonly.ptr), 1) == abi.errno.fault);
    rt.expect(rt.close(file) == 0);
    rt.write("[desktop-files] authority checks passed\n");
}
fn draw(session: *rt.desktop_client.Session) void {
    const cfg = session.config.?;
    const pixels = session.map();
    if (backdrop == null) {
        var full = ui.Surface.init(pixels, cfg.screen_width, cfg.screen_height, cfg.screen_width, .{ .red = 0xff0000, .green = 0xff00, .blue = 0xff }) catch rt.exit(99);
        shell.renderWallpaper(&full) catch rt.exit(99);
        backdrop = ui.Backdrop.build(&full, &backdrop_colors, &backdrop_scratch) catch rt.exit(99);
        rt.write("[desktop-files] frosted backdrop ready\n");
    }
    var viewport = ui.Surface.init(pixels, cfg.width, cfg.height, cfg.screen_width, .{ .red = 0xff0000, .green = 0xff00, .blue = 0xff }) catch rt.exit(99);
    viewport.setBackdrop(&backdrop.?, .{ .x = cfg.origin_x, .y = cfg.origin_y }) catch rt.exit(99);
    app.renderWithWorkspace(&viewport, &workspace, &model) catch rt.exit(99);
    session.submit();
}
export fn bedrock_user_main(parent: u64, inherited: u64, argument: u64) callconv(.c) noreturn {
    rt.markEntry();
    const info = rt.startup(parent, inherited, argument) catch rt.exit(99);
    rt.expect(parent != 0 and inherited == 0 and argument == 0 and info.app_id == abi.display.files);
    rt.expect(std.mem.eql(u8, rt.startup_record.argument(info, 0) orelse "", "org.bedrock.files"));
    rt.expect(std.mem.eql(u8, rt.startup_record.environment(info, "BEDROCK_ROLE") orelse "", "files"));
    seed();
    model.init(provider.provider(&provider_context), "/container/Documents", "/container/Downloads") catch rt.exit(99);
    var session = rt.desktop_client.Session.connect();
    session.awaitConfiguration();
    checkAuthority(&session);
    rt.write("[desktop-files] protected Files ready\n");
    var startup_frames: u8 = 3;
    var presented = false;
    var submitted_nullify: u64 = 0;
    var presented_nullify: u64 = 0;
    while (true) {
        const before = model.revision;
        for (0..32) |_| {
            const event = session.poll() orelse break;
            switch (event) {
                .input => |raw| {
                    const cfg = session.config.?;
                    if (cfg.width != 0) model.dispatch(ui.Event.decode(raw) catch rt.exit(99), cfg.width, cfg.height) catch rt.exit(99);
                },
                .configured => {
                    const cfg = session.config.?;
                    if (cfg.width != 0) model.dispatch(.{ .kind = .redraw, .code = 1 }, cfg.width, cfg.height) catch rt.exit(99);
                },
                .closed => session.close(),
                .acknowledged => |sequence| {
                    const current_epoch = @as(u32, @truncate(sequence >> 32)) == session.config.?.sequence and session.config.?.width != 0;
                    if (!presented and current_epoch) {
                        presented = true;
                        rt.write("[desktop-files] frame presented\n");
                    }
                    if (submitted_nullify > presented_nullify and current_epoch) {
                        presented_nullify = submitted_nullify;
                        rt.write("[desktop-files] Files nullify result frame presented\n");
                    }
                },
            }
        }
        if (before != model.revision) session.dirty = true;
        if (session.config.?.width != 0 and session.in_flight == null and (session.dirty or startup_frames != 0)) {
            draw(&session);
            submitted_nullify = provider.nullify_commits;
            if (startup_frames != 0) startup_frames -= 1;
        }
        rt.expect(rt.syscall(abi.syscall.sleep, 1, 0, 0) == 0);
    }
}
