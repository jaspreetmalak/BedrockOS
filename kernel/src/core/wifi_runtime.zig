//! Trusted boot-time native-radio attachment and protected application controls.
const core = @import("network_core");
const wifi = core.networkkit.wifi;
const options = @import("kernel_options");
const protocol = @import("boot_protocol");
const pci = @import("pci");
const pci_native = @import("pci_native");
const abi = @import("driver_abi");
const adapter_api = @import("wifi_module_adapter.zig");
const network = @import("network_runtime.zig");
const modules = @import("driver_runtime.zig");
var controller: core.wifi.Controller = .{};
var radio: core.wifi_test_radio.TestRadio = .{};
var initialized = false;
pub const Candidate = struct { device: pci.Device };
pub const Inventory = struct { candidates: [16]Candidate = undefined, count: usize = 0 };
var devices: Inventory = .{};
var hardware: ?adapter_api.Adapter = null;
var attaching = false;

/// Trusted platform entry, after real firmware/calibration/regulatory/MMIO/DMA
/// preparation. Normal boot invokes it only after the named port succeeds.
fn attach(radio_table: *const abi.Radio, now: u64) bool {
    if (options.wifi_acceptance or attaching or hardware != null or controller.initialized) return false;
    attaching = true;
    defer attaching = false;
    hardware = .{};
    hardware.?.init(radio_table, now) catch {
        hardware = null;
        return false;
    };
    controller.init(hardware.?.backend(), now) catch {
        // This fresh controller has no published operations or IP binding yet.
        // Stop while its borrowed adapter still exists, then remove all kernel
        // references before false lets the caller handle attachment failure.
        hardware.?.stop() catch {};
        controller = .{};
        hardware = null;
        return false;
    };
    initialized = true;
    return true;
}
/// Opt-in static address belongs to a trusted administrator/platform. The MAC
/// must be the card's actual capability fact; applications cannot forge it.
pub export fn bedrock_wifi_static_address(config: *const core.Config) callconv(.c) bool {
    if (attaching) return false;
    const device = if (hardware) |*value| value else return false;
    if (!@import("std").mem.eql(u8, &config.mac, &device.address)) return false;
    network.attachWireless(config.*, .{ .context = device, .send = adapter_api.Adapter.send }, device, adapter_api.Adapter.connected) catch return false;
    device.sink = .{ .context = device, .ingest = network.ingestWireless };
    return true;
}

pub fn initialize(info: *const protocol.BootInfo, now: u64) !void {
    if (initialized) return;
    defer {
        @import("std").crypto.secureZero(u8, &@constCast(&info.wifi).seed);
        @constCast(&info.wifi).flags &= ~protocol.WifiBootFlags.entropy;
    }
    if (options.wifi_acceptance) try controller.init(radio.backend(), now);
    if (pci_native.legacy(info)) |config| {
        const found = pci.wirelessInventory(config, 0, 0, 255) catch pci.Inventory{};
        devices.count = found.count;
        for (found.items[0..found.count], 0..) |value, i| devices.candidates[i] = .{ .device = value };
    } else |_| {}
    if (options.uefi_entry and !options.wifi_acceptance) {
        const physical = modules.initialize(info, now) catch null;
        if (physical) |value| {
            if (!attach(value, now)) modules.stop();
        }
    }
    initialized = true;
}
pub fn bootReport() abi.Report {
    return modules.report();
}
pub fn inventory() *const Inventory {
    return &devices;
}
pub fn status() wifi.Status {
    if ((!options.wifi_acceptance and hardware == null) or !initialized)
        return .{ .state = .unavailable, .failure = .none, .simulated = false, .revision = 1, .current = null };
    return controller.status();
}
fn ready() !void {
    if ((!options.wifi_acceptance and hardware == null) or !initialized) return error.RadioUnavailable;
}
pub fn poll(now: u64) void {
    if (hardware) |*device| device.now = now;
    if ((options.wifi_acceptance or hardware != null) and initialized) controller.poll(now);
}
pub fn startScan(now: u64) !void {
    try ready();
    if (hardware) |*device| device.now = now;
    try controller.startScan(now);
}
pub fn scan() !wifi.Scan {
    try ready();
    return controller.scan();
}
pub fn join(generation: u64, index: usize, credentials: *wifi.Credentials, now: u64) !void {
    defer credentials.clear();
    try ready();
    if (hardware) |*device| device.now = now;
    try controller.join(generation, index, credentials, now);
}
pub fn disconnect(now: u64) !void {
    try ready();
    try controller.disconnect(now);
}
pub fn setEnabled(enabled: bool, now: u64) !void {
    try ready();
    try controller.setEnabled(enabled, now);
}
