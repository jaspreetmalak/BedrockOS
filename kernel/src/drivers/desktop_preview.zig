//! Temporary kernel host for the native desktop. AxisUI itself has no kernel,
//! firmware or physical-memory dependency; a future display service supplies
//! an owned surface through the same API.
const std = @import("std");
const protocol = @import("boot_protocol");
const desktop_shell = @import("desktop_shell");
const axisui = desktop_shell.axisui;
// Single-CPU boot policy owns this scratch storage exclusively. Keeping the
// bounded rendering plan here preserves the kernel's 64 KiB guarded stack.
var workspace: axisui.Workspace = undefined;

/// Call only after the boot handoff and the active supervisor framebuffer
/// mapping have been validated. Applications never receive this physical view.
pub fn show(description: protocol.Framebuffer, architecture: []const u8) !void {
    try description.validate();
    if (description.base == 0) return error.FramebufferUnavailable;
    const pixel_count = std.math.cast(usize, description.size / @sizeOf(u32)) orelse
        return error.FramebufferTooLarge;
    const pixels: [*]volatile u32 = @ptrFromInt(description.base);
    var surface = try axisui.Surface.init(
        pixels[0..pixel_count],
        description.width,
        description.height,
        description.pixels_per_scanline,
        .{ .red = description.red_mask, .green = description.green_mask, .blue = description.blue_mask },
    );
    try desktop_shell.renderWithWorkspace(&surface, &workspace, architecture);
}

test "native desktop bridge refuses absent framebuffer" {
    try std.testing.expectError(error.FramebufferUnavailable, show(.{}, "test"));
}

test "native desktop bridge validates handoff before pixel access" {
    var pixels: [16 * 24]u32 = undefined;
    @memset(&pixels, 0xdecafbad);
    var description: protocol.Framebuffer = .{
        .base = @intFromPtr(&pixels),
        .size = @sizeOf(@TypeOf(pixels)),
        .width = 16,
        .height = 24,
        .pixels_per_scanline = 16,
        .format = 1,
        .red_mask = 0xff0000,
        .green_mask = 0xff00,
        .blue_mask = 0xff,
    };
    description.size -= 1;
    try std.testing.expectError(error.InvalidFramebuffer, show(description, "test"));
    description.size += 1;
    description.green_mask = description.red_mask;
    try std.testing.expectError(error.InvalidFramebuffer, show(description, "test"));
    description.green_mask = 0xff00;
    description.format = 2;
    try std.testing.expectError(error.InvalidFramebuffer, show(description, "test"));
    for (pixels) |pixel| try std.testing.expectEqual(@as(u32, 0xdecafbad), pixel);
}
