# Native NetworkKit and first UDP profile

Bedrock's public [NetworkKit](../frameworks/public/NetworkKit/README.md) is written
from scratch in Zig. It supplies a small connected UDP client API with a
host-provided transport. It imports no kernel, syscall ABI, driver, filesystem
or UI framework. The independent package exports `networkkit` and
`bedrock-networkkit`, with pinned Zig 0.17.0 native tests and three-ISA compile
probes.

NetworkKit also exposes a separate native Wi-Fi control API. Its bounded
controller, entitled syscall adapter and simulated/unavailable-radio acceptance
are described in the [Wi-Fi foundation](wifi-framework.md). That API does not
provide a physical radio or connect this Ethernet data path to Wi-Fi.

## Public API

```zig
const net = @import("networkkit");
const peer = try net.Endpoint.init(try net.IPv4.parse("10.0.2.2"), port);
var connection = try net.Connection.connect(provider, peer);
defer connection.close() catch {};
_ = try connection.send("hello");
const size = try connection.receive(&buffer);
```

`IPv4` contains four octets. `parse(text)` accepts exactly four canonical decimal
octets, with no signs, whitespace, leading zeros or hostname resolution.
`format(output)` returns a borrowed slice into caller storage; insufficient
capacity leaves that storage unchanged. `eql` compares octets. `Endpoint` carries
the address and a nonzero `u16` port. Address parsing/validation never grants
destination authority.

`Provider` contains an opaque context and open/send/receive/close callbacks.
`Connection.connect` validates the endpoint and rejects a zero handle. Sends are
whole datagrams of at most **256 bytes**, including a valid empty datagram.
Receive returns one whole datagram, or `error.WouldBlock` when no message is
available. Zero is a successful empty message. `error.BufferTooSmall` must leave
the queued message unconsumed. A larger receive buffer is bounded to its first
256 bytes.

The client rejects partial sends and receive counts beyond supplied capacity as
`error.InvalidProviderResult`. Other provider errors propagate without hidden
retries. Keep provider context alive, borrow payload/output only during each
call, and serialize access. Successful close invalidates the local client;
subsequent operations return `error.Closed`. Failed close retains ownership for
explicit handling/retry. Copying a connection does not duplicate its token or
authority; providers must reject stale tokens themselves.

## Runtime and trusted implementation

`userspace_runtime.network.provider()` adapts NetworkKit to protected Bedrock64
calls. `udp_open` (`0x140`) takes a readable eight-byte `UdpConnect`, then two
zero reserved arguments. The request contains four address octets, native
little-endian `u16` port and zero `u16` reserved field. `udp_send` (`0x141`) and
`udp_receive` (`0x142`) take the owned token, user pointer and bounded length or
capacity. Existing `close` releases the socket grant.

The kernel requires the trusted profile's network-client entitlement, resolves
the socket grant and rechecks send/receive rights and user memory. Receive
preflights writable capacity before inspecting/dequeuing a message. Framework
helpers do not replace those checks and give apps no NIC, DMA or raw packet
mapping. Wrong-kind and stale tokens are denied. Provider errors distinguish
temporary `WouldBlock`, short capacity and `NetworkUnavailable`.

