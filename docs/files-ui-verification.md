# Compact native Files and window controls

The 2026-10-11 redesign replaces the large two-pane/debug composition with a
single file list, Places sidebar, breadcrumbs, compact named commands and an
optional Split view. The palette follows the supplied dark pastel reference.
Everything is native Zig/AxisUI; no browser or HTML is used.

Files provides back/forward history, Copy/Cut/Paste, sidebar/folder drag-and-drop,
double-click opening, read-only previews and mouse Create/Save/Cancel buttons.
Home-boundary Up is disabled. Names retain case; folder/document icons and file
sizes are drawn natively. Errors use plain messages.

The caption has separate close, minimize, maximize/restore and fullscreen
controls. F11 toggles fullscreen and Escape leaves it. Alt+F4 closes the focused
window. Fullscreen retains a slim exit strip. Minimize preserves the live app;
close tears down descriptors, context, private mappings and owned frames before
a bar/Super+E launch creates a fresh client. The app's committed disk data is
retained. The host checks the allocator baseline after every close.

## Acceptance

The revised `tools/test-desktop.py` drives real VirtIO input on x86-64, ARM64
and RV64. In each Debug/ReleaseSafe workflow it checks:

- Rename, sidebar move and Ctrl-copy, visible copy collisions and cancelled
  outside drops with unchanged disk generation/records.
- Actual Copy/Paste and Cut/Paste, history buttons, mouse file/folder creation
  and double-click text preview.
- Title drag, maximize/restore, fullscreen/restore, F11/Escape and minimize/reopen.
- Two close/relaunch cycles with verified resource reclamation and repeated
  protected startup checks; file contents survive each fresh client.
- Abrupt QEMU termination followed by a fresh boot and independent CRC,
  generation, content and owner validation of the same disk.

Native package suites cover AxisUI layout/clipping/font/icon behavior, Files
controller/provider failure and state preservation, and window capture,
caption release semantics, mode restoration and guarded shortcuts. The current
package counts at this milestone were AxisUI24, Files24 and window policy9 per optimization mode.
The full workspace test/check and all three UEFI smoke paths are also required.

All six revised workflows passed on the three named QEMU references in Debug
and ReleaseSafe. Each workflow boots twice and closes/relaunches the protected
client twice after reboot: twelve normal boots, twenty-four client starts and
twelve checked close/reclamation operations. All workspace native suites,
compile checks and three UEFI smoke tests passed in each mode. Cached unchanged
test results are included; executed-only build summary counts are not totals
for the whole source test inventory.

Reproduce from the workspace root using the pinned compiler:

```text
zig build test check test-uefi test-desktop -j2 --summary all
zig build test check test-uefi test-desktop -Doptimize=ReleaseSafe -j2 --summary all
```

Local build logs and the aggregate receipt are saved under `.zig-cache/`;
`.zig-cache/files-ui-verification.json` identifies this milestone. Per-architecture
workflow receipts and native PPM/PNG captures are under
`zig-out/desktop-tests/{debug,safe}/`. These are generated, ignored artifacts.
Later runs update those capture paths. The separate
[frosted material milestone](frosted-materials.md) records the subsequent blur,
native material drawing and input batching extension.
The later [context-menu and Nullify milestone](context-menus-and-nullify.md)
replaces the mutation strip with native item/background and More menus. Its
independent package, aggregate and QEMU acceptance passed separately on all
three architectures in both modes. That record includes real menu interactions,
six Nullify actions, twelve complete-bank inspections and reboot absence;
the historical results above remain evidence for this preceding UI revision.

## Limits

This remains one protected Files client with kernel-hosted display/input/window
policy. Multiple applications, tiling/workspaces, a standalone compositor and
GPU rendering are future work. Keyboard/tablet queues do not provide a total
timestamp order for arbitrary fast chords; click timing uses hardware tick
progress in the current single-CPU host.

The existing filesystem limits remain 32 total nodes, 4096 mutable bytes per file
and 128-byte internal paths. Read-only previews cover the first 512 bytes;
the app is not a text editor. These QEMU workflows do not qualify physical
hardware. See [desktop design](desktop-design.md),
[storage verification](storage-and-files-verification.md) and
[support](support-matrix.md).
