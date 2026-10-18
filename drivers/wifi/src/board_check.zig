//! Standalone native tests/PIC probes; never a boot-time hardware exercise.
pub const board = @import("mediatek/board.zig");
pub const probes = @import("mediatek/board_tests.zig");
export fn bedrock_board_power_query(client: *@import("mediatek/nic.zig").Client, output: *board.PowerReport) callconv(.c) bool {
    output.* = client.txPowerInfo() catch return false;
    return true;
}
test {
    _ = @import("mediatek/root.zig");
    _ = probes;
}
