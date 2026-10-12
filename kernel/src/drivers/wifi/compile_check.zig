const drivers = @import("wifi_drivers");
const protocol = @import("boot_protocol");
export fn bedrock_wifi_driver_inventory(info: *const protocol.BootInfo) callconv(.c) usize {
    return (drivers.discover(info) catch return 0).count;
}
export fn bedrock_wifi_family(vendor: u16, product: u16) callconv(.c) u32 {
    return @intCast(@backingInt(drivers.family(vendor, product)));
}
export fn bedrock_wifi_pci_transport(config: *const drivers.pci.Config, device: *const drivers.pci.Device) callconv(.c) u64 {
    return drivers.pci.memoryBar(config.*, device.*, 0) catch 0;
}
export fn bedrock_wifi_dma_range(base: u64, length: u64) callconv(.c) bool {
    drivers.resources.checkDma32(base, length) catch return false;
    return true;
}
// These entry points force code generation of the translated implementations.
// The check artifact is not installed as a boot-time hardware test.
export fn bedrock_wifi_dma_owner(lease: *drivers.resources.Dma32, bytes: usize, alignment: usize) callconv(.c) u32 {
    lease.init(bytes, alignment) catch return 0;
    const address = lease.publish() catch return 0;
    return address;
}
export fn bedrock_wifi_dma_release(lease: *drivers.resources.Dma32, quiescent: bool) callconv(.c) bool {
    if (quiescent) lease.releaseAfterQuiescence() catch return false else lease.releaseUnexposed() catch return false;
    return true;
}
export fn bedrock_mt7922_driver(driver: *drivers.mediatek.Driver, mcu: *drivers.mediatek.Mcu, wm: *drivers.mediatek.dma.Ring, fwdl: *drivers.mediatek.dma.Ring, event: *drivers.mediatek.dma.Ring, patch: [*]const u8, patch_length: usize, ram: [*]const u8, ram_length: usize) callconv(.c) u32 {
    driver.driverOwn() catch return 1;
    driver.reset() catch return 2;
    driver.configureDma(wm, fwdl, event) catch return 3;
    driver.loadFirmware(mcu, patch[0..patch_length], ram[0..ram_length]) catch return 4;
    driver.stop() catch return 5;
    return 0;
}
export fn bedrock_mt7922_ring(ring: *drivers.mediatek.dma.Ring, packet: [*]const u8, packet_length: usize, output: [*]u8, capacity: usize) callconv(.c) usize {
    ring.send(packet[0..packet_length], 3) catch return 0;
    return (ring.receive(output[0..capacity]) catch return 0) orelse 0;
}
export fn bedrock_intel_firmware(bytes: [*]const u8, length: usize, output: *drivers.intel.firmware.Container) callconv(.c) bool {
    drivers.intel.firmware.inspect(bytes[0..length], output) catch return false;
    return true;
}
export fn bedrock_realtek_firmware(bytes: [*]const u8, length: usize, cut: u8, output: *drivers.realtek.firmware.Image, packet: [*]u8, capacity: usize) callconv(.c) usize {
    drivers.realtek.firmware.inspect(bytes[0..length], .{ .cut = cut }, output) catch return 0;
    return (drivers.realtek.h2c.encode(packet[0..capacity], .{ .category = 1, .class = 0, .function = 1, .sequence = 0 }, &.{}) catch return 0).len;
}
export fn bedrock_wifi_beacon(bytes: [*]const u8, length: usize) callconv(.c) u64 {
    const bss = drivers.ieee80211.management.parse(bytes[0..length], null, -50) catch return 0;
    return @backingInt(bss.security) + 1;
}
export fn bedrock_wifi_pmk(password: [*]const u8, length: usize, output: *[32]u8) callconv(.c) bool {
    drivers.ieee80211.wpa2.derivePmk(password[0..length], "Bedrock", output) catch return false;
    return true;
}
export fn bedrock_wifi_key_exchange(station: *drivers.ieee80211.handshake.Station, source: *const [6]u8, destination: *const [6]u8, bytes: [*]const u8, length: usize) callconv(.c) bool {
    const action = station.ingest(source.*, destination.*, bytes[0..length]) catch return false;
    return action.keys_installed;
}
export fn bedrock_wifi_key_unwrap(kek: *const [16]u8, bytes: [*]const u8, length: usize, output: [*]u8, capacity: usize) callconv(.c) usize {
    return drivers.ieee80211.keywrap.unwrap(kek, bytes[0..length], output[0..capacity]) catch 0;
}
export fn bedrock_wifi_mac_association(session: *drivers.ieee80211.station.MacSession, bytes: [*]const u8, length: usize) callconv(.c) bool {
    session.ingestAssociation(bytes[0..length]) catch return false;
    return session.state == .associated;
}
export fn bedrock_mt7922_owned_prepare(transport: *drivers.mt7922_transport.Transport, config: *const drivers.pci.Config, device: *const drivers.pci.Device, platform: *const drivers.mt7922_transport.Platform) callconv(.c) bool {
    transport.prepare(config.*, device.*, platform.*) catch return false;
    return true;
}
export fn bedrock_mt7922_owned_start(transport: *drivers.mt7922_transport.Transport, patch: [*]const u8, patch_length: usize, ram: [*]const u8, ram_length: usize) callconv(.c) bool {
    transport.start(.{ .patch = patch[0..patch_length], .ram = ram[0..ram_length] }) catch return false;
    return true;
}
export fn bedrock_mt7922_owned_stop(transport: *drivers.mt7922_transport.Transport) callconv(.c) bool {
    transport.stop() catch return false;
    return true;
}
export fn bedrock_mt7922_mac(packet: [*]const u8, size: usize, output: [*]u8, capacity: usize, payload_address: u64) callconv(.c) u64 {
    const received = drivers.mediatek.mac.management(packet[0..size], 3) catch return 0;
    _ = drivers.mediatek.mac.transmit(received.frame, payload_address, .{ .token = 1, .wlan_index = 0, .fixed_rate = 0 }, output[0..capacity]) catch return 0;
    return received.channel;
}
export fn bedrock_mt7922_scan(session: *drivers.mediatek.scan.Session, mcu: *drivers.mediatek.Mcu, event: [*]const u8, size: usize) callconv(.c) u64 {
    _ = session.start(mcu, .{ .sequence = 1, .channels = &.{.{ .band = .ghz2, .number = 1 }} }) catch return 0;
    const done = session.completed(event[0..size]) catch return 0;
    session.cancelRequest(mcu) catch return 0;
    return done.beacons;
}
export fn bedrock_mt7922_tx_free(packet: [*]const u8, size: usize) callconv(.c) usize {
    return (drivers.mediatek.mac.transmitFree(packet[0..size]) catch return 0).count;
}
export fn bedrock_wifi_country_policy(alpha2: *const [2]u8, cap: *const drivers.regulatory.ChannelCap, environment: drivers.regulatory.Environment) callconv(.c) i32 {
    const country = drivers.regulatory.lookup(alpha2.*) orelse return -1;
    const decision = drivers.regulatory.evaluate(country, cap.*, environment, .{ .band = cap.band, .channel = cap.channel }) catch return -1;
    return if (decision.allow_initiate_tx) decision.max_conducted_power_mbm orelse -1 else -1;
}
export fn bedrock_wifi_policy_select(authority: *drivers.radio_policy.Authority, epoch: u64, caps: [*]const drivers.regulatory.ChannelCap, count: usize, country: *const [2]u8) callconv(.c) u64 {
    authority.init(epoch, caps[0..count]) catch return 0;
    return authority.select(country.*, .indoor) catch 0;
}
export fn bedrock_wifi_policy_submit(authority: *drivers.radio_policy.Authority, generation: u64, mcu: *drivers.mediatek.Mcu, input: *const drivers.radio_policy.FirmwareInputs) callconv(.c) bool {
    authority.submit(generation, mcu, input.*) catch return false;
    return true;
}
export fn bedrock_wifi_policy_scan(authority: *const drivers.radio_policy.Authority, generation: u64, options: *const drivers.mediatek.scan.Options, output: [*]u8, capacity: usize) callconv(.c) usize {
    return (authority.encodeScan(generation, options.*, output[0..capacity]) catch return 0).len;
}
export fn bedrock_wifi_policy_tx(authority: *const drivers.radio_policy.Authority, generation: u64, request: *const drivers.regulatory.Request, frame: [*]const u8, frame_size: usize, address: u64, options: *const drivers.mediatek.mac.TxOptions, output: [*]u8, capacity: usize) callconv(.c) usize {
    return (authority.encodeTransmit(generation, request.*, frame[0..frame_size], address, options.*, output[0..capacity]) catch return 0).len;
}
export fn bedrock_wifi_policy_reset(authority: *drivers.radio_policy.Authority, epoch: u64, caps: [*]const drivers.regulatory.ChannelCap, count: usize) callconv(.c) u64 {
    authority.afterDeviceReset(epoch, caps[0..count]) catch return 0;
    return (authority.snapshot() catch return 0).generation;
}
export fn bedrock_wifi_policy_retire(authority: *drivers.radio_policy.Authority, epoch: u64, generation: u64) callconv(.c) bool {
    authority.invalidateAfterQuiescence(epoch, generation) catch return false;
    return true;
}
