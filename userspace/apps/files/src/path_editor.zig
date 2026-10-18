//! Bounded ASCII location editing. The provider remains the I/O authority.
const std = @import("std");
const ui = @import("axisui");
const api = @import("provider.zig");

pub const Selection = struct { start: usize, end: usize };
pub const Editor = struct {
    bytes: [api.max_path_bytes]u8 = undefined,
    len: usize = 0,
    cursor: usize = 0,
    anchor: usize = 0,

    pub fn text(self: *const Editor) []const u8 {
        return self.bytes[0..self.len];
    }
    pub fn set(self: *Editor, value: []const u8, select_all: bool) void {
        std.debug.assert(value.len <= self.bytes.len);
        @memcpy(self.bytes[0..value.len], value);
        self.len = value.len;
        self.cursor = value.len;
        self.anchor = if (select_all) 0 else self.cursor;
    }
    pub fn selection(self: *const Editor) Selection {
        return .{ .start = @min(self.cursor, self.anchor), .end = @max(self.cursor, self.anchor) };
    }
    pub fn move(self: *Editor, target: usize, extend: bool) void {
        self.cursor = @min(target, self.len);
        if (!extend) self.anchor = self.cursor;
    }
    pub fn left(self: *Editor, extend: bool) void {
        const range = self.selection();
        self.move(if (!extend and range.start != range.end) range.start else self.cursor -| 1, extend);
    }
    pub fn right(self: *Editor, extend: bool) void {
        const range = self.selection();
        self.move(if (!extend and range.start != range.end) range.end else self.cursor + 1, extend);
    }
    pub fn selectAll(self: *Editor) void {
        self.anchor = 0;
        self.cursor = self.len;
    }
    fn eraseSelection(self: *Editor) bool {
        const range = self.selection();
        if (range.start == range.end) return false;
        std.mem.copyForwards(u8, self.bytes[range.start .. self.len - (range.end - range.start)], self.bytes[range.end..self.len]);
        self.len -= range.end - range.start;
        self.cursor = range.start;
        self.anchor = self.cursor;
        return true;
    }
    pub fn insert(self: *Editor, byte: u16) !void {
        if (byte < 32 or byte > 126) return error.UnsupportedCharacter;
        const range = self.selection();
        if (self.len - (range.end - range.start) == self.bytes.len) return error.PathTooLong;
        _ = self.eraseSelection();
        std.mem.copyBackwards(u8, self.bytes[self.cursor + 1 .. self.len + 1], self.bytes[self.cursor..self.len]);
        self.bytes[self.cursor] = @intCast(byte);
        self.len += 1;
        self.move(self.cursor + 1, false);
    }
    pub fn backspace(self: *Editor) void {
        if (self.eraseSelection() or self.cursor == 0) return;
        self.anchor = self.cursor - 1;
        _ = self.eraseSelection();
    }
    pub fn delete(self: *Editor) void {
        if (self.eraseSelection() or self.cursor == self.len) return;
        self.anchor = self.cursor + 1;
        _ = self.eraseSelection();
    }
    /// Scroll only whole glyphs; reserve a pixel for the caret at the right edge.
    pub fn visibleStart(self: *const Editor, width: u32) usize {
        var start: usize = 0;
        while (start < self.cursor and measured(self.text()[start..self.cursor]) > width -| 1) : (start += 1) {}
        return start;
    }
    pub fn visibleEnd(self: *const Editor, start: usize, width: u32) usize {
        var end = start;
        while (end < self.len and measured(self.text()[start .. end + 1]) <= width) : (end += 1) {}
        return end;
    }
    pub fn cursorAt(self: *const Editor, width: u32, x: u32) usize {
        const start = self.visibleStart(width);
        const end = self.visibleEnd(start, width);
        var previous: u32 = 0;
        for (start..end) |index| {
            const next = measured(self.text()[start .. index + 1]);
            if (x < previous + (next - previous + 1) / 2) return index;
            previous = next;
        }
        return end;
    }
};
pub fn measured(bytes: []const u8) u32 {
    return (ui.font.measure(bytes, 1) catch unreachable).width;
}
pub fn display(path: []const u8, output: *[api.max_path_bytes]u8) []const u8 {
    const home = "/container";
    if (std.mem.eql(u8, path, home) or std.mem.startsWith(u8, path, "/container/")) {
        output[0] = '~';
        @memcpy(output[1 .. 1 + path.len - home.len], path[home.len..]);
        return output[0 .. 1 + path.len - home.len];
    }
    @memcpy(output[0..path.len], path);
    return output[0..path.len];
}

