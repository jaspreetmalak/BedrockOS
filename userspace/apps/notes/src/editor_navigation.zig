//! Pure caret affinity for Notes' already wrapped, ordered visual lines.
const std = @import("std");

pub const Line = struct { start: u16, end: u16 };
pub const Position = struct { row: usize, column: usize };

pub fn position(lines: []const Line, cursor: usize) Position {
    for (lines, 0..) |line, row| {
        // A soft-wrap boundary belongs to the following visual row. A hard
        // newline and EOF retain the preceding row's end caret position.
        const includes_end = row + 1 == lines.len or lines[row + 1].start > line.end;
        if (cursor >= line.start and (cursor < line.end or (cursor == line.end and includes_end)))
            return .{ .row = row, .column = cursor - line.start };
    }
    unreachable;
}

/// Keep the caller's preferred column, but choose a caret byte position that
/// remains on the requested row under the same soft-wrap affinity as position.
pub fn verticalTarget(lines: []const Line, row: usize, column: usize) usize {
    const line = lines[row];
    const length: usize = line.end - line.start;
    const soft_wrap = row + 1 < lines.len and lines[row + 1].start == line.end;
    const maximum = if (soft_wrap) length -| 1 else length;
    return line.start + @min(column, maximum);
}

test "48-byte note at 24 columns moves Up from EOF to the preceding visual row" {
    const lines = [_]Line{ .{ .start = 0, .end = 24 }, .{ .start = 24, .end = 48 } };
    const eof = position(&lines, 48);
    try std.testing.expectEqualDeep(Position{ .row = 1, .column = 24 }, eof);
    const up = verticalTarget(&lines, eof.row - 1, eof.column);
    try std.testing.expectEqual(@as(usize, 23), up);
    try std.testing.expectEqualDeep(Position{ .row = 0, .column = 23 }, position(&lines, up));
    const down = verticalTarget(&lines, 1, eof.column);
    try std.testing.expectEqual(@as(usize, 48), down);
    try std.testing.expectEqualDeep(eof, position(&lines, down));
}

test "repeated Up and Down traverse full soft wraps while retaining the preferred column" {
    const lines = [_]Line{
        .{ .start = 0, .end = 24 },  .{ .start = 24, .end = 48 },
        .{ .start = 48, .end = 72 }, .{ .start = 72, .end = 96 },
    };
    var cursor: usize = 96;
    const preferred = position(&lines, cursor).column;
    for ([_]usize{ 71, 47, 23 }, 0..) |expected, step| {
        cursor = verticalTarget(&lines, position(&lines, cursor).row - 1, preferred);
        try std.testing.expectEqual(expected, cursor);
        try std.testing.expectEqual(2 - step, position(&lines, cursor).row);
    }
    try std.testing.expectEqual(cursor, verticalTarget(&lines, 0, preferred));
    for ([_]usize{ 47, 71, 96 }, 0..) |expected, step| {
        cursor = verticalTarget(&lines, position(&lines, cursor).row + 1, preferred);
        try std.testing.expectEqual(expected, cursor);
        try std.testing.expectEqual(step + 1, position(&lines, cursor).row);
    }
    try std.testing.expectEqualDeep(Position{ .row = 3, .column = 24 }, position(&lines, cursor));
}

test "hard newlines and final empty or partial EOF rows retain end affinity" {
    const lines = [_]Line{
        .{ .start = 0, .end = 24 }, .{ .start = 25, .end = 49 }, .{ .start = 50, .end = 50 },
    };
    for ([_]usize{ 24, 49, 50 }, 0..) |expected, row| {
        const cursor = verticalTarget(&lines, row, 24);
        try std.testing.expectEqual(expected, cursor);
        try std.testing.expectEqual(row, position(&lines, cursor).row);
    }
    try std.testing.expectEqualDeep(Position{ .row = 2, .column = 0 }, position(&lines, 50));
    const empty = [_]Line{.{ .start = 0, .end = 0 }};
    try std.testing.expectEqual(@as(usize, 0), verticalTarget(&empty, 0, 24));
    try std.testing.expectEqualDeep(Position{ .row = 0, .column = 0 }, position(&empty, 0));
    const partial = [_]Line{.{ .start = 0, .end = 5 }};
    try std.testing.expectEqual(@as(usize, 5), verticalTarget(&partial, 0, 24));
    try std.testing.expectEqualDeep(Position{ .row = 0, .column = 5 }, position(&partial, 5));
}

test "one-column soft wrap still targets its preceding visual row" {
    const lines = [_]Line{ .{ .start = 0, .end = 1 }, .{ .start = 1, .end = 2 } };
    const up = verticalTarget(&lines, 0, 1);
    try std.testing.expectEqual(@as(usize, 0), up);
    try std.testing.expectEqualDeep(Position{ .row = 0, .column = 0 }, position(&lines, up));
    try std.testing.expectEqual(@as(usize, 2), verticalTarget(&lines, 1, 1));
}
