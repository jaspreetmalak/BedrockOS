const std = @import("std");
const ui = @import("root.zig");
const rgb: ui.PixelMasks = .{ .red = 0xff0000, .green = 0xff00, .blue = 0xff };
const red = ui.Color.rgb(255, 0, 0);
const green = ui.Color.rgb(0, 255, 0);
const blue = ui.Color.rgb(0, 0, 255);

test "surface rejects invalid geometry capacity masks and oversized coordinates" {
    var pixels: [64]u32 = @splat(0xdeadbeef);
    try std.testing.expectError(error.InvalidSurface, ui.Surface.init(&pixels, 0, 8, 8, rgb));
    try std.testing.expectError(error.InvalidSurface, ui.Surface.init(&pixels, 9, 8, 8, rgb));
    try std.testing.expectError(error.InvalidSurface, ui.Surface.init(&pixels, 8, 9, 8, rgb));
    try std.testing.expectError(error.SurfaceTooLarge, ui.Surface.init(&pixels, 16385, 1, 16385, rgb));
    try std.testing.expectError(error.InvalidPixelMasks, ui.Surface.init(&pixels, 8, 8, 8, .{ .red = 0, .green = 2, .blue = 4 }));
    try std.testing.expectError(error.InvalidPixelMasks, ui.Surface.init(&pixels, 8, 8, 8, .{ .red = 1, .green = 1, .blue = 4 }));
    try std.testing.expectError(error.InvalidPixelMasks, ui.Surface.init(&pixels, 8, 8, 8, .{ .red = 1, .green = 2, .blue = 4, .reserved = 2 }));
    try std.testing.expectError(error.InvalidSurface, ui.Surface.init(&pixels, 8, 8, std.math.maxInt(u32), rgb));
    const wrapped: [*]volatile u32 = @ptrFromInt(std.math.maxInt(usize) & ~@as(usize, 3));
    try std.testing.expectError(error.InvalidSurface, ui.Surface.init(wrapped[0..2], 2, 1, 2, rgb));
    for (pixels) |pixel| try std.testing.expectEqual(@as(u32, 0xdeadbeef), pixel);
}

test "color encoding handles RGB BGR reduced precision and scattered masks" {
    var pixels: [1]u32 = .{0};
    var surface = try ui.Surface.init(&pixels, 1, 1, 1, rgb);
    try std.testing.expectEqual(@as(u32, 0xff0000), surface.encode(red));
    surface = try ui.Surface.init(&pixels, 1, 1, 1, .{ .red = 0xff, .green = 0xff00, .blue = 0xff0000 });
    try std.testing.expectEqual(@as(u32, 0xff), surface.encode(red));
    surface = try ui.Surface.init(&pixels, 1, 1, 1, .{ .red = 0xf800, .green = 0x7e0, .blue = 0x1f });
    try std.testing.expectEqual(@as(u32, 0xf800), surface.encode(red));
    try std.testing.expectEqual(@as(u32, 0x07e0), surface.encode(green));
    try std.testing.expectEqual(@as(u32, 0xffff), surface.encode(ui.Color.rgb(255, 255, 255)));
    surface = try ui.Surface.init(&pixels, 1, 1, 1, .{ .red = 0b10001, .green = 0b100010, .blue = 0b1000100, .reserved = 0x80000000 });
    try std.testing.expectEqual(@as(u32, 0b10000), surface.encode(ui.Color.rgb(170, 0, 0)));
    try std.testing.expectEqual(@as(u32, 0b1110111), surface.encode(ui.Color.rgb(255, 255, 255)));
    try ui.render(&surface, ui.Spacer().background(ui.Color.rgb(170, 0, 0)));
    try std.testing.expectEqual(@as(u32, 0b10000), pixels[0]);
}

test "oversized descendants clip to padded ancestors and preserve scanline padding canaries" {
    const guard: u32 = 0x51abf00d;
    var backing: [2 + 20 * 16]u32 = @splat(guard);
    var surface = try ui.Surface.init(backing[1 .. backing.len - 1], 16, 16, 20, rgb);
    const children = [_]ui.View{ui.Spacer().frame(100, 100).background(red)};
    try ui.render(&surface, ui.ZStack(&children).padding(3).background(blue));
    try std.testing.expectEqual(guard, backing[0]);
    try std.testing.expectEqual(guard, backing[backing.len - 1]);
    for (0..16) |y| {
        for (0..16) |x| {
            const expected: u32 = if (x >= 3 and x < 13 and y >= 3 and y < 13) 0xff0000 else 0xff;
            try std.testing.expectEqual(expected, backing[1 + y * 20 + x]);
        }
        for (16..20) |x| try std.testing.expectEqual(guard, backing[1 + y * 20 + x]);
    }
}

