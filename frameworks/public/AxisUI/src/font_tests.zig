const std = @import("std");
const font = @import("font.zig");
const Surface = @import("surface.zig").Surface;
const types = @import("types.zig");
const renderer = @import("render.zig");
const rgb: types.PixelMasks = .{ .red = 0xff0000, .green = 0xff00, .blue = 0xff };

test "packed native coverage preserves every original pixel and byte fallback" {
    const original = @embedFile("axis_sans.bin");
    const advances = @embedFile("axis_sans_advances.bin");
    // Compare the public sampler against the unchanged source asset, including
    // blank margins, every unsupported byte and the nonprinting controls.
    for (0..256) |value| {
        const byte: u8 = @intCast(value);
        const printable = byte >= 32 and byte < 127;
        const glyph_index: usize = (if (printable) byte else @as(u8, '?')) - 32;
        const control = byte == '\r' or byte == '\n' or byte == '\t';
        for (0..font.coverage_height + 1) |y| for (0..font.max_glyph_width + 1) |x| {
            const expected: u8 = if (control or x >= advances[glyph_index] or y >= font.coverage_height)
                0
            else
                original[glyph_index * font.max_glyph_width * font.coverage_height + y * font.max_glyph_width + x];
            try std.testing.expectEqual(expected, font.coverage(byte, @intCast(x), @intCast(y), 1));
        };
    }
}

test "control cap ink centers consistently while descenders retain their shared baseline" {
    for ([_]u32{ 24, 26, 28, 30, 31, 32, 36 }) |height| {
        var pixels: [32 * 40]u32 = @splat(0);
        var surface = try Surface.init(&pixels, 32, height, 32, rgb);
        const origin = try font.controlOriginY(0, height, 1);
        try font.paint(&surface, "H", 0, origin, types.Color.rgb(255, 255, 255), 1);
        try font.paint(&surface, "g", 16, origin, types.Color.rgb(255, 255, 255), 1);
        var first: ?u32 = null;
        var last: u32 = 0;
        var descender_last: u32 = 0;
        for (0..height) |row| {
            for (0..font.max_glyph_width) |column| if (pixels[row * 32 + column] != 0) {
                if (first == null) first = @intCast(row);
                last = @intCast(row);
            };
            for (16..16 + font.max_glyph_width) |column| if (pixels[row * 32 + column] != 0) {
                descender_last = @intCast(row);
            };
        }
        try std.testing.expect(first != null);
        // Actual AA cap pixels, including both fringes, must be centered to
        // the nearest integer row. Full-line-box centering misses by two.
        const double_center = first.? + last + 1;
        try std.testing.expect(@abs(@as(i64, double_center) - height) <= 1);
        try std.testing.expect(descender_last > last);
    }
    try std.testing.expectEqual(@as(i32, 9), try font.labelOriginY(28, 1, true));
    try std.testing.expectEqual(@as(i32, 9), try font.controlOriginY(0, 36, 1));
}

test "control label origins reject invalid scales and overflow and short labels clip safely" {
    try std.testing.expectError(error.InvalidScale, font.labelOriginY(28, 0, false));
    try std.testing.expectError(error.InvalidScale, font.controlOriginY(0, 28, 17));
    try std.testing.expectError(error.LayoutOverflow, font.controlOriginY(std.math.maxInt(i32), 28, 1));
    try std.testing.expectError(error.LayoutOverflow, font.controlOriginY(std.math.minInt(i32), 0, 1));
    try std.testing.expect(try font.labelOriginY(std.math.maxInt(u32), 16, false) >= 0);
    const sentinel: u32 = 0xa5b6c7d8;
    var backing: [2 + 37 * 6]u32 = @splat(sentinel);
    var surface = try Surface.init(backing[1 .. backing.len - 1], 32, 6, 37, rgb);
    surface.fillRect(0, 0, 32, 6, 0);
    const origin = try font.controlOriginY(0, 6, 1);
    try std.testing.expect(origin < 0);
    try font.paint(&surface, "Hyg", 0, origin, types.Color.rgb(255, 255, 255), 1);
    var visible: usize = 0;
    for (0..6) |row| {
        for (0..32) |column| visible += @intFromBool(backing[1 + row * 37 + column] != 0);
        for (32..37) |column| try std.testing.expectEqual(sentinel, backing[1 + row * 37 + column]);
    }
    try std.testing.expect(visible > 10);
    try std.testing.expectEqual(sentinel, backing[0]);
    try std.testing.expectEqual(sentinel, backing[backing.len - 1]);
}

