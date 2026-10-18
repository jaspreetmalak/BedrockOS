//! Privileged host for window policy and a protected native Files process.
//! Apps receive clipped draw commands and scoped VFS requests, never scanout,
//! raw input transport, disks, page tables or another container's identity.
const std = @import("std");
const builtin = @import("builtin");
const protocol = @import("boot_protocol");
const memory = @import("memory_init");
const arch = @import("isolation_arch");
const contract = @import("isolation_contract");
const security = @import("security");
const abi = @import("bedrock64");
const vfs = @import("vfs.zig");
const requests = @import("directory_syscalls.zig");
const user = @import("user_memory.zig");
const elf = @import("user_elf.zig");
const disk = @import("storage_runtime.zig");
const virtio = @import("virtio");
const shell = @import("desktop_shell");
const ui = shell.axisui;
const windows = @import("window_server");
const Owner = memory.ownership.Owner(3);
const Files = vfs.Files(8);
var active = false;
var stopped = false;
var waiting = false;
var frames: contract.TaskMemory = undefined;
var context: contract.ContextHandle = undefined;
var profile: security.sandbox.Profile = undefined;
var files: Files = undefined;
var display: ui.Surface = undefined;
var backdrop: ui.Backdrop = undefined;
var backdrop_ticket: ?memory.heap_api.Ticket = null;
var window: windows.Window = undefined;
var workspace: ui.Workspace = undefined;
var events: ui.Queue(64) = .{};
var decoder: virtio.Decoder = undefined;
var write_console: *const fn ([]const u8) void = undefined;
var architecture_label: []const u8 = undefined;
var presents: u64 = 0;
var draw_requests: u64 = 0;
var material_requests: u64 = 0;
var material_frame_reported = false;
var nullify_result_pending = false;
var owner: ?Owner = null;
var address_space: ?contract.AddressSpace = null;
var close_requested = false;
var baseline_free_pages: u64 = 0;
var paint_width: u32 = 0;
var paint_height: u32 = 0;
var open_requested = false;
var launcher_pressed = false;
var input_tick: u64 = 0;
var previous_click_tick: u64 = 0;
var previous_click: ui.Point = .{ .x = 0, .y = 0 };
var previous_click_valid = false;
var pointer_press: ui.Point = .{ .x = 0, .y = 0 };
var pointer_moved = false;
var cursor = ui.Point{ .x = 0, .y = 0 };
var cursor_visible = false;
var cursor_saved: [18 * 12]u32 = undefined;

