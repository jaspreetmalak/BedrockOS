//! Authority is supplied by the host through these callbacks. The application
//! does not import a backend, interpret an app ID or open a raw device.
pub const max_name_bytes = 96;
pub const max_path_bytes = 256;
pub const max_entries = 32;
pub const Kind = enum { file, directory };
pub const Entry = struct {
    name: [max_name_bytes]u8 = undefined,
    name_len: u8 = 0,
    kind: Kind = .file,
    size: u64 = 0,
    read_only: bool = false,
    pub fn bytes(self: *const Entry) []const u8 {
        return self.name[0..@min(self.name_len, max_name_bytes)];
    }
    pub fn init(name: []const u8, kind: Kind, size: u64, read_only: bool) !Entry {
        try validateName(name);
        var result: Entry = .{ .kind = kind, .size = size, .read_only = read_only };
        @memcpy(result.name[0..name.len], name);
        result.name_len = @intCast(name.len);
        return result;
    }
};
pub fn validateName(name: []const u8) !void {
    if (name.len == 0 or name.len > max_name_bytes) return error.InvalidName;
    if (name.len == 1 and name[0] == '.' or name.len == 2 and name[0] == '.' and name[1] == '.') return error.InvalidName;
    for (name) |byte| if (byte < 32 or byte > 126 or byte == '/' or byte == '\\') return error.InvalidName;
}
pub fn validatePath(path: []const u8) !void {
    if (path.len == 0 or path.len > max_path_bytes or path[0] != '/') return error.InvalidPath;
    if (path.len == 1) return;
    if (path[path.len - 1] == '/') return error.InvalidPath;
    var start: usize = 1;
    for (1..path.len + 1) |end| {
        if (end != path.len and path[end] != '/') continue;
        validateName(path[start..end]) catch return error.InvalidPath;
        start = end + 1;
    }
}
pub const Provider = struct {
    context: *anyopaque,
    /// Advance cursor strictly for each returned entry. Return null at EOF.
    /// Names are copied values; no borrowed provider listing remains in Model.
    list: *const fn (*anyopaque, []const u8, *usize) anyerror!?Entry,
    open: ?*const fn (*anyopaque, []const u8) anyerror!void = null,
    read: ?*const fn (*anyopaque, []const u8, u64, []u8) anyerror!usize = null,
    write: ?*const fn (*anyopaque, []const u8, u64, []const u8) anyerror!usize = null,
    create: ?*const fn (*anyopaque, []const u8) anyerror!void = null,
    mkdir: ?*const fn (*anyopaque, []const u8) anyerror!void = null,
    copy: ?*const fn (*anyopaque, []const u8, []const u8) anyerror!void = null,
    move: ?*const fn (*anyopaque, []const u8, []const u8) anyerror!void = null,
    remove: ?*const fn (*anyopaque, []const u8) anyerror!void = null,
    nullify: ?*const fn (*anyopaque, []const u8) anyerror!void = null,
};