test "Axis Sans native metrics are proportional and multiline advances match painting" {
    try std.testing.expectEqualStrings("Axis Sans", font.family);
    try std.testing.expectEqual(@as(u32, 20), font.line_height);
    try std.testing.expectEqual(@as(u32, 15), font.baseline);
    try std.testing.expectEqual(@as(u32, 12), font.cap_height);
    try std.testing.expectEqual(@as(u32, 9), font.x_height);
    try std.testing.expectEqualDeep(font.Size{ .width = 42, .height = font.line_height }, try font.measure("WWW", 1));
    try std.testing.expectEqualDeep(font.Size{ .width = 15, .height = font.line_height }, try font.measure("iii", 1));
    try std.testing.expectEqualDeep(font.Size{ .width = 102, .height = font.line_height * 4 }, try font.measure("Ab\tZ\r\nx", 2));
    try std.testing.expectEqualDeep(font.Size{}, try font.measure("", 1));
    try std.testing.expectEqual(font.glyphAdvance('?'), font.glyphAdvance(0xff));
}

test "every original printable glyph has bounded real scale1 grayscale coverage" {
    var space_ink: usize = 0;
    for (0..font.coverage_height) |y| for (0..font.max_glyph_width) |x| {
        space_ink += font.coverage(' ', @intCast(x), @intCast(y), 1);
    };
    try std.testing.expectEqual(@as(usize, 0), space_ink);
    for (33..127) |value| {
        const byte: u8 = @intCast(value);
        const advance = font.glyphAdvance(byte);
        try std.testing.expect(advance >= 3 and advance <= font.editor_advance);
        var ink: usize = 0;
        var gray: usize = 0;
        for (0..font.coverage_height) |y| for (0..font.max_glyph_width) |x| {
            const alpha = font.coverage(byte, @intCast(x), @intCast(y), 1);
            if (x >= advance) try std.testing.expectEqual(@as(u8, 0), alpha);
            ink += @intFromBool(alpha != 0);
            gray += @intFromBool(alpha != 0 and alpha != 255);
        };
        try std.testing.expect(ink != 0 and gray != 0);
        try std.testing.expectEqual(@as(u8, 0), font.coverage(byte, 0, font.coverage_height, 1));
        try std.testing.expectEqual(@as(u8, 0), font.coverage(byte, std.math.maxInt(u32), 0, 1));
    }
    for (0..font.coverage_height) |y| for (0..font.max_glyph_width) |x| {
        try std.testing.expectEqual(font.coverage('?', @intCast(x), @intCast(y), 1), font.coverage(0xff, @intCast(x), @intCast(y), 1));
    };
}

test "smooth paint clips signed origins and preserves stride padding and guards" {
    const sentinel: u32 = 0xa5b6c7d8;
    var backing: [2 + 37 * 20]u32 = @splat(sentinel);
    var surface = try Surface.init(backing[1 .. backing.len - 1], 32, 20, 37, rgb);
    surface.fillRect(0, 0, 32, 20, surface.encode(types.Color.rgb(20, 30, 40)));
    try font.paint(&surface, "Axis Sans\nx", -5, -3, types.Color.rgb(220, 230, 240), 1);
    try font.paintGlyph(&surface, 'W', 18, 5, types.Color.rgb(200, 170, 130), 2);
    try std.testing.expectEqual(sentinel, backing[0]);
    try std.testing.expectEqual(sentinel, backing[backing.len - 1]);
    for (0..20) |y| for (32..37) |x| try std.testing.expectEqual(sentinel, backing[1 + y * 37 + x]);
    var gray: usize = 0;
    for (0..20) |y| for (0..32) |x| {
        const pixel = backing[1 + y * 37 + x];
        if (pixel != 0x141e28 and pixel != 0xdce6f0 and pixel != 0xc8aa82) gray += 1;
    };
    try std.testing.expect(gray > 20);
    const before = backing;
    try std.testing.expectError(error.InvalidScale, font.paint(&surface, "text", 0, 0, types.Color.rgb(1, 2, 3), 0));
    try std.testing.expectError(error.InvalidScale, font.paintGlyph(&surface, 'a', 0, 0, types.Color.rgb(1, 2, 3), 17));
    try std.testing.expectEqualSlices(u32, &before, &backing);
    try font.paint(&surface, "outside", std.math.minInt(i32), std.math.maxInt(i32), types.Color.rgb(1, 2, 3), 16);
    try std.testing.expectEqualSlices(u32, &before, &backing);
}

