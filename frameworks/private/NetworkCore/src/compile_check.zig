const core = @import("network_core");
export fn bedrock_wifi_controller_probe() callconv(.c) u64 {
    var radio: core.wifi_test_radio.Radio = .{};
    var controller: core.wifi.Controller = .{};
    controller.init(radio.backend(), 0) catch return 0;
    controller.setEnabled(true, 0) catch return 0;
    controller.startScan(1) catch return 0;
    controller.poll(2);
    controller.poll(2);
    const scan = controller.scan() catch return 0;
    var credentials: core.wifi.wifi.Credentials = .{};
    controller.join(scan.generation, 0, &credentials, 3) catch return 0;
    controller.poll(4);
    controller.poll(4);
    controller.disconnect(5) catch return 0;
    return controller.status().revision;
}
export fn bedrock_network_core_probe() callconv(.c) usize {
    var stack: core.Stack = .{};
    var context: u8 = 0;
    stack.init(.{ .mac = .{ 2, 0, 0, 0, 0, 1 } }, .{ .context = &context, .send = &struct {
        fn send(_: *anyopaque, _: []const u8) !void {}
    }.send }) catch return 0;
    const id = stack.open(.{ .address = .{ .bytes = .{ 10, 0, 2, 2 } }, .port = 1234 }) catch return 0;
    _ = stack.send(id, "probe") catch {};
    stack.ingest(&.{});
    var bytes: [core.max_datagram]u8 = undefined;
    _ = stack.receive(id, &bytes) catch {};
    stack.close(id) catch return 0;
    return stack.liveCount();
}
