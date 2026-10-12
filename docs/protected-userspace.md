# Protected user-mode bring-up

The primary UEFI kernels establish kernel-owned paging, then run two small
user-mode fixtures. This is the first hardware enforcement layer
for the [application model](application-model.md). Those fixtures remain an
acceptance layer; native ELF processes, app-scoped I/O and the protected Files
client now use the same adapters after their cleanup. The complete Unix and
application sandbox models remain broader than these bounded profiles.

## Ownership and mappings

`kernel/src/core/isolation.zig` owns the tasks, grants, resource charges and
syscall dispatch. `core/isolation_contract.zig` defines the trusted architecture
boundary, and `core/user_memory.zig` validates input ranges. Paging, privilege
entry, trap stacks, cache maintenance and CPU return code live separately in
`kernel/src/arch/<isa>/isolation.zig` and `isolation.S`. The existing bootloader
remains independent. Each adapter uses the same physical allocator instance as
kernel startup.

Kernel text is supervisor-only read/execute; read-only data is non-executable;
writable data, tables and stacks are non-executable. The main kernel stack has
an unmapped page immediately below it. Each probe task has a distinct page-table root
and three owned, zero-initialized frames. User code is read/execute, data and
stack are read/write and non-executable. Physical identity aliases stay
supervisor-only, including the backing pages of both tasks. A user cannot select
another task's root or handle table.

The fixtures use the same virtual addresses in their separate roots:

| Address | Mapping |
| --- | --- |
| `0x2000000000` | One code page, user read/execute |
| `0x2000001000` | One private data page, user read/write |
| `0x2000002000` | Unmapped user stack guard |
| `0x2000003000` | One private stack page, user read/write |
| `0x2000004000` | Initial stack pointer, just above the stack |

These addresses describe the probe and first native acceptance profile.
Files uses a separate trusted bounded profile in the same 2 MiB user window:

| Address | Desktop mapping |
| --- | --- |
| `0x2000010000` | At most 128 KiB user RX code/read-only content |
| `0x2000040000` | At most 1 MiB private user RW/NX data/BSS |
| `0x20001df000` | Unmapped guard below the desktop stack |
| `0x20001e0000` | At most 64 KiB private user RW/NX stack |

The trusted loader selects the profile and validates ELF bounds; user code cannot
choose arbitrary physical or virtual mappings. These are bounded contracts,
not permanent general application layouts.
Identity coverage that collides with the reserved user window is rejected.
ARM task creation also requires the enclosing 1 GiB branch, from 128 GiB to
129 GiB, to contain no identity mappings; the current adapter clones the shared
upper table and installs a fresh lower branch. Other physical coverage in that
branch fails task creation safely. Architecture address-width, MMU and cache requirements are checked separately;
this milestone does not broaden the physical-machine support claim.

## Temporary probe syscall interface

The native assembly fixtures are copied into their owned code pages. Their
code contains no references back into kernel text. They execute at x86 CPL3,
ARM EL0 or RISC-V U mode and enter through the kernel's protected trap path.

| Architecture | Entry | Number | Arguments | Result |
| --- | --- | --- | --- | --- |
| x86-64 | `int 0x80` | `rax` | `rdi`, `rsi`, `rdx` | `rax` |
| ARM64 | `svc #0` | `x8` | `x0`, `x1`, `x2` | `x0` |
| RV64 | `ecall` | `a7` | `a0`, `a1`, `a2` | `a0` |

This internal probe ABI has three calls: report an eight-byte private sentinel
(`0`), exit (`1`), and attempt an object-handle write (`2`). Invalid pointers
return `-14`, denied writes return `-13`, and unknown numbers return `-38`,
encoded as signed 64-bit results. It is not a stable Bedrock64 or POSIX ABI.

After these probes and their cleanup, the same protected trap adapters run
separately linked native ELF programs using Bedrock64 calls beginning at
`0x100`. Init, spawn/wait/exit, sleep/yield and blocking IPC are implemented in
the shared process runtime. Checked copyout permits only the current process's
RW data/stack mappings. See [native processes](native-processes.md). The current
VFS checks trusted app ownership and descriptor rights for bundle/container I/O;
its durable backend and Files client extend that bounded profile. Installation,
brokers and broader object services still gate the complete sandbox.

The dispatcher translates input through the current task's trusted mappings
and reads the corresponding supervisor physical alias. It never dereferences
an unchecked user pointer. Empty, overflowing, unmapped, unreadable and
page-crossing requests fail. Copying across mappings, concurrent unmapping and
long-running I/O are outside this bounded, single-CPU interface.

Each fixture gets a kernel-issued app identity, a three-page/one-handle/one-process
budget, and a read-only test-object handle authorized with its own bundle
provenance. The write call resolves that token in the current task's table and
checks write authority. There is no VFS or file-write backend behind the test
object. Numeric tokens alone cannot select another task's grant. The three
payload-frame, one-handle and one-process charges are returned during fixture
cleanup. Private page tables are reclaimed separately by their architecture
adapter. Page-table and other kernel overhead are not yet fully charged to an
app; shared kernel tables, trap stacks and allocator metadata remain permanently
kernel-owned.

