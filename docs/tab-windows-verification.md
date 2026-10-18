# Draggable tabs and detached windows

The 17 October 2026 revision uses pinned Zig 0.17.0. Files has a left-aligned
native tab strip without a separate visible Files caption. Horizontal dragging
reorders tabs; releasing above or below the strip moves a tab into a real
window. Four Files windows share one authenticated process connection, with
eight navigation tabs per window.

| Reference machine | Framebuffer | Dedicated QEMU result |
| --- | --- | --- |
| x86-64 Q35 | 1280 × 800 | Passed |
| ARM64 `virt` | 800 × 600 | Passed |
| RV64 `virt` | 800 × 600 | Passed |

The native interaction checks exercise both reorder directions, the lifted
tab/insertion marker, a small pointer movement, Escape cancellation and a drop
outside the original window. They verify actual caption glyphs, folder labels,
editable paths and window controls in the resulting two Files windows.

The destination retains Documents → Downloads Back/Forward history. Its tab
receives a fresh identity scoped to the destination window. The source removes
its record only after the destination's current configure epoch has an accepted
visible frame. Native transfer tests also cover checked-listing failures and
stale receipts without losing the source navigation.

The detached window moves, focuses, minimizes, restores through the Files chip
and closes independently. Kernel observations must show eight live surfaces
and five processes with the extra window, then six surfaces and the same five
processes after its producer and cache retire. The original Files PID and its
remaining tab survive. Presentation operations must leave private disk bytes
unchanged.

A separate x86-64 smoke closes the final Files window, observes status-zero
reclamation while Notes continues, and launches Files again. Surface/process
counts return through `6/5 → 4/4 → 6/5`; the new Files PID starts with WindowID 0,
tab ID 1 and an acknowledged frame. Disk bytes remain unchanged. Its receipt is
`zig-out/last-files-window-smoke/last-files-window-verification.json`.

The 600-pixel-high profiles resize and move the detached window before the
combined text probes, keeping its shadow below the original path. Exact glyph
and icon RGB checks remain enabled; focused and inactive controls have separate
expected colors. The usual maximize/fullscreen, keyboard tabs, tiled layout,
workspaces, app menus, clock and Control Center checks run as well.

```text
zig build check desktop test-window-units -j1
zig build test -Doptimize=ReleaseSafe -j1
zig build test-system-menus-x86_64 -j1
zig build test-system-menus-arm64 -j1
zig build test-system-menus-riscv64 -j1
```

Debug and ReleaseSafe native suites pass. Window policy, Hub routing and kernel
message checks cover scoped IDs, cross-window ACK rejection, retired-ID handling,
bounded capacity, pointer capture and caption authority. The full ReleaseSafe
native test target passes, including resource ownership and IPC lifetime tests.

Font coverage is packed at compile time by removing blank glyph margins.
Original assets, metrics and every output pixel remain unchanged. Exhaustive
native tests compare all byte values with the original gray8 atlas. Files remains
within the existing 128 KiB executable-code and 512 KiB writable-data grants.

Per-architecture receipts and native PNG/PPM captures live under
`zig-out/system-menu-tests/debug/<architecture>/`. Receipts bind boot input
hashes, pixel-reference source hashes, captured serial prefixes, PNG/PPM identity,
trusted command order, resource observations and unchanged disk contents.
The README's native captures are bound by [screenshot provenance](images/screenshots.json).
Each passing run contains 59 native scenes, for 177 verified PNG/PPM pairs.

These results qualify the named virtual-machine profiles. Earlier single-window
verification reports describe their original revisions.
