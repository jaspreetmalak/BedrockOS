//! Optional MT7922 boot assets acquired while UEFI boot services are live.
//! Only the loaded image's filesystem is searched. Hashes identify the pinned
//! vendor blobs; neither them nor a board-file checksum proves RF calibration.
const std = @import("std");
const uefi = std.os.uefi;
const protocol = @import("boot_protocol");

pub const patch_path = "\\EFI\\Bedrock\\Firmware\\WIFI_MT7922_patch_mcu_1_1_hdr.bin";
pub const ram_path = "\\EFI\\Bedrock\\Firmware\\WIFI_RAM_CODE_MT7922_1.bin";
pub const profile_path = "\\EFI\\Bedrock\\Firmware\\MT7922.board";
pub const profile_capacity = 32768;
pub const seed_size = 64;
pub const patch_size = 137632;
pub const ram_size = 1231252;
pub const patch_sha256 = hexDigest("7fc9075d6d54b31e0539734614ca971fa52caf41b642a3000c8a4501591a4d98");
pub const ram_sha256 = hexDigest("d100e5e04c324fc8da6302112d1e0b4fac952286447d2419eabcd8fb0a1f5b93");

pub const FirmwareStatus = enum { absent, ready };
pub const ProfileStatus = enum { absent, invalid, ready };
pub const EntropyStatus = enum { unavailable, failed, ready };
pub const Outcome = struct {
    assets: ?Assets = null,
    firmware: FirmwareStatus = .absent,
    profile: ProfileStatus = .absent,
    entropy: EntropyStatus = .unavailable,
};

/// Borrowed retained allocation, consumed by the kernel after ExitBootServices.
/// The loader must release it only on a failure BEFORE the first exit attempt.
pub const Assets = struct {
    allocation: []align(4096) u8,
    patch: protocol.PhysicalRange,
    ram: protocol.PhysicalRange,
    profile: protocol.PhysicalRange = .{ .base = 0, .length = 0 },
    has_entropy: bool = false,

    /// Transfers directly to a disjoint caller-owned handoff, without a
    /// seed-bearing return value on the loader stack. Staging is erased once.
    /// The destination must not alias this asset allocation.
    pub fn publish(self: *Assets, destination: *protocol.WifiBoot) void {
        destination.* = .{
            .version = 1,
            .flags = 1 | (if (self.has_entropy) @as(u32, 2) else 0) | (if (self.profile.length != 0) @as(u32, 4) else 0),
            .reservation = .{ .base = @intFromPtr(self.allocation.ptr), .length = self.allocation.len },
            .patch = self.patch,
            .ram = self.ram,
            .profile = self.profile,
        };
        if (self.has_entropy) {
            @memcpy(&destination.seed, self.allocation[0..seed_size]);
            wipe(self.allocation[0..seed_size]);
            self.has_entropy = false;
        }
    }

    /// Convenience for native models. Production loaders use publish().
    pub fn handoff(self: *Assets) protocol.WifiBoot {
        var result: protocol.WifiBoot = undefined;
        self.publish(&result);
        return result;
    }

    pub fn release(self: *Assets, bs: *uefi.tables.BootServices) !void {
        // Also erase the temporary seed copy before returning its pages.
        wipe(self.allocation);
        const pages: [*]align(4096) uefi.Page = @ptrCast(self.allocation.ptr);
        try bs.freePages(pages[0 .. self.allocation.len / 4096]);
        self.* = undefined;
    }
};

pub const File = struct { token: usize, length: u64, directory: bool = false };
/// Provider operations are synchronous and may not retain any output slice.
/// allocate returns a distinct page-aligned allocation; free consumes it.
pub const Provider = struct {
    context: *anyopaque,
    open: *const fn (*anyopaque, []const u8) anyerror!?File,
    read: *const fn (*anyopaque, File, []u8) anyerror!usize,
    close: *const fn (*anyopaque, File) anyerror!void,
    allocate: *const fn (*anyopaque, usize) anyerror![]align(4096) u8,
    free: *const fn (*anyopaque, []align(4096) u8) anyerror!void,
    entropy: *const fn (*anyopaque, *[seed_size]u8) anyerror!bool,
    validate_profile: *const fn ([]const u8) anyerror!void,
};

const Catalog = struct { patch_length: usize, ram_length: usize, patch_hash: [32]u8, ram_hash: [32]u8 };
const pinned: Catalog = .{ .patch_length = patch_size, .ram_length = ram_size, .patch_hash = patch_sha256, .ram_hash = ram_sha256 };

/// Uses the production pinned lengths/hashes even with an injected provider.
pub fn stageWithProvider(io: Provider, address_limit: u64) !Outcome {
    return stageCatalog(io, address_limit, pinned);
}

