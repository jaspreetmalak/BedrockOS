# Installed application runtime verification

On 2026-10-12, the installed runtime passed its dedicated QEMU gates with Zig
0.17.0 in Debug and ReleaseSafe on x86-64, ARM64 and RV64. The reference machines
use one CPU/hart, UEFI firmware, VirtIO storage and fresh ordinary container-disk
images. The test runner retains serial logs and JSON receipts under
`zig-out/application-runtime-tests/debug/` and `safe/`.

| Mode | Boots across both builds | Required evidence per boot |
|---|---:|---|
| Acceptance | 6 | Three Worker faults, three clean restarts, six reclaimed generations; Observer retains its PID and private file; final pages, contexts, handles and pipe bytes return to the baseline |
| Persistent | 6 | One fault/restart cycle, both apps and init alive at readiness, and QEMU remains running for at least one further second |
| Missing archive | 6 | The installed profile reports `InstalledApplicationArchiveMissing`; installed init and the embedded fixture runtime never start |

The two positive modes use the same installed ELF archive. The image checker
independently reads the FAT chains and compares the entire archive to its input.
The parser checks table and executable hashes; the kernel also checks the full
ELF mappings, catalogue identity and per-package page caps before publishing any
bundle. Repacking the same linked application files reproduces the archive.

Observer and Worker execute denial checks for installed-app launch, launcher
readiness, network creation, bundle writes and foreign namespaces. They use the
same virtual `/container/session.txt` path in different private containers.
Worker intentionally leaves its heap allocation and file descriptor live when
faulting; init waits for status 139 and launches a fresh process. That process
verifies zeroed BSS and heap alongside retained container data, closes its
resources and exits 23. The kernel checks the exact resource baseline after
each of these six test generations before allowing another Worker launch.

Architecture mapping audits require RO/NX startup pages and RW/NX private heaps.
Worker's fault marker immediately precedes its architectural store to the
startup page. The installed fault handler records retirement and status; these
logs do not independently record the fault address and syndrome. The persistent
gate is a bounded liveness observation, rather than a long-duration soak test.

Focused native checks cover archive bounds/corruption, EFI staging failure
cleanup, immutable startup records, heap exhaustion/reuse/ownership and trusted
launch policy. Python suites include 15 package tests and 26 UEFI image tests.
The shared architecture contract also rejects malformed dispatcher-stack
geometry and requires at least 128 KiB of guarded supervisor stack space.

The full Debug regression build passed 421/421 steps and 454/454 native tests,
including all component compile checks, reset/UEFI boots, NetworkKit, simulated
Wi-Fi controls, driver module gates and installed-media generation. Files input,
namespace operations and reboot persistence passed on all three normal desktop
profiles in Debug. The ReleaseSafe build passed its native/compile checks,
reset/UEFI, network, Wi-Fi and driver gates alongside the installed-runtime gates.
Wi-Fi results use simulated or unavailable-radio profiles; they establish no
physical RF support.

The aggregate logs are `.zig-cache/application-gates-debug.log` and
`.zig-cache/application-gates-safe.log`. The generated
`.zig-cache/application-runtime-verification.json` binds the runtime receipts,
tested image bytes and source hashes at that milestone. Later source changes
need their own receipts; [protected display verification](protected-display-verification.md)
records the next integrated runtime regression. These generated files supplement
the committed runner and this reproducible verification record.

Reproduce the installed-runtime checks with:

```powershell
zig build test-apps -j1
zig build test-apps -Doptimize=ReleaseSafe -j1
```

The implemented runtime is headless and bounded. Its three packages and launch
permissions come from the compiled trusted catalogue. A general installer,
dynamic linking, heap growth and physical-machine qualification remain separate
milestones. Protected GUI services now have a dedicated
[display foundation](protected-display.md). The existing Files desktop continues
to use its established boot profile. See [the runtime guide](application-runtime.md)
for image and interactive-run commands.
