# Bedrock userspace

This independent Zig package owns native programs, Bedrock64 syscall/runtime
adapters, installed bundles and protected services. Public reusable APIs remain
in framework packages; reusable internal OS mechanisms belong under private
frameworks. Views and desktop policy remain userspace code.

```text
userspace/
  runtime/        Bedrock64, native entry/linker, startup, heap and IPC adapters
  apps/
    init/         fixture, installed, display-demo and desktop supervisors
    shell/        native wallpaper, Files/Notes launch chips and workspace status
    files/        Files model/provider, native pixel client and legacy draw adapter
    notes/        private native ASCII editor and checked load/Save
    observer/     installed retained-state application
    worker/       installed fault/relaunch and clean-exit workload
    surface-client/ AxisUI display-demo client installed as A and B
    lifecycle-test/ native IPC service and fault child
    io-test/      file, pipe, path-spawn and exec acceptance
    exec-test/    same-PID replacement and explicitly inherited pipe writer
    network-test/ protected UDP echo and authority acceptance
    wifi-test/    simulated/unavailable-radio acceptance
  services/
    display-server/ installed compositor, retained caches, focus and input
    window-server/ portable geometry, controls, modes and capture policy
```

## Primary installed desktop

Normal UEFI selects the [window desktop](../docs/window-desktop.md).
`apps/init/src/window_supervisor.zig` starts display service 104, shell 107,
Files 2 and Notes 108 under init 101. All five are installed native processes
with independent private mappings and checked permissions. Files keeps its
durable app-2 container; Notes saves `/container/notes.txt` in its own app-108
container.

The [shell](apps/shell/README.md) paints the public procedural wallpaper and
36-pixel launcher and workspace bar. [Files](apps/files/README.md) renders its configured
viewport through public [AxisUI](../frameworks/public/AxisUI/README.md), with
Places, breadcrumbs, a single list, optional Split, navigation history,
Copy/Cut/Paste, drag move, Ctrl-drag copy, context menus, create/mkdir,
rename/delete, Nullify and a copied read-only preview. Its provider issues
checked app-scoped file operations and owns no raw disk or scanout resource.

The [display service](services/display-server/README.md) copies incoming RO
snapshots into two GUI caches, retains the shell's bar in bounded BSS and
composes its own scene. It owns frosted captions, borders, cursor, z-order and
focused input. Portable WindowServer supplies title dragging, close, minimize,
maximize/restore, fullscreen and pointer capture; the window policy adds edge
and corner resizing, four workspaces and per-workspace tiling. F11 toggles
fullscreen, Escape exits it and Alt+F4 closes the focused client. Files/Notes
chips and Super+E/Super+N restore a minimized window or request a fresh app
generation through init. Super+1..4 switch workspaces, Super+Shift+1..4 move
the focused window, Super+T toggles tiling and Super+Tab cycles visible focus.
Close/relaunch preserves each app's durable data.

Each client keeps one full-screen logical RGB backing and paints a bounded
viewport at source 0 with full-screen stride. The compositor owns three separate
full-screen surfaces: two GUI caches and composed scanout. Shell, Files and
Notes each own one producer surface, for six live surfaces in the desktop.
Incoming snapshots use its temporary RO slot 0. Submission revokes a client's RW/NX
mapping before authenticated IPC transfers the RO/NX grant. Current-frame ACKs
follow composition/presentation; stale snapshots still release and receive an
exact ACK. Explicit configuration epochs reject stale geometry and old PIDs.
Minimize sends a hidden 0×0 viewport without retiring the client.

Init alone chooses installed identities. The compositor accepts launch requests
only from trusted shell 107 and reports atomic 136-byte heartbeat records through
an inherited pipe. Close waits for process retirement and the peer-close
notification before replacement. A failed app can restart while the other GUI
app, shell and compositor retain their PIDs and state. Each peer's replies and
input are bounded. The native `window_client.Session` SDK opens one window per
GUI client PID and exposes authenticated resize, focus and close requests.

