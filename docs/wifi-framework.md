# Native Wi-Fi control foundation

Bedrock provides a native Zig Wi-Fi control API and a bounded trusted controller.
The current backend is a **simulated test radio**. Normal kernels report the
radio as unavailable; no physical Wi-Fi adapter is supported or qualified.
VirtIO networking remains Ethernet. These tests do not transmit radio traffic,
connect to an access point, authenticate WPA2, or configure an IP network.

## Public API and ownership

The public [NetworkKit](../frameworks/public/NetworkKit/README.md) exports
`networkkit.wifi`. `Radio.init(provider)` stores a borrowed provider context;
keep that context alive and serialize operations. The control methods are
`status`, `startScan`, `scan`, `join`, `disconnect` and `setEnabled`.

`Ssid` stores at most 32 binary bytes. A hidden scan result may have an empty
SSID, but joining hidden results is unsupported. `Bss` carries the SSID, BSSID,
channel, signal level and security classification. `Scan` holds at most 16
validated, distinct BSSIDs and a nonzero generation. Read the committed cache
explicitly: a pending scan returns `WouldBlock`; reading it never starts another
scan or consumes results. Joining selects an index from that exact generation,
so an old snapshot cannot silently select a new network.

`Credentials` accepts printable ASCII passphrases of 8–63 bytes; an open network
uses an empty value. Raw hexadecimal PSKs, enterprise authentication and WPA3
joining are unsupported. `Radio.join` clears the complete caller-owned credential
buffer through volatile stores on every return, including rejected selection,
validation and provider failures. The trusted controller and syscall adapter
also clear their explicit transient credential storage. Backends may borrow the
secret only during submission and must not retain its bytes or pointer. This
contract clears the owned `Credentials` value, not the immutable input passed to
its constructor or independent copies a caller made elsewhere.

Status reports `unavailable`, `disabled`, `idle`, `scanning`, `associating`,
`connected` or `failed`, together with a revision, failure reason and explicit
`simulated` field. The revision saturates at the maximum `u64` value. A submitted
join is not a connected state: the backend must
confirm the selected BSSID and security mode, and report completed authentication
for a WPA2 selection. The test backend exercises this event policy; it implements
no RF, EAPOL, key derivation or encryption.

## Trusted controller and application boundary

The private [NetworkCore](../frameworks/private/NetworkCore/README.md) provides
`wifi.Controller` and its backend contract. Operation IDs do not wrap into reused
identities. Scan generations reject stale selections. A scan retains the first
16 valid distinct BSSIDs and drops additional valid results. Scan deadlines use
500 kernel ticks and join deadlines use 1,000 kernel ticks; each poll consumes at
most 16 events. Disable, disconnect,
timeout and device failure invalidate pending/current state and request backend
cancellation. A late completion cannot reconnect a cancelled operation.

The Bedrock64 calls are `wifi_status` (`0x160`), `wifi_scan_start` (`0x161`),
`wifi_scan_read` (`0x162`), `wifi_join` (`0x163`), `wifi_disconnect` (`0x164`) and
`wifi_enable` (`0x165`). Fixed layouts bound status to 64 bytes, a scan snapshot
to 720 bytes and a join request to 80 bytes. Reserved fields/arguments must be
zero. The [native runtime](../userspace/runtime/README.md) adapts the public
provider to these checked calls.

Observation requires the separately approved `wifi_observe` or `wifi_control`
entitlement. Changes require `wifi_control`. Authorization precedes device work,
request parsing and user-memory translation. The existing network-client
entitlement grants neither permission. Status/scan copyout preflights the full
writable destination before reading a snapshot. Join copies a bounded request,
validates its reserved fields and credential tail, and wipes explicit kernel
copies on every return. Applications receive no device registers, DMA memory,
firmware upload or raw radio authority.

The runtime's pure wire decoder separately rejects unknown tags, noncanonical
flags, nonzero reserved bytes, inactive current-network fields, unused scan
records and SSID tails. A malformed response cannot become a public snapshot.

