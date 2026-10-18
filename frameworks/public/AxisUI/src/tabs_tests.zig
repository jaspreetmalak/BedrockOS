const std = @import("std");
const tabs = @import("tabs.zig");
const input = @import("input.zig");
const Surface = @import("surface.zig").Surface;

const items = [_]tabs.Item{
    .{ .id = 1, .label = "Documents", .icon = .folder },
    .{ .id = 2, .label = "Desktop", .icon = .folder },
    .{ .id = 3, .label = "Downloads", .icon = .folder },
    .{ .id = 4, .label = "Applications" },
    .{ .id = 5, .label = "Projects" },
    .{ .id = 6, .label = "Pictures" },
    .{ .id = 7, .label = "Music" },
    .{ .id = 8, .label = "A folder with a long name" },
};
fn layout(width: u32, active: usize) !tabs.Layout {
    return tabs.Layout.init(.{ .x = 104, .y = 4, .width = width, .height = 24 }, &items, active);
}
fn pointer(kind: input.Kind, rect: input.Rect, button: input.Button) input.Event {
    return .{ .kind = kind, .code = @backingInt(button), .x = @intCast(rect.x + @as(i32, @intCast(rect.width / 2))), .y = @intCast(rect.y + @as(i32, @intCast(rect.height / 2))) };
}

test "tabs reject malformed definitions and overflowing bounds before drawing" {
    const bounds: input.Rect = .{ .x = 0, .y = 0, .width = 66, .height = 24 };
    try std.testing.expectError(error.InvalidTabs, tabs.Layout.init(bounds, &.{}, 0));
    try std.testing.expectError(error.InvalidTabs, tabs.Layout.init(bounds, &items, items.len));
    try std.testing.expectError(error.InvalidTabs, tabs.Layout.init(bounds, &.{ .{ .id = 1, .label = "A" }, .{ .id = 1, .label = "B" } }, 0));
    try std.testing.expectError(error.InvalidTabs, tabs.Layout.init(bounds, &.{.{ .id = 0, .label = "A" }}, 0));
    try std.testing.expectError(error.InvalidTabs, tabs.Layout.init(bounds, &.{.{ .id = 1, .label = "Bad\nlabel" }}, 0));
    try std.testing.expectError(error.InvalidTabs, tabs.Layout.init(.{ .x = std.math.maxInt(i32), .y = 0, .width = 66, .height = 24 }, &items, 0));
    try std.testing.expectError(error.InvalidTabs, tabs.Layout.init(.{ .x = 0, .y = 0, .width = 47, .height = 24 }, &items, 0));
    var too_many: [tabs.max_items + 1]tabs.Item = undefined;
    for (&too_many, 0..) |*item, i| item.* = .{ .id = @intCast(i + 1), .label = "Tab" };
    try std.testing.expectError(error.InvalidTabs, tabs.Layout.init(bounds, &too_many, 0));
}

test "66px title accessory keeps active close and add reachable and wheel reaches eight tabs" {
    var state: tabs.State = .{};
    var active: usize = 0;
    for (0..items.len) |expected| {
        const geometry = try layout(66, active);
        try std.testing.expectEqual(expected, active);
        try std.testing.expect(geometry.tabRect(active) != null);
        try std.testing.expectEqual(@as(usize, 1), geometry.visible);
        const close = geometry.closeRect(active).?;
        const add = geometry.addRect();
        try std.testing.expect(close.width >= 16 and close.height >= 16);
        try std.testing.expect(close.x + @as(i32, @intCast(close.width)) <= add.x);
        try std.testing.expectEqual(items[active].id, geometry.hit(.{ .x = close.x, .y = close.y }).?.close);
        try std.testing.expect(geometry.hit(.{ .x = add.x, .y = add.y }).? == .add);
        try std.testing.expect(geometry.hit(.{ .x = add.x + @as(i32, @intCast(add.width)), .y = add.y }) == null);
        const wheel = state.handle(geometry, .{ .kind = .wheel, .code = 1, .x = 110, .y = 10 });
        try std.testing.expect(wheel.consumed and wheel.changed);
        active = wheel.select.?;
    }
    try std.testing.expectEqual(@as(usize, 0), active);
    const previous = state.handle(try layout(66, active), .{ .kind = .wheel, .code = @bitCast(@as(i16, -1)), .x = 110, .y = 10 });
    try std.testing.expectEqual(@as(?usize, 7), previous.select);
    const outside = state.handle(try layout(66, 0), .{ .kind = .wheel, .code = 1, .x = 0, .y = 0 });
    try std.testing.expect(!outside.consumed and outside.select == null);
}

