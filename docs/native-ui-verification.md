# Axis Sans and native header verification

Verified on 12 October 2026 with pinned Zig 0.17.0 on the named QEMU UEFI
reference machines. This report covers the original Axis Sans font and the
integrated header revision; the [earlier window runtime results](window-desktop-verification.md)
remain preserved with their original source hashes and archived artifacts.

| Kernel mode | x86-64 Q35 | ARM64 `virt` | RV64 `virt` |
| --- | --- | --- | --- |
| Debug, persistent and acceptance | Passed | Passed | Passed |
| ReleaseSafe, persistent and acceptance | Passed | Passed | Passed |

The independent audit passed 12 workflows, 24 fresh boots,
6 contained Notes CPU faults and 6 balanced teardowns.
All 198 required PNG previews match their captured PPM pixels exactly.
The final matrix used one frozen 428-file source/assets manifest,
including architecture assembly, the font generator and generated glyph binaries.
User ELFs remain ReleaseSmall in both kernel modes.

## Native changes and functional proof

Axis Sans is an original proportional humanist face, generated from repository-owned
vector glyph definitions into a 95-glyph grayscale atlas. The generator uses
8×8 supersampling; native painting blends coverage into the actual surface.
The shared measurement and painting APIs use integer operations and no allocations.
The atlas and advance table total 18,335 bytes. No external font file is bundled.
Current coverage is printable ASCII; unsupported bytes use a question-mark fallback.
The explicit legacy text switch preserves the earlier diagnostic font contract.
See [Axis Sans sources and metrics](../frameworks/public/AxisUI/AXIS_SANS.md).

Primary windows put the trusted app name on the left and neutral Minimize,
Maximize/Restore and Close buttons on the right. A client can opt into the
center accessory through `WindowOptions.header_content`, then obtain its
bounds through `Session.headerLayout()`. Files uses that region for a sleek
path field; Notes retains a service-painted caption. Fullscreen uses F11/Escape.
The compositor clips client header pixels and pointer input to the accessory;
apps cannot overwrite or activate privileged caption controls through their surfaces.
The [window guide](window-desktop.md) documents the SDK and protocol checks.

Every complete workflow exercises Ctrl+L and a header click, manual
`~/Downloads` and `~/Documents` entry, and rejection of a file-as-directory
and private-container traversal. Failed navigation preserves the current
directory. Path editing preserves the app PID and raw disk bytes.
The host waits for the active field and error paint before Escape and a
tablet click; saved scene evidence requires all three right control borders
and actual rejection-status pixels. Strict log prefixes bind captures to
their processed path events. The independent gate has 21 positive/negative
tests, including erased controls with fresh matching hashes and missing
visible rejection status.

The 42-case native Files suite includes path transaction rollback, selection,
minimum/strided rendering and releases over the header that must cancel body
gestures without starting a path edit or invoking a destructive action.
AxisUI has 37 focused native cases, including proportional metrics, grayscale
coverage, clipping and direct/command surface rendering. Header, policy,
protocol, lease, init and Notes navigation suites also pass through the root checks.

The runtime workflows additionally preserve file create/rename/copy/drag/delete,
two-bank logical Nullify, private Notes Save and an unclean reboot of the
same ordinary data disk. They verify both tiled apps, four workspaces,
focus routing, caption dragging, minimum resizing, fullscreen, minimize/restore
and independent close/relaunch. An acceptance-only real CPU write fault
restarts Notes while Files, shell and display service retain their PIDs.
Final acceptance requires balanced physical pages and zero charged processes,
handles, IPC bytes, surfaces, connections and queued messages.

## Commands and retained artifacts

```text
zig build test-window-desktop test-window-units check desktop -j3 --summary all
```
Build Summary: 275/275 steps succeeded; 42/42 tests passed.

```text
zig build test-window-desktop test-window-units check desktop -Doptimize=ReleaseSafe -j3 --summary all
```
Build Summary: 275/275 steps succeeded; 147/147 tests passed.