Radio association and IP networking remain separate. The existing
[connected UDP framework](network-framework.md) uses its named static Ethernet
configuration; this milestone does not bridge a simulated radio into that data
path or supply DHCP, DNS, TCP, TLS or a Wi-Fi settings application.

## Isolated protected acceptance

The dedicated kernel option `wifi_acceptance=true` selects the test backend and
protected acceptance caller. The caller exits with
status 45 after testing scan, authentication policy, lifecycle and authority,
then returning the radio to disabled state. The kernel verifies that state before
its native-process cleanup checkpoint. Normal images do not select this backend.

The trusted Wi-Fi probe image may use up to four code pages, one data page and
four stack pages through the existing validated `TaskMemory` path. That
allowance is selected for the kernel's known image; an app-supplied ELF cannot
widen its own layout. Payload allocation charges use the actual page counts and
are released with the process's context/address-space/owner teardown.

A separate `wifi_absence_probe=true` acceptance variant keeps
`wifi_acceptance=false` and exercises the actual production unavailable-radio
path. Its protected caller has observation permission and no control permission;
the caller must observe an unavailable, nonsimulated status and be denied changes.
This variant also exits 45. It does not replace the production path with a fake
physical device.

[tools/test-wifi.py](../tools/test-wifi.py) launches the three named UEFI QEMU
profiles with networking disabled. Each run formats a new, exclusively owned
temporary data image. Firmware code is read only; variable-store and ESP writes
use private snapshots. The harness starts no Ethernet peer and accesses no
ordinary user data disk, host network, access point or physical adapter. Its
80-second timeout kills and reaps only its owned QEMU process.

The CLI takes `architecture qemu esp code variables`, then optional
`--radio simulated|absent` (default simulated), `--mode debug|safe`,
`--artifacts DIR` and `--timeout SECONDS`. Receipts and logs default to
`zig-out/wifi-tests/{debug,safe}/wifi-{arch}...`; absent-radio files use
`wifi-{arch}-absent...`. Every receipt, including a failed run, explicitly records
the radio mode and `physical_supported=false`. Only simulated-radio receipts set
`simulated=true`; absent-radio receipts set it false and identify their backend as
`physical-driver-unavailable`.
Passing receipts require exact protected-caller/control-cleanup checkpoints and
the expected emulator exit, reject panic/fault output, and contain SHA-256 hashes
of both logs and the boot EFI input. They establish controller/broker execution,
not a physical association or cryptographic Wi-Fi security claim.

## Physical adapter work

