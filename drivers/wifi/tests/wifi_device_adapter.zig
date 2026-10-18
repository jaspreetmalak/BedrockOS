//! Test-only direct binding adapter for station lifetime regressions. Production
//! kernel controls use the versioned C ABI in core/wifi_module_adapter.zig.
const core = @import("network_core");
const drivers = @import("wifi_drivers");
const wifi = core.networkkit.wifi;
pub const Sink = struct { context: *anyopaque, ingest: *const fn (*anyopaque, []const u8) void };
pub const Adapter = struct {
    radio: *drivers.mt7922_station.Binding,
    now: u64,
    enabled: bool = false,
    sink: ?Sink = null,
    pub fn backend(self: *Adapter) core.wifi.Backend {
        return .{ .context = self, .capabilities = .{ .scan = true, .wpa2_psk = true }, .simulated = false, .set_enabled = enable, .start_scan = scan, .start_join = join, .cancel = cancel, .disconnect = disconnect, .poll = poll };
    }
    fn cast(context: *anyopaque) *Adapter {
        return @ptrCast(@alignCast(context));
    }
    fn enable(context: *anyopaque, value: bool) !void {
        const self = cast(context);
        try self.radio.setEnabled(value);
        self.enabled = value;
    }
    fn scan(context: *anyopaque, operation: u64) !void {
        try cast(context).radio.startScan(operation);
    }
    fn join(context: *anyopaque, operation: u64, selected: wifi.Bss, secret: []const u8) !void {
        const self = cast(context);
        try self.radio.join(operation, selected, secret, self.now);
    }
    fn cancel(context: *anyopaque, operation: u64) !void {
        try cast(context).radio.cancel(operation);
    }
    fn disconnect(context: *anyopaque) !void {
        try cast(context).radio.disconnect();
    }
    fn poll(context: *anyopaque) !?core.wifi.Event {
        const self = cast(context);
        for (0..16) |_| {
            const event = (try self.radio.poll(self.now)) orelse return null;
            switch (event) {
                .scan_result => |found| return .{ .scan_result = .{ .operation = found.operation, .bss = found.bss } },
                .scan_complete => |done| return .{ .scan_complete = .{ .operation = done.operation } },
                .link => |state| return switch (state) {
                    .joined => |joined| .{ .joined = .{ .operation = joined.operation, .bssid = joined.bssid, .security = joined.security, .authenticated = joined.authenticated } },
                    .failed => |failed| .{ .failed = .{ .operation = failed.operation, .failure = failed.failure } },
                    .link_lost => |lost| .{ .link_lost = .{ .operation = lost.operation } },
                },
                .ethernet => |frame| if (self.sink) |sink| sink.ingest(sink.context, frame),
            }
        }
        return null;
    }
    pub fn connected(context: *anyopaque) bool {
        const self = cast(context);
        return self.enabled and self.radio.isConnected();
    }
    pub fn send(context: *anyopaque, frame: []const u8) !void {
        const self = cast(context);
        if (!connected(context)) return error.NetworkUnavailable;
        try self.radio.sendEthernet(frame);
    }
};
