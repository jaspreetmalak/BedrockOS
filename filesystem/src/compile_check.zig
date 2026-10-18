const filesystem = @import("filesystem");

fn readBlock(context: *anyopaque, start_block: u64, block_count: u64, buffer: []u8) filesystem.ReadError!void {
    _ = context;
    if (start_block != 0 or block_count != 1 or buffer.len != 4) return error.InvalidProbeRead;
    @memset(buffer, 0x42);
}

/// Forces freestanding cross-builds to compile the actual read and bounds path.
export fn bedrock_filesystem_compile_probe() u32 {
    var context: u8 = 0;
    var buffer: [4]u8 = undefined;
    const device: filesystem.BlockDevice = .{
        .context = &context,
        .read_fn = readBlock,
        .block_size = 4,
        .block_count = 1,
    };
    device.read(0, &buffer) catch return 1;
    device.read(1, &buffer) catch |err| {
        return if (err == error.OutOfBounds and buffer[0] == 0x42) bedrock_ramfs_compile_probe() else 2;
    };
    return 3;
}

/// Exercise actual namespace, mutable bytes, borrowed bytes and epoch paths.
export fn bedrock_ramfs_compile_probe() u32 {
    var fs: filesystem.ramfs.RamFs(4, 16, 24) = .{};
    fs.reset() catch return 10;
    const directory = fs.mkdir("/d", .{ .domain = .container, .owner = 7 }) catch return 11;
    const file = fs.create("/d/f", .{ .domain = .container, .owner = 7 }) catch return 12;
    _ = fs.write(file, 3, "ok") catch return 13;
    var output: [5]u8 = undefined;
    if ((fs.read(file, 0, &output) catch return 14) != 5 or output[0] != 0 or output[3] != 'o') return 15;
    fs.truncate(file, 2) catch return 16;
    fs.truncate(file, 5) catch return 17;
    const bytes = fs.contents(file) catch return 18;
    if (bytes[3] != 0 or (fs.size(file) catch return 19) != 5) return 20;
    const borrowed = fs.addBorrowed("/d/elf", .{ .domain = .bundle, .owner = 7, .executable = true }, "ELF") catch return 21;
    const info = fs.stat(borrowed) catch return 22;
    if (info.kind != .borrowed_file or !info.metadata.executable or (fs.lookup("/d/elf") catch return 23) != borrowed)
        return 24;
    if ((fs.path(borrowed) catch return 25).len != 6) return 26;
    var cursor: usize = 0;
    if ((fs.enumerate(directory, &cursor) catch return 27).?.id != file) return 28;
    if ((fs.enumerate(directory, &cursor) catch return 29).?.id != borrowed) return 30;
    if ((fs.enumerate(directory, &cursor) catch return 31) != null) return 32;
    fs.nullify("/d/f") catch return 36;
    fs.reset() catch return 33;
    _ = fs.stat(file) catch |err| return if (err == error.StaleNode) 0 else 34;
    return 35;
}

/// Compile the durable transactions and recovery parser for every ISA. The
/// caller owns the device; this function is never a boot-time format operation.
export fn bedrock_durable_compile_probe(device: *const filesystem.BlockDevice) u32 {
    var fs: filesystem.durable.DurableFs(12, 64, 96) = .{};
    fs.mount(device.*) catch return 40;
    const metadata: filesystem.ramfs.Metadata = .{ .domain = .container, .owner = 1 };
    _ = fs.mkdir("/probe", metadata) catch return 41;
    const file = fs.create("/probe/file", metadata) catch return 42;
    _ = fs.write(file, 0, "data") catch return 43;
    fs.truncate(file, 8) catch return 44;
    _ = fs.copy("/probe/file", "/probe/copied", metadata) catch return 45;
    fs.rename("/probe/copied", "/probe/moved") catch return 46;
    var cursor: usize = 0;
    _ = fs.enumerate(fs.lookup("/probe") catch return 47, &cursor) catch return 48;
    fs.unlink("/probe/moved") catch return 49;
    var output: [8]u8 = undefined;
    if ((fs.read(file, 0, &output) catch return 50) != 8 or output[0] != 'd') return 51;
    fs.nullify("/probe/file") catch return 52;
    return 0;
}

/// Compile GPT metadata checks and bounded forwarding for every target.
export fn bedrock_partition_compile_probe(parent: *const filesystem.BlockDevice) u32 {
    const partition = (filesystem.partition.parseBedrockData(parent.*) catch return 60) orelse return 61;
    var view = filesystem.partition.View.init(parent.*, partition) catch return 62;
    const device = view.device();
    var bytes: [512]u8 = undefined;
    device.read(0, &bytes) catch return 63;
    device.read(device.block_count, &bytes) catch |err| return if (err == error.OutOfBounds) 0 else 64;
    return 65;
}
