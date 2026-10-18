# x86-64 UEFI boot

This additional entry path uses the machine's initialized UEFI firmware to load
Bedrock's own EFI application. The application embeds an opaque separately
linked ELF64 PIE kernel image; neither package imports the other's implementation. After
`ExitBootServices`, the kernel runs directly on hardware and owns its console
and exception handling.

The verified emulator profile is `pc-q35-10.1`, TCG, `qemu64`, one CPU and the
installed EDK2/OVMF code/variable-store pair. This is emulator validation, not
physical-PC qualification.

## Startup and ownership

The loader requests a 2 MiB loader arena with `AllocateAnyPages`. It separately
allocates the kernel's 4 MiB load span, retaining any padding needed for ELF
alignment. The arenas can occupy different firmware RAM banks; neither has a
fixed physical address. The bounded ELF loader checks the image before copying
its segments, zeroes its declared memory span, and applies symbol-free
`R_X86_64_RELATIVE` relocations. It captures the ACPI RSDP and GOP description, then obtains
the final firmware memory map. Normalized region kinds preserve firmware,
ACPI, loader and MMIO reservations, while the raw map retains all original
64-bit EFI attributes and descriptor strides.

`GetMemoryMap` and `ExitBootServices` are retried together for a stale key.
After the first exit attempt, the code never calls firmware console/device
protocols or frees allocations. After a successful exit, a copied transition
block installs Bedrock's GDT, stack and sparse identity mappings, and switches
the UEFI Win64 calling convention to the kernel's SysV convention. Its context
contains the actual entry, handoff, stack and CR3 addresses. A five-level paging
entry is rejected before exit. The kernel uses relative linker symbols for BSS,
stack and runtime bounds; it checks live identity mappings before reading the
handoff and validates its loaded image/stack against the advertised reservation.

| Offset within the loader arena | Retained purpose |
| --- | --- |
| `0x000000..0x001028` | Current 4,136-byte draft v0.6 BootInfo |
| `0x040000..0x080000` | Bounded raw final EFI memory-map buffer |
| `0x080000..0x180000` | Page-table pool, at most 256 pages |
| `0x180000..0x181000` | Copied transition block, at most one page |
| `0x181000..0x181028` | Transition context: four addresses and a byte count |
| `0x1f0000..0x200000` | Loader transition stack |

The kernel's stack occupies offsets `0x3f0000..0x400000` from its aligned load
base. Its image and BSS must fit below that stack. All handoff addresses are
physical addresses after allocation, rather than these offsets.

The four-level mapper covers EFI-described ranges and the GOP framebuffer with
2 MiB pages where possible and 4 KiB pages at boundaries or cache-policy splits.
Addresses must fit the CPU's physical width and the low canonical range below
128 TiB. The handoff records up to 64 sorted sparse coverage ranges, independently
of allocation ownership. Holes grant neither mapping nor allocation permission.
The kernel's page cursor uses only normalized usable pages covered by that map.

The transition installs an explicit PAT layout for WB, WT, WC and UC, with caches
disabled and flushed during replacement. Descriptor cache capabilities select
RAM policy; the loader arena requires WB for its page-table pool. GOP uses WC
only when its complete range is covered by WC-capable descriptors, otherwise UC.
Firmware MTRR state is retained. Initial mappings still allow supervisor
read/write/execution; this is a bootstrap mapping policy.

The kernel uses its own console after firmware exit. Primary desktop images
retain COM1 diagnostics and provide the described GOP framebuffer to checked
user-space compositor scanout. Only dedicated acceptance variants finish
through `isa-debug-exit`; the normal installed desktop keeps running.

## Build and test

```powershell
.\tools\zig.ps1 build uefi-x86_64
.\tools\zig.ps1 build test-uefi-x86_64
.\tools\zig.ps1 build run-uefi-x86_64
.\tools\zig.ps1 build test-boot-matrix
```

The deterministic relocation check below was verified in both Debug and
ReleaseSafe. It places the kernel at `0x100000000` while the loader remains in a
separate arena, then verifies exit from boot services, handoff validation and
breakpoint recovery:

