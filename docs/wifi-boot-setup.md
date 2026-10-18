# MT7922 boot setup

Bedrock loads Wi-Fi firmware during UEFI boot. Normal kernel startup invokes
the native station setup inside a separately installed matching driver module.
**A physical connection is not verified.**
The initial hardware adapter is an explicitly configured x86-64 UEFI MT7922;
ARM64/RISC-V have firmware acquisition and image packaging, but require their
own hardware adapters. An architecture match alone is insufficient.

## Boot inputs and ownership

The loaded EFI application's own filesystem provides these files:

```text
EFI/BOOT/BOOTX64.EFI          # BOOTAA64.EFI or BOOTRISCV64.EFI on other ISAs
EFI/Bedrock/Firmware/WIFI_MT7922_patch_mcu_1_1_hdr.bin
EFI/Bedrock/Firmware/WIFI_RAM_CODE_MT7922_1.bin
EFI/Bedrock/Firmware/LICENCE.mediatek
EFI/Bedrock/Firmware/MT7922.board     # optional trusted administrator profile
EFI/Bedrock/Drivers/mt7922.bdm        # installed only when the package is selected
```

Only the pinned intact blobs are accepted. Their linux-firmware revision is
`afabaf773c4c2e2c841429933a6a084a5af4d14d`:

| File | Bytes | SHA-256 |
| --- | ---: | --- |
| Patch | 137632 | `7fc9075d6d54b31e0539734614ca971fa52caf41b642a3000c8a4501591a4d98` |
| RAM | 1231252 | `d100e5e04c324fc8da6302112d1e0b4fac952286447d2419eabcd8fb0a1f5b93` |

The loader closes files and finishes all allocations/RNG calls before its final
memory map/ExitBootServices loop. Firmware/profile storage has a distinct,
page-aligned non-reclaimable reservation; allocation, MMIO and ECAM helpers
exclude it. The loaded driver independently checks the firmware hashes before download.
The 4 MiB PIE kernel arena includes its guarded stack; the loader arena remains
2 MiB. BootInfo v0.6 is 4136 bytes, including retained driver image records,
the installed-application archive handoff and the optional firmware clock.

The loader obtains 64 bytes through EFI RNG and wipes its staging copy after
handoff. The kernel retains the original validated BootInfo pointer instead of
copying the seed. The module's private HMAC-DRBG SHA-256 consumes it and volatile-erases the
original. Its bounded nonce hook serves WPA2; timestamps, addresses, firmware
bytes and fixture generators never replace unavailable entropy. Unsupported or
unconfigured boots also erase unused handoff entropy.

## Image creation

```text
zig build -j2 wifi-uefi -Doptimize=ReleaseSafe
```

This uses the existing explicitly local pinned reference cache and creates
ordinary 64 MiB GPT/FAT32 files under `zig-out/wifi/{x86_64,arm64,riscv64}/`.
It copies the original vendor license. It never downloads files, flashes a disk,
mounts a host device, reboots the host or executes firmware in the host OS.
The x86 Wi-Fi image includes the current compatible MT7922 package as offline
installation media. ARM64/RISC-V media retain empty driver manifests because
the current package lacks their hardware ports. Ordinary UEFI media remain lean.
The bootloader enters an installed module only when its PCI metadata matches.
For one target machine, [package selection and staging](driver-packages.md)
copies only matching packages. The image tool accepts that selected directory
through `--driver-dir <selected>/EFI/Bedrock/Drivers`; its `--firmware-dir` input
supplies the pinned firmware and trusted profile separately.
If the local cache is absent, supply a directory containing the two exact vendor
filenames and `LICENCE.mediatek`:

```text
zig build -j2 wifi-uefi-x86_64 -Doptimize=ReleaseSafe -Dwifi-firmware-dir=C:/local/mt7922
```

Supply actual board facts using the strict profile encoder, then add the file:

```text
python tools/make-wifi-board-profile.py actual-board.json MT7922.board
zig build -j2 wifi-uefi-x86_64 -Doptimize=ReleaseSafe -Dwifi-board-profile=C:/local/MT7922.board
```

