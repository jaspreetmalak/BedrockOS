//! Native recovery installer. Firmware services remain live throughout copying.
//! Raw disk authority is retained here and is never passed to AxisUI views.
const std = @import("std");
const builtin = @import("builtin");
const uefi = std.os.uefi;
const ui = @import("axisui");
const shell = @import("desktop_shell");
const filesystem = @import("filesystem");
const core = @import("core.zig");
const view = @import("view.zig");
const source_path = @import("source_path.zig");
const maximum_disks = 8;
const maximum_handles = 128;
const minimum_blocks: u64 = 139297;
const machine: u16 = switch (builtin.cpu.arch) {
    .x86_64 => 62,
    .aarch64 => 183,
    .riscv64 => 243,
    else => unreachable,
};
const architecture = switch (builtin.cpu.arch) {
    .x86_64 => "x86_64",
    .aarch64 => "ARM64",
    .riscv64 => "RISC-V64",
    else => unreachable,
};
const payload_path = std.unicode.utf8ToUtf16LeStringLiteral("\\EFI\\Bedrock\\Install\\os.bip");

var serial: ?*uefi.protocol.SerialIo = null;
var manifest: core.Manifest = undefined;
var workspace: ui.Workspace = undefined;
var retained_source_path: [source_path.max_bytes]u8 = undefined;
var retained_session: Session = undefined;
var retained_backdrop: ui.Backdrop = undefined;
var failure_message: [160]u8 = undefined;

pub const panic = std.debug.FullPanic(panicHandler);
fn panicHandler(message: []const u8, _: ?usize) noreturn {
    log("[installer] error panic ");
    log(message);
    log("\n");
    while (true) {}
}
fn log(bytes: []const u8) void {
    if (serial) |port| {
        var offset: usize = 0;
        while (offset < bytes.len) {
            const count = port.write(bytes[offset..]) catch return;
            if (count == 0 or count > bytes.len - offset) return;
            offset += count;
        }
        return;
    }
    const out = uefi.system_table.con_out orelse return;
    var buffer: [192:0]u16 = undefined;
    var position: usize = 0;
    for (bytes) |byte| {
        if (position + 2 >= buffer.len) {
            buffer[position] = 0;
            _ = out.outputString(&buffer) catch false;
            position = 0;
        }
        if (byte == '\n') {
            buffer[position] = '\r';
            position += 1;
        }
        buffer[position] = byte;
        position += 1;
    }
    buffer[position] = 0;
    _ = out.outputString(&buffer) catch false;
}
fn logNumber(value: u64) void {
    var buffer: [24]u8 = undefined;
    log(std.fmt.bufPrint(&buffer, "{d}", .{value}) catch return);
}
fn openProtocol(bs: *uefi.tables.BootServices, comptime Protocol: type, handle: uefi.Handle) !?*Protocol {
    return bs.openProtocol(Protocol, handle, .{ .by_handle_protocol = .{ .agent = uefi.handle } });
}

/// Firmware owns the protocol pointer, but every node traversal is bounded.
fn pathBytes(path: *const uefi.protocol.DevicePath) ![]const u8 {
    const bytes: [*]const u8 = @ptrCast(path);
    var offset: usize = 0;
    for (0..source_path.max_nodes) |_| {
        if (offset > source_path.max_bytes - 4) return error.InvalidDevicePath;
        const size = std.mem.readInt(u16, bytes[offset + 2 ..][0..2], .little);
        if (size < 4 or size > source_path.max_bytes - offset) return error.InvalidDevicePath;
        const end = offset + size;
        if (bytes[offset] == 0x7f) {
            const result = bytes[0..end];
            _ = try source_path.prefix(result);
            return result;
        }
        if (bytes[offset] == 0 or bytes[offset] > 5) return error.InvalidDevicePath;
        offset = end;
    }
    return error.InvalidDevicePath;
}

