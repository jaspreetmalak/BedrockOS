//! Device discovery and the retained, disk-backed namespace. Raw disk access
//! stays in the kernel; VFS callers must supply their trusted app profile.
const std = @import("std");
const protocol = @import("boot_protocol");
const filesystem = @import("filesystem");
const virtio = @import("virtio");
const vfs = @import("vfs.zig");
pub var storage: vfs.Vfs(filesystem.durable.DurableFs(32, 4096, 128)) = .{};
var disk: ?virtio.Block = null;
var data_partition: ?filesystem.partition.Partition = null;
// The mount retains this view's address. Partition requests cannot access the
// ESP, GPT metadata or any other partition on the same underlying disk.
var data_view: ?filesystem.partition.View = null;
pub var inputs: [4]virtio.Input = undefined;
pub var input_count: usize = 0;
var initialized = false;

pub fn initialize(comptime console: type, info: *const protocol.BootInfo) !void {
    return initializeWithInput(console, info, false);
}
pub fn initializeWithInput(comptime console: type, info: *const protocol.BootInfo, force_input: bool) !void {
    if (initialized) return error.StorageAlreadyInitialized;
    const desktop = force_input or (info.console.kind == @backingInt(protocol.ConsoleKind.framebuffer) and
        (info.flags & protocol.flag_smoke_exit) == 0);
    const devices = try virtio.discover(info);
    errdefer {
        if (disk) |*retained| retained.deinit() catch {};
        disk = null;
        data_partition = null;
        data_view = null;
        while (input_count != 0) {
            input_count -= 1;
            inputs[input_count].deinit() catch {};
        }
    }
    for (devices.items[0..devices.count]) |device| {
        if (device.device_id == 2) {
            var candidate = try virtio.Block.init(device);
            var candidate_owned = true;
            errdefer if (candidate_owned) candidate.deinit() catch {};
            const id = try candidate.getId();
            const raw_data = std.mem.startsWith(u8, &id, "bedrock-data") and id[12] == 0;
            const partition = if (raw_data) null else try filesystem.partition.parseBedrockData(blockDevice(&candidate));
            if (!raw_data and partition == null) {
                try candidate.deinit();
                candidate_owned = false;
                continue;
            }
            if (disk != null) return error.DuplicateDataDevice;
            disk = candidate;
            data_partition = partition;
            candidate_owned = false;
        } else if (device.device_id == 18 and desktop) {
            if (input_count == inputs.len) return error.TooManyInputDevices;
            inputs[input_count] = try virtio.Input.init(device);
            input_count += 1;
        }
    }
    if (disk == null) return error.MissingBedrockDataDevice;
    if (desktop and input_count < 2) return error.MissingDesktopInput;
    const device = blockDevice(&disk.?);
    if (data_partition) |partition| {
        data_view = try filesystem.partition.View.init(device, partition);
        try storage.mount(data_view.?.device());
        console.write("[kernel] Bedrock data GPT partition mounted\n");
    } else {
        try storage.mount(device);
    }
    initialized = true;
    console.write("[kernel] persistent filesystem mounted\n");
}
fn blockDevice(block: *virtio.Block) filesystem.BlockDevice {
    return .{ .context = block, .block_size = 512, .block_count = block.sector_count, .read_fn = &readBlocks, .write_fn = &writeBlocks, .flush_fn = &flush };
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
