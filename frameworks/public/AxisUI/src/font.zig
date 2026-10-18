//! Axis Sans: original proportional humanist outlines, native gray8 coverage.
const std = @import("std");
const Surface = @import("surface.zig").Surface;
const Error = @import("surface.zig").Error;
const Color = @import("types.zig").Color;
pub const family = "Axis Sans";
pub const baseline: u32 = 15;
pub const cap_height: u32 = 12;
pub const x_height: u32 = 9;
pub const editor_advance: u32 = 14;
pub const max_glyph_width: u32 = 14;
pub const coverage_height: u32 = 20;
pub const first_codepoint: u8 = 32;
pub const glyph_count: usize = 95;
const original_atlas = @embedFile("axis_sans.bin");
const advances = @embedFile("axis_sans_advances.bin");
const vectors = @embedFile("axis_sans_vectors.bin");
const vector_offsets = @embedFile("axis_sans_vector_offsets.bin");
// The old 5x7 shape API remains for bootstrap fixtures. Primary painting below
// uses the independent original outlines and their grayscale area coverage.
pub const glyph_width: u32 = 5;
pub const glyph_height: u32 = 7;
pub const legacy_advance: u32 = 6;
pub const legacy_line_height: u32 = 10;
pub const advance: u32 = 9; // Approximate column estimate, not proportional width.
pub const line_height: u32 = 20;
pub const offset_x: u32 = 0;
pub const offset_y: u32 = 1;
pub const Size = struct { width: u32 = 0, height: u32 = 0 };

/// Stable control-label placement centers the face's cap band, rather than its
/// full line box or a label-dependent ink box. Descenders keep their baseline;
/// switching between "Files", "gyp" and digits never moves the label origin.
/// A negative result is valid for short controls and clips through the painter.
pub fn labelOriginY(height: u32, scale: u8, legacy: bool) Error!i32 {
    if (scale == 0 or scale > 16) return error.InvalidScale;
    const cap: i64 = @as(i64, if (legacy) glyph_height else cap_height) * scale;
    const top: i64 = @as(i64, if (legacy) offset_y else baseline - cap_height) * scale;
    return @intCast(@divFloor(@as(i64, height) - cap, 2) - top);
}
/// Absolute modern control-label origin, checked before passing it to paint.
pub fn controlOriginY(top: i32, height: u32, scale: u8) Error!i32 {
    const origin = @as(i64, top) + try labelOriginY(height, scale, false);
    if (origin < std.math.minInt(i32) or origin > std.math.maxInt(i32)) return error.LayoutOverflow;
    return @intCast(origin);
}

comptime {
    if (original_atlas.len != glyph_count * max_glyph_width * coverage_height or advances.len != glyph_count or
        vector_offsets.len != (glyph_count + 1) * 2)
        @compileError("Axis Sans assets do not match their bounded native metrics");
}

// Trim only completely blank margins at compile time. The original gray8
// assets remain authoritative; executables retain the smaller exact coverage
// rectangles and their origins instead of ninety-five padded 14x20 cells.
const GlyphBounds = struct { offset: u16, left: u8, top: u8, width: u8, height: u8 };
const glyph_bounds = coverageBounds();
const atlas = packCoverage();

fn coverageBounds() [glyph_count]GlyphBounds {
    @setEvalBranchQuota(300_000);
    var result: [glyph_count]GlyphBounds = undefined;
    var offset: usize = 0;
    for (&result, 0..) |*bounds, glyph_index| {
        var left: usize = max_glyph_width;
        var top: usize = coverage_height;
        var right: usize = 0;
        var bottom: usize = 0;
        for (0..coverage_height) |y| for (0..max_glyph_width) |x| {
            if (original_atlas[glyph_index * max_glyph_width * coverage_height + y * max_glyph_width + x] == 0) continue;
            left = @min(left, x);
            top = @min(top, y);
            right = @max(right, x + 1);
            bottom = @max(bottom, y + 1);
        };
        if (left == max_glyph_width) {
            bounds.* = .{ .offset = @intCast(offset), .left = 0, .top = 0, .width = 0, .height = 0 };
        } else {
            bounds.* = .{ .offset = @intCast(offset), .left = @intCast(left), .top = @intCast(top), .width = @intCast(right - left), .height = @intCast(bottom - top) };
            offset += (right - left) * (bottom - top);
        }
    }
    return result;
}

