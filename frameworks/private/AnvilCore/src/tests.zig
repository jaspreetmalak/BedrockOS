const std = @import("std");
const core = @import("root.zig");
const anvil = core.anvil;
const t = std.testing;

fn image(pixels: []volatile u32, width: u32, height: u32, stride: u32, format: anvil.Format) core.Image {
    return .{ .pixels = pixels, .width = width, .height = height, .stride = stride, .format = format };
}

fn fill(texture: anvil.Texture, rect: anvil.Rect, color: u32) anvil.Command {
    return .{ .fill = .{ .target = texture, .rect = rect, .color = color } };
}

test "software capability report and fence completion follow actual writes" {
    var pixels: [6]u32 = @splat(0xeeeeeeee);
    var device: core.Software(2) = .{};
    const texture = try device.importImage(image(&pixels, 3, 2, 3, .xrgb8888));
    var queue = try anvil.Queue.init(device.provider());
    try t.expectEqualStrings("Anvil CPU 2D", queue.device.name);
    try t.expectEqual(anvil.Acceleration.software, queue.device.acceleration);
    try t.expect(queue.device.capabilities.fill and queue.device.capabilities.copy);
    try t.expect(queue.device.formats.xrgb8888 and queue.device.formats.xbgr8888);
    try t.expectEqual(@as(u64, 0), (try queue.completed()).sequence);
    const fence = try queue.submit(7, &.{fill(texture, .{ .x = 1, .y = 0, .width = 2, .height = 2 }, 0xabcdef)});
    try t.expectEqual(@as(u64, 7), fence.sequence);
    try t.expect(try queue.isComplete(fence));
    try t.expectEqualSlices(u32, &.{ 0xeeeeeeee, 0xabcdef, 0xabcdef, 0xeeeeeeee, 0xabcdef, 0xabcdef }, &pixels);
    try t.expectEqual(@as(u64, 7), device.last_submitted);
    try t.expectEqual(@as(u64, 7), device.last_completed);
}

test "invalid tail leaves earlier valid writes and fences untouched" {
    var pixels: [12]u32 = @splat(0x12345678);
    const before = pixels;
    var device: core.Software(2) = .{};
    const texture = try device.importImage(image(&pixels, 4, 3, 4, .xrgb8888));
    const provider = device.provider();
    const valid = fill(texture, .{ .x = 0, .y = 0, .width = 4, .height = 3 }, 0x102030);
    const invalids: []const anvil.Command = &.{
        fill(.{ .token = 0x123456789 }, .{ .x = 0, .y = 0, .width = 1, .height = 1 }, 0),
        fill(texture, .{ .x = 3, .y = 0, .width = 2, .height = 1 }, 0),
        fill(texture, .{ .x = 0, .y = 0, .width = 1, .height = 1 }, 0xff000000),
        .{ .copy = .{ .source = texture, .target = texture, .source_rect = .{ .x = 0, .y = 2, .width = 2, .height = 2 }, .destination = .{ .x = 0, .y = 0 } } },
        .{ .copy = .{ .source = texture, .target = texture, .source_rect = .{ .x = 0, .y = 0, .width = 1, .height = 1 }, .destination = .{ .x = std.math.maxInt(u32), .y = 0 } } },
    };
    for (invalids) |invalid| {
        const commands: [2]anvil.Command = .{ valid, invalid };
        if (provider.submit(provider.context, 1, &commands)) |_| return error.InvalidBatchAccepted else |_| {}
        try t.expectEqualSlices(u32, &before, &pixels);
        try t.expectEqual(@as(u64, 0), (try provider.completed(provider.context)).sequence);
        try t.expectEqual(@as(u64, 0), device.last_submitted);
    }
    _ = try provider.submit(provider.context, 1, &.{valid});
    try t.expectEqual(@as(u32, 0x102030), pixels[0]);
}

