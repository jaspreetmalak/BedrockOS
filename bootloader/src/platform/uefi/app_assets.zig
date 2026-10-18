//! Installed application archive acquired only from the boot image's filesystem.
//! All handles close before the final EFI map, and retained pages are transferred
//! as read-only application source bytes rather than executable kernel memory.
const std = @import("std");
const uefi = std.os.uefi;
const protocol = @import("boot_protocol");
const bundles = @import("app_bundles");
pub const path = "\\EFI\\Bedrock\\Apps\\apps.bap";
pub const File = struct { token: usize, length: u64, directory: bool = false };
pub const Provider = struct {
    context: *anyopaque,
    open: *const fn (*anyopaque, []const u8) anyerror!?File,
    read: *const fn (*anyopaque, File, []u8) anyerror!usize,
    close: *const fn (*anyopaque, File) anyerror!void,
    allocate: *const fn (*anyopaque, usize) anyerror![]align(4096) u8,
    free: *const fn (*anyopaque, []align(4096) u8) anyerror!void,
};
pub const Retained = struct {
    allocation: []align(4096) u8,
    record: protocol.AppBoot,

    /// Only call on a loader failure before its first ExitBootServices attempt.
    pub fn release(self: *Retained, bs: *uefi.tables.BootServices) !void {
        const pages: [*]align(4096) uefi.Page = @ptrCast(self.allocation.ptr);
        try bs.freePages(pages[0 .. self.allocation.len / 4096]);
    }
};

/// Allocation ownership transfers only after a complete validated read and a
/// successful close. Every earlier failure releases its own staging allocation.
pub fn stageWithProvider(io: Provider, architecture: bundles.Architecture, address_limit: u64) !?Retained {
    const file = (try io.open(io.context, path)) orelse return null;
    var is_open = true;
    defer if (is_open) io.close(io.context, file) catch {};
    if (file.directory or file.length < bundles.header_size or file.length > bundles.max_archive_bytes)
        return error.InvalidApplicationFileInfo;
    const capacity: usize = @intCast((file.length + 4095) & ~@as(u64, 4095));
    const allocation = try io.allocate(io.context, capacity);
    errdefer io.free(io.context, allocation) catch {};
    if (allocation.len != capacity or @intFromPtr(allocation.ptr) == 0) return error.InvalidApplicationAllocation;
    const reservation: protocol.PhysicalRange = .{ .base = @intFromPtr(allocation.ptr), .length = allocation.len };
    if (try reservation.endExclusive() > address_limit) return error.ApplicationOutsideAddressableRange;
    @memset(allocation, 0);
    const bytes = allocation[0..@intCast(file.length)];
    var used: usize = 0;
    var calls: usize = 0;
    while (used < bytes.len) {
        calls += 1;
        if (calls > 4096) return error.ApplicationReadBudget;
        const count = try io.read(io.context, file, bytes[used..]);
        if (count == 0 or count > bytes.len - used) return error.TruncatedApplicationArchive;
        used += count;
    }
    var trailing: [1]u8 = undefined;
    if (try io.read(io.context, file, &trailing) != 0) return error.TrailingApplicationBytes;
    _ = try bundles.inspect(bytes, architecture);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    is_open = false;
    try io.close(io.context, file);
    const result: Retained = .{ .allocation = allocation, .record = .{
        .reservation = reservation,
        .archive = .{ .base = reservation.base, .length = bytes.len },
        .sha256 = digest,
    } };
    try result.record.validate();
    return result;
}

const UefiProvider = struct {
    bs: *uefi.tables.BootServices,
    root: *uefi.protocol.File,

    fn io(self: *UefiProvider) Provider {
        return .{ .context = self, .open = &open, .read = &read, .close = &close, .allocate = &allocate, .free = &free };
    }
    fn get(context: *anyopaque) *UefiProvider {
        return @ptrCast(@alignCast(context));
    }
    fn open(context: *anyopaque, _: []const u8) !?File {
        const filename = comptime utf16(path);
        const file = get(context).root.open(&filename, .read, .{}) catch |err| switch (err) {
            error.NotFound => return null,
            else => return err,
        };
        errdefer file.close() catch {};
        var information: [512]u8 align(8) = undefined;
        var size: usize = information.len;
        if (file._get_info(file, &uefi.protocol.File.Info.File.guid, &size, &information) != .success or
            size < @sizeOf(uefi.protocol.File.Info.File) or size > information.len) return error.InvalidApplicationFileInfo;
        const info: *const uefi.protocol.File.Info.File = @ptrCast(&information);
        if (info.size < @sizeOf(uefi.protocol.File.Info.File) or info.size > size) return error.InvalidApplicationFileInfo;
        return .{ .token = @intFromPtr(file), .length = info.file_size, .directory = info.attribute.directory };
    }
    fn read(_: *anyopaque, file: File, output: []u8) !usize {
        const handle: *uefi.protocol.File = @ptrFromInt(file.token);
        return handle.read(output);
    }
    fn close(_: *anyopaque, file: File) !void {
        const handle: *uefi.protocol.File = @ptrFromInt(file.token);
        try handle.close();
    }
    fn allocate(context: *anyopaque, size: usize) ![]align(4096) u8 {
        const pages = try get(context).bs.allocatePages(.any, .loader_data, size / 4096);
        const bytes: [*]align(4096) u8 = @ptrCast(pages.ptr);
        return bytes[0..size];
    }
    fn free(context: *anyopaque, bytes: []align(4096) u8) !void {
        const pages: [*]align(4096) uefi.Page = @ptrCast(bytes.ptr);
        try get(context).bs.freePages(pages[0 .. bytes.len / 4096]);
    }
};
fn utf16(comptime text: []const u8) [text.len:0]u16 {
    var result: [text.len:0]u16 = undefined;
    for (text, 0..) |byte, index| result[index] = byte;
    result[text.len] = 0;
    return result;
}
pub fn stage(bs: *uefi.tables.BootServices, image: uefi.Handle, architecture: bundles.Architecture, address_limit: u64) !?Retained {
    const loaded = (try bs.openProtocol(uefi.protocol.LoadedImage, image, .{ .by_handle_protocol = .{ .agent = image } })) orelse return error.LoadedImageUnavailable;
    const fs = (try bs.openProtocol(uefi.protocol.SimpleFileSystem, loaded.device_handle orelse return error.LoadedImageDeviceUnavailable, .{ .by_handle_protocol = .{ .agent = image } })) orelse return error.LoadedImageFilesystemUnavailable;
    const root = try fs.openVolume();
    defer root.close() catch {};
    var provider: UefiProvider = .{ .bs = bs, .root = root };
    return stageWithProvider(provider.io(), architecture, address_limit);
}

