# NetworkCore

NetworkCore supplies trusted, allocation-free Ethernet/ARP/IPv4/UDP mechanisms
and a bounded Wi-Fi controller.
The public [NetworkKit](../../public/NetworkKit/README.md) supplies application
types. Directory placement grants no authority; the kernel checks socket grants,
profile permissions and user buffers at its syscall boundary.

Keep one `Stack` in retained storage and call `init(Config, Transport)` in place.
The default reference configuration is static `10.0.2.15/24`, gateway `10.0.2.2`;
the NIC supplies the MAC. `Transport.send` must copy/submit a complete frame before
returning and must never retain the supplied stack buffer. Calls are serialized.

Eight generational endpoints pin one IPv4 peer/port each. Local ports are issued
monotonically from 49152 through 65535 and never reused within this stack's
lifetime, preventing late replies from entering a replacement endpoint. Each
endpoint holds four copied datagrams of at most 256 bytes; full queues drop the
newest packet. `peek` inspects length; a short receive leaves the queue unchanged.
An empty datagram returns zero, while an empty queue returns `WouldBlock`.
Closing clears every queued byte through volatile stores and invalidates its ID.

An unresolved neighbor causes an ARP request and `WouldBlock`; callers retry.
Sending means local whole-frame submission, never remote delivery. Input checks
Ethernet bounds/destination, ARP shape, IPv4 lengths/header checksum, and UDP
pseudo-header checksum when present, and pinned tuple. Outgoing UDP always has a
nonzero checksum; IPv4 UDP's legal zero value means an absent checksum and is
accepted. Options, fragments, VLAN, multicast, broadcasts,
oversize datagrams and unknown protocols are unsupported. Malformed/unmatched/full
input updates bounded counters instead of propagating a kernel failure. ARP is
not peer authentication; this stack supplies no confidentiality or integrity
against an active network attacker.

There is no DHCP, DNS, TCP, TLS, IPv6, server binding, general routing, socket
inheritance or SMP synchronization. This package owns no physical driver or
application handle table. Native tests cover packets, checksums, tuple filtering,
FIFO bounds, stale IDs, nonreused ports and exact datagram preservation.

Protocol sources: [ARP](https://www.rfc-editor.org/rfc/rfc826),
[IPv4](https://www.rfc-editor.org/rfc/rfc791),
[UDP](https://www.rfc-editor.org/rfc/rfc768).

## Wi-Fi controller and software test radio

`network_core.wifi.Controller` uses a caller-owned `Backend`; it does not provide
a physical Wi-Fi driver, RF simulation or WPA cryptography. `init(backend, now)`
confirms an initially disabled radio. Enable/disconnect/cancel callbacks must
synchronously confirm their requested safe state. Scan and association submissions
complete later through checked events with never-reused operation IDs. Backends
must not retain credential bytes or pointers after `start_join` returns.

`startScan(now)` explicitly renews discovery; `scan()` reads the committed cache
without starting or consuming an operation. Surveys retain the first 16 unique
BSSIDs, updating duplicate signal strength. Additional unique BSSIDs are dropped
and counted; contradictory duplicate identity/security records fail the survey.
Scan generations pin selection. Association uses the exact cached BSSID/security,
requires backend-confirmed WPA2 authentication, and rejects hidden SSIDs, WPA3 and
unsupported security without an open downgrade. Scan renewal while connected
returns `Busy`; disconnect first. A radio link does not establish DHCP, routing
or an IP connection.

`join(generation,index,*Credentials,now)` clears all 63 credential bytes and the
length through volatile stores on every return, including preflight or backend
failure. WPA2 accepts printable 8–63 byte passphrases; open joins require empty
credentials. No credentials appear in status, scan results or controller storage.
The serialized caller supplies monotonic ticks. Scan/association deadlines are
500/1000 ticks, with at most 16 backend events handled per poll. Disable,
disconnect, link loss, timeout and device failure invalidate pending link proof;
stale events cannot restore a cancelled connection. Device failure also clears
the scan cache and stops polling the disabled backend.

`wifi_test_radio.TestRadio` (also `Radio`) is an explicit **software test backend**.
It publishes open/WPA2/unsupported-WPA3 fixtures and deterministic authentication
success for `test-passphrase`, failure for other WPA2 strings, plus asynchronous
submission barriers and fault injection. It retains no supplied credential.
Production never automatically selects it. Passing these tests proves controller
and syscall integration, not real radio operation or WPA authentication.
Normal Bedrock kernels report unavailable until a physical backend is implemented
and qualified. The separate observer-only acceptance variant exercises that
production path. See the [Wi-Fi control contract](../../../docs/wifi-framework.md)
for public/runtime boundaries and the isolated verification profiles.

The current package passed **23/23 native tests per mode** and six PIC
freestanding probes. Integrated simulated/unavailable-radio execution passed
all twelve protected QEMU boots across the three architectures in
Debug/ReleaseSafe. The [Wi-Fi verification](../../../docs/wifi-framework.md#verification)
records the aggregate results and receipt; none of these tests qualifies a
physical radio or WPA implementation.
