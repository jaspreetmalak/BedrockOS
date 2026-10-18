//! A private, bounded ASCII notebook. The window service owns desktop policy.
const builtin = @import("builtin");
const std = @import("std");
const rt = @import("userspace_runtime");
const abi = @import("bedrock64");
const ui = @import("axisui");
const shell = @import("desktop_shell");
const navigation = @import("editor_navigation.zig");
pub const panic = std.debug.FullPanic(rt.panic);

const note_path = "/container/notes.txt";
const capacity = 4096;
const cell_width = ui.font.editor_advance;
const row_height = 22;
const colors = struct {
    const background = ui.Color.rgb(36, 40, 51);
    const chrome = ui.Color.rgb(42, 46, 59);
    const paper = ui.Color.rgb(45, 49, 63);
    const text = ui.Color.rgb(233, 235, 243);
    const muted = ui.Color.rgb(173, 179, 195);
    const accent = ui.Color.rgb(202, 186, 214);
    const button = ui.Color.rgb(57, 59, 75);
    const hover = ui.Color.rgb(68, 69, 86);
    const border = ui.Color.rgb(79, 83, 101);
    const error_color = ui.Color.rgb(255, 163, 151);
};
const materials = struct {
    const client: ui.Material = .{ .tint = colors.background, .opacity = 100 };
    const chrome: ui.Material = .{ .tint = colors.chrome, .opacity = 112 };
    const editor: ui.Material = .{ .tint = colors.paper, .opacity = 112 };
};
const Status = enum { new, loaded, saved, modified, full, load_failed, save_failed };
const Model = struct {
    bytes: [capacity]u8 = @splat(0),
    len: usize = 0,
    cursor: usize = 0,
    scroll: usize = 0,
    preferred_column: ?usize = null,
    modified: bool = false,
    save_hover: bool = false,
    save_pressed: bool = false,
    status: Status = .new,
    revision: u64 = 0,

    fn changed(self: *Model) void {
        self.revision += 1;
    }
    fn edited(self: *Model) void {
        self.modified = true;
        self.status = .modified;
        self.preferred_column = null;
        self.changed();
    }
    fn insert(self: *Model, bytes: []const u8) void {
        if (bytes.len > capacity - self.len) {
            self.status = .full;
            self.changed();
            return;
        }
        std.mem.copyBackwards(u8, self.bytes[self.cursor + bytes.len .. self.len + bytes.len], self.bytes[self.cursor..self.len]);
        @memcpy(self.bytes[self.cursor .. self.cursor + bytes.len], bytes);
        self.len += bytes.len;
        self.cursor += bytes.len;
        self.edited();
    }
};
const Line = navigation.Line;
const Position = navigation.Position;
const Geometry = struct {
    editor: ui.Rect,
    save: ui.Rect,
    columns: usize,
    rows: usize,
};
var model: Model = .{};
// Rendering and wrapped-line storage stay in the app's bounded BSS, never stack.
var workspace: ui.Workspace = undefined;
var lines: [capacity + 1]Line = undefined;
var line_count: usize = 0;
var footer_buffer: [160]u8 = undefined;
var log_buffer: [80]u8 = undefined;
// The backdrop is reconstructed from public wallpaper in Notes' own surface.
// Both blur buffers are app-owned; no other app pixels are readable here.
var backdrop_colors: [16000]u32 = undefined;
var backdrop_scratch: [16000]u32 = undefined;
var backdrop: ?ui.Backdrop = null;
var menu_state: ui.menu.State = .{};
const MenuCommand = enum(u32) { save = 1, reload, close, delete_previous, delete_next, newline, start, end };
var file_items = [_]ui.menu.Item{
    .{ .command = @backingInt(MenuCommand.save), .label = "Save", .shortcut = "Ctrl+S" },
    .{ .command = @backingInt(MenuCommand.reload), .label = "Reload from disk" },
    ui.menu.Item.divider(),
    .{ .command = @backingInt(MenuCommand.close), .label = "Close window", .shortcut = "Alt+F4" },
};
var edit_items = [_]ui.menu.Item{
    .{ .command = @backingInt(MenuCommand.delete_previous), .label = "Delete previous character", .shortcut = "Backspace" },
    .{ .command = @backingInt(MenuCommand.delete_next), .label = "Delete next character", .shortcut = "Delete" },
    ui.menu.Item.divider(),
    .{ .command = @backingInt(MenuCommand.newline), .label = "Insert new line", .shortcut = "Enter" },
};
const view_items = [_]ui.menu.Item{
    .{ .command = @backingInt(MenuCommand.start), .label = "Go to beginning", .shortcut = "Ctrl+Home" },
    .{ .command = @backingInt(MenuCommand.end), .label = "Go to end", .shortcut = "Ctrl+End" },
};
const menu_groups = [_]ui.menu.Group{
    .{ .label = "File", .items = &file_items },
    .{ .label = "Edit", .items = &edit_items },
    .{ .label = "View", .items = &view_items },
};
const menu_theme: ui.menu.Theme = .{
    .bar_material = materials.chrome,
    .bar_color = ui.Color.rgb(32, 35, 44),
    .bar_separator = ui.Color.rgb(55, 59, 71),
    .popup_material = .{ .tint = colors.chrome, .opacity = 150 },
    .selected_material = .{ .tint = colors.hover, .opacity = 145 },
    .text = colors.text,
    .disabled = colors.muted,
    .shortcut = colors.muted,
    .accent = colors.accent,
};

