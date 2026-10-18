//! Strong native provider probes; callers must supply opted-in trusted state.
const platform = @import("x86_64.zig");
const protocol = @import("boot_protocol");
const pci = @import("pci");
const transport = @import("../mt7922_transport.zig");
export fn bedrock_mt7922_native_prepare(provider: *platform.Provider, info: *const protocol.BootInfo, device: *const pci.Device, options: *const platform.Options) callconv(.c) bool {
    provider.prepare(info, device.*, options.*) catch return false;
    return true;
}
export fn bedrock_mt7922_native_takeover(provider: *platform.Provider, port: *transport.Transport) callconv(.c) bool {
    provider.takeover() catch return false;
    provider.bindTransport(port) catch return false;
    port.prepare(provider.config(), provider.device, provider.platform()) catch return false;
    return true;
}
export fn bedrock_mt7922_native_clock(provider: *platform.Provider) callconv(.c) u64 {
    return provider.nowMicros() catch 0;
}
