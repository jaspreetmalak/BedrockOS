# AxisUI

AxisUI is Bedrock's public native Zig UI foundation. It uses declarative view
values and an integer-only software renderer, with no firmware, kernel, heap
or third-party dependency. This first version renders
immediately into a caller-owned 32-bit surface or a bounded drawing-command
receiver. It also provides input queues, hit testing and explicit state
revisions. Accessibility, implicit bindings/reconciliation and app compositor
services remain separate work.

The package exports module `axisui` and static compile probe `bedrock-axisui`.
Use Zig 0.17.0. `zig build test` runs native tests; `zig build check` compiles
the probe. Standard `-Dtarget` and `-Doptimize` options are supported;
`-Drelocatable=true` enables PIC. Freestanding x86 code disables the red zone;
x86 uses the small code model and RV64 uses medium.

```zig
const ui = @import("axisui");
var surface = try ui.Surface.init(pixels, width, height, stride, .{
    .red = 0x00ff0000, .green = 0x0000ff00, .blue = 0x000000ff,
});
const labels = [_]ui.View{
    ui.Text("Bedrock").scale(2),
    ui.Spacer(),
    ui.Text("Native UI"),
};
try ui.render(&surface, ui.HStack(&labels)
    .padding(12).gap(8).@"align"(.center)
    .foreground(ui.Color.rgb(229, 237, 245))
    .background(ui.Color.rgb(16, 20, 28)));
```

`Color.rgb(r,g,b)`, `PixelMasks`, `Surface.init` and `render` are the surface
interface. `Text`, `HStack`, `VStack`, `ZStack` and `Spacer` return `View` values.
Fluent modifiers are `padding(u16)`, `gap(u16)`, `frame(?u16,?u16)`,
`foreground(Color)`, `background(Color)`, `border(Color,u8)`,
`cornerRadius(u16)`, `smoothCorners()`, `scale(u8)`, `flex(u16)`, `@"align"(Align)`
and `textVerticalAlign(Align)`.
`material(Material)` replaces a solid background with a frozen backdrop blend.
Zig reserves `align`, so callers spell the method `.@"align"(...)`.
`Align` values are `start`, `center`, `end`, `stretch`.

View text and child slices are borrowed. They must remain valid and unchanged
through the complete `render` call; local arrays work when rendered before
their scope ends. Views do not own or retain buffers after rendering. Surface
exposes `width`, `height`, `stride`, `pixels` and `masks`; callers must retain
exclusive access and establish device mapping/cache policy before rendering.
No firmware calls or GPU command execution occur here.

Protected clients can render without pixel storage:

```zig
var surface = try ui.Surface.initCommands(width, height, .{
    .context = receiver,
    .fillRect = submitRectangle,
});
try ui.renderWithWorkspace(&surface, &workspace, view);
```

`CommandSink.fillRect` has signature
`fn (*anyopaque, u32, u32, u32, u32, u32) void`: context, x, y, width,
height and standard `0x00RRGGBB` pixel. The renderer keeps the same graph
validation, ancestor clipping and rounded outlines. Fully contained fills
coalesce into rectangles; clipped fills and borders coalesce into row spans.
The receiver must enforce its own window authority and record failures in
its context; callbacks do not unwind rendering. This interface grants no
framebuffer access. Callbacks must not reenter rendering or mutate the borrowed
surface/workspace. `Surface.validate`, `putPixel` and `fillRect` also support
both backends; direct painting requires a validated, exclusively owned surface.

Kernel or other small-stack callers should use caller-owned scratch:

```zig
var workspace: ui.Workspace = undefined; // May be permanent caller-owned storage.
try ui.renderWithWorkspace(&surface, &workspace, view);
```

The argument order is surface, workspace, view. `Workspace` is implementation
scratch, not persistent UI state; rendering initializes its used records and
never uses borrowed view or pixel storage after returning. Keep exclusive access through a
call. It can be reused after success or error. The `render` convenience wrapper
puts roughly 26 KiB of workspace on its caller's stack; native kernel integration
uses explicit permanent storage instead. No global workspace lives in AxisUI.

