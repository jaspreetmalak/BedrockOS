# Native MT7922 station path

The native Zig path now joins the chipset protocol, retained packet queues,
association, WPA2-PSK, software CCMP, SDK controller and bounded IPv4/UDP stack.
It is **software implemented and tested; physical Wi-Fi is still unfinished**.
Normal UEFI boot acquires pinned firmware and EFI RNG inputs. When an installed
driver module matches the hardware, kernel startup enters the module's
configured native x86 path described in [boot setup](wifi-boot-setup.md).
Absent board/platform facts keep controls unavailable. No real scan, association,
transmission, physical firmware execution or RF qualification was performed.

## Components and evidence

| Component | Implemented behavior |
| --- | --- |
| [NIC client](../drivers/wifi/src/mediatek/nic.zig) | Actual capability/EFUSE decoding; device, BSS, peer, channel, RLM, MAC/RX-path and optional hardware CCMP key commands. Unified replies require matching command/sequence and status zero. Legacy replies prove correlation only, with explicit null status. |
| [MAC register setup](../drivers/wifi/src/mediatek/nic_registers.zig) | Source-backed RX1536 limit, raw header mode, bounded WTBL counter clearing and both-band register setup/readback. Register phase success is separate from calibration and RF readiness. |
| [Owned transport](../drivers/wifi/src/mt7922_transport.zig) | Six real WFDMA queues: four control queues, data TX0 and main data RX. Generational memory ownership, coherent hooks, actual polling completions and stop-before-free remain required. |
| [Data owner](../drivers/wifi/src/mt7922_data.zig) | TXWI/payload survive descriptor consumption until exact TX_FREE. Separate requested TXS records correlate PID/WCID/MAC sequence and supply ACK evidence. Tokens/PIDs cannot silently wrap into old owners. |
| [Observation](../drivers/wifi/src/observation.zig) | Beacon/probe decoding plus actual RSN, beacon interval, TIM/DTIM and mutually supported legacy rates. Missing mandatory PHY support or metadata is rejected. |
| [Station engine](../drivers/wifi/src/station_link.zig) | Open-system MAC authentication/association, actual WPA2 M1–M4 exchange, secure nonce hook, authenticated key installation, deadlines, typed TX completion, terminal-event ordering, revocation and secret clearing. |
| [CCMP](../drivers/wifi/src/ieee80211/ccmp.zig) | Original AES-CCM protection, exact nonce/AAD/header, software Ethernet bridge, MIC-before-publication, independent pairwise/group replay ledgers and monotonic 48-bit TX packet numbers. Published IEEE packet and RFC CCM vectors are checked. |
| [Native binding](../drivers/wifi/src/mt7922_station.zig) | Actual NIC calls, passive scan cache, selected-peer metadata, policy checks, raw RX/TX, deferred MCU-side frames/completions and bounded packet drops. Received band identity is retained; 6 GHz cannot alias a 2.4 GHz channel number. |
| [Module entry and boot owner](../drivers/mt7922/src/entry.zig) | Separate ELF image keeps the native platform, transport, policy and station owners in module storage; the normal kernel does not import their implementation. |
| [Kernel module adapter](../kernel/src/core/wifi_module_adapter.zig) | Converts copied C ABI events into non-simulated controller events and synchronously delivers copied Ethernet frames to the existing stack. No application country authority or credential retention is introduced. |

The source pin remains Linux v6.18,
`7d0a66e4bb9081d75c82ec4957c50034cb0ea449`. MediaTek's ISC notices and the
[per-file provenance](../drivers/wifi/src/mediatek/PROVENANCE.json) cover
translated command/register formats. Shared station/CCMP/bridge code is original;
the vector attribution is retained in [THIRD_PARTY.md](../drivers/wifi/src/ieee80211/THIRD_PARTY.md).

TX_FREE is resource-release evidence. It never authorizes a connected event.
The station first validates the selected AP's association response, authenticates
M3 and its wrapped GTK, prepares software keys, submits M4, receives correlated
ACK evidence from TXS, and confirms the firmware peer's controlled-port state.
Only then can it emit joined and exchange protected data. A terminal failure
supersedes a join that has not yet reached the SDK controller.

MCU command callbacks run while the shared channel and station are busy. The
binding copies borrowed MCU scratch before routing and defers peer frames/TX
facts until those calls finish. Unrelated/unsupported/FCS-rejected normal frames
are dropped; malformed DMA/completion ownership is an error. Completed teardown
detaches this binding's callback from the retained NIC client.

## Initial supported protocol profile

