# Boot platform adapters

Board reset code, temporary memory, clocks, DRAM initialization, boot storage,
and any chosen firmware entry adapters belong here. Each named platform must
document what initialized hardware it requires and what it initializes itself.

`qemu_virt/` owns ARM64 flash firmware, `qemu_pc/` owns the x86-64 reset ROM,
and `qemu_riscv_virt/` owns RV64 M-mode firmware. All use RAM initialized by QEMU;
physical clock/DRAM initialization requires separate board ports. See the
[ARM64](../../../docs/arm64-qemu.md), [x86-64](../../../docs/x86_64-qemu.md), and
[RV64](../../../docs/riscv64-qemu.md) startup contracts.

`uefi/` provides x86-64 standard firmware entry, page allocation, memory-map
normalization and an ExitBootServices transition. See its
[contract](../../../docs/x86_64-uefi.md) and the [porting guide](../../../docs/portability.md).
