# Native Files client

This independent Zig package exports `files_app` and compile probe
`bedrock-files-app`. Its model/view imports public AxisUI, with no kernel,
filesystem or browser dependency. The legacy protected entry adapter in
`src/main.zig` uses the host-supplied Bedrock64 runtime. The primary installed
desktop's `src/window_main.zig` builds `bedrock-window-files` and uses the native
`window_client.Hub` SDK to retain up to four PID-owned windows over one
authenticated display connection, map each window's pixel surface,
render AxisUI locally and submit immutable snapshots to compositor (ID104).
The earlier `src/compositor_main.zig` / `bedrock-desktop-files` entry remains
the single-window service-desktop regression. Its checked
provider in `src/checked_provider.zig` preserves Files identity (ID2) and its durable
private container. The initialization marker prevents reseeding the welcome
file. Files also attempts to add `/container/Desktop` on every launch before
checking that marker, so existing containers can gain the persistent folder
without recreating sample files. An existing Desktop item is preserved; an
unavailable, full or read-only provider does not abort this upgrade attempt.
Navigation and file operations still report checked provider failures. The host
supplies all authority through
[Provider callbacks](src/provider.zig); paths never select an app identity or
expose raw storage. Window ownership, title-bar controls and driver/service
integration belong to the host.

The window adapter retains one full-screen backing per bound window across viewport
changes, renders with screen-width stride, and uses the configured global
origin when sampling its private frozen wallpaper blur. It does not receive
another process's pixels or a raw framebuffer. The initial three frames prove
readiness; later rendering follows model revision or geometry changes. Closing
one window settles its exact snapshot lease, releases its producer and retires
its compositor cache while other windows remain usable under the same PID.
The shared endpoint closes and the process exits after its last window retires.
Init reaps that process and
starts a fresh Files PID when the shell requests reopening; minimize preserves
the existing process. The successful Nullify result marker follows ACK of its
new revision's current-epoch frame, with old in-flight/stale ACKs excluded.
The original command renderer remains available for legacy regression profiles.
The [primary desktop](../../../docs/window-desktop.md) runs init 101, compositor
104, shell 107, Files 2 and Notes 108 as five protected native processes with
six live surfaces initially. A detached window adds a producer/cache pair;
balanced ownership is `2 + 2 * bound_gui_windows`, without an extra process.
Files can resize, tile, move between four workspaces,
minimize or close independently of Notes; focused input and caption controls
belong to the compositor. The Files chip and Super+E restore or request a fresh
Files generation, while the Notes chip and Super+N select the other GUI client.

The primary window has a dark 32-pixel title bar, RGB(20,21,26), with native
folder tabs from the left and service-owned minimize/maximize/close controls
on the right. There is no visible Files caption. The tabs-only accessory is
x8, y4, width `client_width-154`, height24; it never overlaps the controls.
The 46×32 controls fill the caption height and meet the right edge; Close has
a red hover fill, deeper red pressed fill and white X, while the other controls
use neutral fills. Floating windows use 8-pixel outer corners; maximized,
fullscreen and tiled frames are square. The editable path lives in the
navigation row below the title bar: x128, y36, height32, with width
`client_width-128-(client_width>=640 ? 116 : 64)`. Click the path or press Ctrl+L
to select it. Ctrl+A selects all; arrows, Shift+arrows,
Home/End, Backspace/Delete and typing edit the bounded ASCII path. Enter opens
the location and Escape restores the current location. Long paths scroll by
whole proportional glyphs to keep the caret visible. Only canonical locations
within Files' private `/container` can be entered; redundant/trailing slashes
are normalized, while traversal and other namespaces are rejected. A missing
folder, file location or provider denial preserves the current listing and
history and shows an error in the status row.

The default body is one file list with a Places sidebar, a navigation row and
a small status row. The navigation row normally shows Back/Forward/Up, the
editable path, Split when wide enough, and More. Alt+F/E/V temporarily opens
the native File/Edit/View menus over that row; closing the menu restores the
navigation controls. Right-click and More provide the usual context commands.
Retained profiles keep their original breadcrumb row and navigation buttons.
Split toggles a second folder list, and the path follows the focused
pane, displayed relative to its private home, including `~/Desktop`,
`~/Documents` and `~/Downloads`.
Both `~`/`~/...` and `/container/...` input resolve to that same provider root.
Native
folder/document/home icons, preserved filename case and a size column use
AxisUI's shared font metrics and clipped icon renderer.