test "pixel format conversion respects source margins, row stride and guards" {
    var source: [20]u32 = @splat(0x778899aa);
    source[6] = 0xff123456;
    source[7] = 0xeeabcdef;
    source[11] = 0xdd010203;
    source[12] = 0xcc102030;
    var target: [26]u32 = @splat(0xfeedbeef);
    const source_before = source;
    var device: core.Software(2) = .{};
    const src = try device.importImage(image(source[1..19], 4, 3, 5, .xrgb8888));
    const dst = try device.importImage(image(target[1..25], 5, 4, 6, .xbgr8888));
    const provider = device.provider();
    _ = try provider.submit(provider.context, 1, &.{.{ .copy = .{
        .source = src,
        .target = dst,
        .source_rect = .{ .x = 0, .y = 1, .width = 2, .height = 2 },
        .destination = .{ .x = 2, .y = 1 },
    } }});
    var expected: [26]u32 = @splat(0xfeedbeef);
    expected[9] = 0x563412;
    expected[10] = 0xefcdab;
    expected[15] = 0x030201;
    expected[16] = 0x302010;
    try t.expectEqualSlices(u32, &expected, &target);
    try t.expectEqualSlices(u32, &source_before, &source);
    _ = try provider.submit(provider.context, 2, &.{fill(dst, .{ .x = 0, .y = 0, .width = 1, .height = 1 }, 0xabcdef)});
    try t.expectEqual(@as(u32, 0xefcdab), target[1]);
}

test "both cross-format directions and same-format copies clear reserved bits" {
    const formats: []const anvil.Format = &.{ .xrgb8888, .xbgr8888 };
    for (formats) |source_format| for (formats) |target_format| {
        var source: [1]u32 = .{0xff112233};
        var target: [1]u32 = .{0xffffffff};
        var device: core.Software(2) = .{};
        const src = try device.importImage(image(&source, 1, 1, 1, source_format));
        const dst = try device.importImage(image(&target, 1, 1, 1, target_format));
        const provider = device.provider();
        _ = try provider.submit(provider.context, 1, &.{.{ .copy = .{ .source = src, .target = dst, .source_rect = .{ .x = 0, .y = 0, .width = 1, .height = 1 }, .destination = .{ .x = 0, .y = 0 } } }});
        try t.expectEqual(@as(u32, if (source_format == target_format) 0x112233 else 0x332211), target[0]);
    };
}

test "overlapping same-texture copies have memmove semantics in every direction" {
    const moves = [_]struct { source: anvil.Rect, destination: anvil.Point }{
        .{ .source = .{ .x = 0, .y = 0, .width = 5, .height = 4 }, .destination = .{ .x = 1, .y = 1 } },
        .{ .source = .{ .x = 1, .y = 1, .width = 5, .height = 4 }, .destination = .{ .x = 0, .y = 0 } },
        .{ .source = .{ .x = 0, .y = 0, .width = 5, .height = 5 }, .destination = .{ .x = 1, .y = 0 } },
        .{ .source = .{ .x = 1, .y = 0, .width = 5, .height = 5 }, .destination = .{ .x = 0, .y = 0 } },
        .{ .source = .{ .x = 0, .y = 0, .width = 6, .height = 4 }, .destination = .{ .x = 0, .y = 1 } },
        .{ .source = .{ .x = 0, .y = 1, .width = 6, .height = 4 }, .destination = .{ .x = 0, .y = 0 } },
        .{ .source = .{ .x = 0, .y = 0, .width = 6, .height = 5 }, .destination = .{ .x = 0, .y = 0 } },
    };
    for (moves) |move| {
        var pixels: [42]u32 = undefined;
        for (&pixels, 0..) |*pixel, index| pixel.* = 0xff000000 | @as(u32, @intCast(index));
        const before = pixels;
        var expected = pixels;
        for (0..move.source.height) |row| for (0..move.source.width) |column| {
            expected[1 + (@as(usize, move.destination.y) + row) * 8 + move.destination.x + column] =
                before[1 + (@as(usize, move.source.y) + row) * 8 + move.source.x + column] & 0x00ffffff;
        };
        var device: core.Software(1) = .{};
        const texture = try device.importImage(image(pixels[1..41], 6, 5, 8, .xrgb8888));
        const provider = device.provider();
        _ = try provider.submit(provider.context, 1, &.{.{ .copy = .{ .source = texture, .target = texture, .source_rect = move.source, .destination = move.destination } }});
        try t.expectEqualSlices(u32, &expected, &pixels);
    }
}

