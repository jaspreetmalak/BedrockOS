# Bedrock desktop shell

The native desktop background, compact bar and theme live here. The shell uses
the public [AxisUI framework](../../../frameworks/public/AxisUI/README.md) to
paint an original continuous charcoal wallpaper with broad muted rose/blue light
fields and a 36-pixel material bar. The primary bar uses rounded translucent
Files/Notes launch pills and a small active workspace marker.
Quiet mixed-case branding, muted Files/Notes launch chips, four functional
workspace indicators and an actual architecture label keep the desktop compact.
The primary native shell displays the compositor's active workspace and tiling
state. The reusable renderer retains its original single-Files bar for the
older regression hosts.

`Shell.system_bar` supplies independent native system menus and Control Center
presentation. Its `State` owns only menu gestures, panel visibility and the
software dim preference. `handle(width,height,event)` returns AxisUI menu
results; the trusted caller applies approved launch, workspace, tiling and
scene-dimming commands. Only matching left press/release pairs activate panel
buttons. Outside dismissal consumes the following release, and Escape cancels
the panel. Closing preserves the dim preference.

`draw(surface,state,Clock,workspace,tiled)` overlays the Bedrock menu at the
left and the current clock/Control Center at the right of the existing 36-pixel
bar, leaving the app launch and workspace strip caller-owned. The host supplies
`Clock{available,seconds}` after applying its calendar offset; absent or invalid
time displays `--:--` and `Time unavailable`. Gregorian date conversion supports
years 1..10000 and negative Unix epochs with integer arithmetic. The panel has
working policy targets for Floating/Tiled, four workspaces and software dim
levels 25/50/75/100 percent. Dimming changes rendered scene colors; the UI makes
no hardware brightness or network claim. Rounded glass uses the caller's private
immutable backdrop and AxisUI's original smooth vector icons.

Trusted OS developers configure the leading system dropdown through
`system_bar.Config{.menu=ui.menu.Model}`. `default_model` exposes the borrowed
Bedrock definition, whose items can be copied into a caller-owned bounded array
and extended. `layoutWithConfig(width,height,config)`,
`State.handleWithConfig(width,height,event,config)` and
`drawWithConfig(surface,state,clock,workspace,tiled,config)` use that same
definition for picking, command dispatch results and drawing. The original
`layout`, `handle` and `draw` entry points delegate to the default configuration.
The leading slot remains 80 pixels wide, intended for one dropdown label;
custom commands live inside that dropdown and popups retain AxisUI's bounded
geometry. The clock, Control Center and app strip keep their separate regions.
Borrowed groups/items/labels remain valid and unchanged through each event and
draw; send redraw cancellation when replacing configuration. Returned command
IDs are data for the trusted host to approve and handle. This hook introduces
no third-party app registration, new IPC capability or resource authority.

`Config.status_items` adds trusted native status readouts or buttons between
the existing launch/workspace/layout strip and the clock/Control Center:

```zig
const status = [_]Shell.system_bar.StatusItem{
    .{ .label = "Online", .icon = .wifi, .command = 700 },
    .{ .label = "42%" }, // A display-only readout.
};
const config: Shell.system_bar.Config = .{ .status_items = &status };
const result = try state.handleWithConfig(width, height, event, config);
if (result.command) |command| dispatchTrustedCommand(command);
try Shell.system_bar.drawWithConfig(&surface, &state, clock, workspace, tiled, config);
```

There are at most eight borrowed status items with printable ASCII labels of
at most 24 bytes. Each has a label, an optional shared native `Icon`, a command
ID and an `enabled` flag. Zero commands are display-only; disabled or display
items never dispatch an action. The default list is empty, preserving existing
bar pixels and geometry. On reference screens the reserved strip begins at
x488 and ends eight pixels before the clock region at `width-154`, with y4 and
height28. `statusRectWithConfig(width,index,config)` exposes the shared painted
and picked rectangle. Long labels clip by whole glyphs; overflow items acquire
no hidden targets. Status items use original smooth icons and quiet glass hover
feedback. Their gestures retain the index and command ID, so mismatched releases,
replaced commands and disabled targets cannot dispatch. An open system menu or
panel owns outside dismissal before a status button can activate. Configurations
and label buffers remain caller-owned; cancel gestures before replacing them.
Commands are still data for trusted host policy, and runtime registration from
third-party app processes remains separate future work.

```zig
const Shell = @import("desktop_shell");
const AxisUI = Shell.axisui;

// Caller-owned BSS scratch, used by one renderer at a time.
var scratch: AxisUI.Workspace = undefined;

var surface = try AxisUI.Surface.init(pixels, width, height, stride, masks);
try Shell.renderWithWorkspace(&surface, &scratch, "ARM64");
```

Use the reexported `Shell.axisui` for the same module instance and `Surface`
type. `renderWithWorkspace` builds borrowed `View` arrays locally and immediately
calls AxisUI; no tree escapes its lifetime. The caller retains an
`AxisUI.Workspace`, initialized as `undefined`, in owned storage and serializes
its use. Native and regression hosts keep scratch in BSS to preserve guarded stacks.
Production rendering requires no allocator. The convenience `render` allocates
scratch on the stack for host callers.