The private [NetworkCore](../frameworks/private/NetworkCore/README.md) owns the
bounded Ethernet/ARP/IPv4/UDP mechanism. Its static reference configuration is
`10.0.2.15/24` with gateway `10.0.2.2`; the NIC supplies its MAC. Eight generational
connected endpoints each pin a peer tuple and queue four copied datagrams.
Local ports are issued monotonically without reuse within the current boot.
ARP resolution can return `WouldBlock`; callers explicitly retry. Parsing checks frame/length bounds,
IPv4 header checksums and the pinned tuple, using the header format in
[RFC 791](https://www.rfc-editor.org/rfc/rfc791). Outgoing UDP always includes a
checksum; incoming nonzero checksums are verified. IPv4 UDP's legal zero value
means no checksum was supplied and is accepted, as specified by
[RFC 768](https://www.rfc-editor.org/rfc/rfc768). Unsupported options,
fragmentation and unmatched traffic are rejected. Neighbor resolution follows
the Ethernet ARP mechanism in [RFC 826](https://www.rfc-editor.org/rfc/rfc826).

The current kernel host adapts a modern VirtIO NIC and polls bounded packet
work. The modern device contract is described by
[VirtIO 1.3 section 5.1](https://docs.oasis-open.org/virtio/virtio/v1.3/virtio-v1.3.html);
the current driver is a bounded subset tested on the named QEMU profiles,
not universal device support. Public/private describes API/support boundaries;
execution privileges,
entitlements and checked handles enforce authority. A standalone network service
process is future work. Driver DMA storage and the retained stack belong to the
device/runtime lifetime, while process exit releases owned socket/grant/quota
resources.

## Protected acceptance application

The separately linked `userspace/apps/network-test/src/main.zig` imports
NetworkKit and the native runtime. Its third launch argument is the echo port;
zero prints a graceful skip and exits with status 44. A configured probe connects
to `10.0.2.2`, serially exchanges two distinct nonempty messages, then reopens an
endpoint for one empty message. Each temporary send/receive block permits at
most 128 explicit `sleep(1)` retries.

The first reply must survive a short receive plus denied read-only/invalid
output pointers before whole reception. Raw syscall probes additionally reject
invalid/reserved open requests, oversized/invalid sends, wrong grant kinds and
stale tokens. The app emits echo, authority and zero-datagram proof markers. It
then intentionally opens a final endpoint, emits an exit-cleanup marker and exits
44 without closing it; the kernel must reclaim the live socket, grant and quota.

The QEMU harness uses an isolated loopback Ethernet echo peer, rather than
physical or external traffic. It injects checksum/IP/port mismatches before a
legitimate reply and must observe exactly the expected payloads through the
protected application. Sending establishes local submission, not guaranteed
remote delivery.

## Previous network milestone verification

At the preceding network milestone, NetworkKit passed **13/13 native tests**
in Debug and ReleaseSafe,
plus native compile checks and six PIC freestanding probes: x86-64, strict-aligned
ARM64 and integer-only RV64 in both modes. Tests cover malformed addresses, atomic
format capacity failures, endpoint/open validation, whole/empty/max-size messages,
short-buffer preservation, malformed callback results, error propagation and
closed/stale lifecycle behavior.

Runtime integration, aggregate checks and real networking acceptance passed on
all three QEMU UEFI references in Debug and ReleaseSafe. Both root
`test check test-uefi test-network test-desktop -j2` runs passed **213/213 build
steps**; the default Debug build/install passed **139/139**. Unchanged cached
checks are included, so executed-only test summaries are not a fresh test
inventory. Component native checks per mode include NetworkKit **13**, NetworkCore
**11**, the driver suite **15** including previous driver checks, and the socket
boundary/user-memory suite **8** (three broker and five user-memory checks).

The **six real network boots** exchanged twelve nonempty and six empty
datagrams through the protected ELF and actual VirtIO path. The isolated peer
injected twenty-four bad-checksum/wrong-tuple frames, which did not reach the app.
The second legitimate reply deliberately has a zero UDP checksum, proving the
IPv4 absent-checksum rule; all outbound packets are checksummed, and nonzero
inbound checksums are checked. Short-buffer and denied-output requests preserve
the queued reply. Stale tokens are denied, and all six intentionally live
exit sockets are reclaimed with socket/grant/quota baselines restored.

The same final runs passed six full Files regression workflows: twelve normal
boots, twenty-four client starts and twelve checked closes, with existing
file/window/persistence acceptance intact. Files' protected startup checks deny
network requests on its first client and all three post-reboot starts per
workflow. Adding a NIC does not change its permissions.

The checked aggregate receipt is `.zig-cache/network-verification.json`.
Per-architecture results and logs are under
`zig-out/network-tests/{debug,safe}/network-{arch}-verification.json` and
`network-{arch}.log`. The tested installed QEMU binary reports **10.1.94**
(`v10.2.0-rc4-12104-gb2a6201393`); named `pc-q35-10.1`/`virt-10.1` machine profiles
remain the reference configuration. These generated local receipts do not
qualify physical NICs or boards.

Run package checks from `frameworks/public/NetworkKit/`:

```text
zig build test check
zig build test check -Doptimize=ReleaseSafe
zig build check -Dtarget=x86_64-freestanding-none -Drelocatable=true
```

Reproduce integrated acceptance from the workspace root:

```text
zig build test check test-uefi test-network test-desktop -j2 --summary all
zig build test check test-uefi test-network test-desktop -Doptimize=ReleaseSafe -j2 --summary all
zig build -j2 --summary all
```

`zig build test-network` runs only the isolated network workflows, with
`test-network-x86_64`, `test-network-arm64` and `test-network-riscv64` variants.

The subsequent [Wi-Fi control milestone](wifi-framework.md#verification) passed
269/269 aggregate steps in Debug and ReleaseSafe, with the same six UDP boots
and Files regressions preserved. Its separate twelve Wi-Fi boots cover
simulated controls and production unavailable status, with no physical radio
or wireless authentication claim. The newer aggregate receipt is
`.zig-cache/wifi-verification.json`; the 213/139 results above remain the
preceding network milestone.

## Optional manual network attachment

Normal runs remain offline by default. Enable the NIC explicitly:

```text
zig build run-uefi-arm64 -Dnetwork=true
```

The same option works with `run-uefi-x86_64` or `run-uefi-riscv64`. The Windows
`tools/run-uefi.ps1` wrapper accepts `-Network`; the Unix wrapper accepts an eighth
`network` argument. For example, an empty seventh argument retains its default
data image:

```sh
sh tools/run-uefi.sh "$QEMU" "$ESP" "$UEFI_CODE" "$UEFI_VARS" 128 arm64 '' network
```

This attaches QEMU's user-mode network backend while preserving app permission
checks. The static `10.0.2.15/24`, gateway `10.0.2.2` configuration matches
[QEMU's documented user-mode network](https://www.qemu.org/docs/master/system/devices/net.html#using-the-user-mode-network-stack).
The isolated acceptance peer remains separate from this optional manual backend;
the tests establish no external Internet workflow.

## Limits

This UDP profile supplies no TCP, TLS, DNS, DHCP, IPv6, physical Wi-Fi data path, listening server API,
multicast/VLAN handling, general routing, socket inheritance, asynchronous SDK
event loop or SMP synchronization. UDP/ARP do not authenticate peers or provide
confidentiality against active attackers. General app installation and complete
sandbox/service policy remain separate work. No physical NIC or computer is
qualified by these reference checks.
The separate [Wi-Fi control API](wifi-framework.md) is implemented, with an
explicit software test radio and production unavailable status; physical driver
and wireless security qualification remain future work.