fn menuLayout(width: u32, height: u32) ui.menu.Layout {
    file_items[1].enabled = !model.modified;
    edit_items[0].enabled = model.cursor != 0;
    edit_items[1].enabled = model.cursor < model.len;
    edit_items[3].enabled = model.len < capacity;
    return ui.menu.Layout.initBar(.{ .groups = &menu_groups }, .{ .x = 0, .y = 0, .width = width, .height = height }, .{ .height = 46, .right = 100, .padding_top = 12, .padding_bottom = 6 }) catch rt.exit(99);
}
fn dispatchMenu(session: *rt.window_client.Session, event: ui.Event, info: *const abi.Startup) bool {
    const cfg = session.config.?;
    const layout = menuLayout(cfg.width, cfg.height);
    const was_open = menu_state.open_group != null;
    const activation = event.kind == .key_down and event.modifiers & ui.input.modifiers.alt != 0 and
        event.modifiers & (ui.input.modifiers.control | ui.input.modifiers.super) == 0;
    var result: ui.menu.Result = .{};
    if (activation and (event.code == 'f' or event.code == 'F' or event.code == 'e' or event.code == 'E' or event.code == 'v' or event.code == 'V')) {
        const group: usize = if (event.code == 'f' or event.code == 'F') 0 else if (event.code == 'e' or event.code == 'E') 1 else 2;
        result = .{ .consumed = menu_state.open(layout, group), .changed = true };
    } else result = menu_state.handle(layout, event);
    if (!was_open and menu_state.open_group != null) {
        model.save_pressed = false;
        model.save_hover = false;
    }
    if (result.changed) session.dirty = true;
    if (result.command) |command| {
        const action: MenuCommand = @fromBackingInt(@intCast(command));
        switch (action) {
            .save => save(),
            .reload => if (!model.modified) {
                // Reload is unavailable while unsaved changes exist. It uses
                // the same private checked file path as the startup loader.
                model.len = 0;
                model.status = .new;
                load();
                model.cursor = @min(model.cursor, model.len);
                model.scroll = 0;
                model.preferred_column = null;
                const g = geometry(cfg.width, cfg.height);
                wrap(g.columns);
                revealCursor(g);
                model.changed();
            },
            .close => session.requestClose(),
            .delete_previous, .delete_next, .newline, .start, .end => {
                const key: ui.input.Key = switch (action) {
                    .delete_previous => .backspace,
                    .delete_next => .delete,
                    .newline => .enter,
                    .start => .home,
                    .end => .end,
                    else => unreachable,
                };
                dispatch(.{ .kind = .key_down, .code = @backingInt(key), .modifiers = if (action == .start or action == .end) ui.input.modifiers.control else 0 }, cfg.width, cfg.height, info);
            },
        }
    }
    return event.kind != .redraw and result.consumed;
}