fn stageCatalog(io: Provider, address_limit: u64, catalog: Catalog) !Outcome {
    var patch = try io.open(io.context, patch_path);
    defer if (patch) |file| io.close(io.context, file) catch {};
    var ram = try io.open(io.context, ram_path);
    defer if (ram) |file| io.close(io.context, file) catch {};
    if (patch == null and ram == null) return .{};
    if (patch == null or ram == null) return error.PartialFirmwareAssets;
    if (patch.?.directory or ram.?.directory) return error.AssetIsDirectory;
    if (patch.?.length != catalog.patch_length or ram.?.length != catalog.ram_length)
        return error.FirmwareLengthMismatch;
    const patch_offset = 4096;
    const ram_offset = try alignPage(try add(patch_offset, catalog.patch_length));
    const profile_offset = try alignPage(try add(ram_offset, catalog.ram_length));
    const capacity = try alignPage(try add(profile_offset, profile_capacity));
    const allocation = try io.allocate(io.context, capacity);
    errdefer {
        wipe(allocation);
        io.free(io.context, allocation) catch {};
    }
    if (allocation.len != capacity or @intFromPtr(allocation.ptr) == 0) return error.InvalidAssetAllocation;
    const range: protocol.PhysicalRange = .{ .base = @intFromPtr(allocation.ptr), .length = allocation.len };
    if (try range.endExclusive() > address_limit) return error.AssetOutsideAddressableRange;
    @memset(allocation, 0);
    const patch_bytes = allocation[patch_offset .. patch_offset + catalog.patch_length];
    const ram_bytes = allocation[ram_offset .. ram_offset + catalog.ram_length];
    try readExactly(io, patch.?, patch_bytes);
    try readExactly(io, ram.?, ram_bytes);
    try verifyHash(patch_bytes, catalog.patch_hash);
    try verifyHash(ram_bytes, catalog.ram_hash);
    const patch_file = patch.?;
    patch = null;
    try io.close(io.context, patch_file);
    const ram_file = ram.?;
    ram = null;
    try io.close(io.context, ram_file);
    var result: Outcome = .{ .firmware = .ready, .assets = .{
        .allocation = allocation,
        .patch = .{ .base = range.base + patch_offset, .length = patch_bytes.len },
        .ram = .{ .base = range.base + ram_offset, .length = ram_bytes.len },
    } };
    loadProfile(io, allocation[profile_offset .. profile_offset + profile_capacity], &result) catch {
        wipe(allocation[profile_offset .. profile_offset + profile_capacity]);
        result.profile = .invalid;
        result.assets.?.profile = .{ .base = 0, .length = 0 };
    };
    const seed: *[seed_size]u8 = @ptrCast(allocation.ptr);
    const generated = io.entropy(io.context, seed) catch {
        wipe(seed);
        result.entropy = .failed;
        return result;
    };
    if (generated and !std.mem.allEqual(u8, seed, 0)) {
        result.entropy = .ready;
        result.assets.?.has_entropy = true;
    } else {
        wipe(seed);
        if (generated) result.entropy = .failed;
    }
    return result;
}

fn loadProfile(io: Provider, output: []u8, result: *Outcome) !void {
    const file = (try io.open(io.context, profile_path)) orelse return;
    var open = true;
    defer if (open) io.close(io.context, file) catch {};
    if (file.directory or file.length == 0 or file.length > output.len) return error.InvalidBoardProfile;
    const bytes = output[0..@intCast(file.length)];
    try readExactly(io, file, bytes);
    try io.validate_profile(bytes);
    open = false;
    try io.close(io.context, file);
    result.profile = .ready;
    result.assets.?.profile = .{ .base = @intFromPtr(bytes.ptr), .length = bytes.len };
}

/// Native model tests use small independent bytes; this helper is unavailable
/// in production builds and cannot relax the production firmware hash policy.
pub const testing = if (@import("builtin").is_test) struct {
    pub fn stage(io: Provider, limit: u64, patch: []const u8, ram: []const u8) !Outcome {
        var catalog: Catalog = .{ .patch_length = patch.len, .ram_length = ram.len, .patch_hash = undefined, .ram_hash = undefined };
        std.crypto.hash.sha2.Sha256.hash(patch, &catalog.patch_hash, .{});
        std.crypto.hash.sha2.Sha256.hash(ram, &catalog.ram_hash, .{});
        return stageCatalog(io, limit, catalog);
    }
} else struct {};

fn readExactly(io: Provider, file: File, output: []u8) !void {
    var used: usize = 0;
    var calls: usize = 0;
    while (used < output.len) {
        calls += 1;
        if (calls > 4096) return error.ReadBudgetExceeded;
        const count = try io.read(io.context, file, output[used..]);
        if (count > output.len - used) return error.InvalidReadCount;
        if (count == 0) return error.TruncatedAsset;
        used += count;
    }
    // Detect a changing or inconsistent size instead of accepting a prefix.
    var trailing: [1]u8 = undefined;
    if (try io.read(io.context, file, &trailing) != 0) return error.TrailingAssetBytes;
}