test "horizontal intrinsic frames padding gaps and weighted flex determine actual pixels" {
    var pixels: [40 * 16]u32 = @splat(0);
    var surface = try ui.Surface.init(&pixels, 40, 16, 40, rgb);
    const children = [_]ui.View{
        ui.Spacer().frame(6, null).background(red),
        ui.Spacer().flex(1).background(green),
        ui.Spacer().flex(3).background(blue),
    };
    try ui.render(&surface, ui.HStack(&children).padding(2).gap(1));
    // Content width36: fixed6 + two gaps2 + flexible28 => 7 and21.
    try std.testing.expectEqual(@as(u32, 0xff0000), pixels[2 * 40 + 2]);
    try std.testing.expectEqual(@as(u32, 0xff0000), pixels[2 * 40 + 7]);
    try std.testing.expectEqual(@as(u32, 0), pixels[2 * 40 + 8]);
    try std.testing.expectEqual(@as(u32, 0xff00), pixels[2 * 40 + 9]);
    try std.testing.expectEqual(@as(u32, 0xff00), pixels[2 * 40 + 15]);
    try std.testing.expectEqual(@as(u32, 0), pixels[2 * 40 + 16]);
    try std.testing.expectEqual(@as(u32, 0xff), pixels[2 * 40 + 17]);
    try std.testing.expectEqual(@as(u32, 0xff), pixels[13 * 40 + 37]);
    try std.testing.expectEqual(@as(u32, 0), pixels[14 * 40 + 37]);
}

test "vertical stacks center fixed cross-axis frames and place overlays in declaration order" {
    var pixels: [20 * 20]u32 = @splat(0);
    var surface = try ui.Surface.init(&pixels, 20, 20, 20, rgb);
    const rows = [_]ui.View{
        ui.Spacer().frame(4, 3).background(red),
        ui.Spacer().frame(6, 5).background(green),
    };
    try ui.render(&surface, ui.VStack(&rows).padding(2).gap(1).@"align"(.center));
    try std.testing.expectEqual(@as(u32, 0xff0000), pixels[2 * 20 + 8]);
    try std.testing.expectEqual(@as(u32, 0), pixels[2 * 20 + 7]);
    try std.testing.expectEqual(@as(u32, 0xff00), pixels[6 * 20 + 7]);
    try std.testing.expectEqual(@as(u32, 0), pixels[5 * 20 + 8]);
    const layers = [_]ui.View{ ui.Spacer().frame(20, 20).background(blue), ui.Spacer().frame(4, 4).background(red) };
    try ui.render(&surface, ui.ZStack(&layers).@"align"(.center));
    try std.testing.expectEqual(@as(u32, 0xff), pixels[0]);
    try std.testing.expectEqual(@as(u32, 0xff0000), pixels[8 * 20 + 8]);
    try std.testing.expectEqual(@as(u32, 0xff), pixels[12 * 20 + 12]);
}

test "proportional text intrinsic size and inherited color scale contribute to stack placement" {
    const height = ui.font.line_height * 2 + 4;
    var pixels: [48 * height]u32 = @splat(0);
    var surface = try ui.Surface.init(&pixels, 48, height, 48, rgb);
    const children = [_]ui.View{ ui.Text("A"), ui.Spacer().frame(4, null).background(blue) };
    try ui.render(&surface, ui.HStack(&children).padding(2).foreground(red).scale(2));
    const next = 2 + ui.font.glyphAdvance('A') * 2;
    try std.testing.expectEqual(@as(u32, 0xff), pixels[2 * 48 + next]);
    try std.testing.expectEqual(@as(u32, 0), pixels[2 * 48 + next - 1]);
    var ink: usize = 0;
    var antialiased: usize = 0;
    for (0..height) |y| for (2..next) |x| {
        const pixel = pixels[y * 48 + x];
        try std.testing.expect(pixel & 0xffff == 0);
        if (pixel != 0) ink += 1;
        if (pixel != 0 and pixel != 0xff0000) antialiased += 1;
    };
    try std.testing.expect(ink > 20 and antialiased > 10);
}