Each window supports up to eight real navigation tabs through `TabStore` in
`src/tabs.zig`. A tab retains independent folder paths, eight-location history
per pane, split state, focused pane, selection and scroll position. The
clipboard is shared by the Files process's tabs and windows. Switching relists through the
checked provider and rematches selection by name and kind, so a stale listing
is never shown under a different path. Missing folders and permission/read-only
failures use the model's normal friendly status errors. Switching cancels old
gestures, pending path/name edits and copied previews without writing files.

Click a tab to select it, its X or middle-click to close it, and + to open
a tab in the focused folder. Ctrl+T adds, Ctrl+W closes, Ctrl+Tab selects the
next tab and Ctrl+Shift+Tab the previous one. Closing the active tab selects a
neighbor; closing the last tab requests ordinary window closure. Stable IDs
keep pending gestures attached to their original tabs. Narrow accessories
keep the active close and + targets reachable; wheel navigation reaches all
tabs, with additional overflow arrows when space permits. `ui.tabs` owns
native drawing and picking; `TabStore` owns the bounded navigation snapshots.
Both use caller-owned storage without allocation. Keep the store beside the
model in permanent application storage, rather than on a small user stack.

Drag a tab across a neighbor's midpoint to reorder it. After a six-pixel
movement threshold, the native widget paints a lifted tab and insertion marker
inside the strip while keeping capture attached to its stable ID. A vertical
release more than 16 pixels outside the strip requests tear-off into a real
window. Escape, canceled/hidden geometry and a removed source cancel the
gesture; an X crossed during a drag cannot close it. Tearing the only tab moves
its existing window instead.

Tear-off uses a caller-owned `TabTransfer` transaction: the source record stays
available until the destination has a valid session/producer, imports the
navigation record and presents a visible current-epoch frame acknowledged by
the compositor. Only then does `commitExport` remove the source record. A
rejected allocation, provider/import failure, timeout or canceled/closed window
keeps the source and retires the incomplete destination. Each of the four
contexts owns its Model, TabStore, menu/tab state and input captures. Hub
messages carry the selected u16 WindowID through the same authenticated Files
connection; IDs are monotonic and never reused there. No new process, container
identity or filesystem authority is created by a detached window.

The primary app menus use public `ui.menu` definitions, command IDs and
caller-owned state. File creates folders/files, opens selected entries,
refreshes or closes the window; Edit reuses the model's checked clipboard,
rename and deletion actions. `Nullify...` opens the existing context menu for
an explicit second activation, preserving its matched press/release guard.
View handles history, parent navigation and split mode. Availability follows
the current provider, selection and viewport; split state has a smooth
checkmark. Alt+F/E/V activates a menu, then arrows, Enter and Escape navigate.
The app owns these menus independently of the title and system menu bars. AxisUI's
`ui.menu.Layout.initBar` and `ui.menu.BarOptions` configure its bounds and
padding; `ui.menu.Theme` configures the material or solid background, separator
and foreground colors. Menu configuration does not grant control of the trusted
caption buttons or additional sandbox authority.

While open, File/Edit/View covers the full navigation row at y32, height40;
its label area spans x12 through `client_width-120` at y40, height28.
Its background uses Files' navigation material; the darker solid strip is the
title bar containing Files and its tabs. Split/More retain their right-side
positions. During filename editing
the old Save/Cancel/name toolbar replaces these menus. Popups use whole rows
inside the client viewport, with scrolling at minimum window sizes; outside
press/release pairs dismiss without activating content beneath them. Configure,
focus/workspace status changes and redraw cancellation clear obsolete gestures.
Legacy context popups retain their existing input controller and paint above
the app menu bar via `renderWindowMenuWithWorkspace`; that overlay is clipped
below the service-owned 32-pixel caption.

