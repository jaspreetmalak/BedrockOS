//! Kernel-owned, polling VirtIO block, network and input for named QEMU profiles.
//! Modern MMIO on ARM/RV and modern PCI capabilities on q35 bus zero; identity
//! device mappings and coherent DMA are integration preconditions.
pub const transport = @import("transport.zig");
pub const Transport = transport.Transport;
pub const Devices = transport.Devices;
pub const discover = transport.discover;
pub const Block = @import("block.zig").Block;
pub const Net = @import("net.zig").Net;
pub const Input = @import("input.zig").Input;
pub const Event = @import("input.zig").Event;
pub const Axis = @import("input.zig").Axis;
pub const Decoder = @import("decode.zig").Decoder;
test {
    _ = @import("queue.zig");
    _ = @import("block.zig");
    _ = @import("net.zig");
    _ = @import("input.zig");
    _ = @import("decode.zig");
}
