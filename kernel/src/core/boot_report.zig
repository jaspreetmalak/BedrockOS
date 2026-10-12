const protocol = @import("boot_protocol");
const memory = @import("memory.zig");

pub fn print(comptime console: type, info: *const protocol.BootInfo) !void {
    const summary = try memory.summarize(info);
    console.write("[kernel] memory regions=");
    console.writeHex(summary.regions);
    console.write(" usable bytes=");
    console.writeHex(summary.usable_bytes);
    console.write(" pages=");
    console.writeHex(summary.usable_pages);
    console.write("\n");
}
