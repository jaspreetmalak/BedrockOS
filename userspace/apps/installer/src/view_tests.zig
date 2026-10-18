const std = @import("std");
const ui = @import("axisui");
const view = @import("view.zig");
const drives = [_]view.Drive{ .{ .name = "QEMU drive 1", .blocks = 262144 }, .{ .name = "QEMU drive 2", .blocks = 524288 } };

fn key(model: *view.Model, code: u16) view.Action {
    return model.handle(.{ .kind = .key_down, .code = code }, 800, 600);
}
fn text(model: *view.Model, bytes: []const u8) void {
    for (bytes) |byte| _ = key(model, byte);
}
fn pointer(model: *view.Model, kind: ui.input.Kind, rect: ui.Rect) view.Action {
    return model.handle(.{ .kind = kind, .code = @backingInt(ui.input.Button.left), .x = @intCast(rect.x + 8), .y = @intCast(rect.y + 16) }, 800, 600);
}

test "exact destructive confirmation gates installation and cannot be reused" {
    var model = try view.Model.init(&drives);
    try std.testing.expectEqual(view.Action.none, key(&model, 13));
    try std.testing.expectEqual(view.Phase.review, model.phase);
    text(&model, "erase");
    try std.testing.expectEqual(view.Action.none, key(&model, 13));
    for (0..5) |_| _ = key(&model, 8);
    text(&model, "ERASE!");
    try std.testing.expectEqual(view.Action.none, key(&model, 13));
    _ = key(&model, 8);
    try std.testing.expectEqual(view.Action.install, key(&model, 13));
    try std.testing.expectEqual(view.Phase.installing, model.phase);
    try std.testing.expectEqual(view.Action.none, key(&model, 13));
    try std.testing.expectEqual(view.Action.none, key(&model, 27));
    model.setProgress(255);
    try std.testing.expectEqual(@as(u8, 100), model.progress);
    model.finish();
    try std.testing.expectEqual(view.Action.restart, key(&model, 13));
}
test "empty, undersized and invalid destinations cannot continue" {
    var empty = try view.Model.init(&.{});
    try std.testing.expectEqual(view.Action.none, key(&empty, 13));
    try std.testing.expectEqual(view.Phase.selecting, empty.phase);
    try std.testing.expectEqual(view.Action.exit, key(&empty, 27));
    var small = try view.Model.init(&.{.{ .name = "too small", .blocks = view.layout_minimum_blocks - 1 }});
    try std.testing.expectEqual(view.Action.none, key(&small, 13));
    small.minimum_blocks = 0;
    try std.testing.expectEqual(view.Action.none, key(&small, 13));
    var bad = try view.Model.init(&drives);
    bad.selected = 9;
    try std.testing.expectEqual(view.Action.none, key(&bad, 13));
    const extra: [9]view.Drive = @splat(.{ .name = "drive", .blocks = 262144 });
    try std.testing.expectError(error.TooManyDrives, view.Model.init(&extra));
    try std.testing.expectError(error.InvalidDriveName, view.Model.init(&.{.{ .name = "bad\nname", .blocks = 262144 }}));
}
test "keyboard selection, Back and errors clear confirmation" {
    var model = try view.Model.init(&drives);
    _ = key(&model, @backingInt(ui.input.Key.down));
    try std.testing.expectEqual(@as(?u8, 1), model.selected);
    _ = key(&model, @backingInt(ui.input.Key.down));
    try std.testing.expectEqual(@as(?u8, 1), model.selected);
    _ = key(&model, 13);
    text(&model, "ERASE");
    _ = key(&model, 27);
    try std.testing.expectEqual(view.Phase.selecting, model.phase);
    _ = key(&model, 13);
    try std.testing.expect(!model.confirmed());
    model.fail("Write failed");
    try std.testing.expectEqual(view.Phase.failed, model.phase);
    _ = key(&model, 13);
    try std.testing.expectEqual(view.Phase.selecting, model.phase);
    try std.testing.expect(!model.confirmed());
}
test "release requires a matched press and rejects changed selection or geometry" {
    var model = try view.Model.init(&drives);
    const primary = view.primaryRect(800, 600);
    try std.testing.expectEqual(view.Action.none, pointer(&model, .pointer_up, primary));
    try std.testing.expectEqual(view.Phase.selecting, model.phase);
    _ = pointer(&model, .pointer_down, primary);
    model.selected = 1;
    _ = pointer(&model, .pointer_up, primary);
    try std.testing.expectEqual(view.Phase.selecting, model.phase);
    _ = pointer(&model, .pointer_down, primary);
    _ = model.handle(.{ .kind = .pointer_up, .code = 1, .x = @intCast(primary.x + 8), .y = @intCast(primary.y + 16) }, 1280, 800);
    try std.testing.expectEqual(view.Phase.selecting, model.phase);
    _ = pointer(&model, .pointer_down, primary);
    _ = pointer(&model, .pointer_up, view.secondaryRect(800, 600));
    try std.testing.expectEqual(view.Phase.selecting, model.phase);
    _ = pointer(&model, .pointer_down, primary);
    _ = pointer(&model, .pointer_up, primary);
    try std.testing.expectEqual(view.Phase.review, model.phase);
    text(&model, "ERASE");
    _ = pointer(&model, .pointer_down, primary);
    _ = key(&model, 8);
    try std.testing.expectEqual(view.Action.none, pointer(&model, .pointer_up, primary));
    try std.testing.expectEqual(view.Phase.review, model.phase);
}
test "pointer row selection and obsolete gestures use shared geometry" {
    var model = try view.Model.init(&drives);
    const row = view.driveRect(800, 600, 1);
    _ = pointer(&model, .pointer_down, row);
    _ = pointer(&model, .pointer_up, row);
    try std.testing.expectEqual(@as(?u8, 1), model.selected);
    _ = pointer(&model, .pointer_down, view.primaryRect(800, 600));
    _ = model.handle(.{ .kind = .redraw, .code = 1 }, 800, 600);
    _ = pointer(&model, .pointer_up, view.primaryRect(800, 600));
    try std.testing.expectEqual(view.Phase.selecting, model.phase);
}
test "all eight destinations fit the smallest supported display" {
    const many: [8]view.Drive = @splat(.{ .name = "drive", .blocks = 262144 });
    var model = try view.Model.init(&many);
    var previous_end: i64 = 0;
    const primary = view.primaryRect(640, 480);
    for (0..view.max_drives) |index| {
        const rect = view.driveRect(640, 480, index);
        try std.testing.expect(rect.height >= 22);
        try std.testing.expect(rect.y >= previous_end);
        try std.testing.expect(@as(i64, rect.y) + rect.height < primary.y);
        previous_end = @as(i64, rect.y) + rect.height;
        const x: i16 = @intCast(rect.x + 8);
        const y: i16 = @intCast(@as(i64, rect.y) + rect.height / 2);
        _ = model.handle(.{ .kind = .pointer_down, .code = 1, .x = x, .y = y }, 640, 480);
        _ = model.handle(.{ .kind = .pointer_up, .code = 1, .x = x, .y = y }, 640, 480);
        try std.testing.expectEqual(@as(?u8, @intCast(index)), model.selected);
    }
}
test "an unreadable review cannot authorize an install" {
    var model = try view.Model.init(&drives);
    _ = key(&model, 13);
    text(&model, "ERASE");
    try std.testing.expectEqual(view.Action.none, model.handle(.{ .kind = .key_down, .code = 13 }, 320, 360));
    try std.testing.expectEqual(view.Phase.review, model.phase);
    try std.testing.expectEqual(view.Action.none, model.handle(.{ .kind = .key_down, .code = 27 }, 320, 360));
    try std.testing.expectEqual(view.Phase.selecting, model.phase);
}
test "all installer phases clip and preserve scanout padding and guards" {
    for ([_]struct { width: u32, height: u32 }{ .{ .width = 800, .height = 600 }, .{ .width = 1280, .height = 800 }, .{ .width = 640, .height = 480 }, .{ .width = 320, .height = 360 } }) |size| {
        const sentinel: u32 = 0x12345678;
        const stride = size.width + 3;
        const count = @as(usize, stride) * size.height;
        const pixels = try std.testing.allocator.alloc(u32, count + 2);
        defer std.testing.allocator.free(pixels);
        var surface = try ui.Surface.init(pixels[1 .. count + 1], size.width, size.height, stride, .{ .red = 0xff0000, .green = 0xff00, .blue = 0xff });
        var model = try view.Model.init(&drives);
        var workspace: ui.Workspace = undefined;
        for ([_]view.Phase{ .selecting, .review, .installing, .complete, .failed }) |phase| {
            @memset(pixels, sentinel);
            model.phase = phase;
            model.progress = 50;
            try view.draw(&surface, &model, &workspace);
            try std.testing.expectEqual(sentinel, pixels[0]);
            try std.testing.expectEqual(sentinel, pixels[count + 1]);
            for (0..size.height) |row| for (size.width..stride) |column| try std.testing.expectEqual(sentinel, pixels[1 + row * stride + column]);
        }
    }
}
