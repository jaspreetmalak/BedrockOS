const ui = @import("axisui");

export fn bedrock_axisui_compile_probe(pixels: [*]volatile u32, count: usize, width: u32, height: u32, stride: u32) callconv(.c) bool {
    var surface = ui.Surface.init(pixels[0..count], width, height, stride, .{
        .red = 0xff0000,
        .green = 0xff00,
        .blue = 0xff,
    }) catch return false;
    const labels = [_]ui.View{ ui.Text("BEDROCK").scale(2), ui.Spacer(), ui.Text("AXISUI") };
    ui.render(&surface, ui.HStack(&labels).padding(8).gap(4).background(ui.Color.rgb(16, 20, 28))) catch return false;
    _ = ui.font.measure("Files", 1) catch return false;
    ui.drawIcon(&surface, .folder, .{ .x = 4, .y = 4 }, ui.Color.rgb(212, 149, 173), 1) catch return false;
    return true;
}

export fn bedrock_axisui_input_probe(raw: u64) callconv(.c) u64 {
    const event = ui.Event.decode(raw) catch return 0;
    var queue: ui.Queue(2) = .{};
    queue.push(event) catch return 0;
    const next = queue.pop() orelse return 0;
    var hits: ui.HitMap(2) = .{};
    hits.add(1, .{ .x = 0, .y = 0, .width = 800, .height = 600 }) catch return 0;
    var state: ui.State(u64) = .{ .value = 0 };
    _ = state.set(hits.hit(.{ .x = next.x, .y = next.y }) orelse 0) catch return 0;
    return next.encode() ^ state.revision;
}

export fn bedrock_axisui_material_probe() callconv(.c) u32 {
    var source_pixels: [16 * 16]u32 = @splat(0x204060);
    const source = ui.Surface.init(&source_pixels, 16, 16, 16, .{ .red = 0xff0000, .green = 0xff00, .blue = 0xff }) catch return 1;
    var colors: [4]u32 = undefined;
    var scratch: [4]u32 = undefined;
    const backdrop = ui.Backdrop.build(&source, &colors, &scratch) catch return 2;
    var destination: [16 * 16]u32 = @splat(0);
    var surface = ui.Surface.init(&destination, 16, 16, 16, .{ .red = 0xff0000, .green = 0xff00, .blue = 0xff }) catch return 3;
    surface.setBackdrop(&backdrop, .{ .x = 0, .y = 0 }) catch return 4;
    surface.materialRect(0, 0, 16, 16, .{ .tint = ui.Color.rgb(18, 24, 33), .opacity = 170 });
    return destination[0];
}