fn coverageLength() usize {
    var length: usize = 0;
    for (glyph_bounds) |bounds| length += @as(usize, bounds.width) * bounds.height;
    return length;
}

fn packCoverage() [coverageLength()]u8 {
    @setEvalBranchQuota(300_000);
    var pixels: [coverageLength()]u8 = undefined;
    for (glyph_bounds, 0..) |bounds, glyph_index| {
        for (0..bounds.height) |y| for (0..bounds.width) |x| {
            pixels[@as(usize, bounds.offset) + y * bounds.width + x] =
                original_atlas[glyph_index * max_glyph_width * coverage_height + (bounds.top + y) * max_glyph_width + bounds.left + x];
        };
    }
    return pixels;
}

fn index(byte: u8) usize {
    return (if (byte >= first_codepoint and byte < first_codepoint + glyph_count) byte else @as(u8, '?')) - first_codepoint;
}
pub fn glyphAdvance(byte: u8) u32 {
    if (byte == '\r' or byte == '\n') return 0;
    if (byte == '\t') return advances[0] * 4;
    return advances[index(byte)];
}
/// Proportional metrics and painting share these exact advances. CR is ignored;
/// tabs are four spaces, and unsupported bytes use the original question mark.
pub fn measure(bytes: []const u8, scale: u8) Error!Size {
    return measureFace(bytes, scale, false);
}
pub fn measureLegacy(bytes: []const u8, scale: u8) Error!Size {
    return measureFace(bytes, scale, true);
}
fn measureFace(bytes: []const u8, scale: u8, legacy: bool) Error!Size {
    if (scale == 0 or scale > 16) return error.InvalidScale;
    if (bytes.len == 0) return .{};
    var longest: u32 = 0;
    var width: u32 = 0;
    var lines: u32 = 1;
    for (bytes) |byte| {
        if (byte == '\r') continue;
        if (byte == '\n') {
            longest = @max(longest, width);
            width = 0;
            lines = std.math.add(u32, lines, 1) catch return error.LayoutOverflow;
        } else width = std.math.add(u32, width, if (legacy) legacy_advance * @as(u32, if (byte == '\t') 4 else 1) else glyphAdvance(byte)) catch return error.LayoutOverflow;
    }
    longest = @max(longest, width);
    return .{
        .width = std.math.mul(u32, longest, scale) catch return error.LayoutOverflow,
        .height = std.math.mul(u32, lines, (if (legacy) legacy_line_height else line_height) * scale) catch return error.LayoutOverflow,
    };
}

