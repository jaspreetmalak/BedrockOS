//! Window policy belongs to userspace services. The current kernel host supplies
//! protected clients, input and scanout; this module owns no physical resources.
const std = @import("std");
const ui = @import("axisui");

pub const Mode = enum { floating, maximized, fullscreen };
pub const Control = enum { close, minimize, maximize, fullscreen };
pub const ControlRect = struct { control: Control, rect: ui.Rect };
pub const key = struct {
    pub const f4: u16 = 0x10a;
    pub const f11: u16 = 0x10b;
};

pub const Window = struct {
    x: i32,
    y: i32,
    width: u32,
    height: u32,
    screen_width: u32,
    screen_height: u32,
    visible: bool = true,
    focused: bool = true,
    closed: bool = false,
    minimized: bool = false,
    mode: Mode = .floating,
    saved_geometry: ui.Rect,
    fullscreen_restore_mode: Mode = .floating,
    hovered: ?Control = null,
    pressed_control: ?Control = null,
    drag: ?ui.Point = null,
    capture: bool = false,
    capture_button: u16 = 0,
    fullscreen_key_down: bool = false,
    escape_key_down: bool = false,

    pub const title_height: u32 = 32;
    pub const workarea_top: u32 = 42;
    pub const workarea_bottom: u32 = 12;

    pub fn init(width: u32, height: u32) !Window {
        if (width < 800 or height < 600 or width > 16384 or height > 16384) return error.InvalidDesktopGeometry;
        const w = @min(width - 96, 960);
        const h = @min(height - 140, 620);
        const geometry: ui.Rect = .{ .x = @intCast((width - w) / 2), .y = 72, .width = w, .height = h };
        return .{ .x = geometry.x, .y = geometry.y, .width = w, .height = h, .screen_width = width, .screen_height = height, .saved_geometry = geometry };
    }

    pub fn frame(self: Window) ui.Rect {
        return .{ .x = self.x, .y = self.y, .width = self.width, .height = self.height };
    }
    pub fn surface(self: Window) ui.Rect {
        return self.frame();
    }
    pub fn borderWidth(self: Window) u32 {
        return if (self.mode == .fullscreen) 0 else 2;
    }
    pub fn client(self: Window) ui.Rect {
        const inset = self.borderWidth();
        return .{ .x = self.x + @as(i32, @intCast(inset)), .y = self.y + @as(i32, @intCast(inset + title_height)), .width = self.width - 2 * inset, .height = self.height - 2 * inset - title_height };
    }
    pub fn title(self: Window) ui.Rect {
        const inset = self.borderWidth();
        return .{ .x = self.x + @as(i32, @intCast(inset)), .y = self.y + @as(i32, @intCast(inset)), .width = self.width - 2 * inset, .height = title_height };
    }
    /// The largest client extent is fullscreen with its retained exit strip.
    pub fn maxClient(self: Window) ui.Rect {
        return .{ .x = 0, .y = title_height, .width = self.screen_width, .height = self.screen_height - title_height };
    }
    /// Hit rectangles are larger than the traffic dots drawn by the host.
    pub fn controlRect(self: Window, control: Control) ui.Rect {
        const caption = self.title();
        const offset: u32 = switch (control) {
            .close => 8,
            .minimize => 36,
            .maximize => 64,
            .fullscreen => caption.width - 32,
        };
        return .{ .x = caption.x + @as(i32, @intCast(offset)), .y = caption.y + 4, .width = 24, .height = 24 };
    }
    pub fn controls(self: Window) [4]ControlRect {
        return .{
            .{ .control = .close, .rect = self.controlRect(.close) },
            .{ .control = .minimize, .rect = self.controlRect(.minimize) },
            .{ .control = .maximize, .rect = self.controlRect(.maximize) },
            .{ .control = .fullscreen, .rect = self.controlRect(.fullscreen) },
        };
    }
    pub fn controlAt(self: Window, point: ui.Point) ?Control {
        for (self.controls()) |item| if (item.rect.contains(point)) return item.control;
        return null;
    }

    /// Opening a minimized window preserves its mode and floating geometry.
    /// A closed window requires the host to launch a fresh client first.
    pub fn open(self: *Window) void {
        self.closed = false;
        self.minimized = false;
        self.visible = true;
        self.focused = true;
        self.cancelPointer();
        self.fullscreen_key_down = false;
        self.escape_key_down = false;
    }
    pub fn close(self: *Window) void {
        self.closed = true;
        self.minimized = false;
        self.visible = false;
        self.focused = false;
        self.cancelPointer();
    }
    pub fn minimize(self: *Window) void {
        if (self.closed) return;
        self.minimized = true;
        self.visible = false;
        self.focused = false;
        self.cancelPointer();
    }
    pub fn maximize(self: *Window) void {
        if (self.closed) return;
        if (self.mode == .floating) self.saved_geometry = self.frame();
        self.mode = .maximized;
        self.applyMode();
    }
    pub fn toggleMaximize(self: *Window) void {
        if (self.closed) return;
        if (self.mode == .maximized) {
            self.mode = .floating;
            self.applyMode();
        } else self.maximize();
    }
    pub fn toggleFullscreen(self: *Window) void {
        if (self.closed) return;
        if (self.mode == .fullscreen) {
            self.mode = self.fullscreen_restore_mode;
        } else {
            if (self.mode == .floating) self.saved_geometry = self.frame();
            self.fullscreen_restore_mode = self.mode;
            self.mode = .fullscreen;
        }
        self.applyMode();
    }
    pub fn restore(self: *Window) void {
        if (self.closed) return;
        if (self.minimized) {
            self.open();
        } else if (self.mode == .fullscreen) {
            self.toggleFullscreen();
        } else if (self.mode == .maximized) {
            self.mode = .floating;
            self.applyMode();
        }
    }
    fn applyMode(self: *Window) void {
        const geometry: ui.Rect = switch (self.mode) {
            .floating => self.saved_geometry,
            .maximized => .{ .x = 0, .y = workarea_top, .width = self.screen_width, .height = self.screen_height - workarea_top - workarea_bottom },
            .fullscreen => .{ .x = 0, .y = 0, .width = self.screen_width, .height = self.screen_height },
        };
        self.x = geometry.x;
        self.y = geometry.y;
        self.width = geometry.width;
        self.height = geometry.height;
        self.cancelPointer();
    }
    fn cancelPointer(self: *Window) void {
        self.hovered = null;
        self.pressed_control = null;
        self.drag = null;
        self.capture = false;
        self.capture_button = 0;
    }
    fn activate(self: *Window, control: Control) void {
        switch (control) {
            .close => self.close(),
            .minimize => self.minimize(),
            .maximize => self.toggleMaximize(),
            .fullscreen => self.toggleFullscreen(),
        }
    }
    fn localEvent(self: Window, event: ui.Event) ui.Event {
        var local = event;
        const content = self.client();
        local.x = @intCast(std.math.clamp(@as(i32, event.x) - content.x, -32768, 32767));
        local.y = @intCast(std.math.clamp(@as(i32, event.y) - content.y, -32768, 32767));
        return local;
    }

    /// Caption controls consume their full press/release sequence. Only a
    /// release inside the originally pressed control changes window state.
    /// Client pointer capture retains an outside release to cancel app drags.
    pub fn route(self: *Window, event: ui.Event) ?ui.Event {
        if (!self.visible or self.closed) return null;
        const pointer = ui.Point{ .x = event.x, .y = event.y };
        if (event.kind == .pointer_down or event.kind == .pointer_up or event.kind == .pointer_move)
            self.hovered = self.controlAt(pointer);
        switch (event.kind) {
            .pointer_down => {
                if (self.pressed_control != null or self.drag != null) return null;
                if (event.code == 1 and !self.capture and self.title().contains(pointer)) {
                    self.focused = true;
                    if (self.controlAt(pointer)) |control| {
                        self.pressed_control = control;
                    } else if (self.mode == .floating) {
                        self.drag = .{ .x = pointer.x - self.x, .y = pointer.y - self.y };
                    }
                    return null;
                }
                const inside = self.client().contains(pointer);
                if (!self.capture) self.focused = inside;
                if (!inside) return null;
                if (!self.capture) {
                    self.capture = true;
                    self.capture_button = event.code;
                }
            },
            .pointer_move => {
                if (self.pressed_control != null) return null;
                if (self.drag) |offset| {
                    self.x = std.math.clamp(pointer.x - offset.x, 0, @as(i32, @intCast(self.screen_width - self.width)));
                    self.y = std.math.clamp(pointer.y - offset.y, @as(i32, workarea_top), @as(i32, @intCast(self.screen_height - self.height - workarea_bottom)));
                    self.saved_geometry = self.frame();
                    return null;
                }
                if (!self.capture and !self.client().contains(pointer)) return null;
            },
            .pointer_up => {
                if (self.pressed_control) |control| {
                    if (event.code != 1) return null;
                    self.pressed_control = null;
                    if (self.controlRect(control).contains(pointer)) self.activate(control);
                    return null;
                }
                if (self.drag != null) {
                    if (event.code == 1) self.drag = null;
                    return null;
                }
                if (!self.capture and !self.client().contains(pointer)) return null;
                if (self.capture and event.code == self.capture_button) {
                    self.capture = false;
                    self.capture_button = 0;
                }
            },
            .key_down => {
                if (!self.focused) return null;
                if (event.code == key.f4 and event.modifiers & ui.input.modifiers.alt != 0) {
                    self.close();
                    return null;
                }
                if (event.code == key.f11 and event.modifiers == 0) {
                    if (!self.fullscreen_key_down) {
                        self.fullscreen_key_down = true;
                        self.toggleFullscreen();
                    }
                    return null;
                }
                if (event.code == @backingInt(ui.input.Key.escape) and (self.mode == .fullscreen or self.escape_key_down)) {
                    if (self.mode == .fullscreen and !self.escape_key_down) self.toggleFullscreen();
                    self.escape_key_down = true;
                    return null;
                }
            },
            .key_up => {
                if (event.code == key.f11 and self.fullscreen_key_down) {
                    self.fullscreen_key_down = false;
                    return null;
                }
                if (event.code == @backingInt(ui.input.Key.escape) and self.escape_key_down) {
                    self.escape_key_down = false;
                    return null;
                }
                if (!self.focused) return null;
            },
            .text => if (!self.focused) return null,
            .wheel => if (!self.focused or !self.client().contains(pointer)) return null,
            .redraw => {},
        }
        return self.localEvent(event);
    }
};

