const std = @import("std");
const app = @import("root.zig");
const ui = app.axisui;

test "window context overlay stays above app toolbar and cannot paint caption or stride padding" {
    const EmptyProvider = struct {
        fn list(_: *anyopaque, _: []const u8, _: *usize) anyerror!?app.Entry {
            return null;
        }
    };
    var context: u8 = 0;
    var model: app.Model = .{};
    try model.init(.{ .context = &context, .list = EmptyProvider.list }, "/container/Documents", "/container/Downloads");
    model.action(.more);
    try std.testing.expect(model.menu != null);
    const width = 316;
    const height = 236;
    const stride = 320;
    const untouched: u32 = 0x214365;
    var memory: [height * stride + 2]u32 = @splat(untouched);
    var surface = try ui.Surface.init(memory[1 .. memory.len - 1], width, height, stride, .{ .red = 0xff0000, .green = 0xff00, .blue = 0xff });
    var workspace: app.Workspace = undefined;
    const revision = model.revision;
    try app.renderWindowMenuWithWorkspace(&surface, &workspace, &model);
    var painted_toolbar: usize = 0;
    for (0..height) |row| for (0..stride) |column| {
        const pixel = memory[1 + row * stride + column];
        if (row < app.layout.window_header_height or column >= width) {
            try std.testing.expectEqual(untouched, pixel);
        } else if (row < app.layout.window_header_height + app.layout.body_top and pixel != untouched) painted_toolbar += 1;
    };
    try std.testing.expect(painted_toolbar > 100);
    try std.testing.expectEqual(revision, model.revision);
    try std.testing.expectEqual(untouched, memory[0]);
    try std.testing.expectEqual(untouched, memory[memory.len - 1]);
}
