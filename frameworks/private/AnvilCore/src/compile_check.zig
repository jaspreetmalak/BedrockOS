const core = @import("anvil_core");

export fn bedrock_anvil_software_probe() callconv(.c) u64 {
    var pixels: [16]u32 = @splat(0);
    var device: core.Software(2) = .{};
    const texture = device.importImage(.{ .pixels = &pixels, .width = 4, .height = 4, .stride = 4, .format = .xrgb8888 }) catch return 0;
    var queue = core.anvil.Queue.init(device.provider()) catch return 0;
    const fence = queue.submit(1, &.{.{ .fill = .{ .target = texture, .rect = .{ .x = 0, .y = 0, .width = 4, .height = 4 }, .color = 0x123456 } }}) catch return 0;
    if (!(queue.isComplete(fence) catch return 0)) return 0;
    _ = queue.submit(2, &.{.{ .copy = .{ .source = texture, .target = texture, .source_rect = .{ .x = 0, .y = 0, .width = 3, .height = 3 }, .destination = .{ .x = 1, .y = 1 } } }}) catch return 0;
    device.release(texture) catch return 0;
    return (queue.completed() catch return 0).sequence;
}
