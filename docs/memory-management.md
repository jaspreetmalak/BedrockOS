# Bootstrap physical memory

Bedrock's shared physical-memory allocator manages complete 4 KiB frames. It
returns physical addresses and ranges; it does not create virtual mappings.
Bounded ownership records and a page-backed kernel heap build on that allocator;
the heap has page granularity and no `std.mem.Allocator` adapter. UEFI remains the
primary boot environment, and the three reset profiles exercise the same portable
allocator and startup checks.
All current emulator profiles run one CPU or hart. No physical machine has been
qualified.

## Ownership and accessibility

The handoff's `memory_regions` array determines ownership. Only regions explicitly
marked `usable` may supply frames. Loader, kernel, firmware-runtime, MMIO,
reserved and unknown kinds remain unavailable. Missing regions grant no
permission. The legacy `ram` field is an informational envelope and may contain
holes; it is not an allocation arena.

Accessibility is a separate condition. `Layout.init` intersects usable regions
with explicit `mapped_ranges`, when present, and with a trusted exclusive
address ceiling supplied by the architecture adapter. These ranges describe
current identity access: virtual addresses equal physical addresses. They do
not give the kernel ownership of firmware or device memory. UEFI requires
explicit coverage; reset profiles establish their own direct-access and mapping
contracts. A ceiling alone does not imply that every address below it exists.

The layout includes only full pages contained in those intersections and always
excludes physical page zero. It copies eligible extents into its own bounded
storage rather than retaining slices into `BootInfo`. It rejects malformed,
overlapping or unsorted memory/coverage arrays and arithmetic overflow. Full
handoff validation and the platform's trusted pointer checks must occur first;
layout validation covers only the memory and accessibility inputs.

The architecture adapter supplies these exclusive ceilings:

| Architecture | Reset reference | UEFI |
| --- | --- | --- |
| x86-64 | Smaller of 4 GiB and the CPUID physical-address limit | Smaller of 128 TiB and the CPUID limit, intersected with explicit coverage |
| ARM64 | CPU physical-address limit decoded from `ID_AA64MMFR0_EL1.PARange` | Same CPU limit and explicit coverage; the reported width must match |
| RV64 | `2^56` under the named QEMU `virt` contract | Same contract and explicit coverage; S-mode access still depends on machine firmware permissions |

ARM decoding currently accepts widths from 32 through 52 bits. These limits
describe the current bootstrap execution state, not all hardware with that ISA.
Frame clearing uses naturally aligned volatile 64-bit stores; publication uses
`MFENCE`, `DSB SY` or `FENCE RW,RW` respectively. It supplies neither instruction
cache maintenance nor device/DMA synchronization. Normalized region attributes
do not encode cache policy; later protected mappings must preserve compatible
policy from the retained firmware descriptions and architecture state.

## Modules and APIs

| Module | Responsibility |
| --- | --- |
| `core/memory.zig` | Discovered-memory accounting and the earlier bootstrap page cursor |
| `core/physical_memory.zig` | Portable layout, bitmap bookkeeping, allocation and checked release |
| `core/owned_frames.zig` | Bounded owner ledgers and generational frame-allocation tickets |
| `core/kernel_heap.zig` | Portable page-granular heap bookkeeping over owned frames |
| `core/memory_init.zig` | Retained kernel allocator, owner-ID issuer, zeroing APIs and startup RAM workloads |
| `arch/physical_memory.zig` | CPU address ceiling, physical reads/writes and publication barriers |
| `platform/<board>/main.zig` | Trusted handoff and CPU-state validation, console and trap setup |

The kernel package exports `physical_memory` through `src/root.zig`.

| API | Contract |
| --- | --- |
| `Layout.init(info, limit_exclusive) !Layout` | Copy eligible page spans, calculate bitmap size and choose its permanent storage range |
| `Allocator.init(layout, bitmap) !Allocator` | Validate the layout and caller's bitmap capacity, initialize bits and reserve metadata pages |
| `allocate() ?u64` | Return one owned physical frame, or `null` when exhausted |
| `release(address) !void` | Release one page-aligned, currently allocated nonmetadata frame |
| `allocateContiguous(count, alignment_pages) !?PhysicalRange` | Return a contiguous run with physical alignment, or `null` if no fitting run exists |
| `releaseContiguous(range) !void` | Validate the entire run before changing any bits or counters |
| `stats() Stats` | Report managed, free, caller-allocated and metadata page counts |

Contiguous counts must be nonzero. Alignment is a nonzero power-of-two number of
pages: `allocateContiguous(4, 4)` requests 16 KiB aligned to 16 KiB. A run cannot
cross a physical hole. Failed allocation leaves state intact. Release rejects
unaligned addresses, invalid lengths, addresses outside managed spans, metadata
pages and pages already free. It completes validation before modifying a run.
Callers retain responsibility for the lifetime and ownership of returned frames.
The bitmap validates allocated status, not which subsystem owns a frame.
`Owner(capacity)` adds bounded owner records and generational allocation tickets
above this bookkeeping. `Heap(capacity)` adds zeroed, page-backed runtime
allocations; see [resource lifecycle](resource-lifecycle.md).

