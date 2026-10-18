# Native Bedrock frameworks

Frameworks provide reusable APIs and mechanisms. Public frameworks are the
supported application-facing layer; private frameworks are internal APIs used
by Bedrock's own bootloader, kernel, driver modules, services and applications.
AxisUI is written from scratch in Zig and takes inspiration from declarative
view composition.

```text
frameworks/
  public/
    AxisUI/       views, layout, clipped drawing, bounded input and explicit state
    Anvil/        bounded graphics commands, provider capabilities and completion fences
    NetworkKit/   connected UDP and Wi-Fi control APIs with supplied authority callbacks
  private/
    DriverKit/    shared versioned driver ABI and bounded loader/linker tools
    AnvilCore/    trusted CPU texture execution, resource lifetimes and validation
    NetworkCore/  trusted bounded packet/endpoint and Wi-Fi controller mechanisms
userspace/
  apps/
    shell/        native wallpaper, Files/Notes launcher and workspace status
    files/        protected file-manager client with abstract authority callbacks
    notes/        native private ASCII editor and checked load/Save
    surface-client/ native AxisUI pixel client installed under two app identities
  services/
    display-server/ retained native compositor, controls, focus and input
    window-server/ portable geometry, modes and pointer-capture policy
```

[AxisUI](public/AxisUI/README.md) has no kernel, boot protocol, firmware or
filesystem dependency. It renders to a caller-owned surface with explicit
dimensions, stride, channel masks and reusable rendering workspace. A command
surface sends clipped drawing to a supplied sink instead of exposing pixels;
the legacy kernel-hosted Files regression keeps that adapter. The primary
installed desktop's Files, Notes and shell render into their own bounded pixel surfaces,
as do the separate protected display demo's clients. Submission revokes the writable mapping before the display
service receives an authenticated read-only snapshot grant. Public view
construction is separate from its internal layout, original glyph coverage and pixel
encoding. The [desktop shell](../userspace/apps/shell/README.md) uses these public
view APIs to build Bedrock's appearance. It lives with the other application
sources under `userspace/apps/`.

AxisUI's original [Axis Sans](public/AxisUI/AXIS_SANS.md) face uses proportional
advances, a 20-pixel line height and grayscale antialiasing at native scale1.
Its 14×20 base atlas is generated from the original curves. Scales 2 through 16
evaluate coverage directly from compact fixed-point vectors rather than
enlarging the bitmap. Measurement and drawing share the same advances; runtime
painting uses integer arithmetic and no allocations. Its current 95 printable
ASCII glyphs use a question-mark fallback for unsupported bytes. No Apple or other external
font assets or HTML renderer are used. The old 5×7 glyph API and explicit
`Surface.legacy_text` mode remain for historical diagnostic hosts.

[NetworkKit](public/NetworkKit/README.md) is also independent and written from
scratch in Zig. It provides IPv4 endpoints and connected UDP clients through a
supplied provider, with whole datagrams bounded to 256 bytes. Empty messages,
temporary blocking, short receive buffers and explicit connection lifetime are
distinct. The native runtime adapter submits checked socket syscalls; apps
receive no raw NIC/DMA authority. Its packet implementation belongs to private
[NetworkCore](private/NetworkCore/README.md), not the public client wrapper.
NetworkKit's `wifi` namespace adds status, scan and radio controls through a
separate provider. The runtime checks independent observation/control permissions;
linking either framework grants no device access. Its trusted controller and
explicit software test radio belong to NetworkCore. Normal kernels have no
physical radio backend and report unavailable. See the
[Wi-Fi control foundation](../docs/wifi-framework.md).

[Anvil](public/Anvil/README.md) is the lower graphics command layer. Its first
interface provides bounded 2D fill/copy batches, RGB/BGR textures, opaque resource
tokens and completion fences through an authorized provider. Private
[AnvilCore](private/AnvilCore/README.md) implements the working CPU provider with
checked image bounds, read-only imports, generational resource lifetimes and
whole-batch validation before writes. The kernel's existing display broker
routes approved presentation through the essential
[framebuffer driver](../drivers/gpu/README.md). AxisUI remains the native UI
framework, and composition/window policy remain in userspace.

