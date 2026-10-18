# Installer verification

On 13 October 2026, the native installer completed whole-disk installation on
x86-64 Q35, ARM64 `virt` and RV64 `virt` with pinned Zig 0.17.0 and QEMU 10.2
development firmware. Installer firmware uses ReleaseSafe for responsive GOP
painting; these installed OS images use Debug.

Each architecture passed three owned boots:

1. The installer protects its readonly source, shows one eligible 80 MiB target,
   rejects lowercase confirmation without changing its bytes, then installs
   after actual keyboard entry of exactly `ERASE`.
2. The target alone boots the desktop and mounts its GPT data partition. Notes
   saves `installed\n` under its private owner 108.
3. The target alone boots again. The note's exact bytes/owner and native gray8
   text rendering persist.

Independent checks validate both GPT CRCs and matching entries, the backup
header at the target's actual final LBA, exact ESP bytes against the original
OS image, and the fresh data seed. Source and firmware input hashes remain
unchanged. All three final filesystems reach generation 14. Nine boots and
36 PNG/PPM captures passed independent target/log/pixel/serial-prefix audits.
Thin font strokes are checked using native gray8 blending, including glyphs
that have no completely opaque pixels.

Native checks cover exact consent and cancelled gestures, small viewports and
eight-drive geometry, source-path validation, malformed payloads, zero-write
preflight, two target capacities, unallocated-range preservation, injected
write/read/flush failures and silently ignored writes. Filesystem tests passed
50/50 in Debug and ReleaseSafe; installer tests passed 21/21 in both modes.
Workspace checks and tests also passed in both modes.

Receipts, retained ordinary installed disks and actual UI captures live at
`zig-out/installer-tests/debug/<arch>/installer-<arch>-verification.json`.
The independent audit is `.zig-cache/installer-independent-artifact-audit.json`.
These results qualify the named QEMU/VirtIO machines. Physical SSD drivers,
power-loss qualification, Secure Boot and dual boot remain separate work.

Use `zig build test-installer` to repeat the complete workflow, or
`zig build test-installer-units` for native boundary tests. The
[installer guide](installer.md) documents the architecture, limits and interactive
launch commands.
