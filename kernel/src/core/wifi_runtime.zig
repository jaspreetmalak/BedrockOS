//! No physical adapter is supported yet. Simulation is compiled only into
//! dedicated acceptance kernels; normal kernels never invent a wireless link.
const core = @import("network_core");
const wifi = core.networkkit.wifi;
const options = @import("kernel_options");
const protocol = @import("boot_protocol");
const drivers = @import("wifi_drivers");
var controller: core.wifi.Controller = .{};
var radio: core.wifi_test_radio.TestRadio = .{};
var initialized = false;
var devices: drivers.Inventory = .{};

pub fn initialize(info: *const protocol.BootInfo, now: u64) !void {
    if (initialized) return;
    if (options.wifi_acceptance) try controller.init(radio.backend(), now);
    // Read-only discovery cannot enable PCI bus mastering or stage DMA. The
    // translated protocol modules become a live backend only when the complete
    // ownership/firmware/MLME/key/data path is wired and qualified.
    devices = drivers.discover(info) catch .{};
    initialized = true;
}
pub fn inventory() *const drivers.Inventory {
    return &devices;
}
pub fn status() wifi.Status {
    if (!options.wifi_acceptance or !initialized)
        return .{ .state = .unavailable, .failure = .none, .simulated = false, .revision = 1, .current = null };
    return controller.status();
}
fn ready() !void {
    if (!options.wifi_acceptance or !initialized) return error.RadioUnavailable;
}
pub fn poll(now: u64) void {
    if (options.wifi_acceptance and initialized) controller.poll(now);
}
pub fn startScan(now: u64) !void {
    try ready();
    try controller.startScan(now);
}
pub fn scan() !wifi.Scan {
    try ready();
    return controller.scan();
}
pub fn join(generation: u64, index: usize, credentials: *wifi.Credentials, now: u64) !void {
    defer credentials.clear();
    try ready();
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
