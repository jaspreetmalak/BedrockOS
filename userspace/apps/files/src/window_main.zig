//! Files owns its pixels and private storage; the compositor owns window policy.
const std = @import("std");
const rt = @import("userspace_runtime");
const abi = @import("bedrock64");
const app = @import("files_app");
const shell = @import("desktop_shell");
const provider = @import("checked_provider.zig");
const ui = app.axisui;
pub const panic = std.debug.FullPanic(rt.panic);
const max_windows = 4;
const WindowContext = struct {
    occupied: bool = false,
    closing: bool = false,
    session: ?*rt.window_client.Session = null,
    model: app.Model = .{},
    tabs: app.TabStore = .{},
    tab_state: ui.tabs.State = .{},
    menu_state: ui.menu.State = .{},
    startup_frames: u8 = 3,
    presented: bool = false,
    submitted_nullify: u64 = 0,
    presented_nullify: u64 = 0,
};
var windows: [max_windows]WindowContext = @splat(.{});
var current_window: usize = 0;
var model: *app.Model = &windows[0].model;
var tabs: *app.TabStore = &windows[0].tabs;
var tab_state: *ui.tabs.State = &windows[0].tab_state;
var menu_state: *ui.menu.State = &windows[0].menu_state;
var connection: rt.window_client.Hub = undefined;
var transfer: app.TabTransfer = .{};
const PendingTransfer = struct { source: usize, destination: usize, x: i32, y: i32, started: u64, presenting: bool = false };
var pending_transfer: ?PendingTransfer = null;
var shared_clipboard: @TypeOf(windows[0].model.clipboard) = null;
var workspace: app.Workspace = undefined;
var provider_context: u8 = 0;
var backdrop_colors: [16000]u32 = undefined;
var backdrop_scratch: [16000]u32 = undefined;
var backdrop: ?ui.Backdrop = null;
var tab_items: [app.max_tabs]ui.tabs.Item = undefined;
const close_command: u32 = 256;
fn useWindow(index: usize) void {
    current_window = index;
    model = &windows[index].model;
    tabs = &windows[index].tabs;
    tab_state = &windows[index].tab_state;
    menu_state = &windows[index].menu_state;
    model.clipboard = shared_clipboard;
}
fn windowForId(id: u16) ?usize {
    for (&windows, 0..) |*window, index| {
        if (window.occupied and window.session != null and window.session.?.window_id == id) return index;
    }
    return null;
}
fn resetWindow(index: usize) !void {
    const window = &windows[index];
    window.occupied = true;
    window.closing = false;
    window.session = null;
    window.startup_frames = 3;
    window.presented = false;
    window.submitted_nullify = provider.nullify_commits;
    window.presented_nullify = provider.nullify_commits;
    window.menu_state.close();
    window.tab_state.cancel();
    // Initialize in place: a complete WindowContext is too large for a stack
    // temporary, and every window shares the same checked provider and renderer.
    try window.model.init(provider.provider(&provider_context), "/container/Documents", "/container/Downloads");
    window.model.clipboard = shared_clipboard;
    try window.tabs.init(&window.model);
}
fn openWindow(index: usize) !void {
    resetWindow(index) catch |err| {
        windows[index].occupied = false;
        return err;
    };
    windows[index].session = connection.openWindow(.{ .title = "Files", .preferred_width = 760, .preferred_height = 470, .header_content = true, .header_tabs = true }) catch |err| {
        windows[index].occupied = false;
        return err;
    };
}
fn menuItem(comptime action: app.Action, label: []const u8, shortcut: []const u8) ui.menu.Item {
    return .{ .command = @as(u32, @backingInt(action)) + 1, .label = label, .shortcut = shortcut };
}
var file_items = [_]ui.menu.Item{
    menuItem(.new_folder, "New folder", ""),
    menuItem(.new_file, "New file", ""),
    ui.menu.Item.divider(),
    menuItem(.open, "Open", "Enter"),
    menuItem(.refresh, "Refresh", "F5"),
    ui.menu.Item.divider(),
    .{ .command = close_command, .label = "Close window", .shortcut = "Alt+F4" },
};
var edit_items = [_]ui.menu.Item{
    menuItem(.copy, "Copy", "Ctrl+C"),
    menuItem(.move, "Cut", "Ctrl+X"),
    menuItem(.paste, "Paste", "Ctrl+V"),
    ui.menu.Item.divider(),
    menuItem(.rename, "Rename", "F2"),
    menuItem(.remove, "Delete", "Delete"),
    menuItem(.nullify, "Nullify...", ""),
};
var view_items = [_]ui.menu.Item{
    menuItem(.back, "Back", "Alt+Left"),
    menuItem(.forward, "Forward", "Alt+Right"),
    menuItem(.up, "Parent folder", "Alt+Up"),
    ui.menu.Item.divider(),
    menuItem(.split, "Split view", ""),
};
const menu_groups = [_]ui.menu.Group{
    .{ .label = "File", .items = &file_items },
    .{ .label = "Edit", .items = &edit_items },
    .{ .label = "View", .items = &view_items },
};
const menu_theme: ui.menu.Theme = .{
    .bar_material = app.materials.navigation,
    .bar_separator = ui.Color.rgb(55, 59, 71),
    .popup_material = app.materials.menu,
    .selected_material = .{ .tint = app.colors.selected, .opacity = 145 },
    .text = app.colors.text,
    .disabled = app.colors.muted,
    .shortcut = app.colors.muted,
    .accent = app.colors.accent,
};