fn geometry(width: u32, height: u32) Geometry {
    const x = @min(width, 12);
    const y = @min(height, 58);
    const editor_width = width -| 24;
    const editor_height = height -| 96;
    const save_x = width -| 88;
    return .{
        .editor = .{ .x = @intCast(x), .y = @intCast(y), .width = editor_width, .height = editor_height },
        .save = .{ .x = @intCast(save_x), .y = 8, .width = @min(width - save_x, 80), .height = @min(height -| 8, 30) },
        .columns = @max(1, (editor_width -| 2) / cell_width),
        .rows = @max(1, editor_height / row_height),
    };
}
fn wrap(columns: usize) void {
    line_count = 0;
    var start: usize = 0;
    while (true) {
        var end = start;
        while (end < model.len and model.bytes[end] != '\n' and end - start < columns) : (end += 1) {}
        lines[line_count] = .{ .start = @intCast(start), .end = @intCast(end) };
        line_count += 1;
        if (end == model.len) break;
        start = if (model.bytes[end] == '\n') end + 1 else end;
    }
}
fn cursorPosition() Position {
    return navigation.position(lines[0..line_count], model.cursor);
}
fn revealCursor(g: Geometry) void {
    const position = cursorPosition();
    if (position.row < model.scroll) model.scroll = position.row;
    if (position.row >= model.scroll + g.rows) model.scroll = position.row + 1 - g.rows;
    model.scroll = @min(model.scroll, line_count -| g.rows);
}
fn moveVertical(delta: i64, g: Geometry) void {
    const position = cursorPosition();
    const column = model.preferred_column orelse position.column;
    const row: usize = @intCast(std.math.clamp(@as(i64, @intCast(position.row)) + delta, 0, @as(i64, @intCast(line_count - 1))));
    model.cursor = navigation.verticalTarget(lines[0..line_count], row, column);
    model.preferred_column = column;
    revealCursor(g);
    model.changed();
}

fn load() void {
    const file = rt.open(note_path, abi.open_flags.read);
    if (file == abi.errno.no_entry) return;
    if (abi.isError(file)) {
        model.status = .load_failed;
        return;
    }
    defer _ = rt.close(file);
    const size = rt.seek(file, 0, abi.seek_whence.end);
    if (abi.isError(size) or size > capacity or rt.seek(file, 0, abi.seek_whence.set) != 0) {
        model.status = .load_failed;
        return;
    }
    var done: usize = 0;
    while (done < size) {
        const result = rt.read(file, model.bytes[done..@min(@as(usize, @intCast(size)), done + abi.max_io)]);
        if (abi.isError(result) or result == 0 or result > @min(size - done, abi.max_io)) {
            model.len = 0;
            model.status = .load_failed;
            return;
        }
        done += @intCast(result);
    }
    // Private state is still untrusted input. Keep the editor/font contract ASCII.
    for (model.bytes[0..done]) |*byte| {
        if (byte.* != '\n' and (byte.* < 32 or byte.* > 126)) byte.* = '?';
    }
    model.len = done;
    model.status = .loaded;
    rt.write(std.fmt.bufPrint(&log_buffer, "[window-notes] loaded bytes={d}\n", .{model.len}) catch rt.exit(99));
}
fn save() void {
    if (!model.modified and (model.status == .loaded or model.status == .saved)) {
        model.status = .saved;
        model.changed();
        rt.write(std.fmt.bufPrint(&log_buffer, "[window-notes] saved bytes={d}\n", .{model.len}) catch rt.exit(99));
        return;
    }
    const file = rt.open(note_path, abi.open_flags.write | abi.open_flags.create | abi.open_flags.truncate);
    if (abi.isError(file)) {
        model.status = .save_failed;
        model.changed();
        return;
    }
    var done: usize = 0;
    var failed = false;
    while (done < model.len) {
        const input = model.bytes[done..@min(model.len, done + abi.max_io)];
        const result = rt.writeFd(file, input);
        if (abi.isError(result) or result == 0 or result > input.len) {
            failed = true;
            break;
        }
        done += @intCast(result);
    }
    if (rt.close(file) != 0) failed = true;
    if (failed) {
        model.status = .save_failed;
    } else {
        model.modified = false;
        model.status = .saved;
        rt.write(std.fmt.bufPrint(&log_buffer, "[window-notes] saved bytes={d}\n", .{model.len}) catch rt.exit(99));
    }
    model.changed();
}

