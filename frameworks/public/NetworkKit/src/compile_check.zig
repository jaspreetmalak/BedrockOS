const net = @import("networkkit");

export fn bedrock_networkkit_probe(provider: *const net.Provider, port: u16) callconv(.c) bool {
    const address = net.IPv4.parse("10.0.2.2") catch return false;
    var formatted: [15]u8 = undefined;
    _ = address.format(&formatted) catch return false;
    if (!address.eql(.{ .bytes = .{ 10, 0, 2, 2 } })) return false;
    const endpoint = net.Endpoint.init(address, port) catch return false;
    var connection = net.Connection.connect(provider.*, endpoint) catch return false;
    var output: [net.max_datagram]u8 = undefined;
    _ = connection.send("NetworkKit") catch {
        connection.close() catch {};
        return false;
    };
    _ = connection.receive(&output) catch {};
    connection.close() catch return false;
    return true;
}

var radio: ?net.wifi.Radio = null;
var credentials: net.wifi.Credentials = .{};
export fn bedrock_networkkit_wifi_probe(provider: *const net.wifi.Provider, selected_index: usize) callconv(.c) bool {
    radio = net.wifi.Radio.init(provider.*);
    const current = &radio.?;
    _ = current.status() catch return false;
    current.setEnabled(true) catch return false;
    current.startScan() catch return false;
    const scan = current.scan() catch return false;
    credentials = net.wifi.Credentials.init("probe passphrase") catch return false;
    current.join(scan.generation, selected_index, &credentials) catch {
        current.disconnect() catch {};
        return false;
    };
    current.disconnect() catch return false;
    current.setEnabled(false) catch return false;
    return true;
}
