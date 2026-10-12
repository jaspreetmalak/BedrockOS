const std = @import("std");
const net = @import("root.zig");
const t = std.testing;

const Mock = struct {
    opens: usize = 0,
    sends: usize = 0,
    receives: usize = 0,
    closes: usize = 0,
    token: u64 = 0x8000_0000_0000_1234,
    opened: bool = false,
    queued: bool = false,
    bytes: [net.max_datagram]u8 = undefined,
    length: usize = 0,
    capacity: usize = 0,
    send_result: ?usize = null,
    receive_result: ?usize = null,
    open_error: ?anyerror = null,
    send_error: ?anyerror = null,
    receive_error: ?anyerror = null,
    close_error: ?anyerror = null,
    endpoint: ?net.Endpoint = null,

    fn from(context: *anyopaque) *Mock {
        return @ptrCast(@alignCast(context));
    }
    fn open(context: *anyopaque, peer: net.Endpoint) anyerror!u64 {
        const self = from(context);
        self.opens += 1;
        if (self.open_error) |err| return err;
        self.endpoint = peer;
        self.opened = self.token != 0;
        return self.token;
    }
    fn send(context: *anyopaque, token: u64, payload: []const u8) anyerror!usize {
        const self = from(context);
        self.sends += 1;
        if (!self.opened or token != self.token) return error.InvalidHandle;
        if (self.send_error) |err| return err;
        if (self.send_result) |count| return count;
        @memcpy(self.bytes[0..payload.len], payload);
        self.length = payload.len;
        self.queued = true;
        return payload.len;
    }
    fn receive(context: *anyopaque, token: u64, output: []u8) anyerror!usize {
        const self = from(context);
        self.receives += 1;
        self.capacity = output.len;
        if (!self.opened or token != self.token) return error.InvalidHandle;
        if (self.receive_error) |err| return err;
        if (self.receive_result) |count| return count;
        if (!self.queued) return error.WouldBlock;
        if (output.len < self.length) return error.BufferTooSmall;
        @memcpy(output[0..self.length], self.bytes[0..self.length]);
        self.queued = false;
        return self.length;
    }
    fn close(context: *anyopaque, token: u64) anyerror!void {
        const self = from(context);
        self.closes += 1;
        if (!self.opened or token != self.token) return error.InvalidHandle;
        if (self.close_error) |err| return err;
        self.opened = false;
        self.queued = false;
    }
    fn provider(self: *Mock) net.Provider {
        return .{ .context = self, .open = open, .send = send, .receive = receive, .close = close };
    }
};

fn endpoint() !net.Endpoint {
    return net.Endpoint.init(try net.IPv4.parse("10.0.2.2"), 32123);
}

test "IPv4 strict decimal roundtrips all octet boundaries and formats into borrowed storage" {
    for ([_][]const u8{ "0.0.0.0", "255.255.255.255", "10.0.2.2", "1.9.10.99", "100.254.128.127" }) |text| {
        const parsed = try net.IPv4.parse(text);
        var output: [16]u8 = @splat(0xa5);
        const rendered = try parsed.format(&output);
        try t.expectEqualStrings(text, rendered);
        try t.expect(rendered.ptr == output[0..].ptr);
        try t.expectEqual(@as(u8, 0xa5), output[rendered.len]);
        try t.expect(parsed.eql(try net.IPv4.parse(rendered)));
    }
    try t.expect(!(try net.IPv4.parse("10.0.2.2")).eql(try net.IPv4.parse("10.0.2.3")));
}

test "IPv4 rejects malformed or ambiguous addresses without truncating octets" {
    for ([_][]const u8{ "", "1", "1.2.3", "1.2.3.4.5", "1..2.3", ".1.2.3.4", "1.2.3.4.", "256.1.2.3", "999.1.2.3", "0000.1.2.3", "01.2.3.4", "1.02.3.4", "+1.2.3.4", "-1.2.3.4", " 1.2.3.4", "1.2.3.4 ", "1.2.a.4", "1.2.3.4\x00", "localhost", "10:0:2:2", "0xA.0.2.2" }) |text| {
        try t.expectError(error.InvalidAddress, net.IPv4.parse(text));
    }
}

test "IPv4 formatting insufficient buffers leaves sentinels unchanged" {
    const parsed = try net.IPv4.parse("255.255.255.255");
    var output: [15]u8 = @splat(0xa5);
    for (0..15) |capacity| try t.expectError(error.BufferTooSmall, parsed.format(output[0..capacity]));
    for (output) |byte| try t.expectEqual(@as(u8, 0xa5), byte);
    try t.expectEqualStrings("255.255.255.255", try parsed.format(&output));
}

test "Endpoint rejects zero port before opening and accepts complete u16 boundary" {
    const address = try net.IPv4.parse("10.0.2.2");
    try t.expectError(error.InvalidPort, net.Endpoint.init(address, 0));
    var mock: Mock = .{};
    try t.expectError(error.InvalidPort, net.Connection.connect(mock.provider(), .{ .address = address, .port = 0 }));
    try t.expectEqual(@as(usize, 0), mock.opens);
    try (try net.Endpoint.init(address, 1)).validate();
    try (try net.Endpoint.init(address, 65535)).validate();
}

test "connect propagates failure and rejects zero provider handles" {
    var mock: Mock = .{ .open_error = error.NetworkUnavailable };
    try t.expectError(error.NetworkUnavailable, net.Connection.connect(mock.provider(), try endpoint()));
    try t.expect(!mock.opened and mock.closes == 0);
    mock.open_error = null;
    mock.token = 0;
    try t.expectError(error.InvalidProviderResult, net.Connection.connect(mock.provider(), try endpoint()));
    try t.expect(!mock.opened and mock.closes == 0);
}

