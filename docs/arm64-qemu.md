# ARM64 QEMU platform

This is Bedrock's first executable platform port. It uses Zig 0.17.0 and small
AArch64 assembly entry/vector routines. Its scope is emulator boot, validated
loader-to-kernel handoff, diagnostics, and synchronous exception handling.

## Named machine contract

- QEMU `virt-10.1`, TCG, `cortex-a57`, one CPU; RAM defaults to 128 MiB.
- `secure=off,virtualization=off`: reset enters EL1h with interrupts masked.
- Custom raw firmware loaded through `-bios` at flash address `0x0`.
- MMU and caches disabled; FP/SIMD enabled before entering compiled Zig.
- Bare-metal DTB at `0x40000000`; PL011 UART0 at `0x09000000`.
- Little endian, 16-byte stack alignment, no secondary CPUs.

The versioned machine is deliberate: QEMU documents flash and RAM bases as
stable, while other resources should normally be discovered from the DTB. This
port parses the DTB to discover memory banks, firmware reservations and the
chosen PL011 console with its clock and baud rate. The bounded parser rejects
unsupported address translations and dynamic reservations. Reset flash, initial
RAM/DTB location and linked loader/kernel arenas remain platform-specific.
[QEMU virt documentation](https://www.qemu.org/docs/master/system/arm/virt.html)

QEMU provides working RAM before reset. This port does not implement physical
DDR training, board clocks, power sequencing, or immutable silicon boot ROMs.

## Physical layout

Ranges below use exclusive ends.

| Range | Owner and purpose |
| --- | --- |
| `0x00000000..0x04000000` | First flash bank; loader code and embedded kernel bytes |
| `0x40000000..0x40100000` | Reserved DTB area; actual DTB length is checked |
| `0x40100000..0x40180000` | Loader data/BSS, including the handoff record |
| `0x40180000..0x40200000` | Loader stack |
| `0x40200000..0x403f0000` | Kernel initialized image and BSS |
| `0x403f0000..0x40400000` | Kernel stack, 64 KiB |
| `0x40400000..discovered RAM end` | Remaining bank, with firmware reservations removed from the usable map |

Linker assertions enforce flash capacity and keep data/BSS out of stacks.
The loader verifies every copied image byte before transferring control and
synchronizes instruction execution. Kernel startup clears its own BSS and sets
its own stack and aligned vector table.

The loader passes `x0 = physical BootInfo address` and `x1 = accessible bytes`.
The kernel checks that pointer against the trusted loader RAM envelope before
dereferencing, then validates the shared record and the named platform's ranges.
All loader memory and the DTB remain reserved; reclamation is not implemented.

## Build and run

From the workspace root:

```powershell
.\tools\zig.ps1 build arm64
.\tools\zig.ps1 build test-arm64
.\tools\zig.ps1 build run-arm64
```

The normal run stays in a `WFI` loop after completing startup. Stop it with
Ctrl+C. The build's test runner has a 40-second timeout, captures console output, and
requires ordered loader/kernel milestones plus a successful QEMU exit.

`zig-out/arm64/kernel.elf` is independently linked at `0x40200000`;
`kernel.bin` is its initialized image. `bootloader.elf` contains loader code and
the embedded bytes; `bootloader.bin` is the raw flash image QEMU loads.
The test image is generated separately in Zig's cache. Its handoff flag permits
Arm `SYS_EXIT_EXTENDED`; the normal image leaves that flag clear and does not
execute semihosting instructions.
[Arm semihosting specification](https://github.com/ARM-software/abi-aa/blob/main/semihosting/semihosting.rst)

For a nonstandard QEMU location, append `-Dqemu="<absolute executable path>"`.
Use `-Dram-mib=512` to boot the same images with another RAM size.
On Unix use `sh tools/zig.sh build test-arm64`; Python 3 runs the bounded test.

For debugger attachment, build the normal image and start QEMU with the same
machine contract plus `-S -gdb tcp::1234`:

```powershell
& 'C:\Program Files\qemu\qemu-system-aarch64.exe' `
  -machine virt-10.1,secure=off,virtualization=off -cpu cortex-a57 `
  -accel tcg -smp 1 -m 128M -display none -serial stdio -monitor none `
  -bios zig-out/arm64/bootloader.bin -S -gdb tcp::1234
```

Use an AArch64-capable debugger and load the matching ELF symbols. Exception
diagnostics include ESR, ELR, and FAR. All vectors preserve general registers,
SIMD registers, and FP state; only the armed current-EL breakpoint probe is
resumed. Unexpected exceptions stop execution.

## Next ARM64 work

The UEFI path now has protected paging and timer-preempted saved contexts;
this direct-reset reference retains allocator/breakpoint scope. Extend supported
DTB bus translations, application loading and process lifecycle. Physical boards require
individual platform ports and cold-boot validation.