test "rounded ancestor clips child corners and border overlays child backgrounds" {
    const guard: u32 = 0x51abf00d;
    var pixels: [12 * 12]u32 = @splat(guard);
    var surface = try ui.Surface.init(&pixels, 12, 12, 12, rgb);
    const children = [_]ui.View{ui.Spacer().background(red)};
    try ui.render(&surface, ui.ZStack(&children).background(blue).cornerRadius(5).border(green, 1));
    try std.testing.expectEqual(guard, pixels[0]);
    try std.testing.expectEqual(@as(u32, 0xff00), pixels[5]);
    try std.testing.expectEqual(@as(u32, 0xff0000), pixels[6 * 12 + 6]);
    try std.testing.expectEqual(@as(u32, 0xff00), pixels[6 * 12]);
}

test "text alignment centers glyphs inside its fixed outer frame" {
    var pixels: [16 * 24]u32 = @splat(0);
    var surface = try ui.Surface.init(&pixels, 16, 24, 16, rgb);
    try ui.render(&surface, ui.Text("A").frame(16, 24).@"align"(.center).foreground(red).background(blue));
    // The cap-height band is centered; the font's line descent is not mistaken
    // for visible label height. Width follows the face's proportional advance.
    const glyph_width = ui.font.glyphAdvance('A');
    const origin_x = (16 - glyph_width) / 2;
    const origin_y: usize = @intCast(try ui.font.controlOriginY(0, 24, 1));
    for (0..24) |y| for (0..16) |x| {
        const alpha: u32 = if (x >= origin_x and x < origin_x + glyph_width and y >= origin_y and y < origin_y + ui.font.coverage_height) ui.font.coverage('A', @intCast(x - origin_x), @intCast(y - origin_y), 1) else 0;
        try std.testing.expectEqual((alpha << 16) | (255 - alpha), pixels[y * 16 + x]);
    };
}

test "control labels share a baseline across horizontal alignments and retain descenders" {
    const stride = 101;
    const width = 96;
    const height = 28;
    const guard: u32 = 0x315779;
    var memory: [height * stride + 2]u32 = @splat(guard);
    var surface = try ui.Surface.init(memory[1 .. memory.len - 1], width, height, stride, rgb);
    const children = [_]ui.View{
        ui.Text("g").frame(32, 28).padding(6).@"align"(.start).textVerticalAlign(.center).foreground(red),
        ui.Text("g").frame(32, 28).padding(6).@"align"(.center).textVerticalAlign(.center).foreground(red),
        ui.Text("g").frame(32, 28).padding(6).@"align"(.end).textVerticalAlign(.center).foreground(red),
    };
    try ui.render(&surface, ui.HStack(&children).background(blue));
    var first: [3]usize = @splat(height);
    var last: [3]usize = @splat(0);
    var ink: [3]usize = @splat(0);
    for (0..height) |y| for (0..width) |x| {
        const pixel = memory[1 + y * stride + x];
        if (pixel & 0xff0000 == 0) continue;
        const column = x / 32;
        first[column] = @min(first[column], y);
        last[column] = @max(last[column], y);
        ink[column] += 1;
    };
    for (1..3) |column| {
        try std.testing.expectEqual(first[0], first[column]);
        try std.testing.expectEqual(last[0], last[column]);
        try std.testing.expectEqual(ink[0], ink[column]);
    }
    // Coverage in the descent enters the leaf's own padding, while each text
    // leaf and the surface retain their complete outer clipping boundaries.
    try std.testing.expect(last[0] > height - 6 - 1);
    try std.testing.expect(ink[0] != 0);
    try std.testing.expectEqual(guard, memory[0]);
    try std.testing.expectEqual(guard, memory[memory.len - 1]);
    for (0..height) |y| for (width..stride) |x| try std.testing.expectEqual(guard, memory[1 + y * stride + x]);
}

test "legacy centered text retains its historical line-box placement" {
    var pixels: [16 * 24]u32 = @splat(0);
    var surface = try ui.Surface.init(&pixels, 16, 24, 16, rgb);
    surface.legacy_text = true;
    try ui.render(&surface, ui.Text("A").frame(16, 24).@"align"(.center).foreground(red).background(blue));
    for (0..24) |y| for (0..16) |x| {
        const lit = x >= 5 and x < 10 and y >= 8 and y < 15 and (ui.font.glyph('A')[y - 8] & (@as(u8, 1) << @as(u3, @intCast(9 - x)))) != 0;
        try std.testing.expectEqual(@as(u32, if (lit) 0xff0000 else 0xff), pixels[y * 16 + x]);
    };
}

