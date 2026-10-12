# NetworkKit

Experimental native connected UDP and Wi-Fi control APIs, written from scratch
in Zig.
The independent package exports `networkkit` and compile probe
`bedrock-networkkit`; it has no kernel, driver, filesystem or runtime dependency.
The host supplies transport and authority through each API's provider callbacks.

```zig
const peer = try net.Endpoint.init(try net.IPv4.parse("10.0.2.2"), port);
var connection = try net.Connection.connect(provider, peer);
defer connection.close() catch {};
_ = try connection.send("hello");
const size = connection.receive(&buffer) catch |err| switch (err) {
    error.WouldBlock => return,
    else => return err,
};
```

`IPv4.parse` accepts strict four-octet decimal addresses; signs, whitespace,
leading zeros and hostnames are rejected. `format(output)` borrows caller storage
and leaves it unchanged on insufficient capacity. `Endpoint.validate` rejects
port zero; provider policy decides whether an address/port is authorized.

Datagrams are at most 256 bytes. Empty datagrams are valid: receiving zero is a
successful empty message, while `error.WouldBlock` means no message is available.
`error.BufferTooSmall` must not dequeue the message. `Connection.receive` bounds
larger buffers to their first 256 bytes. Whole sends and receive counts are
checked; malformed results return `error.InvalidProviderResult`. The framework
cannot undo bytes written or a message consumed by a faulty provider.

Keep the provider context alive and serialize access. A connection has one
owner; copying it does not duplicate its token. Successful close clears its
handle and rejects subsequent send/receive/close. Failed close remains retryable.
The provider must reject stale tokens and check rights on every operation.
The framework and its source directory grant no network authority.

The UDP profile supplies no TCP, TLS, DNS, DHCP, IPv6, listening socket, multicast control,
stream framing, general event loop or automatic retries. Transport discovery,
wire validation, packet queues and grants belong to the driver/kernel/runtime
adapter, not this package.

## Wi-Fi controls

`networkkit.wifi.Radio.init(provider)` exposes `status`, `startScan`, `scan`,
`join`, `disconnect` and `setEnabled`. Scan snapshots contain up to 16 distinct
BSSIDs with a generation; joins select that exact generation and cached index.
`Credentials` accepts printable 8–63 byte passphrases, or an empty value for an
open network. `Radio.join` volatile-clears the caller-owned credential value on
every return; immutable constructor input and independent copies are outside
that wipe. Provider context must remain alive and calls must be serialized.

The framework supplies no physical radio or WPA cryptography. Its checked
runtime provider requires separate `wifi_observe`/`wifi_control` approval;
network-client permission grants neither. Dedicated protected acceptance uses
an explicitly simulated backend and a separate production unavailable-radio
variant. Normal kernels report unavailable. See the
[Wi-Fi control contract](../../../docs/wifi-framework.md) for ownership,
wire bounds, controller behavior and physical-driver requirements.

Run `zig build test check` using pinned Zig 0.17.0. Standard target/optimization
options and `-Drelocatable=true` support freestanding PIC checks. The
[network framework contract](../../../docs/network-framework.md) records
integration status separately from package tests.

The current Wi-Fi milestone passed **27/27 native package tests per mode** and
six PIC freestanding probes. Twelve protected QEMU Wi-Fi boots cover simulated
and production unavailable-radio variants in Debug/ReleaseSafe. The
[Wi-Fi verification](../../../docs/wifi-framework.md#verification) records the
269/269 integrated steps per mode and `.zig-cache/wifi-verification.json`;
physical radio and WPA authentication remain unsupported.

The previous UDP/network milestone passed 13/13 native tests per mode and all
six three-ISA PIC checks. Its integrated acceptance passed six actual QEMU
network boots in Debug/ReleaseSafe:
two nonempty and one empty datagram per boot, malformed-frame filtering,
checked-buffer preservation, stale-token denial and live-socket exit cleanup.
See `.zig-cache/network-verification.json` at the workspace root and the linked
milestone for reproducible commands, driver/runtime limits and optional NIC
attachment. Default runs remain offline and app permissions remain checked.
