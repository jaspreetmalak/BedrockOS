const std = @import("std");
const t = std.testing;
const wifi = @import("networkkit").wifi;
const hs = @import("handshake.zig");
const mac = @import("station.zig");
const kw = @import("keywrap.zig");
const eapol = @import("eapol.zig");
const wpa2 = @import("wpa2.zig");
const ap: [6]u8 = .{ 2, 0x10, 0x20, 0x30, 0x40, 0x50 };
const station_mac: [6]u8 = .{ 2, 0x90, 1, 2, 3, 4 };
const pmk: [32]u8 = @splat(0x11);
const snonce: [32]u8 = @splat(0x22);
const anonce: [32]u8 = @splat(0x44);
const gtk: [16]u8 = @splat(0x66);
fn bss() wifi.Bss {
    return .{ .ssid = wifi.Ssid.init("Bedrock") catch unreachable, .bssid = ap, .channel = 6, .signal_dbm = -42, .security = .wpa2_personal };
}
fn config() hs.Config {
    return .{ .selected = bss(), .station_mac = station_mac, .snonce = &snonce, .pmk = &pmk, .ap_rsn_body = &hs.client_rsn };
}
fn hex(comptime length: usize, input: *const [length * 2:0]u8) [length]u8 {
    var output: [length]u8 = undefined;
    _ = std.fmt.hexToBytes(&output, input) catch unreachable;
    return output;
}
const Device = struct {
    installs: usize = 0,
    removals: usize = 0,
    fail_install: bool = false,
    fail_remove: bool = false,
    programmed: bool = false,
    tk: [16]u8 = @splat(0),
    group: [16]u8 = @splat(0),
    group_index: u2 = 0,
    rsc: [8]u8 = @splat(0),
    fn installer(self: *Device) hs.Installer {
        return .{ .context = self, .install = install, .remove = remove };
    }
    fn install(context: *anyopaque, keys: *const hs.InstalledKeys) anyerror!void {
        const self: *Device = @ptrCast(@alignCast(context));
        if (!std.mem.eql(u8, &keys.peer, &ap) or !std.mem.eql(u8, &keys.station, &station_mac)) return error.BadPeer;
        self.installs += 1;
        self.tk = keys.pairwise.*;
        self.group = keys.group.*;
        self.group_index = keys.group_index;
        self.rsc = keys.receive_sequence;
        self.programmed = true;
        if (self.fail_install) return error.PartialInstall;
    }
    fn remove(context: *anyopaque, peer: [6]u8) anyerror!void {
        const self: *Device = @ptrCast(@alignCast(context));
        if (!std.mem.eql(u8, &peer, &ap)) return error.BadPeer;
        self.removals += 1;
        if (self.fail_remove) return error.RemovalFailed;
        self.programmed = false;
        wpa2.clear(&self.tk);
        wpa2.clear(&self.group);
    }
};
const Frame = struct {
    bytes: [2048]u8 = @splat(0),
    length: usize = 99,
    fn slice(self: *const Frame) []const u8 {
        return self.bytes[0..self.length];
    }
    fn init(information: u16, counter: u64) Frame {
        var frame: Frame = .{};
        frame.bytes[0] = 2;
        frame.bytes[1] = 3;
        frame.bytes[4] = 2;
        std.mem.writeInt(u16, frame.bytes[2..4], 95, .big);
        std.mem.writeInt(u16, frame.bytes[5..7], information, .big);
        std.mem.writeInt(u16, frame.bytes[7..9], 16, .big);
        std.mem.writeInt(u64, frame.bytes[9..17], counter, .big);
        @memcpy(frame.bytes[17..49], &anonce);
        return frame;
    }
};
fn ptk() ![48]u8 {
    var result: [48]u8 = undefined;
    try wpa2.derivePtk(&pmk, ap, station_mac, anonce, snonce, &result);
    return result;
}
fn keyData() [48]u8 {
    var bytes: [48]u8 = @splat(0);
    bytes[0] = 48;
    bytes[1] = 20;
    @memcpy(bytes[2..22], &hs.client_rsn);
    bytes[22] = 221;
    bytes[23] = 22;
    @memcpy(bytes[24..28], &@as([4]u8, .{ 0, 15, 172, 1 }));
    bytes[28] = 1;
    @memcpy(bytes[30..46], &gtk);
    bytes[46] = 221;
    return bytes;
}
fn sign(frame: *Frame) !void {
    var keys = try ptk();
    defer wpa2.clear(&keys);
    var tag: [16]u8 = undefined;
    defer wpa2.clear(&tag);
    try eapol.calculateMic(frame.slice(), keys[0..16], &tag);
    @memcpy(frame.bytes[81..97], &tag);
}
fn thirdFrame(plaintext: []const u8, counter: u64) !Frame {
    var keys = try ptk();
    defer wpa2.clear(&keys);
    var frame = Frame.init(0x13ca, counter);
    const length = try kw.wrap(keys[16..32], plaintext, frame.bytes[99..]);
    frame.length += length;
    std.mem.writeInt(u16, frame.bytes[2..4], @intCast(frame.length - 4), .big);
    std.mem.writeInt(u16, frame.bytes[97..99], @intCast(length), .big);
    frame.bytes[65] = 7;
    try sign(&frame);
    return frame;
}
fn begin(station: *hs.Station, device: *Device) !hs.Action {
    try station.start(config(), device.installer());
    const first = Frame.init(0x8a, 5);
    return station.ingest(ap, station_mac, first.slice());
}
fn expectErased(station: *const hs.Station) !void {
    try t.expect(std.mem.allEqual(u8, &station.pmk, 0));
    try t.expect(std.mem.allEqual(u8, &station.ptk, 0));
    try t.expect(std.mem.allEqual(u8, &station.gtk, 0));
    try t.expect(std.mem.allEqual(u8, &station.confirmation_key, 0));
    try t.expect(std.mem.allEqual(u8, &station.snonce, 0));
    try t.expect(!station.complete());
}

