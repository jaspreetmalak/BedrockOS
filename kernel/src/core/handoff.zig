const protocol = @import("boot_protocol");
const arch = @import("../arch/root.zig");

pub fn validateHandoff(header: *const protocol.Header, available_bytes: usize) !void {
    if (available_bytes < @sizeOf(protocol.Header)) return error.HeaderTruncated;
    try header.validate(available_bytes, arch.kind);
}
