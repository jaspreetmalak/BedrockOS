//! Original WPA2-PSK/CCMP four-way station control. complete means authenticated
//! M3 + confirmed device key installation, NOT a connected radio. The backend
//! still owns validated MAC association, M4 submission, DMA and link lifetime.
const std = @import("std");
const wifi = @import("networkkit").wifi;
const eapol = @import("eapol.zig");
const wpa2 = @import("wpa2.zig");
const rsn = @import("rsn.zig");
const keywrap = @import("keywrap.zig");
pub const State = enum { idle, await_message1, await_message3, complete, failed, reset_required };
pub const client_rsn = [_]u8{ 1, 0, 0, 15, 172, 4, 1, 0, 0, 15, 172, 4, 1, 0, 0, 15, 172, 2, 0, 0 };
pub const Config = struct { selected: wifi.Bss, station_mac: [6]u8, snonce: *const [32]u8, pmk: *const [32]u8, ap_rsn_body: []const u8 };
pub const InstalledKeys = struct { peer: [6]u8, station: [6]u8, pairwise: *const [16]u8, group: *const [16]u8, group_index: u2, receive_sequence: [8]u8 };
/// Borrowed keys are consumed synchronously; never retain their pointers. If
/// install partially fails, remove must confirm removal or the device requires
/// a reset. Initial install owns initial packet-number setup; retransmits never
/// call it and cannot reset an installed key's PN/replay state.
pub const Installer = struct { context: *anyopaque, install: *const fn (*anyopaque, *const InstalledKeys) anyerror!void, remove: *const fn (*anyopaque, [6]u8) anyerror!void };
pub const Response = struct {
    bytes: [121]u8 = @splat(0),
    length: usize = 0,
    pub fn slice(self: *const Response) []const u8 {
        return self.bytes[0..self.length];
    }
};
pub const Action = struct { response: Response, message: eapol.Message, keys_installed: bool, retransmission: bool = false };
pub const Error = eapol.Error || wpa2.Error || rsn.Error || keywrap.Error || error{ InvalidState, InvalidOwner, InvalidSelection, UnsupportedSecurity, WrongPeer, SecurityMismatch, InvalidKeyData, MissingGroupKey, KeyInstallFailed, DeviceResetRequired, NonceReuse };

fn hash(bytes: []const u8) [32]u8 {
    var result: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &result, .{});
    return result;
}
fn same(a: [32]u8, b: [32]u8) bool {
    return std.crypto.timing_safe.eql([32]u8, a, b);
}
fn messageIdentity(bytes: []const u8) [32]u8 {
    var context = std.crypto.hash.sha2.Sha256.init(.{});
    context.update(bytes[0..9]);
    context.update(&@as([8]u8, @splat(0))); // Replay counter.
    context.update(bytes[17..81]);
    context.update(&@as([16]u8, @splat(0))); // MIC.
    context.update(bytes[97..]);
    var result: [32]u8 = undefined;
    context.final(&result);
    return result;
}
fn macValid(mac: [6]u8) bool {
    return mac[0] & 1 == 0 and !std.mem.allEqual(u8, &mac, 0);
}
const Group = struct { key: [16]u8, index: u2 };

