# Native Bedrock64 runtime

The independent `userspace/` Zig package exports `bedrock64` from
`runtime/src/abi.zig` and `userspace_runtime` from `runtime/src/root.zig`.
The ABI file is the single shared
definition used by the kernel and native programs. Runtime calls use x86-64
`int 0x80`, ARM64 `svc #0` or RV64 `ecall`, with three integer arguments and a
raw 64-bit return. Use `abi.isError`, rather than the sign bit, to distinguish
errors from opaque handles.

The package supplies `bedrock-user-init`, `bedrock-user-service`,
`bedrock-user-fault`, `bedrock-user-io`, `bedrock-user-exec`,
`bedrock-user-files`, `bedrock-user-network` and `bedrock-user-wifi` artifacts.
It also supplies `bedrock-app-init`, `bedrock-app-observer` and
`bedrock-app-worker`, which use the installed-application profile described below.
The primary native window desktop supplies `bedrock-window-init`,
`bedrock-window-server`, `bedrock-window-shell`, `bedrock-window-files` and
`bedrock-window-notes`. The four-app service-desktop regression retains
`bedrock-desktop-init`, `bedrock-desktop-server`, `bedrock-desktop-shell` and
`bedrock-desktop-files`.
`build_support.zig` builds them from the real application sources under `../apps/` without a
kernel dependency. Their native entry assembly establishes the C call boundary;
RV64 also establishes its global pointer. These are static ELF64 `ET_EXEC`
images, not embedded kernel instruction fixtures.

The package always compiles user programs in `ReleaseSmall`, independently
of the kernel's optimization mode. The acceptance-profile linker bounds code and
read-only content to one RX page at `0x2000000000` and data/BSS to one RW page at
`0x2000001000`.
The kernel supplies an unmapped guard at `0x2000002000` and a RW stack page at
`0x2000003000`. The fault artifact has a four-byte syscall probe at the end of
its full RX page; init and service retain their smaller code images. Code/data
overflows fail linking. ARM64 excludes FP/NEON and uses
strict alignment; RV64 uses integer IMAC without F/D. There is no TLS, dynamic
linker, libc or POSIX binary ABI. The original fixture profile has no startup
record or heap; installed applications have bounded launch data and an allocator.
Legacy kernel-hosted Files uses a separate trusted desktop profile: at most 128 KiB RX code/read-only
content at `0x2000010000`, 1 MiB RW/NX data at `0x2000040000`, and 64 KiB RW/NX
stack at `0x20001e0000`, with an unmapped preceding guard. This bounded profile
does not let a client choose arbitrary mappings.
The known Wi-Fi acceptance image uses the same validated `TaskMemory` mechanism
with a trusted cap of four code pages, one data page and four stack pages.
It is selected only for the kernel's dedicated probe path; app-supplied ELF
metadata cannot widen the layout. Other fixtures retain their one-page bounds,
and payload quotas/teardown use the actual number of pages.

Installed applications retain the same three entry registers: parent PID,
explicit inherited stream token and numeric launch argument. `startup_info`
(`0x107`, all arguments zero) returns their immutable `Startup` page at
`0x2000030000`; legacy fixtures receive `not_supported`. This page is RO/NX.
The 1112-byte version-1 record contains trusted PID/parent/app identity, the
entry arguments, heap lease, launch flags, up to eight 56-byte arguments and
eight 56-byte `KEY=VALUE` environment entries. Reserved bytes, unused slots and
text tails are zero. `runtime.startup()` checks the record and its consistency
with the actual entry registers before returning it. `startup_record.argument`
and `startup_record.environment` operate on the validated record.

The headless and display-demo catalogues permit at most 32 RX code pages,
32 RW/NX data pages and four RW/NX stack pages. The installed Files desktop
permits 128 data pages per package for retained native rendering workspaces and
blur caches. Each has one startup page and an
eight-page zeroed RW/NX heap at `0x2000140000`. Heap capacity is the actual
mapped 32 KiB lease. There is no demand paging or heap growth syscall.
`runtime.appHeap()` creates a `Heap` over this lease; keep it at a stable address
while its `std.mem.Allocator` or allocations are live. The allocator tracks up
to 64 live allocations, supports alignment, free/reuse and resizing, and returns
`OutOfMemory` for lease or metadata exhaustion. The kernel reclaims the complete
process lease independently of this userspace bookkeeping on exit or fault.