fn commandAction(command: u32) ?app.Action {
    if (command == 0 or command > @typeInfo(app.Action).@"enum".field_values.len) return null;
    return @fromBackingInt(@intCast(command - 1));
}
fn actionEnabled(action: app.Action, width: u32) bool {
    return switch (action) {
        .back => model.edit == .none and !model.preview_open and model.canBack(),
        .forward => model.edit == .none and !model.preview_open and model.canForward(),
        .up => model.edit == .none and (model.preview_open or model.canUp()),
        .split => width >= app.layout.split_minimum_width and model.menuEnabled(action),
        else => model.menuEnabled(action),
    };
}
fn menuLayout(width: u32, height: u32) ui.menu.Layout {
    for ([_][]ui.menu.Item{ &file_items, &edit_items, &view_items }) |items| {
        for (items) |*item| {
            if (commandAction(item.command)) |action| {
                item.enabled = actionEnabled(action, width);
                if (action == .split) item.checked = model.split;
                if (action == .up) item.label = if (model.preview_open) "Close preview" else "Parent folder";
            }
        }
    }
    return ui.menu.Layout.initBar(.{ .groups = &menu_groups }, .{ .x = 0, .y = 0, .width = width, .height = height }, .{ .top = 32, .height = 40, .right = 120 }) catch rt.exit(99);
}
fn dispatchMenu(session: *rt.window_client.Session, event: ui.Event) bool {
    const cfg = session.config.?;
    if (model.edit != .none) {
        menu_state.close();
        return false;
    }
    if (model.menu) |context| {
        const popup = app.MenuGeometry.init(cfg.width, cfg.height - app.layout.window_header_height, context.kind, context.anchor) catch rt.exit(99);
        const body_point: ui.Point = .{ .x = event.x, .y = @as(i32, event.y) - app.layout.window_header_height };
        // Existing context popups paint above the app bar, so they also own
        // picking in any overlap. Their captured terminal release must reach
        // the same controller even after the pointer leaves that popup.
        if (event.kind == .pointer_move or event.kind == .pointer_up or
            (event.kind == .pointer_down and popup.rect.contains(body_point))) return false;
    }
    const layout = menuLayout(cfg.width, cfg.height);
    const was_open = menu_state.open_group != null;
    const activation = event.kind == .key_down and event.modifiers & ui.input.modifiers.alt != 0 and
        event.modifiers & (ui.input.modifiers.control | ui.input.modifiers.super) == 0;
    var result: ui.menu.Result = .{};
    if (activation and (event.code == 'f' or event.code == 'F' or event.code == 'e' or event.code == 'E' or event.code == 'v' or event.code == 'V')) {
        const group: usize = if (event.code == 'f' or event.code == 'F') 0 else if (event.code == 'e' or event.code == 'E') 1 else 2;
        result = .{ .consumed = menu_state.open(layout, group), .changed = true };
    } else if (was_open) result = menu_state.handle(layout, event) else return false;
    if (!was_open and menu_state.open_group != null) {
        // Starting an app menu cancels body captures and the old context menu.
        // The existing path controller owns cancelling its edit buffer.
        if (model.path_editing) model.dispatchWindow(.{ .kind = .key_down, .code = @backingInt(ui.input.Key.escape) }, cfg.width, cfg.height, locationRect(session)) catch rt.exit(99);
        model.dispatchWindow(.{ .kind = .redraw, .code = 1 }, cfg.width, cfg.height, locationRect(session)) catch rt.exit(99);
    }
    if (result.changed) session.dirty = true;
    if (result.command) |command| {
        if (command == close_command) {
            session.requestClose();
        } else if (commandAction(command)) |action| {
            if (actionEnabled(action, cfg.width)) {
                // Nullify remains available only through the model's existing
                // guarded context-menu press/release, with an explicit second
                // activation. This menu does not bypass that destructive guard.
                model.action(if (action == .nullify) .more else action);
            }
        }
    }
    if (event.kind == .redraw) return false;
    return result.consumed;
}