test "invalid descendants are rejected before backgrounds can alter any pixel" {
    var pixels: [16 * 16]u32 = @splat(0x12345678);
    var surface = try ui.Surface.init(&pixels, 16, 16, 16, rgb);
    const children = [_]ui.View{ ui.Spacer().background(red), ui.Text("X").scale(0) };
    try std.testing.expectError(error.InvalidScale, ui.render(&surface, ui.HStack(&children).background(blue)));
    for (pixels) |pixel| try std.testing.expectEqual(@as(u32, 0x12345678), pixel);
    surface.stride = std.math.maxInt(u32);
    try std.testing.expectError(error.InvalidSurface, ui.render(&surface, ui.Spacer().background(red)));
    for (pixels) |pixel| try std.testing.expectEqual(@as(u32, 0x12345678), pixel);
}

test "graph depth limit accepts32 levels rejects33 and cycles before painting" {
    var pixels: [1]u32 = .{0x12345678};
    var surface = try ui.Surface.init(&pixels, 1, 1, 1, rgb);
    var nodes: [33]ui.View = undefined;
    nodes[nodes.len - 1] = ui.Spacer().background(red);
    var i: usize = nodes.len - 1;
    while (i > 0) {
        i -= 1;
        nodes[i] = ui.ZStack(nodes[i + 1 .. i + 2]);
    }
    try std.testing.expectError(error.GraphTooDeep, ui.render(&surface, nodes[0]));
    try std.testing.expectEqual(@as(u32, 0x12345678), pixels[0]);
    try ui.render(&surface, nodes[1]);
    try std.testing.expectEqual(@as(u32, 0xff0000), pixels[0]);
    pixels[0] = 0x12345678;
    var cycle: [1]ui.View = undefined;
    cycle[0] = ui.ZStack(&cycle).background(blue);
    try std.testing.expectError(error.CyclicGraph, ui.render(&surface, cycle[0]));
    try std.testing.expectEqual(@as(u32, 0x12345678), pixels[0]);
}

test "node budget accepts1024 visits rejects1025 and shared branches count each visit" {
    var pixels: [1]u32 = .{0x12345678};
    var surface = try ui.Surface.init(&pixels, 1, 1, 1, rgb);
    var leaves: [1024]ui.View = @splat(ui.Spacer());
    leaves[0] = ui.Spacer().background(red);
    try std.testing.expectError(error.TooManyNodes, ui.render(&surface, ui.ZStack(&leaves).background(blue)));
    try std.testing.expectEqual(@as(u32, 0x12345678), pixels[0]);
    try ui.render(&surface, ui.ZStack(leaves[0..1023]));
    try std.testing.expectEqual(@as(u32, 0xff0000), pixels[0]);
    const shared = [_]ui.View{ui.Spacer().background(green)};
    const branches = [_]ui.View{ ui.ZStack(&shared), ui.ZStack(&shared) };
    try ui.render(&surface, ui.ZStack(&branches));
    try std.testing.expectEqual(@as(u32, 0xff00), pixels[0]);
}

test "intrinsic size overflow in a bounded shared-text graph fails before painting" {
    var pixels: [1]u32 = .{0x12345678};
    var surface = try ui.Surface.init(&pixels, 1, 1, 1, rgb);
    const letters: [65536]u8 = @splat('A');
    const leaf_count = comptime std.math.maxInt(u32) / (letters.len * ui.font.glyphAdvance('A') * 16) + 1;
    const leaves: [leaf_count]ui.View = @splat(ui.Text(&letters).scale(16));
    // Bounded individually valid text leaves overflow their combined32-bit width.
    try std.testing.expectError(error.LayoutOverflow, ui.render(&surface, ui.HStack(&leaves).background(red)));
    try std.testing.expectEqual(@as(u32, 0x12345678), pixels[0]);
}

test "caller-owned workspace can be reused after success and rejected graph" {
    var workspace: ui.Workspace = undefined;
    var pixels: [8 * 8]u32 = @splat(0);
    var surface = try ui.Surface.init(&pixels, 8, 8, 8, rgb);
    try ui.renderWithWorkspace(&surface, &workspace, ui.Spacer().background(red));
    try std.testing.expectEqual(@as(u32, 0xff0000), pixels[0]);
    try std.testing.expectError(error.InvalidScale, ui.renderWithWorkspace(&surface, &workspace, ui.Text("X").scale(0)));
    try std.testing.expectEqual(@as(u32, 0xff0000), pixels[0]);
    const inner = [_]ui.View{ui.Spacer().background(green)};
    try ui.renderWithWorkspace(&surface, &workspace, ui.ZStack(&inner));
    for (pixels) |pixel| try std.testing.expectEqual(@as(u32, 0xff00), pixel);
}