fn vectorOffset(glyph_index: usize) usize {
    const at = glyph_index * 2;
    return @as(usize, vector_offsets[at]) | @as(usize, vector_offsets[at + 1]) << 8;
}
fn coordinate(at: usize, scale: u8) i64 {
    const value: i16 = @bitCast(@as(u16, vectors[at]) | @as(u16, vectors[at + 1]) << 8);
    return @as(i64, value) * scale;
}
fn insideStroke(x: i64, y: i64, edge: [4]i64, radius: i64) bool {
    const px = x - edge[0];
    const py = y - edge[1];
    const dx = edge[2] - edge[0];
    const dy = edge[3] - edge[1];
    const length = dx * dx + dy * dy;
    const dot = px * dx + py * dy;
    if (dot <= 0) return px * px + py * py <= radius * radius;
    if (dot >= length) {
        const ex = x - edge[2];
        const ey = y - edge[3];
        return ex * ex + ey * ey <= radius * radius;
    }
    const cross = px * dy - py * dx;
    return cross * cross <= radius * radius * length;
}
/// The base face uses precomputed area coverage. Larger sizes evaluate the
/// original vectors at the destination resolution with 8x8 subpixel coverage.
/// Fixed-point distance tests, round joins and union coverage need no heap or
/// floating point, and never reconstruct an enlarged low-resolution bitmap.
pub fn coverage(byte: u8, x: u32, y: u32, scale: u8) u8 {
    if (scale == 0 or scale > 16 or x >= glyphAdvance(byte) * scale or y >= coverage_height * scale) return 0;
    if (byte == '\r' or byte == '\n' or byte == '\t') return 0;
    const glyph_index = index(byte);
    if (scale == 1) {
        const bounds = glyph_bounds[glyph_index];
        if (x < bounds.left or y < bounds.top) return 0;
        const column = x - bounds.left;
        const row = y - bounds.top;
        if (column >= bounds.width or row >= bounds.height) return 0;
        return atlas[@as(usize, bounds.offset) + @as(usize, row) * bounds.width + column];
    }
    const left: i64 = @as(i64, x) * 64;
    const top: i64 = @as(i64, y) * 64;
    const radius: i64 = @as(i64, scale) * 45;
    var covered: u64 = 0;
    var at = vectorOffset(glyph_index);
    const end = vectorOffset(glyph_index + 1);
    var pen_x: i64 = 0;
    var pen_y: i64 = 0;
    while (at < end) {
        var next_x: i64 = undefined;
        var next_y: i64 = undefined;
        if (vectors[at] == 128) {
            const move = vectors[at + 1] == 0;
            next_x = coordinate(at + 2, scale);
            next_y = coordinate(at + 4, scale);
            at += 6;
            if (move) {
                pen_x = next_x;
                pen_y = next_y;
                continue;
            }
        } else {
            const dx: i8 = @bitCast(vectors[at]);
            const dy: i8 = @bitCast(vectors[at + 1]);
            next_x = pen_x + @as(i64, dx) * scale;
            next_y = pen_y + @as(i64, dy) * scale;
            at += 2;
        }
        const edge: [4]i64 = .{ pen_x, pen_y, next_x, next_y };
        pen_x = next_x;
        pen_y = next_y;
        if (left + 64 < @min(edge[0], edge[2]) - radius or left > @max(edge[0], edge[2]) + radius or
            top + 64 < @min(edge[1], edge[3]) - radius or top > @max(edge[1], edge[3]) + radius) continue;
        // 46 bounds the center-to-corner distance of a 64x64 pixel. These
        // conservative tests skip sampling wholly covered and distant pixels.
        if (insideStroke(left + 32, top + 32, edge, radius - 46)) return 255;
        if (!insideStroke(left + 32, top + 32, edge, radius + 46)) continue;
        for (0..8) |sy| for (0..8) |sx| {
            const bit = @as(u64, 1) << @as(u6, @intCast(sy * 8 + sx));
            if (covered & bit == 0 and insideStroke(left + @as(i64, @intCast(sx)) * 8 + 4, top + @as(i64, @intCast(sy)) * 8 + 4, edge, radius)) covered |= bit;
        };
        if (covered == std.math.maxInt(u64)) return 255;
    }
    return @intCast((@as(u32, @popCount(covered)) * 255 + 32) / 64);
}

/// Signed origins clip to the borrowed surface, including stride-preserving
/// sub-surfaces. Invalid scale/surface requests fail before changing pixels.
pub fn paintGlyph(surface: *Surface, byte: u8, x: i32, y: i32, color: Color, scale: u8) Error!void {
    try surface.validate();
    if (scale == 0 or scale > 16) return error.InvalidScale;
    paintGlyphUnchecked(surface, byte, x, y, color, scale);
}
fn paintGlyphUnchecked(surface: *Surface, byte: u8, x: i64, y: i64, color: Color, scale: u8) void {
    const width = glyphAdvance(byte) * scale;
    const height = coverage_height * scale;
    const first_x: u32 = @intCast(@min(width, @max(0, -x)));
    const first_y: u32 = @intCast(@min(height, @max(0, -y)));
    const last_x: u32 = @intCast(@min(width, @max(0, @as(i64, surface.width) - x)));
    const last_y: u32 = @intCast(@min(height, @max(0, @as(i64, surface.height) - y)));
    if (first_x >= last_x or first_y >= last_y) return;
    for (first_y..last_y) |row| for (first_x..last_x) |column| {
        const alpha = coverage(byte, @intCast(column), @intCast(row), scale);
        if (alpha != 0) surface.blendPixel(@intCast(x + @as(i64, @intCast(column))), @intCast(y + @as(i64, @intCast(row))), color, alpha);
    };
}
pub fn paint(surface: *Surface, bytes: []const u8, x: i32, y: i32, color: Color, scale: u8) Error!void {
    try surface.validate();
    _ = try measure(bytes, scale);
    var pen_x: i64 = x;
    var pen_y: i64 = y;
    for (bytes) |byte| {
        if (byte == '\r') continue;
        if (byte == '\n') {
            pen_x = x;
            pen_y += line_height * scale;
            continue;
        }
        if (byte != '\t') paintGlyphUnchecked(surface, byte, pen_x, pen_y, color, scale);
        pen_x += glyphAdvance(byte) * scale;
    }
}

