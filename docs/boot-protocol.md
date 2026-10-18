# Draft Bedrock boot protocol

The `boot-protocol` package is a shared data contract, draft major 0/minor 6,
not a frozen external ABI. Format and layout checks live in that package.

## Initial records

- `Header`: magic, major/minor version, declared header length, architecture
  identifier, and reserved space.
- `PhysicalRange`: a physical base address and byte length, both `u64`.
- `MemoryRegion`: a physical range and explicit kind/attributes.
- `BootInfo`: the 24-byte header followed by UART address, DTB range, loaded
  kernel load span, boot RAM envelope, loader reservation, kernel reservation, and
  flags. It appends up to 64 sorted memory regions, typed console, boot environment,
  CPU entry state, ACPI/framebuffer descriptions and an owned raw EFI memory-map
  reference. Draft v0.2 adds CPU physical width and up to 64 explicit sparse
  identity-mapping ranges. Draft v0.3 appends a private Wi-Fi asset handoff;
  v0.4 appends retained driver image records; v0.5 appends the installed-app
  archive handoff; v0.6 appends an optional firmware wall-clock snapshot.
  The current record is 4,136 bytes, aligned to 8 bytes.
  Its declared header size includes the complete record. The first 1,784 bytes
  retain every v0.1 field offset, including the original 120-byte prefix; current
  full-record consumers still reject records shorter than 4,136 bytes.
- `Console`: address, type, register stride, clock and baud rate. Supported kinds
  represent PL011, MMIO/I/O 16550, framebuffer and no console.
- `Framebuffer`: checked 32-bit pixel geometry, stride, backing size and explicit
  disjoint channel masks. Normal UEFI boot uses this kernel-owned text output.
- `MemoryMap`: bounded, allocation-free RAM/reservation normalization through
  `reset`, `addRam`, `addReservation` and `finalize`. Reservations split banks,
  stricter kinds win overlaps and matching neighboring regions merge. A failed
  finalization leaves the destination map unchanged.
- `MappedRanges`: a separate bounded builder for actual identity coverage.
  `init`, `add` and `finalize` check physical-width bounds and merge overlapping
  or adjacent ranges in sorted order. Mapping coverage grants no allocation
  ownership or cache/protection policy.

The appended v0.2 fields are `mapped_range_count: u32` at offset 1,784,
`physical_address_bits: u32` at 1,788, and 64 `PhysicalRange` records in
`mapped_ranges` at 1,792. Unused coverage records must be zero. UEFI producers
report nonempty sorted disjoint identity coverage; reset profiles may retain
zero coverage and their explicit platform mapping contract.

Draft v0.3 appends `wifi: WifiBoot` at offset 2,816 (136 bytes), preserving all
prior offsets. It holds version/flags, a page-aligned retained reservation,
patch/RAM/optional profile ranges and a 64-byte EFI RNG seed. Present firmware
must use the exact pinned lengths; assets are contained and disjoint inside a
mapped, non-reclaimable reserved arena, outside loader/kernel/framebuffer
reservations. All absent fields are zero. Flags independently describe firmware,
entropy and profile availability. Kernel consumers retain a pointer to the
original validated handoff; they consume/erase its seed and clear its entropy
flag. The loader erases its temporary seed copy immediately after handoff.
These fields describe acquired inputs; they never certify physical RF readiness.

Draft v0.4 appends `drivers: DriverBoot` at offset 2,952 (1,096 bytes),
preserving all prior offsets. It holds up to four 272-byte `DriverRecord`s.
Each records the retained allocation, contained mapped image, executable entry,
class, SHA-256 of the relocated image and up to eight page-disjoint segment
ranges. ELF flags permit only R, RX and RW; executable pages cannot be writable.
Entry lies inside an RX segment and respects ARM64/RISC-V instruction alignment.
Unused records and segments are zero. Present modules are UEFI-only, completely
mapped and covered by non-reclaimable reserved memory, disjoint from boot arenas,
Wi-Fi assets, the framebuffer and other module reservations.

The EFI loader inspects and relocates optional driver files without entering
them. Kernel architecture code applies supervisor R/RX/RW-NX mappings, then the
private broker checks the image digest and versioned Driver ABI before calling
entry. Driver pages remain reserved for their lifetime; hot unload is not
implemented. These records describe trusted executable code with kernel
privileges, not an application sandbox. See private
[DriverKit](../frameworks/private/DriverKit/README.md)
and [package selection](driver-packages.md).

Draft v0.5 appends `apps: AppBoot` at offset 4,048 (64 bytes), preserving all
prior offsets. It records a page-aligned retained reservation, a contained
archive extent and its SHA-256. The archive is at most 16 MiB; absent fields are
all zero. Present archives are UEFI-only, completely mapped, non-reclaimable
reserved memory and disjoint from loader/kernel, driver, Wi-Fi and framebuffer
reservations. Kernel mappings keep archive pages supervisor-only, read-only and
non-executable. The kernel checks the digest and archive before mounting
app-owned bundles, and retains this reservation while the VFS borrows bytes.
These records identify installed code bytes; they do not assign app permissions
or certify a package signature. See [installed applications](application-runtime.md).

