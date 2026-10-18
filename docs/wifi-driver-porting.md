# Wi-Fi driver translation boundaries

Bedrock is translating selected Linux Wi-Fi protocols into native Zig components. The source pin is Linux **v6.18**, commit **`7d0a66e4bb9081d75c82ec4957c50034cb0ea449`**. Ported format code and PCI identification are distinct from a functioning radio. The existing explicit simulated Wi-Fi acceptance path continues to test SDK authority and asynchronous controller behavior; it does not qualify physical cards.

Use these terms for support claims:

| Stage | Required evidence |
| --- | --- |
| Identified | A source-backed vendor/device match; no assumption that the device works. |
| Protocol ported | Real format/command logic translated, bounded malformed-input tests, and target compilation. |
| Hardware bring-up | Device-owned DMA, interrupts, firmware boot and meaningful hardware completion evidence on a named card. |
| RF qualified | Real scan, authenticated association and data exchange, with regulatory, failure and recovery checks on named hardware/firmware. |

Neither native synthetic fixtures nor the simulated radio establish the last two stages. A CPU target compiling a driver does not establish that every machine with that CPU exposes the same PCI host bridge, DMA policy or radio.

| Component | Implemented scope | Current hardware evidence |
| --- | --- | --- |
| PCI/resource adapters | Bounded configuration inventory, BAR address decoding and explicit mapped-MMIO/DMA lease boundaries. | Reference-platform compilation and software tests; no physical card qualification. |
| MediaTek MT7922 | Register/reset/firmware protocols, six owned WFDMA queues, NIC/EFUSE/MAC/interface/peer/channel commands, passive surveys, separate TX_FREE/TXS and station integration. | Protocol/format tests and software register/completion traces; no observed physical firmware boot or association. |
| Intel targeted iwlwifi families | PCI identification and shared TLV container inspection. | No implemented Intel hardware backend. |
| Realtek RTL8852A/B/C | PCI identification, v0/MFW format inspection and H2C framing. | Cache-only format-reference checks; no implemented Realtek hardware backend. |
| Shared 802.11/WPA2 helpers | Beacon/RSN/PHY metadata, MAC association, PSK/four-way handshake, wrapped GTK, software CCMP, Ethernet bridge and independent packet replay protection. | Portable protocol/crypto/station tests; no physical protected data traffic. |