pub fn glyph(byte: u8) [7]u8 {
    return switch (byte) {
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
        'a' => .{ 0, 0, 14, 1, 15, 17, 15 },
        'b' => .{ 16, 16, 22, 25, 17, 17, 30 },
        'c' => .{ 0, 0, 14, 16, 16, 17, 14 },
        'd' => .{ 1, 1, 13, 19, 17, 17, 15 },
        'e' => .{ 0, 0, 14, 17, 31, 16, 14 },
        'f' => .{ 6, 8, 8, 30, 8, 8, 8 },
        'g' => .{ 0, 14, 17, 17, 15, 1, 14 },
        'h' => .{ 16, 16, 22, 25, 17, 17, 17 },
        'i' => .{ 4, 0, 12, 4, 4, 4, 14 },
        'j' => .{ 2, 0, 6, 2, 2, 18, 12 },
        'k' => .{ 16, 16, 18, 20, 24, 20, 18 },
        'l' => .{ 12, 4, 4, 4, 4, 4, 14 },
        'm' => .{ 0, 0, 26, 21, 21, 21, 21 },
        'n' => .{ 0, 0, 22, 25, 17, 17, 17 },
        'o' => .{ 0, 0, 14, 17, 17, 17, 14 },
        'p' => .{ 0, 30, 17, 17, 30, 16, 16 },
        'q' => .{ 0, 15, 17, 17, 15, 1, 1 },
        'r' => .{ 0, 0, 22, 25, 16, 16, 16 },
        's' => .{ 0, 0, 15, 16, 14, 1, 30 },
        't' => .{ 8, 8, 30, 8, 8, 9, 6 },
        'u' => .{ 0, 0, 17, 17, 17, 19, 13 },
        'v' => .{ 0, 0, 17, 17, 17, 10, 4 },
        'w' => .{ 0, 0, 17, 17, 21, 21, 10 },
        'x' => .{ 0, 0, 17, 10, 4, 10, 17 },
        'y' => .{ 0, 17, 17, 17, 15, 1, 14 },
        'z' => .{ 0, 0, 31, 2, 4, 8, 31 },
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
        ';' => .{ 0, 6, 6, 0, 6, 4, 8 },
        '&' => .{ 12, 18, 20, 8, 21, 18, 13 },
        '=' => .{ 0, 0, 31, 0, 31, 0, 0 },
        '-' => .{ 0, 0, 0, 31, 0, 0, 0 },
        '_' => .{ 0, 0, 0, 0, 0, 0, 31 },
        '.' => .{ 0, 0, 0, 0, 0, 6, 6 },
        '/' => .{ 1, 2, 2, 4, 8, 8, 16 },
        '(' => .{ 2, 4, 8, 8, 8, 4, 2 },
        ')' => .{ 8, 4, 2, 2, 2, 4, 8 },
        '!' => .{ 4, 4, 4, 4, 4, 0, 4 },
        '"' => .{ 10, 10, 10, 0, 0, 0, 0 },
        '#' => .{ 10, 10, 31, 10, 31, 10, 10 },
        '$' => .{ 4, 15, 20, 14, 5, 30, 4 },
        '%' => .{ 24, 25, 2, 4, 8, 19, 3 },
        '\'' => .{ 4, 4, 8, 0, 0, 0, 0 },
        '*' => .{ 0, 21, 14, 31, 14, 21, 0 },
        '+' => .{ 0, 4, 4, 31, 4, 4, 0 },
        ',' => .{ 0, 0, 0, 0, 6, 4, 8 },
        '<' => .{ 2, 4, 8, 16, 8, 4, 2 },
        '>' => .{ 8, 4, 2, 1, 2, 4, 8 },
        '@' => .{ 14, 17, 23, 21, 23, 16, 14 },
        '\\' => .{ 16, 8, 8, 4, 2, 2, 1 },
        '^' => .{ 4, 10, 17, 0, 0, 0, 0 },
        '`' => .{ 8, 4, 2, 0, 0, 0, 0 },
        '{' => .{ 6, 8, 8, 16, 8, 8, 6 },
        '|' => .{ 4, 4, 4, 4, 4, 4, 4 },
        '}' => .{ 12, 2, 2, 1, 2, 2, 12 },
        '~' => .{ 0, 0, 8, 21, 2, 0, 0 },
        else => .{ 14, 17, 1, 2, 4, 0, 4 },
    };
}