Draft v0.6 appends `wall_clock: WallClock` at offset 4,112 (24 bytes), preserving
every earlier offset. It records `seconds: i64`, `nanoseconds: u32`, `flags: u32`,
`utc_offset_minutes: i32`, and a zero reserved word. The available and UTC flag
bits are 1 and 2. Absent fields are completely zero; a present clock is UEFI-only.
The loader reads `GetTime` before its final memory-map/key sequence and never
calls firmware afterward. It validates calendar dates, leap years, fractions,
timezone bounds and daylight flags. UTC seconds are Unix epoch seconds; the
conventional offset is minutes east of UTC. Firmware with unspecified timezone
retains local calendar seconds, offset 2047, and a clear UTC flag. No timezone
or time is guessed. Dates normalized outside 1900–9999 become unavailable.
The kernel advances this baseline through the existing observed timer quanta;
this is an approximate clock rather than a synchronized time service. See
[wall clock](wall-clock.md).

The initial three profiles are 64-bit and little endian. Records have explicit
extern layouts and compile-time size/offset checks. Callers must provide valid,
aligned access to the header; field validation does not make an arbitrary raw
address safe to dereference. A future byte decoder must validate the input
length before reading any header fields.

The header checks magic, supported major version, declared size versus available
bytes, expected architecture, and draft reserved fields. Accessible larger
headers and later minor versions are allowed so that optional extensions can be
added. Physical ranges reject exclusive-end overflow.

`BootInfo.validate` also rejects empty ranges, reservations outside RAM,
overlapping loader/kernel reservations, DTB outside the loader reservation, and
kernel bytes outside the kernel reservation. It also checks typed console/entry
metadata, framebuffer bounds/masks, retained EFI metadata and sorted nonempty
map regions. Loader/kernel reservations must be completely covered by nonusable
regions. It does not prove that supplied ranges describe real hardware; platform
startup must establish this separately. Explicit identity coverage must include
the loader/kernel arenas, driver, Wi-Fi and installed-app arenas, owned DTB, retained EFI map, framebuffer and any MMIO
console ranges. `BootInfo.isMapped(range)` queries validated coverage; it returns
false for unreported reset coverage rather than guessing a mapping.

The prefix `ram` is an informational envelope containing the boot arenas. It may
span discontiguous banks and holes; it grants no access or allocation permission.
Allocate only from `memory_regions` explicitly marked usable.
Unknown kinds and missing address ranges remain unavailable. The kernel's
bootstrap page cursor excludes partial pages and, with explicit coverage,
considers only pages that `isMapped` covers completely. Reset consumers retain
their pinned mapping limits. Current code does not reclaim loader memory. Discontiguous banks and
memory beyond the boot envelope remain representable in the full map.

For UEFI entry, `firmware_memory_map`, `firmware_descriptor_size` and
`firmware_descriptor_version` describe an owned copy of the final EFI map inside
the loader reservation. Raw descriptors preserve 64-bit firmware attributes;
normalized Bedrock region attributes remain zero. The ACPI RSDP address records
firmware information; the kernel does not yet parse or enable ACPI devices.
UEFI arenas are dynamically allocated and may lie in separate RAM banks. EFI
conversion verifies each complete page-aligned arena is owned as loader
code/data without the runtime attribute before preparing the handoff. Sparse
coverage must be published before validating that completed UEFI record.

Consumers establish pointer alignment and accessible header/full-record bounds
before reading fields. Reset consumers use their named platform arenas; dynamic
entries use a trusted loader-arena entry contract or live identity-map checks.
They read and check the header before accessing the full record. The reset ports now discover RAM
and reservations from Devicetree or QEMU fw_cfg rather than a fixed 128 MiB size.
Bit 0 of `flags` permits emulator smoke-test termination through the platform
test backend: Arm semihosting, x86 `isa-debug-exit`, or RV64's SiFive test device.
Unknown optional flag bits are ignored. Normal loaders write zero. x86-64 may
omit Devicetree using the exact range `{0, 0}`; UEFI or ACPI-described platforms
may also omit it. The reset ARM64/RV64 profiles require an owned nonempty DTB.
RV64 copies the emulator's original DTB
into that reservation before handoff. See the [ARM64](arm64-qemu.md),
[x86-64](x86_64-qemu.md), [RV64](riscv64-qemu.md), [x86 UEFI](x86_64-uefi.md),
and [ARM64/RV64 UEFI](arm64-riscv64-uefi.md) entry contracts.

## Future extensions

Broader platform support and kernel features will require:

- Exact loader/module reclaim timing.
- A general command line, broader executable/archive formats and driver classes.
- Additional hardware descriptions, boot CPU identity and runtime services policy.
- Required/optional extension handling and boot verification state.
- Entry contracts for additional platforms, secondary CPU startup, and runtime
  privilege separation. All initial reference machines use one CPU/hart.

Every referenced range remains reserved until the kernel deliberately takes
ownership or reclaims it. Firmware/runtime reservations must retain their
original semantics. ACPI and Devicetree references are hardware descriptions;
they do not substitute for operating drivers.

Keep allocation policy, image loading, storage callbacks, and privileged CPU
operations outside this package.
