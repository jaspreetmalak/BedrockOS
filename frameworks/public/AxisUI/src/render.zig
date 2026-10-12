const types = @import("types.zig");
const Surface = @import("surface.zig").Surface;
const Error = @import("surface.zig").Error;
const font = @import("font.zig");

pub const max_depth = 32;
pub const max_nodes = 1024;
const Size = struct { width: u32 = 0, height: u32 = 0 };
const Node = struct {
    view: *const types.View,
    foreground: types.Color,
    scale: u8,
    first: u16,
    end: u16,
    ideal: Size,
};

fn add(a: u32, b: u32) Error!u32 {
    const result = @addWithOverflow(a, b);
    if (result[1] != 0) return error.LayoutOverflow;
    return result[0];
}
fn multiply(a: u32, b: u32) Error!u32 {
    const result = @mulWithOverflow(a, b);
    if (result[1] != 0) return error.LayoutOverflow;
    return result[0];
}

const Plan = struct {
    nodes: [max_nodes]Node,
    path: [max_depth]*const types.View,
    count: u16,

    fn visit(self: *Plan, view: *const types.View, depth: usize, foreground: types.Color, scale: u8) Error!u16 {
        if (view.style.background_material != null and view.style.background_color != null) return error.InvalidMaterial;
        for (self.path[0..@min(depth, max_depth)]) |ancestor| {
            if (ancestor == view) return error.CyclicGraph;
        }
        if (depth >= max_depth) return error.GraphTooDeep;
        if (self.count == max_nodes) return error.TooManyNodes;
        const actual_scale = view.style.font_scale orelse scale;
        if (actual_scale == 0 or actual_scale > 16) return error.InvalidScale;
        const color = view.style.foreground_color orelse foreground;
        const index = self.count;
        self.count += 1;
        self.path[depth] = view;
        const children: []const types.View = switch (view.kind) {
            .hstack => |values| values,
            .vstack => |values| values,
            .zstack => |values| values,
            else => &.{},
        };
        if (children.len > max_nodes - self.count) return error.TooManyNodes;
        for (children) |*child| _ = try self.visit(child, depth + 1, color, actual_scale);
        const end = self.count;
        var content: Size = .{};
        switch (view.kind) {
            .text => |bytes| content = try textSize(bytes, actual_scale),
            .spacer => {},
            .hstack, .vstack, .zstack => {
                var child = index + 1;
                var seen: u32 = 0;
                while (child < end) {
                    const size = self.nodes[child].ideal;
                    switch (view.kind) {
                        .hstack => {
                            content.width = try add(content.width, size.width);
                            content.height = @max(content.height, size.height);
                        },
                        .vstack => {
                            content.width = @max(content.width, size.width);
                            content.height = try add(content.height, size.height);
                        },
                        .zstack => {
                            content.width = @max(content.width, size.width);
                            content.height = @max(content.height, size.height);
                        },
                        else => unreachable,
                    }
                    seen += 1;
                    child = self.nodes[child].end;
                }
                if (seen > 1) switch (view.kind) {
                    .hstack => content.width = try add(content.width, try multiply(seen - 1, view.style.spacing)),
                    .vstack => content.height = try add(content.height, try multiply(seen - 1, view.style.spacing)),
                    else => {},
                };
            },
        }
        const double_padding = @as(u32, view.style.inset) * 2;
        const padded_width = try add(content.width, double_padding);
        const padded_height = try add(content.height, double_padding);
        self.nodes[index] = .{
            .view = view,
            .foreground = color,
            .scale = actual_scale,
            .first = index + 1,
            .end = end,
            .ideal = .{
                .width = view.style.width orelse padded_width,
                .height = view.style.height orelse padded_height,
            },
        };
        return index;
    }
};

fn textSize(bytes: []const u8, scale: u8) Error!Size {
    const measured = try font.measure(bytes, scale);
    return .{ .width = measured.width, .height = measured.height };
}

const Rect = struct {
    x: i64,
    y: i64,
    width: u32,
    height: u32,

    fn intersect(self: Rect, other: Rect) Rect {
        const left = @max(self.x, other.x);
        const top = @max(self.y, other.y);
        const right = @min(self.x + self.width, other.x + other.width);
        const bottom = @min(self.y + self.height, other.y + other.height);
        return .{
            .x = left,
            .y = top,
            .width = @intCast(@max(@as(i64, 0), right - left)),
            .height = @intCast(@max(@as(i64, 0), bottom - top)),
        };
    }

    fn inset(self: Rect, amount: u32) Rect {
        const horizontal = @min(amount, self.width / 2);
        const vertical = @min(amount, self.height / 2);
        return .{
            .x = self.x + horizontal,
            .y = self.y + vertical,
            .width = self.width - @min(self.width, @as(u64, amount) * 2),
            .height = self.height - @min(self.height, @as(u64, amount) * 2),
        };
    }
};

