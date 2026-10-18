# Native glass appearance

Bedrock's primary native desktop uses a continuous charcoal wallpaper with broad
rose and slate-blue light fields. Floating windows have smooth 8-pixel corners,
a soft offset shadow and a one-pixel translucent rim. The modern caption has a
solid dark background, RGB `(20,21,26)`, rather than a frosted material. It keeps
the normal app name/accessory layout or a tabs-only layout, with trusted outline window
controls right. The three controls are 46 pixels wide and use the full 32-pixel
caption height, ending at the right edge. Their 16-pixel icons are centered with
15-pixel horizontal and 8-pixel vertical insets. Minimize and Maximize/Restore
have transparent resting backgrounds and neutral rectangular hover/press
fills. Close gains a red hover fill, deeper red pressed fill and white X.

Files and Notes share a quiet graphite/lilac palette. Fields, buttons, selected
rows and menus use antialiased corners; navigation bands and borders have less
contrast. Files' client, navigation and sidebar material opacity is respectively
100, 112 and 130 out of 255. Notes' client and editor material opacity is 100 and
112. Their broad wallpaper colors remain visible through the panes. Text and
icons retain full foreground contrast. Maximized, tiled and fullscreen frames
have square corners and fit their work areas without floating shadows.

App menus sit below the trusted caption in a separate background band. Apps can
configure this band's color and spacing through AxisUI. These menus remain
ordinary client UI and do not gain the service's window-control authority.

Files puts native `AxisUI.tabs` at the left of its caption, with no visible
Files title. Up to eight tabs per window and four windows keep independent
folder navigation, selection and scroll inside the same protected app process.
The + button sits beside the last visible tab; overflow arrows keep it anchored
at the strip's right edge. The editable path is in the navigation row below the
caption, leaving the dark tab strip separate from wallpaper-based glass panes.
Dragging a tab shows a lifted native tab and insertion marker within that
strip. Crossing a neighbor reorders by stable ID; a vertical release outside
the strip requests a real separate window. The source remains intact until
that destination presents an acknowledged frame. Escape and canceled captures
stop an unfinished gesture. A single tab moves its existing window.

## AxisUI primitives

The public framework exposes integer-only `Surface.roundedRect`,
`roundedMaterialRect` and `roundedBorder` helpers. A declarative view opts into
antialiased ancestor clipping with `.cornerRadius(...).smoothCorners()`.
`materials.roundedCoverage` and `roundedContains` share relative, half-open
geometry, clamp the radius and cover edge pixels with 4×4 subpixel samples.
Ordinary tint/opacity materials preserve their existing representation.

Pixel surfaces blend coverage into their existing pixels. Command surfaces can
forward it through the optional `blendPixel` and `materialPixel` callbacks;
receivers choose their own authorized backdrop. Missing callbacks retain bounded
compatibility fallbacks. Translucent edges require repainting the underlying
base each frame. Files repaints its path field's navigation base before text;
its caption tabs use the solid title background.
See the [AxisUI API](../frameworks/public/AxisUI/README.md).

## Ownership and composition

Blur uses the existing 8-pixel downsample and 24-pixel separable wallpaper cache.
Each renderer builds it from the same deterministic procedural wallpaper.
Notes owns two 16,000-pixel scratch arrays, adding 128,000 bytes of private static
storage within its existing image allowance. Apps do not receive another app's
pixels or the composed desktop as a backdrop. Wallpaper glass follows a window's
global position when it moves, resizes or changes mode.

The service retains its checked viewport blit and protected caption region.
It saves only the four small corner areas of its own scene, paints permitted
client pixels, then applies the shared rounded coverage. Opaque client pixels
cannot overwrite the rounded silhouette. This snapshot occupies about 1 KiB of
service-owned static scratch, avoiding large copies on its guarded 16 KiB stack.
The shadow visits outside strips and corner rows with a quadratic integer
falloff; painting requires no heap allocation or additional framebuffer.

The shared caption geometry drives both painting and hit testing; only the
chosen accessory is delegated to an opted-in client. Normal-layout bounds are
`(104,4,inner_width-250,24)`, or 66 pixels wide at the minimum 316-pixel inner
width. The title remains 84 pixels wide, and the three controls start 138, 92
and 46 pixels before the right edge. Files' alternate tabs-only accessory is
`(8,4,inner_width-154,24)`, 162 pixels wide at the minimum inner width, and
suppresses the title label. The protected controls retain their normal bounds.
Files uses this accessory for tabs
and places its path at `(128,36,inner_width-128-trailing,32)`, with 116 trailing
pixels at widths of at least 640 and 64 below that. The body offset remains 32;
apps may use another widget in either accessory. Files multiplexes four
WindowID-scoped sessions through one authenticated connection, with exact
per-window leases and independently retired producer/cache pairs. The service
allocates viewport caches lazily; balanced live surfaces are
`2 + 2 * bound_gui_windows`, including its scene and the shell producer. Tabs,
glass and extra windows do not grant additional container or window-control
authority. The shell keeps its
36-pixel bar and launch/workspace targets. All rendering remains native Zig.