`spawn_app` (`0x128`) takes a trusted numeric package ID, launch argument and an
optional authorized pipe-writer descriptor. Only a trusted launcher with
`app_launch` approval can use it; an application cannot manufacture its own
identity or launch permission. The kernel selects the new app's profile and
private namespace, and transfers only the approved writer right.
`application_ready` (`0x10a`, all arguments zero) is reserved for trusted init.
Production supervision continues after this milestone; a dedicated acceptance
kernel verifies its own lifecycle counters and performs controlled teardown.
It is not a generic application exit or a caller-controlled system shutdown.

The dedicated protected-display profile adds surface capabilities (`0x600`–
`0x605`) and named service endpoints (`0x610`–`0x614`). Clients render logical
`0x00RRGGBB` pixels into their own writable surface mappings. Submit revokes
those mappings and sends a frame with a kernel-created read-only grant to the
display service. Service release unmaps/closes that grant; it does not restore
the client's old mapping. An ACK carries service provenance and a frame
sequence, with no surface grant. Clients map their next frame explicitly.
Submit requires the owner's active writable mapping, a nonzero increasing
sequence and an authorized connection to its selected consumer. Queue capacity
is checked before revocation; `again` leaves the writable frame available for
retry. Explicit owner `surface_unmap` retains the owner handle but cancels its
mapping. Unmapping a received read-only snapshot also consumes that read handle;
calling release afterward therefore returns `bad_descriptor`.

There are four bounded 4 MiB mapping slots starting at `0x2000800000`. Slot
addresses identify views of authorized surfaces, not physical addresses. The
64-byte `ServiceMessage` carries authenticated peer PID/app ID. Clients cannot
forge those fields or mint surface grants through ordinary service send.
`display_wire` validates received metadata, unused fields, geometry and mapping
addresses before native programs use them. Named display service 1 belongs to
trusted identity 104; separately sandboxed client identities 105 and 106 share
one native AxisUI executable.
Service send/receive use exactly 64-byte messages, return zero on success and
`again` on queue backpressure or an empty receive. An invalid output pointer or
failed read-handle insertion leaves the queued message intact. Ordinary clients
can send only heartbeat control messages; frame grants come exclusively from
submit. Only the display service can send ACKs/input to authenticated peers.

Only the display service may query scanout metadata, present checked surfaces
or receive global input (`0x620`–`0x622`). It renders a private background,
places read-only client snapshots and routes focused, client-local AxisUI input
through authenticated endpoints. The kernel retains framebuffer/driver
ownership. `display_ready` (`0x10b`) is init's dedicated acceptance milestone;
production processes remain alive. See the [display service](../services/display-server/README.md)
and [native surface client](../apps/surface-client/README.md). Existing Files
and the earlier headless application runtime keep their own profiles.
Presentation is synchronous. The service may present its own currently writable
background or a mapped read-only client snapshot, with geometry wholly inside
scanout. This prototype permits one surface per process and four surfaces in
total, and supports reference scanouts from 800×600 through 1280×800. Client
surfaces are limited to 320×240. The earlier surface demo retains these bounds;
the installed Files desktop below is a separate profile. General damage
composition and GPU acceleration remain future work.

## Primary native window profile

The [native window desktop](../../docs/window-desktop.md) is the primary UEFI
profile. Its trusted catalogue contains init 101, display service 104, shell 107,
Files 2 and Notes 108; [window-apps.json](window-apps.json) must match those five
installed names and entry paths. Files and Notes have only `display_client`
approval and separate private containers. Shell alone can request either
application through launch kind 8; init alone holds `app_launch` and calls
`spawn_app`. The `window_runtime` profile selects desktop, display and installed
application support together.

`window_client.Session.openWindow` connects a GUI client and sends create kind 9
from its bounded `WindowOptions`:

```zig
var session = rt.window_client.Session.openWindow(.{
    .title = "Notes", .preferred_width = 620, .preferred_height = 420,
});
session.awaitConfiguration();
```

Titles are nonempty printable ASCII of at most 16 bytes. Preferred dimensions
describe the window frame and must be nonzero and no larger than the active
screen. The service clamps accepted dimensions to its work area and minimum
size. The kernel rejects requests beyond screen bounds; the current SDK exits
with status 99 when a control send fails. Shell uses
`Session.connect()` and heartbeat kind 4. One live connection and one producer
surface belong to each authenticated client PID; a second connection returns
`busy`.