test "RFC3394 published AES128 KEK vector wraps and unwraps exactly" {
    const kek = hex(16, "000102030405060708090a0b0c0d0e0f");
    const plain = hex(16, "00112233445566778899aabbccddeeff");
    const cipher = hex(24, "1fa68b0a8112b447aef34bd8fb5a7b829d3e862371d2cfe5");
    var output: [24]u8 = @splat(0xa5);
    try t.expectEqual(@as(usize, 24), try kw.wrap(&kek, &plain, &output));
    try t.expectEqual(cipher, output);
    output = @splat(0xa5);
    try t.expectEqual(@as(usize, 16), try kw.unwrap(&kek, &cipher, &output));
    try t.expectEqualSlices(u8, &plain, output[0..16]);
    try t.expect(std.mem.allEqual(u8, output[16..24], 0xa5));
}
test "key wrap integrity bounds and overlap errors never publish plaintext" {
    const kek: [16]u8 = @splat(0x11);
    var cipher: [24]u8 = undefined;
    _ = try kw.wrap(&kek, &@as([16]u8, @splat(0x55)), &cipher);
    var output: [16]u8 = @splat(0xa5);
    cipher[3] ^= 1;
    try t.expectError(error.IntegrityFailure, kw.unwrap(&kek, &cipher, &output));
    try t.expect(std.mem.allEqual(u8, &output, 0xa5));
    try t.expectError(error.InvalidLength, kw.unwrap(&kek, cipher[0..23], &output));
    try t.expectError(error.BufferTooSmall, kw.unwrap(&kek, &cipher, output[0..15]));
    try t.expectError(error.BufferOverlap, kw.unwrap(&kek, &cipher, cipher[0..16]));
    var too_large: [520]u8 = @splat(0);
    try t.expectError(error.InvalidLength, kw.wrap(&kek, &too_large, &too_large));
}
test "WPA2 station pins discovery peer and emits valid M2 before install" {
    var device: Device = .{};
    var station: hs.Station = .{};
    const action = try begin(&station, &device);
    try t.expectEqual(.message2, action.message);
    try t.expect(!action.keys_installed and !station.complete());
    const key = try eapol.parse(action.response.slice());
    try t.expectEqual(snonce, key.nonce);
    try t.expectEqual(@as(u64, 5), key.replay_counter);
    try t.expectEqualSlices(u8, &hs.client_rsn, key.data[2..]);
    var keys = try ptk();
    defer wpa2.clear(&keys);
    try eapol.verifyMic(action.response.slice(), keys[0..16]);
    const first = Frame.init(0x8a, 5);
    const duplicate = try station.ingest(ap, station_mac, first.slice());
    try t.expect(duplicate.retransmission);
    try t.expectEqualSlices(u8, action.response.slice(), duplicate.response.slice());
    const newer_first = Frame.init(0x8a, 6);
    const old_ptk = station.ptk;
    const newer_second = try station.ingest(ap, station_mac, newer_first.slice());
    try t.expect(newer_second.retransmission);
    try t.expectEqual(@as(u64, 6), (try eapol.parse(newer_second.response.slice())).replay_counter);
    try eapol.verifyMic(newer_second.response.slice(), keys[0..16]);
    try t.expectEqual(old_ptk, station.ptk);
    const before = station;
    try t.expectError(error.WrongPeer, station.ingest(station_mac, station_mac, first.slice()));
    try t.expectEqualDeep(before, station);
    try t.expectEqual(@as(usize, 0), device.installs);
    try station.abort();
    try expectErased(&station);
    try t.expectEqual(@as(usize, 0), device.removals);
    try t.expectError(error.NonceReuse, station.start(config(), device.installer()));
}
test "authenticated M3 requires GTK install and never reinstalls on retransmit" {
    var device: Device = .{};
    var station: hs.Station = .{};
    _ = try begin(&station, &device);
    const third = try thirdFrame(&keyData(), 6);
    const completed = try station.ingest(ap, station_mac, third.slice());
    try t.expect(station.complete() and completed.keys_installed and !completed.retransmission);
    try t.expectEqual(@as(usize, 1), device.installs);
    try t.expectEqual(gtk, device.group);
    try t.expectEqual(@as(u2, 1), device.group_index);
    try t.expectEqual(@as(u8, 7), device.rsc[0]);
    var keys = try ptk();
    defer wpa2.clear(&keys);
    try t.expectEqualSlices(u8, keys[32..48], &device.tk);
    try t.expect(std.mem.allEqual(u8, &station.pmk, 0) and std.mem.allEqual(u8, &station.ptk, 0) and std.mem.allEqual(u8, &station.gtk, 0));
    try t.expectEqualSlices(u8, keys[0..16], &station.confirmation_key);
    try eapol.verifyMic(completed.response.slice(), keys[0..16]);
    const repeat = try station.ingest(ap, station_mac, third.slice());
    try t.expect(repeat.retransmission);
    try t.expectEqualSlices(u8, completed.response.slice(), repeat.response.slice());
    const installed_tk = device.tk;
    const installed_gtk = device.group;
    const newer = try thirdFrame(&keyData(), 7);
    const newer_response = try station.ingest(ap, station_mac, newer.slice());
    try t.expect(newer_response.retransmission);
    try t.expectEqual(@as(u64, 7), (try eapol.parse(newer_response.response.slice())).replay_counter);
    try eapol.verifyMic(newer_response.response.slice(), keys[0..16]);
    try t.expectEqual(@as(usize, 1), device.installs);
    try t.expectEqual(@as(usize, 0), device.removals);
    try t.expectEqual(installed_tk, device.tk);
    try t.expectEqual(installed_gtk, device.group);
    try station.abort();
    try t.expectEqual(@as(usize, 1), device.removals);
    try expectErased(&station);
}
test "changed M3 critical identity replay or MIC fails without key reinstall" {
    for (0..6) |mutation| {
        var device: Device = .{};
        var station: hs.Station = .{};
        _ = try begin(&station, &device);
        const initial = try thirdFrame(&keyData(), 6);
        _ = try station.ingest(ap, station_mac, initial.slice());
        var changed = try thirdFrame(&keyData(), 7);
        switch (mutation) {
            0 => changed.bytes[17] ^= 1,
            1 => std.mem.writeInt(u64, changed.bytes[9..17], 5, .big),
            2 => changed.bytes[99] ^= 1,
            3 => changed.bytes[65] ^= 1,
            4 => changed.bytes[81] ^= 1,
            5 => changed.bytes[0] = 1,
            else => unreachable,
        }
        if (mutation != 4) try sign(&changed);
        if (station.ingest(ap, station_mac, changed.slice())) |_| return error.AcceptedChangedM3 else |_| {}
        try t.expectEqual(@as(usize, 1), device.installs);
        try t.expectEqual(@as(usize, 1), device.removals);
        try t.expect(!device.programmed);
        try expectErased(&station);
    }
}
test "invalid MIC unwrap RSNE GTK and padding fail before any installation" {
    for (0..8) |mutation| {
        var device: Device = .{};
        var station: hs.Station = .{};
        _ = try begin(&station, &device);
        var plaintext = keyData();
        switch (mutation) {
            0, 1 => {},
            2 => plaintext[19] = 8, // Changed RSN AKM.
            3 => plaintext[28] = 0x80, // Reserved GTK bits.
            4 => plaintext[29] = 1, // Reserved octet.
            5 => @memset(plaintext[30..46], 0),
            6 => plaintext[47] = 1, // Nonzero padding after dd marker.
            7 => plaintext[22] = 49, // Missing/unknown GTK KDE.
            else => unreachable,
        }
        var third = try thirdFrame(&plaintext, 6);
        if (mutation == 0) third.bytes[81] ^= 1;
        if (mutation == 1) {
            third.bytes[99] ^= 1;
            try sign(&third);
        }
        if (station.ingest(ap, station_mac, third.slice())) |_| return error.AcceptedBadKeyData else |_| {}
        try t.expectEqual(@as(usize, 0), device.installs);
        try t.expectEqual(@as(usize, 0), device.removals);
        try expectErased(&station);
    }
}
test "missing duplicate group and RSN keys fail and all two-bit GTK IDs are valid" {
    for (0..3) |mutation| {
        var device: Device = .{};
        var station: hs.Station = .{};
        _ = try begin(&station, &device);
        var plain: [72]u8 = @splat(0);
        const ordinary = keyData();
        var length: usize = 24;
        @memcpy(plain[0..22], ordinary[0..22]);
        plain[22] = 221;
        if (mutation == 1) {
            @memcpy(plain[0..46], ordinary[0..46]);
            @memcpy(plain[46..70], ordinary[22..46]);
            plain[70] = 221;
            length = 72;
        } else if (mutation == 2) {
            @memcpy(plain[22..44], ordinary[0..22]);
            @memcpy(plain[44..68], ordinary[22..46]);
            plain[68] = 221;
            length = 72;
        }
        const third = try thirdFrame(plain[0..length], 6);
        if (station.ingest(ap, station_mac, third.slice())) |_| return error.AcceptedMissingOrDuplicateKey else |err| {
            if (mutation == 0) try t.expectEqual(error.MissingGroupKey, err);
        }
        try t.expectEqual(@as(usize, 0), device.installs);
        try expectErased(&station);
    }
    for (0..4) |index| {
        var device: Device = .{};
        var station: hs.Station = .{};
        _ = try begin(&station, &device);
        var plain = keyData();
        plain[28] = @intCast(index);
        const third = try thirdFrame(&plain, 6);
        _ = try station.ingest(ap, station_mac, third.slice());
        try t.expectEqual(@as(u2, @intCast(index)), device.group_index);
        try station.abort();
    }
}
test "initial M3 wrong nonce replay flags and reserved receive PN never installs" {
    for (0..4) |mutation| {
        var device: Device = .{};
        var station: hs.Station = .{};
        _ = try begin(&station, &device);
        var third = try thirdFrame(&keyData(), 6);
        switch (mutation) {
            0 => third.bytes[17] ^= 1,
            1 => std.mem.writeInt(u64, third.bytes[9..17], 5, .big),
            2 => third.bytes[71] = 1,
            3 => third.bytes[6] ^= 0x40,
            else => unreachable,
        }
        if (mutation != 3) try sign(&third);
        if (station.ingest(ap, station_mac, third.slice())) |_| return error.AcceptedUnpinnedM3 else |_| {}
        try t.expectEqual(@as(usize, 0), device.installs);
        try expectErased(&station);
    }
}
test "partial device install rollback failure remains reset required" {
    for ([_]bool{ false, true }) |removal_fails| {
        var device: Device = .{ .fail_install = true, .fail_remove = removal_fails };
        var station: hs.Station = .{};
        _ = try begin(&station, &device);
        const third = try thirdFrame(&keyData(), 6);
        try t.expectError(if (removal_fails) error.DeviceResetRequired else error.KeyInstallFailed, station.ingest(ap, station_mac, third.slice()));
        try t.expectEqual(@as(usize, 1), device.installs);
        try t.expectEqual(@as(usize, 1), device.removals);
        try expectErased(&station);
        if (removal_fails) {
            try t.expectEqual(.reset_required, station.state);
            try t.expectError(error.DeviceResetRequired, station.start(config(), device.installer()));
            try t.expectError(error.DeviceResetRequired, station.abort());
            // Test device reset completion, not a real hardware assertion.
            device.programmed = false;
            try station.resetAfterDeviceReset();
            try t.expectEqual(.idle, station.state);
        } else {
            try t.expectEqual(.failed, station.state);
            try t.expect(!device.programmed);
        }
    }
}
test "station preflight rejects WPA3 open downgrade and missing pinned RSN" {
    var device: Device = .{};
    var station: hs.Station = .{};
    var selected = config();
    selected.selected.security = .wpa3_personal;
    try t.expectError(error.UnsupportedSecurity, station.start(selected, device.installer()));
    selected.selected.security = .open;
    try t.expectError(error.UnsupportedSecurity, station.start(selected, device.installer()));
    selected = config();
    var foreign_rsn = hs.client_rsn;
    foreign_rsn[17] = 1;
    selected.ap_rsn_body = &foreign_rsn;
    try t.expectError(error.UnsupportedSecurity, station.start(selected, device.installer()));
    selected = config();
    selected.snonce = &@as([32]u8, @splat(0));
    try t.expectError(error.InvalidNonce, station.start(selected, device.installer()));
    selected = config();
    selected.pmk = &station.pmk;
    try t.expectError(error.BufferOverlap, station.start(selected, device.installer()));
    try expectErased(&station);
    try t.expectEqual(@as(usize, 0), device.installs);
}
test "copied live stations cannot install twice or remove actual owner keys" {
    var device: Device = .{};
    var station: hs.Station = .{};
    _ = try begin(&station, &device);
    var pending_copy = station;
    const third = try thirdFrame(&keyData(), 6);
    try t.expectError(error.InvalidOwner, pending_copy.ingest(ap, station_mac, third.slice()));
    try expectErased(&pending_copy);
    try t.expectEqual(.await_message3, station.state);
    try t.expectEqual(@as(usize, 0), device.installs);
    _ = try station.ingest(ap, station_mac, third.slice());
    try t.expectEqual(@as(usize, 1), device.installs);
    var completed_copy = station;
    try t.expect(!completed_copy.complete());
    try t.expectError(error.InvalidOwner, completed_copy.abort());
    try t.expectError(error.InvalidOwner, completed_copy.resetAfterDeviceReset());
    var start_copy = station;
    try t.expectError(error.InvalidOwner, start_copy.start(config(), device.installer()));
    try expectErased(&start_copy);
    try t.expect(station.complete());
    try t.expectEqual(@as(usize, 0), device.removals);
    try station.abort();
    try t.expectEqual(@as(usize, 1), device.removals);
    try expectErased(&station);
}