fn checkAuthority(session: *const rt.window_client.Session) void {
    rt.expect(rt.serviceConnect(abi.display.service) == abi.errno.busy);
    var display: abi.DisplayInfo = .{};
    var input: abi.DisplayInput = .{};
    const present: abi.PresentRequest = .{ .surface_token = session.token, .x = 0, .y = 0, .width = 1, .height = 1, .sequence = 1 };
    rt.expect(rt.displayInfo(&display) == abi.errno.permission and rt.displayInput(&input) == abi.errno.permission and rt.displayPresent(&present) == abi.errno.permission);
    rt.expect(rt.serviceOpen(abi.display.service) == abi.errno.permission);
    rt.expect(rt.desktopState(1) == abi.errno.permission and rt.windowState(1, 0, 0) == abi.errno.permission);
    rt.expect(rt.spawnApp(abi.display.files, 0, 0) == abi.errno.permission);
    rt.expect(rt.surfaceMap(session.token, 0, false) == abi.errno.permission);
    var forged: abi.ServiceMessage = .{ .kind = abi.display.heartbeat, .sequence = 1, .peer_pid = 1 };
    rt.expect(rt.serviceSend(session.endpoint, &forged) == abi.errno.permission);
    forged.peer_pid = 0;
    forged.surface = session.token;
    rt.expect(rt.serviceSend(session.endpoint, &forged) == abi.errno.permission);
    var control: abi.ServiceMessage = .{ .kind = abi.display.focus_window, .sequence = 1, .peer_app = abi.display.files };
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
    const traversal = rt.open("/container/../0000000000000002/notes.txt", abi.open_flags.read);
    rt.expect(traversal == abi.errno.permission or traversal == abi.errno.invalid);
    rt.expect(rt.open("/private/2/container/notes.txt", abi.open_flags.read) == abi.errno.permission);
    rt.expect(rt.open("/bundle/main.elf", abi.open_flags.write) == abi.errno.permission);
    for ([_]u64{ abi.syscall.udp_open, abi.syscall.udp_send, abi.syscall.udp_receive }) |number| rt.expect(rt.syscall(number, 0, 0, 0) == abi.errno.permission);
    for ([_]u64{ abi.syscall.wifi_status, abi.syscall.wifi_scan_start, abi.syscall.wifi_scan_read, abi.syscall.wifi_join, abi.syscall.wifi_disconnect, abi.syscall.wifi_enable }) |number| rt.expect(rt.syscall(number, 0, 0, 0) == abi.errno.permission);
    rt.write("[window-notes] raw display/input, launch, foreign files and network denied\n");
    rt.write("[window-notes] duplicate connection and forged window controls denied\n");
    rt.write("[window-notes] authority checks passed\n");
}
fn startupWrite(info: *const abi.Startup) noreturn {
    const address = @intFromPtr(info);
    switch (builtin.cpu.arch) {
        .x86_64 => asm volatile ("movb $1, (%[address])"
            :
            : [address] "r" (address),
            : .{ .memory = true }),
        .aarch64 => asm volatile ("strb wzr, [%[address]]"
            :
            : [address] "r" (address),
            : .{ .memory = true }),
        .riscv64 => asm volatile ("sb zero, 0(%[address])"
            :
            : [address] "r" (address),
            : .{ .memory = true }),
        else => unreachable,
    }
    rt.exit(99);
}
fn dispatch(event: ui.Event, width: u32, height: u32, info: *const abi.Startup) void {
    const g = geometry(width, height);
    wrap(g.columns);
    const point: ui.Point = .{ .x = event.x, .y = event.y };
    switch (event.kind) {
        .pointer_move => {
            const hover = g.save.contains(point);
            if (hover != model.save_hover) {
                model.save_hover = hover;
                model.changed();
            }
        },
        .pointer_down => {
            if (event.code != @backingInt(ui.input.Button.left)) return;
            model.save_pressed = g.save.contains(point);
            if (g.editor.contains(point)) {
                const row = @min(line_count - 1, model.scroll + @as(usize, @intCast(@divTrunc(point.y - g.editor.y, row_height))));
                const line = lines[row];
                const column: usize = @intCast(@divTrunc(point.x - g.editor.x + @as(i32, @intCast(cell_width / 2)), @as(i32, @intCast(cell_width))));
                model.cursor = line.start + @min(column, line.end - line.start);
                model.preferred_column = null;
                revealCursor(g);
            }
            model.changed();
        },
        .pointer_up => {
            if (event.code != @backingInt(ui.input.Button.left)) return;
            const activate = model.save_pressed and g.save.contains(point);
            model.save_pressed = false;
            model.changed();
            if (activate) save();
        },
        .wheel => {
            const delta: i16 = @bitCast(event.code);
            model.scroll = @intCast(std.math.clamp(@as(i64, @intCast(model.scroll)) + delta, 0, @as(i64, @intCast(line_count -| g.rows))));
            model.changed();
        },
        .redraw => {
            if (event.code == 1) model.save_pressed = false;
            revealCursor(g);
            model.changed();
        },
        .text => {
            if (event.modifiers & (ui.input.modifiers.control | ui.input.modifiers.alt | ui.input.modifiers.super) != 0 or event.code < 32 or event.code > 126) return;
            const byte = [_]u8{@intCast(event.code)};
            model.insert(&byte);
            wrap(g.columns);
            revealCursor(g);
        },
        .key_down => {
            const control = event.modifiers & ui.input.modifiers.control != 0;
            if (control and event.modifiers & ui.input.modifiers.shift != 0 and event.code == @backingInt(ui.input.Key.f5)) {
                if (info.flags & abi.application.test_mode != 0) {
                    rt.write("[window-notes] deliberate startup write fault requested\n");
                    startupWrite(info);
                }
                return;
            }
            if (control and (event.code == 's' or event.code == 'S')) {
                save();
                return;
            }
            if (event.modifiers & (ui.input.modifiers.alt | ui.input.modifiers.super) != 0) return;
            model.save_pressed = false;
            if (control) {
                switch (event.code) {
                    @backingInt(ui.input.Key.home) => model.cursor = 0,
                    @backingInt(ui.input.Key.end) => model.cursor = model.len,
                    else => return,
                }
            } else switch (event.code) {
                @backingInt(ui.input.Key.enter) => model.insert("\n"),
                @backingInt(ui.input.Key.tab) => model.insert("    "),
                @backingInt(ui.input.Key.backspace) => if (model.cursor != 0) {
                    std.mem.copyForwards(u8, model.bytes[model.cursor - 1 .. model.len - 1], model.bytes[model.cursor..model.len]);
                    model.len -= 1;
                    model.cursor -= 1;
                    model.edited();
                },
                @backingInt(ui.input.Key.delete) => if (model.cursor < model.len) {
                    std.mem.copyForwards(u8, model.bytes[model.cursor .. model.len - 1], model.bytes[model.cursor + 1 .. model.len]);
                    model.len -= 1;
                    model.edited();
                },
                @backingInt(ui.input.Key.left) => model.cursor -|= 1,
                @backingInt(ui.input.Key.right) => model.cursor = @min(model.len, model.cursor + 1),
                @backingInt(ui.input.Key.home) => {
                    while (model.cursor != 0 and model.bytes[model.cursor - 1] != '\n') model.cursor -= 1;
                },
                @backingInt(ui.input.Key.end) => {
                    while (model.cursor != model.len and model.bytes[model.cursor] != '\n') model.cursor += 1;
                },
                @backingInt(ui.input.Key.up) => return moveVertical(-1, g),
                @backingInt(ui.input.Key.down) => return moveVertical(1, g),
                @backingInt(ui.input.Key.page_up) => return moveVertical(-@as(i64, @intCast(g.rows)), g),
                @backingInt(ui.input.Key.page_down) => return moveVertical(@intCast(g.rows), g),
                else => return,
            }
            model.preferred_column = null;
            wrap(g.columns);
            revealCursor(g);
            model.changed();
        },
        .key_up => {},
    }
}

