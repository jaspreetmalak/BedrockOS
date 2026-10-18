# Native window desktop

The primary desktop runs installed init 101, display service 104, shell 107,
Files 2 and Notes 108 as five protected native processes. Files and Notes own
independent windows, pixel surfaces and private storage namespaces. Files can
retain four windows within its single process and display connection, with
eight navigation tabs per window; Notes retains one window. The shell
owns the wallpaper and launcher; the display service owns composition, window
geometry, focus, input routing, tiling and workspaces.

## Build and run

From the repository root:

```text
zig build desktop
zig build windows
zig build desktop-x86_64
zig build run-windows-x86_64 -Doptimize=ReleaseSafe
zig build test-window-desktop-x86_64
zig build test-window-desktop
```

Architecture suffixes are `x86_64`, `arm64` and `riscv64`. The `desktop` and
`windows` targets package the same native window profile. `uefi-<arch>`,
`uefi-image-<arch>` and `run-uefi-<arch>` select that primary profile. The
`service-desktop`/`test-service-desktop` targets retain the earlier protected
single-Files desktop. `legacy-uefi-<arch>` and `test-desktop` retain the
kernel-hosted regression.

The installed catalogue is [window-apps.json](../userspace/runtime/window-apps.json).
Its five applications are built as `bedrock-window-init`,
`bedrock-window-server`, `bedrock-window-shell`, `bedrock-window-files` and
`bedrock-window-notes`. Archive metadata must match the trusted kernel catalogue;
it does not assign permissions.

## Desktop controls

| Action | Control |
| --- | --- |
| Open, focus or restore Files | Files chip; Super+E; Super+Enter |
| Open, focus or restore Notes | Notes chip; Super+N |
| Switch workspace | Super+1 through Super+4; numbered bar indicators |
| Move focused window to another workspace | Super+Shift+1 through Super+Shift+4 |
| Toggle equal-column tiling in the active workspace | Super+T |
| Cycle visible windows | Super+Tab |
| Move a floating window | Drag its caption |
| Resize a floating window | Drag a border or corner |
| Close focused window | Right-side Close button; Alt+F4 |
| Minimize; maximize or restore | Right-side caption buttons |
| Enter or leave fullscreen | F11 |
| Leave fullscreen | Escape |
| Open a Files tab in the focused folder | Adjacent + button; Ctrl+T |
| Close a Files tab | Tab X; middle-click tab; Ctrl+W |
| Switch Files tabs | Click tab; Ctrl+Tab / Ctrl+Shift+Tab; wheel over tabs |
| Reorder Files tabs | Drag a tab across a neighboring tab's midpoint |
| Move a tab into its own window | Drag vertically outside the tab strip and release |

Each workspace retains its own tiling setting. Tiling arranges visible floating
windows in equal columns. Turning it off restores their saved floating frames.
Workspace changes hide the other clients through zero-size configurations and
cancel obsolete pointer gestures. Hidden clients keep their process and model.
The bar shows the active workspace and floating/tiled state.

The modern caption has an opaque charcoal background, RGB `(20,21,26)`.
The normal layout places the app name on the left and quiet outline
Minimize, Maximize/Restore and Close icons on the right. Each control spans the
full 32-pixel caption height and is 46 pixels wide, with no gap at the right
edge. Minimize and Maximize/Restore reveal neutral rectangular backgrounds on
hover and press; Close uses red, a deeper pressed red and a white X. The service
owns these controls, caption dragging and border resizing. Apps may opt into a
generic center accessory. Files instead opts into a tabs-only layout: tabs
start at the left, with no visible Files caption. Its editable
folder path sits in the navigation row below the caption. Click the path or
press Ctrl+L to edit, Enter to open a private folder, and Escape to cancel. Notes uses
the normal service-rendered caption. F11 and Escape provide fullscreen control.
The retained service-desktop and kernel-hosted profiles keep their earlier
caption layout.

Files supports eight independent tabs in each of four windows in one process. Each keeps
its folder paths, navigation histories, focused pane, selection and scroll;
the clipboard is shared by that Files process's tabs and windows. New tabs start in the focused folder with
a fresh history. Switching relists through the checked provider and cancels
unfinished edits, previews and captured gestures. Closing the last tab requests
window closure. The + button follows the last visible tab; when overflow arrows
are shown, it stays anchored at the strip's right edge. Hidden tabs remain
reachable through keyboard or wheel navigation. A six-pixel pointer movement
starts a tab drag. Crossing another tab's midpoint requests a reorder by
stable ID, with a lifted native tab and insertion marker clipped to the strip.
Vertical tear gestures do not reorder. Releasing more than 16 pixels above or
below the strip requests a real separate window. Escape, geometry/hide
cancellation and an obsolete source ID cancel the gesture. Tearing the only
tab in a window moves that existing window.

