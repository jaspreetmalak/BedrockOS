# MediaTek MT7922 protocol port

This directory translates selected MediaTek Linux driver mechanisms into native
Zig. Linux **v6.18**, immutable commit
[`7d0a66e4bb9081d75c82ec4957c50034cb0ea449`](https://github.com/torvalds/linux/tree/7d0a66e4bb9081d75c82ec4957c50034cb0ea449/drivers/net/wireless/mediatek/mt76),
is the source baseline. Each translated source carries its ISC SPDX identifier
and copyright attribution; [LICENSE](LICENSE) contains the complete permission
notice. [PROVENANCE.json](PROVENANCE.json) records source paths, exact SHA-256
hashes, selected mechanisms and deliberate hardening changes. No Linux kernel
APIs or GPL-only source are included in this translation.

The implemented portions are register access, 32-bit WFDMA rings, firmware
parsing/download, hardware packet codecs, legacy scan commands and regulatory
command encoding/submission, NIC/interface/peer control and global MAC register
setup. They are
device-protocol code, with no qualified physical radio or automatic production
backend. QEMU's VirtIO Ethernet cannot exercise this hardware. Replay tests prove
bounded protocol/state behavior; firmware parsing tests prove acceptance of the
pinned real blob formats. Neither establishes RF operation or WPA authentication.

## Interfaces and ownership

Import `root.zig` as one private module. `Registers.init(Mmio)` requires a mapped
BAR0 span of at least 1 MiB, offset-based `read32`/`write32`, `fence` and
`begin`/`end` transaction callbacks. The provider must serialize every device
access, including interrupts. Fixed remaps use half-open ranges; unsupported and
unaligned addresses fail. Dynamic L1 remapping preserves reserved bits, flushes
the write with readback and holds the transaction until the target access ends.

`Driver.init(Registers, Clock)` is retained in place before creating rings:

1. `driverOwn()` performs firmware/host ownership exchange and checks MT7922 ASIC
   identity/revision.
2. `reset()` disables DMA, waits for idle, resets the logic and wireless subsystem
   with the prescribed delay and initialization-ready polling.
3. Initialize the caller-owned WM TX, FWDL TX and MCU-event RX rings with
   `dma.Ring.init(&driver.registers, Config, Hooks)` while DMA is disabled.
4. `configureDma(wm, fwdl, event)` checks disjoint storage and ring identities,
   configures prefetch and enables DMA while keeping IRQ delivery disabled.
5. Initialize a retained `mcu.DmaChannel{wm,fwdl,event}` and a retained `Mcu`
   **in place** with `mcu.init(binding.channel())`. `loadFirmware(mcu, patch, ram)`
   preflights both complete formats, sets normal firmware mode, issues the real
   patch-semaphore/download/scatter/finish/release/start commands, then requires
   the hardware firmware-ready bits.
6. `stop()` must successfully disable/reset DMA before the caller frees any
   backing lease. Failed stop retains all resources; it is not safe rollback.

`snapshot()` reports the stage and identified ASIC. `firmware_ready` is a startup
stage, never a connected, authenticated or operational-radio state. PCI decode,
bus mastering, mappings, interrupt controller setup and coherent DMA ownership
belong to the caller. `Clock.delayUs` must supply actual bounded hardware time;
test callbacks explicitly model it.

`Driver.initMac()` explicitly configures the pinned MDP receive limit, clears
admission counters for all 20 WTBL slots with bounded busy polling, and initializes
both MAC bands' deadline, receive-time, duration and RCPI registers. Each ordinary
masked write gets readback verification. This raw software-CCMP profile disables
global Ethernet header translation and leaves RX group-5 reporting disabled,
preserving the source workaround. `snapshot().mac_initialized` records register
setup only. Partial failures move the driver to `failed`; no initialized claim
survives a failed write or stuck WTBL. EEPROM mode, MCU RX-path, RTS and MAC-enable
commands are separate caller-controlled steps.

`nic.decodeCapabilities` validates the actual `GET_NIC_CAPAB` (`0x8a`) event:
required unicast MAC and 12-byte PHY facts, optional 6 GHz/chip capabilities,
bounded TLV counts and lengths, and no duplicate known fields. NSS, hardware path
and raw bandwidth codes are firmware facts. They do not supply calibrated
conducted power, SAR, antenna gain or country permission.

Retain a zero-owner `nic.Client` with a live shared `Mcu`. The strict
`init(mcu,epoch,prior_sequences)` mode never reuses a 4-bit ID from its supplied
history and can exhaust. Explicit `initReusable(mcu,epoch)` follows the source's
serialized IDs 1–15: the trusted caller establishes an initially drained RX
queue, no pending competing command and a serialized MCU. Each successful call
consumes its matching response. These IDs provide correlation, not cryptographic
anti-replay. The client rejects copies, overlapping control storage and active
MCU access; timeouts, I/O failures or malformed/rejected matching replies poison
the shared MCU until independently confirmed reset and a newer device epoch.
`Events.other` routes asynchronous MCU events and non-event hardware packets such
as TX_FREE before command correlation, while the MCU remains busy. Its packet is
borrowed and must be consumed or copied synchronously.

The client supplies actual device/BSS/station, 20 MHz channel/RLM, EFUSE query/mode,
RX-path, RTS and MAC-enable commands. The initial peer profile is a single
2.4/5 GHz infrastructure station with legacy, non-QoS rates, no aggregation/HT,
and raw 802.11 WTBL receive framing. Device/BSS/station/hardware-key unified
responses must echo the command ID with status zero. Legacy channel/RX-path/
EFUSE-mode/MAC-enable/RTS replies follow the source's matched-response convention:
`ResponseProof.status` is null, with no fabricated status or RF outcome.
EFUSE reads check the echoed aligned address and return the untouched 16-byte
block plus its raw validity word for trusted board policy to interpret.

`nic.encodeCcmp` and `Client.ccmp` provide explicit CCMP-128 hardware key install/
removal records and verified unified responses. They do not initialize replay
PNs or prove a remote handshake. Input/output aliases fail before writes; the
client volatile-clears its own host key scratch on success and failure. Separate
DMA and immutable caller copies have their own ownership. The software-CCMP raw
profile leaves device hardware keys/cipher off and uses the separate authenticated
software key/PN owner. It does not call this optional hardware-key method.

DMA `Buffer` values borrow owned memory and contain device-visible addresses.
`Config.validate()` rejects zero/wrapping/above-4-GiB ranges, insufficient descriptor
storage and overlapping buffers. Rings use little-endian 16-byte descriptors,
at most 64 entries, actual DMA completion and bounded polling. Cache maintenance
and release/acquire barriers are provider hooks. `Hooks.validateLease` optionally
resolves the owner's live generation before initialization, send/receive and
descriptor or packet-memory
access; it also protects copied rings after the original is stopped and its
storage recycled. Its callback context must outlive those copies. Without the
callback, raw callers must retain all borrowed storage themselves. A short RX
destination retains the completion; malformed descriptors or TX timeouts stop
the ring. WM buffers
must fit at least the 1,250-byte scan packet; the general MCU payload bound needs
4,160 bytes. FWDL buffers need 4,096 bytes. MCU-event RX buffers need at least the
384-byte scan completion, with 4,096 bytes recommended.

`firmware.parsePatch/parseRam` return borrowed, validated regions, with at most
32 regions and an 8 MiB image bound. Patch fields are big endian; RAM trailers
and regions are little endian. Unsupported section/encryption/compression/format
and overflowing extents fail before slicing. Non-download CLC data and auxiliary
metadata are preserved without sending them as executable regions. Parsed
checksum fields are not a software integrity or authenticity check: provisioning
must enforce the pinned image hashes or another trusted firmware policy.

`mac.management` checks the hardware packet kind/length, optional RX group
extents, FCS/error flags, header padding and raw Beacon/ProbeResponse form. It
returns a borrowed IEEE frame, BSSID, decoded band/channel and available RCPI
signal. These can feed Bedrock's separate IEEE 802.11 management/RSN parser.
Translated Ethernet headers, aggregation and protected/fragmented management
frames are rejected. `mac.transmit` encodes a single unencrypted, nonaggregated
802.11 TXWI plus hardware TXP using a caller-owned 32-bit DMA payload and token.
It supports a 24-byte three-address station-to-AP ToDS data header, including
unencrypted EAPOL payloads; management frames require zero DS bits. FromDS/WDS,
QoS, fragmentation, protected frames and extra ordered headers remain rejected.
**WFDMA completion does not release that payload**: retain TXWI/payload leases
until a validated `mac.transmitFree` token resolves the live ownership record,
or hardware reset confirms quiescence. TX status is not remote application
delivery, and the codec does not install encryption keys.

`scan.encode` writes the source-backed 1,186-byte legacy request with explicit
caller-approved channels, up to four SSIDs and checked information elements.
`scan.Session.start` submits it through the real WM DMA channel, and
`completed` accepts only the matching bounded hardware completion. Scan
sequences are never reused: the bounded namespace exhausts after 127 issues.
`cancelRequest` submits cancellation and invalidates the local pending operation;
submission is not confirmed firmware/RF cancellation. Unified-MCU scan events,
scheduled scans and a complete radio backend are outside this implementation.

`regulatory` encodes the pinned legacy CE commands `SET_CLC` (`0x5c`),
`SET_CHAN_DOMAIN` (`0x0f`) and `SET_RATE_TX_POWER` (`0x5d`). The domain packet
contains a 12-byte header followed by eight bytes per approved channel, grouped
by band. This implementation grants only 20 MHz width; DFS remains `NO_IR`, and
world/6 GHz channels must be explicitly passive. Indoor-only channels cannot
initiate outside a confirmed indoor environment. `DeviceCapabilities` requires
actual per-channel hardware ceilings. `ChannelLimit.max_power_mbm` is the
**conducted** ceiling after EIRP, antenna gain, hardware and board/SAR limits.
Country selection and legal authority belong to the common policy layer.

`PowerChannel` supplies all 161 signed half-dBm rate entries and a trusted board
ceiling. The encoder checks every entry against the minimum conducted ceiling,
rounding negative mBm down, and sends at most eight channels per 44-byte-header
batch. It does not synthesize calibration, antenna gain, SAR data or a permissive
all-rates table. `Clc.fromRam` selects authentic non-download firmware data;
`Clc.parse` validates each older-format block/rule, matches the actual EEPROM
encapsulation variant and selects exact country rules without silent fallback.
The CLC packet is a 76-byte header plus the unchanged vendor rule payload.

Create `var session: regulatory.Session = .{};`, then call `init(epoch)` once
in place. `submit(mcu, Plan)` validates the complete CLC/domain/rate policy
before generation issuance or I/O, then submits CLC, domain and power commands
in that order. Sessions reject copies, reinitialization, stale device epochs
and non-increasing policy generations. Invalid inputs leave prior session
metadata unchanged; an error after submission starts revokes the prior claim
and requires independently confirmed hardware reset with a newer epoch.
`invalidate()` revokes a submission without reusing its generation.
`isSubmitted(epoch,generation)` describes only **DMA consumption**. No firmware
acknowledgement, effective channel mask or permission to radiate is inferred.
Caller-owned plan and CLC storage must stay immutable throughout the serialized
operation, and the MCU/channel must belong to that same live device epoch.

The pinned 2026 firmware CLC region contains index-0 power records and newer
index-3 records. This v6.18-format port preserves the latter as bounded opaque
blocks, without interpreting them as channel authority. Real-blob tests select
seven US power rules for either EEPROM variant; they establish format handling
only. Confirmed CLC responses/UNII restrictions, NIC/EEPROM calibration and
board/ACPI limits remain prerequisites for a qualified radio backend.

A backend must complete and verify NIC capability, EEPROM/calibration,
CLC/regulatory and channel/power policy, interface/WTBL/MAC setup, caller-owned
data/event queues and asynchronous routing before advertising readiness. The
commands and replay-tested register mechanisms here cannot replace physical
qualification. Association, authenticated key/PN ownership, remote TX outcome,
link-loss handling and IP integration remain separate proof requirements. The
primitive scan sender does not bypass them. The source RX limit is 1,536 bytes;
full-size Ethernet plus raw CCMP overhead requires separate hardware RX-limit
qualification before advertising a general 1,500-byte physical Ethernet MTU.

## Real firmware provenance

The official [linux-firmware repository](https://gitlab.com/kernel-firmware/linux-firmware)
was pinned to `afabaf773c4c2e2c841429933a6a084a5af4d14d` for validation:

| File | Version | SHA-256 |
| --- | --- | --- |
| `mediatek/WIFI_RAM_CODE_MT7922_1.bin` | `20260724143402` | `d100e5e04c324fc8da6302112d1e0b4fac952286447d2419eabcd8fb0a1f5b93` |
| `mediatek/WIFI_MT7922_patch_mcu_1_1_hdr.bin` | `20260724143257a` | `7fc9075d6d54b31e0539734614ca971fa52caf41b642a3000c8a4501591a4d98` |

The pinned WHENCE section identifies `LicenseRef-LICENCE.mediatek`. Its
[LICENSES/LICENCE.mediatek](https://gitlab.com/kernel-firmware/linux-firmware/-/blob/afabaf773c4c2e2c841429933a6a084a5af4d14d/LICENSES/LICENCE.mediatek)
permits use and redistribution for MediaTek chipsets while excluding inclusion
under terms requiring the blobs themselves to become GPL/LGPL covered. Firmware
is cached separately for host parser validation, and no blob is embedded or
executed on hardware by this module. A future firmware distribution must retain
the vendor license and provenance separately from the ISC driver code.

## Verification

Independent checks passed **68/68 native cases** in both Debug and ReleaseSafe,
all six PIC freestanding API probes and separate real-blob parser/CLC cases in
each mode. These counts describe protocol/model checks, with zero physical
radio executions.

Native tests cover firmware/header bounds, endian golden vectors, locked remap
readback/errors, DMA publication/completion/short-output/timeout behavior,
retired-lease rejection before recycled-memory access, firmware command order,
staged reset/stop and malformed MAC/scan packets. Regulatory tests cover exact
wire offsets, negative power rounding, restrictive channel flags, authentic CLC
selection, preflight atomicity, every modeled command failure boundary and
copied/stale session rejection.
NIC cases cover literal capability TLVs, exact command/TLV offsets, real matching
responses, negative/timeout paths, sequence reuse/history limits, copied/aliased
owners, host key wiping, EFUSE address matching and asynchronous TX_FREE demux.
Global MAC replay covers both bands, unrelated-bit preservation, readback no-op
failures, I/O failures and bounded WTBL stalls.
`compile_check.zig` forces the runtime APIs through x86-64, strict-aligned ARM64
and integer-only RV64 PIC compilation. The separate real-blob host test checks
the six RAM regions, five downloadable regions, 144-byte auxiliary metadata,
non-download CLC region and AES patch at `0x900000`. No physical device register,
firmware upload, RF scan or access-point association is used by these tests.