test "overflow arrows navigate all tabs with matched release and active visibility" {
    var state: tabs.State = .{};
    var active: usize = 0;
    for (0..items.len) |_| {
        const geometry = try layout(506, active);
        try std.testing.expect(geometry.arrows);
        try std.testing.expect(geometry.tabRect(active) != null);
        const next = geometry.nextRect().?;
        const down = state.handle(geometry, pointer(.pointer_down, next, .left));
        try std.testing.expect(down.consumed and down.select == null);
        active = state.handle(geometry, pointer(.pointer_up, next, .left)).select.?;
    }
    try std.testing.expectEqual(@as(usize, 0), active);
    const roomy = try layout(1600, 7);
    try std.testing.expect(!roomy.arrows);
    try std.testing.expectEqual(items.len, roomy.visible);
    try std.testing.expectEqual(@as(u32, 160), roomy.tab_width);
    try std.testing.expect(roomy.hit(.{ .x = 1500, .y = 8 }) == null);
}

test "add button follows the final visible tab while unused trailing space stays inert" {
    for ([_]usize{ 1, 2, 8 }) |count| {
        const geometry = try tabs.Layout.init(.{ .x = 104, .y = 4, .width = 1600, .height = 24 }, items[0..count], count - 1);
        try std.testing.expect(!geometry.arrows);
        const last = geometry.tabRect(count - 1).?;
        const add = geometry.addRect();
        try std.testing.expectEqual(last.x + @as(i32, @intCast(last.width)), add.x);
        try std.testing.expect(geometry.hit(.{ .x = add.x + 12, .y = add.y + 12 }).? == .add);
        try std.testing.expect(geometry.hit(.{ .x = add.x + @as(i32, @intCast(add.width)), .y = add.y }) == null);
    }
    const overflow = try layout(506, 0);
    try std.testing.expectEqual(overflow.bounds.x + @as(i32, @intCast(overflow.bounds.width)) - 24, overflow.addRect().x);
}

test "tab add close select require matching targets and cancel on geometry redraw" {
    const geometry = try layout(506, 0);
    var state: tabs.State = .{};
    const close = geometry.closeRect(0).?;
    const body: input.Rect = .{ .x = geometry.tabRect(1).?.x + 2, .y = 4, .width = 12, .height = 24 };
    try std.testing.expect(state.handle(geometry, pointer(.pointer_up, close, .left)).close == null);
    _ = state.handle(geometry, pointer(.pointer_down, close, .left));
    const wrong = state.handle(geometry, pointer(.pointer_up, body, .left));
    try std.testing.expect(wrong.consumed and wrong.close == null and wrong.select == null);
    _ = state.handle(geometry, pointer(.pointer_down, close, .left));
    try std.testing.expectEqual(@as(?usize, 0), state.handle(geometry, pointer(.pointer_up, close, .left)).close);
    _ = state.handle(geometry, pointer(.pointer_down, body, .left));
    try std.testing.expectEqual(@as(?usize, 1), state.handle(geometry, pointer(.pointer_up, body, .left)).select);
    const add = geometry.addRect();
    _ = state.handle(geometry, pointer(.pointer_down, add, .left));
    try std.testing.expect(state.handle(geometry, pointer(.pointer_up, add, .left)).add);
    _ = state.handle(geometry, pointer(.pointer_down, add, .left));
    try std.testing.expect(state.handle(geometry, .{ .kind = .redraw, .code = 1 }).changed);
    try std.testing.expect(!state.handle(geometry, pointer(.pointer_up, add, .left)).add);
}

