# Development roadmap

UEFI is the primary development and portability path for Bedrock's own loader
and OS. Existing firmware initializes hardware and RAM and loads the application.
Each shared milestone requires passing results on x86-64, ARM64, and RV64 UEFI
profiles. Direct-reset QEMU profiles remain reference and regression targets.

| Milestone | Deliverable | Exit condition |
| --- | --- | --- |
| Workspace | Pinned Zig, independent packages, cross-build matrix | All component checks compile for three profiles; portable tests pass natively |
| Startup contract | Named platform profiles and full handoff v0 | Firmware ownership, CPU entry state, memory reservations, and image layout are explicit |
| First boot | UEFI loader, linker layouts, kernel entry, diagnostics | Each UEFI reference machine reaches its kernel, reports memory, and handles a deliberate fault |
| Firmware portability | Relocatable kernels, dynamic arenas, three UEFI entries, explicit accessible memory | Firmware exits and exception recovery pass on all three QEMU profiles; x86 high placement passes |
| Physical memory | Shared bounded bitmap allocator and zeroed-frame startup API | Native ownership/bounds tests and real allocation, alignment, release, zeroed reuse and leak checks pass on all six QEMU boot paths |
| Security foundations | Portable default-deny app policy and generational handle tables | Native tests prove entitlement intersections, stale-handle rejection and rights attenuation; these tests alone do not establish user-mode isolation |
| Protected user entry | Kernel W^X, distinct task roots, native syscall/trap paths and guarded stacks | All three UEFI targets reject invalid pointers/unknown calls/denied handle writes, contain precise protection faults and keep a second task running |
| User preemption | Hardware timers, saved native contexts and shared round-robin policy | Two non-yielding tasks resume intact for three quanta each on every UEFI profile |
| Kernel allocation/lifecycle | Zeroed page-backed kernel heap, owned fixture payloads, table rollback and context/address-space teardown | Partial creation returns private tables; stale references fail; repeated cleanup returns payload/table frames and fixture charges while permanent resources stay owned |
| Native process lifecycle | Bedrock64, static ELF init/service, private address spaces and spawn/wait/exit | Same native sources execute on all three; faulted child status and resource cleanup verified |
| Blocking and IPC | Yield/sleep, wait queues, bounded capability mailboxes and hardware idle ticks | Empty receivers and full senders suspend/resume; sleepers and parents wake; checked copyout and rights attenuation pass |
| Unix I/O, first bounded profile | Implemented VFS descriptors, pipes, path spawn and safe exec replacement | Both Debug and ReleaseSafe RAM-profile boot matrices pass; native I/O workloads enforce app-owned bundle/container authority and release transient resources on all three UEFI targets |
| Durable containers and native Files | Dedicated two-bank disk format, virtio block/input, directory syscalls and a protected two-pane AxisUI client | Native recovery/authority tests pass; real create/copy/rename/remove and reboot persistence pass on every named UEFI profile, preserving separate acceptance/Files identities |
| Installed application runtime | Checked installed ELF archive, persistent user-space init, independent app identities, startup arguments/environment and a bounded heap | The same supervisor launches two installed apps on all three UEFI references; Worker faults and restarts while Observer retains its PID and private state; repeated retirements and final acceptance teardown reclaim process resources |
| Expanded Unix I/O | General ELF layouts, broader process/file APIs and app-accounted storage | Documented native workloads exceed the fixed first-profile limits while preserving resource ownership; general POSIX remains separate work |
| App isolation | Trusted app identities, private containers, bundle/runtime access and object grants | A cannot read/write B or kernel resources; denied descriptors/syscalls cannot escalate; a fault in A leaves B alive |
| Source compatibility | libc and selected POSIX interfaces over Bedrock64 | Documented source workloads build and run on all three; binary compatibility and certification are not implied |
| Native UI foundation | Public AxisUI views, layout/modifiers, software drawing and native shell components | Native tests cover bounded rendering; the same components compile for x86-64, ARM64 and RV64 |
| Desktop input | Virtio keyboard/pointer drivers, bounded events and focused routing | The user-space display service routes authenticated app-local events; legacy kernel-hosted Files remains a regression profile |
| Protected display foundation | Installed native display service, two AxisUI surface clients, checked snapshot transfer and focused input | Init retains the service and B while A faults and restarts; writer mappings are revoked before RO transfer and all surface/table resources are reclaimed |
| Reactive native views | Event-driven state bindings, view identity and reconciliation | State updates redraw the intended views while preserving unrelated state and object ownership |
| First runtime desktop | Installed init, display service, shell and Files; retained native surfaces, user-space controls/focus and durable app-2 files | Passed all three QEMU references in Debug and ReleaseSafe: real input/pixels/frost, disk recovery, stable service PIDs, fresh Files relaunch and checked teardown |
| Native window desktop | Five installed processes, independent Files/Notes windows, native window SDK, edge/corner resizing, tiling and four workspaces | [Passed](window-desktop-verification.md) all three QEMU references in Debug and ReleaseSafe: focus/geometry, private persistence, independent lifecycle, contained faults and balanced teardown |
| Native tab/window expansion | Left-aligned native tabs, stable-ID drag reorder, transactional tear-off and four Files windows over one connection | Widget/SDK/ownership tests pass; fresh integrated evidence must prove real detached windows, retained navigation, independent controls and balanced producer/cache retirement on each reference |
| Expanded desktop services | Broader trusted GUI catalogue, interrupt-driven input and session/service recovery | Added clients preserve ownership and bounded routing; input responsiveness and service retirement/restart have explicit runtime evidence |
| Anvil graphics foundation | Public commands/fences, trusted resources and CPU framebuffer backend behind existing display checks | Native bounds/rights/lifetime tests and all-three desktop pixels preserve existing surface ownership; hardware acceleration remains separate |
| Native GPU backends | Complete VirtIO GPU scanout first; rendering acceleration and named physical GPU families afterward | Real device completion, visible output, DMA/reset lifetime and explicit capability reports verified on each supported profile |
| Rendering effects | GPU support where available, animation and blur | Effects preserve surface ownership and work within documented rendering/driver support |
| Concurrency and I/O | SMP, TLB coordination, small driver set, filesystem integration | Multicore and device failure workloads pass on the three profiles |
| Optional driver packages | Hardware catalogue, separate ELF modules, private versioned ABI and installer staging | All three reference machines execute a test module with protected pages and checked memory tokens; production skips unmatched/rejects malformed modules |
| Physical support | One named machine/board with working UEFI per ISA | Cold boot through the documented firmware, supported devices, and recovery succeed |

