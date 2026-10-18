//! Native, allocation-free installer presentation. The firmware host owns disk
//! discovery and installation; this view never receives a disk or I/O handle.
const std = @import("std");
const ui = @import("axisui");

pub const max_drives = 8;
pub const esp_blocks: u64 = 128991;
pub const data_blocks: u64 = 8192;
pub const layout_minimum_blocks: u64 = 139297;
pub const Drive = struct { name: []const u8, blocks: u64 };
pub const Phase = enum { selecting, review, installing, complete, failed };
pub const Action = enum { none, install, exit, restart };
const Target = union(enum) { primary, secondary, drive: u8 };
const Press = struct {
    target: Target,
    selected: ?u8,
    phase: Phase,
    generation: u32,
    width: u32,
    height: u32,
};

pub const Model = struct {
    /// Borrowed records and names must remain live and immutable throughout the
    /// installer. Discovery filters source media, unsuitable sectors and drives.
    drives: []const Drive,
    selected: ?u8 = null,
    phase: Phase = .selecting,
    minimum_blocks: u64 = layout_minimum_blocks,
    architecture: []const u8 = "",
    confirmation: [32]u8 = @splat(0),
    confirmation_len: u8 = 0,
    progress: u8 = 0,
    /// Borrowed host diagnostic, copied only into bounded drawing buffers.
    error_text: []const u8 = "Installation failed. The drive may contain an incomplete installation.",
    pressed: ?Press = null,
    generation: u32 = 0,

    pub fn init(drives: []const Drive) error{ TooManyDrives, InvalidDriveName }!Model {
        if (drives.len > max_drives) return error.TooManyDrives;
        for (drives) |drive| {
            if (drive.name.len == 0 or drive.name.len > 64) return error.InvalidDriveName;
            for (drive.name) |byte| if (byte < 32 or byte > 126) return error.InvalidDriveName;
        }
        return .{ .drives = drives, .selected = if (drives.len == 0) null else 0 };
    }
    pub fn selectedDrive(self: *const Model) ?Drive {
        const index = self.selected orelse return null;
        if (index >= self.drives.len) return null;
        return self.drives[index];
    }
    pub fn confirmed(self: *const Model) bool {
        if (self.confirmation_len > self.confirmation.len) return false;
        return std.mem.eql(u8, self.confirmation[0..self.confirmation_len], "ERASE");
    }
    pub fn setProgress(self: *Model, percent: u8) void {
        if (self.phase != .installing) return;
        self.progress = @min(percent, 100);
        self.pressed = null;
    }
    pub fn finish(self: *Model) void {
        self.phase = .complete;
        self.progress = 100;
        self.invalidate();
    }
    pub fn fail(self: *Model, diagnostic: []const u8) void {
        self.phase = .failed;
        self.error_text = diagnostic;
        self.invalidate();
    }
    fn invalidate(self: *Model) void {
        self.pressed = null;
        self.generation +%= 1;
    }
    fn resetConfirmation(self: *Model) void {
        @memset(&self.confirmation, 0);
        self.confirmation_len = 0;
        self.invalidate();
    }
    fn primaryEnabled(self: *const Model) bool {
        return switch (self.phase) {
            .selecting => if (self.selectedDrive()) |drive| drive.blocks >= @max(self.minimum_blocks, layout_minimum_blocks) else false,
            .review => self.confirmed() and if (self.selectedDrive()) |drive| drive.blocks >= @max(self.minimum_blocks, layout_minimum_blocks) else false,
            .installing => false,
            .complete, .failed => true,
        };
    }
    fn primary(self: *Model) Action {
        if (!self.primaryEnabled()) return .none;
        self.invalidate();
        switch (self.phase) {
            .selecting => {
                self.phase = .review;
                self.resetConfirmation();
                return .none;
            },
            .review => {
                self.phase = .installing;
                self.progress = 0;
                return .install;
            },
            .complete => return .restart,
            .failed => {
                self.phase = .selecting;
                self.resetConfirmation();
                return .none;
            },
            .installing => return .none,
        }
    }
    fn secondary(self: *Model) Action {
        if (self.phase == .installing) return .none;
        self.invalidate();
        if (self.phase == .review) {
            self.phase = .selecting;
            self.resetConfirmation();
            return .none;
        }
        return .exit;
    }
    fn inputByte(self: *Model, code: u16) void {
        if (self.phase != .review or code < 32 or code > 126) return;
        // Preserve extra input, rather than accepting ERASE followed by an
        // ignored character. Exact matching is the destructive-action gate.
        if (self.confirmation_len == self.confirmation.len) return;
        self.confirmation[self.confirmation_len] = @intCast(code);
        self.confirmation_len += 1;
        self.invalidate();
    }
    /// Both EFI key_down characters and desktop text events are supported. A
    /// host sends one representation per character. Pointer coordinates and
    /// drawing share the same bounded geometry; no release-only activation.
    pub fn handle(self: *Model, event: ui.Event, width: u32, height: u32) Action {
        if (width > ui.max_surface_dimension or height > ui.max_surface_dimension) return .none;
        if ((width < 640 or height < 480) and event.code != @backingInt(ui.input.Key.escape)) return .none;
        if (event.kind == .redraw and event.code == 1) {
            self.invalidate();
            return .none;
        }
        if (event.kind == .text) {
            self.inputByte(event.code);
            return .none;
        }
        if (event.kind == .key_down) {
            switch (event.code) {
                @backingInt(ui.input.Key.escape) => return self.secondary(),
                @backingInt(ui.input.Key.enter) => return self.primary(),
                @backingInt(ui.input.Key.backspace) => if (self.phase == .review and self.confirmation_len != 0) {
                    self.confirmation_len -= 1;
                    self.confirmation[self.confirmation_len] = 0;
                    self.invalidate();
                },
                @backingInt(ui.input.Key.up), @backingInt(ui.input.Key.down) => if (self.phase == .selecting and self.drives.len != 0) {
                    const current = @min(self.selected orelse 0, self.drives.len - 1);
                    self.selected = @intCast(if (event.code == @backingInt(ui.input.Key.up)) current -| 1 else @min(current + 1, self.drives.len - 1));
                    self.invalidate();
                },
                else => if (event.modifiers & (ui.input.modifiers.control | ui.input.modifiers.alt | ui.input.modifiers.super) == 0) self.inputByte(event.code),
            }
            return .none;
        }
        if (event.code != @backingInt(ui.input.Button.left)) return .none;
        const point: ui.Point = .{ .x = event.x, .y = event.y };
        if (event.kind == .pointer_down) {
            self.pressed = null;
            if (self.targetAt(point, width, height)) |target| self.pressed = .{
                .target = target,
                .selected = self.selected,
                .phase = self.phase,
                .generation = self.generation,
                .width = width,
                .height = height,
            };
        } else if (event.kind == .pointer_up) {
            const press = self.pressed orelse return .none;
            self.pressed = null;
            if (press.phase != self.phase or press.selected != self.selected or press.generation != self.generation or press.width != width or press.height != height) return .none;
            const target = self.targetAt(point, width, height) orelse return .none;
            if (!std.meta.eql(press.target, target)) return .none;
            switch (target) {
                .primary => return self.primary(),
                .secondary => return self.secondary(),
                .drive => |index| {
                    self.selected = index;
                    self.resetConfirmation();
                },
            }
        }
        return .none;
    }
    fn targetAt(self: *const Model, point: ui.Point, width: u32, height: u32) ?Target {
        if (width < 640 or height < 480 or self.phase == .installing) return null;
        if (self.phase == .selecting) for (self.drives, 0..) |_, index| {
            const rect = driveRect(width, height, index);
            if (roundedHit(rect, 10, point)) return .{ .drive = @intCast(index) };
        };
        if (self.primaryEnabled() and roundedHit(primaryRect(width, height), 11, point)) return .primary;
        if (roundedHit(secondaryRect(width, height), 11, point)) return .secondary;
        return null;
    }
};