The native controls extend the existing 64-byte `ServiceMessage`:

| Kind | Direction | Fields |
| --- | --- | --- |
| 9 create | GUI to service | Preferred frame width/height; zero-padded 16-byte title |
| 10 resize | GUI to service | Desired frame width/height; zero payload |
| 11 focus | GUI to service | Zero dimensions and payload |
| 12 close request | GUI to service | Zero dimensions and payload |
| 13 status | Service to shell | Width=workspace index 0–3; height=tiled 0/1; payload first 8 bytes=focused PID in little-endian, remaining bytes zero |

Apps use `requestResize(width, height)`, `requestFocus()` and `requestClose()`.
Client controls have zero peer PID/app and surface; the kernel supplies
authenticated sender identity on receive. They can address only the sender's
window. Shell launch kind 8 uses sequence 2 for Files or 108 for Notes; legacy
sequence 1 selects Files. Only the display service can send status, configure,
input, close and ACK replies.

Primary captions place the app name on the left and neutral rectangular
Minimize, Maximize/Restore and Close buttons on the right. The service owns the
title, controls, caption dragging and resize edges. F11 toggles fullscreen and
Escape leaves it; this caption has no separate fullscreen button. Retained
desktop profiles keep their original controls.

`WindowOptions.header_content` defaults to `false`. An app can opt into an
integrated center accessory while keeping all window authority in the service:

```zig
var session = rt.window_client.Session.openWindow(.{
    .title = "Files", .preferred_width = 640, .preferred_height = 420,
    .header_content = true,
});
session.awaitConfiguration();
if (session.headerLayout()) |header| {
    const center = header.accessory; // Client-local painting and hit-test bounds.
    _ = center;
    // Paint the accessory here and the body from row 32 using screen_width stride.
}
```

The opted-in viewport includes its 32-pixel caption. `Session.headerLayout()`
returns shared `window_header.Layout` geometry, or `null` while hidden or without
the opt-in. Recompute bounds after each configure. At inner width 316 the center
is `(104,4,112,24)`; its height is 24 at y=4. Only this caption rectangle accepts
ordinary client pointer input or client pixels. Captured client releases still
reach the app outside it to cancel body gestures. The compositor blits the body
from row 32 and clips caption copies to the accessory. Files uses the center for
an editable private folder path; default Notes retains a service-rendered caption.

Create kind 9 carries `abi.display.header_content` in the low flag bit, and
configure kind 6 echoes it only to that GUI client, including hidden viewports.
The kernel rejects unknown bits and permits the flag only on primary GUI
create/configure traffic; shell and retained profiles cannot use it. The SDK
checks authenticated service provenance and the shared geometry before exposing
the layout. Resize, focus, close, frames and other controls keep zero flags.
The option grants no filesystem, input-device, scanout or foreign-window authority.
The registry remains bounded to two GUI clients and one window per client PID.

`window_wire` and `window_client` retain the desktop configure/frame contract.
Configure kind 6 carries a strictly increasing 32-bit epoch, viewport size and
screen dimensions/origin. Frame sequence high 32 bits identify that epoch; the
low 32 bits are a nonzero increasing counter. A resize or workspace change keeps
an older immutable frame in flight until its exact ACK arrives. Stale frames
are released and acknowledged without replacing the current cache. Hidden
configurations have both viewport dimensions zero and retain the backing; the
client paints only when visible and no frame is in flight. A close notification
lets the client close its surface/endpoint and exit without waiting for an ACK.
Already delivered reader grants remain valid until service release revokes them.

The service owns two GUI caches and the composed scene as three fullscreen
surfaces; its shell-bar cache stays in bounded private BSS. Shell, Files and Notes
each own one fullscreen producer backing, for six steady-state surfaces. RO/NX
snapshot mappings and RW producer mappings use the same checked lease/revocation
rules as the older display profiles. Scanout and raw input stay service-only.
Installed code is bounded to 128 KiB RX, GUI/service/shell data to 512 KiB RW/NX,
stack to 16 KiB and heap to 32 KiB. Startup has its own RO/NX page. The supported
reference display range remains 800×600 through 1280×800.

