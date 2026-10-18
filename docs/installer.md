# Native Bedrock installer

Bedrock's first installer is a standalone native UEFI application. AxisUI paints
the drive picker, glass panels, partition preview, confirmation and progress.
Firmware services remain live while it reads installation media and writes the
selected disk. Raw disk authority stays in the firmware adapter; ordinary apps
and the UI model receive no raw-disk handles.

This release targets the QEMU/VirtIO reference machines on x86-64, ARM64 and
RV64. The installed kernel currently requires VirtIO storage. Firmware disk
discovery alone does not qualify physical SATA/NVMe storage for the running OS.
Secure Boot signing, existing-partition resizing and dual boot remain future work.

The first workflow replaces a whole drive's partition layout. It previews:

| Partition | Location | Current allocation |
| --- | --- | --- |
| EFI system partition | LBA 2048–131038 | About 63 MiB, FAT32 |
| Bedrock data | LBA 131072–139263 | 4 MiB durable filesystem |
| Unallocated space | After data, before backup GPT | Remaining target capacity |

GPT has a protective MBR, CRC-checked primary and backup headers and identical
128-entry tables. The backup header occupies the target's actual final sector.
The data type GUID is `42454452-4f43-4b44-8000-444154410001`. A bounded partition
view prevents filesystem I/O from reaching the ESP, GPT or neighboring ranges.
The current data format still has 32 nodes, 4096 bytes per mutable file and
128-byte paths; the installer does not increase those capacities.

The installer excludes its own disk through validated device-path ancestry.
It accepts present, writable whole media with 512-byte sectors and at least
139297 sectors, then revalidates the selected media before writing. Missing or
malformed source identity disables installation. The review explicitly states
that this release requires VirtIO storage. Installation requires typing exactly
`ERASE` and activating the final button or Enter; selecting a disk never writes.

The bounded sparse `BEDIP001` payload contains the installed ESP and a fresh
data seed. Its architecture, header/table CRCs, extent ranges and every content
CRC are verified before the first write. The writer initializes the new
partitions, copies their payload, checks readback, publishes both GPT copies,
flushes and verifies the committed result. Progress finishes after publication
and verification. I/O failures report failure; an interrupted installation can
leave a partially replaced disk and has no rollback guarantee. Unallocated
ranges are not securely erased.

Build and use the virtual installer from the workspace:

```text
zig build installer -j1
zig build run-installer-x86_64 -j1
zig build run-installed-x86_64 -j1
```

Replace `x86_64` with `arm64` or `riscv64`. The interactive helper creates an
80 MiB ordinary virtual disk at `zig-out/installed/<arch>/bedrock-installed.img`
only when absent; it never replaces an existing target file. Complete the native
installer, close that VM, then run the installed target without installer media.
The firmware installer supports USB keyboard/pointer input; the installed OS
uses its existing VirtIO input drivers. Enter continues, Escape goes back and
arrow keys choose a destination. The helper never opens host block devices.

`zig build test-installer-units` runs native UI, payload, source-protection and
write-failure tests. `zig build test-installer` drives actual installation into
owned virtual disks, checks both GPT copies and partition contents, and boots
the installed disk alone to test Notes persistence through another reboot.
Artifacts are under `zig-out/installer-tests/<mode>/<arch>/`.
The [verification record](installer-verification.md) documents the nine-boot
installation/reboot checks and their independently audited native screenshots.

Implementation lives in `userspace/apps/installer/`; the kernel mounts through
`filesystem.partition`. Existing raw `bedrock-data` regression images continue
to work. GPT and firmware block interfaces follow the
[UEFI specification](https://uefi.org/specs/UEFI/2.11/13_Protocols_Media_Access.html)
and [GPT format](https://uefi.org/specs/UEFI/2.11/05_GUID_Partition_Table_Format.html).