Tear-off is transactional. Files keeps the original navigation record until
the destination has a configured producer, imports the record and presents a
visible frame acknowledged in its current epoch. Only then does the source
commit removal. A rejected allocation, provider/import failure, cancellation,
window closure or timeout keeps the source record and closes the incomplete
destination. Each window has separate model, tab/menu state and captured input;
the shared checked provider and clipboard do not create new filesystem rights.

Floating windows use antialiased 8-pixel corners, a soft offset shadow and a
thin translucent rim. The compositor applies the silhouette after permitted
client pixels, so app surfaces cannot square off the corners. Maximized,
fullscreen and tiled frames use square corners and fit their work areas without
floating shadows.
Files and Notes use lighter wallpaper-based glass materials, rounded fields,
buttons, selections and menus. Notes builds its own immutable blur cache in
private storage. See [glass appearance](glass-desktop.md) for the rendering
contract and [verification](glass-ui-verification.md) for the earlier glass baseline.

Files and Notes own configurable File/Edit/View bars below their captions.
Files opens its menu band with Alt+F, Alt+E or Alt+V; its normal navigation row
contains the path and file controls.
These app menu strips have their own background and spacing, which apps can
customize through AxisUI; they are part of the client body rather than the
privileged title bar. The separate system bar places firmware-based time and Control Center on the
right. Both use the public AxisUI native menu primitives; developer configuration
and ownership are documented in [system menus](system-menus.md). Control Center
changes layout, workspaces and software dimming. `zig build test-system-menus`
checks the two menu layers, actual time, vector icons and scene changes on all
three QEMU references; architecture-specific suffixes are available.

Files supports body areas down to 316×204 pixels. Its integrated client viewport
includes a further 32-pixel header, so the minimum viewport is 316×236. Narrow
layouts retain Places and More, collapse Split while keeping its focused
location and editing target,
and fit every popup action into the available height. Split becomes available
again at 640 pixels of client width.

A normal Files close retires that window's producer and compositor cache;
the same process continues while another Files window exists. Closing its final
window exits the Files process. Notes still closes its single window and process.
Init waits for a new
launcher request before reopening it. A client fault triggers a fresh process
once the service has retired that generation's last snapshot. Files can close
while Notes remains usable, and a Notes fault leaves Files, shell and service
running.

## Notes

[Notes](../userspace/apps/notes/src/main.zig) provides a wrapped ASCII editor with
insertion, Backspace/Delete, arrow navigation, Home/End, Page Up/Page Down,
Ctrl+Home/Ctrl+End, pointer caret placement and wheel scrolling. Its native Save
button and Ctrl+S persist `/container/notes.txt`. The editor and file load/save
are bounded to 4096 bytes; individual I/O calls remain at most 256 bytes.
Saved text survives a process restart and reboot in Notes' private app-108
container. Files cannot read that container.

The acceptance profile exposes Ctrl+Shift+F5 in Notes to request an actual
architectural write to its read-only Startup page. Production Startup flags
leave this path disabled. The acceptance runner checks fault status 139 and
recovery through init; this shortcut is a test mechanism.

## Native window SDK

The app-facing SDK is [window_client.zig](../userspace/runtime/src/window_client.zig),
exported as `userspace_runtime.window_client`. A single-window client such as
Notes can open its normal session:

```zig
var session = rt.window_client.Session.openWindow(.{
    .title = "Notes",
    .preferred_width = 620,
    .preferred_height = 420,
});
session.awaitConfiguration();
```

Titles are nonempty printable ASCII with a maximum of 16 bytes. Preferred
frame dimensions must be nonzero and no larger than the active screen. The
service clamps accepted dimensions to its work area and minimum size. The
kernel rejects requests beyond screen bounds; the current SDK exits with
status 99 when a control send fails. The
client's configuration contains its viewport dimensions, screen stride, desktop
origin and configure epoch. It polls native input, configure, close and exact
frame acknowledgements through the same session.

`session.map()` returns its writable fullscreen logical RGB backing. Apps paint
the viewport from source origin zero with the configured screen stride, then
call `session.submit()`. Only one immutable frame is in flight. A new configure
preserves the earlier lease until its exact ACK arrives; the next frame uses the
new epoch. Hidden configurations retain that lease but do not permit painting.
A close notification stops new painting. A Hub-owned session waits for its
mapped view and exact outstanding frame to settle before individual retirement.