```text
zig build test test-desktop-x86_64 test-service-desktop-x86_64 test-display -j3 --summary all
```
Build Summary: 261/263 steps succeeded.

All native tests, legacy x86 Files and all six protected-display boots passed. Service persistent passed; acceptance row-selection ordering was fixed and both service workflows repeated successfully in the focused command.

```text
zig build test test-service-desktop-x86_64 -j1 --summary all
```
Build Summary: 171/171 steps succeeded.

```text
zig build test -Doptimize=ReleaseSafe -j1 --summary all
```
Build Summary: 140/140 steps succeeded; 55/55 tests passed.

The retained kernel-hosted Files and protected single-window Files profiles
also passed the x86-64 runtime regressions. The protected-display regression
passed on all three architectures. Their separate receipts remain in their
own output directories.

Earlier attempts remain recorded: an intermittent installed Zig `std/Thread.zig`
`Unexpected` read error passed on exact ARM64 retry. The first two x86
attempts exposed host paint checks that assumed the old solid bitmap font;
those helpers were corrected for antialiased text before the final matrix.
Review then strengthened path paint barriers and narrow helper geometry.
The combined retained regression then exposed three checks that assumed
fully opaque old-font pixels: launcher paint, display text and a Shell
native test. Those assertions now count the exact expected text/background
coverage blends; the display fixture still rejects absent or unrelated text.
The protected-display and legacy Files checks passed on retry. The retained
service acceptance harness also required a row-selection paint barrier before
sending F2; both of its workflows passed in the focused final command.
An intermediate native test edit used incorrect color field names; they were
corrected before the successful native checks.

These five post-matrix edits affect retained-profile test helpers and a Shell
test assertion. The Shell production declarations are byte-identical; Python
AST comparisons verify that only the specified compatibility checks changed.
The new single-window click barrier is guarded to exclude the primary runner.
The original matrix scripts remain saved in `.zig-cache/native-ui-matrix-tools/`.
The runtime, glyph assets and exercised primary scene logic stayed unchanged.
The record includes both manifests and each test-only delta.

Artifacts are under `zig-out/window-desktop-tests-before-glass/<debug|safe>/<persistent|acceptance>/`.
Persistent workflows require 16 scenes; acceptance adds the recovered-Notes scene.
Receipts bind the actual serial/stderr, process generations, frame flags/epochs,
boot-image hashes, both independently decoded disk banks and raw PPM pixels.
The auditor reads explicitly selected artifact paths rather than paths from a receipt.

```text
python .zig-cache/native-ui-matrix-tools/tools/verify-window-desktop-artifacts.py zig-out/window-desktop-tests-before-glass/debug/persistent --arch x86_64
```

Build logs are retained in `.zig-cache/native-ui-build-logs/`; the
[machine-readable record](../.zig-cache/native-ui-verification.json) contains
all source, image, artifact and command hashes. The frozen matrix manifest is:

```text
3744ede00c19b62763ff757494fa21a03bad87892e804e71afb6f38d10794085
```

The current manifest includes the compatibility test corrections:

```text
8517a54afd21b2340d0151671c6184f5c011f8f3b798e2f005cdc2ed028ae454
```

## Qualification bounds

The supported test catalogue remains two GUI apps, one window per process
and four workspaces. Displays are bounded to 800×600 through 1280×800.
A minimum 320×240 frame gives Files a 316×236 integrated client viewport
with a 32-pixel header and 316×204 body. Notes remains a 4096-byte ASCII editor
with smooth glyphs in fixed 12-pixel editing cells.

Input remains polled; separate VirtIO keyboard/tablet queues have no shared
arrival timestamp. Paint barriers make the test ordering explicit without
removing that runtime limitation. These results qualify the named emulators,
not arbitrary physical computers, GPUs or installed third-party applications.
