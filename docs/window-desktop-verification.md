# Native window desktop verification

This is the retained verification of the window runtime **before** the Axis Sans
and integrated header revision. Its artifacts were moved to
`zig-out/window-desktop-tests-before-native-ui/`; the matching verifier tools
are preserved in `.zig-cache/window-desktop-before-native-ui-tools/tools/`.
The source and image hashes below describe that earlier revision. Current
typography and header results are recorded separately in
[native UI verification](native-ui-verification.md).

The window desktop runs init 101, display service 104, shell 107, Files 2 and
Notes 108 as five native protected processes. This report concerns the named
QEMU UEFI reference machines, using the pinned Zig 0.17.0 toolchain. It does not
qualify physical computers, GPUs, radios or arbitrary installed applications.

## Runtime matrix

| Kernel mode | x86-64 Q35 | ARM64 `virt` | RV64 `virt` |
| --- | --- | --- | --- |
| Debug, persistent and acceptance | Passed | Passed | Passed |
| ReleaseSafe, persistent and acceptance | Passed | Passed | Passed |

Verified on 12 October 2026: twelve workflows, 24 fresh boots, six contained
Notes CPU faults and six balanced acceptance teardowns. All final workflows
used the same 403-file source manifest. The independent audit also confirmed
that all 174 required PNG previews match their captured PPM pixels exactly.

Each architecture/mode runs two complete workflows. Each workflow boots a fresh
ordinary data image, drives real VirtIO keyboard/tablet input, kills its first
owned QEMU process without guest shutdown, and boots the committed disk again.
Acceptance ends only after the host requests F12 and the kernel proves balanced
teardown. Persistent mode remains alive until the host stops its owned process.
User executables use ReleaseSmall in both kernel modes.

The [runner](../tools/test-window-desktop.py) checks native Files operations,
two-bank logical Nullify, private Notes Save, raw disk preservation across reboot,
two painted tiled clients, all four workspaces, moving a window between them,
keyboard focus routing/cycling, caption dragging, 320×240 window resizing,
fullscreen/Escape, minimize/restore, independent close/relaunch and retained
desktop-service identities. The corresponding Files client viewport is 316×204.

The acceptance workflow sends Ctrl+Shift+F5 to Notes. Notes performs a real CPU
store into its RO/NX startup page. The kernel records the contained fault; init
reaps status 139, waits for retirement of the old surface generation, and starts
a new Notes process that loads the same private saved bytes. Files, shell and
display service retain their PIDs. Normal builds ignore this test shortcut.

## Ownership and saved evidence

Ready desktops have five processes and six surfaces: two client producers, one
Shell producer, two service caches and one service scene. Closing either GUI
client leaves four processes and five surfaces. The service retains only the
Shell's 36-row bar, while regenerating the procedural wallpaper and sampling an
immutable wallpaper blur source.

Final acceptance checks physical allocator free/allocated counts against the
pre-session baseline and requires zero charged pages, processes, handles and IPC
bytes, with no live pipes, sockets, surfaces, connections or queued messages.

Artifacts are saved under:

```text
zig-out/window-desktop-tests-before-native-ui/<debug|safe>/<persistent|acceptance>/
    window-desktop-<arch>-verification.json
    window-desktop-<arch>-first.log
    window-desktop-<arch>-reboot.log
    window-desktop-<arch>-{first,reboot}-<scene>.ppm
    window-desktop-<arch>-{first,reboot}-<scene>.png
    window-desktop-<arch>-before-reboot.img
    window-desktop-<arch>-final-data.img
```

Fourteen required screenshots cover persistent workflows; acceptance adds a
recovered-Notes screenshot. Each receipt binds actual serial/stderr, image and
disk hashes, process generations, kernel counts, configurations and screenshot
bytes. Scene records also bind the serial prefix that supplied their geometry.
The verifier independently decodes both filesystem banks and actual PPM pixels.
The [artifact auditor](../tools/verify-window-desktop-artifacts.py) rechecks
explicit saved paths without following paths selected by a receipt:

```text
python .zig-cache/window-desktop-before-native-ui-tools/tools/verify-window-desktop-artifacts.py zig-out/window-desktop-tests-before-native-ui/debug/persistent --arch x86_64
```

## Native checks and limits

The window policy has twelve native tests, including stable tiled columns and
viewport epochs through focus changes. Files has 34 native tests, including
minimum/narrow guarded rendering, menus, editing, split collapse and stride
preservation. The evidence gate has fifteen negative/positive tests that reject
forged or retired identities, incorrect close counts, reordered CPU-fault
records, stale configurations, mixed profiles and hidden-window pixels.
The SDK additionally checks provenance, bounded requests, hidden viewports,
exact acknowledgements and outstanding leases across configure changes.
Its ten native tests include a close arriving before the first configuration,
with no surface allocation, and closure taking precedence over a queued
configuration. Three init lifecycle tests cover early clean closure, a reopen
request arriving before the old process is reaped, and fault restart after
lease retirement while the other client stays ready. Four Notes navigation
tests cover repeated vertical moves across full soft wraps, hard newlines,
one-column wrapping and empty/partial EOF rows. These checks run in both kernel
build modes through `test-window-units`.

The initial catalogue supports two GUI applications, one window per process,
four workspaces and 800×600 through 1280×800 displays. Notes is an ASCII editor
with a 4096-byte private file. It is not a general GUI installation interface or
a GPU/session-service implementation.

Input remains polled. Different VirtIO devices provide no common arrival
timestamp, so queued keyboard and tablet events can be observed in a different
order. Tests wait for actual selection, caret or keyboard-response paint before
changing focus or switching input devices. An interrupt-driven input broker is
future work. Captured emulator results do not remove this limitation.

## Commands and retained record

Final Debug verification completed 275/275 build steps, with 34/34 newly
reported native tests. Final ReleaseSafe verification completed 404/404 steps,
with 78/78 newly reported native tests; cached native suites also passed.

```text
zig build test-window-desktop check desktop -j1 --summary all
zig build test-window-desktop check test-apps test-display desktop -Doptimize=ReleaseSafe -j1 --summary all
```

The ReleaseSafe aggregate additionally passed all nine installed-application
runtime boots and six protected-display runtime boots. Those profiles preserve
their own receipts. The earlier final Debug aggregate passed those same runtime
regressions, but one compile-only ARM64 target hit an intermittent installed
Zig `std/zig/parser_fuzz.zig` read error (`Unexpected`). The focused
`check-aarch64 test-window-units test-service-desktop-x86_64` retry passed
104/104 steps, including both retained x86-64 service-desktop workflows.
Review then corrected early window closure, reopen-request consumption and
Notes soft-wrap caret movement. The final desktop matrix above was rerun after
those fixes, with no failures. The first ReleaseSafe attempt was intentionally
interrupted for the fixes; it is preserved separately from the final run.

Build logs are retained under `.zig-cache/window-desktop-build-logs/`.
The [machine-readable record](../.zig-cache/window-desktop-verification.json)
contains explicit artifact and installed-image hashes, source hashes, commands,
counts and qualification bounds. Its source manifest SHA-256 is:

```text
1d81238d6b2dfe7c017542fea6423229641d3044b7cadcc86bc4995373119e76
```

The [native window guide](window-desktop.md) describes controls, SDK use and
protocol boundaries. The earlier [single-window service desktop](service-desktop.md)
and [verification report](service-desktop-verification.md) remain separate
historical regression profiles.
