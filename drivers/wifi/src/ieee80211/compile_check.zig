const wire = @import("ieee80211");
export fn bedrock_ieee80211_probe(frame: [*]const u8, length: usize) callconv(.c) u64 {
    const bss = wire.management.parse(frame[0..length], null, -50) catch return 0;
    return @backingInt(bss.security) + 1;
}
export fn bedrock_wpa2_probe(password: [*]const u8, length: usize, output: *[32]u8) callconv(.c) bool {
    wire.wpa2.derivePmk(password[0..length], "Bedrock", output) catch return false;
    var ptk: [48]u8 = undefined;
    defer wire.wpa2.clear(&ptk);
    wire.wpa2.derivePtk(output, .{ 2, 0, 0, 0, 0, 1 }, .{ 2, 0, 0, 0, 0, 2 }, @splat(1), @splat(2), &ptk) catch return false;
    return true;
}
export fn bedrock_eapol_probe(first: [*]const u8, first_length: usize, third: [*]const u8, third_length: usize, kck: *const [16]u8) callconv(.c) bool {
    var guard: wire.eapol.ReplayGuard = .{};
    _ = guard.acceptInitial(first[0..first_length]) catch return false;
    _ = guard.acceptAuthenticated(third[0..third_length], kck) catch return false;
    return true;
}
export fn bedrock_wpa2_station_probe(station: *wire.handshake.Station, source: *const [6]u8, destination: *const [6]u8, bytes: [*]const u8, length: usize) callconv(.c) bool {
    const action = station.ingest(source.*, destination.*, bytes[0..length]) catch return false;
    return action.keys_installed;
}
export fn bedrock_key_unwrap_probe(kek: *const [16]u8, bytes: [*]const u8, length: usize, output: [*]u8, capacity: usize) callconv(.c) usize {
    return wire.keywrap.unwrap(kek, bytes[0..length], output[0..capacity]) catch 0;
}
export fn bedrock_mac_station_probe(session: *wire.station.MacSession, bytes: [*]const u8, length: usize) callconv(.c) bool {
    session.ingestAssociation(bytes[0..length]) catch return false;
    return session.state == .associated;
}
export fn bedrock_ccmp_station_seal(session: *wire.ccmp.Station, bytes: [*]const u8, length: usize, output: [*]u8, capacity: usize) callconv(.c) usize {
    return session.sealEthernet(bytes[0..length], 0, output[0..capacity]) catch 0;
}
export fn bedrock_ccmp_station_init(session: *wire.ccmp.Station, config: *const wire.ccmp.Config) callconv(.c) bool {
    session.init(config.*) catch return false;
    return true;
}
export fn bedrock_ccmp_station_open(session: *wire.ccmp.Station, bytes: [*]const u8, length: usize, output: [*]u8, capacity: usize) callconv(.c) usize {
    return session.openEthernet(bytes[0..length], output[0..capacity]) catch 0;
}
