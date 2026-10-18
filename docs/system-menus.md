# Native application and system menus

Bedrock has two separate menu layers. Files and Notes render configurable
File, Edit and View menus inside their own windows. Files normally shows its
navigation row and opens those menus with Alt+F/E/V; they temporarily overlay
that row. The protected display
service renders the system bar: the Bedrock menu and existing launch/workspace
strip on the left, firmware-based local time and Control Center on the right.
Fullscreen hides the system bar so the application's caption remains usable.

Both layers use the public `AxisUI.menu` source API. Apps choose their own menu
definitions, palette, placement and trailing widgets. The protected display
service owns the caption and minimize, maximize/restore and close buttons.
Floating windows use an 8-pixel outer radius; maximized and fullscreen windows
have square corners. The darker solid RGB(20,21,26) strip is the 32-pixel title
bar. Notes keeps its app title; Files uses left-aligned tabs with no visible
Files caption. That client-owned accessory is separate from
the app's command menus and the system bar.

Developers provide borrowed groups and items, a caller-owned state and client
bounds. `Layout.initBar` separates a full-width strip from its inset menu labels:

```zig
const items = [_]ui.menu.Item{
    .{ .command = 1, .label = "Save", .shortcut = "Ctrl+S" },
    ui.menu.Item.divider(),
    .{ .command = 2, .label = "Close window", .shortcut = "Alt+F4" },
};
const groups = [_]ui.menu.Group{.{ .label = "File", .items = &items }};
var state: ui.menu.State = .{};
const model = try ui.menu.Model.init(&groups);
const layout = try ui.menu.Layout.initBar(model, client_bounds, .{
    .top = 32, .height = 40,
    .left = 12, .right = 120,
    .padding_top = 8, .padding_bottom = 4,
});
const theme: ui.menu.Theme = .{
    .bar_material = .{ .tint = ui.Color.rgb(24, 29, 39), .opacity = 112 },
    .bar_separator = ui.Color.rgb(55, 59, 71),
};
const result = state.handle(layout, event);
if (result.command) |command| dispatchAppCommand(command);
if (result.changed) requestRedraw();
try ui.menu.drawBackground(&surface, layout, theme);
try drawAppTrailingControls(&surface); // App-owned widgets in the reserved area.
try ui.menu.drawContents(&surface, layout, &state, theme);
```

`BarOptions.top` is relative to the supplied bounds; `height` sets the strip's
height. `left`/`right` and `padding_top`/`padding_bottom` inset the label rectangle
without shortening the background. `layout.background` is the whole strip;
`layout.bar` drives label placement and picking. Labels never create targets in
the reserved trailing area. `Theme.bar_color` overrides the bar material with a
solid fill, and `bar_separator` adds its one-pixel bottom edge. Leave either null
to use the material or omit the edge.

Split painting keeps trailing controls visible while open menus paint above app
content. `draw` remains the convenience call for background followed by contents;
the original `Layout.init(model, bar, bounds)` still supports a supplied bar
rectangle with no separate background strip.

Item labels, shortcut hints, enabled state, checkmarks, separators, group order
and theme are configurable. Shortcut labels are hints; apps implement shortcuts.
Menus support mouse picking, Escape, arrow navigation, Home/End, Enter, Tab and
scrolling. Pointer dispatch requires a matching press/release, and dismissal consumes
the terminal release. The initial limits are eight groups, 32 items per group,
128 items total, printable ASCII labels of at most 48 bytes and shortcut hints
of at most 20 bytes. Models and surfaces must stay valid for the operation.

Files connects its menus to its existing checked file actions and path editor.
Nullify opens the existing guarded context action for a second activation.
Notes connects Save, Reload, Close and editing/navigation actions to its private
notebook. Reload is disabled while unsaved edits exist. Opening a menu cancels
prior app gestures; configuration changes close it.

Files normally uses y=32..72 for Back/Forward/Up, its editable path and
Split/More. The path is x128, y36, height32, width
`client_width-128-(client_width>=640 ? 116 : 64)`. While File/Edit/View is open,
its navigation-material background covers that row, with labels at y=40..68
and 120 pixels reserved on the right. Closing the menu restores navigation.
Notes uses y=0..46, labels at y=12..40, 100 pixels on the right and six pixels
of bottom padding, with its own solid strip color. Popup materials remain
configurable independently of the title bar.

Files' tabs-only title accessory is x8, y4, width `client_width-154`, height24,
with no separate Files label. Notes and generic title/accessory clients retain
the normal `(104,4,client_width-250,24)` geometry when opted in. The public
allocation-free widget accepts borrowed labels and unique stable IDs, a
caller-owned state and an active index. It supports up to 32 items as a generic
framework component; Files chooses an eight-tab navigation store per window.
Apps customize tab fills, text/icon colors and corner radius through
`ui.tabs.Theme`; the default active fill is RGB(39,43,54). Captured matching
press/release and stable IDs prevent closing a different tab after a removal
or reorder. The active tab and + remain reachable in narrow accessories;
wheel navigation and overflow arrows reach other tabs.