const Fixture = struct {
    bytes: [288]u8 = @splat(0),
    fn init() Fixture {
        var result: Fixture = .{};
        @memcpy(result.bytes[0..8], bundles.magic);
        result.set(u16, 8, 1);
        result.set(u16, 10, 62);
        result.set(u32, 12, 64);
        result.set(u32, 16, 160);
        result.set(u32, 20, 1);
        result.set(u64, 24, result.bytes.len);
        result.set(u64, 64, 101);
        result.set(u32, 72, 1);
        result.set(u32, 76, 1);
        @memcpy(result.bytes[80..][0..16], "org.bedrock.init");
        @memcpy(result.bytes[112..][0..16], "/bundle/main.elf");
        result.set(u64, 176, 224);
        result.set(u64, 184, 64);
        @memcpy(result.bytes[224..][0..7], "\x7fELF\x02\x01\x01");
        result.set(u16, 240, 2);
        result.set(u16, 242, 62);
        result.set(u32, 244, 1);
        result.set(u16, 276, 64);
        std.crypto.hash.sha2.Sha256.hash(result.bytes[224..], result.bytes[192..224], .{});
        std.crypto.hash.sha2.Sha256.hash(result.bytes[64..224], result.bytes[32..64], .{});
        return result;
    }
    fn set(self: *Fixture, comptime T: type, offset: usize, value: T) void {
        std.mem.writeInt(T, self.bytes[offset..][0..@sizeOf(T)], value, .little);
    }
};
const Model = struct {
    source: []const u8,
    position: usize = 0,
    open_count: usize = 0,
    close_count: usize = 0,
    allocations: usize = 0,
    frees: usize = 0,
    missing: bool = false,
    truncated: bool = false,
    oversized_read: bool = false,
    close_failure: bool = false,
    allocation_failure: bool = false,
    chunk: usize = 37,
    reported_length: ?u64 = null,
    fn io(self: *Model) Provider {
        return .{ .context = self, .open = &open, .read = &read, .close = &close, .allocate = &allocate, .free = &free };
    }
    fn get(context: *anyopaque) *Model {
        return @ptrCast(@alignCast(context));
    }
    fn open(context: *anyopaque, filename: []const u8) !?File {
        const model = get(context);
        try std.testing.expectEqualStrings(path, filename);
        model.open_count += 1;
        if (model.missing) return null;
        return .{ .token = 7, .length = model.reported_length orelse model.source.len };
    }
    fn read(context: *anyopaque, _: File, output: []u8) !usize {
        const model = get(context);
        if (model.oversized_read) return output.len + 1;
        if (model.truncated) return 0;
        const count = @min(@min(output.len, model.chunk), model.source.len - model.position);
        @memcpy(output[0..count], model.source[model.position..][0..count]);
        model.position += count;
        return count;
    }
    fn close(context: *anyopaque, _: File) !void {
        const model = get(context);
        model.close_count += 1;
        if (model.close_failure) return error.ModelCloseFailure;
    }
    fn allocate(context: *anyopaque, size: usize) ![]align(4096) u8 {
        const model = get(context);
        model.allocations += 1;
        if (model.allocation_failure) return error.ModelAllocationFailure;
        return std.testing.allocator.alignedAlloc(u8, .fromByteUnits(4096), size);
    }
    fn free(context: *anyopaque, bytes: []align(4096) u8) !void {
        get(context).frees += 1;
        std.testing.allocator.free(bytes);
    }
};
test "complete archive transfers zero-padded retained pages after closing the file" {
    const fixture = Fixture.init();
    var model: Model = .{ .source = &fixture.bytes };
    const result = (try stageWithProvider(model.io(), .x86_64, std.math.maxInt(u64))).?;
    defer model.io().free(model.io().context, result.allocation) catch unreachable;
    try std.testing.expectEqual(@as(usize, 4096), result.allocation.len);
    try std.testing.expectEqual(@as(u64, 288), result.record.archive.length);
    try std.testing.expectEqual(@as(usize, 1), model.close_count);
    try std.testing.expectEqual(@as(usize, 0), model.frees);
    try std.testing.expect(std.mem.allEqual(u8, result.allocation[288..], 0));
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&fixture.bytes, &digest, .{});
    try std.testing.expectEqualSlices(u8, &digest, &result.record.sha256);
}
test "missing and invalid-sized archives allocate no pages" {
    const fixture = Fixture.init();
    var model: Model = .{ .source = &fixture.bytes, .missing = true };
    try std.testing.expect(try stageWithProvider(model.io(), .x86_64, std.math.maxInt(u64)) == null);
    try std.testing.expectEqual(@as(usize, 0), model.close_count);
    for ([_]u64{ 0, 63, bundles.max_archive_bytes + 1 }) |length| {
        model = .{ .source = &fixture.bytes, .reported_length = length };
        try std.testing.expectError(error.InvalidApplicationFileInfo, stageWithProvider(model.io(), .x86_64, std.math.maxInt(u64)));
        try std.testing.expectEqual(@as(usize, 0), model.allocations);
        try std.testing.expectEqual(@as(usize, 1), model.close_count);
    }
}
test "truncated corrupted oversized and close-failed reads reclaim staging pages" {
    var fixture = Fixture.init();
    var model: Model = .{ .source = &fixture.bytes, .truncated = true };
    try std.testing.expectError(error.TruncatedApplicationArchive, stageWithProvider(model.io(), .x86_64, std.math.maxInt(u64)));
    try std.testing.expectEqual(@as(usize, 1), model.frees);
    model = .{ .source = &fixture.bytes, .oversized_read = true };
    try std.testing.expectError(error.TruncatedApplicationArchive, stageWithProvider(model.io(), .x86_64, std.math.maxInt(u64)));
    try std.testing.expectEqual(@as(usize, 1), model.frees);
    model = .{ .source = &fixture.bytes, .close_failure = true };
    try std.testing.expectError(error.ModelCloseFailure, stageWithProvider(model.io(), .x86_64, std.math.maxInt(u64)));
    try std.testing.expectEqual(@as(usize, 1), model.frees);
    try std.testing.expectEqual(@as(usize, 1), model.close_count);
    fixture.bytes[fixture.bytes.len - 1] ^= 1;
    model = .{ .source = &fixture.bytes };
    try std.testing.expectError(error.FileHashMismatch, stageWithProvider(model.io(), .x86_64, std.math.maxInt(u64)));
    try std.testing.expectEqual(@as(usize, 1), model.frees);
}
test "architecture and address-limit rejection release the retained allocation" {
    const fixture = Fixture.init();
    var model: Model = .{ .source = &fixture.bytes };
    try std.testing.expectError(error.ArchitectureMismatch, stageWithProvider(model.io(), .aarch64, std.math.maxInt(u64)));
    try std.testing.expectEqual(@as(usize, 1), model.frees);
    model = .{ .source = &fixture.bytes };
    try std.testing.expectError(error.ApplicationOutsideAddressableRange, stageWithProvider(model.io(), .x86_64, 1));
    try std.testing.expectEqual(@as(usize, 1), model.frees);
}
test "allocator failure closes the file without freeing an unowned allocation" {
    const fixture = Fixture.init();
    var model: Model = .{ .source = &fixture.bytes, .allocation_failure = true };
    try std.testing.expectError(error.ModelAllocationFailure, stageWithProvider(model.io(), .x86_64, std.math.maxInt(u64)));
    try std.testing.expectEqual(@as(usize, 1), model.allocations);
    try std.testing.expectEqual(@as(usize, 1), model.close_count);
    try std.testing.expectEqual(@as(usize, 0), model.frees);
}
test "trailing bytes and hostile one-byte reads cannot retain staging pages" {
    const fixture = Fixture.init();
    var extended: [289]u8 = @splat(0);
    @memcpy(extended[0..288], &fixture.bytes);
    var model: Model = .{ .source = &extended, .reported_length = 288 };
    try std.testing.expectError(error.TrailingApplicationBytes, stageWithProvider(model.io(), .x86_64, std.math.maxInt(u64)));
    try std.testing.expectEqual(@as(usize, 1), model.frees);
    const hostile: [4097]u8 = @splat(0);
    model = .{ .source = &hostile, .chunk = 1 };
    try std.testing.expectError(error.ApplicationReadBudget, stageWithProvider(model.io(), .x86_64, std.math.maxInt(u64)));
    try std.testing.expectEqual(@as(usize, 1), model.frees);
    try std.testing.expectEqual(@as(usize, 1), model.close_count);
}