const Payload = struct {
    file: *uefi.protocol.File,
    length: u64,
    fn source(self: *Payload) core.Source {
        return .{ .context = self, .byte_count = self.length, .read_fn = read };
    }
    fn read(context: *anyopaque, offset: u64, output: []u8) !void {
        const self: *Payload = @ptrCast(@alignCast(context));
        const end = @addWithOverflow(offset, @as(u64, @intCast(output.len)));
        if (end[1] != 0 or end[0] > self.length) return error.PayloadOutOfBounds;
        try self.file.setPosition(offset);
        var completed: usize = 0;
        while (completed < output.len) {
            const count = try self.file.read(output[completed..]);
            if (count == 0 or count > output.len - completed) return error.PayloadTruncated;
            completed += count;
        }
    }
};

const Disk = struct {
    io: *uefi.protocol.BlockIo,
    handle: uefi.Handle,
    media_id: u32,
    blocks: u64,
    align_bytes: u32,
    path: [source_path.max_bytes]u8,
    path_len: usize,
    bounce: []align(4096) u8,
    label: [64]u8 = undefined,
    label_len: usize = 0,
    fn validate(self: *const Disk) !void {
        const media = self.io.media;
        if (media.media_id != self.media_id or !media.media_present or media.logical_partition or
            media.read_only or media.block_size != 512 or media.last_block != self.blocks - 1 or
            media.io_align != self.align_bytes) return error.TargetMediaChanged;
    }
    fn device(self: *Disk) filesystem.BlockDevice {
        return .{ .context = self, .block_size = 512, .block_count = self.blocks, .read_fn = read, .write_fn = write, .flush_fn = flush };
    }
    fn checkRange(self: *const Disk, start: u64, count: u64, bytes: usize) !void {
        try self.validate();
        if (bytes % 512 != 0 or count != bytes / 512) return error.InvalidBufferLength;
        const end = @addWithOverflow(start, count);
        if (end[1] != 0 or end[0] > self.blocks) return error.OutOfBounds;
    }
    fn read(context: *anyopaque, start: u64, count: u64, output: []u8) !void {
        const self: *Disk = @ptrCast(@alignCast(context));
        try self.checkRange(start, count, output.len);
        var offset: usize = 0;
        while (offset < output.len) {
            try self.validate();
            const bytes = @min(output.len - offset, self.bounce.len);
            try self.io.readBlocks(self.media_id, start + offset / 512, self.bounce[0..bytes]);
            @memcpy(output[offset..][0..bytes], self.bounce[0..bytes]);
            offset += bytes;
        }
    }
    fn write(context: *anyopaque, start: u64, count: u64, input: []const u8) !void {
        const self: *Disk = @ptrCast(@alignCast(context));
        try self.checkRange(start, count, input.len);
        var offset: usize = 0;
        while (offset < input.len) {
            try self.validate();
            const bytes = @min(input.len - offset, self.bounce.len);
            @memcpy(self.bounce[0..bytes], input[offset..][0..bytes]);
            try self.io.writeBlocks(self.media_id, start + offset / 512, self.bounce[0..bytes]);
            offset += bytes;
        }
    }
    fn flush(context: *anyopaque) !void {
        const self: *Disk = @ptrCast(@alignCast(context));
        try self.validate();
        try self.io.flushBlocks();
    }
};