`Model.init(provider,left_directory,right_directory)!void` initializes caller
storage in place. `dispatch(event,width,height)!void` routes native events;
provider errors appear in the status row. `action(Action)` and `shortcut(Shortcut)`
expose controls to hosts. `renderWithWorkspace(surface,workspace,model)!void`
renders body bounds down to 316×204 pixels. The primary adapter uses
`dispatchWindow(event,width,height,path_rect)` and
`renderWindowWithWorkspace(surface,workspace,model,path_rect)` with
`WindowGeometry.navigationPath(width)` for the primary app. The path geometry
also supports legacy caption accessories without straddling the caption edge.
Its full inner viewport is at least 316×236
pixels for a 320×240 floating frame, including a 32-pixel caption; body input
and drawing translate that offset once. The model/view package accepts plain
geometry and remains independent of compositor/runtime authority.
Below 640 pixels wide the layout uses one pane and disables Split; Split becomes
available again when the viewport widens. Retain `Model` and `Workspace` outside
small kernel stacks and serialize access. Views and callback data remain borrowed
only through synchronous calls. Command surfaces submit drawing without a
framebuffer pointer; the receiver rechecks client bounds and rights.

Frosted materials shade a frozen backdrop rather than accumulating alpha over
the previous frame. The graphite client tint uses opacity 100/255; sidebar,
navigation and status materials use 130, 112 and 96/255. Text, selected rows,
errors and pressed/hovered controls remain solid. Native callers attach their
immutable AxisUI `Backdrop` with `Surface.setBackdrop`; protected clients submit
material commands through the optional `CommandSink.materialRect` callback.
The receiver owns the wallpaper blur cache and clips requests to the window.
An absent backdrop/material callback uses a solid tint fallback. Files never
samples scanout or obtains another application's content.

Each folder view copies at most 32 entries, with 96-byte ASCII names and a
256-byte canonical absolute path. A larger listing shows “first 32 entries.”
Providers may impose tighter bounds. Duplicate/malformed names or nonprogressing
cursors fail before replacing the previous listing. Enumeration cursors are
valid for one listing; mutations refresh the views. Listing order is supplied
by the provider.

Select with the pointer or arrow keys. Enter, Open or a host-tagged unmoved
double-click opens a directory/file. A read callback provides a copied read-only
preview of the first 512 bytes; unsupported bytes become `?`. Escape or Up closes
it. A drag never opens an item. Home/Documents/Downloads/Desktop are real sidebar
navigation controls and drop targets. Desktop resolves to the persistent
`/container/Desktop` in Files' own private namespace. Drag onto a sidebar folder, a directory
row or the other split view to move once on valid release. Ctrl held at drag
start or drop selects copy; releasing it early preserves that drag's copy intent.
Outside drops, same-folder empty-space drops and simple clicks do not mutate files.

Copy/Cut retain a copied source path; Paste uses the current active folder.
Ctrl+C/X/V are equivalent. Providers recheck authority at Paste. Failure keeps
the clipboard for explicit user action; successful Cut/Paste clears it.
The primary window exposes mutations through its File/Edit menus and the native
right-click/More menus. Retained hosts use the right-click/More navigation row.
Right-click selects the targeted file/folder, or clears
selection on blank folder space. Open, Copy, Cut, Paste, Rename, Delete and Refresh
are contextual; blank-space menus offer New folder/New file. Missing callbacks,
read-only entries and inapplicable operations appear disabled. A matched left
press/release activates an enabled item once. Outside clicks and Escape dismiss;
keyboard navigation, refresh and geometry changes dismiss the old target too.
Tab switches folder focus in split view. Back/Forward
history retains eight copied locations per view; failed navigation leaves it
intact, and a successful new visit discards the forward branch. Alt+Left/Right/Up
navigate. F2 renames, F5 refreshes, and Delete performs ordinary removal.

The optional destructive **Nullify (zero + delete)** menu item is distinct
from Delete. It applies only to a writable file, requires a matched menu release,
and has no hotkey. The host supplies `Provider.nullify(context,path)!void` and
rechecks authority. The integrated Bedrock backend overwrites both logical
storage snapshots and deletes the file; this does not promise erasure of SSD
remapping, host backups or data another process already copied. Success visibly
reports “File nullified in Bedrock.” The model volatile-zeroes the full matching
preview/name/path buffers and matching clipboard storage; the renderer clears
its preview text scratch. Unrelated retained copies remain intact. A failure
reports “Nullify incomplete: storage may need recovery.” Deletion may have
committed before a later scrub/readback failure; Files never retries automatically.

