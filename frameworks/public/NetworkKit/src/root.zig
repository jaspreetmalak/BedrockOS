//! Allocation-free connected UDP client API. Providers own transport and
//! authorization; this framework never imports a kernel, driver or syscall ABI.
const std = @import("std");
pub const max_datagram: usize = 256;
pub const wifi = @import("wifi.zig");

pub const IPv4 = struct {
    bytes: [4]u8,

    /// Strict dotted decimal: four octets, no signs, whitespace or leading zeros.
    pub fn parse(text: []const u8) !IPv4 {
        if (text.len < 7 or text.len > 15) return error.InvalidAddress;
        var result: IPv4 = undefined;
        var start: usize = 0;
        for (0..4) |index| {
            var end = start;
            var value: u16 = 0;
            while (end < text.len and text[end] != '.') : (end += 1) {
                const byte = text[end];
                if (byte < '0' or byte > '9' or end - start == 3) return error.InvalidAddress;
                value = value * 10 + byte - '0';
                if (value > 255) return error.InvalidAddress;
            }
            if (end == start or end - start > 1 and text[start] == '0') return error.InvalidAddress;
            result.bytes[index] = @intCast(value);
            if (index == 3) {
                if (end != text.len) return error.InvalidAddress;
            } else {
                if (end == text.len) return error.InvalidAddress;
                start = end + 1;
            }
        }
        return result;
    }

    /// Caller owns output. Insufficient capacity leaves the buffer unchanged.
    pub fn format(self: IPv4, output: []u8) ![]const u8 {
        var temporary: [15]u8 = undefined;
        const rendered = try std.fmt.bufPrint(&temporary, "{d}.{d}.{d}.{d}", .{ self.bytes[0], self.bytes[1], self.bytes[2], self.bytes[3] });
        if (output.len < rendered.len) return error.BufferTooSmall;
        @memcpy(output[0..rendered.len], rendered);
        return output[0..rendered.len];
    }

    pub fn eql(self: IPv4, other: IPv4) bool {
        return std.mem.eql(u8, &self.bytes, &other.bytes);
    }
};

pub const Endpoint = struct {
    address: IPv4,
    port: u16,

    pub fn init(address: IPv4, port: u16) !Endpoint {
        const endpoint: Endpoint = .{ .address = address, .port = port };
        try endpoint.validate();
        return endpoint;
    }

    pub fn validate(self: Endpoint) !void {
        if (self.port == 0) return error.InvalidPort;
        // Routing, destination policy and grants belong to the provider.
    }
};

pub const Provider = struct {
    context: *anyopaque,
    open: *const fn (*anyopaque, Endpoint) anyerror!u64,
    send: *const fn (*anyopaque, u64, []const u8) anyerror!usize,
    /// Return a whole datagram (including zero bytes), or error.WouldBlock.
    /// error.BufferTooSmall must leave the queued datagram unconsumed.
    receive: *const fn (*anyopaque, u64, []u8) anyerror!usize,
    close: *const fn (*anyopaque, u64) anyerror!void,
};

/// Single-owner connected UDP client. Keep provider context alive and serialize
/// calls. Copying this value does not duplicate the provider's handle or grant.
pub const Connection = struct {
    provider: Provider,
    handle: u64,
    closed: bool = false,

    pub fn connect(provider: Provider, endpoint: Endpoint) !Connection {
        try endpoint.validate();
        const handle = try provider.open(provider.context, endpoint);
        if (handle == 0) return error.InvalidProviderResult;
        return .{ .provider = provider, .handle = handle };
    }

    pub fn send(self: *Connection, payload: []const u8) !usize {
        if (self.closed) return error.Closed;
        if (payload.len > max_datagram) return error.DatagramTooLarge;
        const count = try self.provider.send(self.provider.context, self.handle, payload);
        if (count != payload.len) return error.InvalidProviderResult;
        return count;
    }

    pub fn receive(self: *Connection, output: []u8) !usize {
        if (self.closed) return error.Closed;
        const bounded = output[0..@min(output.len, max_datagram)];
        const count = try self.provider.receive(self.provider.context, self.handle, bounded);
        if (count > bounded.len) return error.InvalidProviderResult;
        return count;
    }

    /// A failed close leaves the client open so callers can handle/retry it.
    pub fn close(self: *Connection) !void {
        if (self.closed) return error.Closed;
        try self.provider.close(self.provider.context, self.handle);
        self.closed = true;
        self.handle = 0;
    }
};

test {
    _ = @import("tests.zig");
    _ = wifi;
}
