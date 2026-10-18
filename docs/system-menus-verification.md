# Native menus, icons and clock verification

The current [draggable-tab and multi-window checks](tab-windows-verification.md)
qualify the later caption and runtime changes. This page records the earlier menu revision.

The native application/system-menu revision passed dedicated QEMU checks on
13 October 2026 with pinned Zig 0.17.0. The three primary Debug UEFI images
booted on x86-64 Q35, ARM64 `virt` and RV64 `virt`.

Each run checks actual scene pixels and guest results for smooth caption icons,
firmware-based HH:mm time, independent Files/Notes menus, the Bedrock menu and
Control Center. It toggles floating/tiled layout, changes workspaces, changes
display dimming to 25% and restores 100%, dismisses overlays and rejects private
disk changes. The clock must derive from that boot's actual UEFI baseline and
observed timer count; an invented uptime calendar cannot satisfy the check.

The right-side Control Center changes real window policy and composed scene
pixels. It currently provides layout, four workspaces and software dimming.
Window app menus use the public AxisUI borrowed menu API. Icons use original
integer vector coverage and the same antialiased pixel/command painting.
The source-hashed icon oracle detects stale coverage metadata.

The final revision also aligns control text using a shared cap-height baseline.
Menu labels, shortcut hints, shell labels, caption/path fields and rounded
controls keep consistent baselines; icon boxes center independently. Native
labels can select vertical alignment separately from horizontal placement.
Editor/caret geometry and legacy diagnostic placement retain their existing rules.

Trusted system status items support bounded labels, icons, enabled states,
readouts and matched pointer activation. Focused tests cover clipped/hidden
targets, disabled items, changed commands, modal dismissal and pixel guards.
AxisUI's 61 tests, Files' 43 tests and shell's 18 tests passed in Debug and
ReleaseSafe, including painted baseline/descender and ancestor-clipping checks.

```text
zig build test-system-menus check desktop test -j3 --summary all
zig build check desktop test -Doptimize=ReleaseSafe -j1 --summary all
```

Final Debug: 360/360 steps succeeded, including all three normal-image runtime
checks. The last run reported 43/43 newly executed tests; other successful tests
were cached. ReleaseSafe: 347/347 steps succeeded; 163/163 newly executed tests
passed. The complete build receipts are in `.zig-cache/system-menus-verification.json`.

All three runtime checks passed. All 69 saved PNGs were decoded and compared
exactly with their captured PPMs. The clock checks all 576 gray8/background
pixels for its actual HH:mm string, including antialiasing and empty pixels;
it does not depend on a minimum count of fully opaque strokes. The reference
accepts all 1,440 valid time strings. Receipts bind serial prefixes, expected
trusted commands, source coverage and unchanged firmware/boot input hashes.
Only owned QEMU processes, local QMP and freshly seeded ordinary data images
were used. Results qualify these reference machines.

Artifacts are under `zig-out/system-menu-tests/debug/<architecture>/`.
Original tested images are preserved at `.zig-cache/system-menus-debug-images/`.
The final audit is `.zig-cache/system-menus-debug-audit.json`; its 435-file source
manifest is `.zig-cache/system-menus-final-source-snapshot.json`.
Build logs are `.zig-cache/system-menus-complete-debug.log` and
`.zig-cache/system-menus-complete-safe.log`. Runtime boots qualify Debug images;
ReleaseSafe additionally compiles all three images and runs native tests.
The [menu guide](system-menus.md) and [clock contract](wall-clock.md) document
developer APIs, ownership and clock drift limits. Earlier UI reports remain
historical; their scripts and captures were preserved before icon/schema updates.