fn statusText() []const u8 {
    return switch (model.status) {
        .new => "New note",
        .loaded => "Loaded",
        .saved => "Saved",
        .modified => "Unsaved changes",
        .full => "4096-byte limit reached",
        .load_failed => "Could not load note",
        .save_failed => "Save failed - retry Ctrl+S",
    };
}
fn paintGlyph(surface: *ui.Surface, byte: u8, x: u32, y: u32, color: ui.Color) void {
    const inset = (cell_width - ui.font.glyphAdvance(byte)) / 2;
    ui.font.paintGlyph(surface, byte, @intCast(x + inset), @intCast(y), color, 1) catch rt.exit(99);
}
fn draw(session: *rt.window_client.Session) void {
    const cfg = session.config.?;
    const pixels = session.map();
    if (backdrop == null) {
        var full = ui.Surface.init(pixels, cfg.screen_width, cfg.screen_height, cfg.screen_width, .{ .red = 0xff0000, .green = 0xff00, .blue = 0xff }) catch rt.exit(99);
        shell.renderWallpaper(&full) catch rt.exit(99);
        backdrop = ui.Backdrop.build(&full, &backdrop_colors, &backdrop_scratch) catch rt.exit(99);
        rt.write("[window-notes] frosted backdrop ready\n");
    }
    var surface = ui.Surface.init(pixels, cfg.width, cfg.height, cfg.screen_width, .{ .red = 0xff0000, .green = 0xff00, .blue = 0xff }) catch rt.exit(99);
    surface.setBackdrop(&backdrop.?, .{ .x = cfg.origin_x, .y = cfg.origin_y }) catch rt.exit(99);
    const g = geometry(cfg.width, cfg.height);
    wrap(g.columns);
    model.scroll = @min(model.scroll, line_count -| g.rows);
    const position = cursorPosition();
    const footer = std.fmt.bufPrint(&footer_buffer, "{s}   {d}/4096 bytes   Ln {d}, Col {d}   Ctrl+S Save", .{ statusText(), model.len, position.row + 1, position.column + 1 }) catch rt.exit(99);
    const save_tint = if (model.save_pressed) colors.hover else if (model.save_hover) colors.button else colors.paper;
    const save_button = ui.Text("Save").frame(80, 30).@"align"(.center).textVerticalAlign(.center).foreground(colors.text).cornerRadius(4).smoothCorners().material(.{ .tint = save_tint, .opacity = if (model.save_pressed) 170 else if (model.save_hover) 145 else 110 });
    const toolbar_items = [_]ui.View{
        comptime ui.Text("notes.txt").frame(96, 30).foreground(colors.muted).@"align"(.center),
        comptime ui.Spacer(),
        save_button,
    };
    const content = [_]ui.View{
        ui.HStack(&toolbar_items).frame(null, 46).padding(8).gap(10).@"align"(.center).material(materials.chrome),
        comptime ui.Spacer(),
        ui.Text(footer).frame(null, 30).padding(7).textVerticalAlign(.center).foreground(if (model.status == .load_failed or model.status == .save_failed or model.status == .full) colors.error_color else colors.muted).material(materials.chrome),
    };
    ui.renderWithWorkspace(&surface, &workspace, ui.VStack(&content).material(materials.client)) catch rt.exit(99);
    if (g.editor.width != 0 and g.editor.height != 0) {
        const panel_x = g.editor.x -| 6;
        const panel_y = g.editor.y -| 8;
        surface.roundedMaterialRect(panel_x, panel_y, g.editor.width + 12, g.editor.height + 16, 6, materials.editor);
        surface.roundedBorder(panel_x, panel_y, g.editor.width + 12, g.editor.height + 16, 6, colors.border, 1, 48);
        const offset = @as(usize, @intCast(g.editor.y)) * cfg.screen_width + @as(usize, @intCast(g.editor.x));
        var editor = ui.Surface.init(pixels[offset..], g.editor.width, g.editor.height, cfg.screen_width, surface.masks) catch rt.exit(99);
        const last = @min(line_count, model.scroll + g.rows);
        for (model.scroll..last) |row| {
            const line = lines[row];
            const y: u32 = @as(u32, @intCast(row - model.scroll)) * row_height;
            for (model.bytes[line.start..line.end], 0..) |byte, column| paintGlyph(&editor, byte, @as(u32, @intCast(column)) * cell_width, y, colors.text);
        }
        if (position.row >= model.scroll and position.row < model.scroll + g.rows) {
            const x: u32 = @as(u32, @intCast(position.column)) * cell_width;
            const y: u32 = @as(u32, @intCast(position.row - model.scroll)) * row_height;
            editor.fillRect(x, y, 1, ui.font.line_height, surface.encode(colors.accent));
        }
    }
    const bar = menuLayout(cfg.width, cfg.height);
    ui.menu.drawBackground(&surface, bar, menu_theme) catch rt.exit(99);
    // Save is app-owned trailing content on the same configurable menu strip.
    const save_offset = @as(usize, @intCast(g.save.y)) * surface.stride + @as(usize, @intCast(g.save.x));
    var save_surface = ui.Surface.init(surface.pixels[save_offset..], g.save.width, g.save.height, surface.stride, surface.masks) catch rt.exit(99);
    save_surface.setBackdrop(&backdrop.?, .{ .x = cfg.origin_x + g.save.x, .y = cfg.origin_y + g.save.y }) catch rt.exit(99);
    ui.renderWithWorkspace(&save_surface, &workspace, save_button) catch rt.exit(99);
    ui.menu.drawContents(&surface, bar, &menu_state, menu_theme) catch rt.exit(99);
    session.submit();
}

