# Bedrock desktop shell

The native desktop background, compact bar and theme live here. The shell uses
the public [AxisUI framework](../../../frameworks/public/AxisUI/README.md) to
paint an original charcoal wallpaper with muted rose/blue curved layers,
diagonal accents and a 36-pixel material bar.
Cream mixed-case branding, a muted-rose Files launch chip and an actual
caller-supplied architecture label keep the desktop compact. The backdrop has
no decorative workspace buttons, simulated status devices or invented clock.

```zig
const Shell = @import("desktop_shell");
const AxisUI = Shell.axisui;

// Temporary kernel host: retained BSS scratch, used by one caller at a time.
var scratch: AxisUI.Workspace = undefined;

var surface = try AxisUI.Surface.init(pixels, width, height, stride, masks);
try Shell.renderWithWorkspace(&surface, &scratch, "ARM64");
```

Use the reexported `Shell.axisui` for the same module instance and `Surface`
type. `renderWithWorkspace` builds borrowed `View` arrays locally and immediately
calls AxisUI; no tree escapes its lifetime. The caller retains an
`AxisUI.Workspace`, initialized as `undefined`, in owned storage and serializes
its use. Kernel integration keeps scratch in BSS to preserve its guarded stack.
Production rendering requires no allocator. The convenience `render` allocates
scratch on the stack for host callers.

`launchRect(width,height)` returns the clipped actual Files launch target:
`x = 94..165` and `y = 0..35` on the reference sizes. The kernel host consumes
this rectangle for pointer dispatch; presentation alone does not launch apps.
`bar_height=36` and the theme `palette` are exported. Wallpaper rows use at most
15 native clipped spans, with integer shading and intermediate accent tones.
The renderer uses no allocation or image assets. View typography uses AxisUI's
shared 6-pixel advance and 10-pixel line
height, with no automatic upscale on a larger framebuffer.

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
`-Drelocatable=true` for the temporary firmware-loaded kernel host. Independent
`check` compiles the composition; `test` renders both 800x600 and 1280x800 into
bounded native buffers and checks caller-supplied architecture text. These steps
do not install into the root workspace's output directory.

The `userspace/apps/` location records this component's intended application role.
The shell still runs in the kernel display host after boot checks, supplying
the background and visual theme around a separately protected Files ELF.
Modern VirtIO keyboard/tablet input feeds one focused client window; the host
owns its title dragging and close/minimize/maximize/fullscreen controls. The working Files chip
provides a bounded launch/reopen target; workspace switching and a multiwindow
manager are not implied by the backdrop.
The eventual user-space desktop still needs a standalone compositor, installed
bundle launching and surface/input IPC. The storage/client extension's integrated
verification passed on all three UEFI references in Debug and ReleaseSafe; see
the [storage/Files record](../../../docs/storage-and-files-verification.md).
The compact visual revision has separate package layout/guard checks; its
integrated screenshots and input acceptance belong to the host verification.

AxisUI supplies reusable UI primitives. This package owns desktop-specific
views, themes and composition. Reusable internal service APIs will live in
private frameworks when those services exist. Mandatory app isolation depends
on kernel mechanisms and checked grants.