test "stable tab IDs prevent stale close gestures and middle click respects closable" {
    const geometry = try layout(506, 0);
    var state: tabs.State = .{};
    const close = geometry.closeRect(0).?;
    _ = state.handle(geometry, pointer(.pointer_down, close, .left));
    var replaced = items;
    replaced[0].id = 99;
    const updated = try tabs.Layout.init(geometry.bounds, &replaced, 0);
    try std.testing.expect(state.handle(updated, pointer(.pointer_up, close, .left)).close == null);
    const body: input.Rect = .{ .x = geometry.tabRect(1).?.x + 2, .y = 4, .width = 12, .height = 24 };
    _ = state.handle(geometry, pointer(.pointer_down, body, .middle));
    try std.testing.expectEqual(@as(?usize, 1), state.handle(geometry, pointer(.pointer_up, body, .middle)).close);
    replaced[1].closable = false;
    const permanent = try tabs.Layout.init(geometry.bounds, &replaced, 0);
    _ = state.handle(permanent, pointer(.pointer_down, body, .middle));
    try std.testing.expect(state.handle(permanent, pointer(.pointer_up, body, .middle)).close == null);
}

test "tab paint clips long titles icons and controls to accessory without touching stride guards" {
    const guard: u32 = 0x12345678;
    var memory: [200 * 40 + 2]u32 = @splat(guard);
    var surface = try Surface.init(memory[1 .. memory.len - 1], 192, 40, 200, .{ .red = 0xff0000, .green = 0xff00, .blue = 0xff });
    const geometry = try layout(66, 7);
    var state: tabs.State = .{};
    _ = state.handle(geometry, pointer(.pointer_move, geometry.closeRect(7).?, .left));
    try tabs.draw(&surface, geometry, &state, .{});
    var painted: usize = 0;
    for (0..40) |y| for (0..200) |x| {
        const pixel = memory[1 + y * 200 + x];
        if (x >= 104 and x < 170 and y >= 4 and y < 28) {
            if (pixel != guard) painted += 1;
        } else try std.testing.expectEqual(guard, pixel);
    };
    try std.testing.expect(painted > 1000);
    try std.testing.expectEqual(guard, memory[0]);
    try std.testing.expectEqual(guard, memory[memory.len - 1]);
    var invalid = geometry;
    invalid.first = 100;
    try std.testing.expectError(error.InvalidSurface, tabs.draw(&surface, invalid, &state, .{}));
}

fn move(x: i16, y: i16) input.Event {
    return .{ .kind = .pointer_move, .x = x, .y = y };
}
fn release(x: i16, y: i16) input.Event {
    return .{ .kind = .pointer_up, .code = @backingInt(input.Button.left), .x = x, .y = y };
}

test "tab drag threshold and midpoint reordering retain stable source ID after application moves" {
    var ordered = items;
    var geometry = try tabs.Layout.init(.{ .x = 0, .y = 4, .width = 664, .height = 24 }, ordered[0..4], 0);
    var state: tabs.State = .{};
    _ = state.handle(geometry, .{ .kind = .pointer_down, .code = 1, .x = 20, .y = 12 });
    const small = state.handle(geometry, move(25, 12));
    try std.testing.expect(!small.dragging and small.reorder == null and small.detach == null);
    const start = state.handle(geometry, move(26, 12));
    try std.testing.expect(start.dragging and start.consumed and start.changed);
    try std.testing.expectEqual(@as(?usize, 0), start.select);
    try std.testing.expect(start.reorder == null);
    try std.testing.expectEqual(@as(?u32, 1), state.draggedId());
    try std.testing.expect(state.handle(geometry, move(239, 12)).reorder == null);
    const first = state.handle(geometry, move(240, 12));
    try std.testing.expectEqual(@as(usize, 0), first.reorder.?.from);
    try std.testing.expectEqual(@as(usize, 1), first.reorder.?.to);
    std.mem.swap(tabs.Item, &ordered[0], &ordered[1]);
    geometry = try tabs.Layout.init(geometry.bounds, ordered[0..4], 1);
    const second = state.handle(geometry, move(400, 12));
    try std.testing.expectEqual(@as(usize, 1), second.reorder.?.from);
    try std.testing.expectEqual(@as(usize, 2), second.reorder.?.to);
    std.mem.swap(tabs.Item, &ordered[1], &ordered[2]);
    geometry = try tabs.Layout.init(geometry.bounds, ordered[0..4], 2);
    const drop = state.handle(geometry, release(400, 12));
    try std.testing.expect(drop.consumed and !drop.dragging);
    try std.testing.expect(drop.close == null and drop.select == null and drop.detach == null and drop.reorder == null);
    try std.testing.expect(!state.isDragging() and state.draggedId() == null);
    try std.testing.expectEqual(@as(u32, 1), ordered[2].id);
}

