//! Shared checked namespace requests for native processes and desktop clients.
const abi = @import("bedrock64");
const vfs = @import("vfs.zig");
const security = @import("security");
const user = @import("user_memory.zig");
const storage = &@import("storage_runtime.zig").storage;
pub const Path = struct {
    bytes: [abi.max_path]u8 = undefined,
    length: usize = 0,
    pub fn slice(self: *const Path) []const u8 {
        return self.bytes[0..self.length];
    }
};
pub fn copyin(regions: []const user.Region, address: u64, output: []u8) !void {
    if (output.len == 0) return;
    const physical = try user.translateRead(regions, address, output.len);
    const source: [*]const volatile u8 = @ptrFromInt(physical);
    for (output, 0..) |*byte, index| byte.* = source[index];
}
pub fn copyout(regions: []const user.Region, address: u64, input: []const u8) !void {
    if (input.len == 0) return;
    const physical = try user.translateWrite(regions, address, input.len);
    const destination: [*]volatile u8 = @ptrFromInt(physical);
    for (input, 0..) |byte, index| destination[index] = byte;
}
pub fn path(regions: []const user.Region, address: u64, length: u64) !Path {
    if (length == 0 or length > abi.max_path) return error.PathTooLong;
    var value: Path = .{ .length = @intCast(length) };
    try copyin(regions, address, value.bytes[0..value.length]);
    return value;
}
pub fn serve(profile: security.sandbox.Profile, regions: []const user.Region, number: u64, arg0: u64, arg1: u64, arg2: u64) !u64 {
    switch (number) {
        abi.syscall.list => {
            const directory = try path(regions, arg0, arg1);
            // Validate the entire copyout and copyin before advancing cursor.
            _ = try user.translateWrite(regions, arg2, @sizeOf(abi.DirectoryRecord));
            var request: abi.DirectoryRecord = undefined;
            try copyin(regions, arg2, @import("std").mem.asBytes(&request));
            if (request.cursor > 32) return error.InvalidCursor;
            var cursor: usize = @intCast(request.cursor);
            const entry = (try storage.list(profile, directory.slice(), &cursor)) orelse return 0;
            var output: abi.DirectoryRecord = .{ .cursor = cursor, .name = @splat(0), .size = entry.size, .kind = if (entry.kind == .directory) 1 else 0, .name_len = entry.name_len, .read_only = @intFromBool(entry.read_only), .reserved = @splat(0) };
            @memcpy(output.name[0..entry.name_len], entry.name[0..entry.name_len]);
            try copyout(regions, arg2, @import("std").mem.asBytes(&output));
        },
        abi.syscall.mkdir, abi.syscall.unlink, abi.syscall.nullify => {
            if (arg2 != 0) return error.InvalidRequest;
            const target = try path(regions, arg0, arg1);
            switch (number) {
                abi.syscall.mkdir => try storage.mkdir(profile, target.slice()),
                abi.syscall.nullify => try storage.nullify(profile, target.slice()),
                else => try storage.unlink(profile, target.slice()),
            }
        },
        abi.syscall.copy, abi.syscall.rename => {
            if (arg1 != 0 or arg2 != 0) return error.InvalidRequest;
            var request: abi.PathPair = undefined;
            try copyin(regions, arg0, @import("std").mem.asBytes(&request));
            const source = try path(regions, request.source, request.source_length);
            const destination = try path(regions, request.destination, request.destination_length);
            if (number == abi.syscall.copy) try storage.copy(profile, source.slice(), destination.slice()) else try storage.rename(profile, source.slice(), destination.slice());
        },
        else => return error.UnsupportedSyscall,
    }
    return if (number == abi.syscall.list) 1 else 0;
}
