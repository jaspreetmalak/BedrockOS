//! Visual reuse of a last authenticated, locally copied window snapshot.
//! This never validates a new client frame, advances an epoch or releases ACKs.
const std = @import("std");
const Config = @import("userspace_runtime").window_wire.Config;

pub const Frame = struct {
    app: u64 = 0,
    pid: u64 = 0,
    config: ?Config = null,

    /// Only call after authenticating and copying the complete client snapshot.
    /// The compositor still owns the matching pixels and their cache lifetime.
    pub fn remember(self: *Frame, app: u64, pid: u64, config: Config) void {
        self.* = .{ .app = app, .pid = pid, .config = config };
    }

    /// A translation/new epoch may reuse pixels for display while waiting for
    /// the current frame. Other identities, geometry and header modes cannot.
    pub fn compatible(self: *const Frame, app: u64, pid: u64, config: Config) bool {
        const saved = self.config orelse return false;
        return app != 0 and pid != 0 and self.app == app and self.pid == pid and
            config.width != 0 and config.height != 0 and
            config.width <= config.screen_width and config.height <= config.screen_height and
            (!config.header_tabs or config.header_content) and
            saved.window_id == config.window_id and
            saved.width == config.width and saved.height == config.height and
            saved.screen_width == config.screen_width and saved.screen_height == config.screen_height and
            saved.header_content == config.header_content and saved.header_tabs == config.header_tabs;
    }

    /// Close/release and registry-slot creation must forget the old identity.
    pub fn invalidate(self: *Frame) void {
        self.* = .{};
    }
};

fn configuration() Config {
    return .{ .sequence = 7, .width = 636, .height = 416, .screen_width = 1280, .screen_height = 800, .origin_x = 50, .origin_y = 86, .header_content = true, .header_tabs = true, .window_id = 2 };
}

test "retained frame permits only visual translation across configure epochs" {
    const t = std.testing;
    var frame: Frame = .{};
    const original = configuration();
    try t.expect(!frame.compatible(2, 10, original));
    frame.remember(2, 10, original);
    try t.expect(frame.compatible(2, 10, original));
    var translated = original;
    translated.sequence = 81;
    translated.origin_x = 602;
    translated.origin_y = 370;
    try t.expect(frame.compatible(2, 10, translated));
    // Looking up visual compatibility cannot certify the new configuration.
    try t.expectEqualDeep(original, frame.config.?);
    frame.invalidate();
    try t.expect(!frame.compatible(2, 10, original));
    try t.expect(frame.config == null and frame.app == 0 and frame.pid == 0);
}

test "retained frame isolates app PID and window identities across reused slots" {
    const t = std.testing;
    var frame: Frame = .{};
    const config = configuration();
    frame.remember(2, 10, config);
    try t.expect(!frame.compatible(108, 10, config));
    try t.expect(!frame.compatible(2, 11, config));
    try t.expect(!frame.compatible(0, 10, config));
    try t.expect(!frame.compatible(2, 0, config));
    var other = config;
    other.window_id += 1;
    try t.expect(!frame.compatible(2, 10, other));
    frame.invalidate();
    try t.expect(!frame.compatible(2, 10, config));
    frame.remember(2, 11, other);
    try t.expect(frame.compatible(2, 11, other));
    try t.expect(!frame.compatible(2, 10, config));
}

test "retained frame refuses resize screen changes header changes and hidden viewports" {
    const t = std.testing;
    var frame: Frame = .{};
    const original = configuration();
    frame.remember(2, 10, original);
    inline for (.{ "width", "height", "screen_width", "screen_height" }) |field| {
        var changed = original;
        @field(changed, field) += 1;
        try t.expect(!frame.compatible(2, 10, changed));
    }
    inline for (.{ "header_content", "header_tabs" }) |field| {
        var changed = original;
        @field(changed, field) = !@field(changed, field);
        try t.expect(!frame.compatible(2, 10, changed));
    }
    inline for (.{ "width", "height" }) |field| {
        var hidden = original;
        @field(hidden, field) = 0;
        try t.expect(!frame.compatible(2, 10, hidden));
        frame.remember(2, 10, hidden);
        try t.expect(!frame.compatible(2, 10, hidden));
        frame.remember(2, 10, original);
    }
}

test "retained frame replacement remembers only the newest authenticated snapshot" {
    const t = std.testing;
    var frame: Frame = .{};
    const first = configuration();
    frame.remember(2, 10, first);
    var resized = first;
    resized.sequence += 1;
    resized.width += 40;
    try t.expect(!frame.compatible(2, 10, resized));
    frame.remember(2, 10, resized);
    try t.expect(frame.compatible(2, 10, resized));
    try t.expect(!frame.compatible(2, 10, first));
}
