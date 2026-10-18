# Protected display service

The primary installed desktop runs native init 101, display service 104, shell
107, Files 2 and Notes 108 as separate protected ELF processes.
`src/window_main.zig` owns software composition and focused input;
`src/window_policy.zig` owns the PID-based window registry, peer lifetimes,
configure epochs, geometry, focus, resizing, tiling and four workspaces.
The kernel supplies capability-checked surfaces, authenticated messages,
bounded device input and final presentation. These processes receive no raw
framebuffer, physical-memory or device address.

## Native window desktop

Files and Notes each own one producer surface and private storage container.
The shell owns a third producer surface. The compositor owns two GUI caches
and one composed scene, for six live surfaces with five processes. Its bounded
private shell cache retains only the 36-row bar; it regenerates the wallpaper
and uses an immutable wallpaper source for frosted materials. Slot 0 maps an
incoming snapshot RO/NX only while copying it. Release revokes that alias;
exact ACKs and configure epochs protect outstanding frames during resizing.

Each approved GUI process has one display connection and one window. The shell
can focus or restore a live app and request a fresh Files or Notes generation
through init. A 136-byte `WindowHeartbeat` carries both clients' authenticated
identities and lifecycle state. Closing either client retires only that client's
process and surface; a contained client fault permits restart while the other
client, shell and compositor keep their PIDs.

Primary captions place the app name on the left and neutral rectangular
Minimize, Maximize/Restore and Close buttons on the right. These privileged
controls, caption dragging and edge/corner resizing operate in the service.
F11 toggles fullscreen and Escape leaves it; primary captions have no
fullscreen icon. The retained profiles below keep their original layout.

GUI clients may set `WindowOptions.header_content = true` when creating their
own window. Configure echoes the capability, and `Session.headerLayout()`
returns the shared client-local accessory bounds, or `null` while hidden.
An integrated viewport includes all 32 caption rows as well as the body.
The service blits only the center accessory within those caption rows and
routes ordinary client pointer input only through that rectangle or the body.
Client capture still delivers outside releases so the app can cancel gestures.
The left title, caption gaps, right controls and resize edges remain under
service ownership. Files uses the center for its editable path; default Notes
uses the service-rendered caption.

The low `abi.display.header_content` flag is allowed only on primary GUI
create kind 9 and configure kind 6. The kernel rejects unknown bits and flag
use by shell, other message kinds or retained profiles. Configure provenance,
PID ownership, RO snapshot leases, exact ACKs and private storage boundaries
are unchanged. This API adds no compositor filesystem authority or GUI slots:
the catalogue still has two GUI clients and one window per PID.

Super+T toggles tiling, Super+1 through Super+4 switch workspaces, and
Super+Shift+1 through Super+Shift+4 move the focused window. Configurations hide
inactive clients with a zero-size viewport and retain their process and model.
See the [native window guide](../../../docs/window-desktop.md) for controls,
SDK contracts, resource bounds and the polled-input limitation.

`zig build desktop`, `windows` and normal UEFI targets package this profile;
`run-desktop-<arch>` and `run-windows-<arch>` run it.
`test-window-desktop` verifies both apps, private persistence, focus, minimum
resizing, workspaces, independent closure and actual CPU-fault recovery.

## Retained single-window Files profile

`src/desktop_main.zig` and `src/desktop_policy.zig` retain the preceding
four-process profile using the portable [WindowServer](../window-server/README.md)
policy. The following details describe that separate regression profile.

The service owns three full-screen RGB surfaces: Files cache in slot 1, shell
cache in slot 2 and composed scanout in slot 3. A received client snapshot is
mapped RO/NX in slot 0, copied to the matching retained cache and released before
the client receives its exact ACK. A current frame's ACK follows composition
and synchronous final presentation. Surface submission revokes the client's
RW/NX mapping; it explicitly remaps its own backing for the next frame. Every
client keeps one full-screen backing while rendering its configured viewport
at source 0 with full-screen row stride. The reference bound is 800×600 through
1280×800, with five live surfaces in total.

The shell supplies the wallpaper and 36-pixel Files launch bar. The compositor
blits Files at its configured client origin and renders native frosted caption,
border, controls and cursor with AxisUI. An immutable wallpaper-only blur cache
preserves the same materials as the legacy Files host. Close, minimize,
maximize/restore, fullscreen and title dragging remain user-space policy. F11
toggles fullscreen, Escape exits it, Alt+F4 closes the focused Files process,
and the bar or Super+E restores or launches Files. The initial 1280×800 frame is
960×620 at `(160,72)`. Saved floating geometry survives close/relaunch.

Configurations carry a bounded sequence and viewport dimensions, screen size
and origin. Frame sequences encode that configuration epoch in their high 32
bits. Stale geometry, duplicate frames and old PIDs cannot update a retained
cache. Obsolete snapshots are still released and acknowledged so a pending
resize cannot deadlock a compliant client. A newer configuration precedes an
older frame's ACK. Minimize configures a hidden 0×0 viewport while preserving
the process and surface; restore requests a fresh visible epoch. Closing clears
the Files cache immediately and exposes the shell background.

Only authenticated shell 107 can request a launch. Init chooses installed
identities and starts each new Files generation after process retirement and
the service's peer-close notification. The compositor forwards launch requests
through its inherited pipe in atomic 80-byte `DesktopHeartbeat` records.
Records include authenticated peer PIDs, per-generation Files frames, shell
frames, closures, configuration sequence and presentation count. A crash can
restart Files while shell and compositor retain their PIDs and state.

Each peer has a bounded pending ACK, latest configuration, close request and
32-event input queue. Pointer moves coalesce; a nonreading client cannot block
composition or the other peer. Queue overflow cancels the obsolete gesture
backlog through an explicit redraw before the latest event, so an individual
lost release cannot keep a press active. Geometry updates discard old queued coordinates.
Malformed messages cannot choose another cache or identity, and any attached
read lease is retired. This profile supports one Files window and a CPU
compositor. It has no edge resizing, tiling or workspaces. GPU acceleration and
damage tracking remain future work in both desktop profiles.

`zig build service-desktop` packages this profile for all three architectures.
`run-service-desktop-x86_64`, `run-service-desktop-arm64` and
`run-service-desktop-riscv64` run it. `test-service-desktop` drives
native Files input, controls, durable file operations and reboot recovery on
owned test media. F12 finishes its dedicated acceptance host; F11 remains the
actual user-space fullscreen action. Kernel-authenticated state diagnostics
record stable server/shell PIDs and Files generation/resource lifetimes.

## Separate surface demonstration

`src/main.zig` and `src/policy.zig` retain the earlier protected display demo:
init 101 starts service 104 with AxisUI clients 105 and 106 in fixed 320×240 windows
at `(24,64)` and `(456,64)`. Its 40-byte heartbeat and controlled A fault/relaunch
workload remain separate from the Files desktop. The demo directly presents
received read snapshots, and its fixed placement has no general window controls
or retained-scene compositor. Closing A retires its metadata and grants; later
rendering replaces its last scanout pixels. Client B and the service survive.

`zig build display`, `run-display-<arch>` and `test-display` continue to build,
run and verify that demonstration. F11 is its dedicated acceptance-finish key.
The older kernel-hosted Files workflow also remains available through the
separate `test-desktop` regression profile. See
[protected display](../../../docs/protected-display.md) and
[desktop design](../../../docs/desktop-design.md) for profile boundaries.