Intrinsic layout uses original proportional Axis Sans ASCII glyphs with grayscale
coverage at integer scale 1 through 16. The unscaled line height is 20 pixels,
the baseline is 15, the cap height is 12 and the x-height is 9.
`font.glyphAdvance(byte)` returns each glyph's 4-to-14-pixel logical advance.
Scale1 uses a dense gray8 base atlas. Scales 2 through 16 draw directly from
compact fixed-point vectors flattened from the original curves, using 8×8
subpixel coverage at partial edges. Larger text does not magnify a small bitmap.
Native painting remains integer-only and allocation-free. Very small text still
depends on the display's pixel density.
`font.measure(bytes,scale)!font.Size` returns checked width/height and is the
renderer's measurement source; chrome and cursor code should measure text rather
than multiply by `font.advance`, which is only an approximate column estimate.
`font.paint` and `font.paintGlyph` expose the same smooth face to native clients.
Unsupported bytes use a question mark. Newlines make new rows, carriage returns
are ignored, and tabs advance four spaces. There is no UTF-8 shaping or automatic
wrapping yet. The original 5-by-7 `font.glyph(byte)` patterns remain available for
bootstrap callers. Setting `Surface.legacy_text=true` explicitly selects their
6-by-10 metrics for declarative rendering; smooth text is the default. See
[AXIS_SANS.md](AXIS_SANS.md) for the original font source, metrics and coverage API.
Foreground and scale inherit; backgrounds, borders and corners are local.
`cornerRadius` retains binary clipping for compatibility with bootstrap
diagnostics. Add `.smoothCorners()` for four-by-four grayscale corner coverage;
solid/material backgrounds, inward borders and descendants share that clip.
The radius clamps to half the smaller rectangle extent. Fully covered row spans
stay coalesced, with coverage callbacks only at partial edges.

For direct native painting, the same antialiased geometry is available through
`Surface.roundedRect(x:i32,y:i32,width:u32,height:u32,radius:u32,Color)`,
`roundedMaterialRect(...,Material)` and
`roundedBorder(x,y,width,height,radius,Color,line_width:u32,opacity:u8)`.
Placement is signed and clipped to the already validated, exclusively borrowed
surface. Borders sit inside the supplied rectangle; opacity controls their
highlight strength. `materials.roundedCoverage(width,height,radius,x:i64,y:i64)`
returns gray8 coverage at relative pixel coordinates, and `roundedContains`
uses half coverage for matching pointer picking. Both use half-open bounds and
defined integer arithmetic even for oversized or offscreen geometry.

`Icon` provides original native vectors for `folder`, `document`, `home`,
`chevron_left/right/up/down`, `control_center`, `clock`, `wifi`, `speaker`,
`brightness`, `minimize`, `maximize`, `restore`, `close` and `check`.
`drawIcon(surface,icon,point,color,scale)` validates before painting, accepts
signed placement and scale 1..16, and clips at every surface edge. The 16-pixel
design paths use integer distance coverage for smooth rounded strokes, circles
and arcs. Larger sizes scale the paths and stroke widths directly. Fully opaque
row spans remain coalesced; gray edges use `CommandSink.blendPixel` when present,
with the established half-coverage fallback for simpler command receivers.
`icons.coverage(icon,x:u32,y:u32,scale:u8)` exposes the same relative gray8
coverage and returns zero outside the design box or for an invalid scale.
The original `icons.pattern(icon)` bitmaps remain unchanged for the first seven
navigation icons; newer controls produce thresholded vector patterns. Explicit
`Surface.legacy_text=true` selects binary diagnostic drawing. Direct icon paint
does not inherit a View's rounded ancestor clip; callers place it within owned
client bounds. No allocation, floating-point instructions, runtime sampling grid
or external font or image asset is needed.

`icon-coverage.json` is a host screenshot-QA oracle exported from the actual
native `icons.coverage` function. Its source SHA256 detects a stale oracle; it
is never embedded into native UI binaries. Regenerate from the package directory
after changing vector geometry:

```powershell
zig test --dep axisui '-Mroot=tools/export_icon_coverage.zig' '-Maxisui=src/root.zig' --test-filter 'export icon coverage' 2>&1 | Set-Content .zig-cache/icon-coverage-export.txt -Encoding utf8
python tools/export_icon_coverage.py
```

