//! Trusted asynchronous radio controller. A link is not an IP configuration.
const std = @import("std");
pub const wifi = @import("networkkit").wifi;
pub const association_timeout_ticks: u64 = 1000;
pub const scan_timeout_ticks: u64 = 500;
pub const max_events_per_poll: usize = 16;
pub const Capabilities = struct { scan: bool = false, open: bool = false, wpa2_psk: bool = false };
pub const Event = union(enum) {
    scan_result: struct { operation: u64, bss: wifi.Bss },
    scan_complete: struct { operation: u64 },
    /// The backend confirms association and, for WPA2, its completed security
    /// handshake. Submission success alone never establishes a connection.
    joined: struct { operation: u64, bssid: [6]u8, security: wifi.Security, authenticated: bool },
    failed: struct { operation: u64, failure: wifi.Failure },
    link_lost: struct { operation: u64 },
};
pub const Backend = struct {
    context: *anyopaque,
    capabilities: Capabilities,
    simulated: bool = false,
    /// Synchronous confirmed radio state / DMA-operation cancellation.
    set_enabled: *const fn (*anyopaque, bool) anyerror!void,
    start_scan: *const fn (*anyopaque, u64) anyerror!void,
    /// Borrow only for this call. No credential bytes/pointers may be retained.
    start_join: *const fn (*anyopaque, u64, wifi.Bss, []const u8) anyerror!void,
    cancel: *const fn (*anyopaque, u64) anyerror!void,
    disconnect: *const fn (*anyopaque) anyerror!void,
    poll: *const fn (*anyopaque) anyerror!?Event,
};
pub const Error = error{ AlreadyInitialized, NetworkUnavailable, RadioDisabled, Busy, WouldBlock, StaleScan, InvalidSelection, HiddenSsid, UnsupportedSecurity, InvalidCredentials, UnsupportedRadio, InvalidScan, OperationExhausted, GenerationExhausted, TimeOverflow, ClockRegression };
const empty_bss: wifi.Bss = .{ .ssid = .{}, .bssid = @splat(0), .channel = 0, .signal_dbm = 0, .security = .open };
const Pending = enum { none, scan, join };