fn tabLayout(session: *const rt.window_client.Session) ui.tabs.Layout {
    for (tab_items[0..tabs.count], 0..) |*item, index| {
        item.* = .{ .id = tabs.id(index).?, .label = tabs.title(index, model), .icon = .folder };
    }
    const bounds = (session.headerLayout() orelse rt.exit(99)).accessory;
    return ui.tabs.Layout.init(.{ .x = bounds.x, .y = bounds.y, .width = bounds.width, .height = bounds.height }, tab_items[0..tabs.count], tabs.active) catch rt.exit(99);
}
fn logTabs() void {
    var buffer: [192]u8 = undefined;
    const id = windows[current_window].session.?.window_id;
    rt.write(std.fmt.bufPrint(&buffer, "[window-files] tabs count={d} active={d} id={d} window_id={d}\n", .{ tabs.count, tabs.active, tabs.id(tabs.active).?, id }) catch rt.exit(99));
    const prefix = std.fmt.bufPrint(&buffer, "[window-files] tab order window_id={d} ids=", .{id}) catch rt.exit(99);
    var used = prefix.len;
    for (0..tabs.count) |index| {
        const part = std.fmt.bufPrint(buffer[used..], "{s}{d}", .{ if (index == 0) "" else ",", tabs.id(index).? }) catch rt.exit(99);
        used += part.len;
    }
    buffer[used] = '\n';
    rt.write(buffer[0 .. used + 1]);
}
fn tabFailure(err: anyerror) void {
    const message: []const u8 = switch (err) {
        error.TabCapacity => "Eight tabs are open. Close a tab to open another.",
        error.TabIdExhausted => "No more tabs can be opened in this window.",
        error.WindowCapacity => "Close a Files window before moving another tab out.",
        error.DetachFailed => "The tab could not be moved. It remains in this window.",
        else => return, // The checked provider's error is already visible.
    };
    @memcpy(model.status[0..message.len], message);
    model.status_len = message.len;
    model.status_error = true;
    model.status_notice = false;
    model.revision +|= 1;
}
fn abortTransfer() void {
    const pending = pending_transfer orelse return;
    pending_transfer = null;
    transfer.cancel();
    const saved = current_window;
    if (windows[pending.source].occupied and !windows[pending.source].closing) {
        useWindow(pending.source);
        tabFailure(error.DetachFailed);
        const session = windows[pending.source].session.?;
        session.dirty = true;
        if (session.config) |cfg| if (cfg.width != 0) model.dispatchWindow(.{ .kind = .redraw, .code = 1 }, cfg.width, cfg.height, locationRect(session)) catch rt.exit(99);
    }
    const target = &windows[pending.destination];
    if (target.occupied and target.session != null and !target.closing) {
        target.closing = true;
        target.session.?.requestClose();
    }
    useWindow(saved);
}
fn detachTab(session: *rt.window_client.Session, index: usize, x: i32, y: i32) void {
    if (pending_transfer != null) return;
    const cfg = session.config.?;
    const drop_x = cfg.origin_x + x - 88;
    const drop_y = cfg.origin_y + y - 18;
    if (tabs.count == 1) {
        // A tab already in its own window moves that window as one gesture.
        session.moveTo(drop_x, drop_y);
        return;
    }
    const slot = for (&windows, 0..) |*window, i| {
        if (!window.occupied) break i;
    } else {
        tabFailure(error.WindowCapacity);
        return;
    };
    tabs.beginExport(index, model, &transfer) catch |err| {
        model.reportError(err);
        return;
    };
    openWindow(slot) catch {
        transfer.cancel();
        tabFailure(error.DetachFailed);
        return;
    };
    pending_transfer = .{ .source = current_window, .destination = slot, .x = drop_x, .y = drop_y, .started = rt.syscall(abi.syscall.clock_ticks, 0, 0, 0) };
}
fn prepareTransfer() void {
    const pending = pending_transfer orelse return;
    if (pending.destination != current_window or pending.presenting) return;
    const session = windows[current_window].session.?;
    tabs.importTransfer(model, &transfer) catch {
        abortTransfer();
        return;
    };
    pending_transfer.?.presenting = true;
    session.moveTo(pending.x, pending.y);
    session.dirty = true;
    logTabs();
}
fn completeTransfer() void {
    const pending = pending_transfer orelse return;
    if (!pending.presenting or pending.destination != current_window) return;
    const source = &windows[pending.source];
    const result = source.tabs.commitExport(&source.model, &transfer) catch |err| failed: {
        if (!transfer.committed) {
            abortTransfer();
            return;
        }
        source.model.reportError(err);
        break :failed app.CloseResult.changed;
    };
    pending_transfer = null;
    transfer.cancel();
    const saved = current_window;
    useWindow(pending.source);
    const source_session = source.session.?;
    if (result == .close_window) source_session.requestClose();
    source_session.dirty = true;
    if (source_session.config) |cfg| if (cfg.width != 0) model.dispatchWindow(.{ .kind = .redraw, .code = 1 }, cfg.width, cfg.height, locationRect(source_session)) catch rt.exit(99);
    logTabs();
    useWindow(saved);
    windows[current_window].session.?.requestFocus();
    rt.write("[window-files] tab detached after destination frame accepted\n");
}
fn dispatchTabs(session: *rt.window_client.Session, event: ui.Event) bool {
    var result: ui.tabs.Result = .{};
    const modifiers = event.modifiers;
    if (event.kind == .key_down and modifiers & ui.input.modifiers.control != 0 and
        modifiers & (ui.input.modifiers.alt | ui.input.modifiers.super) == 0)
    {
        if (event.code == 't' or event.code == 'T') {
            result = .{ .add = true, .consumed = true };
        } else if (event.code == 'w' or event.code == 'W') {
            result = .{ .close = tabs.active, .consumed = true };
        } else if (event.code == @backingInt(ui.input.Key.tab)) {
            result = .{ .select = if (modifiers & ui.input.modifiers.shift != 0) (tabs.active + tabs.count - 1) % tabs.count else (tabs.active + 1) % tabs.count, .consumed = true };
        } else result = tab_state.handle(tabLayout(session), event);
    } else result = tab_state.handle(tabLayout(session), event);
    if (result.changed) session.dirty = true;
    if (result.consumed and event.kind == .pointer_down) {
        menu_state.close();
        const cfg = session.config.?;
        model.dispatchWindow(.{ .kind = .redraw, .code = 1 }, cfg.width, cfg.height, locationRect(session)) catch rt.exit(99);
        session.dirty = true;
    }
    if (result.add or result.select != null or result.close != null or result.reorder != null or result.detach != null) {
        menu_state.close();
        // A drag's stable-ID capture must survive its own select/reorder.
        if (!result.dragging) tab_state.cancel();
        if (result.add) {
            tabs.add(model) catch |err| tabFailure(err);
        } else if (result.select) |index| {
            tabs.select(index, model) catch |err| tabFailure(err);
        } else if (result.close) |index| {
            const closed = tabs.close(index, model) catch |err| failed: {
                tabFailure(err);
                break :failed app.CloseResult.changed;
            };
            if (closed == .close_window) session.requestClose();
        }
        if (result.reorder) |move| tabs.reorder(move.from, move.to, model) catch |err| model.reportError(err);
        if (result.detach) |detached| detachTab(session, detached.index, detached.x, detached.y);
        session.dirty = true;
        logTabs();
    }
    return result.consumed;
}

