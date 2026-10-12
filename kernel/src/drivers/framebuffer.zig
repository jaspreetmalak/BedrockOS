//! A small kernel-owned text console over a firmware-described 32-bit buffer.
const protocol = @import("boot_protocol");

var surface: protocol.Framebuffer = .{};
var column: u32 = 0;
var row: u32 = 0;
const cell_width = 8;
const cell_height = 12;

pub fn configure(description: protocol.Framebuffer) void {
    surface = description;
    column = 0;
    row = 0;
    clear();
}

fn pixels() [*]volatile u32 {
    return @ptrFromInt(surface.base);
}

fn clear() void {
    if (surface.base == 0) return;
    for (0..@as(usize, surface.pixels_per_scanline) * surface.height) |i| pixels()[i] = 0;
}

fn newline() void {
    column = 0;
    row += 1;
    const rows = surface.height / cell_height;
    if (row < rows) return;
    // Keep the last lines visible without allocating a second framebuffer.
    const stride: usize = surface.pixels_per_scanline;
    const moved: usize = stride * (surface.height - cell_height);
    const skipped = stride * cell_height;
    for (0..moved) |i| pixels()[i] = pixels()[i + skipped];
    for (moved..stride * surface.height) |i| pixels()[i] = 0;
    row = rows - 1;
}

pub fn write(bytes: []const u8) void {
    if (surface.base == 0) return;
    for (bytes) |byte| {
        if (byte == '\r') {
            column = 0;
            continue;
        }
        if (byte == '\n') {
            newline();
            continue;
        }
        if (column >= surface.width / cell_width) newline();
        const bitmap = glyph(byte);
        const white = surface.red_mask | surface.green_mask | surface.blue_mask;
        const x = column * cell_width;
        const y = row * cell_height;
        for (0..cell_height) |dy| {
            for (0..cell_width) |dx| {
                const lit = dy >= 2 and dy < 9 and dx >= 1 and dx < 6 and
                    (bitmap[dy - 2] & (@as(u8, 1) << @as(u3, @intCast(5 - dx)))) != 0;
                pixels()[(@as(usize, y) + dy) * surface.pixels_per_scanline + x + dx] = if (lit) white else 0;
            }
        }
        column += 1;
    }
}

// Original 5-by-7 patterns; lower-case messages use the corresponding capital.
fn glyph(byte: u8) [7]u8 {
    const ch = if (byte >= 'a' and byte <= 'z') byte - 'a' + 'A' else byte;
    return switch (ch) {
        ' ' => .{ 0, 0, 0, 0, 0, 0, 0 },
        'A' => .{ 14, 17, 17, 31, 17, 17, 17 },
        'B' => .{ 30, 17, 17, 30, 17, 17, 30 },
        'C' => .{ 14, 17, 16, 16, 16, 17, 14 },
        'D' => .{ 30, 17, 17, 17, 17, 17, 30 },
        'E' => .{ 31, 16, 16, 30, 16, 16, 31 },
        'F' => .{ 31, 16, 16, 30, 16, 16, 16 },
        'G' => .{ 14, 17, 16, 23, 17, 17, 15 },
        'H' => .{ 17, 17, 17, 31, 17, 17, 17 },
        'I' => .{ 14, 4, 4, 4, 4, 4, 14 },
        'J' => .{ 7, 2, 2, 2, 18, 18, 12 },
        'K' => .{ 17, 18, 20, 24, 20, 18, 17 },
        'L' => .{ 16, 16, 16, 16, 16, 16, 31 },
        'M' => .{ 17, 27, 21, 21, 17, 17, 17 },
        'N' => .{ 17, 25, 25, 21, 19, 19, 17 },
        'O' => .{ 14, 17, 17, 17, 17, 17, 14 },
        'P' => .{ 30, 17, 17, 30, 16, 16, 16 },
        'Q' => .{ 14, 17, 17, 17, 21, 18, 13 },
        'R' => .{ 30, 17, 17, 30, 20, 18, 17 },
        'S' => .{ 15, 16, 16, 14, 1, 1, 30 },
        'T' => .{ 31, 4, 4, 4, 4, 4, 4 },
        'U' => .{ 17, 17, 17, 17, 17, 17, 14 },
        'V' => .{ 17, 17, 17, 17, 17, 10, 4 },
        'W' => .{ 17, 17, 17, 21, 21, 21, 10 },
        'X' => .{ 17, 17, 10, 4, 10, 17, 17 },
        'Y' => .{ 17, 17, 10, 4, 4, 4, 4 },
        'Z' => .{ 31, 1, 2, 4, 8, 16, 31 },
        '0' => .{ 14, 17, 19, 21, 25, 17, 14 },
        '1' => .{ 4, 12, 4, 4, 4, 4, 14 },
        '2' => .{ 14, 17, 1, 2, 4, 8, 31 },
        '3' => .{ 30, 1, 1, 14, 1, 1, 30 },
        '4' => .{ 2, 6, 10, 18, 31, 2, 2 },
        '5' => .{ 31, 16, 16, 30, 1, 1, 30 },
        '6' => .{ 14, 16, 16, 30, 17, 17, 14 },
        '7' => .{ 31, 1, 2, 4, 8, 8, 8 },
        '8' => .{ 14, 17, 17, 14, 17, 17, 14 },
        '9' => .{ 14, 17, 17, 15, 1, 1, 14 },
        '[' => .{ 14, 8, 8, 8, 8, 8, 14 },
        ']' => .{ 14, 2, 2, 2, 2, 2, 14 },
        ':' => .{ 0, 4, 4, 0, 4, 4, 0 },
        '=' => .{ 0, 0, 31, 0, 31, 0, 0 },
        '-' => .{ 0, 0, 0, 31, 0, 0, 0 },
        '_' => .{ 0, 0, 0, 0, 0, 0, 31 },
        '.' => .{ 0, 0, 0, 0, 0, 6, 6 },
        '/' => .{ 1, 2, 2, 4, 8, 8, 16 },
        '(' => .{ 2, 4, 8, 8, 8, 4, 2 },
        ')' => .{ 8, 4, 2, 2, 2, 4, 8 },
        else => .{ 14, 17, 1, 2, 4, 0, 4 },
    };
}

test "console drawing and scrolling stay inside the described framebuffer" {
    const std = @import("std");
    const guard: u32 = 0x5a17cafe;
    var backing: [2 + 20 * 24]u32 = @splat(guard);
    const description: protocol.Framebuffer = .{
        .base = @intFromPtr(&backing[1]),
        .size = 20 * 24 * 4,
        .width = 16,
        .height = 24,
        .pixels_per_scanline = 20,
        .format = 1,
        .red_mask = 0x00ff0000,
        .green_mask = 0x0000ff00,
        .blue_mask = 0x000000ff,
    };
    try description.validate();
    configure(description);
    defer surface = .{};
    write("A\nB");
    var white_pixels: usize = 0;
    for (backing[1 .. backing.len - 1]) |pixel| {
        if (pixel == 0xffffff) white_pixels += 1;
    }
    try std.testing.expect(white_pixels > 0);
    write("CDE\nFGH\nIJK\nL");
    try std.testing.expectEqual(guard, backing[0]);
    try std.testing.expectEqual(guard, backing[backing.len - 1]);
    for (0..24) |y| {
        for (16..20) |x| try std.testing.expectEqual(@as(u32, 0), backing[1 + y * 20 + x]);
    }
}