test "commands execute in order with later reads observing earlier writes" {
    var pixels: [4]u32 = @splat(0);
    var device: core.Software(1) = .{};
    const texture = try device.importImage(image(&pixels, 4, 1, 4, .xrgb8888));
    const provider = device.provider();
    _ = try provider.submit(provider.context, 1, &.{
        fill(texture, .{ .x = 0, .y = 0, .width = 2, .height = 1 }, 0x112233),
        .{ .copy = .{ .source = texture, .target = texture, .source_rect = .{ .x = 0, .y = 0, .width = 2, .height = 1 }, .destination = .{ .x = 2, .y = 0 } } },
    });
    try t.expectEqualSlices(u32, &.{ 0x112233, 0x112233, 0x112233, 0x112233 }, &pixels);
}

test "read-only images may be sources but no invalid tail may write them" {
    var source: [4]u32 = .{ 1, 2, 3, 4 };
    var target: [4]u32 = @splat(0);
    var device: core.Software(2) = .{};
    var readonly = image(&source, 2, 2, 2, .xrgb8888);
    readonly.access = .read_only;
    const src = try device.importImage(readonly);
    const dst = try device.importImage(image(&target, 2, 2, 2, .xrgb8888));
    const provider = device.provider();
    const copy: anvil.Command = .{ .copy = .{ .source = src, .target = dst, .source_rect = .{ .x = 0, .y = 0, .width = 2, .height = 2 }, .destination = .{ .x = 0, .y = 0 } } };
    try t.expectError(error.ReadOnlyTexture, provider.submit(provider.context, 1, &.{ copy, fill(src, .{ .x = 0, .y = 0, .width = 1, .height = 1 }, 0) }));
    try t.expectEqualSlices(u32, &.{ 0, 0, 0, 0 }, &target);
    var reversed = copy.copy;
    reversed.target = src;
    try t.expectError(error.ReadOnlyTexture, provider.submit(provider.context, 1, &.{.{ .copy = reversed }}));
    _ = try provider.submit(provider.context, 1, &.{copy});
    try t.expectEqualSlices(u32, &source, &target);
    try t.expectEqualSlices(u32, &.{ 1, 2, 3, 4 }, &source);
}

test "handles are device-local even across different generic capacities" {
    var first_pixels: [4]u32 = @splat(0);
    var second_pixels: [4]u32 = @splat(0);
    var first: core.Software(2) = .{};
    var second: core.Software(8) = .{};
    const a = try first.importImage(image(&first_pixels, 2, 2, 2, .xrgb8888));
    const b = try second.importImage(image(&second_pixels, 2, 2, 2, .xrgb8888));
    try t.expect(a.token != b.token);
    try t.expectError(error.InvalidTexture, second.release(a));
    const provider = second.provider();
    try t.expectError(error.InvalidTexture, provider.submit(provider.context, 1, &.{fill(a, .{ .x = 0, .y = 0, .width = 1, .height = 1 }, 0)}));
    try first.release(a);
    const next = try first.importImage(image(&first_pixels, 2, 2, 2, .xrgb8888));
    try t.expect(a.token != next.token);
    try t.expectError(error.InvalidTexture, first.release(a));
    try first.release(next);
    try t.expectError(error.InvalidTexture, first.release(next));
}

test "generation exhaustion retires a slot instead of wrapping to stale handles" {
    var pixels: [1]u32 = .{0};
    var device: core.Software(1) = .{};
    const original = try device.importImage(image(&pixels, 1, 1, 1, .xrgb8888));
    device.slots[0].generation = std.math.maxInt(u32);
    const final: anvil.Texture = .{ .token = (original.token & 0xffffffff00000000) | std.math.maxInt(u32) };
    try device.release(final);
    try t.expect(device.slots[0].retired);
    try t.expectError(error.TextureCapacity, device.importImage(image(&pixels, 1, 1, 1, .xrgb8888)));
    try t.expectError(error.InvalidTexture, device.release(original));
}