test "window geometry fits supported screens with bounded useful clients" {
    const t = std.testing;
    for ([_][2]u32{ .{ 800, 600 }, .{ 1280, 800 }, .{ 16384, 16384 } }) |screen| {
        var window = try Window.init(screen[0], screen[1]);
        for (0..3) |i| {
            if (i == 1) window.maximize();
            if (i == 2) window.toggleFullscreen();
            const frame = window.frame();
            const client = window.client();
            try t.expect(frame.x >= 0 and frame.y >= 0);
            try t.expect(@as(u32, @intCast(frame.x)) + frame.width <= screen[0]);
            try t.expect(@as(u32, @intCast(frame.y)) + frame.height <= screen[1]);
            try t.expect(client.width >= 640 and client.height >= 360);
            for (window.controls()) |item| try t.expect(window.title().contains(.{ .x = item.rect.x + 23, .y = item.rect.y + 23 }));
        }
    }
    try t.expectError(error.InvalidDesktopGeometry, Window.init(799, 600));
    try t.expectError(error.InvalidDesktopGeometry, Window.init(800, 599));
    try t.expectError(error.InvalidDesktopGeometry, Window.init(16385, 600));
}

fn pointEvent(kind: ui.input.Kind, rect: ui.Rect) ui.Event {
    return .{ .kind = kind, .code = 1, .x = @intCast(rect.x + 12), .y = @intCast(rect.y + 12) };
}
test "controls capture until same-button inside release and canceled release has no effect" {
    const t = std.testing;
    var window = try Window.init(800, 600);
    const close = window.controlRect(.close);
    try t.expect(window.route(pointEvent(.pointer_down, close)) == null);
    try t.expect(window.visible and !window.closed);
    try t.expectEqual(@as(?Control, .close), window.pressed_control);
    var wrong_button = pointEvent(.pointer_up, close);
    wrong_button.code = 2;
    try t.expect(window.route(wrong_button) == null);
    try t.expectEqual(@as(?Control, .close), window.pressed_control);
    const minimize = window.controlRect(.minimize);
    try t.expect(window.route(pointEvent(.pointer_up, minimize)) == null);
    try t.expect(window.visible and !window.closed and !window.minimized);
    try t.expect(window.pressed_control == null);
    _ = window.route(pointEvent(.pointer_down, close));
    _ = window.route(.{ .kind = .pointer_move, .x = 799, .y = 599 });
    try t.expect(window.hovered == null);
    _ = window.route(.{ .kind = .pointer_up, .code = 1, .x = 799, .y = 599 });
    try t.expect(!window.closed);
    _ = window.route(pointEvent(.pointer_down, close));
    _ = window.route(pointEvent(.pointer_up, close));
    try t.expect(window.closed and !window.visible and !window.minimized);
    window.open();
    try t.expect(!window.closed and window.visible and window.focused);
    try t.expect(window.pressed_control == null and !window.capture);
}

