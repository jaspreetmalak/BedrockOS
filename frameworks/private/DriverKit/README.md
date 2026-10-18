# DriverKit

DriverKit is Bedrock's private ABI and bounded executable loader for separately
packaged native drivers. Essential boot support can remain built in. A package
contains an architecture-specific `.bdm` ELF64 PIE and package metadata. Pinned
firmware and board profiles are separate EFI inputs. Device IDs
in its catalogue and ELF notes select the package without installing every
driver. Loading still executes trusted driver code with kernel privileges.

This private framework lives at `frameworks/private/DriverKit/` and is shared by
the bootloader, kernel and separately built modules. Its interfaces, ELF
validation and linker rules provide the common integration layer. Hardware
implementations remain under [`drivers/`](../../../drivers/), beginning with
[`MT7922`](../../../drivers/mt7922/README.md). Directory placement supplies no
device or execution authority.

The first class is Wi-Fi. Host imports allocate, resolve, and release memory
through opaque generational tokens. The module borrows the public versioned boot
handoff and returns a C function table. BSS records, events, reports, and Ethernet
frames are copied through fixed-width POD values. Private Zig structures,
allocator tickets, `Binding` owners, slices, and error sets stay on their side
of the boundary. Calls are synchronous and serialized; input credentials are
borrowed only for their call and must never be retained.

`src/elf.zig` accepts ELF64 little-endian ET_DYN for x86_64, ARM64, and RISC-V64,
up to eight PT_LOAD segments, an eight-MiB file, and a four-MiB memory span. Load
segments occupy separate pages and use R, RX, or RW permissions. At least one
read-only `BEDROCK` PT_NOTE supplies ABI 1.0 metadata. Up to eight exact PCI
aliases may describe the same module; IDs, architecture, version, class, and
capabilities must agree. Only symbol-free relative RELA writes into writable
segments are allowed. Inspection validates the complete file before copying.

The boot host allocates a retained arena, loads into RW/NX pages, records the
relocated image digest and segment permissions in its handoff, and closes all
firmware file handles before final memory-map acquisition. The kernel checks
the retained ranges, relocated image digest and returned C ABI table. It installs R/RX/RW-NX
supervisor mappings in both its kernel tree and every user address-space tree
before entering the module. Gaps stay NX. ARM64 instruction-cache maintenance
and RISC-V `fence.i` complete loading before entry. There must be no writable
alias of module executable pages.

Module data, code, the host table, the boot handoff, and host allocation-token
records stay at stable addresses for the complete module lifetime. Module
initialization publishes reporting and stop callbacks before touching hardware.
A failed stop or retained-DMA report keeps the arena and all live allocations
reserved. This initial design does not support hot unload or kernel symbol
resolution. Future unload must first detach callbacks, stop new calls, prove
DMA and interrupt quiescence, remove every executable alias, invalidate TLBs,
and only then clear and release pages.
