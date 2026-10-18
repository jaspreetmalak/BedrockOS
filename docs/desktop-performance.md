# Desktop performance

The desktop uses software rendering and QEMU TCG on the reference Windows
host. Interactive runs should use `-Doptimize=ReleaseSafe`; Debug is intended
for diagnostics. These changes reduce work toward a 16.7 ms frame budget,
but do not establish sustained 60 FPS or synchronized presentation.

## Rendering changes

- A retained scene and 432-byte cursor save-under buffer replace full scene
  rendering for pointer-only changes. Scanout visits at most two 6×18 patches,
  rather than 1,024,000 pixels at 1280×800. Full scene changes take priority.
- The kernel validates source/destination rectangles, strides and byte spans
  before copying. Partial source regions require a display-service-owned
  full-monitor surface in the window profile. Other profiles retain their
  whole-source placement semantics; application display permissions are unchanged.
- Captions and opaque cached viewports cover the inner frame. Their material
  background is painted only along the exposed rim once a cache exists.
- A last authenticated window snapshot can remain visible across translation
  while its app renders the new configuration. Reuse checks app, process and
  window identity, dimensions and header ownership. Current-epoch frame
  validation, readiness and ACK fences remain independent of visual reuse.
- Wallpaper vertical geometry calculations are shared across each row. A bounded,
  lossless palette/span cache then avoids recalculating colors during full
  composition. Its 221,468 bytes reuse the temporary blur storage after boot;
  the compositor remains within its 512 KiB writable-data grant. An unavailable
  cache falls back to procedural rendering. No extra graphics surface is allocated.

The public procedural renderer keeps only three row terms on its stack. A
candidate with a larger column scratch array passed native pixel tests but
overflowed Files' 16 KiB stack during real boot; the boot check caught it before
the interactive launch. The scratch array was removed instead of increasing
the application's stack grant.

The cursor layer captures the already dimmed background and paints the cursor
with matching dimmed colors. Full paints invalidate it before touching the
scene, preserving glass, brightness changes and overlapping-window pixels.
Physical scanout submissions have a separate sequence from the full-frame
counter used to release client ACKs.

## Measurement

[test-desktop-performance.py](../tools/test-desktop-performance.py) boots a
specified immutable image with a fresh disposable data disk. It records image
and firmware hashes, host-clock input-to-observed-cursor latency, screenshot
overhead, a bounded 60 Hz input trace and an optional real Notes-window drag.
It checks exact cursor background restoration, process identity and unchanged
disk bytes. The script stops only its own QEMU process.

```text
python tools/test-desktop-performance.py --image zig-out/desktop/x86_64/bedrock-desktop.img --label local-releasesafe --with-drag
```

Screenshot polling gives latency upper bounds; sending 60 inputs per second
does not prove 60 displayed frames per second. Drag measurements describe one
24×16-pixel translation, rather than a sustained drag frame rate. Comparison
between the previous Debug build and ReleaseSafe combines the build-mode and
renderer changes.

QEMU's WHPX backend initialized on this host but failed during actual UEFI
execution, both with the normal interrupt controller and software IRQ-chip
configuration. The launcher therefore retains TCG. No Windows features or
firmware settings were changed.

### Recorded x86-64 comparison, October 18, 2026

Windows 11, Ryzen 7 7800X3D, QEMU 10.1.94 Q35/TCG, one virtual CPU,
1280×800 display and 256 MiB guest RAM:

| Host-observed operation | Previous Debug image | Final ReleaseSafe image |
| --- | ---: | ---: |
| Cursor input to visible observation, median of 8 | 888 ms | 26.10 ms |
| Cursor input to visible observation, p95 | 1,067 ms | 33.31 ms |
| Single Notes window drag | 1,222 ms | 94.77 ms |
| Last event of a 60-event/60 Hz cursor trace to visible endpoint | 1,779 ms | 28.36 ms |
| Screenshot-only overhead, median | 12.7 ms | 10.30 ms |

The final trace reached its endpoint and both cursor-trail checks matched the
exact original background pixels. Private data stayed unchanged and no process
fault occurred. These results describe latency improvements, not a measured
displayed frame rate. In particular, the single drag still exceeds 16.7 ms.
Idle/power efficiency is not established: the short idle sample consumed about
two host CPU cores in both builds.

The executed final image SHA-256 is
`cb23f9d22c483dc90fc39c54180e1658cf06c2b63f743012c5d9f5dfff13a3ef`.
Machine-readable receipts are retained locally:

- [Previous cursor run](../zig-out/desktop-performance/baseline-debug-tcg-verification.json)
- [Previous drag run](../zig-out/desktop-performance/baseline-debug-drag-verification.json)
- [Final run and source audit](../zig-out/desktop-performance/final-releasesafe-tcg-r2-verification.json)
- [Caught stack regression](../zig-out/desktop-performance/failed-final-boot-verification.json)

## Verification

`zig build test-window-units -j1` includes region bounds/stride tests, exact
cursor comparisons across all 256 brightness values, overlap/clipping and
background restoration, redraw policy, retained-frame identity checks,
frame-rim pixel equivalence, wallpaper/cache equivalence and palette-limit
fallbacks. The renderer helpers pass Debug and ReleaseSafe checks.

`zig build test-system-menus -Doptimize=ReleaseSafe -j1` exercises the real
native desktop through QEMU input and pixel checks on x86-64, ARM64 and RV64.
The final ReleaseSafe build passed 59 scene checks per architecture, including
menus, dimming, window controls, tab reordering/tear-off and retirement. Each
run retained unchanged private disk bytes and matching source hashes:

- [x86-64 receipt](../zig-out/system-menu-tests/safe/x86_64/system-menus-x86_64-verification.json)
- [ARM64 receipt](../zig-out/system-menu-tests/safe/arm64/system-menus-arm64-verification.json)
- [RV64 receipt](../zig-out/system-menu-tests/safe/riscv64/system-menus-riscv64-verification.json)

`check`, `desktop` and `test-window-units` also passed together in ReleaseSafe.
Performance measurements are host- and architecture-specific; they do not
qualify physical hardware, a GPU compositor or a display refresh guarantee.