test "code punctuation renders distinct original parenthesis ampersand semicolon glyphs" {
    const stride = ui.font.max_glyph_width * 4;
    var pixels: [stride * ui.font.line_height]u32 = @splat(0);
    var surface = try ui.Surface.init(&pixels, stride, ui.font.line_height, stride, rgb);
    try ui.render(&surface, ui.Text("()&;"));
    var x: u32 = 0;
    for ("()&;") |byte| {
        var ink: usize = 0;
        const width = ui.font.glyphAdvance(byte);
        for (0..ui.font.line_height) |y| for (0..width) |column| {
            const alpha: u32 = ui.font.coverage(byte, @intCast(column), @intCast(y), 1);
            try std.testing.expectEqual(alpha * 0x010101, pixels[y * stride + x + column]);
            ink += @intFromBool(alpha != 0);
        };
        try std.testing.expect(ink > 3);
        x += width;
    }
}

test "font metrics preserve lowercase and printable ASCII at compact advances" {
    const measured = try ui.font.measure("Ab\tZ\r\nx", 2);
    try std.testing.expectEqual(@as(u32, 102), measured.width);
    try std.testing.expectEqual(@as(u32, ui.font.line_height * 4), measured.height);
    try std.testing.expectEqualDeep(ui.font.Size{}, try ui.font.measure("", 1));
    try std.testing.expectError(error.InvalidScale, ui.font.measure("text", 0));
    try std.testing.expectError(error.InvalidScale, ui.font.measure("text", 17));
    for ('a'..'z' + 1) |value| {
        const lower = ui.font.glyph(@intCast(value));
        const upper = ui.font.glyph(@intCast(value - 'a' + 'A'));
        try std.testing.expect(!std.mem.eql(u8, &lower, &upper));
        for (lower) |row| try std.testing.expect(row < 32);
    }
    const fallback = ui.font.glyph('?');
    for (32..127) |value| {
        const shape = ui.font.glyph(@intCast(value));
        if (value != '?') try std.testing.expect(!std.mem.eql(u8, &shape, &fallback));
    }
}

test "native text pixels retain case and fit their proportional advances" {
    const stride = ui.font.max_glyph_width * 2;
    var pixels: [stride * ui.font.line_height]u32 = @splat(0);
    var surface = try ui.Surface.init(&pixels, stride, ui.font.line_height, stride, rgb);
    try ui.render(&surface, ui.Text("Aa").foreground(red));
    var first: [ui.font.max_glyph_width * ui.font.coverage_height]u32 = @splat(0);
    var second: [ui.font.max_glyph_width * ui.font.coverage_height]u32 = @splat(0);
    const first_width = ui.font.glyphAdvance('A');
    const second_width = ui.font.glyphAdvance('a');
    for (0..ui.font.coverage_height) |y| {
        for (0..first_width) |x| first[y * ui.font.max_glyph_width + x] = pixels[y * stride + x];
        for (0..second_width) |x| second[y * ui.font.max_glyph_width + x] = pixels[y * stride + x + first_width];
    }
    try std.testing.expect(!std.mem.eql(u32, &first, &second));
    for (0..ui.font.line_height) |y| for (first_width + second_width..stride) |x| try std.testing.expectEqual(@as(u32, 0), pixels[y * stride + x]);
}