The current useful OS milestone is a bounded installed desktop across all
three architectures, with protected native processes and durable private files.
Bedrock uses a Unix-style modular monolithic kernel and a private Bedrock64
syscall ABI; POSIX source compatibility follows working native userspace.
The current shell, Files and Notes use checked installed bundles and a
Hyprland-inspired desktop with floating windows, tiling and four workspaces. Unix binary
compatibility, a Hyprland port, external compositor/API compatibility and POSIX
certification are not milestones in this plan.

Native ELF process lifecycle and blocking IPC are now implemented behind the
first bounded Bedrock64 profile. Init launches separately compiled user code,
waits for children, exchanges capability-checked messages and sleeps on actual
hardware ticks. The [native process contract](native-processes.md) records
current limits and verification. The [first Unix I/O profile](unix-io.md) adds
app-scoped files, nonblocking pipes, path launch and exec replacement. The current
backend persists mutable containers in a dedicated 4 MiB snapshot image;
[the format contract](persistent-filesystem.md) specifies atomic commits and
old-or-new recovery after uncertain I/O failure. Stable app ID 1 isolates
acceptance writes from the native Files app's ID 2. Normal UEFI now selects the
[window desktop](window-desktop.md): init 101 launches compositor 104, shell
107, Files 2 and Notes 108 through the installed runtime. The two GUI apps
render native AxisUI pixels and receive focused events over checked service
IPC; their private container identities remain 2 and 108. The earlier
single-window service desktop, kernel-hosted Files and fixed two-client
display demonstration remain regression profiles. General ELF layouts,
general POSIX, a broader GUI catalogue and interrupt-driven input remain future work.
Disk/input/restart verification is recorded separately from the earlier
RAM-profile matrices.