fn seed() void {
    app.Model.ensureDesktop(provider.provider(&provider_context));
    for ([_][]const u8{ "/container/Documents", "/container/Downloads" }) |path| {
        const result = rt.syscall(abi.syscall.mkdir, @intFromPtr(path.ptr), path.len, 0);
        rt.expect(result == 0 or result == abi.errno.exists);
    }
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
fn checkAuthority(session: *const rt.window_client.Session) void {
    rt.expect(rt.serviceConnect(abi.display.service) == abi.errno.busy);
    var display: abi.DisplayInfo = .{};
    var input: abi.DisplayInput = .{};
    const present: abi.PresentRequest = .{ .surface_token = session.token, .x = 0, .y = 0, .width = 1, .height = 1, .sequence = 1 };
    rt.expect(rt.displayInfo(&display) == abi.errno.permission and rt.displayInput(&input) == abi.errno.permission and rt.displayPresent(&present) == abi.errno.permission);
    rt.expect(rt.serviceOpen(abi.display.service) == abi.errno.permission);
    rt.expect(rt.windowState(1, abi.display.files, 0) == abi.errno.permission and rt.spawnApp(abi.display.shell, 0, 0) == abi.errno.permission);
    rt.expect(rt.surfaceMap(session.token, 0, false) == abi.errno.permission);
    var forged: abi.ServiceMessage = .{ .kind = abi.display.heartbeat, .sequence = 1, .peer_pid = 1 };
    rt.expect(rt.serviceSend(session.endpoint, &forged) == abi.errno.permission);
    forged.peer_pid = 0;
    forged.surface = session.token;
    rt.expect(rt.serviceSend(session.endpoint, &forged) == abi.errno.permission);
    var control: abi.ServiceMessage = .{ .kind = abi.display.focus_window, .sequence = 1, .peer_app = abi.display.notes };
    rt.expect(rt.serviceSend(session.endpoint, &control) == abi.errno.permission);
    control = .{ .kind = abi.display.create_window, .sequence = 1, .width = 320, .height = 240 };
    control.payload[0] = '\n';
    rt.expect(rt.serviceSend(session.endpoint, &control) == abi.errno.permission);
    control = .{ .kind = abi.display.resize_window, .sequence = 1, .width = 320, .height = 240 };
    control.payload[0] = 1;
    rt.expect(rt.serviceSend(session.endpoint, &control) == abi.errno.permission);
    control = .{ .kind = abi.display.window_status, .sequence = 1 };
    rt.expect(rt.serviceSend(session.endpoint, &control) == abi.errno.permission);
    const launch: abi.ServiceMessage = .{ .kind = abi.display.launch, .sequence = 1 };
    rt.expect(rt.serviceSend(session.endpoint, &launch) == abi.errno.permission);
    rt.write("[window-files] display and raw input authority denied\n");
    rt.write("[window-files] duplicate connection and forged window controls denied\n");
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
    rt.write("[window-files] authority checks passed\n");
}
fn draw(session: *rt.window_client.Session) void {
    const cfg = session.config.?;
    const pixels = session.map();
    if (backdrop == null) {
        var full = ui.Surface.init(pixels, cfg.screen_width, cfg.screen_height, cfg.screen_width, .{ .red = 0xff0000, .green = 0xff00, .blue = 0xff }) catch rt.exit(99);
        shell.renderWallpaper(&full) catch rt.exit(99);
        backdrop = ui.Backdrop.build(&full, &backdrop_colors, &backdrop_scratch) catch rt.exit(99);
        rt.write("[window-files] frosted backdrop ready\n");
    }
    var viewport = ui.Surface.init(pixels, cfg.width, cfg.height, cfg.screen_width, .{ .red = 0xff0000, .green = 0xff00, .blue = 0xff }) catch rt.exit(99);
    viewport.setBackdrop(&backdrop.?, .{ .x = cfg.origin_x, .y = cfg.origin_y }) catch rt.exit(99);
    app.renderWindowWithWorkspace(&viewport, &workspace, model, locationRect(session)) catch rt.exit(99);
    ui.tabs.draw(&viewport, tabLayout(session), tab_state, .{}) catch rt.exit(99);
    if (model.edit == .none and menu_state.open_group != null) {
        const bar = menuLayout(cfg.width, cfg.height);
        ui.menu.drawBackground(&viewport, bar, menu_theme) catch rt.exit(99);
        app.renderWindowActionsWithWorkspace(&viewport, &workspace, model) catch rt.exit(99);
        ui.menu.drawContents(&viewport, bar, menu_state, menu_theme) catch rt.exit(99);
    }
    if (model.menu != null) app.renderWindowMenuWithWorkspace(&viewport, &workspace, model) catch rt.exit(99);
    session.submit();
}
fn locationRect(session: *const rt.window_client.Session) ui.Rect {
    return app.layout.WindowGeometry.navigationPath(session.config.?.width) catch rt.exit(99);
}
fn logPathChanges(activations: u64, commits: u64, rejections: u64) void {
    if (model.path_activations != activations) rt.write("[window-files] path editing\n");
    if (model.path_rejections != rejections) rt.write("[window-files] path rejected\n");
    if (model.path_commits != commits) {
        rt.write("[window-files] path navigated path=");
        rt.write(model.panes[model.focus].directory());
        rt.write("\n");
    }
}
export fn bedrock_user_main(parent: u64, inherited: u64, argument: u64) callconv(.c) noreturn {
    rt.markEntry();
    const info = rt.startup(parent, inherited, argument) catch rt.exit(99);
    rt.expect(parent != 0 and inherited == 0 and argument == 0 and info.app_id == abi.display.files);
    rt.expect(std.mem.eql(u8, rt.startup_record.argument(info, 0) orelse "", "org.bedrock.files"));
    rt.expect(std.mem.eql(u8, rt.startup_record.environment(info, "BEDROCK_ROLE") orelse "", "files"));
    seed();
    connection = rt.window_client.Hub.connect();
    openWindow(0) catch rt.exit(99);
    var authority_checked = false;
    while (true) {
        for (0..32) |_| {
            const routed = connection.poll() orelse break;
            const index = windowForId(routed.window_id) orelse continue;
            useWindow(index);
            const window = &windows[index];
            const session = window.session.?;
            const before = model.revision;
            switch (routed.event) {
                .input => |raw| {
                    if (window.closing) continue;
                    const input_event = ui.Event.decode(raw) catch rt.exit(99);
                    if (pending_transfer) |pending| {
                        if (index == pending.source or index == pending.destination) {
                            if (input_event.kind == .key_down and input_event.code == @backingInt(ui.input.Key.escape)) abortTransfer();
                            continue;
                        }
                    }
                    const cfg = session.config orelse continue;
                    const activations = model.path_activations;
                    const commits = model.path_commits;
                    const rejections = model.path_rejections;
                    if (cfg.width != 0) {
                        if (!dispatchTabs(session, input_event) and !dispatchMenu(session, input_event)) model.dispatchWindow(input_event, cfg.width, cfg.height, locationRect(session)) catch rt.exit(99);
                    }
                    shared_clipboard = model.clipboard;
                    logPathChanges(activations, commits, rejections);
                },
                .configured => {
                    menu_state.close();
                    tab_state.cancel();
                    const cfg = session.config.?;
                    const frozen_source = if (pending_transfer) |pending| pending.source == index else false;
                    if (cfg.width != 0 and !frozen_source) model.dispatchWindow(.{ .kind = .redraw, .code = 1 }, cfg.width, cfg.height, locationRect(session)) catch rt.exit(99);
                    if (!authority_checked and index == 0 and cfg.width != 0 and session.token != 0) {
                        checkAuthority(session);
                        authority_checked = true;
                        logTabs();
                        rt.write("[window-files] protected Files ready\n");
                    }
                    if (cfg.width != 0 and session.token != 0) prepareTransfer();
                },
                .closed => {
                    window.closing = true;
                    if (pending_transfer) |pending| {
                        if (pending.source == index or pending.destination == index) abortTransfer();
                    }
                },
                .rejected => {
                    window.closing = true;
                    if (pending_transfer) |pending| {
                        if (pending.source == index or pending.destination == index) abortTransfer();
                    }
                },
                .status => |status| {
                    menu_state.close();
                    if (status.focused_pid != info.pid) tab_state.cancel();
                    const frozen = if (pending_transfer) |pending| pending.source == index else false;
                    if (session.config) |cfg| if (cfg.width != 0 and !frozen) model.dispatchWindow(.{ .kind = .redraw, .code = 1 }, cfg.width, cfg.height, locationRect(session)) catch rt.exit(99);
                },
                .acknowledged => |sequence| {
                    const current_epoch = if (session.config) |cfg| @as(u32, @truncate(sequence >> 32)) == cfg.sequence and cfg.width != 0 else false;
                    if (!window.presented and current_epoch) {
                        window.presented = true;
                        if (session.window_id == 0) rt.write("[window-files] frame presented\n");
                    }
                    if (window.submitted_nullify > window.presented_nullify and current_epoch) {
                        window.presented_nullify = window.submitted_nullify;
                        rt.write("[window-files] Files nullify result frame presented\n");
                    }
                    // The old tab stays in its source until the new window has
                    // acknowledged a visible frame in its current configure epoch.
                    if (current_epoch) completeTransfer();
                },
            }
            if (before != model.revision) session.dirty = true;
        }
        if (pending_transfer) |pending| {
            const now = rt.syscall(abi.syscall.clock_ticks, 0, 0, 0);
            if (now -| pending.started > 2000) abortTransfer();
        }
        for (&windows, 0..) |*window, index| {
            if (!window.occupied) continue;
            const session = window.session.?;
            if (window.closing) {
                connection.retire(session) catch |err| {
                    if (err == error.Busy) continue;
                    rt.exit(99);
                };
                window.session = null;
                window.occupied = false;
                continue;
            }
            const cfg = session.config orelse continue;
            if (cfg.width == 0 or session.token == 0 or session.in_flight != null) continue;
            if (pending_transfer) |pending| if (pending.destination == index and !pending.presenting) continue;
            if (!session.dirty and window.startup_frames == 0) continue;
            useWindow(index);
            draw(session);
            window.submitted_nullify = provider.nullify_commits;
            if (window.startup_frames != 0) window.startup_frames -= 1;
        }
        if (connection.activeCount() == 0) {
            connection.close();
            rt.write("[window-files] Files closed cleanly\n");
            rt.exit(0);
        }
        rt.expect(rt.syscall(abi.syscall.sleep, 1, 0, 0) == 0);
    }
}
