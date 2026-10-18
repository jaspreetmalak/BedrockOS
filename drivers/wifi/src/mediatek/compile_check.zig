// SPDX-License-Identifier: ISC
// Copyright (C) 2026 Bedrock contributors
const mt = @import("root.zig");
export fn bedrock_mt7922_protocol_probe(bytes: [*]const u8, len: usize, address: u32) u64 {
    const ram = mt.firmware.parseRam(bytes[0..len]) catch return 0;
    const mapped = mt.registers.fixedOffset(address) catch return 0;
    return @as(u64, ram.region_count) << 32 | (mapped orelse 0);
}
export fn bedrock_mt7922_descriptor_probe(address: u64, length: usize) u32 {
    const d = mt.dma.Descriptor.transmit(address, length) catch return 0;
    return d.ctrl;
}
export fn bedrock_mt7922_driver_probe(driver: *mt.Driver, mcu: *mt.Mcu, wm: *mt.dma.Ring, fwdl: *mt.dma.Ring, event: *mt.dma.Ring, patch: [*]const u8, patch_len: usize, ram: [*]const u8, ram_len: usize) u32 {
    driver.driverOwn() catch return 1;
    driver.reset() catch return 2;
    driver.configureDma(wm, fwdl, event) catch return 3;
    driver.loadFirmware(mcu, patch[0..patch_len], ram[0..ram_len]) catch return 4;
    driver.stop() catch return 5;
    return 0;
}
export fn bedrock_mt7922_ring_probe(ring: *mt.dma.Ring, packet: [*]const u8, packet_len: usize, output: [*]u8, output_len: usize) usize {
    ring.send(packet[0..packet_len], 3) catch return 0;
    return (ring.receive(output[0..output_len]) catch return 0) orelse 0;
}
export fn bedrock_mt7922_mac_probe(packet: [*]const u8, size: usize, output: [*]u8, output_size: usize, payload_address: u64) u64 {
    const received = mt.mac.management(packet[0..size], 3) catch return 0;
    _ = mt.mac.transmit(received.frame, payload_address, .{ .token = 1, .wlan_index = 0, .fixed_rate = 0 }, output[0..output_size]) catch return 0;
    return received.channel;
}
export fn bedrock_mt7922_scan_probe(session: *mt.scan.Session, mcu: *mt.Mcu, event: [*]const u8, event_size: usize) u64 {
    _ = session.start(mcu, .{ .sequence = 1, .channels = &.{.{ .band = .ghz2, .number = 1 }} }) catch return 0;
    const done = session.completed(event[0..event_size]) catch return 0;
    session.cancelRequest(mcu) catch return 0;
    return done.beacons;
}
export fn bedrock_mt7922_free_probe(packet: [*]const u8, size: usize) usize {
    return (mt.mac.transmitFree(packet[0..size]) catch return 0).count;
}
export fn bedrock_mt7922_regulatory_probe(session: *mt.regulatory.Session, mcu: *mt.Mcu, plan: *const mt.regulatory.Plan) u32 {
    session.submit(mcu, plan.*) catch return 1;
    if (!session.isSubmitted(plan.device_epoch, plan.generation)) return 2;
    session.invalidate() catch return 3;
    session.afterDeviceReset(plan.device_epoch +| 1) catch return 4;
    return 0;
}
export fn bedrock_mt7922_clc_probe(bytes: [*]const u8, size: usize, output: [*]u8, output_size: usize, encapsulation: u8) usize {
    if (encapsulation > 1) return 0;
    const ram = mt.firmware.parseRam(bytes[0..size]) catch return 0;
    const clc = mt.regulatory.Clc.fromRam(ram, @intCast(encapsulation)) catch return 0;
    var rules = clc.rules(.{ 'U', 'S' });
    const rule = rules.next() orelse return 0;
    return (mt.regulatory.encodeClc(rule, .indoor, .{ .encapsulation = @intCast(encapsulation), .acpi_conf = 0, .mtcl_conf = 0, .power_type = .unset, .clc_event_supported = false }, output[0..output_size]) catch return 0).len;
}
export fn bedrock_mt7922_nic_probe(client: *mt.nic.Client, device: *const mt.nic.Device, bss: *const mt.nic.Bss, station: *const mt.nic.Station, channel: *const mt.nic.Channel20, key: *const mt.nic.CcmpKey) u64 {
    const facts = client.capabilities() catch return 1;
    _ = client.readEfuse(0x55b) catch return 2;
    _ = client.useEfuse() catch return 3;
    _ = client.device(device.*) catch return 4;
    _ = client.bss(bss.*) catch return 5;
    _ = client.station(station.*) catch return 6;
    _ = client.channel(channel.*) catch return 7;
    _ = client.rlm(bss.bss_index, channel.*) catch return 8;
    _ = client.rxPath(channel.*) catch return 9;
    _ = client.rtsThreshold(0x92b) catch return 10;
    _ = client.macEnable(true) catch return 11;
    _ = client.ccmp(key.*) catch return 12;
    return facts.phy.nss;
}
export fn bedrock_mt7922_nic_owner_probe(client: *mt.nic.Client, mcu: *mt.Mcu, epoch: u64, history: u16) u32 {
    client.init(mcu, epoch, history) catch return 1;
    client.afterDeviceReset(epoch +| 1, 0) catch return 2;
    return 0;
}
export fn bedrock_mt7922_nic_register_probe(driver: *mt.Driver) u32 {
    driver.initMac() catch return 1;
    return @intFromBool(driver.snapshot().mac_initialized);
}