The [installed application runtime](application-runtime.md) adds a dedicated
headless boot profile alongside that desktop. A validated archive on the UEFI
partition supplies persistent init, Observer and Worker. The trusted kernel
catalogue establishes separate identities, permissions and containers; only
init receives installed-app launch authority. Observer holds its original heap,
file and PID while init waits for a Worker startup-page protection fault and
launches a fresh process. Worker checks retained private file content alongside
zeroed BSS and a fresh heap. The same native supervisor uses one demonstration
cycle in normal runs and three in acceptance, then retains both applications.
Acceptance cleanup is gated by kernel-owned lifecycle and ownership checks.

This first installed profile accepts two-segment static ELF64 programs with up
to 128 KiB RX code/read-only content, a guarded 16 KiB stack, an immutable RO/NX
startup page and a preallocated 32 KiB RW/NX heap. The default RW/NX data cap is
128 KiB; trusted desktop packages 104, 107, 2 and 108 receive a 512 KiB cap for
bounded render/backdrop scratch. An ELF cannot raise its catalogue limits.
The SDK supports up to eight arguments, eight environment entries and 64
live heap allocations. Dynamic paging, heap growth, arbitrary executable
layouts, signed updates and a general service manager remain future work.
`zig build app-runtime` packages all three profiles; architecture-specific
`app-runtime-x86_64`, `app-runtime-arm64` and `app-runtime-riscv64` targets select
one. `run-apps-x86_64`, `run-apps-arm64` and `run-apps-riscv64` keep init running;
`test-apps` exercises the dedicated acceptance path on all three machines.
The legacy kernel-hosted Files workflow retains its own regression profile.
The [protected display foundation](protected-display.md) retains a separate
graphical profile using the same installed process runtime: init 101 launches
display service 104 and surface clients A 105 and B 106. Native AxisUI draws
into bounded pixel surfaces. Submission revokes the client's RW mapping before
the service receives a checked RO grant; device access and final presentation
remain mediated by the kernel. The service selects placement and focus and
routes real input through authenticated IPC. A faults and relaunches while the
service and B retain their identities and state. Its verification record tracks
the dedicated acceptance and persistent runs separately from Files.

The retained [service desktop](service-desktop.md) implements Files/shell migration,
retained full-scene software composition, native frost/cursor, title dragging,
close, minimize, maximize/restore and fullscreen in user space. Init alone
launches Files generations; hidden and resized viewport epochs cannot reuse
stale frames. Native/cross-build and
[integrated QEMU checks](service-desktop-verification.md) passed on all three
references in Debug and ReleaseSafe. The primary [window desktop](window-desktop.md)
adds Notes, a bounded app/PID/WindowID registry,
z-order/focus, edge/corner resizing, four workspaces, tiling and a native
create/resize/focus/close SDK. Shell launch requests restore a live app or ask
init for a fresh process. `test-window-desktop` and its runtime receipts are
the primary gate; [final verification](window-desktop-verification.md) passed
twelve workflows and 24 fresh boots across all three references in both modes.
The separate `display` demonstration intentionally retains fixed placement.

The current tab/window expansion gives Files four independently controlled
windows in one process and authenticated display connection, with eight
navigation tabs per window. Its tabs-only caption starts at the left with no
visible Files title. AxisUI owns bounded tab picking, drag previews and reorder
requests; Files commits tear-off only after a real destination window imports
the record and presents a current-epoch acknowledged frame. Failure or
cancellation retains the source. SDK Hub slots, monotonic WindowIDs, checked
surface bindings and per-window cache retirement preserve ownership without
spawning another Files process. These changes require their own fresh QEMU
receipts; the preceding window baseline does not qualify the expansion.