The allocator does not clear frames on allocation or release. Runtime
`memory_init.allocateZeroed() !u64` allocates a frame and clears all 4 KiB before
returning it; it reports uninitialized state or exhaustion as errors.
`memory_init.allocator()` exposes the retained allocator after initialization.
Neither interface performs synchronization. Callers must serialize access until
interrupt and SMP coordination is implemented.

`memory_init.allocateKernel(bytes, alignment)` returns a heap ticket after
clearing its complete page-rounded allocation. `resolveKernel(ticket)` returns
the physical range and requested byte length; `freeKernel(ticket)` releases the
exact recorded range. Alignment is a nonzero power of two in bytes. Neither the
portable owner nor heap module dereferences or clears physical RAM on its own.
`memory_init.newOwnerId()` uses the retained kernel issuer. Live ledgers must not
be duplicated or reinitialized with a previously used owner identity.

## Bitmap storage and lifetime

The layout holds at most 128 eligible spans, derived from the bounded handoff
arrays. Physical holes consume no bitmap bits. One bit represents each managed
page, so `bitmap_bytes` is the managed page count rounded up to whole bytes after
division by eight. `layout.storage` rounds that size up to full pages and selects
the first eligible contiguous extent large enough to hold it. If none fits,
initialization fails with `MetadataUnavailable`; it does not use reserved RAM or
fall back to a heap.

The caller supplies the actual bitmap slice. Kernel startup exposes the selected
physical storage through the architecture adapter; native tests can use an
ordinary byte array. Only `layout.bitmap_bytes` bytes are accessed. The bitmap
must outlive its allocator and must not be modified separately. The layout is
copied into the allocator, and unused bitmap tail bits stay unavailable.

Metadata pages are permanently busy for the current allocator's lifetime. They
are included in `managed_pages` and `metadata_pages`, excluded from `free_pages`
and caller `allocated_pages`, and cannot be released. This reservation is tracked
by the allocator; it does not rewrite the original handoff memory map. The
discovered-memory report therefore differs from the allocator's free-page count.
Loader and firmware reservations are also retained; reclaiming them requires a
later explicit ownership transition.

## Startup workload and acceptance

After handoff validation, each platform calls shared `memory_init.initialize`.
It reports discovered memory, builds the layout, initializes the bitmap and
retains one kernel-owned allocator. Its workload allocates two zeroed frames,
writes distinct patterns, allocates an aligned four-page run and checks every
word through volatile physical access. It then releases and reuses a frame,
checks that reuse clears previous contents, checks that the other frame retains
its pattern, releases all workload frames and compares allocation counters with
their starting values.

Both bounded boot runners require these serial markers in order after
`[kernel] handoff valid`:

```text
[kernel] allocator ready pages=
[kernel] page allocation verified
[kernel] page reuse verified
[kernel] kernel heap verified
[kernel] exception handled
```

The runners also require the existing `[kernel] memory regions=` report, the
architecture's completion marker and expected emulator exit status. Panic,
fault, missing markers, ordering failures and timeouts fail acceptance. The
same allocation workload runs in normal images before their idle loop.

`zig build test` at the workspace root and in `kernel/` includes native layout
and allocator tests. Their fixtures cover partial pages, holes, unknown and
reserved kinds, sparse coverage, high physical addresses, exhaustion, metadata
capacity, alignment, overflow and atomic invalid/double releases. Native tests
verify bookkeeping with host-owned bitmap storage; bounded QEMU tests verify
actual physical RAM access and zeroing on all six UEFI/reset paths. The
`test-boot-matrix` step expands those paths across configured RAM sizes.

The primary UEFI kernels consume this allocator for protected paging, private
user tasks and saved contexts for timer preemption. Runtime lifecycle acceptance
adds rollback of failed task creation and release of completed fixture resources.
Saved contexts must be destroyed before private address-space tables, with
translations invalidated before table frames are recycled. Only then may the
core release the task's code, data and stack frames. Bootstrap kernel tables,
shared supervisor mappings and dispatcher/trap stacks remain permanent; private
table ledgers must never release them.

The bounded page-backed heap is separate from the physical allocator and from
user virtual-memory management. It does not supply a general Zig allocator,
application loading, process lifecycle or VFS. The fixture's three-page payload
quota covers code, data and stack; table pages and kernel overhead are not yet
charged to that quota. Table-page limits provide a separate resource bound.

The lifecycle acceptance requires failed creates with table limits 0 through
3 to restore allocation counts, successful destruction and reuse beyond registry
capacity, stale-token rejection, and zeroed reuse on all three UEFI profiles.
Those checks are distinct from the physical-allocator workload above; runtime
results are recorded in the [resource lifecycle](resource-lifecycle.md) document. See
[resource lifecycle](resource-lifecycle.md) and
[protected userspace](protected-userspace.md). Loader/firmware reclamation,
general virtual-memory management and SMP synchronization remain future work.
