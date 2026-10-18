//! Software protocol acceptance only. Device/entropy fixtures never touch RF.
const std = @import("std");
const t = std.testing;
const link = @import("station_link.zig");
const ieee = @import("ieee80211/root.zig");
const rules = @import("regulatory/root.zig");
const policy = @import("radio_policy.zig");
const wifi = @import("networkkit").wifi;
const ap: [6]u8 = .{ 2, 1, 2, 3, 4, 5 };
const station: [6]u8 = .{ 2, 6, 7, 8, 9, 10 };
const rates: ieee.station.Rates = .{ .bytes = .{ 0x82, 0x84, 0x8b, 0x96, 0, 0, 0, 0 }, .length = 4 };
const password = "fixture-secret-only";
const cap: rules.ChannelCap = .{ .band = .ghz2, .channel = 6, .center_khz = 2_437_000, .available_rx = true, .calibrated = true, .max_conducted_power_mbm = 1500, .antenna_gain_mbi = 0 };
fn bss() wifi.Bss {
    return .{ .ssid = wifi.Ssid.init("StationFixture") catch unreachable, .bssid = ap, .channel = 6, .signal_dbm = -40, .security = .wpa2_personal };
}
const Device = struct {
    count: usize = 0,
    kinds: [32]link.Kind = @splat(.data),
    frames: [32][512]u8 = @splat(@splat(0)),
    lengths: [32]usize = @splat(0),
    preparations: usize = 0,
    associated_count: usize = 0,
    stops: usize = 0,
    next_ticket: u64 = 1,
    fail_stop: bool = false,
    bad_nonce: bool = false,
    backpressure: bool = false,
    reentrant: ?*link.Link = null,
    fn cast(p: *anyopaque) *Device {
        return @ptrCast(@alignCast(p));
    }
    fn hooks(self: *Device) link.Hooks {
        return .{ .context = self, .prepare = prepare, .associated = associated, .authorized = authorized, .transmit = transmit, .quiesce = quiesce, .entropy = entropy };
    }
    fn prepare(p: *anyopaque, request: rules.Request, generation: u64, selected: wifi.Bss, _: ieee.station.Rates) !void {
        const self = cast(p);
        try t.expectEqual(@as(u16, 6), request.channel);
        try t.expect(generation != 0 and std.mem.eql(u8, &selected.bssid, &ap));
        self.preparations += 1;
    }
    fn associated(p: *anyopaque, aid: u16) !void {
        try t.expectEqual(@as(u16, 7), aid);
        cast(p).associated_count += 1;
    }
    fn authorized(_: *anyopaque) !void {}
    fn transmit(p: *anyopaque, bytes: []const u8, kind: link.Kind) !u64 {
        const self = cast(p);
        if (self.backpressure) return error.WouldBlock;
        if (self.reentrant) |owner| try t.expectError(error.LinkBusy, owner.disconnect());
        if (bytes.len > 512 or self.count >= 32) return error.WouldBlock;
        @memcpy(self.frames[self.count][0..bytes.len], bytes);
        self.lengths[self.count] = bytes.len;
        self.kinds[self.count] = kind;
        self.count += 1;
        const ticket = self.next_ticket;
        self.next_ticket += 1;
        return ticket;
    }
    fn quiesce(p: *anyopaque) !void {
        const self = cast(p);
        self.stops += 1;
        if (self.fail_stop) return error.StopFailed;
    }
    fn entropy(p: *anyopaque, out: *[32]u8) !void {
        out.* = @splat(if (cast(p).bad_nonce) 0 else 0x22);
    }
};
fn init(owner: *link.Link, authority: *policy.Authority, device: *Device, country: bool) !void {
    try authority.init(1, &.{cap});
    if (country) _ = try authority.select(.{ 'U', 'S' }, .indoor);
    try owner.init(.{ .station_mac = station, .device_epoch = 1 }, authority, device.hooks());
}
fn join(owner: *link.Link) !void {
    try owner.join(1, bss(), rates, &ieee.handshake.client_rsn, password, 0);
}
fn receive(owner: *link.Link, frame: []const u8, now: u64) !void {
    try owner.ingest(.{ .device_epoch = 1, .policy_generation = owner.generation, .channel = 6, .frame = frame }, now);
}
fn complete(owner: *link.Link, ticket: u64, ack: bool) !void {
    try owner.completeTx(.{ .device_epoch = 1, .policy_generation = owner.generation, .ticket = ticket, .acknowledged = ack, .now = owner.last_now });
}
fn response(subtype: u8, protected: bool) [30]u8 {
    var out: [30]u8 = @splat(0);
    out[0] = subtype;
    @memcpy(out[4..10], &station);
    @memcpy(out[10..16], &ap);
    @memcpy(out[16..22], &ap);
    if (subtype == 0xb0) std.mem.writeInt(u16, out[26..28], 2, .little) else {
        std.mem.writeInt(u16, out[24..26], if (protected) 0x11 else 1, .little);
        std.mem.writeInt(u16, out[28..30], 0xc007, .little);
    }
    return out;
}
fn associate(owner: *link.Link) !void {
    try join(owner);
    try complete(owner, 1, true);
    var auth = response(0xb0, false);
    try receive(owner, &auth, 1);
    try complete(owner, 2, true);
    var assoc = response(0x10, true);
    try receive(owner, &assoc, 2);
}
const KeyFrame = struct {
    bytes: [512]u8 = @splat(0),
    length: usize = 131,
    fn slice(self: *const KeyFrame) []const u8 {
        return self.bytes[0..self.length];
    }
    fn message(information: u16, counter: u64) KeyFrame {
        var out: KeyFrame = .{};
        std.mem.writeInt(u16, out.bytes[0..2], 0x0208, .little);
        @memcpy(out.bytes[4..10], &station);
        @memcpy(out.bytes[10..16], &ap);
        @memcpy(out.bytes[16..22], &ap);
        @memcpy(out.bytes[24..32], &@as([8]u8, .{ 0xaa, 0xaa, 3, 0, 0, 0, 0x88, 0x8e }));
        const body = out.bytes[32..];
        body[0] = 2;
        body[1] = 3;
        body[4] = 2;
        std.mem.writeInt(u16, body[2..4], 95, .big);
        std.mem.writeInt(u16, body[5..7], information, .big);
        std.mem.writeInt(u16, body[7..9], 16, .big);
        std.mem.writeInt(u64, body[9..17], counter, .big);
        @memset(body[17..49], 0x44);
        return out;
    }
};
fn derive() ![48]u8 {
    var pmk: [32]u8 = undefined;
    defer ieee.wpa2.clear(&pmk);
    var ptk: [48]u8 = undefined;
    try ieee.wpa2.derivePmk(password, "StationFixture", &pmk);
    try ieee.wpa2.derivePtk(&pmk, ap, station, @splat(0x44), @splat(0x22), &ptk);
    return ptk;
}
fn third() !KeyFrame {
    var ptk = try derive();
    defer ieee.wpa2.clear(&ptk);
    var data: [48]u8 = @splat(0);
    data[0] = 48;
    data[1] = 20;
    @memcpy(data[2..22], &ieee.handshake.client_rsn);
    data[22] = 221;
    data[23] = 22;
    @memcpy(data[24..28], &@as([4]u8, .{ 0, 15, 172, 1 }));
    data[28] = 1;
    @memset(data[30..46], 0x66);
    data[46] = 221;
    var out = KeyFrame.message(0x13ca, 6);
    const body = out.bytes[32..];
    const count = try ieee.keywrap.wrap(ptk[16..32], &data, body[99..]);
    out.length = 131 + count;
    std.mem.writeInt(u16, body[2..4], @intCast(out.length - 36), .big);
    std.mem.writeInt(u16, body[97..99], @intCast(count), .big);
    body[65] = 7;
    var tag: [16]u8 = undefined;
    try ieee.eapol.calculateMic(body[0 .. out.length - 32], ptk[0..16], &tag);
    @memcpy(body[81..97], &tag);
    return out;
}
fn handshake(owner: *link.Link, device: *Device) !void {
    try associate(owner);
    var first = KeyFrame.message(0x8a, 5);
    try receive(owner, first.slice(), 3);
    try t.expectEqual(link.Kind.message2, device.kinds[2]);
    var ptk = try derive();
    defer ieee.wpa2.clear(&ptk);
    try ieee.eapol.verifyMic(device.frames[2][32..device.lengths[2]], ptk[0..16]);
    try complete(owner, 3, true);
    var m3 = try third();
    try receive(owner, m3.slice(), 4);
}
test "station connection waits for authenticated M3 and actual M4 acknowledgment before data" {
    var authority: policy.Authority = .{};
    var device: Device = .{};
    var owner: link.Link = .{};
    try init(&owner, &authority, &device, true);
    device.reentrant = &owner;
    try handshake(&owner, &device);
    try t.expectEqual(link.State.await_final_tx, owner.state);
    try t.expect((try owner.takeEvent()) == null);
    try t.expectError(error.LinkNotConnected, owner.sendEthernet(&.{}));
    try t.expectEqual(link.Kind.message4, device.kinds[3]);
    try complete(&owner, 4, true);
    const event = (try owner.takeEvent()).?;
    try t.expectEqual(@as(u64, 1), event.joined.operation);
    try t.expect(event.joined.authenticated);
    var ethernet: [60]u8 = @splat(0);
    @memcpy(ethernet[0..6], &ap);
    @memcpy(ethernet[6..12], &station);
    ethernet[12] = 8;
    const ticket = try owner.sendEthernet(&ethernet);
    try t.expectEqual(@as(u64, 5), ticket);
    try t.expectEqual(@as(u64, 1), owner.cipher.tx_pn);
    try t.expect(device.frames[4][1] & 0x40 != 0);
    var m3 = try third();
    try receive(&owner, m3.slice(), 5);
    try t.expectEqual(@as(u64, 1), owner.cipher.tx_pn);
    try t.expectEqual(link.State.connected, owner.state);
    try t.expect((try owner.takeEvent()) == null);
    try owner.disconnect();
    try t.expect(std.mem.allEqual(u8, &owner.cipher.pairwise_key, 0));
    try t.expect(std.mem.allEqual(u8, &owner.handshake.confirmation_key, 0));
}
test "station encrypted ingress rejects spoofing MIC corruption and replay without publishing bytes" {
    var authority: policy.Authority = .{};
    var device: Device = .{};
    var owner: link.Link = .{};
    try init(&owner, &authority, &device, true);
    try handshake(&owner, &device);
    try complete(&owner, 4, true);
    _ = try owner.takeEvent();
    var ethernet: [60]u8 = @splat(0);
    @memcpy(ethernet[0..6], &station);
    @memcpy(ethernet[6..12], &ap);
    ethernet[12] = 8;
    var plaintext: [100]u8 = undefined;
    const plen = try ieee.ccmp.encodeEthernet(&ethernet, &plaintext);
    var ptk = try derive();
    defer ieee.wpa2.clear(&ptk);
    var frame: [128]u8 = undefined;
    const length = try ieee.ccmp.seal(ptk[32..48], .{ .direction = .from_ds, .receiver = station, .transmitter = ap, .address3 = ap }, 1, 0, plaintext[0..plen], &frame);
    const incoming: link.Received = .{ .device_epoch = 1, .policy_generation = owner.generation, .channel = 6, .frame = frame[0..length] };
    var output: [100]u8 = @splat(0xa5);
    frame[length - 1] ^= 1;
    if (owner.receiveEthernet(incoming, &output)) |_| return error.ExpectedAuthenticationFailure else |_| {}
    try t.expect(std.mem.allEqual(u8, &output, 0xa5));
    frame[length - 1] ^= 1;
    try t.expectEqual(@as(usize, 60), try owner.receiveEthernet(incoming, &output));
    try t.expectEqualSlices(u8, &ethernet, output[0..60]);
    output = @splat(0xa5);
    try t.expectError(error.ReplayDetected, owner.receiveEthernet(incoming, &output));
    try t.expect(std.mem.allEqual(u8, &output, 0xa5));
}
test "station world policy and invalid entropy prevent radio preparation" {
    var authority: policy.Authority = .{};
    var device: Device = .{};
    var owner: link.Link = .{};
    try init(&owner, &authority, &device, false);
    try t.expectError(error.TransmissionDenied, join(&owner));
    try t.expectEqual(@as(usize, 0), device.preparations);
    _ = try authority.select(.{ 'U', 'S' }, .indoor);
    device.bad_nonce = true;
    try t.expectError(error.InvalidNonce, join(&owner));
    try t.expectEqual(@as(usize, 0), device.preparations);
    try t.expectEqual(@as(u64, 0), owner.operation_highwater);
}
test "station failed M4 never publishes joined and erases key material" {
    var authority: policy.Authority = .{};
    var device: Device = .{};
    var owner: link.Link = .{};
    try init(&owner, &authority, &device, true);
    try handshake(&owner, &device);
    try t.expectError(error.TransmissionFailed, complete(&owner, 4, false));
    try t.expectEqual(link.State.failed, owner.state);
    try t.expectEqual(wifi.Failure.device_lost, (try owner.takeEvent()).?.failed.failure);
    try t.expect(std.mem.allEqual(u8, &owner.cipher.pairwise_key, 0));
    try t.expectEqual(@as(usize, 1), device.stops);
}
test "station owner epoch aliases reentrant cleanup and operation identities are guarded" {
    var authority: policy.Authority = .{};
    var device: Device = .{};
    var owner: link.Link = .{};
    try init(&owner, &authority, &device, true);
    try join(&owner);
    var copy = owner;
    try t.expectError(error.InvalidOwner, copy.disconnect());
    try t.expectEqual(@as(usize, 0), device.stops);
    try t.expectError(error.BufferOverlap, owner.ingest(.{ .device_epoch = 1, .policy_generation = owner.generation, .channel = 6, .frame = &owner.frame }, 1));
    var auth = response(0xb0, false);
    try t.expectError(error.StaleReceive, owner.ingest(.{ .device_epoch = 2, .policy_generation = owner.generation, .channel = 6, .frame = &auth }, 1));
    try t.expectError(error.UnknownTxTicket, complete(&owner, 99, true));
    try owner.disconnect();
    try t.expectError(error.ReusedOperation, join(&owner));
    try t.expectError(error.NonceReuse, owner.join(2, bss(), rates, &ieee.handshake.client_rsn, password, 2));
    try t.expectEqual(link.State.failed, owner.state);
}
test "station timeout or new reset revokes old traffic and failed quiescence quarantines" {
    var authority: policy.Authority = .{};
    var device: Device = .{};
    var owner: link.Link = .{};
    try init(&owner, &authority, &device, true);
    try join(&owner);
    device.fail_stop = true;
    try owner.poll(1000);
    try t.expectEqual(link.State.reset_required, owner.state);
    try t.expectEqual(wifi.Failure.timeout, (try owner.takeEvent()).?.failed.failure);
    try t.expectError(error.DeviceResetRequired, owner.disconnect());
    try authority.afterDeviceReset(2, &.{cap});
    try owner.afterDeviceReset(2);
    try t.expectEqual(link.State.idle, owner.state);
    try t.expectError(error.StaleCompletion, complete(&owner, 1, true));
    try t.expectError(error.StaleDeviceEpoch, owner.afterDeviceReset(2));
}
test "station terminal failure supersedes a join event that has not been delivered" {
    var authority: policy.Authority = .{};
    var device: Device = .{};
    var owner: link.Link = .{};
    try init(&owner, &authority, &device, true);
    try handshake(&owner, &device);
    try complete(&owner, 4, true);
    var deauth = response(0xc0, false);
    try receive(&owner, deauth[0..26], 5);
    const event = (try owner.takeEvent()).?;
    try t.expectEqual(@as(u64, 1), event.failed.operation);
    try t.expectEqual(wifi.Failure.authentication, event.failed.failure);
    try t.expectEqual(link.State.failed, owner.state);
    try t.expect(std.mem.allEqual(u8, &owner.cipher.pairwise_key, 0));
}
test "station transient backpressure consumes PN without tearing down a healthy link" {
    var authority: policy.Authority = .{};
    var device: Device = .{};
    var owner: link.Link = .{};
    try init(&owner, &authority, &device, true);
    try handshake(&owner, &device);
    try complete(&owner, 4, true);
    _ = try owner.takeEvent();
    var ethernet: [60]u8 = @splat(0);
    @memcpy(ethernet[0..6], &ap);
    @memcpy(ethernet[6..12], &station);
    ethernet[12] = 8;
    device.backpressure = true;
    try t.expectError(error.WouldBlock, owner.sendEthernet(&ethernet));
    try t.expectEqual(link.State.connected, owner.state);
    try t.expectEqual(@as(usize, 0), device.stops);
    try t.expectEqual(@as(u64, 1), owner.cipher.tx_pn);
    device.backpressure = false;
    _ = try owner.sendEthernet(&ethernet);
    try t.expectEqual(@as(u64, 2), owner.cipher.tx_pn);
}
test "station M4 after deadline cannot bypass timeout and TX_FREE is not ACK evidence" {
    var authority: policy.Authority = .{};
    var device: Device = .{};
    var owner: link.Link = .{};
    try init(&owner, &authority, &device, true);
    try handshake(&owner, &device);
    try t.expect(!try owner.releaseData(1, owner.generation, 4));
    try t.expectEqual(link.State.await_final_tx, owner.state);
    try t.expectError(error.ConnectionTimeout, owner.completeTx(.{ .device_epoch = 1, .policy_generation = owner.generation, .ticket = 4, .acknowledged = true, .now = 1000 }));
    try t.expectEqual(wifi.Failure.timeout, (try owner.takeEvent()).?.failed.failure);
    try t.expectEqual(link.State.failed, owner.state);
}