## Resource ownership and cleanup

The trusted fixture owner records its three payload frames and its address-space
reference. Architecture adapters record the table frames they allocate for that
space, separately from permanent or shared kernel tables. A partially failed
table build returns every frame it allocated. The caller remains responsible
for payload pages, so a failed task creation can unwind both owners without
freeing shared mappings or another task's memory.

Cleanup destroys saved native contexts before their address space, then returns
the owned payload frames, closes the test handle and releases the fixture's
resource charges. An active task or a space with a live context reference cannot
be destroyed. The adapter invalidates affected translations before its private
table frames return to the physical allocator. These changes happen on the
single CPU with kernel interrupts masked.

Address-space references pair a physical root with a globally issued nonzero
generation. Saved-context handles identify a bounded registry slot and its
generation. Reused slots reject old references, and generation exhaustion cannot
wrap into a previously valid identity. These are trusted kernel references, not
application authority tokens.

A page-backed kernel heap obtains owned, zeroed frames and returns them on free.
This supplies kernel allocation alongside fixture cleanup; it does not define
user-space allocation APIs or implement a general Unix process lifecycle.

## Runtime acceptance

Both tasks first directly read their distinct private sentinels in user mode
and supply those values to their report syscalls. The dispatcher verifies both
the user-loaded value and the checked copyin value against each task's
kernel-owned expectation, so a wrong-root transition cannot pass by reading
only supervisor aliases. Both complete valid reporting, invalid-pointer rejection,
unknown-call rejection, denied-handle writing and clean exit. The first task
then attempts five forbidden accesses:

1. Read supervisor kernel text.
2. Read the other task's backing page through its physical identity address.
3. Write its own read-only code.
4. Execute its non-executable stack.
5. Read the unmapped stack guard.

The kernel checks the reported fault address and the architecture's precise
page-fault/abort cause. In particular, an illegal instruction on an executable
stack does not count as NX enforcement. After every contained fault the kernel
switches to the second task's root, runs all its syscall checks again and
verifies its private sentinel remains intact. Boot runners require all five
faults and ordered completion markers; normal images run the same checks before
idling. A subsequent [timer-preemption workload](preemptive-scheduling.md) runs
both tasks without yielding and verifies saved-context resume across six turns.

Lifecycle acceptance also requires table-allocation caps of zero through three
to fail without leaking physical frames, live-context teardown to be rejected,
and destroyed context/address-space references to remain invalid after reuse.
Acceptance repeats creation and cleanup for more than eight cycles, beyond the
bounded registry capacity. After each cycle the owned payload and table frames,
handle and process charges must return to their baseline; permanent kernel and
allocator resources stay owned. Heap acceptance checks zeroed allocation,
release and reuse separately.

## Remaining work

The protection/syscall fixtures run with user interrupts masked. A separate
saved-context workload enables hardware timer preemption and round-robin user
execution. Kernel execution remains interrupt-masked, with no SMP support.
The original protection tasks remain fixed boot fixtures with explicit cleanup
and rollback. The later native runtime implements init, spawn/exec/wait/exit,
blocking IPC and app-scoped files. A contained fault terminates that execution
and returns control to the trusted kernel. Arbitrary application admission and
general executable layouts remain future work.

The current protected Files ELF uses a larger bounded layout, durable private
container and checked drawing/input calls. Display ownership, input polling and
single-window policy remain kernel-hosted; no client receives raw device or GOP
access. The preceding extension's [integrated verification](storage-and-files-verification.md)
passed all three UEFI references in Debug and ReleaseSafe, including checked
syscall authority and abrupt-shutdown/fresh-boot recovery. The compact redesign
opens with a sidebar and single file list, with bounded history and optional
Split. Its Copy/Cut/Paste, double-click and mouse name-confirmation controls use
the same checked file/namespace boundary.

Close and minimize have separate lifetimes. Minimize hides the window while
retaining its protected client. Close/Alt+F4 is deferred until a trusted kernel
continuation before closing descriptors, destroying the saved context and
address space and returning its owned frames; the host checks the allocator
baseline. The bar Files target or Super+E launches a fresh protected client and
preserves its durable container. Maximize/restore and fullscreen/F11 reuse the
client with checked new drawing bounds and a queued redraw; Escape leaves
fullscreen. A retained caption strip supplies an exit control. The revised
[UI acceptance](files-ui-verification.md) passed in Debug and ReleaseSafe on
all three named QEMU profiles: six two-boot workflows, twenty-four client
starts and twelve checked close/reclamation operations. Saved file bytes are
checked again after each fresh client. This remains one kernel-hosted window.

Bundle installation, trusted launch
configuration, external resource brokers, libc, a standalone compositor and
physical qualification remain later work. Direct-reset reference images retain their
earlier allocator and breakpoint checks; this user-mode milestone applies to
the three primary UEFI paths.

CPU references: [Intel system programming manuals](https://www.intel.com/content/www/us/en/developer/articles/technical/intel-sdm.html),
[Arm exception model](https://documentation-service.arm.com/static/63a065c41d698c4dc521cb1c),
and [RISC-V supervisor specification](https://docs.riscv.org/reference/isa/priv/supervisor.html).
