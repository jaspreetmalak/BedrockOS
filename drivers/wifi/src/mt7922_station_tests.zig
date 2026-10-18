//! Explicit software fixtures for glue rejection/retirement, never RF readiness.
const std = @import("std");
const t = std.testing;
const api = @import("mt7922_station.zig");
const policy = @import("radio_policy.zig");
const transport = @import("mt7922_transport.zig");
const mt = @import("mediatek/root.zig");
const wifi = @import("networkkit").wifi;
const cap: @import("regulatory/root.zig").ChannelCap = .{ .band = .ghz2, .channel = 6, .center_khz = 2_437_000 };
fn station() wifi.Bss {
    return .{ .ssid = wifi.Ssid.init("Original") catch unreachable, .bssid = .{ 2, 1, 2, 3, 4, 5 }, .channel = 6, .signal_dbm = -40, .security = .wpa2_personal };
}
fn entropy(_: *anyopaque, _: *[32]u8) !void {
    return error.EntropyUnavailable;
}
fn fixture(binding: *api.Binding, device: *transport.Transport, authority: *policy.Authority) !void {
    try authority.init(1, &.{cap});
    // Isolated control facts let tests reach rejection boundaries without any
    // MMIO, DMA lease or physical command. They are NOT a production provider.
    authority.firmware.stage = .policy_submitted;
    authority.firmware.submitted_generation = authority.generation;
    device.owner_address = @intFromPtr(device);
    device.state = .firmware_ready;
    device.mcu.stopped = false;
    device.mcu.busy = false;
    binding.owner_address = @intFromPtr(binding);
    binding.transport = device;
    binding.authority = authority;
    binding.generation = authority.generation;
    binding.config = .{ .device_epoch = 1, .fixed_rate = 0, .entropy_context = binding, .entropy = entropy };
    binding.link.owner_address = @intFromPtr(&binding.link);
    binding.link.state = .await_final_tx;
    binding.selected = .{ .bss = station(), .rates = .{ .length = 1, .bytes = .{ 0x82, 0, 0, 0, 0, 0, 0, 0 } }, .supported_rates = 1, .basic_rates = 1, .beacon_interval = 100, .dtim_period = 2 };
}
test "binding rejects a second join before overwriting peer metadata awaiting M4" {
    var authority: policy.Authority = .{};
    var device: transport.Transport = .{};
    var binding: api.Binding = .{};
    try fixture(&binding, &device, &authority);
    const before = binding.selected;
    var another = station();
    another.bssid[5] = 9;
    try t.expectError(error.RadioBusy, binding.join(2, another, "fixture-only-secret", 0));
    try t.expectEqualDeep(before, binding.selected);
    try t.expectEqual(@as(u64, 0), binding.operation_highwater);
}
test "binding exhausted or busy scan does not overwrite observations and operation" {
    var authority: policy.Authority = .{};
    var device: transport.Transport = .{};
    var binding: api.Binding = .{};
    try fixture(&binding, &device, &authority);
    binding.link.state = .idle;
    binding.observation_count = 1;
    binding.observations[0] = binding.selected;
    binding.scan.sequence.issued = 127;
    try t.expectError(error.ScanSequenceExhausted, binding.startScan(5));
    try t.expectEqual(@as(usize, 1), binding.observation_count);
    try t.expectEqual(@as(u64, 0), binding.operation_highwater);
    binding.scan.sequence.issued = 0;
    device.mcu.busy = true;
    try t.expectError(error.McuBusy, binding.startScan(5));
    try t.expectEqual(@as(usize, 1), binding.observation_count);
    try t.expectEqual(@as(u64, 0), binding.operation_highwater);
}
test "binding hardware attach denies unprepared owners and unsubmitted policy without IO" {
    var authority: policy.Authority = .{};
    var device: transport.Transport = .{};
    var binding: api.Binding = .{};
    var client: mt.nic.Client = .{};
    const config: api.Config = .{ .device_epoch = 1, .fixed_rate = 0, .entropy_context = &binding, .entropy = entropy };
    try t.expectError(error.UnpreparedHardware, binding.init(&device, &authority, &client, config));
    try t.expectEqual(@as(usize, 0), binding.owner_address);
    try authority.init(1, &.{cap});
    device.owner_address = @intFromPtr(&device);
    device.state = .firmware_ready;
    client.owner_address = @intFromPtr(&client);
    client.mcu = &device.mcu;
    client.device_epoch = 1;
    try t.expectError(error.UnsubmittedPolicy, binding.init(&device, &authority, &client, config));
    try t.expect(client.events == null);
    try t.expectEqual(@as(usize, 0), binding.owner_address);
}
