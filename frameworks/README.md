# Native Bedrock frameworks

Frameworks provide reusable APIs and mechanisms. Public frameworks are the
supported application-facing layer; private frameworks are internal APIs used
by Bedrock's own services and applications. AxisUI is written from scratch in
Zig and takes inspiration from declarative view composition.

```text
frameworks/
  public/
    AxisUI/       views, layout, clipped drawing, bounded input and explicit state
    NetworkKit/   connected UDP and Wi-Fi control APIs with supplied authority callbacks
  private/
    NetworkCore/  trusted bounded packet/endpoint and Wi-Fi controller mechanisms
userspace/
  apps/
    shell/        desktop application, theme, bar and workspace composition
    files/        protected file-manager client with abstract authority callbacks
```

[AxisUI](public/AxisUI/README.md) has no kernel, boot protocol, firmware or
filesystem dependency. It renders to a caller-owned surface with explicit
dimensions, stride, channel masks and reusable rendering workspace. A command
surface sends clipped drawing to a supplied sink instead of exposing pixels;
the protected Files client uses checked syscalls behind this sink. Public view
construction is separate from its internal layout, bitmap glyphs and pixel
encoding. The [desktop shell](../userspace/apps/shell/README.md) uses these public
view APIs to build Bedrock's appearance. It lives with the other application
sources under `userspace/apps/`.

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

[Private frameworks](private/README.md) contain NetworkCore's reusable trusted
packet and radio-controller mechanisms. Future display-service IPC clients and broker helpers belong
there when their services exist. Application views, themes and workspace-bar
composition belong in
`userspace/apps/shell/`. Internal APIs may change without preserving app
compatibility.
This API boundary does not enforce a sandbox; protected address spaces and
checked handles/syscalls enforce authority.

The kernel's temporary display host adapts a validated, supervisor-only
framebuffer for the shell and executes the protected Files ELF separately.
It checks client drawing/input requests against the one window's bounds and
focus. A standalone protected display service and surface IPC remain future work.

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
