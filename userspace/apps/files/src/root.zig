//! Native Files model/controller and client views. Provider callbacks are the
//! complete I/O boundary; this package grants no filesystem or pixel authority.
pub const axisui = @import("axisui");
pub const provider = @import("provider.zig");
pub const Provider = provider.Provider;
pub const Entry = provider.Entry;
pub const Kind = provider.Kind;
pub const Model = @import("model.zig").Model;
pub const Pane = @import("model.zig").Pane;
pub const Edit = @import("model.zig").Edit;
pub const Action = @import("layout.zig").Action;
pub const Menu = @import("model.zig").Menu;
pub const MenuKind = @import("layout.zig").MenuKind;
pub const MenuGeometry = @import("layout.zig").MenuGeometry;
pub const menuActions = @import("layout.zig").menuActions;
pub const menuLabel = @import("view.zig").menuLabel;
pub const Geometry = @import("layout.zig").Geometry;
pub const Shortcut = @import("layout.zig").Shortcut;
pub const layout = @import("layout.zig");
pub const Workspace = @import("view.zig").Workspace;
pub const renderWithWorkspace = @import("view.zig").renderWithWorkspace;
pub const colors = @import("view.zig").colors;
pub const materials = @import("view.zig").materials;
pub const max_entries = provider.max_entries;
pub const max_path_bytes = provider.max_path_bytes;
pub const max_name_bytes = provider.max_name_bytes;
test {
    _ = @import("tests.zig");
}
