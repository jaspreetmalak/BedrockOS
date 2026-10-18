//! Protected native Files executable. AxisUI draws through its window grant;
//! filesystem calls use only the process's checked bundle/container namespace.
const std = @import("std");
const rt = @import("userspace_runtime");
const abi = @import("bedrock64");
const app = @import("files_app");
const ui = app.axisui;
pub const panic = std.debug.FullPanic(rt.panic);
var model: app.Model = .{};
var workspace: app.Workspace = undefined;
var client = Client{};
const Client = struct { drawing_failed: bool = false };

fn checked(value: u64) !u64 {
    if (!abi.isError(value)) return value;
    return switch (value) {
        abi.errno.permission => error.PermissionDenied,
        abi.errno.no_entry => error.NotFound,
        abi.errno.bad_descriptor => error.BadDescriptor,
        abi.errno.no_memory => error.Capacity,
        abi.errno.not_directory => error.NotDirectory,
        abi.errno.invalid => error.InvalidPath,
        abi.errno.exists => error.AlreadyExists,
        abi.errno.not_empty => error.DirectoryNotEmpty,
        abi.errno.read_only => error.ReadOnly,
        abi.errno.file_too_large => error.FileTooLarge,
        else => error.IOFailure,
    };
}
fn list(_: *anyopaque, path: []const u8, cursor: *usize) !?app.Entry {
    var record: abi.DirectoryRecord = undefined;
    record.cursor = cursor.*;
    const result = try checked(rt.syscall(abi.syscall.list, @intFromPtr(path.ptr), path.len, @intFromPtr(&record)));
    if (result == 0) return null;
    if (result != 1 or record.name_len == 0 or record.name_len > 96 or record.kind > 1) return error.InvalidEntry;
    cursor.* = @intCast(record.cursor);
    return try app.Entry.init(record.name[0..record.name_len], if (record.kind == 1) .directory else .file, record.size, record.read_only != 0);
}
fn create(_: *anyopaque, path: []const u8) !void {
    const fd = try checked(rt.open(path, abi.open_flags.write | abi.open_flags.create));
    _ = try checked(rt.close(fd));
}
fn mkdir(_: *anyopaque, path: []const u8) !void {
    _ = try checked(rt.syscall(abi.syscall.mkdir, @intFromPtr(path.ptr), path.len, 0));
}
fn remove(_: *anyopaque, path: []const u8) !void {
    _ = try checked(rt.syscall(abi.syscall.unlink, @intFromPtr(path.ptr), path.len, 0));
}
fn nullify(_: *anyopaque, path: []const u8) !void {
    _ = try checked(rt.syscall(abi.syscall.nullify, @intFromPtr(path.ptr), path.len, 0));
}
fn pair(number: u64, source: []const u8, destination: []const u8) !void {
    const request: abi.PathPair = .{ .source = @intFromPtr(source.ptr), .source_length = source.len, .destination = @intFromPtr(destination.ptr), .destination_length = destination.len };
    _ = try checked(rt.syscall(number, @intFromPtr(&request), 0, 0));
}
fn copy(_: *anyopaque, source: []const u8, destination: []const u8) !void {
    try pair(abi.syscall.copy, source, destination);
}
fn move(_: *anyopaque, source: []const u8, destination: []const u8) !void {
    try pair(abi.syscall.rename, source, destination);
}
fn read(_: *anyopaque, path: []const u8, offset: u64, output: []u8) !usize {
    const fd = try checked(rt.open(path, abi.open_flags.read));
    defer _ = rt.close(fd);
    if (offset > std.math.maxInt(i64)) return error.InvalidOffset;
    _ = try checked(rt.seek(fd, @intCast(offset), abi.seek_whence.set));
    var done: usize = 0;
    while (done < output.len) {
        const got = try checked(rt.read(fd, output[done..@min(output.len, done + abi.max_io)]));
        if (got == 0) break;
        done += @intCast(got);
    }
    return done;
}
fn write(_: *anyopaque, path: []const u8, offset: u64, input: []const u8) !usize {
    const fd = try checked(rt.open(path, abi.open_flags.write));
    defer _ = rt.close(fd);
    if (offset > std.math.maxInt(i64)) return error.InvalidOffset;
    _ = try checked(rt.seek(fd, @intCast(offset), abi.seek_whence.set));
    var done: usize = 0;
    while (done < input.len) {
        const got = try checked(rt.writeFd(fd, input[done..@min(input.len, done + abi.max_io)]));
        if (got == 0) break;
        done += @intCast(got);
    }
    return done;
}
fn fill(ctx: *anyopaque, x: u32, y: u32, width: u32, height: u32, color: u32) void {
    const state: *Client = @ptrCast(@alignCast(ctx));
    const rectangle: abi.DrawRect = .{ .x = x, .y = y, .width = width, .height = height, .color = color };
    if (abi.isError(rt.syscall(abi.syscall.ui_rect, @intFromPtr(&rectangle), 0, 0))) state.drawing_failed = true;
}
fn frost(ctx: *anyopaque, x: u32, y: u32, width: u32, height: u32, material: ui.Material) void {
    const state: *Client = @ptrCast(@alignCast(ctx));
    const request: abi.DrawMaterial = .{
        .x = x,
        .y = y,
        .width = width,
        .height = height,
        .tint = (@as(u32, material.tint.r) << 16) | (@as(u32, material.tint.g) << 8) | material.tint.b,
        .opacity = material.opacity,
    };
    if (abi.isError(rt.syscall(abi.syscall.ui_material, @intFromPtr(&request), 0, 0))) state.drawing_failed = true;
}
fn draw() void {
    const dimensions = rt.success(rt.syscall(abi.syscall.ui_geometry, 0, 0, 0));
    var surface = ui.Surface.initCommands(@intCast(dimensions >> 32), @truncate(dimensions), .{ .context = &client, .fillRect = &fill, .materialRect = &frost }) catch rt.exit(99);
    // This retained kernel-hosted diagnostic keeps its original glyph contract.
    surface.legacy_text = true;
    client.drawing_failed = false;
    app.renderWithWorkspace(&surface, &workspace, &model) catch rt.exit(99);
    rt.expect(!client.drawing_failed);
    _ = rt.success(rt.syscall(abi.syscall.ui_present, 0, 0, 0));
}
fn checkAuthority() void {
    // Exercise the real syscall boundary from the larger user address space.
    rt.expect(rt.syscall(abi.syscall.ui_rect, 0x1000, 0, 0) == abi.errno.fault);
    const clipped: abi.DrawRect = .{ .x = 0xffffffff, .y = 0xffffffff, .width = 0xffffffff, .height = 0xffffffff, .color = 0xffffff };
    rt.expect(rt.syscall(abi.syscall.ui_rect, @intFromPtr(&clipped), 0, 0) == 0);
    rt.expect(rt.syscall(abi.syscall.ui_material, 0x1000, 0, 0) == abi.errno.fault);
    var material: abi.DrawMaterial = .{ .x = 0xffffffff, .y = 0xffffffff, .width = 0xffffffff, .height = 0xffffffff, .tint = 0x20222c, .opacity = 192 };
    rt.expect(rt.syscall(abi.syscall.ui_material, @intFromPtr(&material), 0, 0) == 0);
    material.opacity = 256;
    rt.expect(rt.syscall(abi.syscall.ui_material, @intFromPtr(&material), 0, 0) == abi.errno.invalid);
    material.opacity = 192;
    material.tint = 0xff20222c;
    rt.expect(rt.syscall(abi.syscall.ui_material, @intFromPtr(&material), 0, 0) == abi.errno.invalid);
    material.tint = 0x20222c;
    material.reserved = 1;
    rt.expect(rt.syscall(abi.syscall.ui_material, @intFromPtr(&material), 0, 0) == abi.errno.invalid);
    material.reserved = 0;
    rt.expect(rt.syscall(abi.syscall.ui_material, @intFromPtr(&material), 1, 0) == abi.errno.invalid);
    rt.expect(rt.syscall(abi.syscall.ui_material, @intFromPtr(&material), 0, 1) == abi.errno.invalid);
    rt.expect(rt.syscall(abi.syscall.ui_pending, 1, 0, 0) == abi.errno.invalid);
    rt.expect(rt.syscall(abi.syscall.ui_pending, 0, 1, 0) == abi.errno.invalid);
    rt.expect(rt.syscall(abi.syscall.ui_pending, 0, 0, 1) == abi.errno.invalid);
    rt.write("[user] frosted material authority checks passed\n");
    const denied = rt.open("/container/../0000000000000001/note.txt", abi.open_flags.read);
    rt.expect(denied == abi.errno.permission or denied == abi.errno.invalid);
    rt.expect(rt.open("/bundle/Files.elf", abi.open_flags.write) == abi.errno.permission);
    const bundle = "/bundle/Files.elf";
    rt.expect(rt.syscall(abi.syscall.nullify, @intFromPtr(bundle.ptr), bundle.len, 0) == abi.errno.permission);
    rt.expect(rt.syscall(abi.syscall.nullify, 0x1000, 1, 0) == abi.errno.fault);
    rt.expect(rt.syscall(abi.syscall.nullify, @intFromPtr(bundle.ptr), bundle.len, 1) == abi.errno.invalid);
    const home = "/container/Documents";
    rt.expect(rt.syscall(abi.syscall.nullify, @intFromPtr(home.ptr), home.len, 0) == abi.errno.invalid);
    rt.write("[user] Nullify namespace authority checks passed\n");
    // Files has no network_client approval, even when the OS has a live NIC.
    rt.expect(rt.syscall(abi.syscall.udp_open, 0, 0, 0) == abi.errno.permission);
    rt.expect(rt.syscall(abi.syscall.udp_send, 0, 0, 0) == abi.errno.permission);
    rt.expect(rt.syscall(abi.syscall.udp_receive, 0, 0, 0) == abi.errno.permission);
    rt.write("[user] Files network access denied\n");
    for ([_]u64{ abi.syscall.wifi_status, abi.syscall.wifi_scan_start, abi.syscall.wifi_scan_read, abi.syscall.wifi_join, abi.syscall.wifi_disconnect, abi.syscall.wifi_enable }) |number|
        rt.expect(rt.syscall(number, 0, 0, 0) == abi.errno.permission);
    rt.write("[user] Files Wi-Fi control denied\n");
    const fd = rt.success(rt.open("/bundle/Files.elf", abi.open_flags.read));
    const readonly = "readonly";
    rt.expect(rt.syscall(abi.syscall.read, fd, @intFromPtr(readonly.ptr), 1) == abi.errno.fault);
    _ = rt.success(rt.close(fd));
    rt.write("[user] Files authority checks passed\n");
}
export fn bedrock_user_main(_: u64, _: u64, _: u64) callconv(.c) noreturn {
    rt.markEntry();
    checkAuthority();
    model.init(.{ .context = &client, .list = &list, .create = &create, .mkdir = &mkdir, .copy = &copy, .move = &move, .remove = &remove, .nullify = &nullify, .read = &read, .write = &write }, "/container/Documents", "/container/Downloads") catch rt.exit(99);
    rt.write("[user] protected Files ready\n");
    draw();
    while (true) {
        var raw = rt.success(rt.syscall(abi.syscall.ui_event, 0, 0, 0));
        const revision = model.revision;
        // Keep every routed event in order, but paint once for a bounded batch.
        // Buffered typing must not trigger a full wallpaper tint per character.
        var handled: u8 = 0;
        while (true) {
            const event = ui.Event.decode(raw) catch rt.exit(99);
            const dimensions = rt.success(rt.syscall(abi.syscall.ui_geometry, 0, 0, 0));
            model.dispatch(event, @intCast(dimensions >> 32), @truncate(dimensions)) catch rt.exit(99);
            handled += 1;
            if (handled == 32) break;
            raw = rt.success(rt.syscall(abi.syscall.ui_pending, 0, 0, 0));
            if (raw == 0) break;
        }
        if (model.revision != revision) draw();
    }
}
