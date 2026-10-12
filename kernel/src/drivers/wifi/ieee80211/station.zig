//! Bounded Open System Authentication + infrastructure Association management
//! control. associated means matching MAC responses only, never WPA completion
//! or proof that a physical device can transmit encrypted data.
const std = @import("std");
const wifi = @import("networkkit").wifi;
const rsn = @import("rsn.zig");
const handshake = @import("handshake.zig");
pub const State = enum { idle, ready, authenticating, authenticated, associating, associated, failed };
pub const Error = rsn.Error || error{ InvalidSelection, UnsupportedSecurity, InvalidRates, InvalidState, BufferTooSmall, InvalidSequence, WrongPeer, InvalidFrame, UnsupportedFrame, AuthenticationDenied, AssociationDenied, SecurityMismatch };
pub const max_response_bytes = 4096;
pub const Rates = struct {
    bytes: [8]u8 = @splat(0),
    length: u8,
    /// Driver supplies a supported negotiated rate set. No PHY/channel/rate
    /// support is guessed by this serializer, and zero/duplicate rates fail.
    pub fn validate(self: *const Rates) Error!void {
        if (self.length == 0 or self.length > 8) return error.InvalidRates;
        for (self.bytes[0..self.length], 0..) |value, i| {
            if (value & 0x7f == 0) return error.InvalidRates;
            for (self.bytes[0..i]) |prior| if (prior & 0x7f == value & 0x7f) return error.InvalidRates;
        }
        for (self.bytes[self.length..]) |value| if (value != 0) return error.InvalidRates;
    }
};
fn validMac(value: [6]u8) bool {
    return value[0] & 1 == 0 and !std.mem.allEqual(u8, &value, 0);
}
fn header(output: []u8, subtype: u8, peer: [6]u8, station: [6]u8, sequence: u16) Error!void {
    if (sequence > 4095) return error.InvalidSequence;
    @memset(output, 0);
    output[0] = subtype;
    @memcpy(output[4..10], &peer);
    @memcpy(output[10..16], &station);
    @memcpy(output[16..22], &peer);
    std.mem.writeInt(u16, output[22..24], sequence << 4, .little);
}
pub const MacSession = struct {
    state: State = .idle,
    selected: wifi.Bss = undefined,
    station: [6]u8 = @splat(0),
    rates: Rates = undefined,
    ap_rsn: [255]u8 = @splat(0),
    ap_rsn_length: usize = 0,
    association_id: u16 = 0,
    pub fn start(self: *MacSession, selected: wifi.Bss, station_mac: [6]u8, rates: Rates, ap_rsn_body: []const u8) Error!void {
        if (self.state != .idle and self.state != .failed) return error.InvalidState;
        selected.validate() catch return error.InvalidSelection;
        if (selected.ssid.len == 0 or !validMac(station_mac) or std.mem.eql(u8, &station_mac, &selected.bssid)) return error.InvalidSelection;
        try rates.validate();
        switch (selected.security) {
            .open => if (ap_rsn_body.len != 0) return error.SecurityMismatch,
            .wpa2_personal => if (try rsn.classify(ap_rsn_body, true) != .wpa2_personal) return error.UnsupportedSecurity,
            else => return error.UnsupportedSecurity,
        }
        self.selected = selected;
        self.station = station_mac;
        self.rates = rates;
        self.ap_rsn_length = ap_rsn_body.len;
        // The caller keeps no borrowed frame/IE pointers in this session.
        var copied: [255]u8 = @splat(0);
        @memcpy(copied[0..ap_rsn_body.len], ap_rsn_body);
        self.ap_rsn = copied;
        self.association_id = 0;
        self.state = .ready;
    }
    pub fn authenticationRequest(self: *MacSession, sequence: u16, output: []u8) Error!usize {
        if (self.state != .ready and self.state != .authenticating) return error.InvalidState;
        if (output.len < 30) return error.BufferTooSmall;
        try header(output[0..30], 0xb0, self.selected.bssid, self.station, sequence);
        std.mem.writeInt(u16, output[26..28], 1, .little); // Open System, transaction1, status0.
        self.state = .authenticating;
        return 30;
    }
    fn validateHeader(self: *const MacSession, bytes: []const u8, subtype: u8) Error!void {
        if (bytes.len < 30 or bytes.len > max_response_bytes) return error.InvalidFrame;
        const control = std.mem.readInt(u16, bytes[0..2], .little);
        if (control & 0x00ff != subtype or control & 0xc700 != 0 or std.mem.readInt(u16, bytes[22..24], .little) & 15 != 0) return error.UnsupportedFrame;
        if (!std.mem.eql(u8, bytes[4..10], &self.station) or !std.mem.eql(u8, bytes[10..16], &self.selected.bssid) or !std.mem.eql(u8, bytes[16..22], &self.selected.bssid)) return error.WrongPeer;
    }
    pub fn ingestAuthentication(self: *MacSession, bytes: []const u8) Error!void {
        if (self.state != .authenticating) return error.InvalidState;
        try self.validateHeader(bytes, 0xb0);
        if (bytes.len != 30 or std.mem.readInt(u16, bytes[24..26], .little) != 0 or std.mem.readInt(u16, bytes[26..28], .little) != 2) return error.UnsupportedFrame;
        if (std.mem.readInt(u16, bytes[28..30], .little) != 0) {
            self.state = .failed;
            return error.AuthenticationDenied;
        }
        self.state = .authenticated;
    }
    pub fn associationRequest(self: *MacSession, sequence: u16, listen_interval: u16, output: []u8) Error!usize {
        if (self.state != .authenticated and self.state != .associating) return error.InvalidState;
        if (listen_interval == 0) return error.InvalidFrame;
        const protected = self.selected.security == .wpa2_personal;
        const length = 28 + 2 + @as(usize, self.selected.ssid.len) + 2 + self.rates.length + (if (protected) @as(usize, 22) else 0);
        if (output.len < length) return error.BufferTooSmall;
        try header(output[0..length], 0, self.selected.bssid, self.station, sequence);
        std.mem.writeInt(u16, output[24..26], if (protected) 0x11 else 1, .little);
        std.mem.writeInt(u16, output[26..28], listen_interval, .little);
        var at: usize = 28;
        output[at] = 0;
        output[at + 1] = self.selected.ssid.len;
        @memcpy(output[at + 2 ..][0..self.selected.ssid.len], self.selected.ssid.bytes[0..self.selected.ssid.len]);
        at += 2 + self.selected.ssid.len;
        output[at] = 1;
        output[at + 1] = self.rates.length;
        @memcpy(output[at + 2 ..][0..self.rates.length], self.rates.bytes[0..self.rates.length]);
        at += 2 + self.rates.length;
        if (protected) {
            output[at] = 48;
            output[at + 1] = 20;
            @memcpy(output[at + 2 ..][0..20], &handshake.client_rsn);
        }
        self.state = .associating;
        return length;
    }
    pub fn ingestAssociation(self: *MacSession, bytes: []const u8) Error!void {
        if (self.state != .associating) return error.InvalidState;
        try self.validateHeader(bytes, 0x10);
        const status = std.mem.readInt(u16, bytes[26..28], .little);
        if (status != 0) {
            self.state = .failed;
            return error.AssociationDenied;
        }
        const capabilities = std.mem.readInt(u16, bytes[24..26], .little);
        if (capabilities & 3 != 1 or (capabilities & 0x10 != 0) != (self.selected.security == .wpa2_personal)) return error.SecurityMismatch;
        const aid = std.mem.readInt(u16, bytes[28..30], .little);
        if (aid & 0xc000 != 0xc000 or aid & 0x3fff == 0 or aid & 0x3fff > 2007) return error.InvalidFrame;
        var at: usize = 30;
        var seen = false;
        var count: usize = 0;
        while (at < bytes.len) {
            if (bytes.len - at < 2) return error.InvalidFrame;
            count += 1;
            if (count > 256) return error.InvalidFrame;
            const id = bytes[at];
            const length: usize = bytes[at + 1];
            at += 2;
            if (length > bytes.len - at) return error.InvalidFrame;
            const body = bytes[at..][0..length];
            at += length;
            if (id == 48) {
                if (seen or self.selected.security != .wpa2_personal or !std.mem.eql(u8, body, self.ap_rsn[0..self.ap_rsn_length])) return error.SecurityMismatch;
                seen = true;
            } else if (id == 244 or (id == 221 and body.len >= 4 and std.mem.eql(u8, body[0..4], &.{ 0, 0x50, 0xf2, 1 }))) return error.UnsupportedSecurity;
        }
        self.association_id = aid & 0x3fff;
        self.state = .associated;
    }
    pub fn reset(self: *MacSession) void {
        self.state = .idle;
        self.association_id = 0;
    }
};