pub const Station = struct {
    owner_address: usize = 0,
    state: State = .idle,
    installer: Installer = undefined,
    peer: [6]u8 = @splat(0),
    station: [6]u8 = @splat(0),
    rsn_body: [255]u8 = @splat(0),
    rsn_length: usize = 0,
    snonce: [32]u8 = @splat(0),
    last_snonce: ?[32]u8 = null,
    anonce: [32]u8 = @splat(0),
    pmk: [32]u8 = @splat(0),
    ptk: [48]u8 = @splat(0),
    gtk: [16]u8 = @splat(0),
    confirmation_key: [16]u8 = @splat(0),
    counter: u64 = 0,
    first_hash: [32]u8 = @splat(0),
    first_identity: [32]u8 = @splat(0),
    third_hash: [32]u8 = @splat(0),
    third_identity: [32]u8 = @splat(0),
    second: Response = .{},
    fourth: Response = .{},
    keys_live: bool = false,

    pub fn start(self: *Station, config: Config, installer: Installer) Error!void {
        if (self.owner_address != 0) try self.requireOwner();
        if (self.state == .reset_required) return error.DeviceResetRequired;
        if (self.keys_live or (self.state != .idle and self.state != .failed)) return error.InvalidState;
        config.selected.validate() catch return error.InvalidSelection;
        if (config.selected.ssid.len == 0 or !macValid(config.station_mac) or std.mem.eql(u8, &config.station_mac, &config.selected.bssid)) return error.InvalidSelection;
        if (config.selected.security != .wpa2_personal or try rsn.classify(config.ap_rsn_body, true) != .wpa2_personal) return error.UnsupportedSecurity;
        if (std.mem.allEqual(u8, config.snonce, 0)) return error.InvalidNonce;
        if (self.last_snonce) |prior| if (same(prior, config.snonce.*)) return error.NonceReuse;
        const owned_start = @intFromPtr(self);
        const owned_end = @addWithOverflow(owned_start, @sizeOf(Station));
        for ([_][]const u8{ config.snonce, config.pmk, config.ap_rsn_body }) |input| {
            const input_base = @intFromPtr(input.ptr);
            const input_end = @addWithOverflow(input_base, input.len);
            if (owned_end[1] != 0 or input_end[1] != 0 or (owned_start < input_end[0] and input_base < owned_end[0])) return error.BufferOverlap;
        }
        self.clearSecrets();
        self.installer = installer;
        self.owner_address = @intFromPtr(self);
        self.peer = config.selected.bssid;
        self.station = config.station_mac;
        @memset(&self.rsn_body, 0);
        @memcpy(self.rsn_body[0..config.ap_rsn_body.len], config.ap_rsn_body);
        self.rsn_length = config.ap_rsn_body.len;
        self.snonce = config.snonce.*;
        self.last_snonce = config.snonce.*;
        self.pmk = config.pmk.*;
        self.counter = 0;
        self.first_hash = @splat(0);
        self.first_identity = @splat(0);
        self.third_hash = @splat(0);
        self.third_identity = @splat(0);
        self.second = .{};
        self.fourth = .{};
        self.state = .await_message1;
    }
    pub fn complete(self: *const Station) bool {
        return self.owner_address == @intFromPtr(self) and self.state == .complete and self.keys_live;
    }
    /// Source/destination are supplied by the validated L2 receive envelope.
    /// Unrelated peers fail without disturbing this association. Any matching
    /// peer's invalid exchange fails closed and erases transient key material.
    pub fn ingest(self: *Station, source: [6]u8, destination: [6]u8, bytes: []const u8) Error!Action {
        try self.requireOwner();
        if (!std.mem.eql(u8, &source, &self.peer) or !std.mem.eql(u8, &destination, &self.station)) return error.WrongPeer;
        if (self.state == .reset_required) return error.DeviceResetRequired;
        if (self.state == .idle or self.state == .failed) return error.InvalidState;
        return self.accept(bytes) catch |err| {
            self.fail() catch return error.DeviceResetRequired;
            return err;
        };
    }
    fn accept(self: *Station, bytes: []const u8) Error!Action {
        const key = try eapol.parse(bytes);
        const message = try key.message();
        const fingerprint = hash(bytes);
        if (self.state == .complete) {
            if (message != .message3 or key.replay_counter < self.counter) return error.ReplayDetected;
            if (!same(messageIdentity(bytes), self.third_identity)) return error.SecurityMismatch;
            try eapol.verifyMic(bytes, &self.confirmation_key);
            if (key.replay_counter == self.counter and !same(fingerprint, self.third_hash)) return error.ReplayDetected;
            // AP retransmissions may advance the counter. Only counter/MIC can
            // differ; key/nonce/RSC/security identity is unchanged. Never
            // reinstall or reset any hardware packet-number/replay state.
            self.fourth = try response(0x030a, bytes[0], key.replay_counter, @splat(0), &self.confirmation_key, null);
            self.counter = key.replay_counter;
            self.third_hash = fingerprint;
            return .{ .response = self.fourth, .message = .message4, .keys_installed = true, .retransmission = true };
        }
        if (message == .message1) {
            if (self.state == .await_message3) {
                if (key.replay_counter < self.counter or !same(messageIdentity(bytes), self.first_identity)) return error.ReplayDetected;
                if (key.replay_counter == std.math.maxInt(u64)) return error.ReplayCounterExhausted;
                if (key.replay_counter == self.counter and !same(fingerprint, self.first_hash)) return error.ReplayDetected;
                self.second = try response(0x010a, bytes[0], key.replay_counter, self.snonce, self.ptk[0..16], &client_rsn);
                self.counter = key.replay_counter;
                self.first_hash = fingerprint;
                return .{ .response = self.second, .message = .message2, .keys_installed = false, .retransmission = true };
            }
            if (self.state != .await_message1) return error.InvalidState;
            if (key.replay_counter == std.math.maxInt(u64)) return error.ReplayCounterExhausted;
            try wpa2.derivePtk(&self.pmk, self.peer, self.station, key.nonce, self.snonce, &self.ptk);
            self.anonce = key.nonce;
            self.counter = key.replay_counter;
            self.first_hash = fingerprint;
            self.first_identity = messageIdentity(bytes);
            self.second = try response(0x010a, bytes[0], self.counter, self.snonce, self.ptk[0..16], &client_rsn);
            self.state = .await_message3;
            return .{ .response = self.second, .message = .message2, .keys_installed = false };
        }
        if (self.state != .await_message3 or message != .message3) return error.InvalidState;
        if (key.replay_counter <= self.counter) return error.ReplayDetected;
        if (!same(key.nonce, self.anonce)) return error.NonceMismatch;
        try eapol.verifyMic(bytes, self.ptk[0..16]);
        if (!std.mem.allEqual(u8, bytes[71..73], 0)) return error.InvalidKeyData; // CCMP has a 48-bit receive PN.
        var plaintext: [keywrap.max_plaintext]u8 = undefined;
        defer wpa2.clear(&plaintext);
        const length = try keywrap.unwrap(self.ptk[16..32], key.data, &plaintext);
        var group = try self.groupData(plaintext[0..length]);
        defer wpa2.clear(&group.key);
        self.gtk = group.key;
        self.fourth = try response(0x030a, bytes[0], key.replay_counter, @splat(0), self.ptk[0..16], null);
        self.confirmation_key = self.ptk[0..16].*;
        const keys: InstalledKeys = .{ .peer = self.peer, .station = self.station, .pairwise = self.ptk[32..48], .group = &self.gtk, .group_index = group.index, .receive_sequence = bytes[65..73].* };
        self.keys_live = true; // Includes a possibly partial install failure.
        self.installer.install(self.installer.context, &keys) catch return error.KeyInstallFailed;
        self.counter = key.replay_counter;
        self.third_hash = fingerprint;
        self.third_identity = messageIdentity(bytes);
        self.state = .complete;
        self.clearSecrets();
        return .{ .response = self.fourth, .message = .message4, .keys_installed = true };
    }
    fn groupData(self: *const Station, bytes: []const u8) Error!Group {
        var at: usize = 0;
        var rsn_seen = false;
        var group: ?Group = null;
        defer if (group) |*value| wpa2.clear(&value.key);
        var count: usize = 0;
        while (at < bytes.len) {
            // AES key-data padding is 0xdd followed only by zeros. At an IE
            // boundary it cannot be interpreted as a second vendor element.
            if (bytes[at] == 0xdd and (at + 1 == bytes.len or bytes[at + 1] == 0)) {
                if (!std.mem.allEqual(u8, bytes[at + 1 ..], 0)) return error.InvalidKeyData;
                at = bytes.len;
                break;
            }
            if (bytes.len - at < 2) return error.InvalidKeyData;
            count += 1;
            if (count > 32) return error.InvalidKeyData;
            const id = bytes[at];
            const length: usize = bytes[at + 1];
            at += 2;
            if (length > bytes.len - at) return error.InvalidKeyData;
            const body = bytes[at..][0..length];
            at += length;
            switch (id) {
                48 => {
                    if (rsn_seen or !std.mem.eql(u8, body, self.rsn_body[0..self.rsn_length])) return error.SecurityMismatch;
                    if (try rsn.classify(body, true) != .wpa2_personal) return error.SecurityMismatch;
                    rsn_seen = true;
                },
                221 => {
                    if (group != null or length != 22 or !std.mem.eql(u8, body[0..4], &.{ 0, 15, 172, 1 }) or
                        body[4] & 0xfc != 0 or body[5] != 0 or std.mem.allEqual(u8, body[6..22], 0)) return error.InvalidKeyData;
                    group = .{ .key = body[6..22].*, .index = @intCast(body[4] & 3) };
                },
                else => return error.InvalidKeyData,
            }
        }
        if (!rsn_seen) return error.SecurityMismatch;
        return group orelse error.MissingGroupKey;
    }
    fn clearSecrets(self: *Station) void {
        wpa2.clear(&self.pmk);
        wpa2.clear(&self.ptk);
        wpa2.clear(&self.gtk);
        wpa2.clear(&self.snonce);
    }
    fn fail(self: *Station) Error!void {
        self.clearSecrets();
        wpa2.clear(&self.confirmation_key);
        wpa2.clear(std.mem.asBytes(&self.second));
        wpa2.clear(std.mem.asBytes(&self.fourth));
        if (self.keys_live) {
            self.installer.remove(self.installer.context, self.peer) catch {
                self.state = .reset_required;
                return error.DeviceResetRequired;
            };
            self.keys_live = false;
        }
        self.state = .failed;
    }
    /// A copied object never owns the original device keys. Erase only its
    /// copied secret records and reject; never call the original installer.
    fn requireOwner(self: *Station) Error!void {
        if (self.owner_address == @intFromPtr(self)) return;
        self.clearSecrets();
        wpa2.clear(&self.confirmation_key);
        wpa2.clear(std.mem.asBytes(&self.second));
        wpa2.clear(std.mem.asBytes(&self.fourth));
        self.keys_live = false;
        self.state = .failed;
        return error.InvalidOwner;
    }
    pub fn abort(self: *Station) Error!void {
        if (self.owner_address == 0 and self.state == .idle and !self.keys_live) {
            self.clearSecrets();
            return;
        }
        try self.requireOwner();
        if (self.state == .reset_required) return error.DeviceResetRequired;
        try self.fail();
        self.state = .idle;
    }
    /// Trusted backend only, after a confirmed full device reset removed keys.
    pub fn resetAfterDeviceReset(self: *Station) Error!void {
        try self.requireOwner();
        self.clearSecrets();
        wpa2.clear(&self.confirmation_key);
        wpa2.clear(std.mem.asBytes(&self.second));
        wpa2.clear(std.mem.asBytes(&self.fourth));
        self.keys_live = false;
        self.state = .idle;
    }
};

fn response(information: u16, version: u8, counter: u64, nonce: [32]u8, kck: *const [16]u8, rsn_body: ?[]const u8) Error!Response {
    var result: Response = .{};
    result.length = eapol.fixed_length;
    if (rsn_body) |body| {
        result.bytes[99] = 48;
        result.bytes[100] = @intCast(body.len);
        @memcpy(result.bytes[101..][0..body.len], body);
        result.length += 2 + body.len;
    }
    result.bytes[0] = version;
    result.bytes[1] = 3;
    result.bytes[4] = 2;
    std.mem.writeInt(u16, result.bytes[2..4], @intCast(result.length - 4), .big);
    std.mem.writeInt(u16, result.bytes[5..7], information, .big);
    std.mem.writeInt(u64, result.bytes[9..17], counter, .big);
    @memcpy(result.bytes[17..49], &nonce);
    std.mem.writeInt(u16, result.bytes[97..99], @intCast(result.length - 99), .big);
    var mic: [16]u8 = undefined;
    defer wpa2.clear(&mic);
    try eapol.calculateMic(result.slice(), kck, &mic);
    @memcpy(result.bytes[81..97], &mic);
    return result;
}