const Session = struct {
    bs: *uefi.tables.BootServices,
    source_handle: uefi.Handle,
    source_path: []const u8,
    payload: *Payload,
    disks: [maximum_disks]Disk = undefined,
    count: usize = 0,
    drive_views: [maximum_disks]view.Drive = undefined,
    model: view.Model = undefined,
    surface: ui.Surface,
    point: ui.Point = .{ .x = 0, .y = 0 },
    left_pressed: bool = false,
    pointer_present: bool = false,
    last_progress: u8 = 255,

    fn draw(self: *Session) !void {
        // Repaint the public wallpaper, while glass samples only its original
        // frozen capture. Installer overlays never enter the blur source.
        try shell.renderWallpaper(&self.surface);
        try view.draw(&self.surface, &self.model, &workspace);
        if (self.pointer_present) try ui.drawCursor(&self.surface, self.point, ui.Color.rgb(238, 233, 240));
    }
    fn discover(self: *Session, bounce: []align(4096) u8) !void {
        const handles = (try self.bs.locateHandleBuffer(.{ .by_protocol = &uefi.protocol.BlockIo.guid })) orelse return error.SourceWholeDiskUnavailable;
        defer self.bs.freePool(@ptrCast(handles.ptr)) catch {};
        if (handles.len > maximum_handles) return error.TooManyFirmwareDisks;
        var protected: usize = 0;
        for (handles) |handle| {
            const io = (try openProtocol(self.bs, uefi.protocol.BlockIo, handle)) orelse continue;
            if (io.media.logical_partition) continue;
            const path = (try openProtocol(self.bs, uefi.protocol.DevicePath, handle)) orelse continue;
            const bytes = pathBytes(path) catch continue;
            const is_source = handle == self.source_handle or (try source_path.isSourceAncestor(bytes, self.source_path));
            if (is_source) {
                protected += 1;
                continue;
            }
            const media = io.media;
            if (!media.media_present or media.read_only or media.block_size != 512 or media.last_block == std.math.maxInt(u64)) continue;
            if (media.io_align > 4096 or (media.io_align > 1 and !std.math.isPowerOfTwo(media.io_align))) continue;
            const blocks = media.last_block + 1;
            if (blocks < @max(minimum_blocks, manifest.minimumBlocks())) continue;
            if (self.count == maximum_disks) return error.TooManyInstallTargets;
            const disk = &self.disks[self.count];
            disk.* = .{ .io = io, .handle = handle, .media_id = media.media_id, .blocks = blocks, .align_bytes = media.io_align, .path = undefined, .path_len = bytes.len, .bounce = bounce };
            @memcpy(disk.path[0..bytes.len], bytes);
            const label = try std.fmt.bufPrint(&disk.label, "Drive {d} / {d} MiB", .{ self.count + 1, blocks / 2048 });
            disk.label_len = label.len;
            self.drive_views[self.count] = .{ .name = disk.label[0..label.len], .blocks = blocks };
            self.count += 1;
        }
        if (protected == 0) return error.SourceWholeDiskUnavailable;
        log("[installer] devices eligible=");
        logNumber(self.count);
        log(" protected=");
        logNumber(protected);
        log("\n");
    }
    fn revalidate(self: *Session, disk: *const Disk) !void {
        try disk.validate();
        const path = (try openProtocol(self.bs, uefi.protocol.DevicePath, disk.handle)) orelse return error.TargetDevicePathUnavailable;
        const bytes = try pathBytes(path);
        if (!std.mem.eql(u8, bytes, disk.path[0..disk.path_len])) return error.TargetMediaChanged;
        if (disk.handle == self.source_handle or try source_path.isSourceAncestor(bytes, self.source_path)) return error.SourceDiskProtected;
    }
    fn progress(context: *anyopaque, completed: u64, total: u64) void {
        const self: *Session = @ptrCast(@alignCast(context));
        const percent: u8 = if (total == 0) 0 else @intCast(@min(@as(u128, completed) * 100 / total, 100));
        if (percent == self.last_progress) return;
        self.last_progress = percent;
        self.model.setProgress(percent);
        self.draw() catch {};
    }
    fn installSelected(self: *Session) !void {
        const selected = self.model.selected orelse return error.NoInstallTarget;
        if (selected >= self.count or self.model.phase != .installing or !self.model.confirmed()) return error.InvalidInstallSelection;
        const disk = &self.disks[selected];
        try self.revalidate(disk);
        log("[installer] installing selected=");
        logNumber(selected);
        log(" blocks=");
        logNumber(disk.blocks);
        log("\n");
        var guid: [16]u8 = undefined;
        // GPT identities need uniqueness, not cryptographic entropy. Firmware
        // RNG is preferred; the fallback mixes target path and firmware time.
        if (self.bs.locateProtocol(uefi.protocol.Rng, null) catch null) |rng| {
            rng.getRNG(null, &guid) catch try self.fallbackGuid(disk, &guid);
        } else try self.fallbackGuid(disk, &guid);
        guid[7] = (guid[7] & 15) | 0x40;
        guid[8] = (guid[8] & 63) | 0x80;
        try core.install(self.payload.source(), &manifest, disk.device(), guid, .{ .context = self, .notify_fn = progress });
        self.model.finish();
        log("[installer] complete selected=");
        logNumber(selected);
        log(" blocks=");
        logNumber(disk.blocks);
        log("\n");
        try self.draw();
    }
    fn fallbackGuid(self: *Session, disk: *const Disk, guid: *[16]u8) !void {
        _ = self;
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        hash.update(disk.path[0..disk.path_len]);
        const time = (try uefi.system_table.runtime_services.getTime())[0];
        hash.update(std.mem.asBytes(&time));
        hash.update(std.mem.asBytes(&disk.blocks));
        var digest: [32]u8 = undefined;
        hash.final(&digest);
        @memcpy(guid, digest[0..16]);
    }
    fn dispatch(self: *Session, event: ui.Event) !?uefi.Status {
        const previous_selection = self.model.selected;
        const previous_phase = self.model.phase;
        const action = self.model.handle(event, self.surface.width, self.surface.height);
        if (previous_selection != self.model.selected or (previous_phase == .selecting and self.model.phase == .review)) {
            if (self.model.selected) |selected| {
                log("[installer] selected index=");
                logNumber(selected);
                log("\n");
            }
        }
        switch (action) {
            .none => {},
            .exit => return .success,
            .restart => uefi.system_table.runtime_services.resetSystem(.cold, .success, null),
            .install => self.installSelected() catch |err| {
                log("[installer] error ");
                log(@errorName(err));
                log("\n");
                const message = std.fmt.bufPrint(&failure_message, "Installation stopped: {s}", .{@errorName(err)}) catch "Installation stopped";
                self.model.fail(message);
            },
        }
        try self.draw();
        return null;
    }
    fn pointer(self: *Session, x: i32, y: i32, pressed: bool) !?uefi.Status {
        self.pointer_present = true;
        self.point = .{ .x = @intCast(std.math.clamp(x, 0, @as(i32, @intCast(self.surface.width)) - 1)), .y = @intCast(std.math.clamp(y, 0, @as(i32, @intCast(self.surface.height)) - 1)) };
        const event: ui.Event = .{ .kind = if (pressed != self.left_pressed) (if (pressed) .pointer_down else .pointer_up) else .pointer_move, .code = @backingInt(ui.input.Button.left), .x = @intCast(self.point.x), .y = @intCast(self.point.y) };
        self.left_pressed = pressed;
        return self.dispatch(event);
    }
};

