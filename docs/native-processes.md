# Native processes and capability IPC

Bedrock's first native process profile loads separate Zig ELF executables into
private user address spaces on the x86-64, ARM64 and RV64 UEFI paths. A bounded
single-CPU runtime supplies process creation, child waiting, timer sleep and
capability-checked mailbox IPC. The first [Unix I/O extension](unix-io.md) adds
RAM files, pipes, path launch and same-PID exec. The implementations are in
[`process_runtime.zig`](../kernel/src/core/process_runtime.zig),
[`process.zig`](../kernel/src/core/process.zig) and
[`ipc.zig`](../kernel/src/core/ipc.zig).

The preceding process/IPC stage was verified on 2026-10-11 with Zig 0.17.0 on
the Windows QEMU TCG references in Debug and ReleaseSafe. Its native suite and
cross-build checks passed;
both 18-configuration boot matrices passed for that stage. The later
[Unix I/O verification](unix-io.md) also passed both matrices and all six normal
UEFI graphical checks; physical machines remain unqualified.

This document retains the first native lifecycle/IPC acceptance profile. The
newer [protected Files desktop](desktop-design.md) uses the same trap adapters
with a separate bounded larger ELF layout, checked drawing/input calls and
[durable container storage](persistent-filesystem.md). Its kernel display host
and integrated acceptance limits are recorded in the
[storage/Files verification](storage-and-files-verification.md), which passed
all three UEFI references in Debug and ReleaseSafe. The earlier results here
retain their original scope.

## Executable and launch profile

The kernel mounts immutable build-time ELF bytes in the current app's read-only
RAM bundle: init, IPC/fault children and I/O/exec acceptance images. They are separately
linked ELF64 little-endian `ET_EXEC` artifacts from `userspace/`, compiled in
`ReleaseSmall` independently of the kernel optimization mode. This catalog is
trusted bootstrap input. `spawn_path` and `exec` can select approved immutable
bundle nodes; applications cannot supply an executable buffer or execute
mutable container files. Legacy catalog spawn resolves through the same VFS.

[`user_elf.zig`](../kernel/src/core/user_elf.zig) validates the architecture,
headers, segment bounds, permissions and supported section contents before RAM
allocation or copying. The first profile allows one RX code/read-only segment
and one RW data/BSS segment, each bounded to one 4 KiB page. Dynamic linking,
relocations and TLS are rejected. The kernel supplies zeroed backing pages and
a separate nonexecutable stack.

| User virtual address | Mapping |
| --- | --- |
| `0x2000000000` | One 4 KiB RX code/read-only page |
| `0x2000001000` | One 4 KiB RW, nonexecutable data/BSS page |
| `0x2000002000` | Unmapped guard page |
| `0x2000003000` | One 4 KiB RW, nonexecutable stack page |

Processes use the same virtual layout with different physical backing and
translation roots. Supervisor physical aliases remain inaccessible to user
code. The launch arguments are the parent PID, one explicitly inherited IPC
handle or zero, and a zero argument for ordinary init/service launches. The
trusted fault fixture uses the third argument to select its acceptance case.
Path launch supplies an explicit argument; `spawn_pipe` instead installs one
authorized pipe writer in the child table. Exec keeps the same PID and parent.
Init has parent PID zero. There is no `argv`, environment, libc startup or general
user allocator yet.
ARM64 user programs exclude FP/NEON; RV64 uses the integer instruction profile
without F/D. See the [native runtime](../userspace/runtime/README.md).

## Experimental Bedrock64 ABI

[`userspace/runtime/src/abi.zig`](../userspace/runtime/src/abi.zig) is the shared
source definition. Bedrock64 v0 is a private experimental ABI, with three integer
arguments and a raw 64-bit result. It does not establish POSIX or foreign binary
compatibility.

| Architecture | Entry | Number | Arguments | Result |
| --- | --- | --- | --- | --- |
| x86-64 | `int 0x80` | `rax` | `rdi`, `rsi`, `rdx` | `rax` |
| ARM64 | `svc #0` | `x8` | `x0`, `x1`, `x2` | `x0` |
| RV64 | `ecall` | `a7` | `a0`, `a1`, `a2` | `a0` |

