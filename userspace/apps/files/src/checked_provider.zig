//! Checked Files I/O adapter shared by the installed compositor client.
const std = @import("std");
const rt = @import("userspace_runtime");
const abi = @import("bedrock64");
const app = @import("files_app");
pub var nullify_commits: u64 = 0;
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
    nullify_commits += 1;
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

pub fn provider(context: *anyopaque) app.Provider {
    return .{ .context = context, .list = &list, .create = &create, .mkdir = &mkdir, .copy = &copy, .move = &move, .remove = &remove, .nullify = &nullify, .read = &read, .write = &write };
}