`launchRect(width,height)` returns the clipped actual Files launch target:
`x = 94..165` and `y = 0..35` on the reference sizes. The primary shell keeps
this Files chip and adds Notes at `x = 180..251`. A matching left press/release,
Super+E/Super+Enter for Files or Super+N for Notes sends an authenticated launch
request to the compositor. The service restores or focuses a live window, or
asks init to launch a fresh approved app. The shell has no app-launch permission.
The legacy kernel host reuses the Files rectangle for its separate pointer dispatch.
Workspace indicators occupy four 30-pixel positions starting at x270; the
compositor handles their switching and the Super+1..4 shortcuts. Super+Shift+1..4
moves the focused window, Super+T toggles tiling and Super+Tab cycles visible
focus. Window dragging, edge/corner resize and caption controls remain service policy.
`bar_height=36` and the theme `palette` are exported. Wallpaper rows use at most
128 native clipped spans, with smooth integer light-field shading.
The renderer uses no allocation or external image assets. View typography uses
AxisUI's original proportional [Axis Sans](../../../frameworks/public/AxisUI/AXIS_SANS.md)
face with grayscale antialiasing and a 20-pixel line height at native scale1.
Larger integer text scales evaluate coverage directly from the original font's
flattened vector geometry, so larger labels retain their shape rather than
magnifying the base bitmap. Very small text remains limited by the display's
pixel density.
Labels are centered using measured widths, with no automatic upscale on a larger
framebuffer. Its current 95 printable ASCII glyphs use a question-mark fallback
for other bytes. The font is original Bedrock work; no external Apple font or
HTML renderer is used. Historical diagnostic callers can explicitly select
AxisUI's legacy text mode.

The compositor's compact 32-pixel native header places the app title left,
a configurable centered accessory and neutral minimize/maximize/close controls
right. Files fills the center with its private location field. Click it or press
Ctrl+L, enter `~/Documents`, `~/Downloads` or a canonical `/container/...` path,
and press Enter. Title dragging and controls remain compositor policy; the shell
does not receive client header or filesystem authority.

The host can separate the two paint phases to supply genuine backdrop blur:

```zig
try Shell.renderWallpaper(&surface);
// Caller retains both buffers and the Backdrop value in owned storage.
var backdrop = try AxisUI.Backdrop.build(&surface, colors, blur_scratch);
try surface.setBackdrop(&backdrop, .{ .x = 0, .y = 0 });
try Shell.renderBarWithWorkspace(&surface, &scratch, "ARM64");
```

`Backdrop.requiredLen(width,height)` returns the required length of each cache
buffer. The immutable cache is built from wallpaper before chrome or clients
are painted. The bar samples this frozen backdrop with charcoal tint and
opacity170; it does not blur or sample its own output. `renderWallpaper` paints
only the wallpaper, while `renderBarWithWorkspace` writes only the clipped top
36 pixels. The one-pass `render`/`renderWithWorkspace` helpers do not create a
cache: without a caller-provided backdrop, AxisUI uses the solid charcoal tint
fallback. Wallpaper, cache and material coordinates use the same Surface.

The package exports module `desktop_shell` and static compile-probe artifact
`bedrock-desktop-shell`. It accepts standard target/optimization options and
`-Drelocatable=true` for firmware-loaded regression hosts. Independent
`check` compiles the composition; `test` renders both 800x600 and 1280x800 into
bounded native buffers and checks caller-supplied architecture text. These steps
do not install into the root workspace's output directory.

`src/window_main.zig` builds the primary installed `bedrock-window-shell`
process under trusted identity 107. It owns one full-screen surface and an
immutable wallpaper blur cache, and uses native window IPC for input and
authenticated workspace/tiling/focus status. Its producer renders the wallpaper
and bar; the compositor retains only the 36-row bar and regenerates the public
procedural wallpaper in its scene. Init 101, compositor 104, shell 107, Files 2
and Notes 108 form five processes with six live surfaces: three compositor
surfaces and one per client. Shell and compositor retain their PIDs while either
GUI app closes or faults and relaunches independently.
See the [window desktop guide](../../../docs/window-desktop.md) and primary
`test-window-desktop` runtime gate.

`src/main.zig` / `bedrock-desktop-shell` retains the earlier single-window
service-desktop regression and its original Files-only bar. The pure library
renderer also remains available to kernel-hosted regressions.

The legacy kernel display host still uses the pure library renderer for its
separate regression profile. The storage/client extension's integrated
verification passed on all three UEFI references in Debug and ReleaseSafe; see
the [storage/Files record](../../../docs/storage-and-files-verification.md).
The compact visual revision has separate package layout/guard checks; its
integrated screenshots and input acceptance belong to the host verification.

AxisUI supplies reusable UI primitives. This package owns desktop-specific
views, themes and composition. Reusable internal service APIs will live in
private frameworks when those services exist. Mandatory app isolation depends
on kernel mechanisms and checked grants.