Applications may call `requestResize(width, height)`, `requestFocus()` and
`requestClose()`, plus `moveTo(x,y)` for a bounded requested screen position.
These controls carry no target PID, app identity or surface
handle. The kernel authenticates their sender; the service applies them to that
sender's selected WindowID. The shell uses `Session.connect()` and an authenticated launch
request to select Files or Notes. Its status messages update workspace, tiling
and focused-PID presentation.

`WindowOptions.header_content` defaults to `false`. Opting in includes the
32-pixel caption in the client viewport and delegates only its center accessory:

```zig
var session = rt.window_client.Session.openWindow(.{
    .title = "Files",
    .preferred_width = 640,
    .preferred_height = 420,
    .header_content = true,
});
session.awaitConfiguration();
if (session.headerLayout()) |header| {
    const center = header.accessory; // Client-local x, y, width and height.
    _ = center;
    // Paint the center widget and the body below row 32 with the screen stride.
}
```

`Session.headerLayout()` uses the shared native header geometry and returns
`null` for a hidden or non-opted-in viewport. Recompute it after configuration
changes. The title occupies `(12,0,84,32)`; the accessory is
`(104,4,inner_width-250,24)`, leaving eight pixels before Minimize. At the minimum
inner width of 316, the accessory is `(104,4,66,24)`. The three control rectangles
start at `inner_width-138`, `inner_width-92` and `inner_width-46`, at row zero,
with 46×32 bounds. Their 16-pixel icons sit at local `(15,8)` inside each control.
Pointer events enter the app through the accessory or body; the service keeps
the left title, right controls, remaining caption and resize edges. A captured
client release is delivered even outside those regions so an app can cancel
its gesture. The service copies client pixels in the first 32 rows only within
the accessory rectangle. The body still starts at row 32, and its desktop
origin remains available for wallpaper-derived materials.

`WindowOptions.header_tabs=true` selects the alternate tabs-only layout and
implies `header_content=true`. Its delegated rectangle is
`(8,4,inner_width-154,24)`; there is no visible app-title label. Files renders
`AxisUI.tabs` there. At the minimum 316-pixel width it is 162 pixels wide. The
three trusted controls and the eight-pixel gap before Minimize retain their
normal geometry. Both accessory layouts are widget-neutral and delegate no
filesystem or window-control authority. Files' separate path rectangle is
`(128,36,inner_width-128-trailing,32)`, with `trailing=116` at widths of at least
640 pixels and `64` below that. Moving the path into the navigation row adds no
new vertical strip: the client body still starts at row 32.

Files uses `rt.window_client.Hub` for several windows over one authenticated
connection. `Hub.connect()` opens that connection; `openWindow(options)!*Session`
allocates one of four caller-owned slots and assigns a monotonically increasing
u16 WindowID, starting at zero. IDs are never reused during that connection,
including rejected or retired requests. `poll()` returns `{window_id,event}`
and routes configure, input, rejection, close and exact ACK to the matching
session. It creates that window's producer after a valid visible configuration.
Call `session(id)` to find its retained state; do not poll individual sessions
on a shared connection. Late messages for a retired ID cannot target a new slot.

`Hub.retire(session)` requires a closing session with no writable mapping or
frame in flight. It closes the producer, sends per-window retirement and frees
only that slot. The compositor then retires that window's cache. `Hub.close()`
requires all slots retired and closes the shared connection; the caller decides
when to exit. Per-window focus, geometry, workspaces, minimize and Close are
independent despite a shared Files PID. Its launch chip restores/focuses the
most recent Files window, including a minimized one.

## Protocol and resource ownership

The shared [Bedrock64 ABI](../userspace/runtime/src/abi.zig) retains the 64-byte
`ServiceMessage`. The native window profile adds:

| Kind | Direction | Meaning |
| --- | --- | --- |
| 9 | GUI client to service | Create/update own window; preferred dimensions and 16-byte title |
| 10 | GUI client to service | Resize own window; desired dimensions |
| 11 | GUI client to service | Focus own window |
| 12 | GUI client to service | Request own window closure |
| 13 | Service to shell | Workspace index 0–3, tiled flag and focused PID |
| 14 | GUI client to service | Move own selected window to bounded signed screen coordinates |
| 15 | Service to GUI client | Reject selected window creation; bounded reason payload |
| 16 | GUI client to service | Retire own closing window after producer leases settle |