test "native icon edge clipping preserves stride guards and command equality" {
    const sentinel: u32 = 0x51abf00d;
    var guarded: [2 + 20 * 16]u32 = @splat(sentinel);
    var surface = try ui.Surface.init(guarded[1 .. guarded.len - 1], 16, 16, 20, rgb);
    try ui.drawIcon(&surface, .folder, .{ .x = -3, .y = 7 }, red, 2);
    try ui.drawIcon(&surface, .document, .{ .x = 10, .y = -6 }, blue, 1);
    try std.testing.expectEqual(sentinel, guarded[0]);
    try std.testing.expectEqual(sentinel, guarded[guarded.len - 1]);
    for (0..16) |y| for (16..20) |x| try std.testing.expectEqual(sentinel, guarded[1 + y * 20 + x]);
    const before = guarded;
    try std.testing.expectError(error.InvalidScale, ui.drawIcon(&surface, .home, .{ .x = 0, .y = 0 }, green, 0));
    try std.testing.expectEqualSlices(u32, &before, &guarded);
    const Sink = struct {
        pixels: [16 * 16]u32 = @splat(0),
        fn fill(context: *anyopaque, x: u32, y: u32, width: u32, height: u32, value: u32) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            for (y..y + height) |row| for (x..x + width) |col| {
                self.pixels[row * 16 + col] = value;
            };
        }
        fn blend(context: *anyopaque, x: u32, y: u32, value: u32, alpha: u8) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            var destination = ui.Surface.init(&self.pixels, 16, 16, 16, rgb) catch unreachable;
            destination.blendPixel(x, y, destination.decode(value), alpha);
        }
    };
    var sink: Sink = .{};
    var commands = try ui.Surface.initCommands(16, 16, .{ .context = &sink, .fillRect = Sink.fill, .blendPixel = Sink.blend });
    var direct: [16 * 16]u32 = @splat(0);
    var native = try ui.Surface.init(&direct, 16, 16, 16, rgb);
    inline for (std.meta.tags(ui.Icon)) |icon| {
        try ui.drawIcon(&commands, icon, .{ .x = -2, .y = 4 }, red, 1);
        try ui.drawIcon(&native, icon, .{ .x = -2, .y = 4 }, red, 1);
    }
    try std.testing.expectEqualSlices(u32, &direct, &sink.pixels);
}
test "command surface emits identical clipped rounded text pixels without a framebuffer grant" {
    const Sink = struct {
        pixels: []u32,
        width: u32,
        height: u32,
        calls: usize = 0,
        invalid: bool = false,
        fn fill(context: *anyopaque, x: u32, y: u32, width: u32, height: u32, value: u32) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
            if (x >= self.width or y >= self.height or width > self.width - x or height > self.height - y or width == 0 or height == 0) {
                self.invalid = true;
                return;
            }
            for (y..y + height) |row| for (x..x + width) |column| {
                self.pixels[row * self.width + column] = value;
            };
        }
        fn blend(context: *anyopaque, x: u32, y: u32, value: u32, alpha: u8) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
            if (x >= self.width or y >= self.height) {
                self.invalid = true;
                return;
            }
            var received = ui.Surface.init(self.pixels, self.width, self.height, self.width, rgb) catch unreachable;
            received.blendPixel(x, y, received.decode(value), alpha);
        }
    };
    var direct: [64 * 48]u32 = @splat(0x333333);
    var submitted = direct;
    var receiver: Sink = .{ .pixels = &submitted, .width = 64, .height = 48 };
    var native = try ui.Surface.init(&direct, 64, 48, 64, .{ .red = 0xff0000, .green = 0xff00, .blue = 0xff });
    var commands = try ui.Surface.initCommands(64, 48, .{ .context = &receiver, .fillRect = Sink.fill, .blendPixel = Sink.blend });
    var workspace: ui.Workspace = undefined;
    const children = [_]ui.View{
        ui.Text("AB\nC").padding(3).scale(2).frame(60, 40).background(ui.Color.rgb(40, 60, 80)).cornerRadius(12),
        ui.Text("!@?").frame(45, 35).@"align"(.end).foreground(ui.Color.rgb(240, 150, 90)).border(ui.Color.rgb(0, 200, 255), 2).cornerRadius(9),
    };
    const view = ui.ZStack(&children).padding(2).background(ui.Color.rgb(10, 20, 30)).cornerRadius(8);
    try ui.renderWithWorkspace(&native, &workspace, view);
    try ui.renderWithWorkspace(&commands, &workspace, view);
    try ui.drawCursor(&native, .{ .x = -2, .y = 40 }, ui.Color.rgb(255, 255, 255));
    try ui.drawCursor(&commands, .{ .x = -2, .y = 40 }, ui.Color.rgb(255, 255, 255));
    try std.testing.expectEqualSlices(u32, &direct, &submitted);
    try std.testing.expect(!receiver.invalid and receiver.calls != 0);
    receiver.calls = 0;
    try std.testing.expectError(error.InvalidScale, ui.renderWithWorkspace(&commands, &workspace, ui.Text("bad").scale(0)));
    try std.testing.expectEqual(@as(usize, 0), receiver.calls);
}