Name editing supports insertion, cursor movement, Home/End, Backspace/Delete,
Enter and Escape. Captured mouse Create/Save and Cancel controls also work in
the breadcrumb row. Long names keep the text cursor visible. Unicode input is
explicitly unsupported in this first font/editor profile.

`Geometry.initMode(width,height,split)` shares draw/hit geometry; `init` selects
single view. The sole navigation row is 40 pixels, with 32-pixel
controls. The sidebar is 148 pixels wide, file rows 28 pixels, and status footer
24 pixels. `button(Action)`, `sidebar(Shortcut)`, `row`, `confirm` and `cancel`
expose rectangles to hosts/tests. Header `button` rectangles exist only for
Back/Forward/Up/Split/More; mutation actions have no hidden toolbar hit areas.
`MenuGeometry.init(width,height,kind,anchor)` clamps the 208-pixel popup to client
bounds. Its four-pixel padding surrounds rows up to 28 pixels tall; the row
height shrinks to fit every action in short viewports. `row_height`, `item`, `itemAt` and
`actionIndex` share render/hit geometry. `MenuKind` and `menuActions(kind)` expose
file/directory/background/More choices. `Model.menu` records the anchor and
hover/press state, and `menuEnabled(Action)` exposes availability hints. Existing
actions 0–12 remain stable; Nullify is 13 and More is 14. `colors` and `materials`
export the palette. The frosted popup uses a translated clipped command surface
on both native pixel and protected command backends. Its optional
`CommandSink.blendPixel` callback preserves antialiased text when forwarding
paint to the parent surface.

A host `redraw` event invalidates pixels while preserving history, selection,
scroll, clipboard, editing and preview. Code 1 cancels pointer gestures after
geometry/visibility changes and dismisses menus; code 0 preserves them for focus repaint. These
events and source directories grant no device or filesystem authority.

`Provider` contains opaque `context` and required `list(context,path,cursor)!?Entry`.
Entries copy name, kind, size and a read-only hint; every result must advance the
cursor, and null means EOF. Optional callbacks are open/read/write/create/mkdir/
copy/move/remove/nullify. Unavailable menu callbacks are disabled; unsupported
host/keyboard actions show a plain status message. Read/write take offsets
and slices; copy/move take complete source/destination paths. Validation failures
leave the namespace unchanged. An I/O failure may retain a complete old or new
committed snapshot; a poisoned provider requires fresh-mount recovery. The model
never retries a failed mutation automatically. Read-only hints do not replace
provider authorization, and collision policy belongs to the provider.

Run `zig build test check` with pinned Zig 0.17.0. Tests cover sidebar/split drag
behavior, clipboard/history, denied operations, keyboard/mouse editing,
double-click metadata, redraw preservation, path/enumeration bounds, previews
and pixel/command rendering at minimum/reference sizes, including narrow tiled
clients and short popup menus. Tab tests cover independent navigation/history,
stable IDs, selection rematching, shared clipboard, capture cancellation,
capacity/ID exhaustion, neighbor/last-tab closing and safe recovery after
partial or missing provider listings, reordering and transactional export/import
commit/rollback. AxisUI tests cover drag thresholds, stable-ID reorder/detach,
overflow and clipped previews; runtime tests cover scoped Hub sessions and
lease-safe retirement. Menu tests cover all
viewport edges, contextual/read-only availability, outside/release cancellation,
stale-target dismissal, Nullify exact-once/error behavior, visible scoped results
and full matching-cache clearing. Material tests compare
both backends against an immutable blurred backdrop, verify unchanged output on
repaint, and check solid control/error ink and guarded stride. Standard target and
optimization options plus `-Drelocatable=true` apply. Host storage/authority and
workflow acceptance is recorded separately. The primary
[`test-window-desktop` runner](../../../tools/test-window-desktop.py) checks
Files/Notes persistence, tiling, workspaces, resize, focus and independent app
recovery; see the [window desktop guide](../../../docs/window-desktop.md).
The historical [storage verification](../../../docs/storage-and-files-verification.md)
and [single-window service verification](../../../docs/service-desktop-verification.md)
retain their own regression scope. Emulator profiles do not qualify physical hardware.