test "whole UDP message lifecycle preserves token endpoint and borrowed payload" {
    var mock: Mock = .{};
    var connection = try net.Connection.connect(mock.provider(), try endpoint());
    try t.expectEqual(mock.token, connection.handle);
    try t.expect(mock.endpoint.?.address.eql((try endpoint()).address));
    try t.expectEqual(@as(u16, 32123), mock.endpoint.?.port);
    const message = "Native UDP";
    try t.expectEqual(message.len, try connection.send(message));
    var output: [20]u8 = @splat(0xa5);
    try t.expectEqual(message.len, try connection.receive(&output));
    try t.expectEqualSlices(u8, message, output[0..message.len]);
    try t.expectEqual(@as(u8, 0xa5), output[message.len]);
    try connection.close();
    try t.expect(connection.closed and connection.handle == 0);
    try t.expect(mock.opens == 1 and mock.sends == 1 and mock.receives == 1 and mock.closes == 1);
}

test "oversized sends fail before callback while maximum messages remain whole" {
    var mock: Mock = .{};
    var connection = try net.Connection.connect(mock.provider(), try endpoint());
    defer connection.close() catch unreachable;
    const message: [net.max_datagram + 1]u8 = @splat(0xa5);
    try t.expectError(error.DatagramTooLarge, connection.send(&message));
    try t.expectEqual(@as(usize, 0), mock.sends);
    try t.expectEqual(net.max_datagram, try connection.send(message[0..net.max_datagram]));
    var output: [net.max_datagram + 10]u8 = @splat(0x55);
    try t.expectEqual(net.max_datagram, try connection.receive(&output));
    try t.expectEqual(net.max_datagram, mock.capacity);
    try t.expectEqualSlices(u8, message[0..net.max_datagram], output[0..net.max_datagram]);
    for (output[net.max_datagram..]) |byte| try t.expectEqual(@as(u8, 0x55), byte);
}

test "empty datagrams are delivered once and distinct from WouldBlock" {
    var mock: Mock = .{};
    var connection = try net.Connection.connect(mock.provider(), try endpoint());
    defer connection.close() catch unreachable;
    var empty: [0]u8 = .{};
    try t.expectError(error.WouldBlock, connection.receive(&empty));
    try t.expectEqual(@as(usize, 0), try connection.send(""));
    try t.expectEqual(@as(usize, 0), try connection.receive(&empty));
    try t.expectError(error.WouldBlock, connection.receive(&empty));
}

test "short receive fails without dequeuing and later full receive preserves bytes" {
    var mock: Mock = .{};
    var connection = try net.Connection.connect(mock.provider(), try endpoint());
    defer connection.close() catch unreachable;
    _ = try connection.send("preserved");
    var output: [12]u8 = @splat(0xa5);
    try t.expectError(error.BufferTooSmall, connection.receive(output[0..2]));
    try t.expectError(error.BufferTooSmall, connection.receive(output[0..0]));
    try t.expect(mock.queued);
    for (output) |byte| try t.expectEqual(@as(u8, 0xa5), byte);
    try t.expectEqual(@as(usize, 9), try connection.receive(&output));
    try t.expectEqualStrings("preserved", output[0..9]);
}

test "partial oversized or impossible provider results never report message success" {
    var mock: Mock = .{};
    var connection = try net.Connection.connect(mock.provider(), try endpoint());
    defer connection.close() catch unreachable;
    for ([_]usize{ 0, 2, 4, std.math.maxInt(usize) }) |count| {
        mock.send_result = count;
        try t.expectError(error.InvalidProviderResult, connection.send("udp"));
    }
    mock.send_result = 1;
    try t.expectError(error.InvalidProviderResult, connection.send(""));
    var output: [8]u8 = undefined;
    mock.receive_result = output.len + 1;
    try t.expectError(error.InvalidProviderResult, connection.receive(&output));
    var larger: [net.max_datagram + 1]u8 = undefined;
    mock.receive_result = net.max_datagram + 1;
    try t.expectError(error.InvalidProviderResult, connection.receive(&larger));
}

test "provider errors propagate without hidden retries and close failure retains ownership" {
    var mock: Mock = .{};
    var connection = try net.Connection.connect(mock.provider(), try endpoint());
    mock.send_error = error.WouldBlock;
    try t.expectError(error.WouldBlock, connection.send("udp"));
    try t.expectEqual(@as(usize, 1), mock.sends);
    var output: [8]u8 = undefined;
    mock.receive_error = error.NetworkUnavailable;
    try t.expectError(error.NetworkUnavailable, connection.receive(&output));
    try t.expectEqual(@as(usize, 1), mock.receives);
    mock.close_error = error.WouldBlock;
    try t.expectError(error.WouldBlock, connection.close());
    try t.expect(!connection.closed and connection.handle == mock.token and mock.opened);
    mock.close_error = null;
    try connection.close();
    try t.expectEqual(@as(usize, 2), mock.closes);
}

test "closed guards avoid callbacks and copying does not duplicate provider rights" {
    var mock: Mock = .{};
    var connection = try net.Connection.connect(mock.provider(), try endpoint());
    var stale_copy = connection;
    try connection.close();
    var output: [8]u8 = undefined;
    try t.expectError(error.Closed, connection.send("udp"));
    try t.expectError(error.Closed, connection.receive(&output));
    try t.expectError(error.Closed, connection.close());
    try t.expect(mock.sends == 0 and mock.receives == 0 and mock.closes == 1);
    try t.expectError(error.InvalidHandle, stale_copy.send("stale"));
    try t.expectEqual(@as(usize, 1), mock.sends);
}
