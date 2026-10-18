//! Host-only pixel QA exporter. Native painting still evaluates vector paths;
//! this JSON is an oracle for screenshot checks, never a runtime icon asset.
const std = @import("std");
const ui = @import("axisui");
test "export icon coverage" {
    std.debug.print("AXIS_ICON_COVERAGE {{\"size\":16,\"icons\":{{", .{});
    inline for (.{ "close", "minimize", "maximize", "restore", "control_center", "clock", "folder", "document", "home", "check" }, 0..) |name, index| {
        if (index != 0) std.debug.print(",", .{});
        std.debug.print("\"{s}\":[", .{name});
        for (0..16) |y| for (0..16) |x| {
            if (y != 0 or x != 0) std.debug.print(",", .{});
            std.debug.print("{d}", .{ui.icons.coverage(@field(ui.Icon, name), @intCast(x), @intCast(y), 1)});
        };
        std.debug.print("]", .{});
    }
    std.debug.print("}}}}\n", .{});
}
