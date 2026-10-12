# Draft Bedrock boot protocol

The `boot-protocol` package is a shared data contract, draft major 0/minor 2,
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
  identity-mapping ranges. The current record is 2,816 bytes, aligned to 8 bytes.
  Its declared header size includes the complete record. The first 1,784 bytes
  retain every v0.1 field offset, including the original 120-byte prefix; current
  full-record consumers still reject records shorter than 2,816 bytes.
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
the loader/kernel arenas, owned DTB, retained EFI map, framebuffer and any MMIO
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
- Kernel image ranges, initial archive/modules, and command line.
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
