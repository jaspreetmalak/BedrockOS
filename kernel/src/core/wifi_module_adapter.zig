//! Kernel-side Wi-Fi class adapter. It imports no chipset implementation and
//! converts the versioned C ABI into the private NetworkCore controller API.
const std = @import("std");
const abi = @import("driver_abi");
const core = @import("network_core");
const wifi = core.networkkit.wifi;
pub const Sink = struct { context: *anyopaque, ingest: *const fn (*anyopaque, []const u8) void };
pub const Adapter = struct {
    radio: abi.Radio = .{},
    now: u64 = 0,
    enabled: bool = false,
    retired: bool = false,
    owner_address: usize = 0,
    busy: bool = false,
    sink: ?Sink = null,
    address: [6]u8 = @splat(0),

    /// Copy only the function table. The loader retains the separately mapped
    /// module image, its opaque context and all outstanding DMA allocations.
    pub fn init(self: *Adapter, radio: *const abi.Radio, now: u64) !void {
        if (self.owner_address != 0) return error.AlreadyInitialized;
        if (!radio.validate()) return error.InvalidModuleAbi;
        var address: [6]u8 = @splat(0);
        try result(radio.mac.?(radio.context.?, &address));
        if (address[0] & 1 != 0 or std.mem.allEqual(u8, &address, 0)) return error.InvalidModuleMac;
        self.* = .{ .radio = radio.*, .now = now, .address = address, .owner_address = @intFromPtr(self) };
    }
    pub fn backend(self: *Adapter) core.wifi.Backend {
        return .{
            .context = self,
            .capabilities = .{ .scan = self.radio.capabilities & abi.Capabilities.scan != 0, .wpa2_psk = self.radio.capabilities & abi.Capabilities.wpa2_psk != 0 },
            .simulated = false,
            .set_enabled = enable,
            .start_scan = scan,
            .start_join = join,
            .cancel = cancel,
            .disconnect = disconnect,
            .poll = poll,
        };
    }
    fn cast(context: *anyopaque) *Adapter {
        return @ptrCast(@alignCast(context));
    }
    fn owner(self: *const Adapter) !void {
        if (self.owner_address == 0 or self.owner_address != @intFromPtr(self)) return error.InvalidModuleAdapter;
        if (self.retired) return error.NetworkUnavailable;
    }
    fn enter(self: *Adapter) !void {
        try self.owner();
        if (self.busy) return error.ModuleBusy;
        self.busy = true;
    }
    fn complete(self: *Adapter, status: u32) !void {
        if (status == @backingInt(abi.Status.retired)) {
            self.retired = true;
            self.enabled = false;
        }
        try result(status);
    }
    fn enable(context: *anyopaque, value: bool) !void {
        const self = cast(context);
        try self.enter();
        defer self.busy = false;
        try self.complete(self.radio.enable.?(self.radio.context.?, @intFromBool(value)));
        self.enabled = value;
    }
    fn scan(context: *anyopaque, operation: u64) !void {
        const self = cast(context);
        try self.enter();
        defer self.busy = false;
        try self.complete(self.radio.scan.?(self.radio.context.?, operation));
    }
    fn join(context: *anyopaque, operation: u64, selected: wifi.Bss, secret: []const u8) !void {
        const self = cast(context);
        try selected.validate();
        if (secret.len > 63) return error.InvalidCredentials;
        var raw: abi.Bss = .{ .ssid = selected.ssid.bytes, .ssid_len = selected.ssid.len, .bssid = selected.bssid, .channel = selected.channel, .signal_dbm = selected.signal_dbm, .security = @backingInt(selected.security) };
        try self.enter();
        defer self.busy = false;
        try self.complete(self.radio.join.?(self.radio.context.?, operation, &raw, secret.ptr, @intCast(secret.len), self.now));
    }
    fn cancel(context: *anyopaque, operation: u64) !void {
        const self = cast(context);
        try self.enter();
        defer self.busy = false;
        try self.complete(self.radio.cancel.?(self.radio.context.?, operation));
    }
    fn disconnect(context: *anyopaque) !void {
        const self = cast(context);
        try self.enter();
        defer self.busy = false;
        try self.complete(self.radio.disconnect.?(self.radio.context.?));
    }
    fn next(self: *Adapter, output: *abi.Event) !bool {
        try self.enter();
        defer self.busy = false;
        const status = self.radio.poll.?(self.radio.context.?, self.now, output);
        if (status == @backingInt(abi.Status.no_event)) return false;
        try self.complete(status);
        return true;
    }
    fn poll(context: *anyopaque) !?core.wifi.Event {
        const self = cast(context);
        for (0..16) |_| {
            var event: abi.Event = .{};
            if (!try self.next(&event)) return null;
            if (!std.mem.allEqual(u8, &event.reserved, 0)) return error.InvalidModuleEvent;
            if (event.kind != @backingInt(abi.EventKind.ethernet) and (event.length != 0 or event.operation == 0)) return error.InvalidModuleEvent;
            switch (event.kind) {
                @backingInt(abi.EventKind.scan_result) => return .{ .scan_result = .{ .operation = event.operation, .bss = try decodeBss(&event.bss) } },
                @backingInt(abi.EventKind.scan_complete) => return .{ .scan_complete = .{ .operation = event.operation } },
                @backingInt(abi.EventKind.joined) => {
                    if (event.security > @backingInt(wifi.Security.unsupported) or event.authenticated > 1 or event.bssid[0] & 1 != 0 or std.mem.allEqual(u8, &event.bssid, 0)) return error.InvalidModuleEvent;
                    return .{ .joined = .{ .operation = event.operation, .bssid = event.bssid, .security = @fromBackingInt(event.security), .authenticated = event.authenticated != 0 } };
                },
                @backingInt(abi.EventKind.failed) => {
                    if (event.failure == 0 or event.failure > @backingInt(wifi.Failure.device_lost)) return error.InvalidModuleEvent;
                    return .{ .failed = .{ .operation = event.operation, .failure = @fromBackingInt(event.failure) } };
                },
                @backingInt(abi.EventKind.link_lost) => return .{ .link_lost = .{ .operation = event.operation } },
                @backingInt(abi.EventKind.ethernet) => {
                    if (event.length < 14 or event.length > event.ethernet.len or event.operation != 0) return error.InvalidModuleEvent;
                    // The module callback has returned before a sink can send
                    // an ARP reply; no borrowed module receive storage remains.
                    if (self.sink) |sink| sink.ingest(sink.context, event.ethernet[0..event.length]);
                },
                else => return error.InvalidModuleEvent,
            }
        }
        return null;
    }
    pub fn connected(context: *anyopaque) bool {
        const self = cast(context);
        self.owner() catch return false;
        if (!self.enabled or self.busy) return false;
        return self.radio.connected.?(self.radio.context.?) == 1;
    }
    pub fn send(context: *anyopaque, frame: []const u8) !void {
        const self = cast(context);
        if (!connected(context)) return error.NetworkUnavailable;
        if (frame.len > 1280) return error.FrameTooLarge;
        try self.enter();
        defer self.busy = false;
        try self.complete(self.radio.send.?(self.radio.context.?, frame.ptr, @intCast(frame.len)));
    }
    /// The kernel loader still owns the image. It must retain it whenever
    /// report().flags contains dma_retained or retirement fails.
    pub fn stop(self: *Adapter) !void {
        if (self.owner_address == 0 or self.owner_address != @intFromPtr(self) or self.busy) return error.InvalidModuleAdapter;
        self.busy = true;
        defer self.busy = false;
        const status = self.radio.stop.?(self.radio.context.?);
        self.enabled = false;
        self.retired = true;
        if (status != @backingInt(abi.Status.retired) and status != @backingInt(abi.Status.ok)) try result(status);
    }
};
fn result(status: u32) !void {
    return switch (status) {
        @backingInt(abi.Status.ok) => {},
        @backingInt(abi.Status.invalid_abi) => error.InvalidModuleAbi,
        @backingInt(abi.Status.unavailable), @backingInt(abi.Status.failed), @backingInt(abi.Status.retired) => error.NetworkUnavailable,
        else => error.InvalidModuleStatus,
    };
}
fn decodeBss(raw: *const abi.Bss) !wifi.Bss {
    if (!std.mem.allEqual(u8, &raw.reserved, 0) or raw.security > @backingInt(wifi.Security.unsupported)) return error.InvalidModuleEvent;
    const value: wifi.Bss = .{ .ssid = .{ .bytes = raw.ssid, .len = raw.ssid_len }, .bssid = raw.bssid, .channel = raw.channel, .signal_dbm = raw.signal_dbm, .security = @fromBackingInt(raw.security) };
    try value.validate();
    return value;
}