pub fn cardRect(width: u32, height: u32) ui.Rect {
    const w = @min(680, width -| 48);
    const h = @min(520, height -| 48);
    return .{ .x = @intCast((width - w) / 2), .y = @intCast((height - h) / 2), .width = w, .height = h };
}
pub fn primaryRect(width: u32, height: u32) ui.Rect {
    const card = cardRect(width, height);
    return .{ .x = card.x + @as(i32, @intCast(card.width -| 154)), .y = card.y + @as(i32, @intCast(card.height -| 60)), .width = @min(130, card.width), .height = 36 };
}
pub fn secondaryRect(width: u32, height: u32) ui.Rect {
    const card = cardRect(width, height);
    return .{ .x = card.x + 24, .y = card.y + @as(i32, @intCast(card.height -| 60)), .width = @min(100, card.width), .height = 36 };
}
pub fn driveRect(width: u32, height: u32, index: usize) ui.Rect {
    const card = cardRect(width, height);
    const step = @min(38, (card.height -| 194) / max_drives);
    const top: u32 = 120 + @as(u32, @intCast(@min(index, max_drives))) * step;
    const bottom = card.height -| 74;
    return .{ .x = card.x + 24, .y = card.y + @as(i32, @intCast(top)), .width = card.width -| 48, .height = @min(@min(32, step -| 6), bottom -| top) };
}
fn roundedHit(rect: ui.Rect, radius: u32, point: ui.Point) bool {
    return ui.materials.roundedContains(rect.width, rect.height, radius, @as(i64, point.x) - rect.x, @as(i64, point.y) - rect.y);
}