The MediaTek implementation follows the pinned [PCI](https://github.com/torvalds/linux/blob/7d0a66e4bb9081d75c82ec4957c50034cb0ea449/drivers/net/wireless/mediatek/mt76/mt7921/pci.c), [MCU transport](https://github.com/torvalds/linux/blob/7d0a66e4bb9081d75c82ec4957c50034cb0ea449/drivers/net/wireless/mediatek/mt76/mt7921/pci_mcu.c), and [DMA source](https://github.com/torvalds/linux/blob/7d0a66e4bb9081d75c82ec4957c50034cb0ea449/drivers/net/wireless/mediatek/mt76/dma.c). Caller-owned rings require actual coherent DMA/cache maintenance and real device completion before leases can be reclaimed. A failed stop must retain exposed memory. None of this changes the production Wi-Fi controller's unavailable state into a simulated connection or a hardware success claim.

## MediaTek and shared backend prerequisites

[MediaTek's standalone subset](../drivers/wifi/src/mediatek/README.md) passed **37 executed native checks per mode**, all six PIC target probes, and one separate pinned real-firmware format check per mode. Hardware RX parsing bounds metadata groups and raw management frames. TXWI/TXP serialization supports unencrypted management and three-address station-to-AP non-QoS data/EAPOL; FromDS, WDS, QoS, fragmented, protected and ordered forms are rejected. TX_FREE codecs track wire tokens; a transport must retain payload memory beyond WFDMA consumption until a validated TX_FREE resolves its live owner, or reset proves quiescence. Scan serialization uses explicit caller-approved channels and never-reused sequence IDs; a submitted cancellation is not proof of firmware/RF cancellation.

The [owned polling transport](../drivers/wifi/src/mt7922_transport.zig) prepares stable, generational DMA leases and disjoint zeroed buffers after read-only identity/BAR checks. It owns four control rings: WM TX, firmware-download TX, boot-ROM MCU-event RX, and normal-firmware MCU-response RX. All are posted before DMA enable; MCU responses switch to the second RX ring only after firmware loading completes. Preparation rejects a function with inherited bus mastering still enabled and makes no PCI/MMIO writes. A trusted platform must provide a verified aperture, exclusive function ownership, actual timing, a valid CPU/DMA view and coherent cache/barrier hooks. Native MMIO/ECAM aperture initialization rejects protected-memory aliases and incomplete mapped coverage; informational RAM-envelope holes remain possible device apertures.

Explicit `start` requires the documented intact patch/RAM hashes before register activity, revalidates its live lease, resets the device, publishes rings, and requires firmware readiness. Stop clears bus mastering and confirms DMA quiescence before freeing exposed storage; failed stop/free retains a retryable owner. It never restores an inherited bus-master bit. This source path is compiled and its ownership/failure boundaries use fake providers in native tests; it is not enabled as a production radio backend and no physical firmware execution was performed.

Stop rejects activation, nested teardown and in-flight ring/MCU or delegated DMA callbacks. Successful and partially initialized I/O objects are retired before storage is released. Guarded DMA hooks check the live generational lease before descriptor/payload access and after cache callbacks, so copied rings cannot touch a recycled allocation. The transport and validator context must remain alive and in place, without reinitialization, while any borrowed references exist. Caller serialization and actual platform coherency remain required; standalone rings without a validator require their borrowed storage to stay live.

A usable named MT7922 backend still needs a platform boot provider for actual
firmware/MMIO/DMA/timing, genuine board calibration/SAR/antenna/rate facts,
secure entropy and physical acceptance. The [station integration](wifi-station.md)
now supplies bounded NIC/MAC/interface/WTBL initialization, six data/control
queues, polled event routing, management/EAPOL, software CCMP/replay handling and
explicit SDK/static-IPv4 glue. Hardware key programming is a separate codec;
the raw software profile does not silently use it. Automatic recovery/rebinding,
roaming and automatic IP configuration remain pending. The [regulatory layer](wifi-regulatory.md)
supplies pinned country facts, conservative decisions, protected snapshots and
actual CLC/channel/rate-power submission; firmware enforcement and RF behavior
remain physical gates. Named-card evidence must precede an operational claim.

[Shared IEEE helpers](../drivers/wifi/src/ieee80211/README.md) passed **27 executed native checks per mode** and six PIC probes. The four-way station derives keys from a caller PMK and fresh trusted SNonce, validates the pinned peer/RSNE, authenticates and unwraps M3 key data, then invokes a synchronous installer and produces M4. Its `complete` state means authenticated M3 plus successful installer return; M4 delivery and radio connectivity remain separate. Authenticated retransmissions do not reinstall keys or reset packet numbers. Copy/move rejection protects the live station's installer ownership; failed partial-key cleanup requires a trusted device reset. AES key-data integrity follows [RFC 3394](https://www.rfc-editor.org/rfc/rfc3394).

Entropy, exchange deadlines, actual association/key-install/transmit completions and backend recovery remain required caller responsibilities. Native fake installer success proves portable control logic, not device key programming or RF authentication. This bounded WPA2-PSK/CCMP profile does not implement SAE/WPA3 authentication, enterprise EAP or general protected-management support.

## Intel

[The Intel module](../drivers/wifi/src/intel/README.md) contains a bounded firmware TLV parser and a targeted PCI family inventory. Intel's pinned format uses an 88-byte little-endian header followed by length-delimited, four-byte-padded records. The port decodes section-offset images, CPU/paging delimiters, flags, API/capability words and version metadata. It rejects unsupported legacy layouts and bounds every referenced input extent. Unhandled metadata remains opaque. Parsing does not authenticate firmware or make its section addresses safe for DMA. [Pinned format](https://github.com/torvalds/linux/blob/7d0a66e4bb9081d75c82ec4957c50034cb0ea449/drivers/net/wireless/intel/iwlwifi/fw/file.h), [upstream parser](https://github.com/torvalds/linux/blob/7d0a66e4bb9081d75c82ec4957c50034cb0ea449/drivers/net/wireless/intel/iwlwifi/iwl-drv.c).

The inventory covers device IDs for 7260, 3160, 3165, 3168, 7265, 8260/4165, 8265 variants, AX200 and AX210. These are **identified** families with **protocol-ported** shared container inspection. Every profile explicitly reports `hardware_backend=false`; none is RF qualified. Subsystem IDs, MAC/RF revision and NVM can affect exact selection. AX201/AX211 and arbitrary Intel devices are not inferred from an AX200/AX210 match. [Pinned PCI table](https://github.com/torvalds/linux/blob/7d0a66e4bb9081d75c82ec4957c50034cb0ea449/drivers/net/wireless/intel/iwlwifi/pcie/drv.c).

Upstream 7000/8000 and AX generations use different transport/configuration paths. A useful hardware backend still needs PCI resource ownership, reset/power sequencing, DMA descriptors and coherent buffers, interrupt completion, firmware loading/ALIVE handling, command queues, receive/transmit processing, NVM/calibration, regulatory policy, authentication/key installation, and recovery. Bedrock has not implemented those Intel transport paths. [7000 configuration](https://github.com/torvalds/linux/blob/7d0a66e4bb9081d75c82ec4957c50034cb0ea449/drivers/net/wireless/intel/iwlwifi/cfg/7000.c), [8000 configuration](https://github.com/torvalds/linux/blob/7d0a66e4bb9081d75c82ec4957c50034cb0ea449/drivers/net/wireless/intel/iwlwifi/cfg/8000.c), [AX200 configuration](https://github.com/torvalds/linux/blob/7d0a66e4bb9081d75c82ec4957c50034cb0ea449/drivers/net/wireless/intel/iwlwifi/cfg/22000.c), [AX210 configuration](https://github.com/torvalds/linux/blob/7d0a66e4bb9081d75c82ec4957c50034cb0ea449/drivers/net/wireless/intel/iwlwifi/cfg/ax210.c).

The initial Intel parser passed **15 executed native checks per optimization mode** in Debug and ReleaseSafe, and all six PIC compilation probes for x86_64, ARM64 and RISC-V64. Tests exercise unaligned borrowed bytes, truncation, lengths, bitmap bounds, metadata ambiguity, section overflow/overlap, delimiters and capacity limits. These are format and compilation checks, not hardware boots.

## Realtek

[The rtw89 module](../drivers/wifi/src/realtek/README.md) identifies RTL8852A/B/C PCI families and ports real v0 firmware inspection plus H2C wire framing. It validates multi-image wrapper extents, selects the closest compatible non-MP cut, bounds the selected section table and dynamic-header aggregate, and preserves borrowed sections/checksum trailers/signatures. Version 1 and formatted MSSC are rejected. Opaque metadata and the raw image signature do not establish chip identity or firmware authenticity; exact profile/file/hash selection remains trusted caller policy. No Realtek hardware backend is supplied. [Pinned format](https://github.com/torvalds/linux/blob/7d0a66e4bb9081d75c82ec4957c50034cb0ea449/drivers/net/wireless/realtek/rtw89/fw.h), [upstream parser and H2C encoder](https://github.com/torvalds/linux/blob/7d0a66e4bb9081d75c82ec4957c50034cb0ea449/drivers/net/wireless/realtek/rtw89/fw.c).

The inventory covers `10ec:8852/a85a`, `10ec:b852/b85b`, and `10ec:c852`; these identify RTL8852A, B and C respectively. It does not infer RTL8852BT, USB variants or all Realtek cards. [A PCI source](https://github.com/torvalds/linux/blob/7d0a66e4bb9081d75c82ec4957c50034cb0ea449/drivers/net/wireless/realtek/rtw89/rtw8852ae.c), [B PCI source](https://github.com/torvalds/linux/blob/7d0a66e4bb9081d75c82ec4957c50034cb0ea449/drivers/net/wireless/realtek/rtw89/rtw8852be.c), [C PCI source](https://github.com/torvalds/linux/blob/7d0a66e4bb9081d75c82ec4957c50034cb0ea449/drivers/net/wireless/realtek/rtw89/rtw8852ce.c).

Realtek's subset passed **14 executed native checks per mode** and six PIC probes. Another **three format-reference checks per mode** passed against intact RTL8852A/B/C files at linux-firmware commit `afabaf773c4c2e2c841429933a6a084a5af4d14d`, including real dynamic headers. These separate binary references stay in the local cache; [their manifest](../drivers/wifi/src/realtek/firmware-references.json) records exact hashes. No instructions were executed or disassembled. This advances protocol validation, not hardware bring-up or RF qualification.

## Licensing and firmware

Each inspected Intel source at this exact commit offers **GPL-2.0 OR BSD-3-Clause**. The isolated Intel translation selects BSD-3-Clause and retains original notices, license conditions and the disclaimer in its [NOTICE](../drivers/wifi/src/intel/NOTICE.md) and [LICENSE](../drivers/wifi/src/intel/LICENSE). Its [provenance manifest](../drivers/wifi/src/intel/upstream.json) records immutable URLs and SHA-256 hashes. This does not change the OS-wide license. [Pinned license text](https://github.com/torvalds/linux/blob/7d0a66e4bb9081d75c82ec4957c50034cb0ea449/LICENSES/preferred/BSD-3-Clause).

The inspected rtw89 sources also offer GPL-2.0 OR BSD-3-Clause; the Realtek subset selects BSD and retains its own [notices](../drivers/wifi/src/realtek/NOTICE.md), [license](../drivers/wifi/src/realtek/LICENSE) and [source hashes](../drivers/wifi/src/realtek/upstream.json). Its separate firmware reference license permits intact binary use/redistribution under conditions and forbids reverse engineering/disassembly. Container inspection follows the published Linux source definitions. No firmware blob is shipped by this port. [Separate firmware license](https://gitlab.com/kernel-firmware/linux-firmware/-/raw/afabaf773c4c2e2c841429933a6a084a5af4d14d/LICENSES/LICENCE.rtlwifi_firmware.txt).

Pinned MediaTek mt76 reference files inspected for this work carry ISC notices; per-file provenance remains necessary because other revisions can differ. Future GPL-only translations must retain their own GPL notices and scope, rather than relabeling unrelated files. Source-code licenses do not automatically license separate firmware blobs. Packaging firmware needs its own redistribution review. [Pinned MediaTek PCI source](https://github.com/torvalds/linux/blob/7d0a66e4bb9081d75c82ec4957c50034cb0ea449/drivers/net/wireless/mediatek/mt76/mt7921/pci.c).

Physical hardware acceptance remains pending. The next hardware gate must name the exact PCI/subsystem IDs, revision, firmware hash/version, transport resources, regulatory setting and observed failures/recovery before claiming card support.

## Integrated verification

With Zig 0.17.0, the preceding driver-port workspace Debug and ReleaseSafe runs each passed
**277/277 build steps** across `test check test-uefi test-network test-wifi
test-desktop`. The integrated driver suite passed **116 native checks per mode**;
package counts above include their own transitive checks and are not additive.
`check` emits six complete driver probes per mode: baseline and PIC for x86-64,
ARM64 and RV64, with strict-alignment ARM64 and integer RV64 runtime PIC profiles.
The independent kernel package passed **46/46 steps** in Debug. Default workspace
build/install passed **208/208 steps**. Aggregate summaries include cached
unchanged checks.

The same gates passed twelve protected Wi-Fi control boots (six explicitly
simulated, six production-unavailable), six UDP boots and twelve Files desktop
boots. Their receipts are checked against log/boot-image hashes; none accessed a
physical radio. Default EFI images exclude the fake test passphrase strings and
sampled vendor firmware data. No vendor firmware is packaged by the build.

The optional intact-file checker passed **19 checks per mode**: accepted the
pinned MediaTek pair, rejected seventeen mutations/truncations/extensions/wrong
pairs and revalidated the originals. It opens only explicit local inputs and
never submits firmware to a device. With no inputs it skips without opening files.

```text
zig build test-wifi-drivers
zig build test-wifi-firmware -Dwifi-patch-reference=PATCH_PATH -Dwifi-ram-reference=RAM_PATH
```

The local `.zig-cache/wifi-driver-verification.json` receipt records source,
artifact, log and workflow hashes. **Operational hardware backends: zero.** The
missing integration gates in this document remain required; compilation, fixture
completion, firmware-format checks and WPA2 test exchanges cannot establish
real scan, association or protected data traffic.

The subsequent [regulatory implementation and acceptance](wifi-regulatory.md)
passed 149 integrated driver checks per mode and all-three-architecture probes,
with 237/237 steps per mode for its boot/control regression gate. Its separate
receipt preserves the current regulatory source hashes and software scope.

The later [native station path](wifi-station.md) extends those protocols through
MAC/WPA2/CCMP, actual data/status queues and trusted kernel attachment. Its
separate final receipt records the latest source/build/control checks and the
remaining hardware inputs. **Operational hardware backends remain zero.**