test "the original smooth alphabet preserves distinct lowercase and printable identities" {
    var shapes: [font.glyph_count][font.max_glyph_width * font.coverage_height]u8 = undefined;
    for (32..127) |value| {
        for (0..font.coverage_height) |y| for (0..font.max_glyph_width) |x| {
            shapes[value - 32][y * font.max_glyph_width + x] = font.coverage(@intCast(value), @intCast(x), @intCast(y), 1);
        };
    }
    for ('a'..'z' + 1) |value| try std.testing.expect(!std.mem.eql(u8, &shapes[value - 32], &shapes[value - 'a' + 'A' - 32]));
    for (0..95) |value| for (0..value) |earlier| try std.testing.expect(!std.mem.eql(u8, &shapes[value], &shapes[earlier]));
}

test "coverage blending honors RGB BGR reduced and scattered masks without reserved bits" {
    for ([_]types.PixelMasks{
        rgb,                                              .{ .red = 0xff, .green = 0xff00, .blue = 0xff0000 },
        .{ .red = 0xf800, .green = 0x7e0, .blue = 0x1f }, .{ .red = 0b10001, .green = 0b100010, .blue = 0b1000100, .reserved = 0x80000000 },
    }) |masks| {
        var pixels: [1]u32 = .{0};
        var surface = try Surface.init(&pixels, 1, 1, 1, masks);
        const foreground = types.Color.rgb(224, 160, 48);
        pixels[0] = surface.encode(types.Color.rgb(32, 64, 96));
        const old = surface.decode(pixels[0]);
        const before = pixels[0];
        surface.blendPixel(0, 0, foreground, 0);
        try std.testing.expectEqual(before, pixels[0]);
        surface.blendPixel(0, 0, foreground, 128);
        const expected = types.Color.rgb(
            @intCast((224 * @as(u32, 128) + @as(u32, old.r) * 127 + 127) / 255),
            @intCast((160 * @as(u32, 128) + @as(u32, old.g) * 127 + 127) / 255),
            @intCast((48 * @as(u32, 128) + @as(u32, old.b) * 127 + 127) / 255),
        );
        try std.testing.expectEqual(surface.encode(expected), pixels[0]);
        try std.testing.expectEqual(@as(u32, 0), pixels[0] & masks.reserved);
        surface.blendPixel(0, 0, foreground, 255);
        try std.testing.expectEqual(surface.encode(foreground), pixels[0]);
    }
}

test "native scale2 follows outlines rather than repeating smaller bitmap cells" {
    var replicated = true;
    for (0..font.coverage_height * 2) |y| for (0..font.max_glyph_width * 2) |x| {
        if (font.coverage('A', @intCast(x), @intCast(y), 2) != font.coverage('A', @intCast(x / 2), @intCast(y / 2), 1)) replicated = false;
    };
    try std.testing.expect(!replicated);
}

test "larger native strikes keep straight stems sharp with only boundary coverage" {
    for ([_]u8{ 2, 3, 4, 8, 16 }) |scale| {
        const row = (font.baseline - font.cap_height / 2) * scale;
        var solid: usize = 0;
        var partial: usize = 0;
        var first: ?u32 = null;
        var last: u32 = 0;
        for (0..font.glyphAdvance('I') * scale) |column| {
            const alpha = font.coverage('I', @intCast(column), row, scale);
            if (alpha == 0) continue;
            if (first == null) first = @intCast(column);
            last = @intCast(column);
            solid += @intFromBool(alpha == 255);
            partial += @intFromBool(alpha != 255);
        }
        // An axis-aligned stem has two geometric edges. More than one partial
        // pixel at either edge exposes blur from enlarging a smaller raster.
        try std.testing.expect(first != null and solid != 0);
        try std.testing.expect(partial <= 2);
        try std.testing.expectEqual(@as(usize, last - first.? + 1), solid + partial);
    }
}

