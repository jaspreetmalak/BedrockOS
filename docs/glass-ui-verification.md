# Glass desktop verification

This report covers the native glass revision on the named QEMU UEFI reference
machines with pinned Zig 0.17.0. All six Debug runtime workflows passed on one
frozen source manifest: 12 fresh boots, three contained Notes CPU faults and
three balanced acceptance teardowns. All 99 required PNG previews match their
captured PPM pixels exactly. Original boot-image bytes are explicitly bound to
each receipt, and all 429 current source/assets hashes match the manifest.

| Reference | Debug persistence/lifecycle | Debug fault acceptance |
| --- | --- | --- |
| x86-64 Q35, 1280×800 | Passed | Passed |
| ARM64 `virt`, 800×600 | Passed | Passed |
| RV64 `virt`, 800×600 | Passed | Passed |

The workflows include private file operations and unclean reboot, path editing
and rejection, right-hand window controls, tiling, four workspaces, focus,
caption dragging, minimum resizing, fullscreen, minimize/restore and independent
close/relaunch. Fault acceptance restarts Notes while the other protected
processes survive, then requires zero charged resources after teardown.

## Rendering changes

Floating frames use antialiased 16-pixel corners, a soft quadratic shadow and a
thin translucent rim. Window controls are quiet outline icons with rounded
hover/press backgrounds. Files and Notes use lighter graphite glass, rounded
controls and a shared muted palette. A continuous charcoal/rose/blue wallpaper
and rounded launch pills replace the sharp wallpaper planes and bar blocks.
See the [appearance and ownership contract](glass-desktop.md).

AxisUI supplies reusable signed rounded solid/material/border primitives and
opt-in antialiased view clipping. Material representation stays tint/opacity.
An optional covered-material command callback preserves receiver ownership of
the blur source. Existing fallback backends keep bounded behavior.

## Focused native evidence

AxisUI's 42 cases pass in Debug and ReleaseSafe. They include radius clamping,
half-open and extreme geometry, offscreen/stride guards, nested rounded
clipping, immutable backdrop storage, repeat-frame consistency and exact
pixel/command rendering parity. An independent full-pixel border reference
covers 17 signed, clipped and degenerate geometries. An independent nested
paint reference covers six ancestor/child radius and border combinations.
Large flat regions use bulk painting; curved edges retain subpixel checks.

Files' 42 cases pass in both modes, including material command forwarding,
rounded popup/path parity and a stable header redraw after adversarial old
pixels. Shell's seven cases pass in both modes, including continuous bounded
wallpaper shading and identical pixel/command output. Two compositor cases
verify that opaque client paint cannot square off rounded corners, and that
offscreen masks and shadows preserve stride guards.

The screenshot gate checks actual Minimize, Maximize and Close glyph pixels
after Files renders its centered accessory. Its 21 positive/negative fixtures
still reject an erased privileged control even with fresh matching hashes,
missing rejection paint and inconsistent logs, geometry, disk data or PPMs.

## Input and resources

Keyboard and pointer remain independently polled. The runtime host waits for
actual selection/path paint and, before Ctrl-drag, a real Ctrl+C result's
clipboard footer. Notes typing waits for each new visible caret before the next
key. These gates qualify guest consumption and exact saved bytes; they do not
qualify arbitrary synthetic bursts or remove the existing input queue limits.

The initial compositor snapshot exhausted the guarded 16 KiB stack: emitted
x86 code reserved 13,064 bytes in composition on top of its caller's 3,896.
Pointer capture into service-owned static scratch reduced the compositor frame
to 760 bytes. Notes owns 128,000 additional bytes for its private blur arrays;
the existing image and permission allowances are unchanged.

Earlier integration attempts are retained in `.zig-cache/glass-*.log`.
They exposed stale host color assumptions, input timing and intermittent
installed Zig standard-library read errors. Source repairs address the
rendering/stack costs; paint acknowledgements address host input sequencing.

## Source and retained evidence

```text
zig build test-window-desktop check desktop test -j3 --summary all
```

All runtime workflows passed; Build Summary: 376/379 steps succeeded,
128/128 tests passed. The sole failed branch was a transient installed Zig
`std/c/openbsd.zig` read error while compiling the retained ARM64 shell.
The exact checks passed on single-job retry, without source changes:

```text
zig build check desktop test -j1 --summary all
```

Build Summary: 341/341 steps succeeded.

```text
zig build check desktop test -Doptimize=ReleaseSafe -j1 --summary all
```

Build Summary: 341/341 steps succeeded; 128/128 newly reported native tests
passed. All three architecture builds pass in both modes. The runtime matrix
above uses Debug kernels; ReleaseSafe is a native/build qualification here.
User-space programs use ReleaseSmall in both kernel build modes.

The finalized 429-file source/assets manifest includes architecture assembly,
font metadata, glyph binaries and all verification Python sources:

`d86a950a6bd12fc22505ddfb5dcc13062ddc686392a19dfe9ad4be2b80be52f0`.

It is saved at `.zig-cache/glass-final-source-snapshot.json`; matching host tools,
font metadata and atlas are at `.zig-cache/glass-final-tools/`.
The full image-bound audit is `.zig-cache/glass-debug-audit.json`; the independent
five-workflow audit, completed before the final ARM64 acceptance run, is
`.zig-cache/glass-partial-independent-audit.json`. Copied original Debug installed
images remain at `.zig-cache/glass-debug-installed-images/`, so a later
ReleaseSafe installation does not replace the image bytes used for that audit.
Earlier native UI captures remain at `zig-out/window-desktop-tests-before-glass/`
with their [original verification report](native-ui-verification.md).

Runtime captures, serial logs, ordinary before/after data images and receipts
use `zig-out/window-desktop-tests/debug/<persistent|acceptance>/`.
Only owned QEMU processes and freshly seeded ordinary data files are used.
These checks qualify the reference emulators, without extending physical
computer or GPU/driver support.