Frame, ACK, input, configure, close and launch retain kinds 1, 2, 5, 6, 7 and 8.
The shell sends launch kind 8 with target app ID 2 or 108; legacy value 1 selects
Files. Client controls have zero peer fields and surface. In the native window
profile, flags bits16..31 carry the sender-scoped u16 WindowID; bits0 and1 are
`header_content` and `header_tabs`, accepted only on create/configure.
`header_tabs` requires `header_content`. Configure echoes the selected window's
capabilities even when hidden. Controls, input, ACK, close and rejection carry
only the WindowID tag, with no low capability bits. The checked surface-create
record binds a producer to its owning WindowID; submitted frame tags come from
that binding rather than caller-supplied peer fields. The kernel permits
nonzero WindowIDs only for the Files native window connection and appropriate
message direction/kind. Notes, shell and retained profiles keep their original
zero-tag constraints. Unknown flag bits, foreign peers and malformed payloads
are rejected before routing.
Receive fills authenticated peer PID/app identity. Frames gain read authority
only through `surface_submit`, never ordinary service send.

One live display connection is allowed per client PID. Files may own four
producer surfaces, each bound to a distinct live WindowID; Notes and shell
retain one each. Foreign identities, forged status/control metadata and duplicate
connections are rejected at the kernel boundary. GUI clients cannot present
scanout, consume raw device input, open the display service, launch applications,
read another app's container or acquire network/Wi-Fi authority.

The compositor owns one fullscreen scene and allocates a viewport cache lazily
for each accepted GUI window, within its six-entry registry and checked surface
quota. Its shell-bar
cache is bounded private BSS. Each bound GUI window owns one producer and has
one compositor cache; shell owns its separate producer. Balanced surface count
is `2 + 2 * bound_gui_windows`: six for initial Files+Notes, eight after one
tear-off, and twelve for four Files windows plus Notes. Individual retirement
returns both producer and cache without restarting the shared process.
Pointer motion uses a private 6×18 save-under cache and submits only the old
and new cursor rectangles. Full scene changes invalidate that cache before
painting. Cursor submissions have their own scanout sequence; client frame
ACKs still wait for a completed full composition. The kernel checks rectangle
bounds, strides, ownership and display-service authority before any copy.
See [desktop performance](desktop-performance.md) for the measured scope.
Incoming client snapshots occupy the compositor's RO/NX mapping slot only
during copying; release revokes that alias before the client remaps writable.
The producer's RW alias is revoked before a snapshot is published.

The display bounds are 800×600 through 1280×800. Native installed code is limited
to 128 KiB RX, GUI/service/shell data to 512 KiB RW/NX, stack to 16 KiB and heap
to a fully mapped 32 KiB lease. Startup occupies its own RO/NX page. Kernel
quotas charge actual allocated pages and handles; teardown retires generations
before process slots, surfaces or connections are reused.

## Verification

Native unit coverage checks sender identity, reserved fields, bounded titles,
configure epochs, stale frames, exact ACKs, hidden viewports, generic peer slots,
focus/capture, resize gestures, workspace changes and tiled restoration. The
real Files/Notes clients probe duplicate connection rejection, forged foreign
focus, non-ASCII creation titles, nonzero resize payloads and forbidden client
status messages, alongside raw display/input, launch, storage and network denial.

The integrated runner is [test-window-desktop.py](../tools/test-window-desktop.py).
It drives the native desktop in QEMU, records serial logs and screenshots,
checks each client's lifetime and persistent state, and uses the dedicated
acceptance profile for deliberate Notes fault recovery and balanced teardown.
Its [evidence-gate unit tests](../tools/test-window-desktop-units.py) use
in-memory logs, pixels and checked filesystem banks. Run them with
`python tools/test-window-desktop-units.py`; they reject forged or retired PIDs,
wrong independent-close counts, delayed or missing CPU faults, stale configure
epochs, mixed profiles, hidden-window pixels and Boolean replacements for
numeric receipt evidence.
The [native UI verification report](native-ui-verification.md) records the earlier
Debug/ReleaseSafe baseline, saved evidence and qualification bounds. It does not
qualify the new caption-tab layout. Source-level
checks alone do not establish runtime acceptance.
The [preceding window record](window-desktop-verification.md) retains its original
sources, artifacts and earlier verification tools.

The [draggable-tab verification](tab-windows-verification.md) records passing
x86-64, ARM64 and RV64 QEMU checks for reordering, tear-off, retained history,
independent window controls and balanced retirement.

The initial catalogue supports two GUI applications, four Files windows and one
Notes window. Native widget and SDK tests cover drag/cancellation, stable IDs,
per-window routing, flags, quotas and retirement.
There is no external executable installation interface, foreign window-system
ABI, GPU compositor, Unicode editor or general-purpose session service manager.
