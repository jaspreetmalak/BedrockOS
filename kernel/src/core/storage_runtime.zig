//! Device discovery and the retained, disk-backed namespace. Raw disk access
//! stays in the kernel; VFS callers must supply their trusted app profile.
const std = @import("std");
const protocol = @import("boot_protocol");
const filesystem = @import("filesystem");
const virtio = @import("virtio");
const vfs = @import("vfs.zig");
pub var storage: vfs.Vfs(filesystem.durable.DurableFs(32, 4096, 128)) = .{};
var disk: ?virtio.Block = null;
pub var inputs: [4]virtio.Input = undefined;
pub var input_count: usize = 0;
var initialized = false;

pub fn initialize(comptime console: type, info: *const protocol.BootInfo) !void {
    if (initialized) return error.StorageAlreadyInitialized;
    const desktop = info.console.kind == @backingInt(protocol.ConsoleKind.framebuffer) and
        (info.flags & protocol.flag_smoke_exit) == 0;
    const devices = try virtio.discover(info);
    for (devices.items[0..devices.count]) |device| {
        if (device.device_id == 2) {
            var candidate = try virtio.Block.init(device);
            const id = candidate.getId() catch |err| {
                try candidate.deinit();
                return err;
            };
            if (!std.mem.startsWith(u8, &id, "bedrock-data") or id[12] != 0) {
                try candidate.deinit();
                continue;
            }
            if (disk != null) {
                try candidate.deinit();
                return error.DuplicateDataDevice;
            }
            disk = candidate;
        } else if (device.device_id == 18 and desktop) {
            if (input_count == inputs.len) return error.TooManyInputDevices;
            inputs[input_count] = try virtio.Input.init(device);
            input_count += 1;
        }
    }
    if (disk == null) return error.MissingBedrockDataDevice;
    const device: filesystem.BlockDevice = .{ .context = &disk.?, .block_size = 512, .block_count = disk.?.sector_count, .read_fn = &readBlocks, .write_fn = &writeBlocks, .flush_fn = &flush };
    try storage.mount(device);
    initialized = true;
    console.write("[kernel] persistent filesystem mounted\n");
    if (desktop and input_count < 2) return error.MissingDesktopInput;
}
fn readBlocks(context: *anyopaque, start: u64, _: u64, output: []u8) !void {
    const block: *virtio.Block = @ptrCast(@alignCast(context));
    try block.readBlocks(start, output);
}
fn writeBlocks(context: *anyopaque, start: u64, _: u64, input: []const u8) !void {
    const block: *virtio.Block = @ptrCast(@alignCast(context));
    try block.writeBlocks(start, input);
}
fn flush(context: *anyopaque) !void {
    const block: *virtio.Block = @ptrCast(@alignCast(context));
    try block.flush();
}