A frame sets outer width/height, including padding. Padding reduces content
space. Stack gaps separate direct children. Flexible children receive a
weighted share of space left after intrinsic sizes and gaps; a fixed frame
on that axis takes precedence over flex. `Spacer` has zero intrinsic size and
default weight 1. Stack alignment controls the cross axis; overlay alignment
controls both axes. Text alignment positions its glyph block within its frame.
`textVerticalAlign(.center)` independently centers a text leaf vertically while
`align` retains its horizontal placement. Native centered text uses a shared
cap-height baseline, including mixed labels and values. Descenders may extend
into the leaf's vertical padding, with the outer frame and ancestor clips still
enforced. `font.controlOriginY(top,height,scale)` and
`font.labelOriginY(height,scale,legacy)` expose the same placement to direct
painters. Editor line spacing and legacy diagnostic layout remain separate.
Stretch fills the available cross axis for unframed views.

Native tab strips use the public `ui.tabs` module. The application supplies
borrowed labels, nonzero unique stable IDs, its active index and caller-owned
input state. Tabs do not create windows or retain application contents:

```zig
const items = [_]ui.tabs.Item{
    .{ .id = 1, .label = "Documents", .icon = .folder },
    .{ .id = 2, .label = "Desktop", .icon = .folder },
};
var state: ui.tabs.State = .{}; // Retain between events and frames.
const layout = try ui.tabs.Layout.init(owned_strip_bounds, &items, active_index);
const result = state.handle(layout, event);
if (result.select) |index| try selectAppTab(index);
if (result.close) |index| try closeAppTab(index);
if (result.add) try addAppTab();
if (result.changed) requestRedraw();
// Rebuild the layout after changing the tab model, then draw the current state.
try ui.tabs.draw(&surface, current_layout, &state, .{});
```

`Item` contains `id:u32`, `label:[]const u8`, `closable:bool=true` and an optional
native `icon`. `Layout.init(bounds,items,active_index)` validates one through
32 items, printable ASCII labels of one through 96 bytes, unique nonzero IDs,
the active index and nonnegative bounds of at least 48×20 pixels. Definitions
and labels remain borrowed and unchanged through each event or draw operation.
Return values are app-owned requests, with `select:?usize`, `close:?usize`,
`add:bool`, `reorder:?{from:usize,to:usize}`, `detach:?{index:usize,x:i32,y:i32}`,
`dragging:bool`, `consumed:bool` and `changed:bool`; the application applies them and
owns any resulting storage or permissions. Send all events through the widget
while it holds a pointer gesture. `State.cancel()` or redraw `code=1` cancels
obsolete gestures when geometry or visibility changes. Applying a requested
reorder preserves the captured stable ID; rebuild the layout without canceling
that gesture.

The active tab stays visible alongside adjacent tabs. Comfortable tab widths
range from 72 to 160 pixels; narrow strips clip labels while retaining a
16×16 close target and a 24-pixel add button. Overflow arrows appear when there
is space, and the wheel cycles through every tab even at narrow widths.
The add button follows the last visible tab; overflowing bars keep it beside
their right-side navigation arrows.
`tabRect(index)`, `closeRect(index)`, `addRect()`, `previousRect()`, `nextRect()`
and `hit(point)` expose painted geometry. Hidden tabs have no invisible targets.
Matching left press/release selects, closes or adds; matching middle
press/release closes a closable tab. Stable IDs prevent a removed or replaced
tab's captured release from closing its neighbor. Do not reuse an ID while a
gesture is pending. Keyboard shortcuts remain application-owned.

A captured left press on a tab body becomes a drag after six pixels of movement.
The first drag result selects that stable source and may also request a reorder;
apply both requests when present. Crossing a neighboring midpoint returns
`reorder` with current source index and its final destination index. Continued
edge movement reaches hidden overflow neighbors. A vertical gesture does not
reorder; releasing more than 16 pixels outside the strip's top/bottom returns
`detach` with the source's current index and client-local release coordinates.
Escape, redraw cancellation, wheel navigation or a removed source cancels
capture. Dragging across an X cannot accidentally close the tab. Rendering
shows a lifted native tab and insertion marker strictly within the owned strip.
`State.isDragging()` and `draggedId()` expose the retained gesture. The widget
does not create a window, move application records, access files or acquire
another surface; a host such as Files decides how to service a detach request.