Native UI work starts with `frameworks/public/AxisUI/` and
[`userspace/apps/shell`](../userspace/apps/shell/README.md), implemented from scratch in Zig.
Public AxisUI provides reusable declarative views, stack layouts, modifiers and
software framebuffer drawing. The `desktop_shell` package owns themes,
workspace/status bars and actual shell view composition; its compile probe is
`bedrock-desktop-shell`.

`userspace/apps/` contains application sources. `userspace/services/display-server/`
contains the separately linked protected display service. Shell, Files and Notes
run as native installed processes in the primary desktop. Standalone input,
launch and general broker services remain future work; init currently owns
installed launch authority, and the service accepts launch requests only from
the trusted shell.
Installed bundles and service paths need not mirror source organization.

Private frameworks hold reusable internal OS APIs and service mechanisms.
NetworkCore already provides trusted networking mechanisms. Checked display IPC
and surface adapters now live in the native runtime; their resource brokers live
in the kernel. Additional reusable internal framework APIs remain future work.
Public/private describes API support and distribution. Protected address spaces
and checked capability/syscall rights provide authority. AxisCore and additional
native service frameworks are future milestones, with APIs driven by process,
IPC and object-lifetime needs.

Caller-owned rendering workspaces keep the bounded layout plan off execution
stacks. Native desktop programs retain their scratch in private BSS and borrow
view trees only for synchronous render calls. The legacy preview bridge keeps
its separate kernel-owned scratch for regression coverage.

The primary native UI uses installed shell, Files and Notes processes with retained
pixel surfaces composed by a protected user-space service. Files preserves its
navigation, create/mkdir, copy/move, rename/remove, context menus, Nullify and
read-only preview over the same durable container. Window policy, focus, frost
and cursor are in user space; VirtIO access, page ownership and final scanout
stay checked by the kernel. The legacy Files regression retains bounded draw
commands and kernel-hosted policy. The compositor retains one composed scene,
lazily allocates a viewport cache per bound GUI window and keeps only the
shell's 36-row bar in private BSS. Each GUI window has one producer and one
cache, so balanced surface count is `2 + 2 * bound_gui_windows`: six initially,
eight after a tear-off and twelve with four Files windows plus Notes, while
the five application/service processes stay unchanged. Automatic view bindings, GPU rendering,
interrupt-driven input and broader catalogue/session services remain future work. The
[desktop design](desktop-design.md) records these acceptance boundaries and the
Hyprland-inspired visual direction.

The workspace and UEFI reference-machine first-boot milestones are complete for
ARM64, x86-64 and RV64: independent kernel loading, validated handoff, console
and memory diagnostics, deliberate exception recovery and bounded emulator
acceptance checks. The retained reset references also pass these checks.
Platform entry states and memory layouts are documented.

Memory discovery, normalized reservations, a bootstrap physical-page cursor,
typed console handoffs, dynamic UEFI arenas and relocatable kernels provide the
portability foundation. All three architectures now have a primary standard
firmware adapter; RV64's UEFI kernel has its own S-mode exception path while the
reset reference retains M mode.

The physical-memory milestone adds shared layout planning, permanent bitmap
metadata, checked frame and aligned contiguous allocation, and a zeroing API.
Its acceptance runners require allocator readiness, RAM allocation checks and
release/reuse checks before exception recovery. Native tests cover ownership,
addressability, exhaustion and invalid releases; runtime checks access actual
RAM on each UEFI and reset path. The [memory-management contract](memory-management.md)
describes the APIs and completion criteria.

This milestone passed on 2026-10-11: all 82 workspace native tests and twelve
compile probes passed in Debug and ReleaseSafe, and each mode passed the
18-configuration UEFI/reset boot matrix. Two additional ReleaseSafe x86 checks
covered the 4 GiB reset limit and a UEFI kernel placed above 4 GiB. No physical
machine was used for these checks.