const Shape = struct {
    rectangle: Rect,
    radius: u32,

    fn contains(self: Shape, x: i64, y: i64) bool {
        const rectangle = self.rectangle;
        if (x < rectangle.x or y < rectangle.y or x >= rectangle.x + rectangle.width or y >= rectangle.y + rectangle.height)
            return false;
        const radius = @min(self.radius, @min(rectangle.width, rectangle.height) / 2);
        if (radius == 0) return true;
        const local_x: u64 = @intCast(x - rectangle.x);
        const local_y: u64 = @intCast(y - rectangle.y);
        const dx = if (local_x < radius) radius - 1 - local_x else if (local_x >= rectangle.width - radius) local_x - (rectangle.width - radius) else 0;
        const dy = if (local_y < radius) radius - 1 - local_y else if (local_y >= rectangle.height - radius) local_y - (rectangle.height - radius) else 0;
        return dx * dx + dy * dy < @as(u64, radius) * radius;
    }
};

fn offset(available: u32, desired: u32, alignment: types.Align) u32 {
    const extra = available - @min(available, desired);
    return switch (alignment) {
        .center => extra / 2,
        .end => extra,
        else => 0,
    };
}

const Painter = struct {
    surface: *Surface,
    plan: *const Plan,
    shapes: *[max_depth]Shape,

    fn pixel(self: *Painter, x: i64, y: i64, value: u32, depth: usize) void {
        // Every caller intersects with the checked surface before reaching here.
        for (self.shapes[0 .. depth + 1]) |shape| if (!shape.contains(x, y)) return;
        self.surface.putPixel(@intCast(x), @intCast(y), value);
    }

    fn fill(self: *Painter, area: Rect, clip: Rect, color: types.Color, depth: usize) void {
        const visible = area.intersect(clip);
        const value = self.surface.encode(color);
        if (visible.width == 0 or visible.height == 0) return;
        if (self.surface.commands != null) {
            // Rounded rectangles and their intersections are convex. Four
            // contained corners prove this entire rectangular fill is inside.
            var all_inside = true;
            for (self.shapes[0 .. depth + 1]) |shape| {
                const right = visible.x + visible.width - 1;
                const bottom = visible.y + visible.height - 1;
                if (!shape.contains(visible.x, visible.y) or !shape.contains(right, visible.y) or
                    !shape.contains(visible.x, bottom) or !shape.contains(right, bottom))
                {
                    all_inside = false;
                    break;
                }
            }
            if (all_inside) {
                self.surface.fillRect(@intCast(visible.x), @intCast(visible.y), visible.width, visible.height, value);
                return;
            }
            var row = visible.y;
            while (row < visible.y + visible.height) : (row += 1) {
                var start: ?i64 = null;
                var column = visible.x;
                while (column <= visible.x + visible.width) : (column += 1) {
                    var inside = column < visible.x + visible.width;
                    if (inside) for (self.shapes[0 .. depth + 1]) |shape| {
                        if (!shape.contains(column, row)) {
                            inside = false;
                            break;
                        }
                    };
                    if (inside) {
                        if (start == null) start = column;
                    } else if (start) |first| {
                        self.surface.fillRect(@intCast(first), @intCast(row), @intCast(column - first), 1, value);
                        start = null;
                    }
                }
            }
            return;
        }
        var y = visible.y;
        while (y < visible.y + visible.height) : (y += 1) {
            var x = visible.x;
            while (x < visible.x + visible.width) : (x += 1) self.pixel(x, y, value, depth);
        }
    }

    fn material(self: *Painter, area: Rect, clip: Rect, value: types.Material, depth: usize) void {
        const visible = area.intersect(clip);
        if (visible.width == 0 or visible.height == 0) return;
        var all_inside = true;
        for (self.shapes[0 .. depth + 1]) |shape| {
            const right = visible.x + visible.width - 1;
            const bottom = visible.y + visible.height - 1;
            if (!shape.contains(visible.x, visible.y) or !shape.contains(right, visible.y) or
                !shape.contains(visible.x, bottom) or !shape.contains(right, bottom))
            {
                all_inside = false;
                break;
            }
        }
        if (all_inside) {
            self.surface.materialRect(@intCast(visible.x), @intCast(visible.y), visible.width, visible.height, value);
            return;
        }
        var row = visible.y;
        while (row < visible.y + visible.height) : (row += 1) {
            var start: ?i64 = null;
            var column = visible.x;
            while (column <= visible.x + visible.width) : (column += 1) {
                var inside = column < visible.x + visible.width;
                if (inside) for (self.shapes[0 .. depth + 1]) |shape| {
                    if (!shape.contains(column, row)) {
                        inside = false;
                        break;
                    }
                };
                if (inside) {
                    if (start == null) start = column;
                } else if (start) |first| {
                    self.surface.materialRect(@intCast(first), @intCast(row), @intCast(column - first), 1, value);
                    start = null;
                }
            }
        }
    }

    fn border(self: *Painter, rectangle: Rect, clip: Rect, color: types.Color, width: u32, radius: u32, depth: usize) void {
        const visible = rectangle.intersect(clip);
        const inner: Shape = .{ .rectangle = rectangle.inset(width), .radius = radius - @min(radius, width) };
        const value = self.surface.encode(color);
        if (self.surface.commands != null) {
            var row = visible.y;
            while (row < visible.y + visible.height) : (row += 1) {
                var start: ?i64 = null;
                var column = visible.x;
                while (column <= visible.x + visible.width) : (column += 1) {
                    var inside = column < visible.x + visible.width and !inner.contains(column, row);
                    if (inside) for (self.shapes[0 .. depth + 1]) |shape| {
                        if (!shape.contains(column, row)) {
                            inside = false;
                            break;
                        }
                    };
                    if (inside) {
                        if (start == null) start = column;
                    } else if (start) |first| {
                        self.surface.fillRect(@intCast(first), @intCast(row), @intCast(column - first), 1, value);
                        start = null;
                    }
                }
            }
            return;
        }
        var y = visible.y;
        while (y < visible.y + visible.height) : (y += 1) {
            var x = visible.x;
            while (x < visible.x + visible.width) : (x += 1) {
                if (!inner.contains(x, y)) self.pixel(x, y, value, depth);
            }
        }
    }

    fn text(self: *Painter, bytes: []const u8, area: Rect, clip: Rect, color: types.Color, scale: u8, depth: usize) void {
        const visible = area.intersect(clip);
        var x = area.x;
        var y = area.y;
        const cell_width: u32 = font.advance * scale;
        const cell_height: u32 = font.line_height * scale;
        for (bytes) |byte| {
            if (byte == '\r') continue;
            if (byte == '\n') {
                x = area.x;
                y += cell_height;
                continue;
            }
            if (byte == '\t') {
                x += cell_width * 4;
                continue;
            }
            const glyph = font.glyph(byte);
            for (glyph, 0..) |bits, dy| {
                for (0..font.glyph_width) |dx| {
                    if (bits & (@as(u8, 1) << @as(u3, @intCast(4 - dx))) == 0) continue;
                    self.fill(.{
                        .x = x + (@as(i64, @intCast(dx)) + font.offset_x) * scale,
                        .y = y + (@as(i64, @intCast(dy)) + font.offset_y) * scale,
                        .width = scale,
                        .height = scale,
                    }, visible, color, depth);
                }
            }
            x += cell_width;
        }
    }

    fn draw(self: *Painter, index: u16, offered: Rect, inherited_clip: Rect, depth: usize) void {
        const node = self.plan.nodes[index];
        const view = node.view;
        var rectangle = offered;
        rectangle.width = view.style.width orelse offered.width;
        rectangle.height = view.style.height orelse offered.height;
        const clip = rectangle.intersect(inherited_clip);
        if (clip.width == 0 or clip.height == 0) return;
        const radius = @min(@as(u32, view.style.radius), @min(rectangle.width, rectangle.height) / 2);
        self.shapes[depth] = .{ .rectangle = rectangle, .radius = radius };
        if (view.style.background_color) |color| self.fill(rectangle, clip, color, depth);
        if (view.style.background_material) |value| self.material(rectangle, clip, value, depth);
        const content = rectangle.inset(view.style.inset);
        const content_clip = content.intersect(clip);
        switch (view.kind) {
            .text => |bytes| {
                // Preflight already checked these borrowed, immutable bytes.
                const size = textSize(bytes, node.scale) catch unreachable;
                self.text(bytes, .{
                    .x = content.x + offset(content.width, size.width, view.style.alignment),
                    .y = content.y + offset(content.height, size.height, view.style.alignment),
                    .width = size.width,
                    .height = size.height,
                }, content_clip, node.foreground, node.scale, depth);
            },
            .spacer => {},
            .zstack => {
                var child = node.first;
                while (child < node.end) {
                    const item = self.plan.nodes[child];
                    const width = item.view.style.width orelse if (view.style.alignment == .stretch) content.width else item.ideal.width;
                    const height = item.view.style.height orelse if (view.style.alignment == .stretch) content.height else item.ideal.height;
                    self.draw(child, .{
                        .x = content.x + offset(content.width, width, view.style.alignment),
                        .y = content.y + offset(content.height, height, view.style.alignment),
                        .width = width,
                        .height = height,
                    }, content_clip, depth + 1);
                    child = item.end;
                }
            },
            .hstack => self.stack(node, content, content_clip, depth, true),
            .vstack => self.stack(node, content, content_clip, depth, false),
        }
        // Borders are overlays, so a child's background cannot erase the edge.
        if (view.style.border_color) |color| {
            if (view.style.border_width != 0) self.border(rectangle, clip, color, view.style.border_width, radius, depth);
        }
    }

    fn stack(self: *Painter, node: Node, content: Rect, clip: Rect, depth: usize, horizontal: bool) void {
        var minimum: u64 = 0;
        var total_weight: u64 = 0;
        var count: u32 = 0;
        var child = node.first;
        while (child < node.end) {
            const item = self.plan.nodes[child];
            minimum += if (horizontal) item.ideal.width else item.ideal.height;
            // A fixed main-axis frame takes precedence over flex.
            const fixed = if (horizontal) item.view.style.width != null else item.view.style.height != null;
            if (!fixed) total_weight += item.view.style.flex_weight;
            count += 1;
            child = item.end;
        }
        if (count == 0) return;
        minimum += @as(u64, count - 1) * node.view.style.spacing;
        const available = if (horizontal) content.width else content.height;
        const remaining = @as(u64, available) - @min(available, minimum);
        var distributed: u64 = 0;
        var weight_before: u64 = 0;
        var cursor = if (horizontal) content.x else content.y;
        child = node.first;
        while (child < node.end) {
            const item = self.plan.nodes[child];
            const fixed = if (horizontal) item.view.style.width != null else item.view.style.height != null;
            const weight: u64 = if (fixed) 0 else item.view.style.flex_weight;
            weight_before += weight;
            const target = if (total_weight == 0) 0 else remaining * weight_before / total_weight;
            const extra: u32 = @intCast(target - distributed);
            distributed = target;
            const main: u32 = (if (horizontal) item.ideal.width else item.ideal.height) + extra;
            const available_cross = if (horizontal) content.height else content.width;
            const fixed_cross = if (horizontal) item.view.style.height else item.view.style.width;
            const ideal_cross = if (horizontal) item.ideal.height else item.ideal.width;
            const cross = fixed_cross orelse if (node.view.style.alignment == .stretch) available_cross else ideal_cross;
            const cross_position = (if (horizontal) content.y else content.x) + offset(available_cross, cross, node.view.style.alignment);
            self.draw(child, .{
                .x = if (horizontal) cursor else cross_position,
                .y = if (horizontal) cross_position else cursor,
                .width = if (horizontal) main else cross,
                .height = if (horizontal) cross else main,
            }, clip, depth + 1);
            cursor += @as(i64, main) + node.view.style.spacing;
            child = item.end;
        }
    }
};

/// Caller-owned scratch. Initialize with `undefined`; rendering initializes
/// exactly the records it uses. Keep exclusive access for the complete call.
/// There is no global renderer state or retained view/surface ownership.
pub const Workspace = struct {
    plan: Plan,
    shapes: [max_depth]Shape,
};

/// Validate/measure before touching any pixel, using caller-owned bounded scratch.
/// Kernel callers should retain a workspace outside their small execution stack.
pub fn renderWithWorkspace(surface: *Surface, workspace: *Workspace, view: types.View) Error!void {
    try surface.validate();
    workspace.plan.count = 0;
    _ = try workspace.plan.visit(&view, 0, types.Color.rgb(255, 255, 255), 1);
    var painter: Painter = .{ .surface = surface, .plan = &workspace.plan, .shapes = &workspace.shapes };
    const bounds: Rect = .{ .x = 0, .y = 0, .width = surface.width, .height = surface.height };
    painter.draw(0, bounds, bounds, 0);
}

/// Convenience for callers with enough stack space for the bounded workspace.
pub fn render(surface: *Surface, view: types.View) Error!void {
    var workspace: Workspace = undefined;
    return renderWithWorkspace(surface, &workspace, view);
}
