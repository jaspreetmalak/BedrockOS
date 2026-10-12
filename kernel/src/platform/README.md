# Kernel platform support

Hardware discovery, interrupt controllers, platform timers, secondary CPU
startup, and reset/power mechanisms belong here. Named platforms supply these
mechanisms through explicit interfaces used by portable kernel subsystems.

CPU exceptions, page tables, context switching, and memory barriers belong in
`../arch/`. Kernel platform support must not call terminated boot services or
depend on bootloader implementation files.

`qemu_virt/`, `qemu_pc/`, and `qemu_riscv_virt/` hold each reference port's
physical layout, entry policy, handoff validation, and console. CPU entry and
trap assembly remain in `../arch/<isa>/`. See the [ARM64](../../../docs/arm64-qemu.md),
[x86-64](../../../docs/x86_64-qemu.md), and [RV64](../../../docs/riscv64-qemu.md) contracts.

The x86 kernel is shared by reset-ROM and UEFI entry. Its validated console
description selects I/O serial output or the kernel framebuffer driver. It must
check addressability before reading or clearing physical framebuffer memory.
