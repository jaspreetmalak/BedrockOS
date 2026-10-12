# Standalone x86-64 UEFI disk image

The optional image builder packages Bedrock's UEFI application into one ordinary
raw disk-image file. It requires Python 3.8 or later and uses only its standard
library, with no filesystem utilities, administrator access, mounting, or
host-drive access.
This is an artifact for inspection and emulator testing; physical firmware
compatibility has not been established.

## Build and inspect

From the workspace root:

```sh
zig build uefi-image-x86_64
python tools/test-uefi-image.py zig-out/uefi/x86_64/EFI/BOOT/BOOTX64.EFI zig-out/uefi/x86_64/bedrock-uefi.img
```

The build step finds Python 3 on `PATH` and installs a **67,108,864-byte (64 MiB)**
image at `zig-out/uefi/x86_64/bedrock-uefi.img`. This optional x86 artifact and
its checks require Python. The RV64 UEFI directory build also requires Python
for ELF-to-PE conversion; reset-only and ARM64/x86-64 UEFI directory builds do
not use it. This disk packager currently installs only the x86 boot filename.

The tools can also package and check a supplied application directly:

```sh
python tools/make-uefi-image.py INPUT.EFI OUTPUT.img
python tools/test-uefi-image.py INPUT.EFI OUTPUT.img
python tools/test-uefi-image.py
```

The last command runs structural and corruption tests in memory. The builder
checks nonempty input and capacity, but does not validate or sign the input's
PE/COFF executable format. Its destination directory must already exist. It
rejects special files, Windows device paths and DOS aliases (including extensions
and superscript COM/LPT digits), ambiguous Windows names with trailing spaces or
dots, output symbolic links, and using the input file as the output. These Windows
name restrictions do not alter ordinary POSIX filenames. A successful build
atomically replaces the output file through a temporary file in the same directory.

To run the separate raw-image acceptance path with the configured QEMU/OVMF:

```sh
zig build test-uefi-image-x86_64
```

That step runs the eight image-format selftests, checks the generated smoke
application byte for byte inside its disk image, and then boots it through OVMF.
The normal installed image and the smoke image carry separate EFI applications;
only the smoke variant uses the emulator's test-exit device.

## Serialized layout

All sectors are 512 bytes. GPT LBAs are encoded as 64-bit little-endian values.

| Area | Location |
| --- | --- |
| Protective MBR | LBA 0; one type `0xEE` record |
| Primary GPT header | LBA 1 |
| Primary partition array | LBAs 2–33; 128 entries of 128 bytes |
| EFI System Partition | LBAs 2048–131038 |
| Backup partition array | LBAs 131039–131070 |
| Backup GPT header | LBA 131071 |

The GPT copies contain matching partition arrays with CRC32 checksums and
individually checked headers. The ESP uses the standard EFI System Partition
type GUID and contains `EFI/BOOT/BOOTX64.EFI` using uppercase 8.3 entries.

The FAT32 volume has 40 reserved sectors, two mirrored FATs of 992 sectors each,
and 126,967 data clusters of 512 bytes. The data region starts on a 4 KiB
boundary. The primary boot and FSInfo sectors are partition-relative sectors 0
and 1; their backups are sectors 6 and 7. Three clusters hold the root, `EFI`,
and `BOOT` directories. Remaining clusters can hold an application of at most
**65,005,568 bytes**. All unallocated bytes and final-cluster padding are zero.

Disk and partition GUIDs are UUIDv5 values derived from separate names containing
the application's SHA-256 hash. The FAT volume ID also derives from that hash;
directory timestamps are fixed at 1980-01-01. Identical application bytes produce
identical image bytes. These identifiers distinguish different payloads; copying
an image reproduces its identifiers.

The checker independently derives filesystem positions from the BPB, checks both
GPT header and table CRCs, FAT mirroring, boot/FSInfo backups, free-cluster counts,
directory entries, chain bounds and cycles, and every application byte. It also
detects orphaned allocations and incorrect final-cluster padding.

## Format references

- [UEFI file-system and boot-path requirements](https://uefi.org/specs/UEFI/2.11/13_Protocols_Media_Access.html).
- [TianoCore's GPT structure definitions](https://github.com/tianocore/edk2/blob/master/MdePkg/Include/Uefi/UefiGpt.h).
- [Microsoft FAT32 specification, version 1.03 (reference copy)](https://www.isdaman.com/alsos/protocols/fats/fatgen103.pdf).
- [Microsoft's Windows file and device-name rules](https://learn.microsoft.com/en-us/windows/win32/fileio/naming-a-file).
