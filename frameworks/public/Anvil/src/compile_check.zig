const anvil = @import("anvil");

export fn bedrock_anvil_probe(provider: *const anvil.Provider, token: u64) callconv(.c) bool {
    var queue = anvil.Queue.init(provider.*) catch return false;
    var storage: [2]anvil.Command = undefined;
    var batch = anvil.Batch.init(&storage) catch return false;
    batch.append(.{ .fill = .{
        .target = .{ .token = token },
        .rect = .{ .x = 0, .y = 0, .width = 1, .height = 1 },
        .color = 0x112233,
    } }) catch return false;
    batch.append(.{ .copy = .{
        .source = .{ .token = token },
        .target = .{ .token = token },
        .source_rect = .{ .x = 0, .y = 0, .width = 1, .height = 1 },
        .destination = .{ .x = 1, .y = 1 },
    } }) catch return false;
    const fence = queue.submit(1, batch.commands()) catch return false;
    batch.reset();
    return queue.isComplete(fence) catch false;
}
