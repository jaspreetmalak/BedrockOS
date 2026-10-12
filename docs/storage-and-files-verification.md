# Persistent storage and native Files verification

Verified on 2026-10-11 with Zig 0.17.0 and QEMU 10.1 on Windows. The normal
UEFI images launch a protected native Zig Files executable and use a dedicated
writable VirtIO disk. No browser or HTML is involved.

| Check | Debug | ReleaseSafe |
| --- | --- | --- |
| Native Zig tests, fresh local caches | 282/282 | 282/282 |
| Python disk formatter tests | 6/6 | 6/6 |
| Required freestanding architecture/component checks | Passed | Passed |
| Reset/UEFI boot matrix | 18/18 | 18/18 |
| ARM64 Files workflow and recovery | Passed | Passed |
| x86-64 Files workflow and recovery | Passed | Passed |
| RV64 Files workflow and recovery | Passed | Passed |
| x86 UEFI kernel at physical `0x100000000`, 4096 MiB RAM | — | Passed |

The native counts include repeated tests reached through relative imports in
30 test executables. Each boot matrix covers nine reset regressions at
64/128/512 MiB and nine UEFI boots at 128/256/512 MiB. The reset regressions
retain their memory/exception scope. The UEFI boots also exercise persistent
storage, protected process loading, IPC, descriptors, pipes, exec and cleanup.

## Interactive acceptance

Each architecture/mode workflow uses a newly formatted ordinary 4 MiB image,
real VirtIO keyboard/tablet events and the actual protected Files ELF. It:

1. Checks rejected physical pointers, writes to bundle/code memory and traversal
   attempts through the live syscall boundary.
2. Renames the welcome file, drags it to Downloads, Ctrl-drags a copy back,
   deletes that copy, and creates a directory and file through native controls.
   A colliding copy shows a native error; dropping outside the client is
   cancelled. Independent generation/record comparisons confirm neither
   rejected operation changes the disk.
3. Independently reads both disk banks and validates their headers, generation
   and CRCs before interpreting committed directory records and file bytes.
4. Abruptly kills the owned QEMU process, then boots a fresh process with the
   same disk without formatting or exporting its contents.
5. Confirms the saved paths, exact file bytes and app-2 ownership after reboot.
6. Opens and dismisses the native text preview, drags the title bar, minimizes
   and reopens Files. Framebuffer pixels verify the window state changes.

Six two-boot workflows cover twelve normal boots. ARM64 and RV64 use 800×600
framebuffers; x86-64 uses 1280×800. Firmware templates and boot media use
read-only/snapshot attachments. Only owned temporary data images are writable
in acceptance runs. Interactive launchers instead retain
`zig-out/data/<architecture>.img`, creating it only when missing.

The filesystem's native tests additionally inject failures at payload writes,
payload flush, header writes and final flush. They check recovery into a fresh
instance, corruption fallback, malformed valid-CRC records, stale node IDs,
subtree transactions and namespace authority. Successful device flushes are
the durability contract; CRCs are integrity checks, not cryptographic protection.

## Reproducing

Run from the workspace root:

```text
zig build test check test-boot-matrix -j2 --summary all
zig build test-desktop -j2 --summary all
zig build test check test-boot-matrix -Doptimize=ReleaseSafe -j2 --summary all
zig build test-desktop -Doptimize=ReleaseSafe -j2 --summary all
zig build test-uefi-x86_64 -Doptimize=ReleaseSafe -Dram-mib=4096 -Duefi-kernel-min=4294967296 --summary all
```

Use `tools/zig.ps1` or `tools/zig.sh` for the pinned zvm compiler. Individual
desktop steps are `test-desktop-arm64`, `test-desktop-x86_64` and
`test-desktop-riscv64`. Python 3 and the documented EDK2/QEMU paths are required.
PNG captures additionally use Pillow when available; the harness always saves
PPM captures. It cleans up its own emulator after success or failure, including
malformed diagnostic captures.

Local evidence is saved in `.zig-cache/persistent-verification.json`, build
logs, and `zig-out/desktop-tests/{debug,safe}/desktop-<architecture>-verification.json`.
These generated artifacts are ignored by source control.

## Limits

This is the named QEMU storage/input profile. Physical PCs and boards, NVMe,
AHCI, USB storage/input, noncoherent DMA and power-loss behavior on actual
devices remain unqualified. The durable format has 32 total nodes, including
directories and bundle overlays, and 4096 bytes per mutable file. Backend paths
have 128 bytes; the hidden app identity prefix reduces the user-visible limit.

Files has a private address space and an eight-descriptor table. Drawing is
clipped to its client region; disk, framebuffer and raw input access remain in
the kernel. The kernel currently hosts a single window and input/display policy;
a standalone protected compositor, multiple clients, general installation and
full app resource accounting remain future work. Ctrl intent is retained from
drag start or accepted at release; independent keyboard/tablet queues do not
provide a total timestamp order for arbitrary fast chords.

See [the format contract](persistent-filesystem.md),
[Unix I/O](unix-io.md), [desktop design](desktop-design.md) and
[the support matrix](support-matrix.md).