const colors = struct {
    const text = ui.Color.rgb(230, 227, 226);
    const quiet = ui.Color.rgb(161, 162, 177);
    const rose = ui.Color.rgb(212, 149, 173);
    const blue = ui.Color.rgb(139, 174, 192);
    const card = ui.Color.rgb(32, 34, 44);
    const row = ui.Color.rgb(46, 48, 61);
    const line = ui.Color.rgb(82, 83, 101);
};
fn label(surface: *ui.Surface, bytes: []const u8, rect: ui.Rect, color: ui.Color, scale: u8, centered: bool) !void {
    var n: usize = 0;
    while (n < bytes.len) : (n += 1) {
        if ((try ui.font.measure(bytes[0 .. n + 1], scale)).width > rect.width) break;
    }
    const measured = try ui.font.measure(bytes[0..n], scale);
    const x = rect.x + @as(i32, @intCast(if (centered) (rect.width - measured.width) / 2 else 0));
    try ui.font.paint(surface, bytes[0..n], x, try ui.font.controlOriginY(rect.y, rect.height, scale), color, scale);
}
fn line(surface: *ui.Surface, bytes: []const u8, card: ui.Rect, y: u32, color: ui.Color) !void {
    try label(surface, bytes, .{ .x = card.x + 24, .y = card.y + @as(i32, @intCast(y)), .width = card.width -| 48, .height = 24 }, color, 1, false);
}
fn button(surface: *ui.Surface, bytes: []const u8, rect: ui.Rect, enabled: bool, primary: bool) !void {
    const tint = if (primary and enabled) colors.rose else colors.row;
    surface.roundedMaterialRect(rect.x, rect.y, rect.width, rect.height, 11, .{ .tint = tint, .opacity = if (primary and enabled) 240 else 170 });
    surface.roundedBorder(rect.x, rect.y, rect.width, rect.height, 11, colors.line, 1, 120);
    try label(surface, bytes, rect, if (!enabled) colors.quiet else if (primary) colors.card else colors.text, 1, true);
}
fn partitionRow(surface: *ui.Surface, card: ui.Rect, y: u32, name: []const u8, detail: []const u8, color: ui.Color) !void {
    const rect: ui.Rect = .{ .x = card.x + 24, .y = card.y + @as(i32, @intCast(y)), .width = card.width -| 48, .height = if (card.height < 500) 34 else 38 };
    surface.roundedMaterialRect(rect.x, rect.y, rect.width, rect.height, 10, .{ .tint = colors.row, .opacity = 155 });
    surface.roundedRect(rect.x + 12, rect.y + @as(i32, @intCast((rect.height - 10) / 2)), 10, 10, 3, color);
    try label(surface, name, .{ .x = rect.x + 34, .y = rect.y, .width = rect.width -| 190, .height = rect.height }, colors.text, 1, false);
    try label(surface, detail, .{ .x = rect.x + @as(i32, @intCast(rect.width -| 148)), .y = rect.y, .width = @min(136, rect.width), .height = rect.height }, colors.quiet, 1, false);
}