`ui.tabs.State.handle` adds `reorder:{from,to}` requests when a captured tab
crosses another tab's midpoint after a six-pixel drag threshold. The source is
resolved by stable ID after each caller-owned move. A lifted tab and insertion
marker remain clipped to the owned header. Vertical gestures do not reorder;
a release more than 16 pixels outside the top/bottom edge returns
`detach:{index,x,y}` in client coordinates. The widget never creates a window.
Escape, redraw cancellation, wheel navigation or a removed source ID cancel
the gesture without a late close/detach. Closing and middle-click gestures
remain distinct from dragging.

Files tabs retain independent paths, histories, pane split/focus, selection
and scroll while sharing the Files process clipboard. Switching relists through the
checked provider and reports ordinary friendly model errors. +/Ctrl+T adds;
X/middle-click/Ctrl+W closes; Ctrl+Tab and Ctrl+Shift+Tab cycle. Closing the
active tab selects a neighbor, and closing the final tab requests window
closure. None of these UI requests grants additional filesystem authority.

The Files adapter supports four windows with eight tabs per window over one
`window_client.Hub` connection and one process. A tear-off keeps the source
record until a real destination window imports it and presents a visible
current-epoch frame acknowledged by the compositor. Failure, timeout or
cancellation rolls back the destination. A single remaining tab moves its
existing window instead. Each window has independent input/menu state and
trusted minimize/maximize/close controls. Closing one retires only its producer
and compositor cache; the process exits when its final window closes. Scoped
WindowID tags, checked producer bindings and authenticated app/PID routing
prevent window controls or tab operations from targeting a foreign process.

Files also exposes `~/Desktop` as a persistent private folder at
`/container/Desktop`. Its shortcut is appended at index 3, preserving Home,
Documents and Downloads values. Launch adds the folder through the checked
provider without resetting storage or replaying sample files. Existing items
are preserved; unavailable or full storage does not prevent the app launching.

The system menu model lives in `userspace/apps/shell/src/system_bar.zig` and uses
the same framework. `system_bar.Config.menu` accepts a borrowed developer-defined
model; `layoutWithConfig`, `handleWithConfig` and `drawWithConfig` share it. The
production compositor's `system_config` is the configuration point. OS developers
can extend that model and its trusted command dispatcher. The leading dropdown
label occupies the reserved 80-pixel slot; launch/workspace and right clock/control
areas keep their separate geometry. Third-party apps currently configure their own window menus;
registration of third-party system-bar status items is future work. A menu
command ID grants no device, filesystem, launch or other app permissions.

Trusted OS developers can also provide `Config.status_items`, up to eight
borrowed `StatusItem` values with a label, optional native icon, enabled state
and command. Command zero defines a display-only readout. Nonzero commands
require matching press/release targets; disabled items never dispatch. The
shared `statusRectWithConfig` places items in the free region between
the layout label and the right clock/control area. Labels clip at whole glyphs;
items with insufficient room remain hidden and cannot receive clicks. Labels
are printable ASCII, at most 24 bytes.
Changing a command or disabling an item cancels its pending activation. The
trusted dispatcher decides what a returned command may do.

For example, a trusted host can supply a readout and an action without changing
the renderer:

```zig
const status_items = [_]system_bar.StatusItem{
    .{ .label = "Build 1" }, // command zero: readout
    .{ .icon = .control_center, .command = system_bar.commands.controls },
};
const system_config: system_bar.Config = .{ .status_items = &status_items };
```

Pass the same configuration to `State.handleWithConfig` and `drawWithConfig`,
then handle returned commands in the trusted host. Keep borrowed definitions
alive while they are used.

Control labels share Axis Sans's stable cap-height baseline through
`font.controlOriginY(top, height, scale)`. Native menu labels and shortcut hints
use that origin, while icons center their 16-pixel boxes. This keeps letters and
icons aligned without moving labels when their text gains a descender.
Declarative controls can use `Text(...).textVerticalAlign(.center)` while keeping
their horizontal placement independently configured with `align`. Centered ink
may use the label's vertical padding for descenders, while its outer frame,
rounded shape and ancestor clips still bound painting.

Control Center changes the actual floating/tiled layout and four workspaces.
Its display dimming multiplies the composed desktop's RGB values at 25%, 50%,
75% or 100%; it is software dimming. The panel also shows the current local
date. Firmware time and its drift limits are documented in [wall-clock.md](wall-clock.md).
Unavailable firmware time displays `--:--` and `Time unavailable`.

AxisUI icons now use original integer vector geometry with antialiased edges,
including folders, documents, navigation, window controls and system controls.
The default 16-pixel icons scale through the same source API. Legacy diagnostic
surfaces explicitly retain their old bitmap glyphs. The renderer allocates no
heap storage and requires no HTML, external icon assets or GPU library.

The [runtime verification](system-menus-verification.md) records the earlier
menu, clock and window-policy baseline on all three QEMU references. AxisUI's
native tests cover strip options, split painting and validation. The new native
tab widget passes Debug and ReleaseSafe tests for narrow overflow, gesture
cancellation, stable IDs and guarded painting; that historical report does not
qualify the title/tab revision on QEMU.
