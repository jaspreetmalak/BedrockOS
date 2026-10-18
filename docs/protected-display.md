# Protected display foundation

Bedrock's dedicated `display` profile runs a native AxisUI compositor as a
protected user-space process. Persistent init launches it and two independent
clients from the installed ELF archive. The service paints the backdrop, places
windows and routes input. The kernel retains device drivers, checked physical
allocations, page tables, authenticated message queues and bounded scanout.

This document describes the separate fixed two-client demonstration, retained
as `display`/`test-display`. The primary [service desktop](service-desktop.md)
now runs installed Files 2 and shell 107 with compositor 104 under init 101, retained
full-scene composition and user-space window controls. Its implementation and
native/cross-build and integrated Files/input/reboot checks passed on all three
QEMU references in Debug and ReleaseSafe. See its
[verification record](service-desktop-verification.md). The older kernel-hosted Files workflow remains a separate
`test-desktop` regression profile.

## Build and run

Use the workspace's pinned Zig 0.17.0 toolchain:

```powershell
zig build display -j1
zig build run-display-x86_64 -j1
zig build run-display-arm64 -j1
zig build run-display-riscv64 -j1
```

The run targets launch QEMU with UEFI, a GOP framebuffer, modern VirtIO keyboard,
tablet and storage devices, and at least 128 MiB RAM. The same application
sources run on x86-64, ARM64 and RV64; this is qualification on named emulated
machines. It does not qualify arbitrary physical computers.

Architecture-specific `display-x86_64`, `display-arm64` and `display-riscv64`
targets produce `zig-out/display/<architecture>/bedrock-display.img`, with the
matching EFI executable, installed `apps.bap` archive and `kernel.elf` beside it.
The normal supervisor demonstrates one client fault and clean restart before
keeping both windows alive. Click **Toggle accent** in either window to update
its native state. Closing the QEMU window ends the host session.

## Ownership and placement

| Component | Responsibility |
| --- | --- |
| `userspace/apps/init/src/display_supervisor.zig` | Launch and wait, supervise client A, verify service progress and client B survival |
| `userspace/services/display-server/src/main.zig` and `policy.zig` | Demo backdrop, fixed two-window placement, sequences, focus and input |
| `userspace/apps/surface-client/` | Render private AxisUI pixels, submit frames, react to routed input |
| `userspace/runtime/src/abi.zig` and `display_wire.zig` | Fixed Bedrock64 records and validation; syscall adapters live in `root.zig` |
| `kernel/src/core/display_syscalls.zig` | Policy/handle checks, backing ownership, mapping transitions, queue accounting and checked scanout |
| `kernel/src/core/surface.zig` and `service_ipc.zig` | Portable lifetime state machine and authenticated bounded service queues |
| Architecture isolation implementations | RW/NX producer and RO/NX consumer mappings, translation retirement and private table cleanup |

The compiled trusted catalogue assigns init **101**, display server **104**,
and clients **105** and **106**. Init alone has installed-app launch permission.
Only the approved display server may register the display service or request
scanout and raw display input. A client may request its own pixel allocation and
connection; entitlement alone never authorizes someone else's object.

Each process keeps its existing bounded code, data, startup page, heap and
guarded stack. Four optional surface slots occupy a separate virtual area,
starting 8 MiB above the user base, spaced 4 MiB apart. No gap or unused slot is
user-accessible. Surface pixels are always NX. The kernel validates physical
backing, including exclusion of kernel, firmware, archive, driver and framebuffer
resources, before installing page tables.

## Frame and handle lifetime

1. `surface_create` allocates zeroed owned pages and returns a process-local
   generational handle. Producer authority includes read, write and submit.
2. `surface_map(..., writable=true)` grants a checked RW/NX lease in a free slot.
   The producer renders into this mapping.
3. `surface_submit` preflights the connection, sequence, queue and quota. It
   removes the producer's writable PTEs before publishing the frame and its
   read-only snapshot grant. A failed queue preflight preserves the writable
   lease so the producer can retry.
4. The service receives copied metadata with kernel-authenticated PID/app ID.
   Its new surface handle carries read authority only. It maps RO/NX, chooses
   placement and requests a bounds-checked scanout copy.
5. `surface_release` revokes the service mapping and consumes that snapshot
   handle. The service acknowledges the frame. The producer can then map again.

This demonstration allows one frame in flight per surface and one private
surface per owner process. The primary desktop separately permits three owned
service surfaces for Files cache, shell cache and composed scene; its clients
retain one full-screen backing each. Snapshot handles cannot gain write rights;
apps cannot forge frame attachments or peer identities in service messages.
Endpoint and connection object identities occupy distinct namespaces, and
generations never wrap into a retired identity.

A producer's exit first revokes its mappings, discards queued references and
drops owner authority. Already delivered snapshots remain alive until the
service releases them. Backing pages return exactly once after the final
reference and PTE are gone. Closing a service retires connections and returns
queued grants. Cleanup runs with user roots inactive before their private page
tables are destroyed. Failed mapping and allocation operations roll back their
owned resources.

## Input and current limits

The service reads checked VirtIO events and owns focus. A pointer press inside
a live window selects it; subsequent keyboard events target that exact PID/app
pair. Pointer coordinates are translated into local window coordinates. Clients
receive events only through their authenticated connection and validate the
service peer and record fields before using them.

This first profile has two fixed **320 × 240** client windows. The backdrop
supports GOP modes from **800 × 600** through **1280 × 800**, at most 4 MiB per
surface. Limits are four live surfaces, two service endpoints, four connections,
64-byte records, sixteen queued requests/replies per endpoint/connection,
sixteen authority handles per process, and a shared 8192-page memory budget.
Private page-table allocations are independently owned but not yet charged to
an individual app's budget.

Service receive is nonblocking. The demo sleeps on hardware ticks between
bounded polls; it does not yet provide event-driven display waits. Pending
per-window acknowledgements isolate a full reply queue; overflowing input is
explicitly rejected rather than blocking other clients. Retrying input and
coalescing pointer movement need a broader desktop event policy.

This demo chooses fixed placement and blits client rectangles through checked
kernel scanout. It intentionally retains no full scene for overlap, damage or
cursor composition. The primary [service desktop](service-desktop.md) now copies
Files/shell snapshots into retained caches and composes its own scene, frosted
caption and cursor. Close/minimize/maximize/fullscreen and title dragging live
in its user-space policy. General app launch, edge resizing, multiple windows,
tiling/workspaces, service recovery, GPU rendering and blur across independent
windows remain future work. Both profiles use native AxisUI, with no HTML.

## Verification

```powershell
zig build test-display test check -j1
zig build test-display test check -Doptimize=ReleaseSafe -j1
```

Acceptance performs three actual reads from revoked client-A mappings,
three clean client-A exits and restarts, and a final live replacement. Client B
keeps its original process while the display service keeps presenting frames.
The host checks actual QMP framebuffer pixels, clicks B, then verifies B changes
blue to green while A remains pink. It sends a finish key only after that
evidence is captured; the test kernel then checks complete page, context,
mapping, handle, queue, pipe and quota reclamation. Normal persistent runs stay
alive after the corresponding one-cycle demonstration.

Receipts, serial logs and native screenshots are retained under
`zig-out/display-tests/debug/` and `safe/`. The [verification record](protected-display-verification.md)
documents completed gates and practical limits.