test "hover and control presses stay outside client input" {
    const t = std.testing;
    var window = try Window.init(800, 600);
    for (window.controls()) |item| {
        var move = pointEvent(.pointer_move, item.rect);
        move.code = 0;
        try t.expect(window.route(move) == null);
        try t.expectEqual(@as(?Control, item.control), window.hovered);
        try t.expect(window.route(pointEvent(.pointer_down, item.rect)) == null);
        try t.expect(window.route(.{ .kind = .pointer_up, .code = 1, .x = 799, .y = 599 }) == null);
    }
    try t.expect(window.visible and !window.closed);
}

test "minimize and mode transitions retain the exact floating geometry" {
    const t = std.testing;
    var window = try Window.init(1280, 800);
    const floating = window.frame();
    window.minimize();
    try t.expect(window.minimized and !window.closed and !window.visible);
    window.restore();
    try t.expectEqualDeep(floating, window.frame());
    window.toggleMaximize();
    const maximized = window.frame();
    try t.expectEqual(Mode.maximized, window.mode);
    window.minimize();
    window.open();
    try t.expectEqualDeep(maximized, window.frame());
    window.toggleFullscreen();
    try t.expectEqual(Mode.fullscreen, window.mode);
    try t.expectEqual(@as(u32, 0), window.borderWidth());
    try t.expectEqual(@as(i32, 0), window.title().y);
    window.minimize();
    window.open();
    try t.expectEqual(Mode.fullscreen, window.mode);
    window.restore();
    try t.expectEqualDeep(maximized, window.frame());
    window.toggleMaximize();
    try t.expectEqualDeep(floating, window.frame());
    window.toggleFullscreen();
    window.toggleFullscreen();
    try t.expectEqualDeep(floating, window.frame());
}

