# Bedrock desktop direction

Bedrock combines a compact, Hyprland-inspired dark pastel theme with familiar
file-manager navigation and native window controls. The inspiration comes from
[Hyprland's official site](https://hypr.land/) and
[project repository](https://github.com/hyprwm/Hyprland). Bedrock builds its own
kernel, application model and native Zig UI; it promises no Hyprland, Wayland,
Linux or external binary/API compatibility.

Normal UEFI selects the [native window desktop](window-desktop.md): installed
init 101 starts compositor 104, shell 107, Files 2 and Notes 108 as five protected
processes. Files and Notes have independent windows and private containers.
The [menu framework](system-menus.md) gives each window its own app menus, with
a separate trusted system bar for local time and a frosted Control Center.
The [glass revision](glass-desktop.md) uses softer floating silhouettes and
lighter wallpaper-based materials throughout the native desktop.
The preceding [native UI revision](native-ui-verification.md) passed its Debug/ReleaseSafe
matrix on all three QEMU references, including original Axis Sans, centered path
editing and service-owned right-side controls. The
[preceding window record](window-desktop-verification.md) remains archived. The earlier
[single-window service desktop](service-desktop.md),
[fixed protected display demonstration](protected-display.md) with clients
105/106, and kernel-hosted Files workflow remain regression profiles.

## Appearance and interaction

The desktop keeps its procedural charcoal, rose and blue wallpaper, 36-pixel
Files/Notes launch bar, four workspace indicators, antialiased 8-pixel floating
corners, a thin translucent rim and a soft offset shadow. Rounded launch pills
and small active markers replace segmented bar blocks. A compact 32-pixel native header offers a normal app-title/accessory layout
or a tabs-only layout, with neutral minimize/maximize/close controls
right. The 46×32 controls fill the caption height and meet the right edge.
Minimize and Maximize/Restore reveal neutral rectangular hover/press fills;
Close uses a red hover fill, deeper pressed red and white X. Maximized,
fullscreen and tiled frames use square corners without floating shadows.
The darker RGB(20,21,26) strip is the title bar. Files uses its tabs-only
accessory from the left edge, with no visible Files caption and a
lighter RGB(39,43,54) active tab. AxisUI lets apps configure tab colors and
their own menu contents, materials and placement independently of the trusted
window controls and system bar.
Native AxisUI frosted materials sample an immutable blurred wallpaper
cache; lower tint opacity lets the muted wallpaper colors show through while
text, icons and controls remain crisp. The shell owns wallpaper and bar
views, while the compositor draws window chrome and cursor. No HTML is used.

Files opens one list with Places and a 40-pixel navigation row containing
Back/Forward/Up, the editable path, Split/More. The path is below the caption
at x128, y36, height32; its width reserves 116 trailing pixels at widths of
640 or more, and 64 pixels otherwise. Click the location or
press Ctrl+L to edit it, then Enter to navigate or Escape to restore the current
location. `~/Desktop`, `~/Documents`, `~/Downloads` and canonical private `/container/...`
paths resolve within Files' own container. Invalid, missing or denied locations
preserve the current listing and history and show an error. Mutations appear in
native item/background context menus and More. Places provides Home, Documents,
Downloads and Desktop; each pane
keeps eight history locations. Optional Split adds a second pane. Copy/Cut/Paste,
create/mkdir, rename/delete, drag move, Ctrl-drag copy and a copied read-only text
preview remain available through checked file operations. At narrower widths,
Files retains Places/More and one pane; Split becomes available at 640 pixels.
Its body supports client areas down to 316×204 pixels.

Files supports four windows in its single protected process and connection,
with eight independent folder tabs in each. Its title accessory at x8, y4,
width `client_width-154`, height24 holds the public AxisUI tab widget. Tabs retain
their own folder paths, history, pane split/focus, selection and scroll, while
sharing the Files process's clipboard. Switching relists through the checked provider
and cancels stale gestures and previews. Use + or Ctrl+T to add, click to
select, X/middle-click or Ctrl+W to close, and Ctrl+Tab/Ctrl+Shift+Tab to cycle.
The wheel reaches hidden tabs at narrow widths; overflow arrows appear when
space permits. Closing the active tab selects a neighbor; closing the last
tab closes that window; the process exits after its final window closes.
Dragging across neighboring tab midpoints reorders by stable ID with a native
lifted-tab preview and insertion marker. A vertical release outside the strip
tears the tab into a real, independently focused and movable window. The source
keeps the record until the destination presents an acknowledged frame; failure
or cancellation leaves it in place. Tearing the only tab moves its existing
window. Escape or geometry/hide cancellation stops an unfinished drag.
File/Edit/View menus temporarily overlay the navigation
row when opened with Alt+F/E/V. More and right-click retain the normal file
commands. The tab widget allocates no storage; the app owns its bounded
navigation snapshots and provider permissions.

The desktop uses Bedrock's original proportional
[Axis Sans](../frameworks/public/AxisUI/AXIS_SANS.md) typeface. A native grayscale
coverage atlas smooths text at UI scale1, with a 14×20 base cell, 15-pixel
baseline and 12-pixel cap height. Measurement and painting use the same glyph
advances and 20-pixel line height. Larger integer scales evaluate round-stroke
coverage from compact fixed-point vectors flattened from the original curves,
with 8×8 subpixel samples at partial edges. Text never enlarges the base bitmap;
tiny sizes still have the physical display's pixel-density limit. No Apple or other
external font assets are imported. The current face covers 95 printable ASCII
glyphs and substitutes `?` for unsupported bytes; Unicode shaping remains
future work. Notes centers these glyphs within fixed 14-pixel editor cells.

Context menus select their target row, disable unavailable/read-only actions,
and require matching left press/release. Escape, outside clicks, navigation,
refresh and geometry updates dismiss stale targets. Create/Save/Cancel and
Enter/Escape operate name editing. Double-click, Enter or Open previews the first
512 bytes; Back/Escape closes it. The current path/name editors accept ASCII.
Errors are visible and do not silently replace destinations.

The separate red **Nullify (zero + delete)** item is file-only. Its checked
syscall overwrites, flushes and reads back both complete logical storage banks
before removing the namespace entry. Matching preview/clipboard caches clear
after success. SSD remapping, backups and independent copies are outside that
logical-bank contract; see [context menus and Nullify](context-menus-and-nullify.md).

Caption dragging moves a floating window; border and corner dragging resize it.
Close, minimize and maximize/restore use the service-owned controls. F11 toggles
fullscreen, Escape exits it and Alt+F4 closes the focused client. Fullscreen
retains the compact caption and its three controls. Restoring a retained window
preserves its saved floating geometry or preceding mode; a new process requests
its initial frame through the native SDK.

Minimize retains the same process, surface and model state but configures a
hidden viewport. The matching launch chip, Super+E for Files or Super+N for Notes
restores it. Close retires the selected Files window while its other windows
continue under the same PID. The final window closes that app; a later launch
starts a new PID against its persisted private data. Geometry changes rotate the viewport epoch, discard old queued
coordinates and request a native redraw. Input follows the focused app, with
client pointer capture retaining an outside release. Window controls consume
their own press/release sequences. The optional centered accessory routes input
to its client and is excluded from title dragging; the compositor copies client
caption pixels only inside that reserved rectangle.

Four workspaces retain independent tiling settings. Super+1 through Super+4
switch workspaces, Super+Shift+1 through Super+Shift+4 move the focused window,
Super+T toggles equal-column tiling and Super+Tab cycles visible focus. The
current catalogue supports two GUI apps: four Files windows and one Notes
window, across five processes including init, shell and the display service. General
GUI installation, automatic view bindings and GPU rendering remain future work.

## Native UI and source ownership

`frameworks/public/AxisUI/` provides reusable app-facing views, stacks, text,
layout/style modifiers, native tab/menu widgets, software drawing, events, explicit state and bounded
queues/hit tests. Pixel surfaces borrow caller-owned storage with explicit
dimensions, stride and color masks. Command surfaces route clipped drawing to
a supplied sink; the legacy Files host retains that adapter. Installed Files,
Notes and shell render directly to their own checked logical RGB pixel surfaces.

Text and child-view slices remain borrowed through synchronous rendering.
`AxisUI.renderWithWorkspace(surface, workspace, view)` uses caller-owned
scratch without allocation. Native desktop programs keep their large layout and
blur scratch in private BSS. Framework code does not own app views, surfaces,
device access or process lifetime.

| Component | Current responsibility |
| --- | --- |
| `userspace/apps/init/` | Installed launch authority, service progress and independent GUI generation supervision |
| `userspace/apps/shell/` | Native wallpaper, theme, launch bar and authenticated Files/Notes launch requests |
| `userspace/apps/files/` | Native Files model, pixel adapter and checked app-2 file operations |
| `userspace/apps/notes/` | Native bounded ASCII editor and checked private app-108 load/Save |
| `userspace/services/display-server/` | Retained composition, viewport epochs, focus, input and window chrome/cursor |
| `userspace/services/window-server/` | Portable window/header geometry, controls, mode transitions and capture policy |
| `userspace/runtime/` | Bedrock64 records, syscall wrappers and native desktop client/wire adapters |
| Kernel display/resource brokers | Checked mappings, lifetime accounting, device input and final scanout |

Public/private frameworks describe API support and distribution, not sandbox
authority. `frameworks/private/` holds reusable internal mechanisms such as
NetworkCore; application themes and views remain under userspace. Additional
display/service frameworks should follow concrete object and IPC needs.
Standalone input, launcher/file-picker brokers and a general service manager
remain future work. Source paths need not mirror installed bundles.

## Retained surfaces and ownership

The compositor owns one full-screen scene and allocates GUI viewport caches
lazily, one per accepted window within six registry slots. Its shell-bar cache
is bounded private BSS. Incoming client snapshots use its RO/NX slot 0 only
during copying. Each bound window retains one full-screen producer backing and
paints its configured viewport at source 0 using full-screen row stride. This
bounded desktop supports 800×600 through 1280×800. Balanced surface ownership is
`2 + 2 * bound_gui_windows`: scene plus shell producer, then a producer/cache
pair per window. Initial Files+Notes uses six; one tear-off uses eight; four
Files windows plus Notes uses twelve without adding application processes.

Creation returns a process-local generational surface capability. Submission
revokes the producer's RW/NX mapping before authenticated IPC transfers a RO/NX
snapshot. The compositor copies only the configured extent to the matching cache
and releases its read mapping/grant. Current-frame ACKs follow composition and
checked final presentation. A stale frame still receives its exact ACK after
release, allowing the client to retire its old epoch and repaint.

One authenticated connection per app carries scoped u16 WindowIDs in the upper
message flags. Files' Hub routes configure/input/ACK/close independently to four
caller-owned session slots, with monotonic IDs never reused within the
connection. Controls resolve through the authenticated app/PID and selected
WindowID; they cannot target another app or gain authority from a copied ID.
Configured size/origin and frame epoch are explicit. Old PIDs, duplicate sequences
and obsolete layouts cannot update a visible cache. Minimize sends a 0×0 hidden
viewport; restore requests a new visible epoch without allocating a new client
surface. Closing hides the selected window; retirement releases its producer
after leases settle, then its compositor cache. Snapshot references
keep delivered pixels alive through owner retirement until the service releases
them; backing and private mapping tables return after their final reference.

Each peer has bounded pending ACK/configuration/close state and a 32-event input
queue. Pointer moves coalesce; overflow sends explicit gesture cancellation
before the latest event. A nonreading peer cannot block the compositor or
the other peer. Init receives atomic heartbeat records containing peer
PIDs, launch/close counters and frame/presentation progress. Only the trusted
shell can request a launch; only init chooses and starts installed identities.

The compositor builds wallpaper-only blur before bar, app or cursor pixels.
Frost samples this immutable cache rather than capturing another application's
content. Files builds its own public-wallpaper backdrop and samples it using its
configured screen origin. Damage tracking, animation
and GPU support remain separate rendering milestones.

The logical surface format is packed RGB. The kernel validates scanout bounds,
framebuffer channel masks, stride and byte coverage for final presentation.
Apps receive neither raw scanout authority nor another app's writable pixels.

## Files and sandbox authority

The [application model](application-model.md) keeps native installed bundles,
private containers, immutable content and explicitly granted objects. Desktop
appearance, window placement or linking AxisUI cannot grant extra filesystem,
device, network or launch permissions.

Files retains trusted app identity 2 and its `/container/Desktop`,
`/container/Documents` and `/container/Downloads` data. Desktop is a real
persistent directory and a navigation/drop target. Launch attempts to add it
to existing Files containers without recreating sample files or replacing an
existing item of the same name; provider errors remain subject to the normal
checked navigation and mutation paths.
Notes stores `/container/notes.txt` in its separate
app-108 container; the same path root does not expose that data to Files.
Shell is independently sandboxed as 107; the display
service is 104. The compiled catalogue selects permissions and bounded ELF memory
limits. An app cannot choose another app ID, gain rights through copied handles
or opt out of its sandbox. Files has no direct raw-input or display-present
authority; it submits its own pixels and receives app-local events.

Modern VirtIO block/input devices supply the reference QEMU paths. The bounded
durable backend keeps 32 nodes and 4096 bytes per mutable file in a dedicated
two-bank 4 MiB image. Bundles remain immutable overlays. See the
[persistent filesystem contract](persistent-filesystem.md) for commit ordering
and recovery after uncertain I/O.

## Profiles and acceptance

`zig build desktop`, `zig build windows` and architecture-specific
`desktop-<arch>` targets package the five installed programs. Normal
`run-uefi-<arch>` and `run-desktop-<arch>` select this desktop.
`test-window-desktop` exercises independent Files/Notes input, window controls,
workspaces, tiling, persistence, fault recovery and teardown; F12 finishes its
dedicated acceptance host while F11 remains actual fullscreen. See
[native window desktop](window-desktop.md) for SDK and current limits.

The preceding single-window [integrated gate](service-desktop-verification.md)
passed on all three named UEFI QEMU profiles in Debug and ReleaseSafe: 24 boots verify actual rendered
pixels, focused input, persistent mutations, close/relaunch with stable
shell/server PIDs, capability denials, resource retirement and fresh-boot data
recovery. Native tests additionally cover stale-frame and queue behavior.
No physical machine has been qualified by these emulator checks.

The earlier `display`/`test-display` profile retains fixed 320×240 clients105/106
and A fault/relaunch while B and the service survive. Its
[verification record](protected-display-verification.md) applies to that demo.
The legacy `test-desktop` regression retains the kernel-hosted Files adapter;
[storage/input verification](storage-and-files-verification.md),
[compact Files UI verification](files-ui-verification.md) and the
[menu/Nullify record](context-menus-and-nullify.md) describe its completed gates.
Those historical results do not substitute for the primary native window gate,
or for a fresh integrated run of the typography and compact-header revision.

The boot checks still precede graphical startup. A broader GUI catalogue,
service recovery and general app installation require their own future
workloads. See the [roadmap](roadmap.md) for the surrounding milestones.
