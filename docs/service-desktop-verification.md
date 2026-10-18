# Installed service desktop verification

This record covers the primary installed init/compositor/shell/Files desktop on
Bedrock's single-CPU QEMU UEFI references. Kernel modes are Debug and ReleaseSafe;
native user ELF programs retain their size-optimized ReleaseSmall build. Desktop
tests use 256 MiB RAM, modern VirtIO block/keyboard/tablet devices and fresh
ordinary test data images. Physical hardware and GPU qualification are outside
this record.

## Required evidence

Every workflow uses two independently started QEMU processes against the same
ordinary data image. The first boot verifies real Files input, rename, directory
creation, drag move, Ctrl-drag copy, clipboard operations, collision handling,
history, native menus, preview and checked Nullify. It is killed abruptly after
the committed filesystem is read independently. The fresh boot checks the
surviving file bytes, ownership and removed Nullify content.

The second boot also verifies title dragging, maximize/restore, fullscreen,
keyboard Escape, minimize/reopen and two close/relaunch cycles. Actual framebuffer
captures prove native text/controls, changed preview content, window removal and
frosted material samples against the unobscured wallpaper. Serial messages alone
do not establish rendering.

Kernel-authenticated telemetry binds server and shell PIDs across each workflow,
identifies each fresh Files process, and checks five live surfaces while open or
minimized and four after close. Init reaps a retired generation before the next
starts. Files verifies denied global display/input, service registration, launch,
network/Wi-Fi and foreign namespace/bundle-write authority. Minimize retains its
PID and surface. Close retires its private mappings, context, descriptors and
owned pages; retained snapshots return after their final grant is released.

Both persistent and acceptance profiles observe at least one second of liveness
after their final frame. Persistent sessions are stopped by their owning runner.
Acceptance sends F12 only after the full host workflow, then requires exact
baseline balance of allocations, tables, contexts, handles, surfaces, IPC and
quotas before the expected guest exit. F11 remains the actual fullscreen action.

The independent receipt verifier reads explicit saved logs, framebuffer bytes,
both complete logical disk banks and the tested boot image. It rechecks hashes,
PID/resource order, rendered scenes and disk content rather than trusting the
receipt's success flags or following receipt-supplied artifact paths.

## Completed gates

The final desktop matrix passed in Debug and ReleaseSafe: twelve workflows,
24 boots, 24 Files relaunches and six checked acceptance teardowns. Native and
cross-build checks and the broader required regressions passed, including the
unchanged retries below.

| Reference | Debug persistent / acceptance | ReleaseSafe persistent / acceptance |
| --- | --- | --- |
| x86-64 | Passed, four boots | Passed, four boots |
| ARM64 | Passed, four boots | Passed, four boots |
| RISC-V 64 | Passed, four boots | Passed, four boots |

Native tests cover trusted desktop identity/authority, nonblocking parent-only
wait without scheduler mutation, viewport/hidden epochs, exact ACK retirement,
capture and controls, bounded input cancellation, framebuffer conversion,
surface lifetime and mapping/queue rollback. The desktop policy suite has eight
cases; desktop wire/session has five. Twenty-three Python evidence tests reject
malformed/stale PIDs, missing authority markers, invalid resource baselines,
relaunch before reclamation, residual/corrupt disk banks, false pixels/frost,
forged receipts and invalid termination/liveness claims. LF and CRLF logs must
produce the same strict lifecycle proof; embedded malformed telemetry is denied.

The first cross-architecture integration exposed a host-checker line-ending bug:
ARM64/RV64 UART logs use CRLF and the new lifecycle regexes initially expected
LF. Both machines rendered the native desktop, but the checker timed out on
readiness. Complete CRLF sequences are now normalized and regression tested;
the failed attempt remains recorded. Final verification must use the corrected
checker and the final input-overflow fix.

The Debug aggregate completed 624/630 steps before one transient Windows/Zig
read failure for installed `std/math/complex/tanh.zig`. The RISC-V reset target
passed 8/8 steps on an unchanged retry. Other required Debug targets passed;
the initial aggregate is retained as a failed attempt rather than reported as
a single clean pass.

The ReleaseSafe aggregate completed 619/630 steps with all 177 reported native
tests passing. Two standard-library read failures affected the x86-64 headless
persistent kernel (`InstallDir.zig`) and ARM64 Files compile probe (`ElfFile.zig`).
Their focused retry passed 64/64 steps without source or toolchain changes.
Default Debug build/install then passed 420/420 steps. Both aggregates include
cached unchanged checks; failed attempts and successful retries remain recorded.

The required regressions cover the fixed two-client display demonstration,
headless installed applications, reset/UEFI boot, legacy Files input/storage,
NetworkKit, simulated/unavailable Wi-Fi and driver modules. These emulator tests
do not qualify a physical radio or physical computer.

## Reproduction and records

```powershell
zig build test-service-desktop test check desktop -j1 --summary all
zig build test-service-desktop test check desktop -Doptimize=ReleaseSafe -j1 --summary all
zig build test-display test-apps test-boot test-desktop test-network test-wifi test-driver-modules -j1 --summary all
zig build test-display test-apps test-boot test-desktop test-network test-wifi test-driver-modules -Doptimize=ReleaseSafe -j1 --summary all
```

Desktop receipts, serial/error logs, PPM/PNG images and saved data bytes live in
`zig-out/service-desktop-tests/<debug|safe>/<persistent|acceptance>/`.
The completed `.zig-cache/service-desktop-verification.json` binds sources,
build logs, tested images and reverified evidence at this milestone. Subsequent
source changes require new checks.

The earlier fixed two-client `display` demonstration and legacy kernel-hosted
Files workflow remain separate regressions. Their historical records do not
substitute for the installed desktop tests. The
[desktop guide](service-desktop.md) documents current commands, ownership and
limits: one Files window, bounded CPU composition and retained app-2 disk data.
General multi-window launch, tiling/workspaces, edge resizing, display-service
recovery and physical device support remain future work.
