pub const boot_protocol = @import("boot_protocol");
pub const arch = @import("arch/root.zig");
const handoff = @import("core/handoff.zig");

pub fn prepareHeader() boot_protocol.Header {
    return handoff.prepareHeader(arch.kind);
}
