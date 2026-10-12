# x86-64 QEMU platform

The named target is QEMU `pc-i440fx-10.1`, TCG, `qemu64`, one CPU; RAM defaults
to 128 MiB. Bedrock supplies a custom 2 MiB reset ROM through `-bios`; no SeaBIOS,
UEFI, GRUB or firmware boot services are used.

The ROM starts at `0xffe00000` and ends at 4 GiB. CPU reset fetches its first
instruction at `0xfffffff0`. The 16-bit entry enables A20, masks interrupts,
loads a GDT and switches to 32-bit protected mode. It initializes loader RAM,
creates identity page mappings for the first 4 GiB using 2 MiB pages, enables
PAE/long mode and SSE, and calls Zig in 64-bit mode. These initial mappings are
for bring-up; page protection is a later kernel milestone.

QEMU initializes RAM and supplies the chipset and COM1 device. This port does
not initialize physical PC DRAM or replace platform-specific chipset firmware.
[QEMU PC documentation](https://www.qemu.org/docs/master/system/i386/pc.html)

The loader discovers total RAM and the E820 map through QEMU's fw_cfg device.
It searches the fw_cfg file directory for `etc/e820`, checks the record format,
and normalizes RAM and reserved ranges. This is a QEMU platform adapter, not a
physical-PC firmware interface. The separate [UEFI path](x86_64-uefi.md) uses
standard PC firmware instead.

## Layout and handoff

Ranges use exclusive ends.

| Range | Purpose |
| --- | --- |
| `0x00000000..0x00100000` | Reserved low memory, including PC device/ROM holes |
| `0x00100000..0x00180000` | Loader data and BSS |
| `0x00180000..0x00186000` | Loader identity page tables |
| `0x001f0000..0x00200000` | Loader stack, 64 KiB |
| `0x00200000..0x003f0000` | Kernel initialized bytes and BSS |
| `0x003f0000..0x00400000` | Kernel stack, 64 KiB |
| `0x00400000..discovered RAM end` | Remaining RAM, excluding discovered reserved regions |
| `0xffe00000..0x100000000` | Read-only loader ROM and embedded kernel bytes |

All RAM below 2 MiB stays reserved by the loader. The kernel reservation spans
2–4 MiB. The ROM contains opaque bytes from a separately linked kernel; the
loader copies and verifies them before entry. Loader data has a RAM virtual
address and ROM load address; assembly copies it and clears BSS.

At kernel entry, `RDI` is the BootInfo physical address and `RSI` is its
accessible byte count. The stack follows the SysV AMD64 alignment rule; CPL is
0, paging is active, and interrupts remain masked. The kernel checks the record
against its trusted loader arena before dereferencing. COM1 uses port `0x3f8`.
This PC port has no Devicetree: its DTB range is `{0, 0}`. It does not yet supply
ACPI tables or enumerate PCI devices.

The kernel installs an IDT, handles an armed `INT3` probe, and idles. Unexpected
exceptions report a fault and stop; device interrupts and userspace are not
implemented. Loader page tables remain reserved until the kernel replaces them.

## Commands

```powershell
.\tools\zig.ps1 build x86_64
.\tools\zig.ps1 build test-x86_64
.\tools\zig.ps1 build run-x86_64
```

Images are in `zig-out/x86_64/`. QEMU loads `bootloader.bin`; the ELF files
provide symbols for an x86-64 debugger. Add `-S -gdb tcp::1234` when starting
QEMU manually to debug reset and the mode transitions.

The acceptance runner attaches `isa-debug-exit` at port `0xf4`. A successful
smoke image writes `0x10`, which QEMU converts to host exit code 33. The runner
checks that code, seven ordered milestones, memory discovery and a 40-second timeout.
Normal images clear the test flag and remain in an interrupt-masked `HLT` loop
without a test-exit device. Use Ctrl+C to stop a normal run.

Select a nonstandard emulator location with `-Dqemu-x86_64="<absolute path>"`.
Use `-Dram-mib=512` to test the same images with another RAM size.
On Unix use `sh tools/zig.sh build test-x86_64`; Python 3 runs the bounded test.