pub fn isActive() bool {
    return active;
}
pub fn run(comptime console: type, info: *const protocol.BootInfo, architecture: []const u8) !void {
    try info.framebuffer.validate();
    if (info.framebuffer.base == 0) return error.FramebufferUnavailable;
    const fb = info.framebuffer;
    const pixels: [*]volatile u32 = @ptrFromInt(fb.base);
    display = try ui.Surface.init(pixels[0..@intCast(fb.size / 4)], fb.width, fb.height, fb.pixels_per_scanline, .{ .red = fb.red_mask, .green = fb.green_mask, .blue = fb.blue_mask });
    window = try windows.Window.init(fb.width, fb.height);
    decoder = try virtio.Decoder.init(fb.width, fb.height);
    architecture_label = architecture;
    write_console = &struct {
        fn write(bytes: []const u8) void {
            console.write(bytes);
        }
    }.write;
    try prepareBackdrop();
    defer releaseBackdrop() catch @panic("desktop backdrop teardown");
    profile = try security.sandbox.Profile.init(2, 0, 0);
    files = try Files.init(profile);
    try disk.storage.prepareContainer(profile.app_id);
    try disk.storage.mountBundle(profile, "/bundle/Files.elf", @embedFile("user_files_image"), true);
    try seedDirectory("/container/Documents");
    try seedDirectory("/container/Downloads");
    // Optional home-directory upgrade must not reject existing full disks or
    // replace a user item already named Desktop.
    disk.storage.mkdir(profile, "/container/Desktop") catch {};
    try seedWelcome();
    try launchClient();
    defer retireClient() catch @panic("desktop client teardown");
    try background();
    while (true) {
        try pollInput();
        if (stopped or close_requested) {
            window.close();
            try retireClient();
            stopped = false;
            close_requested = false;
            try background();
        }
        if (open_requested) {
            open_requested = false;
            window.open();
            try background();
            if (active) try refresh();
        }
        if (window.closed) {
            try idleTick();
            continue;
        }
        if (!active) try launchClient();
        if (waiting) {
            if (events.pop()) |event| {
                try arch.setContextResult(context, event.encode());
                waiting = false;
            } else {
                try idleTick();
                continue;
            }
        }
        try arch.validateContext(context);
        arch.resumeContext(context);
    }
}
fn launchClient() !void {
    if (active or owner != null or address_space != null) return error.DesktopClientAlreadyRunning;
    const bytes = try disk.storage.execPath(profile, "/bundle/Files.elf");
    const image = try elf.inspectDesktop(bytes, builtin.cpu.arch);
    files = try Files.init(profile);
    baseline_free_pages = memory.allocator().?.stats().free_pages;
    var client_owner = try Owner.init(memory.allocator().?, try memory.newOwnerId());
    errdefer client_owner.releaseAll() catch @panic("desktop launch rollback");
    var code_pages: u16 = 0;
    var data_pages: u16 = 0;
    for (image.segments[0..image.count]) |segment| {
        if (segment.flags == 5) code_pages = @intCast((segment.address + segment.memory_size - contract.desktop_code + 4095) / 4096) else data_pages = @intCast((segment.address + segment.memory_size - contract.desktop_data + 4095) / 4096);
    }
    frames = .{ .code = try allocate(&client_owner, code_pages), .data = try allocate(&client_owner, data_pages), .stack = try allocate(&client_owner, 16), .code_pages = code_pages, .data_pages = data_pages, .stack_pages = 16, .desktop = true };
    try frames.validate();
    for (image.segments[0..image.count]) |segment| {
        const base = if (segment.flags == 5) frames.code else frames.data;
        const virtual = if (segment.flags == 5) frames.codeVirtual() else frames.dataVirtual();
        const output: [*]volatile u8 = @ptrFromInt(base + segment.address - virtual);
        for (bytes[@intCast(segment.offset)..@intCast(segment.offset + segment.file_size)], 0..) |byte, i| output[i] = byte;
    }
    const space = try arch.create(frames);
    errdefer arch.destroy(space) catch @panic("desktop root rollback");
    context = try arch.createContext(space, .{ .entry = image.entry, .user_sp = frames.stackTop(), .arg0 = 0, .arg1 = 0, .arg2 = 0 });
    owner = client_owner;
    address_space = space;
    events = .{};
    waiting = false;
    stopped = false;
    close_requested = false;
    presents = 0;
    nullify_result_pending = false;
    draw_requests = 0;
    material_requests = 0;
    material_frame_reported = false;
    paint_width = 0;
    paint_height = 0;
    previous_click_valid = false;
    active = true;
    write_console("[kernel] protected Files launched\n");
}
fn retireClient() !void {
    if (!active) return;
    _ = files.closeAll();
    try arch.destroyContext(context);
    try arch.destroy(address_space.?);
    try owner.?.releaseAll();
    owner = null;
    address_space = null;
    active = false;
    waiting = false;
    events = .{};
    if (memory.allocator().?.stats().free_pages != baseline_free_pages) return error.DesktopResourceLeak;
    write_console("[kernel] Files closed; resources reclaimed\n");
}
fn allocate(client_owner: *Owner, pages: usize) !u64 {
    const ticket = try client_owner.allocate(pages, 1);
    const range = try client_owner.resolve(ticket);
    memory.clearRange(range);
    return range.base;
}
fn prepareBackdrop() !void {
    // Desktop-owned cache and blur scratch are separate from scanout and every
    // app mapping. Build from wallpaper only, before bars, windows or cursor.
    const count = try ui.Backdrop.requiredLen(display.width, display.height);
    const ticket = try memory.allocateKernel(count * @sizeOf(u32) * 2, @alignOf(u32));
    errdefer memory.freeKernel(ticket) catch @panic("backdrop allocation rollback");
    const block = try memory.resolveKernel(ticket);
    const storage: [*]u32 = @ptrFromInt(block.range.base);
    try shell.renderWallpaper(&display);
    backdrop = try ui.Backdrop.build(&display, storage[0..count], storage[count .. count * 2]);
    try display.setBackdrop(&backdrop, .{ .x = 0, .y = 0 });
    backdrop_ticket = ticket;
    write_console("[kernel] immutable frosted backdrop cached\n");
}
fn releaseBackdrop() !void {
    try display.setBackdrop(null, .{ .x = 0, .y = 0 });
    if (backdrop_ticket) |ticket| try memory.freeKernel(ticket);
    backdrop_ticket = null;
}
fn seedDirectory(path: []const u8) !void {
    disk.storage.mkdir(profile, path) catch |err| if (err != error.AlreadyExists) return err;
}
fn seedWelcome() !void {
    // Seed only a fresh Documents directory. Never recreate a file that a user
    // deliberately moved/deleted on a previous boot.
    var cursor_value: usize = 0;
    if ((try disk.storage.list(profile, "/container/Documents", &cursor_value)) != null) return;
    cursor_value = 0;
    if ((try disk.storage.list(profile, "/container/Downloads", &cursor_value)) != null) return;
    const marker = files.open(&disk.storage, profile, "/container/.initialized", .{ .read = true }) catch |err| {
        if (err != error.NotFound) return err;
        const fd = try files.open(&disk.storage, profile, "/container/Documents/welcome.txt", .{ .write = true, .create = true });
        errdefer files.close(profile, fd) catch {};
        _ = try files.write(&disk.storage, profile, fd, "Welcome to Bedrock.\nDrag this file into Downloads.\nCtrl-drag copies; F2 renames.\nYour files survive reboot.\n");
        try files.close(profile, fd);
        const initialized = try files.open(&disk.storage, profile, "/container/.initialized", .{ .write = true, .create = true });
        try files.close(profile, initialized);
        return;
    };
    try files.close(profile, marker);
}
fn regions() [3]user.Region {
    const maps = frames.mappings();
    var result: [3]user.Region = undefined;
    for (maps, 0..) |range, i| result[i] = .{ .virtual = range.virtual, .physical = range.physical, .length = @as(u64, range.pages) * 4096, .writable = range.writable };
    return result;
}
pub fn dispatch(event: *const contract.Event, reply: *contract.Reply) void {
    reply.* = .{ .action = contract.action_resume, .result = 0 };
    if (event.kind == contract.event_fault) {
        write_console("[kernel] Files fault pc/address= ");
        writeHex(event.pc);
        writeHex(event.fault_address);
        stopped = true;
        reply.action = contract.action_terminate;
        return;
    }
    if (event.kind == contract.event_timer) {
        input_tick +%= 1;
        reply.action = contract.action_suspend;
        return;
    }
    if (event.kind != contract.event_syscall) @panic("unexpected desktop event");
    serve(event, reply) catch |err| {
        reply.result = @import("process_runtime.zig").errorResult(err);
    };
    // Closing can arrive while the user is repainting. Retire only after
    // leaving its active trap/context and returning to the kernel host loop.
    if (close_requested and reply.action == contract.action_resume) reply.action = contract.action_suspend;
}
fn serve(event: *const contract.Event, reply: *contract.Reply) !void {
    const mappings = regions();
    switch (event.number) {
        abi.syscall.ui_geometry => {
            paint_width = window.client().width;
            paint_height = window.client().height;
            reply.result = (@as(u64, paint_width) << 32) | paint_height;
        },
        abi.syscall.ui_event => {
            if (events.pop()) |value| reply.result = value.encode() else {
                waiting = true;
                reply.action = contract.action_suspend;
            }
        },
        abi.syscall.ui_pending => {
            if (event.arg0 != 0 or event.arg1 != 0 or event.arg2 != 0) return error.InvalidRequest;
            try pollInput();
            if (events.pop()) |value| reply.result = value.encode();
        },
        abi.syscall.ui_rect => {
            if (event.arg1 != 0 or event.arg2 != 0) return error.InvalidRequest;
            var rect: abi.DrawRect = undefined;
            try requests.copyin(&mappings, event.arg0, std.mem.asBytes(&rect));
            if (rect.reserved != 0 or rect.color & 0xff000000 != 0) return error.InvalidRequest;
            // A large software repaint can make thousands of syscalls before
            // blocking again. Drain hardware regularly so pointer/key state
            // does not accumulate across the whole repaint.
            draw_requests +%= 1;
            if (draw_requests & 31 == 0) try pollInput();
            if (window.visible) drawClient(rect);
        },
        abi.syscall.ui_material => {
            if (event.arg1 != 0 or event.arg2 != 0) return error.InvalidRequest;
            var request: abi.DrawMaterial = undefined;
            try requests.copyin(&mappings, event.arg0, std.mem.asBytes(&request));
            if (request.reserved != 0 or request.tint & 0xff000000 != 0 or request.opacity > 255)
                return error.InvalidRequest;
            draw_requests +%= 1;
            if (draw_requests & 31 == 0) try pollInput();
            if (window.visible) drawClientMaterial(request);
        },
        abi.syscall.ui_present => {
            presents += 1;
            showCursor();
            if (presents == 1) write_console("[kernel] protected Files frame presented\n");
            if (!material_frame_reported and material_requests != 0) {
                material_frame_reported = true;
                write_console("[kernel] frosted Files frame presented\n");
            }
            if (nullify_result_pending) {
                nullify_result_pending = false;
                write_console("[kernel] Files nullify result frame presented\n");
            }
        },
        abi.syscall.list, abi.syscall.mkdir, abi.syscall.copy, abi.syscall.rename, abi.syscall.unlink, abi.syscall.nullify => {
            reply.result = try requests.serve(profile, &mappings, event.number, event.arg0, event.arg1, event.arg2);
            if (event.number != abi.syscall.list) write_console("[kernel] Files namespace transaction committed\n");
            if (event.number == abi.syscall.nullify) {
                nullify_result_pending = true;
                write_console("[kernel] Files nullify logical banks verified\n");
            }
        },
        abi.syscall.udp_open, abi.syscall.udp_send, abi.syscall.udp_receive => return error.PermissionDenied,
        abi.syscall.wifi_status, abi.syscall.wifi_scan_start, abi.syscall.wifi_scan_read, abi.syscall.wifi_join, abi.syscall.wifi_disconnect, abi.syscall.wifi_enable => return error.PermissionDenied,
        abi.syscall.open => {
            const target = try requests.path(&mappings, event.arg0, event.arg1);
            if (event.arg2 & ~@as(u64, 15) != 0) return error.InvalidOpenFlags;
            reply.result = @backingInt(try files.open(&disk.storage, profile, target.slice(), .{ .read = event.arg2 & 1 != 0, .write = event.arg2 & 2 != 0, .create = event.arg2 & 4 != 0, .truncate = event.arg2 & 8 != 0 }));
        },
        abi.syscall.close => try files.close(profile, @fromBackingInt(event.arg0)),
        abi.syscall.seek => {
            const whence: vfs.Whence = switch (event.arg2) {
                0 => .start,
                1 => .current,
                2 => .end,
                else => return error.InvalidSeek,
            };
            reply.result = try files.seek(&disk.storage, profile, @fromBackingInt(event.arg0), @bitCast(event.arg1), whence);
        },
        abi.syscall.read => {
            if (event.arg2 > abi.max_io) return error.InvalidReadLength;
            const length: usize = @intCast(event.arg2);
            if (length != 0) _ = try user.translateWrite(&mappings, event.arg1, length);
            var buffer: [abi.max_io]u8 = undefined;
            const got = try files.read(&disk.storage, profile, @fromBackingInt(event.arg0), buffer[0..length]);
            try requests.copyout(&mappings, event.arg1, buffer[0..got]);
            reply.result = got;
        },
        abi.syscall.write => {
            if (event.arg2 > abi.max_io) return error.InvalidWriteLength;
            var buffer: [abi.max_io]u8 = undefined;
            const length: usize = @intCast(event.arg2);
            try requests.copyin(&mappings, event.arg1, buffer[0..length]);
            if (event.arg0 == 1) write_console(buffer[0..length]) else reply.result = try files.write(&disk.storage, profile, @fromBackingInt(event.arg0), buffer[0..length]);
            if (event.arg0 == 1) reply.result = length;
        },
        abi.syscall.exit => {
            stopped = true;
            reply.action = contract.action_terminate;
            write_console("[kernel] Files exited status= ");
            writeHex(event.arg0);
        },
        else => reply.result = abi.errno.unknown,
    }
}
fn drawClient(rect: abi.DrawRect) void {
    hideCursor();
    const client = window.client();
    // Ignore the remainder of a repaint started before a resize. Its queued
    // refresh will ask for current geometry before painting the next frame.
    if (paint_width != client.width or paint_height != client.height) return;
    if (rect.x >= client.width or rect.y >= client.height) return;
    const width = @min(rect.width, client.width - rect.x);
    const height = @min(rect.height, client.height - rect.y);
    const color = ui.Color.rgb(@truncate(rect.color >> 16), @truncate(rect.color >> 8), @truncate(rect.color));
    display.fillRect(@as(u32, @intCast(client.x)) + rect.x, @as(u32, @intCast(client.y)) + rect.y, width, height, display.encode(color));
}
fn drawClientMaterial(request: abi.DrawMaterial) void {
    const client = window.client();
    if (paint_width != client.width or paint_height != client.height) return;
    if (request.x >= client.width or request.y >= client.height) return;
    const width = @min(request.width, client.width - request.x);
    const height = @min(request.height, client.height - request.y);
    if (width == 0 or height == 0) return;
    hideCursor();
    display.materialRect(@as(u32, @intCast(client.x)) + request.x, @as(u32, @intCast(client.y)) + request.y, width, height, .{
        .tint = ui.Color.rgb(@truncate(request.tint >> 16), @truncate(request.tint >> 8), @truncate(request.tint)),
        .opacity = @intCast(request.opacity),
    });
    material_requests +%= 1;
}
fn background() !void {
    hideCursor();
    try shell.renderWallpaper(&display);
    try shell.renderBarWithWorkspace(&display, &workspace, architecture_label);
    if (!window.visible) {
        showCursor();
        return;
    }
    const frame = window.frame();
    if (window.mode != .fullscreen) {
        fill(.{ .x = frame.x + 5, .y = frame.y + 7, .width = frame.width, .height = frame.height }, ui.Color.rgb(36, 38, 47));
        fill(.{ .x = frame.x + 2, .y = frame.y + 3, .width = frame.width, .height = frame.height }, ui.Color.rgb(31, 33, 41));
    }
    fill(frame, if (window.focused) ui.Color.rgb(84, 75, 89) else ui.Color.rgb(60, 63, 74));
    const border = window.borderWidth();
    frost(.{ .x = frame.x + @as(i32, @intCast(border)), .y = frame.y + @as(i32, @intCast(border)), .width = frame.width - border * 2, .height = frame.height - border * 2 }, .{ .tint = ui.Color.rgb(26, 27, 35), .opacity = 178 });
    drawChrome();
}
fn drawChrome() void {
    if (!window.visible) return;
    hideCursor();
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
    // Host policy supplies nonnegative in-bounds geometry. Surface helpers
    // also clip the shadow at the screen edges after maximize/fullscreen.
    if (rect.x < 0 or rect.y < 0) return;
    display.fillRect(@intCast(rect.x), @intCast(rect.y), rect.width, rect.height, display.encode(color));
}
fn frost(rect: ui.Rect, material: ui.Material) void {
    if (rect.x < 0 or rect.y < 0) return;
    display.materialRect(@intCast(rect.x), @intCast(rect.y), rect.width, rect.height, material);
}
fn circle(cx: i32, cy: i32, radius: i32, color: ui.Color) void {
    const pixel = display.encode(color);
    var dy = -radius;
    while (dy <= radius) : (dy += 1) {
        var dx = -radius;
        while (dx <= radius) : (dx += 1) {
            if (dx * dx + dy * dy > radius * radius or cx + dx < 0 or cy + dy < 0) continue;
            display.putPixel(@intCast(cx + dx), @intCast(cy + dy), pixel);
        }
    }
}
fn text(x: i32, y: i32, value: []const u8, color: ui.Color) void {
    const pixel = display.encode(color);
    for (value, 0..) |byte, index| {
        const glyph = ui.font.glyph(byte);
        for (glyph, 0..) |row, gy| for (0..ui.font.glyph_width) |gx| {
            if (row & (@as(u8, 1) << @as(u3, @intCast(ui.font.glyph_width - 1 - gx))) == 0) continue;
            const px = x + @as(i32, @intCast(index * ui.font.advance + gx));
            const py = y + @as(i32, @intCast(gy + ui.font.offset_y));
            if (px >= 0 and py >= 0) display.putPixel(@intCast(px), @intCast(py), pixel);
        };
    }
}
fn pollInput() !void {
    for (disk.inputs[0..disk.input_count]) |*input| {
        var polled: usize = 0;
        while (polled < 64) : (polled += 1) {
            // Leave receive descriptors queued when the client is rendering;
            // releases and text remain ordered instead of overflowing the broker.
            if (events.len >= 60) break;
            const raw = (try input.poll()) orelse break;
            try decoder.feed(raw, input.abs_x, input.abs_y);
            while (decoder.pop()) |encoded| try route(try ui.Event.decode(encoded));
        }
    }
}
fn route(event: ui.Event) !void {
    if (event.kind == .pointer_move or event.kind == .pointer_down or event.kind == .pointer_up) {
        hideCursor();
        cursor = .{ .x = event.x, .y = event.y };
    }
    if (event.kind == .pointer_down and event.code == 1) {
        pointer_press = cursor;
        pointer_moved = false;
    }
    if (event.kind == .pointer_move and (@abs(@as(i64, cursor.x) - pointer_press.x) >= 4 or @abs(@as(i64, cursor.y) - pointer_press.y) >= 4)) pointer_moved = true;
    const launcher = shell.launchRect(display.width, display.height);
    const launcher_accessible = !window.visible or window.mode != .fullscreen;
    if (launcher_accessible and event.kind == .pointer_down and event.code == 1 and launcher.contains(cursor)) {
        launcher_pressed = true;
        showCursor();
        return;
    }
    const launch_key = event.kind == .key_down and event.modifiers & ui.input.modifiers.super != 0 and (event.code == 'e' or event.code == 13);
    const launch_click = event.kind == .pointer_up and event.code == 1 and launcher_pressed and launcher.contains(cursor);
    if (event.kind == .pointer_up and event.code == 1) launcher_pressed = false;
    if (launch_key or launch_click) {
        open_requested = true;
        showCursor();
        return;
    }
    const before = window;
    if (window.route(event)) |routed| {
        var local = routed;
        if (event.kind == .pointer_up and event.code == 1) {
            const is_click = !pointer_moved and window.client().contains(cursor);
            if (is_click and previous_click_valid and input_tick -% previous_click_tick <= 50 and
                @abs(@as(i64, cursor.x) - previous_click.x) < 4 and @abs(@as(i64, cursor.y) - previous_click.y) < 4)
            {
                local.modifiers |= ui.input.modifiers.double_click;
                previous_click_valid = false;
            } else previous_click_valid = is_click;
            previous_click_tick = input_tick;
            previous_click = cursor;
        }
        if (local.kind == .pointer_move and events.len != 0) {
            const last = (events.head + events.len - 1) % events.records.len;
            const prior = try ui.Event.decode(events.records[last]);
            if (prior.kind == .pointer_move and prior.modifiers == local.modifiers) events.records[last] = local.encode() else try events.push(local);
        } else try events.push(local);
    } else if (event.kind == .pointer_up and event.code == 1) previous_click_valid = false;
    if (window.closed) close_requested = active;
    const geometry_changed = before.x != window.x or before.y != window.y or before.width != window.width or before.height != window.height or before.mode != window.mode;
    if (geometry_changed) {
        // Old client coordinates cannot become clicks in the new layout.
        events = .{};
        if (active and window.visible) try refresh();
    }
    if (before.visible != window.visible or geometry_changed or before.focused != window.focused) {
        try background();
        if (active and window.visible and !geometry_changed) try events.push(.{ .kind = .redraw, .code = @intFromBool(before.visible != window.visible) });
    } else if (before.hovered != window.hovered or before.pressed_control != window.pressed_control) {
        drawChrome();
    }
    showCursor();
}
fn refresh() !void {
    try events.push(.{ .kind = .redraw, .code = 1 });
}
fn idleTick() !void {
    try arch.idleUntilTick();
    input_tick +%= 1;
}
fn hideCursor() void {
    if (!cursor_visible) return;
    for (0..18) |row| for (0..12) |col| {
        const x = cursor.x + @as(i32, @intCast(col));
        const y = cursor.y + @as(i32, @intCast(row));
        if (x >= 0 and y >= 0 and x < display.width and y < display.height)
            display.pixels[@as(usize, @intCast(y)) * display.stride + @as(usize, @intCast(x))] = cursor_saved[row * 12 + col];
    };
    cursor_visible = false;
}
fn showCursor() void {
    if (cursor_visible) return;
    for (0..18) |row| for (0..12) |col| {
        const x = cursor.x + @as(i32, @intCast(col));
        const y = cursor.y + @as(i32, @intCast(row));
        if (x >= 0 and y >= 0 and x < display.width and y < display.height)
            cursor_saved[row * 12 + col] = display.pixels[@as(usize, @intCast(y)) * display.stride + @as(usize, @intCast(x))];
    };
    ui.drawCursor(&display, cursor, ui.Color.rgb(222, 232, 241)) catch @panic("desktop cursor geometry");
    cursor_visible = true;
}
fn writeHex(value: u64) void {
    var buffer: [19]u8 = undefined;
    buffer[0..2].* = "0x".*;
    for (0..16) |i| buffer[i + 2] = "0123456789abcdef"[@intCast(value >> @as(u6, @intCast((15 - i) * 4)) & 15)];
    buffer[18] = '\n';
    write_console(&buffer);
}
