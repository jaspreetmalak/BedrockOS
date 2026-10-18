//! Original station connection orchestration. Hardware hooks are synchronous,
//! trusted, serialized and must preserve raw MPDUs for software CCMP. Actual
//! association responses and an acknowledged M4 precede a connected event.
const std = @import("std");
const wifi = @import("networkkit").wifi;
const ieee = @import("ieee80211/root.zig");
const policy = @import("radio_policy.zig");
const rules = @import("regulatory/root.zig");
const hs = ieee.handshake;
const ccmp = ieee.ccmp;
pub const State = enum { empty, idle, authenticating, associating, handshake, await_final_tx, connected, failed, reset_required };
pub const Kind = enum { authentication, association, message2, message4, data };
pub const Event = union(enum) {
    joined: struct { operation: u64, bssid: [6]u8, security: wifi.Security, authenticated: bool },
    failed: struct { operation: u64, failure: wifi.Failure },
    link_lost: struct { operation: u64 },
};
pub const Hooks = struct {
    context: *anyopaque,
    /// Select a policy-approved channel and confirm firmware/NIC setup. Success
    /// cannot be synthesized from descriptor submission or a country lookup.
    prepare: *const fn (*anyopaque, rules.Request, u64, wifi.Bss, ieee.station.Rates) anyerror!void,
    /// Update the peer's actual association/AID and raw software-crypto mode.
    associated: *const fn (*anyopaque, u16) anyerror!void,
    /// Confirm the firmware peer's controlled-port state after security/M4.
    authorized: *const fn (*anyopaque) anyerror!void,
    /// Copy bytes into retained DMA storage; return a never-reused TX identity.
    /// Descriptor consumption alone must NOT be reported as acknowledged TX.
    transmit: *const fn (*anyopaque, []const u8, Kind) anyerror!u64,
    /// Stop/drain peer traffic and confirm cancellation before returning. A
    /// failed stop leaves the owner quarantined until a confirmed new reset.
    quiesce: *const fn (*anyopaque) anyerror!void,
    /// A real, cryptographically secure source; no clock/SSID seeded fallback.
    entropy: *const fn (*anyopaque, *[32]u8) anyerror!void,
};
pub const Config = struct { station_mac: [6]u8, device_epoch: u64, timeout_ticks: u64 = 1000 };
pub const Received = struct { device_epoch: u64, policy_generation: u64, channel: u16, frame: []const u8 };
pub const Completion = struct { device_epoch: u64, policy_generation: u64, ticket: u64, acknowledged: bool, now: u64 };
const Tx = struct { ticket: u64 = 0, kind: Kind = .data };
const snap_eapol = [_]u8{ 0xaa, 0xaa, 3, 0, 0, 0, 0x88, 0x8e };
const max_frame = 4096;
fn overlaps(a: usize, alen: usize, b: usize, blen: usize) bool {
    if (alen == 0 or blen == 0) return false;
    return if (a >= b) a - b < blen else b - a < alen;
}
fn validMac(mac: [6]u8) bool {
    return mac[0] & 1 == 0 and !std.mem.allEqual(u8, &mac, 0);
}

