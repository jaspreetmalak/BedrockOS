# Protected display verification

The protected display foundation is qualified on Bedrock's single-CPU QEMU UEFI
references with Zig 0.17.0. The completed results below cover x86-64, ARM64 and
RV64, using modern VirtIO storage/keyboard/tablet devices and fresh ordinary
container-disk images. No physical machine or GPU was used.

## Required display evidence

| Profile | Evidence |
| --- | --- |
| Acceptance | Three revoked-address faults and three clean restarts for A; the service and B retain their original processes; seven A surface generations ultimately reclaimed; final allocations, private tables, contexts, handles, queues, pipe bytes and quotas return to baseline |
| Persistent | One A fault and clean restart; both windows render and react to focused input; init, service and clients remain running for at least one second after readiness |

The dedicated host runner reads actual framebuffer pixels through QMP. Its
first screenshot requires both native text and controls, with pink A and blue B.
It clicks B's Toggle accent control and requires green B, unchanged pink A and
the corresponding focused-input marker. A blank pair of coloured rectangles
does not satisfy this gate. Acceptance sends F11 only after both screenshots
are verified, allowing the test kernel to perform and check final teardown.
F11 does not end normal production sessions.

Init checks architectural fault exit status 139, clean exit status 23, the
service PID, close notifications and continued B presentation before each
replacement. Kernel-owned counters independently check exact startup and fault
counts, presentation progress, read-map releases and surface reclamation before
accepting readiness. A's fault comes from an actual load through its previously
revoked virtual address after the ACK; release never silently reinstalls it.
This is a bounded liveness observation, rather than a long-duration soak test.

Portable native tests cover writer/reader transitions, PID and app provenance,
read-only grants, producer death while snapshots are retained, mapping/queue
failure rollback, FIFO/backpressure, closure delivery, service death, exact-once
reference return, stale identities and generation exhaustion. Sandbox tests
cover default denial, foreign surface ownership and rights widening. Wire and
policy tests reject malformed records, slot aliases, stale peers and frame
sequences. Framebuffer tests cover RGB/BGR, sparse and wide masks; x86 table
validation tests permit only the hardware Accessed update on nonleaf pointers.

Fourteen Python regressions test the evidence checker itself, including
correct-count/wrong-order logs, early reclamation, missing completion, panic,
stale hashes, wrong focus, missing native text, malformed PPM images, short
persistent liveness and forged receipt fields. The pure receipt verifier takes
explicit artifact bytes and recounts pixels and markers instead of trusting a
saved success flag.

## Completed gates

On 2026-10-12, both kernel modes completed the following reference-machine
coverage; installed user ELF programs use the existing size-optimized build:

| Workload | Debug | ReleaseSafe |
| --- | --- | --- |
| Protected display acceptance and persistent | All three architectures, six boots | All three architectures, six boots |
| Headless installed-app acceptance, persistent and missing archive | All three architectures, nine boots | All three architectures, nine boots |
| Files input, durable operations and fresh reboot | All three workflows | All three workflows |
| Reset/UEFI, network, simulated/unavailable Wi-Fi and driver modules | Required gates passed | Required gates passed |

The larger aggregate builds encountered three transient failures to read
installed Zig standard-library files (`MemoryMap.zig`, `nvptx.zig`, `dwarf.zig`).
The affected build/boot targets passed when retried without source or toolchain
changes. Both failed attempts and successful retry logs are retained in the
verification record, rather than describing either initial aggregate as a
single clean pass.

Final build results and their source/image hashes are recorded in
`.zig-cache/protected-display-verification.json`. Display logs, screenshots and
receipts live under `zig-out/display-tests/debug/` and `safe/`; the
[display guide](protected-display.md) documents build, run and focused test
commands. This generated record binds the tested sources and evidence at this
milestone; later changes require new verification.

The integration additionally exercises the established headless installed-app
runtime, reset/UEFI boot checks, protected Files input and disk/reboot operations,
NetworkKit, simulated/unavailable Wi-Fi and driver-module loading. Physical
Wi-Fi operation is outside these profiles.

Reproduce the broader integration in either Debug or ReleaseSafe:

```powershell
zig build test-display test check test-apps test-boot test-desktop test-network test-wifi test-driver-modules display -j1
zig build test-display test check test-apps test-boot test-desktop test-network test-wifi test-driver-modules display -Doptimize=ReleaseSafe -j1
```

## Scope

These historical results describe the separate `display` demonstration.
The primary [service desktop](service-desktop.md) now runs Files and shell in
protected processes with a retained scene and user-space window controls;
its qualification is recorded in [desktop verification](service-desktop-verification.md).

The demonstration provides two fixed 320 × 240 windows, user-space placement,
focused event routing and native AxisUI rendering through synchronous checked
scanout. Its separate legacy Files regression retains kernel-hosted window
policy. The demonstration has no retained scene or window controls. Edge resizing,
tiling/workspaces, broader application launch, service recovery and physical
hardware qualification remain future work. A closed window's last pixels remain
until redraw or relaunch; the initial demo has no retained damage scene.