/// Draws over the host's native wallpaper. The host may attach an immutable
/// blurred backdrop to obtain frosted materials. Without one, AxisUI uses its
/// solid-tint fallback. Every control uses the framework's stable cap baseline.
pub fn draw(surface: *ui.Surface, model: *const Model, workspace: *ui.Workspace) !void {
    _ = workspace;
    try surface.validate();
    if (model.drives.len > max_drives) return error.TooManyDrives;
    const card = cardRect(surface.width, surface.height);
    surface.roundedRect(card.x + 5, card.y + 9, card.width, card.height, 24, ui.Color.rgb(14, 16, 24));
    surface.roundedMaterialRect(card.x, card.y, card.width, card.height, 24, .{ .tint = colors.card, .opacity = 200 });
    surface.roundedBorder(card.x, card.y, card.width, card.height, 24, colors.line, 1, 140);
    try label(surface, "Install Bedrock", .{ .x = card.x + 24, .y = card.y + 22, .width = card.width -| 48, .height = 38 }, colors.text, 2, false);
    const stage = switch (model.phase) {
        .selecting => "1 / Choose a drive",
        .review => "2 / Review partitions - VirtIO storage required",
        .installing => "3 / Installing",
        .complete => "Ready to boot",
        .failed => "Installation interrupted",
    };
    try line(surface, stage, card, 69, colors.rose);
    if (surface.width < 640 or surface.height < 480) {
        try line(surface, "Installer needs a 640 x 480 display.", card, 139, colors.text);
        try line(surface, "Press Esc to exit.", card, 173, colors.quiet);
        return;
    }
    if (model.phase == .selecting) {
        if (model.drives.len == 0) {
            try line(surface, "No eligible destination drives found.", card, 139, colors.text);
            try line(surface, "Connect a separate writable drive and restart the installer.", card, 173, colors.quiet);
            try line(surface, "Installer source media is never offered as a destination.", card, 207, colors.quiet);
        } else for (model.drives, 0..) |drive, index| {
            const rect = driveRect(surface.width, surface.height, index);
            if (rect.height == 0) continue;
            const selected = model.selected == @as(u8, @intCast(index));
            surface.roundedMaterialRect(rect.x, rect.y, rect.width, rect.height, 10, .{ .tint = if (selected) ui.Color.rgb(69, 50, 67) else colors.row, .opacity = if (selected) 225 else 125 });
            if (selected) surface.roundedBorder(rect.x, rect.y, rect.width, rect.height, 10, colors.rose, 1, 200);
            try ui.icons.draw(surface, .document, .{ .x = rect.x + 10, .y = rect.y + @as(i32, @intCast((rect.height - 16) / 2)) }, if (selected) colors.rose else colors.blue, 1);
            try label(surface, drive.name, .{ .x = rect.x + 36, .y = rect.y, .width = rect.width -| 150, .height = rect.height }, colors.text, 1, false);
            var capacity: [48]u8 = undefined;
            const bytes = try std.fmt.bufPrint(&capacity, "{d} MiB", .{drive.blocks / 2048});
            try label(surface, bytes, .{ .x = rect.x + @as(i32, @intCast(rect.width -| 108)), .y = rect.y, .width = @min(96, rect.width), .height = rect.height }, colors.quiet, 1, false);
        }
    } else if (model.phase == .review) {
        const compact = card.height < 500;
        var selected: [96]u8 = undefined;
        const drive = model.selectedDrive();
        const selected_text = try std.fmt.bufPrint(&selected, "Destination: {s}", .{if (drive) |d| d.name else "Unavailable"});
        try line(surface, selected_text, card, if (compact) 105 else 111, colors.text);
        try line(surface, "This replaces every partition and file on this drive.", card, if (compact) 130 else 142, colors.rose);
        try partitionRow(surface, card, if (compact) 163 else 181, "EFI System / FAT32", "63 MiB", colors.blue);
        try partitionRow(surface, card, if (compact) 204 else 226, "Bedrock / persistent data", "4 MiB", colors.rose);
        var remaining: [48]u8 = undefined;
        const free = if (drive) |d| (d.blocks -| layout_minimum_blocks) / 2048 else 0;
        try partitionRow(surface, card, if (compact) 245 else 271, "Unallocated", try std.fmt.bufPrint(&remaining, "{d} MiB", .{free}), colors.quiet);
        try line(surface, "Type ERASE to confirm the entire drive can be replaced.", card, if (compact) 294 else 327, colors.quiet);
        const field: ui.Rect = .{ .x = card.x + 24, .y = card.y + @as(i32, if (compact) 322 else 361), .width = card.width -| 48, .height = if (compact) 34 else 42 };
        surface.roundedMaterialRect(field.x, field.y, field.width, field.height, 11, .{ .tint = ui.Color.rgb(24, 26, 36), .opacity = 230 });
        surface.roundedBorder(field.x, field.y, field.width, field.height, 11, if (model.confirmed()) colors.rose else colors.line, 1, 210);
        const value = model.confirmation[0..@min(model.confirmation_len, model.confirmation.len)];
        try label(surface, if (value.len == 0) "ERASE" else value, .{ .x = field.x + 13, .y = field.y, .width = field.width -| 26, .height = field.height }, if (value.len == 0) colors.quiet else colors.text, 1, false);
    } else if (model.phase == .installing) {
        try line(surface, "Installing to the selected drive", card, 142, colors.text);
        try line(surface, "Keep the computer on until verification completes.", card, 177, colors.quiet);
        const track: ui.Rect = .{ .x = card.x + 24, .y = card.y + 227, .width = card.width -| 48, .height = 8 };
        surface.roundedRect(track.x, track.y, track.width, track.height, 4, colors.row);
        surface.roundedRect(track.x, track.y, @intCast(@as(u64, track.width) * @min(model.progress, 100) / 100), track.height, 4, colors.rose);
        var percent: [12]u8 = undefined;
        try line(surface, try std.fmt.bufPrint(&percent, "{d}%", .{@min(model.progress, 100)}), card, 252, colors.rose);
    } else if (model.phase == .complete) {
        try line(surface, "Bedrock is installed.", card, 146, colors.text);
        try line(surface, "Remove the installer media, then restart.", card, 186, colors.quiet);
        try line(surface, "The new drive uses GPT and the standard UEFI boot path.", card, 220, colors.quiet);
    } else {
        try line(surface, "The installation could not be completed.", card, 146, colors.rose);
        try line(surface, model.error_text, card, 183, colors.quiet);
        try line(surface, "The destination may contain an incomplete installation.", card, 221, colors.quiet);
    }
    if (model.phase != .installing) {
        const primary = switch (model.phase) {
            .selecting => "Continue",
            .review => "Erase and install",
            .complete => "Restart",
            .failed => "Choose drive",
            .installing => "",
        };
        try button(surface, primary, primaryRect(surface.width, surface.height), model.primaryEnabled(), true);
        try button(surface, if (model.phase == .review) "Back" else "Exit", secondaryRect(surface.width, surface.height), true, false);
    }
    if (surface.height >= 580) {
        var footer: [96]u8 = undefined;
        const footer_text = try std.fmt.bufPrint(&footer, "{s}    Arrows: choose    Enter: continue    Esc: back", .{model.architecture});
        try label(surface, footer_text, .{ .x = card.x, .y = card.y + @as(i32, @intCast(card.height)) + 12, .width = card.width, .height = 24 }, colors.quiet, 1, true);
    }
}

test {
    _ = @import("view_tests.zig");
}