test "caption drag clamps within work area and client release stays captured" {
    const t = std.testing;
    var window = try Window.init(800, 600);
    const client = window.client();
    const down = window.route(.{ .kind = .pointer_down, .code = 1, .x = @intCast(client.x + 20), .y = @intCast(client.y + 20) }).?;
    try t.expectEqual(@as(i16, 20), down.x);
    var unrelated_up: ui.Event = .{ .kind = .pointer_up, .code = 2, .x = 799, .y = 599 };
    try t.expect(window.route(unrelated_up) != null);
    try t.expect(window.capture);
    unrelated_up.code = 1;
    try t.expect(window.route(unrelated_up) != null);
    try t.expect(!window.capture);
    _ = window.route(.{ .kind = .pointer_down, .code = 1, .x = 0, .y = 0 });
    try t.expect(window.route(.{ .kind = .key_down, .code = 13 }) == null);
    const title = window.title();
    _ = window.route(.{ .kind = .pointer_down, .code = 1, .x = @intCast(title.x + 150), .y = @intCast(title.y + 10) });
    _ = window.route(.{ .kind = .pointer_move, .x = -100, .y = -100 });
    try t.expectEqual(@as(i32, 0), window.x);
    try t.expectEqual(@as(i32, Window.workarea_top), window.y);
    _ = window.route(.{ .kind = .pointer_move, .x = 32000, .y = 32000 });
    try t.expectEqual(@as(i32, 96), window.x);
    try t.expectEqual(@as(i32, 128), window.y);
    try t.expect(window.route(.{ .kind = .pointer_up, .code = 1 }) == null);
    try t.expectEqualDeep(window.frame(), window.saved_geometry);
    window.maximize();
    const maximized = window.frame();
    _ = window.route(.{ .kind = .pointer_down, .code = 1, .x = 200, .y = @intCast(window.title().y + 10) });
    _ = window.route(.{ .kind = .pointer_move, .x = -100, .y = -100 });
    try t.expectEqualDeep(maximized, window.frame());
    try t.expect(window.capture == false and window.drag == null);
}

