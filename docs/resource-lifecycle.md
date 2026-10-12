# Runtime memory ownership and cleanup

This milestone defines bounded ownership for kernel runtime allocations and
the protected boot fixtures. It builds on the
[physical-frame allocator](memory-management.md), existing user isolation and
timer-preempted contexts. It does not add user ELF loading, general processes,
IPC, VFS or a general virtual-memory manager. The checks below pass on the
current single-CPU QEMU profiles.

## Ownership layers

The physical bitmap knows whether a managed frame is allocated. It does not
identify the subsystem that may release it. `Owner(capacity)` supplies a bounded
ledger above that allocator. Each owner receives a globally issued, nonzero
`OwnerId`; allocation tickets bind a live allocation to its owner and generation.
An old ticket must not authorize release after its slot or physical pages are
reused. Identity and generation exhaustion must fail rather than wrap into a
previously valid token.

Runtime owners obtain identities through the retained issuer in
`memory_init.newOwnerId()`. A live owner or heap ledger must not be duplicated
into a second live ledger, or reinitialized with an old identity. Owner IDs and
tickets are trusted kernel bookkeeping, not application-supplied credentials.

`Heap(capacity)` uses owned physical pages for kernel runtime memory. Allocation
has page granularity. The portable heap records allocations; the runtime
`memory_init.allocateKernel` wrapper clears every allocated page before returning
its ticket. This is a bounded page-backed heap, without small-object bins or a
`std.mem.Allocator` adapter.
It does not create mappings; the caller uses pages already accessible through
the current supervisor mappings. Physical ownership and addressability remain
separate requirements.

| Module/API | Responsibility |
| --- | --- |
| `core/owned_frames.zig`: `Owner(capacity)` | `init`, `allocate`, `resolve`, `release` and `releaseAll` maintain exact owned ranges |
| `core/kernel_heap.zig`: `Heap(capacity)` | `allocate(bytes, alignment)` rounds sizes to pages; `resolve` returns the range and requested length; release uses the recorded ticket |
| `memory_init.newOwnerId()` | Issue a unique runtime owner identity without wrapping |
| `memory_init.allocateKernel(bytes, alignment)` | Allocate and zero a runtime block, returning its ticket |
| `memory_init.resolveKernel(ticket)` / `freeKernel(ticket)` | Resolve or release the exact live heap allocation |

Owner allocation takes page counts and alignment in pages. Heap alignment is in
bytes and must be a nonzero power of two; requests smaller than a page still own
a complete page. Invalid requests and capacity/exhaustion failures publish no
allocation ticket. `releaseAll` is cleanup for one ledger: a backend invariant
error retains the failing range and stops, while earlier successful releases
remain released. It is not an atomic rollback of already completed releases.

| Resource | Owner and lifetime |
| --- | --- |
| Allocator bitmap metadata | Permanent for the physical allocator's lifetime |
| Kernel image and bootstrap translation tables | Permanent kernel resources |
| Shared supervisor table branches and dispatcher/trap stacks | Permanent; never released by private-space cleanup |
| Loader and firmware reservations | Retained until a separate explicit reclamation transition |
| Kernel heap allocations | Bounded heap/owner ledger; released through valid allocation tickets |
| Fixture code, data and user stack | Core-owned payload frames; released after contexts and mappings |
| Private address-space table pages | Architecture-owned ledger; released on failed creation or explicit space destruction |
| Saved native contexts | Bounded kernel registry; explicit destruction makes a slot reusable |

The kernel's native shell preview scratch remains BSS storage in its image; it
is not a task or heap allocation. Directory and package boundaries do not
establish physical ownership.

## Creation and rollback

Task construction acquires zeroed code, data and stack frames and records them
under their core owner. Address-space construction owns only newly allocated
private translation-table pages. The architecture records each allocation as
it occurs, including tables created by splitting a large mapping. It never
infers ownership by walking mapped leaves: those leaves can refer to core-owned
payload, shared kernel memory, firmware or devices.

`createWithTableLimit(frames, table_limit)` applies a per-address-space bound
that includes the private root and all private child tables. `create(frames)`
uses the normal architecture limit. Resource-limit or mapping failure returns
every table page acquired by that attempt before returning an error. It neither
takes ownership of the supplied payload frames nor leaves a published space or
context. The core then rolls back its own acquisitions.

