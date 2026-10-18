//! Native, allocation-free declarative software UI. See README for lifetimes.
const types = @import("types.zig");
pub const Color = types.Color;
pub const PixelMasks = types.PixelMasks;
pub const Align = types.Align;
pub const View = types.View;
pub const Text = types.Text;
pub const HStack = types.HStack;
pub const VStack = types.VStack;
pub const ZStack = types.ZStack;
pub const Spacer = types.Spacer;
pub const Surface = @import("surface.zig").Surface;
pub const CommandSink = @import("surface.zig").CommandSink;
pub const Error = @import("surface.zig").Error;
pub const max_surface_dimension = @import("surface.zig").max_surface_dimension;
pub const max_depth = @import("render.zig").max_depth;
pub const max_nodes = @import("render.zig").max_nodes;
pub const render = @import("render.zig").render;
pub const Workspace = @import("render.zig").Workspace;
pub const renderWithWorkspace = @import("render.zig").renderWithWorkspace;
pub const input = @import("input.zig");
pub const events = input;
pub const Event = input.Event;
pub const Queue = input.Queue;
pub const Point = input.Point;
pub const Rect = input.Rect;
pub const HitMap = input.HitMap;
pub const drawCursor = input.drawCursor;
pub const State = @import("state.zig").State;
pub const font = @import("font.zig");
pub const icons = @import("icons.zig");
pub const Icon = icons.Icon;
pub const drawIcon = icons.draw;
pub const menu = @import("menu.zig");
pub const tabs = @import("tabs.zig");
pub const materials = @import("materials.zig");
pub const Material = types.Material;
pub const Backdrop = materials.Backdrop;

test {
    _ = @import("tests.zig");
    _ = @import("material_tests.zig");
    _ = @import("font_tests.zig");
    _ = @import("menu_tests.zig");
    _ = @import("tabs_tests.zig");
    _ = input;
    _ = @import("state.zig");
}