The [profile format](../drivers/wifi/src/mediatek/BOARD.md) documents exact PCI/subsystem/revision, EFUSE comparison,
antenna and board/SAR per-channel/per-rate facts, configured country/environment
and explicit platform declarations. Missing facts are errors. A checksum or
provenance digest proves neither calibration nor administrator authorization;
the EFI profile is trusted configuration. No usable sample with invented power,
country or calibration values is installed.

## Physical x86 setup

The current named port requires exclusive ownership of one exact card,
coherent identity DMA with the IOMMU disabled, masked interrupts on one CPU,
invariant TSC with a nonzero CPUID 0x15 crystal/ratio, and supported PAT/MTRRs.
It verifies the BAR's complete EFI MMIO description, existing supervisor identity
mapping and effective uncached CPU memory type. It verifies live DMA lease and
write-back RAM, rejects No-Snoop/Relaxed Ordering, and checks effective page
permissions in the current CR3 even while a process address space is active.

The sequence is: validate assets/profile and platform; consume RNG; disable
inherited bus mastering; take driver ownership and confirm reset/quiescence;
allocate retained DMA; download the pinned firmware; read actual NIC/PHY/EFUSE;
match the supplied board; select factory EFUSE; query genuine GET_TXPWR tables;
intersect only exact current-channel factory reports with supplied ceilings;
submit CLC/country/domain/SKU; initialize MAC/station and attach the protected
NetworkKit controller. Failure stops the transport, with uncertain DMA retained
instead of freed. Firmware consumption and station preparation are distinct
from observed scan/association/protected traffic.

With a matching module installed but no profile, setup reports
`[kernel] driver module: MissingBoardProfile`. A firmware-only image reports
that the Wi-Fi module is absent. Missing EFI RNG,
unsupported clocks, omitted/unmapped BARs, mismatching EFUSE and incomplete
platform declarations each retain explicit error names. They leave controls
unavailable and allow the rest of the OS to boot.

This first port uses 20 MHz legacy OFDM and WPA2-PSK/CCMP; fixed 6 Mbps maps to
MT76 encoding `0x4b` and must be supported by the observed peer. Country policy
continues to deny unapproved/DFS/6 GHz transmission. Intel/Realtek, arbitrary
ARM/RISC-V host bridges, IOMMU mappings, automatic reconnect and suspend recovery
are separate remaining implementations. A joined Wi-Fi link also needs IP
configuration: trusted `bedrock_wifi_static_address` exists; DHCP/DNS/TCP/TLS
are not added by this setup.

## Verification

```text
zig build -j2 test-wifi-boot-assets test-wifi-drivers check
zig build -j2 test-wifi-boot
zig build -j2 test check test-uefi test-network test-wifi test-wifi-boot wifi-uefi
zig build -j2 test check test-uefi test-network test-wifi test-wifi-boot wifi-uefi -Doptimize=ReleaseSafe
```

Native tests inject providers; they do not execute host privileged instructions
or access the host radio. QEMU boots use actual pinned firmware *as file data*,
plus damaged-file fixtures: they verify EFI loading, reservations, failure
diagnostics and the protected kernel lifecycle. QEMU has no MediaTek RF device.
Production-unavailable and explicit simulated Wi-Fi acceptance profiles remain
separate. Physical firmware execution, scan, AP join, protected bidirectional
traffic and teardown still require a real machine test before support is claimed.

Before module extraction, the Debug aggregate passed 323/323 build steps and 360/360 executed
native checks. The final direct-publication change then passed its focused
174/174-step gate, including 10/10 asset tests and all six asset boots.
ReleaseSafe passed 347/347 steps after retrying a transient standard-library
file-read error; its earlier successful native substeps include all 238 driver
checks. The normal Debug build/install passed 208/208. Each mode verified three
valid-file and three damaged-file boots; all installed 64 MiB images also passed
independent GPT/FAT32/long-name and asset inspection. Counts include imported and
cached checks and are not additive. The local
`.zig-cache/wifi-boot-verification.json` records source/image/log hashes and zero
physical RF tests.

References: [HMAC-DRBG specification](https://csrc.nist.gov/pubs/sp/800/90/a/r1/final),
[pinned MT76 legacy rate table](https://github.com/torvalds/linux/blob/7d0a66e4bb9081d75c82ec4957c50034cb0ea449/drivers/net/wireless/mediatek/mt76/mac80211.c#L154),
and the driver's retained provenance files.