| Call | Current behavior |
| --- | --- |
| `getpid` | Returns the current process's generation PID. |
| `spawn` | Selects an allowed catalog child and optionally inherits an IPC grant with equal or fewer rights. |
| `exit` | Accepts status `0..255`; cleanup runs after the trap returns to the kernel. |
| `wait` | Selects a direct child PID, or zero for any direct child; returns its exit status and reaps its PID record. |
| `yield` | Returns to the scheduler without advancing the hardware tick clock. |
| `sleep` | Blocks for relative verified timer ticks; zero behaves as yield. |
| `clock_ticks` | Reads the shared observed-quantum clock used by sleep deadlines. |
| `ipc_create` | Creates a bounded mailbox and a process-local send/receive handle. |
| `ipc_send` | Copies at most 64 bytes into a queued message, or suspends while the queue is full. |
| `ipc_receive` | Writes a 16-byte sender/length header followed by payload; an empty open queue suspends the caller. |
| `close` | Invalidates an exact file, pipe or IPC/stdout token and releases its reference. |
| `write` | Writes at most 256 bytes through inherited stdout or an authorized file/pipe. |
| `open`, `read`, `seek` | Resolve scoped RAM files and enforce descriptor rights/offset bounds. |
| `spawn_path`, `exec` | Load immutable executable bundle nodes; exec stages a same-PID replacement. |
| `pipe`, `dup`, `spawn_pipe` | Create nonblocking byte pipes, attenuate pipe descriptors and explicitly grant a child writer. |

Errors occupy the final 4,095 unsigned 64-bit values. Programs use `abi.isError`
rather than testing the sign bit, because opaque identities may set that bit.
Unknown calls, invalid user ranges, unavailable authority, closed objects and
resource limits return errors. User addresses are checked against the selected
process's mapping list before physical copyin or copyout.

## Process lifecycle and scheduling

`ProcessTable(8)` retains generation PIDs encoded as a nonzero 32-bit generation
and a one-based 32-bit slot. Records move through ready, running, blocked and
zombie states; only reaping or trusted construction rollback makes a slot free.
Generation exhaustion permanently retires that slot. PID identity supplies no
object authority.

Round-robin dispatch skips blocked and zombie entries. A verified timer quantum
preempts the running process and advances the shared tick clock. Yield advances
the dispatch cursor without advancing time; adapters retain the unfinished timer
quantum across cooperative yields. Sleeping processes wake at their checked
deadlines. When no process is ready, the current architecture adapters
poll an armed hardware timer with kernel interrupts masked, then advance that
same clock. This scheduler clock counts observed quantum expiries; it does not
catch up missed wall-clock intervals. The idle path does not provide CPU power
saving or a realtime scheduling guarantee.

Only an actual parent may wait for or reap a child. Exit and user faults leave a
zombie status and notify the parent. Native contexts, page tables, backing pages
and handle charges are released before that PID record becomes reusable. A
blocked wait resumes after the saved syscall rather than asking user code to
repeat it. Init adopts live children and existing zombies when their parent
exits; ordinary init exit is refused until all direct child records are reaped.

Trusted init failure ends the bootstrap session. The kernel uses `failInit` to
stop every live process, preserve existing zombie statuses and regain control
for cleanup and failure diagnostics. Init retains its fault status; other live
processes receive status 137. This path is unavailable to user syscalls. Init's
own final zombie remains available for trusted kernel inspection.

Portable policy helpers include `slot`, `pidAt`, `state`, `parent`,
`blockedReason`, `exitRecord`, `abortSpawn`, `block`, `wake`, `takeWake` and
`reblockReady`. An outstanding wake must be consumed before another block.
Deferred IPC completion rechecks queue readiness and can reblock a ready process
when another waiter already consumed it. Kernel-side probe, block and wake
operations are serialized to avoid lost notifications.

## Mailboxes, authority and resource ownership

Mailboxes hold copied messages with a kernel-selected sender PID. That PID
remains historical message metadata after the sender exits. Endpoint object IDs
are trusted kernel identities with slot generations; applications operate
through the current process's handle table and required send/receive rights.
Receiving an object ID or copying another process's numeric token grants no
authority. Child inheritance passes an explicitly authorized grant into a new
child-local handle entry, with no increase in rights.

`peek` observes a copied message without dequeueing it. The dispatcher checks
the caller's output capacity and writable mapping before `receive` commits the
pop. Queue progress wakes matching blocked senders or receivers. The kernel
retains blocked send bytes and receive metadata; it completes their syscall
results after returning to the permanent kernel root, before user execution
resumes.

