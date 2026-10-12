# RV64 QEMU platform

The named target is QEMU RISC-V `virt`, TCG, `rv64`, one hart; RAM defaults to 128 MiB.
The installed emulator has no versioned RISC-V `virt` alias; the verified QEMU
binary version is recorded in [the support matrix](support-matrix.md).

Bedrock's own firmware ELF is passed through `-bios`. QEMU's small reset ROM at
`0x1000` passes the hart ID in `a0` and the generated DTB address in `a1`, then
jumps to Bedrock at `0x80000000`. No OpenSBI or SBI calls are used. Both loader
and initial kernel execute in machine mode; a supervisor-mode kernel is a future
privilege-separation milestone. QEMU supplies initialized RAM.
[QEMU RISC-V documentation](https://www.qemu.org/docs/master/system/riscv/virt.html),
[QEMU reset-vector implementation](https://github.com/qemu/qemu/blob/master/hw/riscv/boot.c)

Compilation uses an integer-only RV64 target: I, M, A, C, Zicsr and Zifencei,
with F/D/V absent, soft-float ABI, and medany addressing. FP/vector context is
therefore not part of this port's trap frame. Interrupts are masked; the initial
address space is physical, with translation disabled.

## Layout and handoff

Ranges use exclusive ends.

| Range | Purpose |
| --- | --- |
| `0x80000000..0x800e0000` | Loader code, embedded kernel, data and BSS |
| `0x800e0000..0x80100000` | Loader stack, 128 KiB |
| `0x80100000..0x80180000` | Preserved copy of DTB, at most 512 KiB |
| `0x80180000..0x80200000` | Remaining loader reservation |
| `0x80200000..0x803f0000` | Kernel initialized bytes and BSS |
| `0x803f0000..0x80400000` | Kernel stack, 64 KiB |
| `0x80400000..discovered RAM end` | Remaining bank, excluding firmware reservations and the original DTB |

The initial `a1` is a trusted QEMU reset-ROM pointer, required to reference
readable initialized RAM. A header cannot prove physical accessibility before
the first read. The loader bounds and parses the DTB, discovers RAM banks,
memreserve/static reserved-memory ranges and the chosen 16550 console, then
checks the original DTB against discovered RAM and destination capacity.
Unsupported bus translations and dynamic reservations fail explicitly. It preserves a copy
inside the loader reservation, so the shared handoff ownership rules apply.
The original DTB range also stays reserved in the normalized map.
The kernel image is separately linked at `0x80200000`, converted to raw bytes,
embedded in the loader, and copied and checked before entry. `FENCE.I` makes the
new instructions visible before branching.

At kernel entry, `a0` is the BootInfo address and `a1` is its accessible size.
Stacks are 16-byte aligned. The kernel validates that pointer against the trusted
loader arena, checks the protocol and platform ranges, and initializes its own
direct-mode `mtvec` trap handler. UART0 is a polling 16550 at `0x10000000`.
The armed `EBREAK` probe is a 32-bit instruction; the handler preserves integer
registers and status, reports success and resumes at the next instruction.
Unexpected traps stop execution. Device interrupts are not implemented yet.

## Commands

```powershell
.\tools\zig.ps1 build riscv64
.\tools\zig.ps1 build test-riscv64
.\tools\zig.ps1 build run-riscv64
```

Images are in `zig-out/riscv64/`. QEMU loads `bootloader.elf` so initialized
segments and their physical addresses are explicit; `bootloader.bin` is also
emitted. Kernel ELF/raw files remain separate. A RISC-V debugger can use the
ELF symbols with QEMU `-S -gdb tcp::1234`.

The acceptance runner checks seven ordered console milestones, exit code 0 and
a 40-second timeout. A smoke image signals the SiFive test device at `0x100000`;
a normal image clears its test flag and idles in `WFI`. Use Ctrl+C to stop it.
Select another emulator location with `-Dqemu-riscv64="<absolute path>"`.
Use `-Dram-mib=512` to test the same images with another RAM size.
On Unix use `sh tools/zig.sh build test-riscv64`; Python 3 runs the bounded test.