test "image registration validates full spans and rejects overlapping handles" {
    var pixels: [32]u32 = @splat(0);
    var device: core.Software(2) = .{};
    try t.expectError(error.EmptyExtent, device.importImage(image(&pixels, 0, 1, 1, .xrgb8888)));
    try t.expectError(error.InvalidStride, device.importImage(image(&pixels, 3, 2, 2, .xrgb8888)));
    try t.expectError(error.BufferTooSmall, device.importImage(image(pixels[0..5], 3, 2, 3, .xrgb8888)));
    try t.expectError(error.OutOfBounds, device.importImage(image(&pixels, 16385, 1, 16385, .xrgb8888)));
    const overflow: [*]volatile u32 = @ptrFromInt(std.math.maxInt(usize) - 3);
    try t.expectError(error.Overflow, device.importImage(image(overflow[0..1], 1, 1, 1, .xrgb8888)));
    const long: [*]volatile u32 = @ptrFromInt(4);
    try t.expectError(error.Overflow, device.importImage(image(long[0 .. std.math.maxInt(usize) / 4 + 1], 1, 1, 1, .xrgb8888)));
    const first = try device.importImage(image(pixels[0..16], 4, 3, 5, .xrgb8888));
    try t.expectError(error.AliasedImage, device.importImage(image(pixels[13..17], 2, 2, 2, .xrgb8888)));
    const second = try device.importImage(image(pixels[14..18], 2, 2, 2, .xrgb8888));
    try t.expectError(error.TextureCapacity, device.importImage(image(pixels[24..28], 2, 2, 2, .xrgb8888)));
    try device.release(first);
    try device.release(second);
}

test "image storage may not overlap backend metadata or submission descriptors" {
    var device: core.Software(1) = .{};
    const metadata: [*]volatile u32 = @ptrCast(@alignCast(&device));
    try t.expectError(error.AliasedImage, device.importImage(image(metadata[0..1], 1, 1, 1, .xrgb8888)));
    var pixels: [128]u32 align(@alignOf(anvil.Command)) = @splat(0);
    const texture = try device.importImage(image(&pixels, 128, 1, 128, .xrgb8888));
    const commands: [*]anvil.Command = @ptrCast(&pixels);
    commands[0] = fill(texture, .{ .x = 0, .y = 0, .width = 128, .height = 1 }, 0);
    const provider = device.provider();
    try t.expectError(error.AliasedCommandStorage, provider.submit(provider.context, 1, commands[0..1]));
    try t.expectEqual(@as(u64, 0), (try provider.completed(provider.context)).sequence);
}

test "sequence and command bounds remain enforced when bypassing public queue" {
    var pixels: [1]u32 = .{0};
    var device: core.Software(1) = .{};
    const texture = try device.importImage(image(&pixels, 1, 1, 1, .xrgb8888));
    const provider = device.provider();
    const command = fill(texture, .{ .x = 0, .y = 0, .width = 1, .height = 1 }, 123);
    try t.expectError(error.InvalidSequence, provider.submit(provider.context, 0, &.{command}));
    try t.expectError(error.EmptyBatch, provider.submit(provider.context, 1, &.{}));
    const too_many: [anvil.max_commands + 1]anvil.Command = @splat(command);
    try t.expectError(error.TooManyCommands, provider.submit(provider.context, 1, &too_many));
    const maximum: [anvil.max_commands]anvil.Command = @splat(command);
    _ = try provider.submit(provider.context, std.math.maxInt(u64), &maximum);
    try t.expectError(error.InvalidSequence, provider.submit(provider.context, std.math.maxInt(u64), &.{command}));
    try t.expectError(error.InvalidSequence, provider.submit(provider.context, 1, &.{command}));
    try t.expectEqual(std.math.maxInt(u64), (try provider.completed(provider.context)).sequence);
    try t.expectEqual(@as(u32, 123), pixels[0]);
}

test "moving a borrowed device invalidates the copied provider context" {
    var device: core.Software(1) = .{};
    _ = device.provider();
    var moved = device;
    const provider = moved.provider();
    try t.expectError(error.MovedDevice, provider.info(provider.context));
    var pixels: [1]u32 = .{0};
    try t.expectError(error.MovedDevice, moved.importImage(image(&pixels, 1, 1, 1, .xrgb8888)));
}
