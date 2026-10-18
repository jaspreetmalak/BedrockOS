# ARM64 and RV64 UEFI entry

These adapters use initialized RAM and image access supplied by existing UEFI
firmware. Bedrock owns the loader and kernel after firmware exit. They supplement
the existing reset references; they do not initialize physical DRAM or replace
silicon boot ROM.

## Build and run

```sh
zig build uefi-arm64
zig build uefi-riscv64
zig build test-uefi-arm64
zig build test-uefi-riscv64
zig build run-uefi-arm64
zig build run-uefi-riscv64
```

Installed removable-media paths are
`zig-out/uefi/arm64/EFI/BOOT/BOOTAA64.EFI` and
`zig-out/uefi/riscv64/EFI/BOOT/BOOTRISCV64.EFI`. A separately compiled PIE kernel
is embedded in each application and installed as `kernel.elf` by `images`.
The primary images include `EFI/Bedrock/Apps/apps.bap` for installed init,
compositor, shell and Files. Archive/image packaging requires Python 3.9+.
RV64 also uses Python: Zig 0.17 cannot emit RV64 COFF, so a
bounded converter preserves the ELF loader's RVAs and converts symbol-free
relative relocations to PE32+ DIR64 records, with machine type `0x5064`.

Override matching firmware code/variables with `-Duefi-code-arm64`,
`-Duefi-vars-arm64`, `-Duefi-code-riscv64` and `-Duefi-vars-riscv64`.
The runners use private snapshots for variable-store and ESP writes.
The ARM64 reference uses Cortex-A57, `virt-10.1`, EDK2, and one CPU.
The RV64 reference uses `virt`, `rv64`, bundled OpenSBI, EDK2, and one hart.
Both disable ACPI in these reference tests to exercise firmware DTB discovery.
The RV64 reset reference continues to run without OpenSBI.
Normal run commands add QEMU's `ramfb` device, which provides a linear GOP
framebuffer in the installed firmware. Primary runs use at least 256 MiB RAM
and start the installed native [service desktop](service-desktop.md). Its
`test-service-desktop-arm64` and `test-service-desktop-riscv64` workflows check
actual pixels, input, window controls and durable storage across fresh boots.
The smoke matrix stays on UART. Firmware exposing only `PixelBltOnly`, including
the installed virtio GPU driver, falls back to the described UART.

## Memory and firmware lifetime

The loader requests a 2 MiB executable arena from firmware, then enough kernel
pages for a 4 MiB PIE span and its alignment. Allocations may land in separate
RAM banks. `-Duefi-kernel-min=<decimal address>` selects a minimum address for
deterministic placement tests. Every ELF segment and relocation is checked before
the destination changes; only symbol-free architecture-relative RELA is accepted.

| Loader-relative area | Bounds |
| --- | --- |
| Handoff v0.6 | Offset 0; 4,136 bytes |
| Exact EFI memory descriptors | `0x40000..0x80000` |
| Owned DTB copy | `0x80000..0x100000` |
| Copied CPU transition | `0x180000..0x190000` |
| Owned loader/transition stack | `0x190000..0x200000` |

The small firmware entry allocates and clears the arena before heavy ELF and
Devicetree parsing. Architecture thunks switch to its stack, restoring the
firmware stack before returning/freeing on a normal pre-exit failure.

Firmware DTBs must be backed by EFI RAM descriptors before their headers or
tables are read. The original capacity is bounded to 16 MiB; validated live
tables and the reservation terminator must fit the 512 KiB copy area.
Unused trailing edit capacity may be trimmed while preserving table offsets
and content. Static DTB reservations must not conflict with owned boot arenas.
The shared parser's node, depth, bank, reservation and bus-translation limits
apply. The final map remains bounded to 64 normalized regions and 64 accessible
ranges; the exact descriptor bytes remain in the loader arena.

The handoff retains ACPI RSDP and/or the copied DTB. A normal image prefers a
validated linear GOP framebuffer, otherwise requires ARM64's described PL011
or RV64's NS16550 MMIO console with supported register/clock geometry. GOP does not
require a chosen UART. Smoke images require the reference DTB UART and use
emulator-only exit devices. `ExitBootServices` retries a stale key at most eight
times, obtaining and validating a fresh map each time. No firmware protocol or
allocator is called afterward.

## CPU entry and limits

ARM64 requires AArch64 UEFI at EL1 or EL2, identity-addressable RAM and manageable
architectural caches. The copied transition masks interrupts, cleans caches,
disables translation/caching and enters EL1h with floating-point access enabled.
The kernel establishes its own stack, BSS and vectors through relative addresses.
Physical address width comes from `ID_AA64MMFR0_EL1`.

RV64 requires the LP64 UEFI ABI in Supervisor mode and machine firmware that
permits access to RAM and the selected console/device ranges. The transition
owns `stvec`, disables interrupts and `satp`, fences code and enters an integer
RV64IMAC kernel with an S-mode trap path. It cannot change machine PMP policy.
Its current 56-bit address-width contract is specific to the named QEMU profile.
The direct reset kernel retains its distinct M-mode entry/trap implementation.

The kernel checks the handoff address against the loader arena supplied in CPU
entry registers before dereferencing it, then validates the full handoff and
its actual linked runtime span. The page cursor selects complete pages from
usable memory intersecting the explicit accessible ranges.
These paths reach diagnostics and a deliberate breakpoint, then establish owned
protected mappings, user-mode isolation probes and timer-preempted saved
contexts before idling. ARM uses DTB-discovered GICv2 and its architectural
physical timer; RV uses discovered SBI TIME and DTB timebase frequency. See
[preemptive scheduling](preemptive-scheduling.md) for the supported bindings.
ARM uses 4 KiB EL1 stage-1 tables and EL0; RV64 uses Sv39 and U mode. RV retained
identity coverage must fit below 256 GiB and avoid the reserved 128 GiB user
window; ARM requires a supported 4 KiB translation format and up to 48-bit
physical addresses for this adapter. See [protected userspace](protected-userspace.md).
Application loading, SMP, broader interrupt-controller discovery and
storage/network drivers remain future work. Physical compatibility has not been established.
Firmware must permit the application; trusted image signing/enrollment is not
implemented.

Primary platform reference: [QEMU RISC-V virt and firmware boot](https://www.qemu.org/docs/master/system/riscv/virt.html).