pub const Controller = struct {
    backend: Backend = undefined,
    initialized: bool = false,
    enabled: bool = false,
    state: wifi.State = .unavailable,
    failure: wifi.Failure = .none,
    revision: u64 = 1,
    current: ?wifi.Bss = null,
    pending: Pending = .none,
    operation: u64 = 0,
    link_operation: u64 = 0,
    next_operation: u64 = 1,
    deadline: u64 = 0,
    last_now: u64 = 0,
    scan_generation: u64 = 0,
    cache: wifi.Scan = .{ .generation = 0, .count = 0, .entries = @splat(empty_bss) },
    working: [wifi.max_scan_results]wifi.Bss = @splat(empty_bss),
    working_count: usize = 0,
    selected: ?wifi.Bss = null,
    stale_events: u64 = 0,
    dropped_scan_results: u64 = 0,

    pub fn init(self: *Controller, backend: Backend, now: u64) !void {
        if (self.initialized) return error.AlreadyInitialized;
        self.backend = backend;
        self.initialized = true;
        self.last_now = now;
        backend.set_enabled(backend.context, false) catch return error.NetworkUnavailable;
        self.transition(.disabled, .none);
    }
    pub fn status(self: *const Controller) wifi.Status {
        return .{ .state = self.state, .failure = self.failure, .simulated = self.initialized and self.backend.simulated, .revision = self.revision, .current = self.current };
    }
    pub fn startScan(self: *Controller, now: u64) !void {
        try self.ready(now);
        if (!self.enabled) return error.RadioDisabled;
        if (self.pending != .none or self.state == .connected) return error.Busy;
        if (!self.backend.capabilities.scan) return error.UnsupportedRadio;
        if (self.scan_generation == std.math.maxInt(u64)) return error.GenerationExhausted;
        const deadline = try until(now, scan_timeout_ticks);
        const operation = try self.issue();
        self.backend.start_scan(self.backend.context, operation) catch {
            self.backend.cancel(self.backend.context, operation) catch {};
            self.deviceFailed();
            return error.NetworkUnavailable;
        };
        self.cache = .{ .generation = 0, .count = 0, .entries = @splat(empty_bss) };
        self.working = @splat(empty_bss);
        self.working_count = 0;
        self.operation = operation;
        self.pending = .scan;
        self.deadline = deadline;
        self.transition(.scanning, .none);
    }
    /// Explicit cache read; no renewed operation or consumption on success.
    pub fn scan(self: *const Controller) !wifi.Scan {
        if (!self.initialized) return error.NetworkUnavailable;
        if (!self.enabled) return error.RadioDisabled;
        if (self.pending == .scan or self.cache.generation == 0) return error.WouldBlock;
        return self.cache;
    }
    pub fn join(self: *Controller, generation: u64, index: usize, credentials: *wifi.Credentials, now: u64) !void {
        defer credentials.clear();
        try credentials.validate();
        try self.ready(now);
        if (!self.enabled) return error.RadioDisabled;
        if (self.pending != .none or self.state == .connected) return error.Busy;
        if (generation == 0 or generation != self.cache.generation) return error.StaleScan;
        if (index >= self.cache.count) return error.InvalidSelection;
        const selected = self.cache.entries[index];
        try selected.validate();
        if (selected.ssid.len == 0) return error.HiddenSsid;
        switch (selected.security) {
            .open => {
                if (!self.backend.capabilities.open) return error.UnsupportedSecurity;
                if (credentials.len != 0) return error.InvalidCredentials;
            },
            .wpa2_personal => {
                if (!self.backend.capabilities.wpa2_psk) return error.UnsupportedSecurity;
                if (credentials.len < 8) return error.InvalidCredentials;
            },
            .wpa3_personal, .unsupported => return error.UnsupportedSecurity,
        }
        const deadline = try until(now, association_timeout_ticks);
        const operation = try self.issue();
        self.backend.start_join(self.backend.context, operation, selected, credentials.bytes[0..credentials.len]) catch {
            self.backend.cancel(self.backend.context, operation) catch {};
            self.deviceFailed();
            return error.NetworkUnavailable;
        };
        self.selected = selected;
        self.pending = .join;
        self.operation = operation;
        self.deadline = deadline;
        self.transition(.associating, .none);
    }
    pub fn setEnabled(self: *Controller, enable: bool, now: u64) !void {
        try self.ready(now);
        if (!enable) {
            const old = self.operation;
            self.invalidate();
            self.cache = .{ .generation = 0, .count = 0, .entries = @splat(empty_bss) };
            var failed = false;
            if (old != 0) self.backend.cancel(self.backend.context, old) catch {
                failed = true;
            };
            self.backend.disconnect(self.backend.context) catch {
                failed = true;
            };
            self.backend.set_enabled(self.backend.context, false) catch {
                failed = true;
            };
            self.enabled = false;
            if (failed) {
                self.transition(.failed, .device_lost);
                return error.NetworkUnavailable;
            }
            self.transition(.disabled, .none);
            return;
        }
        if (self.enabled) return;
        self.backend.set_enabled(self.backend.context, true) catch {
            self.deviceFailed();
            return error.NetworkUnavailable;
        };
        self.enabled = true;
        self.transition(.idle, .none);
    }
    pub fn disconnect(self: *Controller, now: u64) !void {
        try self.ready(now);
        const old = self.operation;
        self.invalidate();
        var failed = false;
        if (old != 0) self.backend.cancel(self.backend.context, old) catch {
            failed = true;
        };
        self.backend.disconnect(self.backend.context) catch {
            failed = true;
        };
        if (failed) {
            self.deviceFailed();
            return error.NetworkUnavailable;
        }
        self.transition(if (self.enabled) .idle else .disabled, .none);
    }
    pub fn poll(self: *Controller, now: u64) void {
        if (!self.initialized or !self.enabled) return;
        if (now < self.last_now) {
            self.deviceFailed();
            return;
        }
        self.last_now = now;
        if (self.pending != .none and now >= self.deadline) {
            const old = self.operation;
            self.invalidate();
            self.backend.cancel(self.backend.context, old) catch {
                self.deviceFailed();
                return;
            };
            self.backend.disconnect(self.backend.context) catch {
                self.deviceFailed();
                return;
            };
            self.transition(.failed, .timeout);
        }
        for (0..max_events_per_poll) |_| {
            const event = (self.backend.poll(self.backend.context) catch {
                self.deviceFailed();
                return;
            }) orelse return;
            self.handle(event);
            if (!self.enabled) return;
        }
    }
    fn handle(self: *Controller, event: Event) void {
        switch (event) {
            .link_lost => |lost| {
                if (lost.operation == 0 or lost.operation != self.link_operation or self.state != .connected) {
                    self.stale_events +|= 1;
                    return;
                }
                self.invalidate();
                self.transition(.idle, .none);
                return;
            },
            else => {},
        }
        const operation = switch (event) {
            inline else => |value| value.operation,
        };
        if (operation == 0 or operation != self.operation or self.pending == .none) {
            self.stale_events +|= 1;
            return;
        }
        switch (event) {
            .scan_result => |result| {
                if (self.pending != .scan) {
                    self.deviceFailed();
                    return;
                }
                result.bss.validate() catch {
                    self.deviceFailed();
                    return;
                };
                for (self.working[0..self.working_count]) |*prior| {
                    if (!std.mem.eql(u8, &prior.bssid, &result.bss.bssid)) continue;
                    if (prior.security != result.bss.security or prior.channel != result.bss.channel or prior.ssid.len != result.bss.ssid.len or
                        !std.mem.eql(u8, &prior.ssid.bytes, &result.bss.ssid.bytes))
                    {
                        self.deviceFailed();
                        return;
                    }
                    prior.signal_dbm = @max(prior.signal_dbm, result.bss.signal_dbm);
                    return;
                }
                if (self.working_count == self.working.len) {
                    // Real surveys can exceed our bounded cache. Keep the
                    // first16 unique BSSIDs and continue to scan completion.
                    self.dropped_scan_results +|= 1;
                    return;
                }
                self.working[self.working_count] = result.bss;
                self.working_count += 1;
            },
            .scan_complete => {
                if (self.pending != .scan) {
                    self.deviceFailed();
                    return;
                }
                self.scan_generation += 1;
                self.cache = .{ .generation = self.scan_generation, .count = self.working_count, .entries = self.working };
                self.invalidate();
                self.transition(.idle, .none);
            },
            .joined => |joined| {
                if (self.pending != .join) {
                    self.deviceFailed();
                    return;
                }
                const selected = self.selected orelse {
                    self.deviceFailed();
                    return;
                };
                if (!std.mem.eql(u8, &joined.bssid, &selected.bssid) or joined.security != selected.security or
                    (selected.security == .wpa2_personal and !joined.authenticated))
                {
                    self.invalidate();
                    self.backend.disconnect(self.backend.context) catch {
                        self.deviceFailed();
                        return;
                    };
                    self.transition(.failed, .authentication);
                    return;
                }
                self.invalidate();
                self.link_operation = operation;
                self.current = selected;
                self.transition(.connected, .none);
            },
            .failed => |failed| {
                const reason: wifi.Failure = if (failed.failure == .none) .device_lost else failed.failure;
                self.invalidate();
                self.backend.disconnect(self.backend.context) catch {
                    self.deviceFailed();
                    return;
                };
                if (reason == .device_lost) {
                    self.deviceFailed();
                    return;
                }
                self.transition(.failed, reason);
            },
            .link_lost => unreachable,
        }
    }
    fn invalidate(self: *Controller) void {
        self.pending = .none;
        self.operation = 0;
        self.link_operation = 0;
        self.deadline = 0;
        self.current = null;
        self.selected = null;
        self.working = @splat(empty_bss);
        self.working_count = 0;
    }
    fn deviceFailed(self: *Controller) void {
        const old = self.operation;
        self.invalidate();
        self.enabled = false;
        self.cache = .{ .generation = 0, .count = 0, .entries = @splat(empty_bss) };
        if (old != 0) self.backend.cancel(self.backend.context, old) catch {};
        self.backend.disconnect(self.backend.context) catch {};
        self.backend.set_enabled(self.backend.context, false) catch {};
        self.transition(.failed, .device_lost);
    }
    fn transition(self: *Controller, state: wifi.State, failure: wifi.Failure) void {
        self.state = state;
        self.failure = failure;
        self.revision +|= 1;
    }
    fn ready(self: *Controller, now: u64) !void {
        if (!self.initialized) return error.NetworkUnavailable;
        if (now < self.last_now) return error.ClockRegression;
        self.last_now = now;
    }
    fn issue(self: *Controller) !u64 {
        if (self.next_operation == 0) return error.OperationExhausted;
        const operation = self.next_operation;
        self.next_operation = if (operation == std.math.maxInt(u64)) 0 else operation + 1;
        return operation;
    }
};
fn until(now: u64, duration: u64) !u64 {
    const result = @addWithOverflow(now, duration);
    if (result[1] != 0) return error.TimeOverflow;
    return result[0];
}
test {
    _ = @import("wifi_tests.zig");
}