test "vertical tab tears emit a client-local detach only beyond the outside threshold" {
    const geometry = try layout(506, 0);
    var state: tabs.State = .{};
    _ = state.handle(geometry, .{ .kind = .pointer_down, .code = 1, .x = 110, .y = 12 });
    const vertical = state.handle(geometry, move(560, 45));
    try std.testing.expect(vertical.dragging and vertical.reorder == null);
    const detached = state.handle(geometry, release(560, 45));
    try std.testing.expectEqual(@as(usize, 0), detached.detach.?.index);
    try std.testing.expectEqual(@as(i32, 560), detached.detach.?.x);
    try std.testing.expectEqual(@as(i32, 45), detached.detach.?.y);
    try std.testing.expect(detached.close == null and detached.reorder == null and !detached.dragging);
    _ = state.handle(geometry, .{ .kind = .pointer_down, .code = 1, .x = 110, .y = 12 });
    _ = state.handle(geometry, move(110, 43)); // Exactly 16px beyond the lower edge.
    try std.testing.expect(state.handle(geometry, release(110, 43)).detach == null);
    _ = state.handle(geometry, .{ .kind = .pointer_down, .code = 1, .x = 110, .y = 12 });
    _ = state.handle(geometry, move(110, -13));
    try std.testing.expectEqual(@as(usize, 0), state.handle(geometry, release(110, -13)).detach.?.index);
    _ = state.handle(geometry, .{ .kind = .pointer_down, .code = 1, .x = 110, .y = 12 });
    _ = state.handle(geometry, move(115, 17));
    try std.testing.expect(state.handle(geometry, release(115, 17)).detach == null);
    // A host may already have applied an earlier reorder before the tear.
    var ordered = items;
    _ = state.handle(geometry, .{ .kind = .pointer_down, .code = 1, .x = 110, .y = 12 });
    _ = state.handle(geometry, move(220, 12));
    std.mem.swap(tabs.Item, &ordered[0], &ordered[1]);
    const reordered = try tabs.Layout.init(geometry.bounds, &ordered, 1);
    _ = state.handle(reordered, move(220, 60));
    try std.testing.expectEqual(@as(usize, 1), state.handle(reordered, release(220, 60)).detach.?.index);
}

test "Escape redraw wheel and removed source cancel pending tab tears without closing another tab" {
    const geometry = try layout(506, 0);
    const cancellations = [_]input.Event{
        .{ .kind = .key_down, .code = @backingInt(input.Key.escape) },
        .{ .kind = .redraw, .code = 1 },
        .{ .kind = .wheel, .code = 1, .x = 110, .y = 12 },
    };
    for (cancellations) |cancel| {
        var state: tabs.State = .{};
        _ = state.handle(geometry, .{ .kind = .pointer_down, .code = 1, .x = 110, .y = 12 });
        _ = state.handle(geometry, move(110, 60));
        const canceled = state.handle(geometry, cancel);
        try std.testing.expect(canceled.consumed and !canceled.dragging);
        try std.testing.expect(canceled.detach == null and canceled.close == null and canceled.reorder == null);
        const up = state.handle(geometry, release(110, 60));
        try std.testing.expect(up.detach == null and up.close == null and up.select == null);
    }
    var state: tabs.State = .{};
    _ = state.handle(geometry, .{ .kind = .pointer_down, .code = 1, .x = 110, .y = 12 });
    _ = state.handle(geometry, move(110, 60));
    const without_source = try tabs.Layout.init(geometry.bounds, items[1..], 0);
    const missing = state.handle(without_source, move(110, 70));
    try std.testing.expect(!missing.dragging and missing.reorder == null and missing.detach == null);
    try std.testing.expect(state.handle(without_source, release(110, 70)).detach == null);
}