Portable security foundations now establish default-deny
app policy and bounded generational handle bookkeeping in `kernel/src/security/`.
The user-mode probe dispatcher now consumes their handle and policy checks;
the native process runtime and durable VFS also consume this policy. Manifest
requests intersect trusted
grants; app identity comes from the trusted launcher, separately from UID and
PID. Apps cannot opt out, root cannot bypass policy, children cannot gain
authority and copied/duplicated handles can only preserve or reduce rights.
The kernel must recheck those rights at each future object operation.

Kernel-owned protected paging and checked user/kernel transitions now run
on the three UEFI paths. Two fixed fixtures exercise private memory, pointer
validation, unknown calls, denied handle writes and five contained protection
faults. The second fixture runs successfully after each fault. This is the
first enforcement layer; its internal probe ABI is not yet Bedrock64. See
[protected userspace](protected-userspace.md).

Hardware timer entry and saved-context round-robin execution now follow these
checks. Two tasks that never yield receive three quanta each; their private
progress, one-time entry counts and register/stack state prove resume rather
than restart. This is single-CPU user preemption, with kernel interrupts masked.
See [the timer/context contract](preemptive-scheduling.md).

The first lifecycle milestone adds a zeroed page-backed kernel heap and explicit
ownership of fixture payloads, architecture page tables and saved contexts.
Failed table builds roll back their own frames. Cleanup destroys contexts before
their address space, invalidates translations before table reuse and then
returns the core-owned payload frames and test grants. Generational references
reject stale contexts and address spaces across registry reuse.

Acceptance requires rollback under table-allocation caps zero through three,
live-context teardown rejection and more than eight creation/cleanup cycles.
The workload runs 12 cycles and resumes replacement-generation contexts through
real timer entry. Debug and ReleaseSafe each pass all 18 matrix configurations;
normal native previews also complete on all three architectures. See the
[lifecycle verification record](resource-lifecycle.md#verified-results).
Each fixture charges three payload frames, one handle and one process; those
charges return on cleanup. Private tables are reclaimed but page-table and
kernel overhead are not yet fully app-accounted. Shared kernel tables, trap
stacks and allocator metadata remain permanently owned. This is fixed-fixture
resource lifecycle. Later native process and I/O stages build on that ownership;
it did not by itself implement app loading or a general process API.

The first RAM VFS, path-backed loading, pipe and exec profile is implemented
over the native process and IPC foundations; [integrated verification](unix-io.md)
passed in Debug and ReleaseSafe. Next core work expands general ELF layouts,
app-accounted storage and Unix interfaces. The durable backend and protected
Files client add actual disk-backed private containers, directory operations
and a bounded interactive app window. Their Debug/ReleaseSafe native tests,
boot matrices and all three disk/input/reboot workflows
[passed integrated verification](storage-and-files-verification.md).
Files and shell integration with the protected display service passed its
all-three-architecture runtime gate in Debug and ReleaseSafe. The new native
window desktop passed the bounded two-GUI management milestone's
[runtime verification](window-desktop-verification.md) in both modes on all three
references. Subsequent work expands the GUI catalogue, input
delivery and reactive view state.
Read-only embedded bundles also have VFS mediation; trusted installation/identity
management, explicit shared runtime and broker/file-picker object grants still
need their services.
Full sandbox acceptance requires two apps:
A cannot read or write B's or kernel resources; denied descriptors and syscalls
cannot raise authority; a fault in A leaves B running. The
[application model](application-model.md) defines that contract and the later
`.app` desktop layout. Current boot images enforce the first bounded durable file
authority profile. Installed bundle archives and bounded surface/service brokers
are also implemented in dedicated profiles; general installation, broader
resource brokers and a general-purpose process/Unix API remain future work.

S-mode entry alone does not provide userspace isolation. Physical cold boot,
firmware compatibility and device support still need individual qualification
and platform ports.