`Theme` configures background, active and hovered fills, text/icon and insertion
marker colors and
corner radius. Defaults use RGB(20,21,26) for the strip, RGB(39,43,54) for the
active tab and a four-pixel radius. Drawing validates before writing and clips
all labels, icons and controls to the supplied strip. No heap or frame-sized
scratch is added. The widget works in an app toolbar or an opted-in title
accessory; it cannot claim the trusted window controls or window-drag regions.
Files uses the tabs-only `(8,4,inner_width-154,24)` caption accessory without a
visible Files title, and limits each of four windows to eight navigation tabs,
distinct from the framework's 32-item bound. Native Debug and ReleaseSafe tests
cover narrow overflow, matched/canceled gestures, stable-ID reordering and
detach requests, and guarded normal/drag-preview painting.

Native app menus use the public `ui.menu` module. A menu definition is borrowed
data, so the same component can live in a window toolbar or an owned system
bar. Developers supply group labels and app-owned command IDs:

```zig
const file_items = [_]ui.menu.Item{
    .{ .command = 1, .label = "Open", .shortcut = "Ctrl+O" },
    ui.menu.Item.divider(),
    .{ .command = 2, .label = "Show hidden files", .checked = true },
};
const groups = [_]ui.menu.Group{.{ .label = "File", .items = &file_items }};
const model = try ui.menu.Model.init(&groups);
const layout = try ui.menu.Layout.initBar(model,
    .{ .x = 0, .y = 0, .width = 316, .height = 236 },
    .{ .top = 32, .height = 40, .left = 12, .right = 100,
       .padding_top = 8, .padding_bottom = 4 });
const theme: ui.menu.Theme = .{
    .bar_material = .{ .tint = ui.Color.rgb(24, 29, 39), .opacity = 112 },
    .bar_separator = ui.Color.rgb(55, 59, 71),
};
var menu_state: ui.menu.State = .{}; // Retain this between frames/events.
const result = menu_state.handle(layout, event);
if (result.command) |command| {
    // Dispatch through this application's existing permission-checked actions.
    _ = command;
}
// After app content, paint the strip, native trailing widgets, then labels/popups.
try ui.menu.drawBackground(&surface, layout, theme);
try drawAppTrailingControls(&surface); // Application-defined, within its reserve.
try ui.menu.drawContents(&surface, layout, &menu_state, theme);
```

`Item` also exposes `enabled`, `checked` and `separator`. Shortcut strings are
display hints; applications retain keyboard shortcut dispatch and resource
permissions. Definitions accept at most eight groups, 32 rows per group and
128 total rows. Labels are printable ASCII, at most 48 bytes; shortcut hints
are at most 20 bytes. Active commands use nonzero IDs, with unique IDs within
each group. Separators carry no command. `Model.init` and `validate` reject
invalid definitions before geometry or drawing. The definition slices and
label bytes must remain valid and unchanged through each layout, event and
draw operation. Refresh the layout and send a redraw event with `code=1` when
replacing a definition or changing its geometry.

`Layout.initBar(model,bounds,BarOptions)` uses a full-width strip inside
nonnegative client-local bounds. `top` is relative to those bounds, `height`
sets the strip height, `left`/`right` reserve horizontal space and
`padding_top`/`padding_bottom` place the labels vertically. Defaults are
`top=0`, `height=40`, `left=right=12`, `padding_top=8`, `padding_bottom=4`.
`layout.background` stores the full strip, including trailing space;
`layout.bar` stores the inset label rectangle used for picking. Padding must
leave a nonempty width and at least the 20-pixel font line height. Invalid
dimensions, bounds and padding return `InvalidMenu` before painting.

`Theme.bar_color` optionally selects a solid background instead of
`bar_material`; `bar_separator` optionally draws a one-pixel bottom edge.
`drawBackground(surface,layout,theme)` paints only that strip and edge.
Apps may then render native controls in the reserved area before
`drawContents(surface,layout,state,theme)` paints labels and the open popup.
`draw(surface,layout,state,theme)` composes both calls when no controls need
to be painted between them. Menus, palettes, placement and trailing widgets
belong to the app; trusted window caption controls remain host-owned.

The compatible `Layout.init(model,bar,bounds)` accepts an explicit label/bar
rectangle and leaves `background` null, so background painting uses that same
bar. Its bounds must be at least 32 pixels wide and the bar at least 20 pixels
high. `bar_height=28` is a suggested size, while 36- and 40-pixel toolbars also
work. `groupRect`, `popup`, `rowRect` and `hit` expose
the exact painted/picked geometry. Clipped labels create no hidden target
outside the bar. Popups clamp to their owned viewport and only whole rows
receive input. Long menus scroll with the wheel or keyboard selection.