test "native strike clipping fallback and nonprinting coverage hold at every supported scale" {
    for (1..17) |value| {
        const scale: u8 = @intCast(value);
        for ([_]u8{ 'I', 'W', 'g', '?' }) |byte| {
            const width = font.glyphAdvance(byte) * scale;
            const height = font.coverage_height * scale;
            try std.testing.expectEqual(@as(u8, 0), font.coverage(byte, width, height / 2, scale));
            try std.testing.expectEqual(@as(u8, 0), font.coverage(byte, 0, height, scale));
            try std.testing.expectEqual(@as(u8, 0), font.coverage(byte, std.math.maxInt(u32), 0, scale));
            try std.testing.expectEqual(@as(u8, 0), font.coverage(byte, 0, std.math.maxInt(u32), scale));
        }
        for (0..font.coverage_height * scale) |y| for (0..font.max_glyph_width * scale) |x| {
            try std.testing.expectEqual(font.coverage('?', @intCast(x), @intCast(y), scale), font.coverage(0xff, @intCast(x), @intCast(y), scale));
        };
        for ([_]u8{ ' ', '\t', '\r', '\n' }) |byte| {
            try std.testing.expectEqual(@as(u8, 0), font.coverage(byte, scale, scale, scale));
        }
    }
    try std.testing.expectEqual(@as(u8, 0), font.coverage('A', 0, 0, 0));
    try std.testing.expectEqual(@as(u8, 0), font.coverage('A', 0, 0, 17));
}

test "every enlarged printable outline retains ink and its bounded proportional advance" {
    for ([_]u8{ 2, 3, 8, 16 }) |scale| {
        for (33..127) |value| {
            const byte: u8 = @intCast(value);
            const width = font.glyphAdvance(byte) * scale;
            var ink: usize = 0;
            // Probe each design-pixel cell at the destination resolution. This
            // exercises every compact outline, including curves and pen moves,
            // without enlarging the base face or depending on its raster bytes.
            for (0..font.coverage_height) |y| for (0..font.max_glyph_width) |x| {
                const column: u32 = @intCast(x * scale + scale / 2);
                const row: u32 = @intCast(y * scale + scale / 2);
                const alpha = font.coverage(byte, column, row, scale);
                if (column >= width) try std.testing.expectEqual(@as(u8, 0), alpha);
                ink += @intFromBool(alpha != 0);
            };
            try std.testing.expect(ink != 0);
        }
    }
}

test "explicit legacy face retains 5x7 glyphs and matching measure without changing the native default" {
    try std.testing.expectEqualDeep(font.Size{ .width = 12, .height = 10 }, try font.measureLegacy("Ai", 1));
    var pixels: [24 * 20]u32 = @splat(0);
    var surface = try Surface.init(&pixels, 24, 20, 24, rgb);
    try std.testing.expect(!surface.legacy_text);
    surface.legacy_text = true;
    var workspace: renderer.Workspace = undefined;
    const children = [_]types.View{ types.Text("A"), types.Spacer().frame(2, null).background(types.Color.rgb(0, 0, 255)) };
    const view = types.HStack(&children);
    try renderer.renderWithWorkspace(&surface, &workspace, view);
    try std.testing.expectEqual(@as(u32, 0xffffff), pixels[1 * 24 + 1]);
    try std.testing.expectEqual(@as(u32, 0xff), pixels[6]);
    try std.testing.expectEqual(@as(u32, 0), pixels[5]);
    surface.legacy_text = false;
    @memset(&pixels, 0);
    try renderer.renderWithWorkspace(&surface, &workspace, view);
    try std.testing.expectEqual(@as(u32, 0xff), pixels[font.glyphAdvance('A')]);
    try std.testing.expectEqual(@as(u32, 0), pixels[font.glyphAdvance('A') - 1]);
    try std.testing.expectEqual(@as(u32, 0), pixels[1 * 24 + 1]);
}
