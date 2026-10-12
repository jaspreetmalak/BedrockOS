//! Allocation-free radio control. Providers own authorization and hardware.
//! No credential is retained in status, scan, or Radio. Access is serialized.
const std = @import("std");
pub const max_scan_results = 16;

pub const Ssid = struct {
    bytes: [32]u8 = @splat(0),
    len: u8 = 0,

    /// SSIDs are binary. An empty hidden result uses .{}, not this constructor.
    pub fn init(input: []const u8) !Ssid {
        if (input.len == 0 or input.len > 32) return error.InvalidSsid;
        var result: Ssid = .{ .len = @intCast(input.len) };
        @memcpy(result.bytes[0..input.len], input);
        return result;
    }

    pub fn validate(self: *const Ssid) !void {
        if (self.len > self.bytes.len) return error.InvalidSsid;
        for (self.bytes[self.len..]) |byte| if (byte != 0) return error.InvalidSsid;
    }

    /// Borrowed only while this SSID remains alive and unchanged.
    pub fn slice(self: *const Ssid) ![]const u8 {
        try self.validate();
        return self.bytes[0..self.len];
    }
};

pub const Security = enum(u8) { open, wpa2_personal, wpa3_personal, unsupported };
pub const Bss = struct {
    ssid: Ssid,
    bssid: [6]u8,
    channel: u16,
    signal_dbm: i16,
    security: Security,

    pub fn validate(self: *const Bss) !void {
        try self.ssid.validate();
        if (self.bssid[0] & 1 != 0 or std.mem.eql(u8, &self.bssid, &@as([6]u8, @splat(0)))) return error.InvalidBss;
        if (self.channel < 1 or self.channel > 233 or self.signal_dbm < -127 or self.signal_dbm > 0) return error.InvalidBss;
    }
};

pub const Scan = struct {
    generation: u64,
    count: usize,
    entries: [max_scan_results]Bss,

    /// Unused entries are not inspected or exposed as discovered results.
    pub fn validate(self: *const Scan) !void {
        if (self.generation == 0 or self.count > max_scan_results) return error.InvalidScan;
        for (self.entries[0..self.count], 0..) |*entry, index| {
            try entry.validate();
            for (self.entries[0..index]) |*previous| {
                if (std.mem.eql(u8, &previous.bssid, &entry.bssid)) return error.InvalidScan;
            }
        }
    }
};

pub const Credentials = struct {
    bytes: [63]u8 = @splat(0),
    len: u8 = 0,

    /// First profile: printable ASCII WPA2 passphrases, not raw hexadecimal PSKs.
    /// Open networks use .{} and no secret bytes.
    pub fn init(passphrase: []const u8) !Credentials {
        if (passphrase.len < 8 or passphrase.len > 63) return error.InvalidCredentials;
        for (passphrase) |byte| if (byte < 32 or byte > 126) return error.InvalidCredentials;
        var result: Credentials = .{ .len = @intCast(passphrase.len) };
        @memcpy(result.bytes[0..passphrase.len], passphrase);
        return result;
    }

    pub fn validate(self: *const Credentials) !void {
        if (self.len > self.bytes.len or self.len != 0 and self.len < 8) return error.InvalidCredentials;
        for (self.bytes[0..self.len]) |byte| if (byte < 32 or byte > 126) return error.InvalidCredentials;
        for (self.bytes[self.len..]) |byte| if (byte != 0) return error.InvalidCredentials;
    }

    pub fn clear(self: *Credentials) void {
        const output: [*]volatile u8 = @ptrCast(&self.bytes);
        for (0..self.bytes.len) |index| output[index] = 0;
        const length: *volatile u8 = &self.len;
        length.* = 0;
    }
};

pub const State = enum(u8) { unavailable, disabled, idle, scanning, associating, connected, failed };
pub const Failure = enum(u8) { none, authentication, timeout, device_lost };
pub const Status = struct {
    state: State,
    failure: Failure,
    simulated: bool,
    revision: u64,
    current: ?Bss,

    pub fn validate(self: *const Status) !void {
        if (self.revision == 0) return error.InvalidStatus;
        if (self.state == .failed) {
            if (self.failure == .none) return error.InvalidStatus;
        } else if (self.failure != .none) return error.InvalidStatus;
        if (self.state == .connected) {
            const current = if (self.current) |*value| value else return error.InvalidStatus;
            try current.validate();
        } else if (self.current != null) return error.InvalidStatus;
    }
};

pub const Provider = struct {
    context: *anyopaque,
    status: *const fn (*anyopaque) anyerror!Status,
    startScan: *const fn (*anyopaque) anyerror!void,
    /// Read the committed cache. Return WouldBlock while a requested scan is
    /// pending or no cache exists. Reads never start another scan implicitly.
    scan: *const fn (*anyopaque) anyerror!Scan,
    /// Borrow the validated secret synchronously; never retain it or its pointer.
    join: *const fn (*anyopaque, u64, usize, *const Credentials) anyerror!void,
    disconnect: *const fn (*anyopaque) anyerror!void,
    setEnabled: *const fn (*anyopaque, bool) anyerror!void,
};

pub const Radio = struct {
    provider: Provider,
    last_scan: ?Scan = null,

    pub fn init(provider: Provider) Radio {
        return .{ .provider = provider };
    }

    pub fn status(self: *Radio) !Status {
        const result = try self.provider.status(self.provider.context);
        try result.validate();
        return result;
    }

    pub fn startScan(self: *Radio) !void {
        try self.provider.startScan(self.provider.context);
        self.last_scan = null;
    }

    pub fn scan(self: *Radio) !Scan {
        const result = try self.provider.scan(self.provider.context);
        try result.validate();
        self.last_scan = result;
        return result;
    }

    /// Clear the complete caller-owned credential buffer on EVERY return,
    /// including failed preflight and provider errors. No automatic retries.
    pub fn join(self: *Radio, generation: u64, index: usize, credentials: *Credentials) !void {
        defer credentials.clear();
        try credentials.validate();
        const snapshot = if (self.last_scan) |*value| value else return error.NoScan;
        try snapshot.validate();
        if (generation == 0 or generation != snapshot.generation) return error.StaleScan;
        if (index >= snapshot.count) return error.InvalidSelection;
        const selected = &snapshot.entries[index];
        if (selected.ssid.len == 0) return error.HiddenSsid;
        switch (selected.security) {
            .open => if (credentials.len != 0) return error.InvalidCredentials,
            .wpa2_personal => if (credentials.len < 8) return error.InvalidCredentials,
            .wpa3_personal, .unsupported => return error.UnsupportedSecurity,
        }
        try self.provider.join(self.provider.context, generation, index, credentials);
    }

    pub fn disconnect(self: *Radio) !void {
        try self.provider.disconnect(self.provider.context);
    }

    pub fn setEnabled(self: *Radio, enabled: bool) !void {
        try self.provider.setEnabled(self.provider.context, enabled);
        if (!enabled) self.last_scan = null;
    }
};

test {
    _ = @import("wifi_tests.zig");
}