The fixture's existing three-frame memory quota covers its code, data and user
stack only. Private tables, kernel stacks and other kernel overhead are not yet
charged against that payload quota. The table-page limit is a separate bounded
resource policy, not complete process-memory accounting.

## Destruction and reuse

Cleanup proceeds in this order:

1. Stop running the task and return to the trusted kernel continuation/root.
   Kernel mutations occur with interrupts masked.
2. Call `destroyContext(handle)` for every saved context referring to the space.
   Runnable, suspended and terminated records still retain references until
   destroyed. An active context cannot be destroyed.
3. Call `destroy(space)` after its last context is removed. Reject an active
   space or remaining context references. Invalidate translations before any
   private table frames can be recycled. Permanent/shared tables stay owned.
4. Release the core-owned code, data and stack through their owner tickets.
   Release other owned runtime allocations and confirm expected accounting.

Address-space records include the physical root and a globally issued nonzero
generation. Reusing a root address in another registry slot cannot revive an old
record. Saved-context handles encode a one-based slot in the low 32 bits and a
generation in the high 32 bits. Destroying a record invalidates its old handle;
generation exhaustion retires the context slot. `validateContext(handle)` checks
a handle without attempting user entry. These handles are kernel-only records,
not values chosen by applications.

All owner, heap, allocator and registry operations require caller serialization.
Current profiles run on one CPU/hart, and kernel mutations keep interrupts
masked. There is no concurrent teardown, remote TLB shootdown, SMP reclamation
or automatic lifetime management for arbitrary external references.

## Acceptance boundaries

Portable ownership and heap tests must cover wrong-owner and stale tickets,
exhaustion, partial acquisition rollback, invalid/double release and unchanged
accounting after rejected operations. Runtime checks must exercise actual RAM,
not only host bookkeeping.

On each x86-64, ARM64 and RV64 UEFI profile, acceptance requires:

- Table limits 0, 1, 2 and 3 fail with `PageTableCapacity` and restore physical
  allocation counts, including failures after partial table construction.
- Successful fixture creation, protected execution and destruction return all
  private table and payload frames while preserving permanent kernel resources.
- More than eight create/destroy cycles demonstrate reusable registries rather
  than append-only capacity.
- Destroying a space with a live saved context fails without mutation. Destroyed
  context handles and stale address-space records cannot select reused resources.
- Reused runtime allocations are zeroed, and surviving allocations retain their
  contents while other owners are released.
- Existing isolation, precise fault containment and saved-PC timer-preemption
  workloads continue to pass.

The timer workload creates and destroys an initial context for each task before
resuming its replacement generation. The six real timer returns therefore check
reused-slot entry and saved-state restoration, as well as stale validation. The
reuse workload runs 12 cycles, replaces a task while its peer remains intact,
requires physical root reuse with a different generation, and returns allocation
counts to the permanent-resource baseline after every cycle.

## Verified results

Verified on 2026-10-11 with the pinned Zig 0.17.0 toolchain:

| Check | Result |
| --- | --- |
| `zig build test check uefi test-boot-matrix --summary all` | Debug: 136/136 steps; all 18 boot configurations pass |
| Same command with `-Doptimize=ReleaseSafe` | ReleaseSafe: 136/136 steps; all 18 boot configurations pass |
| `zig build test check` in `kernel/` | Standalone package: 29/29 steps pass |
| `zig build test-uefi-x86_64 -Doptimize=ReleaseSafe -Duefi-kernel-min=4294967296 -Dram-mib=4096` | Pass; kernel placed at physical 0x100000000, including lifecycle checks |
| Normal UEFI images with graphics | All three architectures remain alive and render the native AxisUI preview in Debug and ReleaseSafe |

Each matrix covers x86-64, ARM64 and RV64 reset references at 64/128/512 MiB
and primary UEFI paths at 128/256/512 MiB. Heap RAM/zeroing checks run on all six
paths. Protection, saved-context preemption and full fixture teardown/reuse run
on the three UEFI paths. Five new portable tests cover ownership and heap policy;
the existing native tests and cross-compilation checks also pass. Both boot
runners require heap and lifecycle completion markers, alongside the five
contained user faults and six timer returns on UEFI.

The normal-image checks capture the framebuffer after the complete kernel
workload and verify the native preview completed and stayed alive. Debug and
ReleaseSafe previews match for each architecture. No physical hardware
validation or complete general-purpose process lifecycle is implied.
