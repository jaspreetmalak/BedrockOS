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
| Expanded Unix I/O | General ELF layouts, broader process/file APIs and app-accounted storage | Documented native workloads exceed the fixed first-profile limits while preserving resource ownership; general POSIX remains separate work |
| App isolation | Trusted app identities, private containers, bundle/runtime access and object grants | A cannot read/write B or kernel resources; denied descriptors/syscalls cannot escalate; a fault in A leaves B alive |
| Source compatibility | libc and selected POSIX interfaces over Bedrock64 | Documented source workloads build and run on all three; binary compatibility and certification are not implied |
| Native UI foundation | Public AxisUI declarative views, layout/modifiers and software renderer; `userspace/apps/shell` composition and themes | Native tests cover layout and bounded drawing; normal UEFI GOP previews render the static shell after preemption checks on all three architectures |
| Desktop input | Virtio keyboard/pointer drivers, bounded events and focused routing | Native Files receives input through the host; malformed or overflowing events cannot corrupt state on the named profiles |
| Protected display services | User-space shell application and display service, compositor IPC and capability surface grants | One app cannot read/write another surface or claim ungranted input/display authority; a failed client leaves the service and other clients alive |
| Reactive native views | Event-driven state bindings, view identity and reconciliation | State updates redraw the intended views while preserving unrelated state and object ownership |
| First runtime desktop | Native `.app` launch, interactive windows and a user-space tiling/workspace shell | After app loading and init, native apps launch and receive correctly routed input while preserving grants and isolation on all three UEFI profiles |
| Rendering effects | GPU support where available, animation and blur | Effects preserve surface ownership and work within documented rendering/driver support |
| Concurrency and I/O | SMP, TLB coordination, small driver set, filesystem integration | Multicore and device failure workloads pass on the three profiles |
| Physical support | One named machine/board with working UEFI per ISA | Cold boot through the documented firmware, supported devices, and recovery succeed |

The first useful OS milestone is a protected shell running from RAM across all
three architectures. Bedrock uses a Unix-style modular monolithic kernel and a
private Bedrock64 syscall ABI; POSIX source compatibility follows working native
userspace. A Hyprland-inspired tiling desktop and native app bundles follow
protected processes, mediated resource access and input support. Unix binary
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
acceptance writes from the native Files app's ID 2. Native Files now runs in a
protected address space and receives bounded input/drawing/file syscalls from
the privileged desktop host. General ELF layouts, a user-space compositor and
general POSIX remain future work. Real disk/input/restart verification is being
recorded separately from the earlier RAM-profile matrices.

Native UI work starts with `frameworks/public/AxisUI/` and
[`userspace/apps/shell`](../userspace/apps/shell/README.md), implemented from scratch in Zig.
Public AxisUI provides reusable declarative views, stack layouts, modifiers and
software framebuffer drawing. The `desktop_shell` package owns themes,
workspace/status bars and actual shell view composition; its compile probe is
`bedrock-desktop-shell`.

`userspace/apps/` contains application sources. `userspace/services/` is the
future home for display/compositor, input, launch and broker processes; those
service processes are not implemented yet. The shell source move does not add
user-space shell execution. Its background composition still renders through
the privileged kernel host, while `userspace/apps/Files` is a real protected
native executable. Installed bundles and service paths need not mirror this
source organization.

Private frameworks are reserved for reusable internal OS APIs and service
mechanisms, such as future display IPC clients, surface ownership interfaces
and internal brokering. No private framework package is implemented yet.
Public/private describes API support and distribution. Protected address spaces
and checked capability/syscall rights provide authority. AxisCore and additional
native service frameworks are future milestones, with APIs driven by process,
IPC and object-lifetime needs.

Caller-owned rendering workspaces keep the bounded layout plan out of the
kernel's small guarded stack. The current preview bridge owns scratch in BSS
and borrows the view tree only for the synchronous render call.

The native UI provides framework layout/rendering, a kernel-hosted shell
background and a separately loaded protected Files client on normal UEFI GOP
boots. Files supports two-pane navigation, create/mkdir, copy/move, rename,
remove and a copied read-only file preview over its persisted container. The
kernel still owns window policy, focus, virtio input and bounded draw commands;
there is no GPU renderer or user-space compositor. Next desktop work separates
protected display/input services, adds general app launch and multi-client
surfaces, then event/state bindings and reconciliation. The
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
Desktop work next separates protected
display/input services and adds multi-client surfaces and reactive view state.
Read-only embedded bundles also have VFS mediation; trusted installation/identity
management, explicit shared runtime and broker/file-picker object grants still
need their services.
Full sandbox acceptance requires two apps:
A cannot read or write B's or kernel resources; denied descriptors and syscalls
cannot raise authority; a fault in A leaves B running. The
[application model](application-model.md) defines that contract and the later
`.app` desktop layout. Current boot images enforce the first bounded durable file
authority profile; resource brokers, persistent bundles and a general-purpose
process/Unix API remain future work.

S-mode entry alone does not provide userspace isolation. Physical cold boot,
firmware compatibility and device support still need individual qualification
and platform ports.