`State.open(layout,index)` enables explicit keyboard menu activation.
`handle(layout,event)` returns `consumed`, `changed` and an optional `command`.
Feed all events while a menu is open. A matching left press/release dispatches
an enabled command; unmatched releases, disabled rows and separators do not.
An outside press dismisses the menu and consumes its release to prevent
clickthrough. Up/down skip unavailable rows, left/right change groups,
Home/End select their first/last available row, Enter dispatches, and Escape
or Tab dismisses. Redraw `code=1` cancels old gestures; focus redraw `code=0`
retains the current menu. `Theme` customizes text, solid strip colors and
frozen-backdrop materials.
Bar labels, checkmarks, popup edges and selection highlights use the same
smooth Axis Sans, icons and rounded material primitives as the native UI.
No heap, device access, framebuffer privilege or frame-sized scratch is added;
the retained state is less than 32 bytes.
Children paint in declaration order; borders paint afterward as overlays.
Oversized descendants clip to ancestor content rectangles and rounded outlines,
then to the surface. A zero-sized frame paints nothing.

`Surface.init` rejects zero/oversized dimensions, short storage, invalid stride
and overlapping/empty channel masks. Width and height are limited to 16,384
pixels; stride may include padding. Channel masks can be reduced precision or
noncontiguous: 8-bit channels scale to mask precision and scatter into its bits.
Reserved bits remain zero. Drawing leaves scanline padding untouched.

Before any writes, rendering revalidates the surface and checks/measures the
entire graph. Maximum depth is 32 levels including the root, with at most
1,024 visits (shared subtrees count each occurrence). Cycles, invalid scales,
capacity/depth exhaustion and checked layout-size overflow return an error
without painting. Rendering uses bounded stack storage and no allocation.
It does not verify the physical accessibility of a caller-provided pointer.

## Frosted materials

`Material` contains `tint:Color` and `opacity:u8=192`. Opacity 0 shows the frozen
blurred backdrop exactly and 255 shows the tint exactly. Intermediate channels
use `(backdrop*(255-opacity)+tint*opacity+127)/255`. View backgrounds are local:
`.material(...)` clears a solid background and `.background(...)` clears the
material. Manually setting both style fields is `InvalidMaterial`, rejected
during graph preflight before painting.

`materials.glass.window`, `.sidebar` and `.control` are restrained dark-glass
presets with tint opacity 136, 104 and 124. They use the existing `Material`
value shape; no extra blur cache or pixel access is implied. `.edge` and
`.edge_opacity=42` provide a quiet rounded outline:

```zig
surface.roundedMaterialRect(8, 8, 320, 240, 16, ui.materials.glass.window);
surface.roundedBorder(8, 8, 320, 240, 16,
    ui.materials.glass.edge, 1, ui.materials.glass.edge_opacity);
```

The caller builds a cache from readable pixels and retains its storage:

```zig
const count = try ui.Backdrop.requiredLen(source.width, source.height);
// colors and scratch are separate caller-owned u32 slices of at least count.
var backdrop = try ui.Backdrop.build(&source, colors, scratch);
try destination.setBackdrop(&backdrop, .{ .x = global_x, .y = global_y });
try ui.renderWithWorkspace(&destination, &workspace,
    ui.Spacer().material(.{ .tint = ui.Color.rgb(18, 24, 33), .opacity = 170 }));
```

`Backdrop` borrows immutable standard `0x00RRGGBB` colors with full-resolution
`width`/`height` and sampled-grid `stride`. The fixed recipe downsamples 8×8
blocks, then performs horizontal and vertical box blur with a 24-pixel radius
(three sampled cells each way), using replicated edges and rounded integer
averages. Sampling bilinearly interpolates between cell centers at 3.5, 11.5, ...
source pixels. `materials.step=8` and `materials.radius=24` expose this recipe.
`sample(x:i64,y:i64)` clamps out-of-range coordinates to source edges.
Dimensions are bounded by the same 16,384-pixel surface limit; storage needs
`ceil(width/8)*ceil(height/8)` values per buffer. At 1280×800 this is 16,000
values, or 64,000 bytes per buffer. There is no heap allocation in AxisUI.