Owner death closes its endpoints and wakes peers. Committed messages may still
drain through surviving authorized handles; new sends report closure. Final
reference release drains remaining messages, releases their byte charges and
destroys the closed endpoint. Closed/reused handle or object generations reject
stale references.

| First-profile bound | Limit |
| --- | --- |
| Process/PID records | 8, including unreaped zombies |
| Mailboxes | 4 |
| Queued messages per mailbox | 4 |
| Payload per message | 64 bytes |
| IPC/stdout handles per process | 8 |
| File / pipe descriptors per process | Separate tables of 8 each |
| Pipes / bytes per pipe | 4 / 256 |
| RAMFS nodes / mutable bytes per file | 32 including root/directories / 4,096 |
| Shared app-tree payload pages | 27: eight three-page images plus three transient exec frames |
| Shared app-tree process charges | 8 |
| Shared app-tree handle charges | 64 |
| Shared app-tree queued payload charges | 1,024 bytes |

Init and its children charge the same retained app-tree budget. Creating a child
does not copy fresh allowances. Payload page charges exclude private translation
tables and permanent kernel/trap storage, which have separate fixed bounds.
Message and pipe charges count buffered payload bytes. Construction failures unwind quota charges,
owned pages and private tables before `abortSpawn` invalidates the provisional
PID. RAM file bytes and metadata remain in permanent BSS rather than these
payload-frame charges. The VFS checks app-owned container/bundle authority;
trusted installation, brokers and broader object services are still needed for
the complete app sandbox. Full architecture registries can reject staged exec
with safe `ENOMEM` while the old image remains usable.

## Acceptance and remaining scope

The integrated workload requires separately loaded native init and child
executables, an empty-queue receiver block, a full-queue sender block and a parent
wait block. Six messages exceed the four-slot queue while the receiver sleeps
after its first receive; a full send must suspend until the receiver makes space.
It also checks attenuated IPC rights, sleep while
every user process is blocked, stale-token rejection and resource return to the
pre-workload baseline.
Init also performs 4,096 volatile increments before each yield until two real
timer ticks pass, with a bounded iteration limit, while the service sleeps.
Acceptance requires a
sleep completion without an intervening idle tick. This covers progress while
another process remains runnable. The null-fault child sleeps before faulting,
which requires its parent to block in wait before collecting the fault status.

Three native child fault cases must remain contained: a null read, yield with a
zero user stack pointer, and a syscall at the end of the RX page whose saved
return PC lies outside executable memory. Invalid saved PC/SP is rejected before
resuming user execution. Each child leaves a fault status for its parent while
the kernel and init continue. Native tests cover portable state transitions,
generation reuse, atomic failures and queue behavior.

| Previously verified process/IPC configuration | Result |
| --- | --- |
| Workspace native tests and cross-builds | Pass in Debug and ReleaseSafe, including all nine separately linked user images |
| Debug boot matrix | 18/18 pass |
| ReleaseSafe boot matrix | 18/18 pass |
| Additional ReleaseSafe x86-64 UEFI | Pass with 4,096 MiB RAM and kernel placed at `0x100000000` |
| Normal UEFI graphics at 256 MiB | All three architectures remain alive and finish the native AxisUI preview in both modes; each pair of captures matches |

Each matrix covers reset references at 64/128/512 MiB and UEFI references at
128/256/512 MiB for all three architectures. Native process and IPC acceptance
runs on UEFI. Reset references retain their memory/exception regression scope.
The earlier five precise protection faults, six timer-preemption returns and
12 resource-reuse cycles also pass before the new ELF workload. Queued payload,
handle and process charges return to zero, and the physical allocator returns
to its pre-process ownership baseline after final cleanup.

The new Unix I/O stage requires file/pipe operations, failed exec preservation,
same-PID replacement and descriptor cleanup. A kernel probe fills all eight
space/context slots, requires replacement failure without changing old
authority or ownership, then releases the temporary children before init runs.
Its [complete verification record](unix-io.md) confirms both 18-boot matrices,
including nine native I/O workload boots per mode, and all six normal UEFI
previews in Debug and ReleaseSafe.

There is no POSIX layer, persistent disk-backed app loader, dynamic linker, general
`mmap`, multiple threads per process, SMP scheduler, display/input service or
userspace compositor in this profile. The shell remains a static native AxisUI
composition through its temporary kernel framebuffer host. Its userspace source
location does not make it a launched process yet.