fn framebuffer(bs: *uefi.tables.BootServices) !ui.Surface {
    const gop = (try bs.locateProtocol(uefi.protocol.GraphicsOutput, null)) orelse return error.NoGraphicsOutput;
    const mode = gop.mode;
    const info = mode.info;
    if (info.horizontal_resolution < 640 or info.vertical_resolution < 480 or info.horizontal_resolution > 4096 or info.vertical_resolution > 4096) return error.UnsupportedGraphicsMode;
    const required = @as(u64, info.pixels_per_scan_line) * info.vertical_resolution * 4;
    if (mode.frame_buffer_base == 0 or required > mode.frame_buffer_size or required > std.math.maxInt(usize)) return error.InvalidFramebuffer;
    const masks: ui.PixelMasks = switch (info.pixel_format) {
        .red_green_blue_reserved_8_bit_per_color => .{ .red = 0xff, .green = 0xff00, .blue = 0xff0000 },
        .blue_green_red_reserved_8_bit_per_color => .{ .red = 0xff0000, .green = 0xff00, .blue = 0xff },
        .bit_mask => .{ .red = info.pixel_information.red_mask, .green = info.pixel_information.green_mask, .blue = info.pixel_information.blue_mask },
        .blt_only => return error.NoLinearFramebuffer,
    };
    const pixels: [*]volatile u32 = @ptrFromInt(mode.frame_buffer_base);
    return ui.Surface.init(pixels[0..@as(usize, @intCast(required / 4))], info.horizontal_resolution, info.vertical_resolution, info.pixels_per_scan_line, masks);
}
fn keyEvent(key: uefi.protocol.SimpleTextInput.Key.Input) ?ui.Event {
    if (key.unicode_char != 0) return .{ .kind = .key_down, .code = key.unicode_char };
    const code: ui.input.Key = switch (key.scan_code) {
        1 => .up,
        2 => .down,
        3 => .right,
        4 => .left,
        5 => .home,
        6 => .end,
        8 => .delete,
        9 => .page_up,
        10 => .page_down,
        23 => .escape,
        else => return null,
    };
    return .{ .kind = .key_down, .code = @backingInt(code) };
}
fn absoluteCoordinate(value: u64, minimum: u64, maximum: u64, size: u32) !i32 {
    if (maximum <= minimum or value < minimum or value > maximum) return error.InvalidPointerCoordinates;
    return @intCast(@as(u128, value - minimum) * (size - 1) / (maximum - minimum));
}