export fn bedrock_user_main(parent: u64, inherited: u64, argument: u64) callconv(.c) noreturn {
    rt.markEntry();
    const info = rt.startup(parent, inherited, argument) catch rt.exit(99);
    rt.expect(parent != 0 and inherited == 0 and argument == 0 and info.app_id == abi.display.notes);
    rt.expect(std.mem.eql(u8, rt.startup_record.argument(info, 0) orelse "", "org.bedrock.notes"));
    rt.expect(std.mem.eql(u8, rt.startup_record.environment(info, "BEDROCK_ROLE") orelse "", "notes"));
    load();
    var session = rt.window_client.Session.openWindow(.{ .title = "Notes", .preferred_width = 620, .preferred_height = 420 });
    session.awaitConfiguration();
    checkAuthority(&session);
    rt.write("[window-notes] protected Notes ready\n");
    var presented = false;
    var startup_frames: u8 = 3;
    while (true) {
        const revision = model.revision;
        for (0..32) |_| {
            const event = session.poll() orelse break;
            switch (event) {
                .input => |raw| {
                    const cfg = session.config.?;
                    if (cfg.width != 0) {
                        const input_event = ui.Event.decode(raw) catch rt.exit(99);
                        if (!dispatchMenu(&session, input_event, info)) dispatch(input_event, cfg.width, cfg.height, info);
                    }
                },
                .configured => {
                    menu_state.close();
                    const cfg = session.config.?;
                    if (cfg.width != 0) dispatch(.{ .kind = .redraw, .code = 1 }, cfg.width, cfg.height, info);
                },
                .closed => {
                    rt.write("[window-notes] Notes closed cleanly\n");
                    session.close();
                },
                .rejected => rt.exit(99),
                .acknowledged => |sequence| {
                    if (!presented and @as(u32, @truncate(sequence >> 32)) == session.config.?.sequence and session.config.?.width != 0) {
                        presented = true;
                        rt.write("[window-notes] frame presented\n");
                    }
                },
                .status => {
                    menu_state.close();
                    model.save_pressed = false;
                },
            }
        }
        if (revision != model.revision) session.dirty = true;
        if (session.config.?.width != 0 and session.in_flight == null and (session.dirty or startup_frames != 0)) {
            draw(&session);
            if (startup_frames != 0) startup_frames -= 1;
        }
        rt.expect(rt.syscall(abi.syscall.sleep, 1, 0, 0) == 0);
    }
}
