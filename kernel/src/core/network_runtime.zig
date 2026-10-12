//! One retained NIC and packet stack for named coherent-DMA QEMU references.
const protocol = @import("boot_protocol");
const virtio = @import("virtio");
const core = @import("network_core");
pub const networkkit = core.networkkit;
var nic: ?virtio.Net = null;
var stack: core.Stack = .{};
var initialized = false;
var available = false;
var receive_buffer: [core.max_frame]u8 = undefined;

/// Optional NIC absence never breaks an existing non-network boot profile.
pub fn initialize(info: *const protocol.BootInfo) !void {
    if (initialized) return;
    initialized = true;
    const devices = virtio.discover(info) catch return;
    for (devices.items[0..devices.count]) |device| {
        if (device.device_id != 1) continue;
        if (nic != null) {
            disable();
            return;
        }
        nic = virtio.Net.init(device) catch return;
    }
    if (nic == null) return;
    stack.init(.{ .mac = nic.?.mac }, .{ .context = &nic.?, .send = transmit }) catch {
        disable();
        return;
    };
    available = true;
}
fn transmit(_: *anyopaque, frame: []const u8) !void {
    if (!available or nic == null) return error.NetworkUnavailable;
    nic.?.send(frame) catch |err| {
        if (err == error.WouldBlock or err == error.NetworkBusy) return error.WouldBlock;
        disable();
        return error.NetworkUnavailable;
    };
}
fn disable() void {
    available = false;
    // Quiesce DMA but retain permanent allocations: freeing them mid-workload
    // would invalidate the process allocator baseline after a network failure.
    // Failed reset also retains every exposed page instead of recycling it.
    if (nic) |*device| device.device.reset() catch {};
}
pub fn shutdown() void {
    available = false;
    if (nic) |*device| device.deinit() catch return;
    nic = null;
}
pub fn isAvailable() bool {
    return available;
}
pub fn poll() void {
    if (!available) return;
    for (0..16) |_| {
        const length = (nic.?.receive(&receive_buffer) catch |err| {
            if (err == error.OutputTooSmall) continue;
            disable();
            return;
        }) orelse return;
        if (length > receive_buffer.len) {
            disable();
            return;
        }
        stack.ingest(receive_buffer[0..length]);
        // An ARP response can transmit through the callback and stop/reset the
        // NIC. Never consume or repost another descriptor after that transition.
        if (!available) return;
    }
}
fn ready() !void {
    if (!available) return error.NetworkUnavailable;
}
pub fn open(peer: networkkit.Endpoint) !u64 {
    try ready();
    return stack.open(peer);
}
pub fn send(id: u64, bytes: []const u8) !usize {
    try ready();
    return stack.send(id, bytes);
}
pub fn peek(id: u64) !?usize {
    try ready();
    return stack.peek(id);
}
pub fn receive(id: u64, output: []u8) !usize {
    try ready();
    return stack.receive(id, output);
}
/// Closing remains possible after a failed device, so authority can be reclaimed.
pub fn close(id: u64) !void {
    try stack.close(id);
}
pub fn liveCount() usize {
    return stack.liveCount();
}
