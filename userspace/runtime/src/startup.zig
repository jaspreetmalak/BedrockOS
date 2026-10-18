//! Validate the immutable installed-application startup record before using it.
const std = @import("std");
const abi = @import("bedrock64");

pub const Error = error{ InvalidStartupHeader, InvalidStartupIdentity, InvalidStartupHeap, InvalidStartupFlags, InvalidStartupText, InvalidStartupCounts, InvalidStartupEnvironment, InvalidStartupReserved, EntryMismatch };

fn allZero(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != 0) return false;
    return true;
}

fn validateText(text: *const abi.Text, used: bool) Error!void {
    if (text.length > text.bytes.len or !allZero(&text.reserved)) return error.InvalidStartupText;
    if (!used and text.length != 0) return error.InvalidStartupText;
    if (!allZero(text.bytes[text.length..])) return error.InvalidStartupText;
    for (text.slice()) |byte| if (byte == 0) return error.InvalidStartupText;
}

pub fn validate(info: *const abi.Startup) Error!void {
    if (info.version != 1 or info.size != @sizeOf(abi.Startup)) return error.InvalidStartupHeader;
    if (info.pid == 0 or info.app_id == 0 or info.parent == info.pid) return error.InvalidStartupIdentity;
    if (info.heap_base != abi.application.heap_address or info.heap_length == 0 or
        info.heap_length > abi.application.heap_limit or info.heap_length % abi.page_size != 0 or
        info.heap_capacity != info.heap_length) return error.InvalidStartupHeap;
    if (info.flags & ~abi.application.test_mode != 0) return error.InvalidStartupFlags;
    if (!allZero(&info.reserved)) return error.InvalidStartupReserved;
    if (info.argc == 0 or info.argc > info.args.len or info.envc > info.environment.len) return error.InvalidStartupCounts;
    for (&info.args, 0..) |*item, i| try validateText(item, i < info.argc);
    if (info.args[0].length == 0) return error.InvalidStartupText;
    for (&info.environment, 0..) |*entry, i| {
        try validateText(entry, i < info.envc);
        if (i < info.envc) {
            const separator = std.mem.indexOfScalar(u8, entry.slice(), '=') orelse return error.InvalidStartupEnvironment;
            if (separator == 0) return error.InvalidStartupEnvironment;
            for (info.environment[0..i]) |previous| {
                const earlier = std.mem.indexOfScalar(u8, previous.slice(), '=').?;
                if (std.mem.eql(u8, entry.slice()[0..separator], previous.slice()[0..earlier])) return error.InvalidStartupEnvironment;
            }
        }
    }
}

pub fn validateEntry(info: *const abi.Startup, parent: u64, inherited_token: u64, launch_arg: u64) Error!void {
    try validate(info);
    if (info.parent != parent or info.inherited_token != inherited_token or info.launch_arg != launch_arg) return error.EntryMismatch;
}

pub fn argument(info: *const abi.Startup, index: usize) ?[]const u8 {
    return if (index < info.argc) info.args[index].slice() else null;
}

pub fn environment(info: *const abi.Startup, name: []const u8) ?[]const u8 {
    for (info.environment[0..info.envc]) |*entry| {
        const separator = std.mem.indexOfScalar(u8, entry.slice(), '=') orelse continue;
        if (std.mem.eql(u8, entry.slice()[0..separator], name)) return entry.slice()[separator + 1 ..];
    }
    return null;
}

fn fixture() abi.Startup {
    var result: abi.Startup = .{ .pid = 7, .parent = 3, .app_id = abi.application.observer, .heap_capacity = 8 * abi.page_size, .heap_length = 8 * abi.page_size, .argc = 2, .envc = 2 };
    result.args[0] = abi.Text.init("org.bedrock.observer") catch unreachable;
    result.args[1] = abi.Text.init("--watch") catch unreachable;
    result.environment[0] = abi.Text.init("BEDROCK_ROLE=observer") catch unreachable;
    result.environment[1] = abi.Text.init("EMPTY=") catch unreachable;
    return result;
}

test "startup decodes bounded arguments and environment and matches entry" {
    const info = fixture();
    try validateEntry(&info, 3, 0, 0);
    try std.testing.expectEqualStrings("--watch", argument(&info, 1).?);
    try std.testing.expect(argument(&info, 2) == null);
    try std.testing.expectEqualStrings("observer", environment(&info, "BEDROCK_ROLE").?);
    try std.testing.expectEqualStrings("", environment(&info, "EMPTY").?);
    try std.testing.expect(environment(&info, "BEDROCK") == null);
    try std.testing.expectError(error.EntryMismatch, validateEntry(&info, 9, 0, 0));
}

test "startup rejects versions reserved fields and unknown flags" {
    var info = fixture();
    info.version = 2;
    try std.testing.expectError(error.InvalidStartupHeader, validate(&info));
    info = fixture();
    info.size += 1;
    try std.testing.expectError(error.InvalidStartupHeader, validate(&info));
    info = fixture();
    info.reserved[4] = 1;
    try std.testing.expectError(error.InvalidStartupReserved, validate(&info));
    info = fixture();
    info.flags = 2;
    try std.testing.expectError(error.InvalidStartupFlags, validate(&info));
}

test "startup rejects out of bounds text counts and uninitialized tails" {
    var info = fixture();
    info.argc = 9;
    try std.testing.expectError(error.InvalidStartupCounts, validate(&info));
    info = fixture();
    info.args[0].length = 57;
    try std.testing.expectError(error.InvalidStartupText, validate(&info));
    info = fixture();
    info.args[3].bytes[0] = 'x';
    try std.testing.expectError(error.InvalidStartupText, validate(&info));
    info = fixture();
    info.args[1].reserved[0] = 1;
    try std.testing.expectError(error.InvalidStartupText, validate(&info));
    info = fixture();
    info.args[0].bytes[2] = 0;
    try std.testing.expectError(error.InvalidStartupText, validate(&info));
}

test "startup rejects duplicate or malformed environment names" {
    var info = fixture();
    info.environment[1] = try abi.Text.init("BEDROCK_ROLE=worker");
    try std.testing.expectError(error.InvalidStartupEnvironment, validate(&info));
    info = fixture();
    info.environment[1] = try abi.Text.init("=value");
    try std.testing.expectError(error.InvalidStartupEnvironment, validate(&info));
    info = fixture();
    info.environment[1] = try abi.Text.init("missing-separator");
    try std.testing.expectError(error.InvalidStartupEnvironment, validate(&info));
}

test "startup rejects invalid identity and heap lease boundaries" {
    var info = fixture();
    info.pid = 0;
    try std.testing.expectError(error.InvalidStartupIdentity, validate(&info));
    info = fixture();
    info.parent = info.pid;
    try std.testing.expectError(error.InvalidStartupIdentity, validate(&info));
    info = fixture();
    info.heap_base += abi.page_size;
    try std.testing.expectError(error.InvalidStartupHeap, validate(&info));
    info = fixture();
    info.heap_length = abi.application.heap_limit + abi.page_size;
    info.heap_capacity = info.heap_length;
    try std.testing.expectError(error.InvalidStartupHeap, validate(&info));
    info = fixture();
    info.heap_capacity += abi.page_size;
    try std.testing.expectError(error.InvalidStartupHeap, validate(&info));
    info = fixture();
    info.heap_length = 1;
    info.heap_capacity = 1;
    try std.testing.expectError(error.InvalidStartupHeap, validate(&info));
}