The binding supports 20 MHz, 2.4/5 GHz, legacy-rate, non-QoS infrastructure
WPA2-PSK/CCMP stations. The SDK adapter advertises WPA2, rather than an open-data
or WPA3 implementation. Software-protected raw MPDUs bypass device encryption;
hardware-decrypted/translated/fragmented/aggregated forms are not accepted by
that profile. Optional hardware-key commands are a separate codec and are not
silently mixed with software CCMP.

The raw binding limits Ethernet frames to 1,280 bytes pending qualification of
the chipset's RX1536 semantics. The existing bounded UDP profile fits this limit.
It is not an unrestricted Ethernet1500, QoS/HT/VHT/HE, roaming, DFS/AFC, 6 GHz,
SAE/WPA3, enterprise EAP or protected-management implementation.

Each data owner issues wire tokens1–32767 without reuse. Requested status IDs
3–255 are bounded and retained independently of payload release; ordinary data
uses TX_FREE release without falsely requesting an ACK for every packet. CCMP
retains 16 key-history entries and never evicts them to reset replay counters.
Capacity or packet-number exhaustion requires explicit lifecycle handling.
The reusable NIC correlation mode follows the firmware's 4-bit sequence wrap;
its trusted caller must serialize and initially drain RX. It is correlation,
not a cryptographic anti-replay mechanism. Errors poison MCU control until a
confirmed newer device reset. There is no invented successful retry.

Disconnect/failure confirms a full transport stop before exposed DMA memory
can be released. This first binding is then retired. Automatic reconstruction
of a new platform transport after that stop, recovery across suspend/resume and
roaming are still pending; there is no automatic re-enable claim.

## Remaining physical platform work

The [boot setup](wifi-boot-setup.md) now supplies firmware storage, secure nonce
generation, a named x86 PCI/cache/DMA/clock provider, and startup/attachment through
the separately packaged module. [Package selection](driver-packages.md) chooses
the driver files for a machine; the kernel keeps essential boot support built in.
It does not manufacture board facts. Remaining work is:

1. Extend native providers beyond the documented x86 prerequisites, including
   verified ARM/RISC-V host bridges and platform DMA/cache/timing contracts.
2. Supply actual board calibration/SAR/antenna/rate ceilings and
   firmware/ACPI facts; intersect them with a trusted configured country and
   submit the authentic CLC/domain/SKU commands. NIC MAC/PHY facts and a raw
   EFUSE block do not provide those ceilings. No default power is invented.
3. Enable the prepared binding through NetworkKit, scan, and join a compatible test AP.
   `bedrock_wifi_static_address` optionally attaches an explicit static IPv4
   configuration using the actual card MAC. DHCP/DNS/TCP/TLS are not implemented
   by this work, and a Wi-Fi link does not invent an Internet configuration.
4. On the actual machine, record PCI/subsystem/revision, firmware hashes,
   country/board profile, commands/replies, beacons, association/M1–M4, TXS ACKs,
   protected inbound/outbound traffic, timeout/failure behavior and DMA teardown.
   Only that evidence can promote a named card to an operational support claim.

The initial target is the MT7922/RZ616 family already identified in the host's
read-only inventory. Intel and Realtek remain identification/format subsets;
this station path does not make their missing hardware transports operational.
QEMU's normal NIC cannot validate a physical MediaTek radio.

## Verification

```text
zig build test-wifi-station check
zig build test-wifi-station check -Doptimize=ReleaseSafe
zig build test check test-uefi test-network test-wifi
zig build test check test-uefi test-network test-wifi -Doptimize=ReleaseSafe
```

Before boot setup, Debug and ReleaseSafe acceptance each passed **263/263 build steps** for
`test check test-uefi test-network test-wifi`. The native driver suite passes
**212 checks per mode**, plus **two trusted SDK adapter checks**. MediaTek's
standalone suite passes 68/68 and the shared IEEE suite 39/39 in both modes;
those package counts include transitive checks and are not additive.

All twelve protected Wi-Fi boots, six UEFI smoke boots and six ARP/UDP stack
boots passed across the three reference architectures and both modes. Wi-Fi
boots are explicitly simulated or production-unavailable; ARP/UDP boots use
VirtIO and a loopback test peer. None is a physical MediaTek test. Default build
and installation passed 208/208 and the independent Debug kernel package
passed 46/46. Aggregate summaries include cached unchanged checks.

The station gate includes the complete native driver suite and separate
trusted SDK adapter tests. Strong compile probes force the actual binding,
scan/join/poll/transmit/stop and security bodies on baseline and PIC x86_64,
strict-alignment ARM64 and integer RISC-V64. Kernel boot/control regressions
retain production-unavailable and explicit simulation profiles. Native fixture
tests do not qualify hardware. The local `.zig-cache/wifi-station-verification.json`
records exact counts, source/artifact/log hashes and **zero physical RF tests**.