test "window keyboard guards preserve app Escape and reject repeat toggles" {
    const t = std.testing;
    var window = try Window.init(800, 600);
    const escape: ui.Event = .{ .kind = .key_down, .code = @backingInt(ui.input.Key.escape) };
    try t.expect(window.route(escape) != null);
    const f11: ui.Event = .{ .kind = .key_down, .code = key.f11 };
    try t.expect(window.route(f11) == null);
    try t.expectEqual(Mode.fullscreen, window.mode);
    try t.expect(window.route(f11) == null);
    try t.expectEqual(Mode.fullscreen, window.mode);
    try t.expect(window.route(.{ .kind = .key_up, .code = key.f11 }) == null);
    try t.expect(window.route(escape) == null);
    try t.expectEqual(Mode.floating, window.mode);
    try t.expect(window.route(escape) == null);
    try t.expect(window.route(.{ .kind = .key_up, .code = escape.code }) == null);
    try t.expect(window.route(escape) != null);
    _ = window.route(.{ .kind = .pointer_down, .code = 1, .x = 0, .y = 0 });
    try t.expect(window.route(f11) == null);
    try t.expectEqual(Mode.floating, window.mode);
    const alt_f4: ui.Event = .{ .kind = .key_down, .code = key.f4, .modifiers = ui.input.modifiers.alt };
    try t.expect(window.route(alt_f4) == null);
    try t.expect(!window.closed);
    _ = window.route(pointEvent(.pointer_down, window.client()));
    _ = window.route(pointEvent(.pointer_up, window.client()));
    try t.expect(window.route(.{ .kind = .key_down, .code = key.f4 }) != null);
    try t.expect(window.route(alt_f4) == null);
    try t.expect(window.closed);
    try t.expect(window.route(f11) == null);
}

test "geometry transitions discard old client and caption captures" {
    const t = std.testing;
    var window = try Window.init(800, 600);
    _ = window.route(pointEvent(.pointer_down, window.client()));
    try t.expect(window.capture);
    window.toggleMaximize();
    try t.expect(!window.capture and window.capture_button == 0);
    const maximize = window.controlRect(.maximize);
    _ = window.route(pointEvent(.pointer_down, maximize));
    try t.expect(window.pressed_control != null);
    window.toggleFullscreen();
    try t.expect(window.pressed_control == null and window.hovered == null);
    _ = window.route(pointEvent(.pointer_up, window.controlRect(.maximize)));
    try t.expectEqual(Mode.fullscreen, window.mode);
}

test "each caption control acts only on release and restores through its same hitbox" {
    const t = std.testing;
    var window = try Window.init(800, 600);
    const original = window.frame();
    for ([_]Control{ .minimize, .maximize, .fullscreen }) |control| {
        const rect = window.controlRect(control);
        _ = window.route(pointEvent(.pointer_down, rect));
        try t.expect(window.visible and !window.minimized);
        try t.expectEqual(Mode.floating, window.mode);
        _ = window.route(pointEvent(.pointer_up, rect));
        switch (control) {
            .minimize => {
                try t.expect(!window.visible and window.minimized and !window.closed);
                window.open();
            },
            .maximize => {
                try t.expectEqual(Mode.maximized, window.mode);
                const restore = window.controlRect(control);
                _ = window.route(pointEvent(.pointer_down, restore));
                _ = window.route(pointEvent(.pointer_up, restore));
            },
            .fullscreen => {
                try t.expectEqual(Mode.fullscreen, window.mode);
                const exit = window.controlRect(control);
                try t.expectEqual(@as(i32, 4), exit.y);
                _ = window.route(pointEvent(.pointer_down, exit));
                _ = window.route(pointEvent(.pointer_up, exit));
            },
            .close => unreachable,
        }
        try t.expectEqualDeep(original, window.frame());
        try t.expectEqual(Mode.floating, window.mode);
    }
}

test "client wheel focus and hotkeys do not grant input outside their target" {
    const t = std.testing;
    var window = try Window.init(800, 600);
    try t.expect(window.route(.{ .kind = .wheel, .x = 0, .y = 0 }) == null);
    const inside = pointEvent(.wheel, window.client());
    try t.expect(window.route(inside) != null);
    try t.expect(window.route(.{ .kind = .key_down, .code = key.f11, .modifiers = ui.input.modifiers.control }) != null);
    try t.expectEqual(Mode.floating, window.mode);
    window.minimize();
    try t.expect(window.route(.{ .kind = .key_down, .code = key.f11 }) == null);
    try t.expect(window.route(inside) == null);
    window.open();
    _ = window.route(.{ .kind = .pointer_down, .code = 1, .x = 0, .y = 0 });
    try t.expect(window.route(inside) == null);
    try t.expect(window.route(.{ .kind = .text, .code = 'a' }) == null);
}