Build validates geometry and all storage before writing. Colors/scratch cannot
overlap each other, source pixels or source metadata. Build does not modify
the source and cannot capture a command-only surface. RGB/BGR, reduced and
scattered source masks are decoded into canonical colors. Freeze the descriptor
and cache for every complete rendering call; regenerate only between frames
under caller serialization. Direct destinations reject a cache descriptor or
color storage overlapping their pixel storage, preventing redraw feedback.
Source/caches must be physically accessible; this API does not establish memory
mapping, access grants or object lifetime.

`Surface.backdrop` is an optional borrowed descriptor pointer and
`backdrop_origin` is a signed source offset for a local destination.
`setBackdrop(pointer?,origin)!void` validates before changing those fields.
`Surface.materialRect(x,y,width,height,Material)` clips like `fillRect` and
requires a previously validated, exclusively borrowed surface/backdrop.
Missing backdrops fall back to a solid tint. Declarative material fills use the
same ancestor/rounded clipping as solid fills and coalesce complete rectangles
or clipped row spans; text, borders and opaque controls remain ordinary draws.

Command receivers may provide optional `CommandSink.materialRect` with signature
`fn(*anyopaque,u32,u32,u32,u32,Material)void`. It receives clipped local bounds
and material values; the trusted receiver selects its frozen backdrop and
enforces window ownership. An absent callback emits an ordinary solid-tint
fill instead. Material requests never grant raw pixels or framebuffer access,
and neither backend reads the changing destination to implement the effect.

Antialiased material edges may additionally use
`CommandSink.materialPixel:fn(*anyopaque,u32,u32,Material,u8)void`, with coverage
as the final argument. The receiver selects its own frozen backdrop and can
forward to `Surface.materialPixel`. Full coverage uses `materialRect`; partial
coverage first samples the immutable material color, then blends only its
geometric edge over the destination. A receiver without this callback falls
back to a coverage-blended solid tint at partial edges; receivers without
`blendPixel` retain the existing half-coverage threshold fallback. Translated
native overlays forward both coverage callbacks for exact pixel parity.
Repaint a frame's base before translucent overlays. Rebuilding a cache from the
immutable source and painting the same base produces the same result each
frame, with no accumulated blur or source modification.

These APIs are an initial source interface, not a frozen framework binary ABI
or compatibility claim with SwiftUI or Apple platforms.

## Input and explicit state

`input` (also exported as `events`) defines `Event`, `Kind`, `Button`, `Key`,
modifier constants, `Queue(capacity)`, `Point`, `Rect`, `HitMap(capacity)` and
`drawCursor`. Queue/geometry/cursor types are also reexported at the root.
The eight-byte event encoding is kind bits 0–7, modifiers 8–15, code 16–31,
signed x 32–47 and signed y 48–63. `Event.encode()` returns a `u64`;
`Event.decode(u64)` rejects unknown kinds and modifier bits. Text carries a
codepoint in `code`; the current font and Files editor remain ASCII.

Kinds are pointer move/down/up (1/2/3), key down/up (4/5), text (6) and wheel
(7). Pointer buttons are left/middle/right (1/2/3); modifiers are
shift/control/alt/super (1/2/4/8). Wheel `code` is a signed i16 row delta.
Key control codes use ASCII; arrows and other navigation keys have explicit
values in [input.zig](src/input.zig). Coordinates are local to the client.
The host supplies translation, focus, capture and device ownership.

`Queue.push` rejects overflow and malformed events, preserving queued release
events; `pop` returns FIFO events and `clear` discards all records. The host
must serialize access and recover explicitly from overflow. `Rect.contains`
uses half-open bounds and checked-width-independent arithmetic; `HitMap.hit`
selects the last added covering rectangle. Cursor drawing clips to the surface
and preserves stride padding on the framebuffer backend.

`State(T){ .value=initial }` exposes `revision`, `set(value)!bool` and
`changedSince(revision)`. Equal values do not invalidate; revision exhaustion
returns an error before changing the value. The host observes revisions and
schedules rendering. These primitives do not implement implicit dependencies,
accessibility or full view reconciliation. State holds a normal Zig value;
borrowed slices/pointers retain their ordinary caller-owned lifetimes.