fn managementReply(subtype: u8) [30]u8 {
    var bytes: [30]u8 = @splat(0);
    bytes[0] = subtype;
    @memcpy(bytes[4..10], &station_mac);
    @memcpy(bytes[10..16], &ap);
    @memcpy(bytes[16..22], &ap);
    return bytes;
}
const rates: mac.Rates = .{ .bytes = .{ 0x82, 0x84, 0x8b, 0x96, 0, 0, 0, 0 }, .length = 4 };
test "MAC authentication and association serializers pin addresses and security" {
    var session: mac.MacSession = .{};
    try session.start(bss(), station_mac, rates, &hs.client_rsn);
    var output: [128]u8 = @splat(0xa5);
    try t.expectError(error.BufferTooSmall, session.authenticationRequest(3, output[0..29]));
    try t.expectEqual(.ready, session.state);
    try t.expect(std.mem.allEqual(u8, &output, 0xa5));
    try t.expectEqual(@as(usize, 30), try session.authenticationRequest(3, &output));
    try t.expectEqual(@as(u8, 0xb0), output[0]);
    try t.expectEqualSlices(u8, &ap, output[4..10]);
    try t.expectEqualSlices(u8, &station_mac, output[10..16]);
    try t.expectEqual(@as(u8, 1), output[26]);
    var auth = managementReply(0xb0);
    auth[26] = 2;
    try session.ingestAuthentication(&auth);
    const length = try session.associationRequest(4, 10, &output);
    try t.expectEqual(@as(u8, 0x11), output[24]);
    try t.expectEqualSlices(u8, "Bedrock", output[30..37]);
    try t.expectEqualSlices(u8, &hs.client_rsn, output[length - 20 .. length]);
    var association = managementReply(0x10);
    association[24] = 0x11;
    std.mem.writeInt(u16, association[28..30], 0xc007, .little);
    try session.ingestAssociation(&association);
    try t.expectEqual(.associated, session.state);
    try t.expectEqual(@as(u16, 7), session.association_id);
}
test "MAC responses reject foreign frames invalid AID and security downgrade" {
    var session: mac.MacSession = .{};
    try session.start(bss(), station_mac, rates, &hs.client_rsn);
    var output: [128]u8 = undefined;
    _ = try session.authenticationRequest(0, &output);
    var auth = managementReply(0xb0);
    auth[26] = 2;
    auth[10] = 4;
    try t.expectError(error.WrongPeer, session.ingestAuthentication(&auth));
    try t.expectEqual(.authenticating, session.state);
    auth[10] = ap[0];
    try session.ingestAuthentication(&auth);
    _ = try session.associationRequest(1, 1, &output);
    var association = managementReply(0x10);
    association[24] = 1;
    std.mem.writeInt(u16, association[28..30], 0xc001, .little);
    try t.expectError(error.SecurityMismatch, session.ingestAssociation(&association));
    association[24] = 0x11;
    std.mem.writeInt(u16, association[28..30], 0xc000, .little);
    try t.expectError(error.InvalidFrame, session.ingestAssociation(&association));
    std.mem.writeInt(u16, association[28..30], 0xc001, .little);
    association[26] = 1;
    try t.expectError(error.AssociationDenied, session.ingestAssociation(&association));
    try t.expectEqual(.failed, session.state);
    session.reset();
    var open = bss();
    open.security = .open;
    try t.expectError(error.SecurityMismatch, session.start(open, station_mac, rates, &hs.client_rsn));
    try session.start(open, station_mac, rates, &.{});
    try t.expectEqual(.ready, session.state);
}
test "MAC wire response truncation duplicate RSN and serializer sequence preserve state" {
    var session: mac.MacSession = .{};
    try session.start(bss(), station_mac, rates, &hs.client_rsn);
    var output: [128]u8 = @splat(0xa5);
    try t.expectError(error.InvalidSequence, session.authenticationRequest(4096, &output));
    try t.expect(std.mem.allEqual(u8, &output, 0xa5));
    _ = try session.authenticationRequest(0, &output);
    var auth = managementReply(0xb0);
    auth[26] = 2;
    for (0..30) |length| try t.expectError(error.InvalidFrame, session.ingestAuthentication(auth[0..length]));
    try t.expectEqual(.authenticating, session.state);
    try session.ingestAuthentication(&auth);
    _ = try session.associationRequest(0, 1, &output);
    var response: [74]u8 = @splat(0);
    var base = managementReply(0x10);
    base[24] = 0x11;
    std.mem.writeInt(u16, base[28..30], 0xc001, .little);
    @memcpy(response[0..30], &base);
    response[30] = 48;
    response[31] = 20;
    @memcpy(response[32..52], &hs.client_rsn);
    response[52] = 48;
    response[53] = 20;
    @memcpy(response[54..74], &hs.client_rsn);
    try t.expectError(error.SecurityMismatch, session.ingestAssociation(&response));
    try t.expectEqual(.associating, session.state);
    try t.expectError(error.InvalidFrame, session.ingestAssociation(response[0..73]));
    try t.expectEqual(.associating, session.state);
    try session.ingestAssociation(response[0..52]);
    try t.expectEqual(.associated, session.state);
}
