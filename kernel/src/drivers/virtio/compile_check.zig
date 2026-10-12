//! Compile-only probe; never execute against caller-created fake transports.
const virtio = @import("root.zig");
const protocol = @import("boot_protocol");
export fn bedrock_virtio_compile_probe(info: *const protocol.BootInfo, storage: *virtio.Block, input: *virtio.Input) callconv(.c) u64 {
    const devices = virtio.discover(info) catch return 0;
    if (devices.count != 0) {
        switch (devices.items[0].device_id) {
            2 => storage.* = virtio.Block.init(devices.items[0]) catch return 0,
            18 => input.* = virtio.Input.init(devices.items[0]) catch return 0,
            else => {},
        }
    }
    var sector: [512]u8 = undefined;
    storage.read(0, &sector) catch return 0;
    storage.write(0, &sector) catch return 0;
    storage.readBlocks(0, &sector) catch return 0;
    storage.writeBlocks(0, &sector) catch return 0;
    storage.flush() catch return 0;
    _ = storage.getId() catch return 0;
    _ = input.poll() catch return 0;
    var decoder = virtio.Decoder.init(800, 600) catch return 0;
    decoder.feed(.{ .event_type = 0, .code = 0, .value = 0 }, input.abs_x, input.abs_y) catch return 0;
    _ = decoder.pop();
    storage.deinit() catch return 0;
    input.deinit() catch return 0;
    return devices.count;
}

export fn bedrock_virtio_net_compile_probe(info: *const protocol.BootInfo, network: *virtio.Net) callconv(.c) u64 {
    const devices = virtio.discover(info) catch return 0;
    for (devices.items[0..devices.count]) |device| {
        if (device.device_id != virtio.transport.net_id) continue;
        network.* = virtio.Net.init(device) catch return 0;
        var frame: [1514]u8 = @splat(0);
        network.send(&frame) catch return 0;
        const received = network.receive(&frame) catch return 0;
        _ = network.linkUp() catch return 0;
        const result = (received orelse 0) + network.mac[0];
        network.deinit() catch return 0;
        return result;
    }
    return 0;
}