/// Normalize redundant slashes and a trailing slash without resolving traversal.
/// Locations are always within the app's private /container namespace.
pub fn canonical(input: []const u8, output: *[api.max_path_bytes]u8) ![]const u8 {
    if (input.len == 0 or input.len > api.max_path_bytes) return error.InvalidPath;
    var source = std.mem.splitScalar(u8, input, '/');
    const first = source.next() orelse unreachable;
    var count: usize = 0;
    var root = true;
    if (std.mem.eql(u8, first, "~")) {
        @memcpy(output[0..10], "/container");
        count = 10;
        root = false;
    } else if (first.len != 0) return error.InvalidPath;
    while (source.next()) |part| {
        if (part.len == 0) continue;
        if (root and !std.mem.eql(u8, part, "container")) return error.PermissionDenied;
        api.validateName(part) catch return error.InvalidPath;
        if (count + 1 + part.len > output.len) return error.PathTooLong;
        output[count] = '/';
        count += 1;
        @memcpy(output[count .. count + part.len], part);
        count += part.len;
        root = false;
    }
    if (root) return error.PermissionDenied;
    try api.validatePath(output[0..count]);
    return output[0..count];
}

test "location normalization preserves the private root without resolving traversal" {
    var output: [api.max_path_bytes]u8 = undefined;
    try std.testing.expectEqualStrings("/container/Documents", try canonical("//container//Documents/", &output));
    try std.testing.expectEqualStrings("/container", try canonical("/container///", &output));
    try std.testing.expectEqualStrings("/container/Downloads", try canonical("~//Downloads/", &output));
    try std.testing.expectEqualStrings("/container", try canonical("~", &output));
    try std.testing.expectEqualStrings("~/Documents", display("/container/Documents", &output));
    try std.testing.expectEqualStrings("~", display("/container", &output));
    for ([_][]const u8{ "/container/../Downloads", "/container/./Documents", "~/../Downloads", "~/Documents\\Other", "/container/Bad\nName", "container/Documents", "~other/Documents", "" }) |path| {
        try std.testing.expectError(error.InvalidPath, canonical(path, &output));
    }
    for ([_][]const u8{ "/private/108/container", "/container2", "/bundle", "/" }) |path| {
        try std.testing.expectError(error.PermissionDenied, canonical(path, &output));
    }
}

test "location glyph scroll and pointer caret use measured proportional widths" {
    var editor: Editor = .{};
    editor.set("WiWiWiWiWiWiWiWi", false);
    const width = measured("WiWi");
    const start = editor.visibleStart(width);
    try std.testing.expect(start != 0);
    try std.testing.expect(measured(editor.text()[start..editor.cursor]) < width);
    try std.testing.expectEqual(start, editor.cursorAt(width, 0));
    try std.testing.expectEqual(editor.len, editor.cursorAt(width, width));
    editor.move(0, false);
    const first_width = measured("W");
    try std.testing.expectEqual(@as(usize, 0), editor.cursorAt(width, first_width / 3));
    try std.testing.expectEqual(@as(usize, 1), editor.cursorAt(width, first_width));
    editor.move(editor.len, false);
    try std.testing.expectEqual(editor.cursor, editor.visibleStart(0));
}