test "dragging across a close glyph cannot close and close middle and add presses never start dragging" {
    const geometry = try layout(506, 0);
    var state: tabs.State = .{};
    _ = state.handle(geometry, .{ .kind = .pointer_down, .code = 1, .x = 110, .y = 12 });
    const close = geometry.closeRect(0).?;
    _ = state.handle(geometry, pointer(.pointer_move, close, .left));
    const drop = state.handle(geometry, pointer(.pointer_up, close, .left));
    try std.testing.expect(drop.close == null and drop.detach == null);
    const controls = [_]input.Rect{ close, geometry.addRect() };
    for (controls) |control| {
        _ = state.handle(geometry, pointer(.pointer_down, control, .left));
        const moving = state.handle(geometry, move(110, 80));
        try std.testing.expect(!moving.dragging and moving.reorder == null);
        const outside = state.handle(geometry, release(110, 80));
        try std.testing.expect(outside.close == null and outside.detach == null and !outside.add);
    }
    _ = state.handle(geometry, .{ .kind = .pointer_down, .code = @backingInt(input.Button.middle), .x = 110, .y = 12 });
    try std.testing.expect(!state.handle(geometry, move(120, 12)).dragging);
    const middle = state.handle(geometry, .{ .kind = .pointer_up, .code = @backingInt(input.Button.middle), .x = 120, .y = 12 });
    try std.testing.expectEqual(@as(?usize, 0), middle.close);
}

test "captured drag edge movement reaches hidden neighbors without reusing indices as identity" {
    var ordered = items;
    var geometry = try layout(506, 0);
    var state: tabs.State = .{};
    _ = state.handle(geometry, .{ .kind = .pointer_down, .code = 1, .x = 110, .y = 12 });
    const next = geometry.nextRect().?;
    const edge = state.handle(geometry, move(@intCast(next.x + 10), 12));
    try std.testing.expectEqual(@as(usize, 0), edge.reorder.?.from);
    try std.testing.expectEqual(geometry.first + geometry.visible, edge.reorder.?.to);
    const destination = edge.reorder.?.to;
    const dragged = ordered[0];
    std.mem.copyForwards(tabs.Item, ordered[0..destination], ordered[1 .. destination + 1]);
    ordered[destination] = dragged;
    geometry = try tabs.Layout.init(geometry.bounds, &ordered, destination);
    const left = state.handle(geometry, move(@intCast(geometry.bounds.x + 1), 12));
    try std.testing.expectEqual(destination, left.reorder.?.from);
    try std.testing.expectEqual(geometry.first - 1, left.reorder.?.to);
    try std.testing.expectEqual(@as(?u32, 1), state.draggedId());
}

test "drag previews and insertion markers stay inside 48px 66px and overflowing owned strips" {
    const guard: u32 = 0x12345678;
    var memory: [700 * 40 + 2]u32 = undefined;
    for ([_]u32{ 48, 66, 506 }) |width| {
        @memset(&memory, guard);
        var surface = try Surface.init(memory[1 .. memory.len - 1], 680, 40, 700, .{ .red = 0xff0000, .green = 0xff00, .blue = 0xff });
        const geometry = try layout(width, 0);
        var state: tabs.State = .{};
        _ = state.handle(geometry, .{ .kind = .pointer_down, .code = 1, .x = 105, .y = 12 });
        const dragging = state.handle(geometry, move(32760, 12));
        try std.testing.expect(dragging.dragging);
        try tabs.draw(&surface, geometry, &state, .{});
        _ = state.handle(geometry, move(-32760, 12));
        try tabs.draw(&surface, geometry, &state, .{});
        for (0..40) |y| for (0..700) |x| {
            if (x >= 104 and x < 104 + width and y >= 4 and y < 28) continue;
            try std.testing.expectEqual(guard, memory[1 + y * 700 + x]);
        };
        try std.testing.expectEqual(guard, memory[0]);
        try std.testing.expectEqual(guard, memory[memory.len - 1]);
    }
}