`zig build desktop` packages all three architectures; `desktop-x86_64`,
`desktop-arm64` and `desktop-riscv64` select one.
`windows` packages the same profile; `run-uefi-<arch>`, `run-desktop-<arch>` and
`run-windows-<arch>` run it. `test-window-desktop` is the primary native desktop
runtime gate; `test-window-units` covers policy, SDK and receipt validation.
Its dedicated acceptance host uses F12 to finish, while F11 remains fullscreen.
The integrated runner records Files/Notes persistence, focus, resize, tiling,
workspace moves, independent close/relaunch and contained fault recovery.
All three QEMU references passed both kernel modes, with twelve workflows and
24 fresh boots; see [verification](../docs/window-desktop-verification.md) and the
[window contract](../docs/window-desktop.md). Broader GUI catalogue support,
interrupt-driven input, automatic UI bindings and GPU support remain future work.

## Separate runtime and regression profiles

The [single-window service desktop](../docs/service-desktop.md) retains
`apps/init/src/desktop_supervisor.zig` and compositor `src/desktop_main.zig` /
`src/desktop_policy.zig`. `service-desktop`, `run-service-desktop-<arch>` and
`test-service-desktop` select this earlier four-process Files profile. Its
[completed verification](../docs/service-desktop-verification.md) remains
separate from the primary window-desktop runtime receipts.

The [installed application runtime](../docs/application-runtime.md) remains a
headless profile: init 101 starts Observer 102 and Worker 103 from a validated UEFI
archive. Worker faults and restarts while Observer keeps its PID and private
state. It exercises startup arguments/environment, a bounded user heap,
independent containers and retirement accounting.

The [protected display demonstration](../docs/protected-display.md) retains
`apps/init/src/display_supervisor.zig`, display-server `src/main.zig` and its
`src/policy.zig`. Installed clients105/106 draw independent AxisUI pixel surfaces
at fixed 320×240 positions. Real focused input and A fault/relaunch coexist with
B/service survival. `display`, `run-display-<arch>` and `test-display` continue
to select this demo; its dedicated acceptance finish key is F11.

The legacy `test-desktop` regression separately keeps kernel-hosted display
policy and clipped drawing for a protected Files ELF. Its
[storage/input verification](../docs/storage-and-files-verification.md),
[compact UI verification](../docs/files-ui-verification.md) and
[menu/Nullify record](../docs/context-menus-and-nullify.md) describe completed
Debug/ReleaseSafe workflows on all three named QEMU profiles, including abrupt
shutdown and durable reboot recovery. Those results do not establish the new
window-desktop gate.

Earlier init/lifecycle/I/O/exec, network and Wi-Fi fixtures also remain separate
native ELF programs. Wi-Fi acceptance uses an explicit software test radio or
observation-only unavailable-radio status. Normal images have no physical radio
backend; see the [Wi-Fi contract](../docs/wifi-framework.md).

## SDK and resource boundaries

Installed programs load from checked UEFI-partition archives and immutable
bundle overlays. Programs use ReleaseSmall in every kernel mode. The trusted
catalogue bounds code/data/stack/heap for each identity; an ELF cannot request
a wider profile. Desktop programs 104/107/2/108 receive up to 128 KiB RX and 512 KiB RW/NX
data, a guarded 16 KiB stack, immutable startup page and preallocated 32 KiB heap.
Their checked surface mappings occupy four optional 4 MiB slots outside the core
program window. Actual payload/surface/table resources follow explicit ownership
and retirement. The smaller legacy fixtures retain their original bounds.

Rendering workspaces and blur scratch remain in private BSS; borrowed view
trees stay live for synchronous rendering. Linking AxisUI grants no framebuffer,
input, filesystem, network or launch authority. Only the approved compositor
can request raw display input/final presentation. Files, Notes and shell receive
authenticated app-local events and their own surface capabilities.

The [native process contract](../docs/native-processes.md) describes loading,
spawn/wait/exit, blocking IPC and sleep/wakeup. The [Unix I/O profile](../docs/unix-io.md)
adds app-scoped descriptors, pipes, path launch and same-PID exec. The
[persistent filesystem](../docs/persistent-filesystem.md) retains containers on
a dedicated two-bank image. General POSIX, arbitrary executable layouts,
dynamic paging/heap growth and a general service manager remain future work.

Standalone package builds accept `-Dtarget=<arch>-freestanding-none`.
Integer ARM/RV CPU features and profile limits are enforced by the package
build; the root builds the shared sources for x86-64, ARM64 and RV64.
No physical machine has been qualified by these emulator profiles.
See the [desktop design](../docs/desktop-design.md),
[application model](../docs/application-model.md) and
[private framework boundary](../frameworks/private/README.md).