fn run(bs: *uefi.tables.BootServices) !uefi.Status {
    _ = bs.setWatchdogTimer(0, 0, null) catch {};
    const loaded = (try openProtocol(bs, uefi.protocol.LoadedImage, uefi.handle)) orelse return error.LoadedImageUnavailable;
    const source_handle = loaded.device_handle orelse return error.InstallerSourceUnavailable;
    const path = (try openProtocol(bs, uefi.protocol.DevicePath, source_handle)) orelse return error.InstallerSourcePathUnavailable;
    const live_source_bytes = try pathBytes(path);
    @memcpy(retained_source_path[0..live_source_bytes.len], live_source_bytes);
    const source_bytes = retained_source_path[0..live_source_bytes.len];
    const fs = (try openProtocol(bs, uefi.protocol.SimpleFileSystem, source_handle)) orelse return error.InstallerFilesystemUnavailable;
    const root = try fs.openVolume();
    defer root.close() catch {};
    const payload_file = try root.open(payload_path, .read, .{});
    defer payload_file.close() catch {};
    var info_buffer: [1024]u8 align(8) = undefined;
    const file_info = try payload_file.getInfo(.file, &info_buffer);
    if (file_info.attribute.directory or file_info.file_size == 0 or file_info.file_size > 64 * 1024 * 1024) return error.InvalidPayloadFile;
    var payload: Payload = .{ .file = payload_file, .length = file_info.file_size };
    try core.Manifest.load(payload.source(), machine, &manifest);
    const pages = try bs.allocatePages(.any, .loader_data, 8);
    defer bs.freePages(pages) catch {};
    const bounce: [*]align(4096) u8 = @ptrCast(pages.ptr);
    retained_session = .{ .bs = bs, .source_handle = source_handle, .source_path = source_bytes, .payload = &payload, .surface = try framebuffer(bs) };
    const session = &retained_session;
    try session.discover(bounce[0..32768]);
    session.model = try view.Model.init(session.drive_views[0..session.count]);
    session.model.architecture = architecture;
    session.model.minimum_blocks = manifest.minimumBlocks();
    session.point = .{ .x = @intCast(session.surface.width / 2), .y = @intCast(session.surface.height / 2) };
    const backdrop_len = try ui.Backdrop.requiredLen(session.surface.width, session.surface.height);
    const backdrop_pages = (backdrop_len * @sizeOf(u32) + 4095) / 4096;
    const color_pages = try bs.allocatePages(.any, .loader_data, backdrop_pages);
    defer bs.freePages(color_pages) catch {};
    const scratch_pages = try bs.allocatePages(.any, .loader_data, backdrop_pages);
    defer bs.freePages(scratch_pages) catch {};
    const colors: [*]u32 = @ptrCast(color_pages.ptr);
    const scratch: [*]u32 = @ptrCast(scratch_pages.ptr);
    try shell.renderWallpaper(&session.surface);
    retained_backdrop = try ui.Backdrop.build(&session.surface, colors[0..backdrop_len], scratch[0..backdrop_len]);
    try session.surface.setBackdrop(&retained_backdrop, .{ .x = 0, .y = 0 });
    defer session.surface.setBackdrop(null, .{ .x = 0, .y = 0 }) catch {};
    try session.draw();
    log("[installer] ready architecture=");
    log(architecture);
    log(" width=");
    logNumber(session.surface.width);
    log(" height=");
    logNumber(session.surface.height);
    log("\n");
    const keyboard = uefi.system_table.con_in orelse return error.FirmwareKeyboardUnavailable;
    const absolute = bs.locateProtocol(uefi.protocol.AbsolutePointer, null) catch null;
    const relative = if (absolute == null) bs.locateProtocol(uefi.protocol.SimplePointer, null) catch null else null;
    while (true) {
        if (keyboard.readKeyStroke()) |key| {
            if (keyEvent(key)) |event| if (try session.dispatch(event)) |status| return status;
        } else |err| switch (err) {
            error.NotReady => {},
            else => return err,
        }
        if (absolute) |pointer| {
            if (pointer.getState()) |state| {
                const x = absoluteCoordinate(state.current_x, pointer.mode.absolute_min_x, pointer.mode.absolute_max_x, session.surface.width) catch continue;
                const y = absoluteCoordinate(state.current_y, pointer.mode.absolute_min_y, pointer.mode.absolute_max_y, session.surface.height) catch continue;
                if (try session.pointer(x, y, state.active_buttons.touch_active)) |status| return status;
            } else |_| {}
        } else if (relative) |pointer| {
            if (pointer.getState()) |state| {
                const x: i64 = @as(i64, session.point.x) + state.relative_movement_x;
                const y: i64 = @as(i64, session.point.y) + state.relative_movement_y;
                if (try session.pointer(@intCast(std.math.clamp(x, 0, session.surface.width - 1)), @intCast(std.math.clamp(y, 0, session.surface.height - 1)), state.left_button)) |status| return status;
            } else |_| {}
        }
        try bs.stall(10000);
    }
}