```powershell
.\tools\zig.ps1 build test-uefi-x86_64 -Dram-mib=4096 -Duefi-kernel-min=4294967296
.\tools\zig.ps1 build test-uefi-x86_64 -Doptimize=ReleaseSafe -Dram-mib=4096 -Duefi-kernel-min=4294967296
```

`uefi-kernel-min=0`, the default, uses arbitrary firmware allocation. A nonzero
minimum selects an aligned conventional-memory range at or above that address
and reserves it through UEFI; it fails cleanly if no suitable range is available.

The installed removable-media application is
`zig-out/uefi/x86_64/EFI/BOOT/BOOTX64.EFI`. It already contains its matching
kernel bytes, alongside `EFI/Bedrock/Apps/apps.bap`. The normal run starts the
installed compositor, shell and Files, with persistent app-2 disk data. Close
QEMU or use Ctrl+C to end the run. The underlying boot smoke tests remain
bounded; `test-service-desktop-x86_64` exercises the primary graphical runtime.

For a standalone GPT/FAT32 disk file, use `zig build uefi-image-x86_64`; that
packaging step requires Python 3. `zig build test-uefi-image-x86_64`
checks the disk format and boots the equivalent smoke disk image. See
[image packaging](uefi-image.md).
No command in these steps writes a physical disk or flashes motherboard firmware.

Windows defaults use the matching QEMU-installed EDK2 files. On another host,
pass `-Dovmf-code="<code image>" -Dovmf-vars="<matching variable template>"`.
The build supports `-Dqemu-x86_64="<executable>"` and `-Dram-mib=512`.
UEFI runs use at least 128 MiB in these emulator helpers. QEMU writes only to
private disk/NVRAM snapshots; firmware templates and directory inputs remain
unchanged.

## Current portability limits

- x86-64 UEFI firmware must permit this unsigned application, or the owner must
  arrange a trusted signed image. Secure Boot enrollment/signing is not implemented.
- The loader needs contiguous firmware allocations for its 2 MiB arena and the
  kernel span plus alignment padding. Unsupported ELF layouts or relocations fail.
- Four-level paging and a PAT-capable CPU with 32..52 physical address bits are
  required. Firmware entering with LA57 enabled is rejected. Addresses beyond
  the physical-width or low-canonical ceiling cannot be mapped.
- The normal console requires a linear 32-bit GOP framebuffer. BLT-only graphics
  are rejected. Framebuffers above 4 GiB are supported within the addressing and
  table-capacity limits; physical devices still require qualification.
- The normalized handoff and sparse coverage are each capped at 64 ranges.
  The mapper has 256 table pages; raw EFI maps have a 256 KiB buffer and at most
  1,024 descriptors. EFI descriptor version 1 and bounded extended strides are
  accepted. Unsupported layouts, cache policies or exhausted bounds fail.
- Loader mappings allow supervisor read/write/execution during transition. The
  kernel replaces them with owned W^X mappings, guarded stacks and distinct CPL3
  task roots while preserving live PAT choices. NX support and CR0.WP are required.
  The [user-mode probes](protected-userspace.md) also exercise saved-context
  timer preemption on the named single-CPU Q35 PIT/PIC backend. x2APIC state is
  rejected; inherited xAPIC is disabled and only legacy IRQ0 is enabled.
  Application loading and PCI/USB/storage/network drivers remain future work.
- ACPI tables and raw EFI runtime metadata are retained, but no ACPI interpreter
  or EFI runtime-services support is implemented.

References: [UEFI boot services and ExitBootServices](https://uefi.org/specs/UEFI/2.11/07_Services_Boot_Services.html),
[UEFI Graphics Output Protocol](https://uefi.org/specs/UEFI/2.11/12_Protocols_Console_Support.html),
[QEMU EDK2 firmware descriptor](https://github.com/qemu/qemu/blob/master/pc-bios/descriptors/60-edk2-x86_64.json).