fn add(a: usize, b: usize) !usize {
    const sum = @addWithOverflow(a, b);
    if (sum[1] != 0) return error.AssetSizeOverflow;
    return sum[0];
}
fn alignPage(value: usize) !usize {
    return (try add(value, 4095)) & ~@as(usize, 4095);
}
fn verifyHash(bytes: []const u8, expected: [32]u8) !void {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    if (!std.mem.eql(u8, &digest, &expected)) return error.FirmwareHashMismatch;
}
fn hexDigest(comptime text: *const [64]u8) [32]u8 {
    @setEvalBranchQuota(10000);
    var result: [32]u8 = undefined;
    for (0..32) |index| result[index] = std.fmt.parseInt(u8, text[index * 2 ..][0..2], 16) catch unreachable;
    return result;
}
fn wide(comptime path: []const u8) [path.len:0]u16 {
    var result: [path.len:0]u16 = undefined;
    for (path, 0..) |byte, index| result[index] = byte;
    result[path.len] = 0;
    return result;
}
pub fn wipe(bytes: []u8) void {
    for (bytes) |*byte| @as(*volatile u8, @ptrCast(byte)).* = 0;
}

const UefiContext = struct {
    bs: *uefi.tables.BootServices,
    root: *uefi.protocol.File,

    fn open(context: *anyopaque, path: []const u8) !?File {
        const self: *UefiContext = @ptrCast(@alignCast(context));
        const patch_name = comptime wide(patch_path);
        const ram_name = comptime wide(ram_path);
        const profile_name = comptime wide(profile_path);
        const name: [*:0]const u16 = if (std.mem.eql(u8, path, patch_path)) &patch_name else if (std.mem.eql(u8, path, ram_path)) &ram_name else if (std.mem.eql(u8, path, profile_path)) &profile_name else return error.InvalidAssetPath;
        const file = self.root.open(name, .read, .{}) catch |err| switch (err) {
            error.NotFound => return null,
            else => return err,
        };
        errdefer file.close() catch {};
        // EFI_FILE_INFO has a variable filename tail. Bound both firmware's
        // returned byte count and declared record size before reading fields.
        var info_bytes: [512]u8 align(8) = undefined;
        var count: usize = info_bytes.len;
        const status = file._get_info(file, &uefi.protocol.File.Info.File.guid, &count, &info_bytes);
        if (status != .success) return error.AssetFileInfoUnavailable;
        if (count < @sizeOf(uefi.protocol.File.Info.File) or count > info_bytes.len) return error.InvalidAssetFileInfo;
        const info: *const uefi.protocol.File.Info.File = @ptrCast(&info_bytes);
        if (info.size < @sizeOf(uefi.protocol.File.Info.File) or info.size > count) return error.InvalidAssetFileInfo;
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
    fn allocate(context: *anyopaque, capacity: usize) ![]align(4096) u8 {
        const self: *UefiContext = @ptrCast(@alignCast(context));
        const pages = try self.bs.allocatePages(.any, .loader_data, capacity / 4096);
        const bytes: [*]align(4096) u8 = @ptrCast(pages.ptr);
        return bytes[0..capacity];
    }
    fn free(context: *anyopaque, bytes: []align(4096) u8) !void {
        const self: *UefiContext = @ptrCast(@alignCast(context));
        const pages: [*]align(4096) uefi.Page = @ptrCast(bytes.ptr);
        try self.bs.freePages(pages[0 .. bytes.len / 4096]);
    }
    fn entropy(context: *anyopaque, seed: *[seed_size]u8) !bool {
        const self: *UefiContext = @ptrCast(@alignCast(context));
        const rng = (try self.bs.locateProtocol(uefi.protocol.Rng, null)) orelse return false;
        // UEFI's default algorithm is requested, once, with no clock/CPUID/
        // deterministic fallback. EDK2 Guid/Rng.h defines this null-GUID ABI.
        try rng.getRNG(null, seed);
        return true;
    }
};

/// Must be called and all file handles closed before final GetMemoryMap/Exit.
pub fn stage(bs: *uefi.tables.BootServices, image: uefi.Handle, address_limit: u64) !Outcome {
    const loaded = (try bs.openProtocol(uefi.protocol.LoadedImage, image, .{ .by_handle_protocol = .{ .agent = image } })) orelse return error.LoadedImageUnavailable;
    const device = loaded.device_handle orelse return error.LoadedImageDeviceUnavailable;
    const filesystem = (try bs.openProtocol(uefi.protocol.SimpleFileSystem, device, .{ .by_handle_protocol = .{ .agent = image } })) orelse return error.LoadedImageFilesystemUnavailable;
    const root = try filesystem.openVolume();
    var root_open = true;
    defer if (root_open) root.close() catch {};
    var context: UefiContext = .{ .bs = bs, .root = root };
    var result = try stageWithProvider(.{
        .context = &context,
        .open = UefiContext.open,
        .read = UefiContext.read,
        .close = UefiContext.close,
        .allocate = UefiContext.allocate,
        .free = UefiContext.free,
        .entropy = UefiContext.entropy,
        .validate_profile = @import("mt7922_board").validate,
    }, address_limit);
    errdefer if (result.assets) |*assets| assets.release(bs) catch {};
    root_open = false;
    try root.close();
    return result;
}

test {
    _ = @import("wifi_assets_tests.zig");
}