pub fn main() uefi.Status {
    const bs = uefi.system_table.boot_services orelse return .unsupported;
    serial = bs.locateProtocol(uefi.protocol.SerialIo, null) catch null;
    return run(bs) catch |err| {
        log("[installer] error ");
        log(@errorName(err));
        log("\n");
        return .load_error;
    };
}

// RV64's existing workspace PE converter uses an explicit LP64 entry export.
comptime {
    if (builtin.cpu.arch == .riscv64) @export(&efiMain, .{ .name = "EfiMain" });
}
fn efiMain(handle: uefi.Handle, system_table: *uefi.tables.SystemTable) callconv(.c) usize {
    uefi.handle = handle;
    uefi.system_table = system_table;
    return @backingInt(main());
}

test "firmware keys preserve exact typed confirmation and scan navigation" {
    try std.testing.expectEqual(@as(u16, 'E'), keyEvent(.{ .scan_code = 0, .unicode_char = 'E' }).?.code);
    try std.testing.expectEqual(@backingInt(ui.input.Key.up), keyEvent(.{ .scan_code = 1, .unicode_char = 0 }).?.code);
    try std.testing.expectEqual(@backingInt(ui.input.Key.escape), keyEvent(.{ .scan_code = 23, .unicode_char = 0 }).?.code);
    try std.testing.expect(keyEvent(.{ .scan_code = 0xffff, .unicode_char = 0 }) == null);
}
