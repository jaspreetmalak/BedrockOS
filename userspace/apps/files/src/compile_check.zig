const files = @import("files_app");
var model: files.Model = .{};
var workspace: files.Workspace = undefined;
var context: u8 = 0;
fn list(_: *anyopaque, _: []const u8, _: *usize) anyerror!?files.Entry {
    return null;
}
export fn bedrock_files_compile_probe(pixels: [*]volatile u32, count: usize, width: u32, height: u32, stride: u32) callconv(.c) bool {
    model.init(.{ .context = &context, .list = list }, "/container", "/bundle") catch return false;
    model.dispatch(.{ .kind = .key_down, .code = @backingInt(files.axisui.input.Key.tab) }, width, height) catch return false;
    var surface = files.axisui.Surface.init(pixels[0..count], width, height, stride, .{ .red = 0xff0000, .green = 0xff00, .blue = 0xff }) catch return false;
    files.renderWithWorkspace(&surface, &workspace, &model) catch return false;
    return true;
}
fn rect(_: *anyopaque, _: u32, _: u32, _: u32, _: u32, _: u32) void {}
fn material(_: *anyopaque, _: u32, _: u32, _: u32, _: u32, _: files.axisui.Material) void {}
export fn bedrock_files_commands_probe(width: u32, height: u32) callconv(.c) bool {
    model.init(.{ .context = &context, .list = list }, "/container", "/bundle") catch return false;
    model.action(.more);
    var surface = files.axisui.Surface.initCommands(width, height, .{ .context = &context, .fillRect = rect, .materialRect = material }) catch return false;
    files.renderWithWorkspace(&surface, &workspace, &model) catch return false;
    return true;
}