The installed QEMU device lists expose Ethernet NICs, including VirtIO, and no
Wi-Fi device for these three references. Bridging guest Ethernet through a
host's Wi-Fi connection would still leave scan, association and credentials under
the host OS. QEMU describes this separation between guest NICs and host network
backends in its [network-emulation documentation](https://www.qemu.org/docs/master/system/devices/net.html).

A credible first physical backend needs one named adapter, bus, hardware
revision, board and firmware version. A FullMAC device can delegate wireless
management to its firmware; a SoftMAC device requires more host management.
These are distinct driver models, as described by the
[Linux Wireless project](https://wireless.docs.kernel.org/en/latest/en/developers/documentation/cfg80211.html).
Either path needs safe discovery and register mapping, owned DMA/bus transfers,
reset/cancellation, firmware protocol validation, radio/channel/regulatory state,
real scan/association events and a verified security/key-management path. USB,
SDIO or SPI adapters first require their respective host transport. An Ethernet
frame callback alone implements none of those control functions.

The locally identified MediaTek MT7922/RZ616 (`14c3:0616`) is the first translation
target, with no operational Bedrock support claim. Upstream Linux's pinned
[mt7921e PCI driver](https://github.com/torvalds/linux/blob/7d0a66e4bb9081d75c82ec4957c50034cb0ea449/drivers/net/wireless/mediatek/mt76/mt7921/pci.c)
matches that ID, maps BAR0, enables bus mastering/IRQ handling and requests
**32-bit DMA**. It also initializes data, MCU and firmware-download queues and
performs hardware reset and firmware/driver power ownership. Bedrock now has
read-only generic PCI inventory on x86-64, explicit verified ECAM access for other
platforms, protected-range checks and generational DMA leases. Its owned MT7922
transport binds real polling rings and validates exact firmware inputs. Platform
clock/coherency policy, calibration, regulatory/MAC setup and complete control/data
integration are still required before physical use.

The pinned [MT792x definitions](https://github.com/torvalds/linux/blob/7d0a66e4bb9081d75c82ec4957c50034cb0ea449/drivers/net/wireless/mediatek/mt76/mt792x.h)
identify `mediatek/WIFI_RAM_CODE_MT7922_1.bin` and
`mediatek/WIFI_MT7922_patch_mcu_1_1_hdr.bin`. This is an mt76/mac80211 driver path,
not a ready-made FullMAC Ethernet adapter. The isolated Zig translations preserve
ISC or selected BSD notices and immutable provenance. Shared original 802.11 code
implements WPA2 derivation, bounded authentication/association wire helpers and
the CCMP four-way handshake, including GTK unwrap and no key reinstall on replay.
No vendor firmware blob is included in boot images. See
[driver translation scope](wifi-driver-porting.md) for exact implemented subsets,
source/firmware licenses, cache-only reference checks and remaining radio gates.

Qualification must then prove cold reset, bounded scan/cancel, real association,
security failure/recovery and data exchange on the named physical machine.
Successful cross-compilation or simulated QEMU execution cannot qualify a radio.
The [project overview](../README.md) and
[support matrix](support-matrix.md) retain the wider hardware and application
scope; the public/private package READMEs describe their separate API roles.

## Verification

Debug and ReleaseSafe each passed **269/269 aggregate build steps** across
native tests, three-architecture compile checks, UEFI smoke checks, networking,
Wi-Fi and desktop acceptance. The default Debug build/install passed **202/202**.
Component native suites passed per mode: NetworkKit **27**, NetworkCore **23**,
the Wi-Fi syscall boundary **10** and pure wire decoding **7**. NetworkKit and
NetworkCore each passed six PIC freestanding probes across the three ISAs and
both modes. Aggregates include unchanged cached suites; the final Safe run
executed 103/103 native cases, which is not a complete test-inventory count.

All **twelve dedicated protected Wi-Fi boots** passed: six simulated-radio and
six production unavailable-radio runs, covering x86-64, ARM64 and RV64 in both
modes. Every caller completed its variant's authority/lifecycle checks, exited
45 and reached checked radio state and native-process cleanup. The same runs
passed six real UDP boots and six two-boot Files workflows: twelve desktop
boots, twenty-four client starts and twelve checked closes.

The aggregate receipt is `.zig-cache/wifi-verification.json`; it verifies all
twelve Wi-Fi receipts and their boot/log hashes, the network/Files receipts and
source/installed hashes. Per-run Wi-Fi receipts and logs are under
`zig-out/wifi-tests/{debug,safe}/wifi-{arch}...`, with `-absent` names for the
production unavailable variant. All twelve record `physical_supported=false`;
only the six simulated-radio receipts record `simulated=true`. Physical radio
access and physical WPA authentication tests total **zero**.

Reproduce from the workspace root:

```text
zig build test check test-uefi test-network test-wifi test-desktop -j2 --summary all
zig build test check test-uefi test-network test-wifi test-desktop -Doptimize=ReleaseSafe -j2 --summary all
zig build -j2 --summary all
```

`zig build test-wifi` runs both radio variants on all three architectures;
`test-wifi-x86_64`, `test-wifi-arm64` and `test-wifi-riscv64` select one. These
results establish the stated control/broker boundary on named QEMU references.
No physical Wi-Fi adapter, access-point association or WPA2 implementation is
qualified.
