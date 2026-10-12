# Bedrock bootloader

Independent Zig package for platform startup, boot-image loading, and kernel
handoff. Its only current dependency is `../boot-protocol`. It never imports
kernel internals.

UEFI is the primary boot environment on x86-64, ARM64 and RV64. Existing
firmware initializes hardware and RAM and loads Bedrock's own UEFI application.
Bedrock owns kernel loading and the handoff to its OS.

`src/core/` contains portable loader policy; `src/arch/` contains per-CPU code;
`src/platform/` holds board and boot-environment adapters.

The UEFI adapters for all three architectures allocate dynamic arenas,
load independently linked PIE kernels through a bounded ELF/RELA loader,
retain EFI/ACPI/DTB/GOP information and exit boot services. x86-64 establishes
sparse mappings; ARM64 enters EL1h and RV64 enters S mode. Heavy ARM64/RV64
loader work uses an owned stack. RV64's host ELF-to-PE conversion requires Python.

Custom ARM64 flash code, an x86-64 reset ROM and RV64 M-mode code remain for the
named QEMU reference machines. Each establishes a RAM stack and console, copies
an opaque kernel binary and hands over a checked boot record. ARM64/RV64 discover
RAM, reservations and console properties through the bounded Devicetree parser;
RV64 preserves a checked DTB copy. The PC reset port discovers QEMU RAM/E820
through fw_cfg. The workspace supplies separately built images to the retained
`arm64_firmware`, `x86_64_firmware`, and `riscv64_firmware` modules.
`src/compile_check.zig` continues to verify the portable interface for all three
architectures.

From the workspace root, `zig build` builds the three primary UEFI applications
and compile probes. `zig build uefi` builds the UEFI set and `zig build test-uefi`
checks its emulator boot paths. `zig build images` includes both UEFI and reset
images; individual `arm64`, `x86_64` and `riscv64` reset build steps remain available.

From this directory:

```powershell
zig build check -Dtarget=aarch64-freestanding-none
```

The package's compile checks support `x86_64`, `aarch64`, and `riscv64`, with
`freestanding-none`. The workspace root orchestrates runtime UEFI applications
and retained reset images. See the workspace README for the pinned Zig toolchain
and named-platform limits.
