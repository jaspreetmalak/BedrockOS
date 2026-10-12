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
`cornerRadius(u16)`, `scale(u8)`, `flex(u16)` and `@"align"(Align)`.
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

Intrinsic layout uses compact 6-by-10 cells with original, case-preserving 5-by-7
ASCII glyph patterns at integer scale 1 through 16. Public `font` metrics are
`advance=6`, `line_height=10`, `glyph_width=5`, `glyph_height=7`, `offset_x=0`
and `offset_y=1`, all in unscaled pixels. `font.measure(bytes,scale)!font.Size`
returns checked width/height and is the renderer's measurement source. Chrome,
wrapping and cursor code should use these metrics instead of copying constants.
`font.glyph(byte)` returns seven rows of 5-bit patterns. Every printable ASCII
byte has a native pattern; unsupported bytes use a question mark. Newlines make
new rows, carriage returns are ignored, and tabs advance four cells. There is
no UTF-8 shaping or automatic wrapping yet.
Foreground and scale inherit; backgrounds, borders and corners are local.

`Icon` provides original 16-pixel `folder`, `document`, `home` and
`chevron_left/right/up/down` shapes. `drawIcon(surface,icon,point,color,scale)`
validates the surface and scale before painting and clips signed placement at
every edge. It uses coalesced row runs for both pixel and command backends.
The `icons` module also exposes `size` and `pattern(icon)` for native clients
that need their own placement. Direct icon drawing does not inherit a View's
rounded ancestor clip; callers place it within owned client bounds. No external
font or image asset is required.

A frame sets outer width/height, including padding. Padding reduces content
space. Stack gaps separate direct children. Flexible children receive a
weighted share of space left after intrinsic sizes and gaps; a fixed frame
on that axis takes precedence over flex. `Spacer` has zero intrinsic size and
default weight 1. Stack alignment controls the cross axis; overlay alignment
controls both axes. Text alignment positions its glyph block within its frame.
Stretch fills the available cross axis for unframed views.
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