Init's `window_ready` (`0x10d`, all arguments zero) reports initial supervision
after three frames from shell and each GUI client. The kernel independently
checks the five processes, six surfaces and actual publication/presentation.
Only the compositor can call `window_state` (`0x624`) through
`windowState(state, app_id, auxiliary)` for authenticated lifecycle/resource
observations; this diagnostic grants no launch or device authority.

The compositor's inherited pipe carries a 136-byte `WindowHeartbeat`, 17 `u64`
fields in this order:

```text
server_pid, shell_pid, files_pid, notes_pid,
shell_frames, files_frames, notes_frames,
files_closed, notes_closed, files_launch_requests, notes_launch_requests,
configure_sequence, presents, workspace, tiled, focused_pid, reserved
```

Init validates server identity, reserved bytes, workspace/tile bounds and
monotonic close/launch/configure/present counters. Frame counters remain
monotonic within a PID generation. Both children are polled independently;
normal close waits for a fresh launcher request, and nonzero exit triggers a
restart after that generation's snapshot retirement. The service and shell
retain their PIDs. Production continues after readiness; only the dedicated
acceptance profile performs controlled teardown and test-only Notes fault
recovery. Notes persists its bounded ASCII buffer in its own `notes.txt`.

Input is currently polled from bounded VirtIO device queues. Per-device order
is retained, but pointer and keyboard chronology across separate devices can
vary between polls. Dependent automation waits for observed selection, caret
or completed paint before the next action. An IRQ/event-driven input broker
with stronger cross-device ordering remains future work. The reference
verification uses QEMU/UEFI and does not establish physical-hardware support.

## Retained four-app service desktop

The service-desktop regression shares the same surface and authenticated endpoint
mechanisms, with compositor (ID104), shell (ID107) and Files (ID2). Each client owns one
full-screen pixel surface, bounded by 1280×800. The compositor owns three private
surfaces for two retained client caches and composed scanout; five surfaces are
live at steady state. Clients use slot 0 for a writable frame; submit revokes that
mapping. The compositor reads received immutable snapshots in slot 0 and keeps
its own writable caches in slots 1 through 3. Raw framebuffer addresses never
enter the client ABI.

`desktop_wire` and `desktop_client.Session` implement the desktop protocol,
separately from `display_wire`'s historical fixed-window demo. Configure kind 6
carries a strictly increasing 32-bit epoch, viewport width/height, and a 16-byte
little-endian payload containing screen width/height and global viewport origin.
A hidden viewport has both dimensions zero. The full-screen backing allocation
is retained across resize and minimize. A frame sequence contains its configure
epoch in the high 32 bits and a nonzero increasing frame counter in the low 32.
An obsolete frame is released and acknowledged without replacing the current
cache. A new configure does not discard an old in-flight sequence; a client
waits for its exact ACK before explicitly remapping its surface.

Input kind 5 carries an encoded AxisUI event in the first eight payload bytes.
Close kind 7 makes Files close its owner surface and endpoint and exit, without
waiting on an outstanding frame ACK. Already delivered reader leases remain
valid until the compositor releases them. Only shell (ID107) may send launch kind 8;
the compositor requests a launch through its inherited 80-byte `DesktopHeartbeat`
pipe. Init (ID101) alone calls `spawn_app`, waits nonblocking with
`waitPoll(pid)` (`wait` arg1=`wait_flags.nohang`), and observes process reaping
and compositor lease retirement before starting a new Files generation.
Minimize/restore retain Files' PID and surface. `waitPoll` returns `again` for
a live child and consumes a completed child's exit status.

Only the compositor may call `desktop_state` (`0x623`) to obtain a trusted kernel
lifecycle observation; the call grants no launcher or driver access.
`desktop_ready` (`0x10c`) is init's initial readiness report. The desktop includes
native title dragging, close/minimize/maximize/fullscreen controls and a Files
launch chip. Public procedural wallpaper supplies each process's own immutable
blur cache; Files does not read other clients' pixels. There is still one Files
window, synchronous CPU composition and bounded input queues, without dynamic
paging, a GPU compositor or a general multiwindow application launcher.