pub const Link = struct {
    owner_address: usize = 0,
    state: State = .empty,
    busy: bool = false,
    hooks: Hooks = undefined,
    authority: *const policy.Authority = undefined,
    config: Config = undefined,
    generation: u64 = 0,
    operation: u64 = 0,
    operation_highwater: u64 = 0,
    ticket_highwater: u64 = 0,
    sequence: u12 = 0,
    deadline: u64 = 0,
    last_now: u64 = 0,
    mac: ieee.station.MacSession = .{},
    handshake: hs.Station = .{},
    cipher: ccmp.Station = .{},
    ledger: [16]Tx = @splat(.{}),
    pending: ?Event = null,
    reported_connected: bool = false,
    frame: [max_frame]u8 = @splat(0),

    pub fn init(self: *Link, config: Config, authority: *const policy.Authority, hooks: Hooks) !void {
        if (self.owner_address != 0 or self.state != .empty) return error.AlreadyInitialized;
        if (!validMac(config.station_mac) or config.device_epoch == 0 or config.timeout_ticks == 0) return error.InvalidConfiguration;
        if (overlaps(@intFromPtr(self), @sizeOf(Link), @intFromPtr(authority), @sizeOf(policy.Authority))) return error.BufferOverlap;
        const snapshot = try authority.snapshot();
        if (snapshot.device_epoch != config.device_epoch) return error.StaleDeviceEpoch;
        self.config = config;
        self.authority = authority;
        self.hooks = hooks;
        self.owner_address = @intFromPtr(self);
        self.state = .idle;
    }
    fn owner(self: *Link) !void {
        if (self.owner_address == @intFromPtr(self)) return;
        // A moved copy must erase only its own secrets. Nested owners reject
        // their copies before any device callback can affect the live link.
        self.cipher.clear() catch {};
        self.handshake.abort() catch {};
        ieee.wpa2.clear(&self.frame);
        return error.InvalidOwner;
    }
    fn enter(self: *Link) !void {
        try self.owner();
        if (self.busy) return error.LinkBusy;
        if (self.state == .reset_required) return error.DeviceResetRequired;
        self.busy = true;
    }
    fn alias(self: *const Link, bytes: []const u8) bool {
        return overlaps(@intFromPtr(self), @sizeOf(Link), @intFromPtr(bytes.ptr), bytes.len) or
            overlaps(@intFromPtr(self.authority), @sizeOf(policy.Authority), @intFromPtr(bytes.ptr), bytes.len);
    }
    fn clock(self: *Link, now: u64) !void {
        if (now < self.last_now) return error.ClockRegression;
        self.last_now = now;
    }
    fn current(self: *const Link) !void {
        const snapshot = try self.authority.snapshot();
        if (snapshot.device_epoch != self.config.device_epoch) return error.StaleDeviceEpoch;
        if (snapshot.generation != self.generation) return error.StalePolicyGeneration;
    }
    fn request(self: *const Link) rules.Request {
        return .{ .band = if (self.mac.selected.channel <= 14) .ghz2 else .ghz5, .channel = self.mac.selected.channel };
    }
    fn permit(self: *const Link) !void {
        try self.current();
        const decision = try self.authority.decision(self.generation, self.request());
        if (!decision.allow_initiate_tx) return error.TransmissionDenied;
    }
    fn emit(self: *Link, bytes: []const u8, kind: Kind) !u64 {
        try self.permit();
        for (&self.ledger) |*entry| if (entry.ticket == 0) {
            const ticket = try self.hooks.transmit(self.hooks.context, bytes, kind);
            if (ticket == 0 or ticket <= self.ticket_highwater) return error.ReusedTxTicket;
            self.ticket_highwater = ticket;
            entry.* = .{ .ticket = ticket, .kind = kind };
            return ticket;
        };
        return error.WouldBlock;
    }
    fn nextSequence(self: *Link) u12 {
        const result = self.sequence;
        self.sequence +%= 1; // MAC sequence wrap is independent of CCMP PN.
        return result;
    }
    fn wipe(self: *Link) void {
        self.cipher.clear() catch {};
        ieee.wpa2.clear(&self.frame);
    }
    fn cleanup(self: *Link) !void {
        // Erase software keys even if the hardware cancellation fails.
        self.wipe();
        self.handshake.abort() catch {
            self.state = .reset_required;
            return error.DeviceResetRequired;
        };
        self.hooks.quiesce(self.hooks.context) catch {
            self.state = .reset_required;
            return error.DeviceResetRequired;
        };
        self.ledger = @splat(.{});
        self.mac.reset();
        self.deadline = 0;
    }
    fn fail(self: *Link, reason: wifi.Failure) void {
        const reported = self.reported_connected;
        self.cleanup() catch {};
        if (self.state != .reset_required) self.state = .failed;
        // A terminal event supersedes an undelivered join. The controller is
        // still associating until it consumes that join, so send failure then.
        self.pending = if (reported)
            .{ .link_lost = .{ .operation = self.operation } }
        else
            .{ .failed = .{ .operation = self.operation, .failure = reason } };
    }
    /// Raw passphrase is borrowed for this call and erased by its upstream
    /// credential owner. Only derived exchange material is retained.
    pub fn join(self: *Link, operation: u64, selected: wifi.Bss, rates: ieee.station.Rates, rsn_body: []const u8, passphrase: []const u8, now: u64) !void {
        try self.enter();
        defer self.busy = false;
        if (self.state != .idle and self.state != .failed) return error.InvalidState;
        if (self.pending != null) return error.PendingEvent;
        if (operation == 0 or operation <= self.operation_highwater) return error.ReusedOperation;
        if (self.alias(rsn_body) or self.alias(passphrase)) return error.BufferOverlap;
        try self.clock(now);
        const until = @addWithOverflow(now, self.config.timeout_ticks);
        if (until[1] != 0) return error.TimeOverflow;
        const snapshot = try self.authority.snapshot();
        if (snapshot.device_epoch != self.config.device_epoch) return error.StaleDeviceEpoch;
        var candidate: ieee.station.MacSession = .{};
        try candidate.start(selected, self.config.station_mac, rates, rsn_body);
        const req: rules.Request = .{ .band = if (selected.channel <= 14) .ghz2 else .ghz5, .channel = selected.channel };
        if (!(try self.authority.decision(snapshot.generation, req)).allow_initiate_tx) return error.TransmissionDenied;
        var pmk: [32]u8 = @splat(0);
        var snonce: [32]u8 = @splat(0);
        defer ieee.wpa2.clear(&pmk);
        defer ieee.wpa2.clear(&snonce);
        if (selected.security == .wpa2_personal) {
            try ieee.wpa2.derivePmk(passphrase, selected.ssid.bytes[0..selected.ssid.len], &pmk);
            try self.hooks.entropy(self.hooks.context, &snonce);
            if (std.mem.allEqual(u8, &snonce, 0)) return error.InvalidNonce;
        } else if (passphrase.len != 0) return error.InvalidCredentials;
        self.mac = candidate;
        self.operation = operation;
        self.reported_connected = false;
        self.operation_highwater = operation;
        self.generation = snapshot.generation;
        self.deadline = until[0];
        errdefer self.fail(.authentication);
        // Initialize security before any device traffic so entropy failure or
        // SNonce reuse cannot leave a half-created MAC association.
        if (selected.security == .wpa2_personal) try self.handshake.start(.{
            .selected = selected,
            .station_mac = self.config.station_mac,
            .snonce = &snonce,
            .pmk = &pmk,
            .ap_rsn_body = rsn_body,
        }, .{ .context = self, .install = install, .remove = remove });
        try self.hooks.prepare(self.hooks.context, req, self.generation, selected, rates);
        const size = try self.mac.authenticationRequest(self.nextSequence(), &self.frame);
        self.state = .authenticating;
        _ = try self.emit(self.frame[0..size], .authentication);
        ieee.wpa2.clear(&self.frame);
    }
    fn install(context: *anyopaque, keys: *const hs.InstalledKeys) !void {
        const self: *Link = @ptrCast(@alignCast(context));
        try self.owner();
        if (!self.busy or self.state != .handshake) return error.InvalidState;
        try self.permit();
        if (!std.mem.eql(u8, &keys.peer, &self.mac.selected.bssid) or !std.mem.eql(u8, &keys.station, &self.config.station_mac)) return error.WrongPeer;
        if (!std.mem.allEqual(u8, keys.receive_sequence[6..], 0)) return error.InvalidReceiveSequence;
        var pn: u64 = 0;
        for (keys.receive_sequence[0..6], 0..) |b, i| pn |= @as(u64, b) << @as(u6, @intCast(i * 8));
        // The initial backend uses software CCMP, with no device key-table
        // programming/decryption. NIC raw-mode setup remains a hardware hook.
        try self.cipher.init(.{ .peer = keys.peer, .station = keys.station, .epoch = self.operation, .pairwise = keys.pairwise, .group = .{ .id = keys.group_index, .key = keys.group, .rx_pn = pn } });
    }
    fn remove(context: *anyopaque, peer: [6]u8) !void {
        const self: *Link = @ptrCast(@alignCast(context));
        try self.owner();
        if (!std.mem.eql(u8, &peer, &self.mac.selected.bssid)) return error.WrongPeer;
        try self.cipher.clear();
    }
    fn eapolFrame(self: *Link, bytes: []const u8) !usize {
        if (bytes.len > self.frame.len - 32) return error.FrameTooLarge;
        @memset(self.frame[0 .. 32 + bytes.len], 0);
        std.mem.writeInt(u16, self.frame[0..2], 0x0108, .little);
        @memcpy(self.frame[4..10], &self.mac.selected.bssid);
        @memcpy(self.frame[10..16], &self.config.station_mac);
        @memcpy(self.frame[16..22], &self.mac.selected.bssid);
        std.mem.writeInt(u16, self.frame[22..24], @as(u16, self.nextSequence()) << 4, .little);
        @memcpy(self.frame[24..32], &snap_eapol);
        @memcpy(self.frame[32..][0..bytes.len], bytes);
        return 32 + bytes.len;
    }
    /// Received raw MPDUs have already passed the chipset's metadata/FCS checks.
    /// Peer/channel/epoch/policy matching and cryptographic validation are still
    /// mandatory here. Unrelated packets are ignored without changing state.
    pub fn ingest(self: *Link, received: Received, now: u64) !void {
        try self.enter();
        defer self.busy = false;
        if (self.alias(received.frame)) return error.BufferOverlap;
        if (received.device_epoch != self.config.device_epoch or received.policy_generation != self.generation) return error.StaleReceive;
        if (self.state == .idle or self.state == .failed) return error.InvalidState;
        self.clock(now) catch |err| {
            self.fail(.device_lost);
            return err;
        };
        self.current() catch |err| {
            self.fail(.device_lost);
            return err;
        };
        if (self.deadline != 0 and now >= self.deadline) {
            self.fail(.timeout);
            return error.ConnectionTimeout;
        }
        const bytes = received.frame;
        if (bytes.len < 24 or bytes.len > max_frame) return error.InvalidFrame;
        if (received.channel != self.mac.selected.channel or
            !std.mem.eql(u8, bytes[10..16], &self.mac.selected.bssid)) return error.WrongPeer;
        const fc = std.mem.readInt(u16, bytes[0..2], .little);
        if (fc & 0x00ff == 0xc0 or fc & 0x00ff == 0xa0) {
            if (bytes.len != 26 or fc & 0xc700 != 0 or
                !std.mem.eql(u8, bytes[4..10], &self.config.station_mac) or
                !std.mem.eql(u8, bytes[16..22], &self.mac.selected.bssid)) return error.InvalidFrame;
            self.fail(.authentication);
            return;
        }
        if (self.state == .authenticating) {
            if (fc & 0xff != 0xb0) return error.UnsupportedFrame;
            self.mac.ingestAuthentication(bytes) catch |err| {
                self.fail(.authentication);
                return err;
            };
            errdefer self.fail(.authentication);
            const size = try self.mac.associationRequest(self.nextSequence(), 10, &self.frame);
            self.state = .associating;
            _ = try self.emit(self.frame[0..size], .association);
            ieee.wpa2.clear(&self.frame);
            return;
        }
        if (self.state == .associating) {
            if (fc & 0xff != 0x10) return error.UnsupportedFrame;
            self.mac.ingestAssociation(bytes) catch |err| {
                self.fail(.authentication);
                return err;
            };
            errdefer self.fail(.device_lost);
            try self.hooks.associated(self.hooks.context, self.mac.association_id);
            if (self.mac.selected.security == .open) {
                self.state = .connected;
                self.deadline = 0;
                self.pending = .{ .joined = .{ .operation = self.operation, .bssid = self.mac.selected.bssid, .security = .open, .authenticated = false } };
            } else self.state = .handshake;
            return;
        }
        // Initial EAPOL exchanges use unprotected FromDS non-QoS raw frames.
        // Protected ordinary data is handled only by receiveEthernet below.
        if (fc != 0x0208 and fc != 0x0a08) return error.UnsupportedFrame;
        if (bytes.len < 32 or std.mem.readInt(u16, bytes[22..24], .little) & 15 != 0 or
            !std.mem.eql(u8, bytes[4..10], &self.config.station_mac) or
            !std.mem.eql(u8, bytes[16..22], &self.mac.selected.bssid) or
            !std.mem.eql(u8, bytes[24..32], &snap_eapol)) return error.UnsupportedFrame;
        if (self.mac.selected.security != .wpa2_personal) return error.UnsupportedSecurity;
        const prior = self.state;
        // Authenticated M3 retransmission after M4 submission uses the same keys.
        // The installer never runs a second time; the PN ledger is preserved.
        self.state = .handshake;
        const action = self.handshake.ingest(self.mac.selected.bssid, self.config.station_mac, bytes[32..]) catch |err| {
            self.fail(.authentication);
            return err;
        };
        errdefer self.fail(.authentication);
        const size = try self.eapolFrame(action.response.slice());
        _ = try self.emit(self.frame[0..size], if (action.message == .message4) .message4 else .message2);
        ieee.wpa2.clear(&self.frame);
        self.state = if (prior == .connected) .connected else if (action.keys_installed) .await_final_tx else .handshake;
    }
    pub fn completeTx(self: *Link, completion: Completion) !void {
        try self.enter();
        defer self.busy = false;
        if (completion.device_epoch != self.config.device_epoch or completion.policy_generation != self.generation) return error.StaleCompletion;
        self.current() catch |err| {
            self.fail(.device_lost);
            return err;
        };
        self.clock(completion.now) catch |err| {
            self.fail(.device_lost);
            return err;
        };
        if (self.deadline != 0 and completion.now >= self.deadline) {
            self.fail(.timeout);
            return error.ConnectionTimeout;
        }
        for (&self.ledger) |*entry| if (entry.ticket == completion.ticket and completion.ticket != 0) {
            const kind = entry.kind;
            entry.* = .{};
            if (!completion.acknowledged) {
                self.fail(.device_lost);
                return error.TransmissionFailed;
            }
            if (kind == .message4 and self.state == .await_final_tx and self.handshake.complete()) {
                self.hooks.authorized(self.hooks.context) catch |err| {
                    self.fail(.device_lost);
                    return err;
                };
                self.state = .connected;
                self.deadline = 0;
                self.pending = .{ .joined = .{ .operation = self.operation, .bssid = self.mac.selected.bssid, .security = .wpa2_personal, .authenticated = true } };
            }
            return;
        };
        return error.UnknownTxTicket;
    }
    /// TX_FREE is resource-release evidence, never an ACK. Only ordinary data
    /// can leave the Link ledger here; M4 still waits for actual TX status.
    pub fn releaseData(self: *Link, epoch: u64, generation: u64, ticket: u64) !bool {
        try self.enter();
        defer self.busy = false;
        if (epoch != self.config.device_epoch or generation != self.generation) return error.StaleCompletion;
        try self.current();
        for (&self.ledger) |*entry| if (entry.ticket == ticket and ticket != 0) {
            if (entry.kind != .data) return false;
            entry.* = .{};
            return true;
        };
        return false;
    }
    pub fn poll(self: *Link, now: u64) !void {
        try self.enter();
        defer self.busy = false;
        self.clock(now) catch |err| {
            self.fail(.device_lost);
            return err;
        };
        if (self.state == .idle or self.state == .failed) return;
        self.current() catch |err| {
            self.fail(.device_lost);
            return err;
        };
        if (self.deadline != 0 and now >= self.deadline) self.fail(.timeout);
    }
    pub fn takeEvent(self: *Link) !?Event {
        try self.owner();
        if (self.busy) return error.LinkBusy;
        const event = self.pending;
        self.pending = null;
        if (event) |value| if (value == .joined) {
            self.reported_connected = true;
        };
        return event;
    }
    pub fn sendEthernet(self: *Link, ethernet: []const u8) !u64 {
        try self.enter();
        defer self.busy = false;
        if (self.state != .connected) return error.LinkNotConnected;
        if (self.alias(ethernet)) return error.BufferOverlap;
        // Initial data profile is WPA2 only; open L2 data is not silently sent
        // through a crypto API or granted by an association event.
        if (self.mac.selected.security != .wpa2_personal) return error.UnsupportedSecurity;
        try self.permit();
        const size = try self.cipher.sealEthernet(ethernet, self.nextSequence(), &self.frame);
        defer ieee.wpa2.clear(&self.frame);
        return self.emit(self.frame[0..size], .data) catch |err| {
            if (err != error.WouldBlock) self.fail(.device_lost);
            return err;
        };
    }
    pub fn receiveEthernet(self: *Link, received: Received, output: []u8) !usize {
        try self.enter();
        defer self.busy = false;
        if (self.state != .connected) return error.LinkNotConnected;
        if (received.device_epoch != self.config.device_epoch or received.policy_generation != self.generation or received.channel != self.mac.selected.channel) return error.StaleReceive;
        if (self.alias(received.frame) or self.alias(output) or overlaps(@intFromPtr(output.ptr), output.len, @intFromPtr(received.frame.ptr), received.frame.len)) return error.BufferOverlap;
        try self.current();
        if (self.mac.selected.security != .wpa2_personal) return error.UnsupportedSecurity;
        return self.cipher.openEthernet(received.frame, output);
    }
    pub fn disconnect(self: *Link) !void {
        try self.enter();
        defer self.busy = false;
        try self.cleanup();
        self.pending = null;
        self.state = .idle;
        self.operation = 0;
        self.reported_connected = false;
    }
    pub fn deviceLost(self: *Link) !void {
        try self.enter();
        defer self.busy = false;
        self.fail(.device_lost);
    }
    /// Trusted caller only, after a real device reset and policy refresh. Old
    /// tickets remain retired; packet/exchange epochs cannot be rewound.
    pub fn afterDeviceReset(self: *Link, epoch: u64) !void {
        try self.owner();
        if (self.busy) return error.LinkBusy;
        if (epoch <= self.config.device_epoch) return error.StaleDeviceEpoch;
        self.busy = true;
        defer self.busy = false;
        self.wipe();
        self.state = .reset_required;
        const snapshot = try self.authority.snapshot();
        if (snapshot.device_epoch != epoch) return error.StaleDeviceEpoch;
        if (self.handshake.owner_address != 0) try self.handshake.resetAfterDeviceReset();
        self.mac.reset();
        self.ledger = @splat(.{});
        self.pending = null;
        self.config.device_epoch = epoch;
        self.generation = snapshot.generation;
        self.operation = 0;
        self.reported_connected = false;
        self.deadline = 0;
        self.state = .idle;
    }
};
test {
    _ = @import("station_link_tests.zig");
}
