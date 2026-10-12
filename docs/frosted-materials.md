# Native frosted materials

AxisUI provides reusable frosted backgrounds through `View.material` and
`Surface.materialRect`. Bedrock applies them to the Files content, sidebar,
navigation, footer, window caption and desktop launch bar. The wallpaper uses
muted rose and blue shapes over charcoal; material tints keep file names and
controls legible.

## Framework contract

```zig
const material: ui.Material = .{
    .tint = ui.Color.rgb(26, 27, 35),
    .opacity = 178,
};
const view = ui.VStack(&children).material(material);

const count = try ui.Backdrop.requiredLen(source.width, source.height);
// Caller supplies independent color and scratch buffers of at least count u32s.
var backdrop = try ui.Backdrop.build(&source, colors, scratch);
try destination.setBackdrop(&backdrop, .{ .x = 0, .y = 0 });
try ui.renderWithWorkspace(&destination, &workspace, view);
```

The filter averages eight-by-eight source tiles and runs separable integer box
passes with a three-sample radius, approximately 24 source pixels. Bilinear
sampling expands the cache into the destination; opacity mixes the backdrop
with the requested tint. There is no GPU, floating point or framework heap
allocation. Blur storage is caller-owned and retained while any surface borrows
the backdrop. Origin translates local surface coordinates into wallpaper space.

`CommandSink.materialRect` lets a protected client submit the same material
description without receiving pixel storage. Missing backdrop or receiver
support falls back to the solid tint. View material painting retains ancestor
clipping and rounded boundaries; crisp backgrounds and borders remain available
for selections and controls.

## Desktop ownership

The current trusted display host paints wallpaper alone, allocates two cache
buffers through the kernel heap, builds the backdrop once, and then paints the
bar and window. The cache never contains app text, window controls or the cursor.
Material redraws sample that immutable cache rather than previous scanout, so
repeated painting cannot compound blur or transparency. Moving and restoring a
window uses its new screen coordinates against the same backdrop.

The cache belongs to the desktop lifetime and predates the Files allocation
baseline. Closing Files releases its existing process resources while retaining
the desktop cache. A desktop error path detaches and releases the cache after
retiring the client. A future wallpaper or resolution change must rebuild the
cache before publishing it to surfaces.

Protected Files uses Bedrock64 `ui_material` (`0x154`) with a copied 32-byte
`DrawMaterial`. The host rejects nonzero reserved values, high tint bits and
opacity above 255, validates readable app memory, and clips unsigned dimensions
to its current client. Old-size requests are discarded after resize, alongside
ordinary drawing. This grants no framebuffer readback or other-window access.
The client drains at most 32 host-routed events through nonblocking `ui_pending`
between blocking waits and renders once for each batch. It preserves individual
model transitions without repainting a full material for every queued character.

The current frost samples wallpaper only. Blurring other independent app
surfaces requires the future compositor and its own surface authority.

## Verification

All six QEMU workflows passed on x86-64, ARM64 and RV64 in Debug and
ReleaseSafe. Each boots twice, minimizes/restores the window and performs two
close/relaunch cycles: twelve normal boots, twenty-four protected client starts
and twelve verified resource reclamations. Saved files recover after abrupt
termination and a fresh boot of the same disk.

For each workflow, the test independently reconstructs the box blur and tint
from an unobscured wallpaper screenshot. Six blank-list samples before and
after minimize/restore match exactly: twelve distinct pixel comparisons per
workflow. Native material syscall tests reject invalid pointers, reserved
arguments/fields, high tint bits and opacity above 255. Window controls,
clipboard, navigation, drag-and-drop, name editing and file operations remain
covered. Input checks await visible editing state, completed typed names and
the protected client's footer before mixing devices or inspecting restored
content; fixed delays do not substitute for those visual barriers.

AxisUI has 30 native tests, Files 25, shell 6 and window policy 9 per mode.
Framework tests cover actual two-axis filtering, masked RGB, source immutability,
buffer alias rejection, guarded clipping, repeated paint, fallback and command
parity. All workspace native suites, three-target compile checks and three UEFI
smokes passed in each mode; cached unchanged tests are included. Zig formatting
passed across 136 source/manifests. The default installed images were rebuilt.

Reproduce from the workspace root with the pinned compiler:

```text
zig build test check test-uefi test-desktop -j2 --summary all
zig build test check test-uefi test-desktop -Doptimize=ReleaseSafe -j2 --summary all
zig build -j2 --summary all
```

The ignored aggregate receipt `.zig-cache/frosted-verification.json` records
logs, workflow results, source hashes and installed Debug artifact hashes.
Native PPM/PNG captures and per-architecture receipts are under
`zig-out/desktop-tests/{debug,safe}/`. These QEMU checks do not qualify physical
hardware or a compositor for independently protected app surfaces.

These are the historical frost/input-batching results. The subsequent
[context-menu and Nullify milestone](context-menus-and-nullify.md) uses the same
immutable-backdrop material path for a clipped native popup, removes the mutation
strip, and adds checked logical-file overwrite/delete. Its independent package,
aggregate and six QEMU workflows passed separately in Debug and ReleaseSafe.
That record also checks the completed Nullify result presentation and both
logical banks before fresh-boot absence; these preceding frost counts remain
historical.