This is a software backend. A general app GPU context/submission syscall and
hardware rendering drivers are subsequent milestones; importing Anvil supplies
no framebuffer, MMIO or DMA authority. See [Anvil](../docs/anvil.md) and the
[GPU driver porting plan](../docs/anvil-driver-porting.md).

[Private frameworks](private/README.md) contain
[DriverKit](private/DriverKit/README.md)'s shared versioned C driver ABI and bounded
ELF loader/linker tools, alongside NetworkCore's reusable trusted packet and
radio-controller mechanisms. Hardware-specific implementations and module
entry/boot ownership belong under `../drivers/`. Driver modules currently
execute with kernel privileges; framework placement does not isolate them.
Display wire records and checked surface/service adapters currently belong to
the native runtime, while the
kernel retains resource brokers. Reusable internal display framework APIs can
follow those concrete interfaces. Application views, themes and workspace-bar
composition belong in
`userspace/apps/shell/`. Internal APIs may change without preserving app
compatibility.
This API boundary does not enforce a sandbox; protected address spaces and
checked handles/syscalls enforce authority.

The primary [window desktop](../docs/window-desktop.md) runs installed init 101,
display service 104, shell 107, Files 2 and Notes 108 as five protected native
processes. The service owns two GUI caches, a bounded shell-bar cache, composed
scanout, z-order, focused input, window controls, title dragging, edge/corner
resizing, four workspaces, per-workspace tiling and frosted captions/cursor. It copies
checked RO snapshots into its own caches and retires read grants before exact
ACKs. Configured viewport epochs reject stale frames, and minimized clients
retain their process/surface with hidden viewport configuration. Init alone
launches app generations against their own durable containers. The native
runtime's `window_client.Session` API opens one window per GUI client PID and
provides resize, focus and close requests. The shell launcher restores live
windows or requests fresh Files/Notes processes through init.

The shared native header keeps the app title on the left, a configurable
centered accessory and neutral minimize/maximize/close controls on the right.
Within the caption, an opted-in client paints and receives input only in the reserved accessory
rectangle; the compositor owns the remaining caption. Files uses this area for
its location field: click it or press Ctrl+L, enter `~/Documents`, `~/Downloads`
or a canonical private `/container/...` path, and press Enter. Header composition
does not grant filesystem or window-control authority.

`test-window-desktop` and its runtime receipts are the primary desktop gate.
The current [glass revision](../docs/glass-desktop.md) uses shared AxisUI rounded
primitives, antialiased clipping and lighter private wallpaper materials; see
its [verification](../docs/glass-ui-verification.md). The preceding
[native UI verification](../docs/native-ui-verification.md) passed on all three
QEMU references in Debug and ReleaseSafe, including private persistence,
independent closure/relaunch, contained faults and balanced teardown with Axis
Sans and integrated center headers. The
[preceding window results](../docs/window-desktop-verification.md) remain archived. The retained
[single-window service desktop](../docs/service-desktop.md) passed its
[separate verification](../docs/service-desktop-verification.md) on all three
QEMU references in Debug and ReleaseSafe. The separate
[protected display demo](../docs/protected-display.md) retains clients105/106,
fixed placement and A fault/relaunch while B and service 104 survive. The legacy
kernel-hosted Files regression separately adapts supervisor scanout and clipped
draw commands. These profile boundaries do not grant apps extra authority:
only the approved display service receives raw input/final presentation rights;
linking AxisUI supplies no capabilities.

Broader GUI catalogue support, interrupt-driven input, automatic view
reconciliation and GPU hardware acceleration remain future work. User-space
views and service policy do not belong in private framework directories.

AxisUI and the desktop shell participate in the workspace's three-target
`zig build check` and native `zig build test`. Their APIs are experimental.
AxisUI now provides packed events, bounded queues/hit tests, a clipped cursor
and explicit revision state. Automatic bindings/reconciliation, richer widgets,
font services and accessibility remain future work. Drivers, process lifecycle
and compositor services belong to their own components.
NetworkKit's native tests and all three PIC target probes pass. The protected
preceding UDP/NIC milestone also passed six real QEMU boots across all three architectures
in Debug and ReleaseSafe, including malformed-frame rejection, empty datagrams,
checked buffers, stale handles and process-exit cleanup. Normal runs remain
offline unless their NIC is explicitly enabled; attaching it grants no app rights.
See the [network framework contract](../docs/network-framework.md) for scope.
