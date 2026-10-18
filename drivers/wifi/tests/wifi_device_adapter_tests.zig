//! Direct binding lifetime checks retained with the driver sources. Production
//! module adapter checks live in kernel/src/core/wifi_module_adapter_tests.zig.
const std = @import("std");
const api = @import("wifi_device_adapter.zig");
const drivers = @import("wifi_drivers");
const core = @import("network_core");
test "native SDK adapter never grants stale wireless L2 traffic after device reset" {
    var authority: drivers.radio_policy.Authority = .{};
    const cap: drivers.regulatory.ChannelCap = .{ .band = .ghz2, .channel = 6, .center_khz = 2_437_000 };
    try authority.init(1, &.{cap});
    authority.firmware.stage = .policy_submitted;
    authority.firmware.submitted_generation = authority.generation;
    var device: drivers.mt7922_transport.Transport = .{};
    device.owner_address = @intFromPtr(&device);
    device.state = .firmware_ready;
    device.mcu.stopped = false;
    var binding: drivers.mt7922_station.Binding = .{};
    binding.owner_address = @intFromPtr(&binding);
    binding.transport = &device;
    binding.authority = &authority;
    binding.generation = authority.generation;
    binding.config.device_epoch = 1;
    binding.link.state = .connected;
    var adapter: api.Adapter = .{ .radio = &binding, .now = 0, .enabled = true };
    const backend = adapter.backend();
    try std.testing.expect(!backend.simulated and backend.capabilities.scan and backend.capabilities.wpa2_psk and !backend.capabilities.open);
    try std.testing.expect(api.Adapter.connected(&adapter));
    try authority.afterDeviceReset(2, &.{cap});
    try std.testing.expect(!api.Adapter.connected(&adapter));
    // Rejected before any DMA/packet callback or access to unprepared rings.
    try std.testing.expectError(error.NetworkUnavailable, api.Adapter.send(&adapter, &.{}));
}
test "SDK controller reports device loss when disconnect retires the native binding" {
    var device: drivers.mt7922_transport.Transport = .{};
    device.state = .stopped;
    var binding: drivers.mt7922_station.Binding = .{};
    binding.owner_address = @intFromPtr(&binding);
    binding.stopped = true;
    binding.transport = &device;
    binding.link.state = .idle;
    var adapter: api.Adapter = .{ .radio = &binding, .now = 0, .enabled = true };
    var controller: core.wifi.Controller = .{ .initialized = true, .enabled = true, .state = .connected, .backend = adapter.backend() };
    try std.testing.expectError(error.NetworkUnavailable, controller.disconnect(0));
    try std.testing.expectEqual(core.networkkit.wifi.State.failed, controller.status().state);
    try std.testing.expectEqual(core.networkkit.wifi.Failure.device_lost, controller.status().failure);
    try std.testing.expect(!controller.enabled and !adapter.enabled);
}