The wrappers additionally expose app-scoped file open/read/write/seek/close,
path spawn and exec, and nonblocking pipes with pipe-only rights-attenuating
duplication and explicit child-writer grants. `exec` preserves PID and trusted
profile, closes old descriptors, and enters a fresh zeroed image; failure leaves
the caller's old image usable. Directory listing, mkdir, copy, rename and remove
now support the Files client; general stat and POSIX interfaces remain future work.
`network.provider()` supplies the public NetworkKit connected-UDP adapter.
`udp_open` (`0x140`) reads an eight-byte `UdpConnect` with IPv4 address, port and
zero reserved field; the other two arguments must be zero. `udp_send`/`udp_receive`
(`0x141`/`0x142`) take a task-local socket token, buffer pointer and capacity or
length at most 256. Empty datagrams return zero; an empty receive queue returns
`again`. Short or invalid receive buffers retain the queued datagram. Existing
`close` releases the socket; successful exec, fault and process exit release its
authority too. The kernel requires explicit `network_client` approval; public
framework linkage supplies no network permission. See the
[network framework](../../docs/network-framework.md) for actual scope and checks.

`wifi.provider()` adapts `networkkit.wifi.Radio` to checked Wi-Fi calls
`0x160`–`0x165`: status, scan start/read, join, disconnect and enable/disable.
Their fixed status/scan/join records are 64/720/80 bytes. The pure wire decoder
rejects unknown tags, noncanonical flags, reserved bytes and inactive/unused
fields. Status/scan preflight complete writable buffers; joins copy and validate
bounded requests and volatile-clear explicit credential copies on every return.
Observation requires `wifi_observe` or `wifi_control`; changes require
`wifi_control`. `network_client` grants neither permission. Normal kernels report
unavailable. Dedicated tests exercise an explicitly simulated radio and the
production observer-only unavailable path, without RF or WPA authentication.
See the [Wi-Fi control foundation](../../docs/wifi-framework.md).

`nullify` (`0x135`) takes a readable canonical path pointer, its byte length and
a zero reserved third argument. The kernel rechecks trusted app identity,
private-container write authority and mutable file kind; bundles and directories
are rejected. Success follows overwrite/flush/exact readback of both complete
logical storage banks. An I/O failure can retain old data or a committed deletion
and poisons the live backend until fresh mount. This is a scoped Bedrock logical
file operation, not a hardware sanitization or independent-copy guarantee. See
[context menus and Nullify](../../docs/context-menus-and-nullify.md).
See [Unix I/O](../../docs/unix-io.md) for exact bounds and ownership.

The original fixture programs exercise launch, child waiting, timer sleep,
yield, attenuated IPC, files, pipes and executable replacement. The installed
application workload adds persistent init, independent observer/worker app
identities, private files, startup-page protection faults, heap/BSS reset and
repeated worker restarts while the observer keeps its original PID. It remains
a bounded application runtime, without a general service manager or filesystem
service. The legacy Files profile retains its temporary kernel-hosted shell
renderer. Files in that profile is a real protected ELF;
its command surface invokes checked rectangle, frosted material and presentation calls,
and its event call receives only host-routed input. This Files profile keeps
modern VirtIO input and window policy in the kernel host. The separate protected
display profile routes input and chooses placement in its installed service.
`ui_material` (`0x154`) accepts a readable 32-byte `DrawMaterial`: four `u32`
client coordinates/dimensions, `u32` RGB tint, `u32` opacity (0 through 255),
and a zero `u64` reserved field. Other syscall arguments must be zero. The host
clips to the current client and samples its immutable wallpaper blur cache.
Malformed requests are rejected before drawing; clients receive no framebuffer
address or readback. See [frosted materials](../../docs/frosted-materials.md).
`ui_event` blocks for a routed event. `ui_pending` (`0x155`) returns the next
already routed event or zero without blocking; all arguments must be zero.
Files handles at most 32 events per paint, reducing repeated frost work while
retaining event order and an explicit bound before the next presentation.
See [Files](../apps/files/README.md) and the [desktop contract](../../docs/desktop-design.md)
for the integration scope. Its
[verification record](../../docs/storage-and-files-verification.md) covers
actual checked syscall authority, input, file/window operations and reboot
recovery on all three UEFI references in Debug and ReleaseSafe.
The newer clean-header, native context-menu and Nullify revision has its own
[completed acceptance](../../docs/context-menus-and-nullify.md): Files 31/31 and
filesystem 35/35 native tests per mode, 172/172 root build steps in Debug and
ReleaseSafe, and six real QEMU workflows. Checked syscall authority, complete
logical-bank inspection, a presented result frame and fresh-boot absence cover
all three architectures in both modes.
