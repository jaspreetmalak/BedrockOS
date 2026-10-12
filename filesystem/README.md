# Filesystem package

This independent Zig 0.17.0 package provides a synchronous block-device
interface, a bounded in-memory backend and a durable snapshot filesystem. It has no kernel or
security dependencies. A kernel VFS owns authorization, descriptors, mounts
and synchronization; platform drivers supply the device callbacks.

The public module is `filesystem`. It exports `ramfs`, `durable`, `BlockDevice`, `ReadFn`,
`WriteFn`, `FlushFn`, `ValidationError`, `ReadError` and `WriteError`. Block callers supply a borrowed opaque context, a
read callback, a nonzero block size and a nonzero block count. The caller owns
storage access, memory, synchronization and the context's lifetime.

`BlockDevice.read(start_block, buffer)` derives the number of requested blocks
from the buffer length. It rejects invalid geometry, partial-block buffers,
out-of-range requests and arithmetic overflow before calling the backend.
Device capacity must fit in a 64-bit byte count. An empty read is a no-op at
positions from zero through the end of the device. Backend errors are forwarded
unchanged; `ReadError` is therefore `anyerror`, while `ValidationError` names the
errors produced by validation.

The callback receives the context, start block, block count and destination
buffer. It must complete the entire read or report an error before returning.
On a backend failure, the destination may have been partially modified.

Optional `write_fn` and `flush_fn` callbacks extend the same device descriptor.
`write(start_block, buffer)` checks whole blocks, geometry and bounds before
calling the backend; absent write authority returns `ReadOnly`. Its callback
receives a const source buffer and must complete the whole write or fail.
`flush()` validates geometry and requires a flush callback (`FlushUnavailable`
otherwise). The driver must make all earlier completed writes durable before
returning success. Callbacks and opaque context remain borrowed and serialized
by the caller; an error may follow a partially completed write or flush.

`filesystem.ramfs.RamFs(node_capacity, file_bytes, path_bytes)` stores bounded
directory records and mutable file buffers in caller-owned memory. Capacity
includes the root and all directory/file nodes; `file_bytes` bounds each
mutable file and `path_bytes` bounds each full absolute path. Its constants
`max_nodes`, `max_file_bytes` and `max_path_bytes` expose those limits. Keep a
large instance in permanent storage such as the VFS's BSS and initialize with
`fs.reset()` in place, instead of returning a large stack aggregate.

The RAM backend exposes `root`, `lookup`, `mkdir`, `create`, `addBorrowed`,
`stat`, `size`, `path`, `contents`, `read`, `write`, `truncate`, `enumerate` and
`nullify`.
Paths must already be canonical absolute byte paths: no empty components,
`.`/`..`, NUL or trailing slash except `/`. Parent directories must exist.
Enumeration returns immediate children in insertion order through a
caller-owned cursor; it observes the live tree rather than a snapshot.

`addBorrowed(path, metadata, bytes)` mounts immutable content of arbitrary
length without copying it into a mutable buffer. Its source must stay alive
and immutable until reset. This supports embedded ELF and bundle resources.
`Metadata` records a trusted `Domain` (`system`, `bundle` or `container`), an
opaque `owner` value and `executable` intent. Metadata is fixed at creation;
only borrowed files can carry executable intent. These fields do not enforce
permissions: the caller must recheck domain, ownership and rights, including
requiring an immutable borrowed node for execution.

RAM reads return a short count or zero at/beyond EOF. Writes either complete
or fail before mutation; seeking past EOF and then writing zero-fills the gap.
Empty writes do not extend a file. Truncation clears removed bytes and
zero-fills extension, so later reads cannot expose old contents. Offset
arithmetic and mutable capacity are checked before touching output/storage.
Live file-byte overlap uses memmove semantics. Caller buffers must remain
valid and must not alias filesystem metadata.

`nullify(path)!void` accepts only mutable container files. It clears the full
owned node, including unused data/path tails, through explicit volatile byte
stores and removes the file. Directories return `IsDirectory`; immutable,
borrowed and system files return `ReadOnly`. Ownership authorization remains
the VFS caller's responsibility. The removed slot is retired until reset, so
an old node ID cannot regain authority through slot reuse.

RAM nodes are session-lived with no ordinary unlink or slot recycling. `NodeId` combines
a one-based slot and per-instance reset generation. Keep the same instance and
associate IDs with it; IDs are not global object authority. `reset` clears all
mutable storage and records and invalidates every earlier ID and borrowed view.
Generation exhaustion fails without mutation. Never reset while descriptors
or views remain live. `contents` and `path` return borrowed views; mutable
contents can change after write/truncate. All operations require caller
serialization; the package supplies no lock or global allocator.

`filesystem.durable.DurableFs(node_capacity, file_bytes, path_bytes)` provides
the same lookup/file API plus `mount`, `format`, `copy`, `rename` and `unlink`.
Its production configuration is `(32, 4096, 128)`. Keep its two bounded RAM
snapshots in retained storage; it needs no heap and avoids large transaction
aggregates on a kernel stack. `mount(device)` requires writable 512-byte sectors,
a flush callback, at least 8192 sectors and matching on-disk capacities. It never
formats missing/corrupt media. `format(device)` is a separate destructive
trusted setup operation, unused by the production mount path.

The dedicated 4 MiB Bedrock data format has two 2 MiB banks. A transaction
writes the inactive payload, flushes, writes its CRC/generation header and
flushes again before publishing the new RAM snapshot. Mount validates both
banks and chooses the highest valid generation. Any commit I/O error poisons
that instance (`RemountRequired`): recover through a new instance after closing
all descriptors. A failed final write/flush has an uncertain old-or-new outcome;
the caller must not report a guaranteed rollback or continue using stale RAM.

Mutable files and container/system directories persist. `/bundle` and its
immutable borrowed files are a trusted RAM overlay rebuilt from the ROM catalog
after each mount. `copy(source,destination,container_metadata)` copies a complete
bounded subtree atomically; copied executable flags are cleared. `rename`
updates an entire subtree without replacing an existing path and preserves its
node IDs. `unlink` removes a file or empty directory; an old ID then fails even
after its slot is reused. IDs combine slot and a monotonic node serial and are
local to the mounted instance; overflow retires future creation instead of
wrapping. Every `path` borrow and mutable `contents` borrow expires at the next
successful transaction; immutable ROM contents keep their source lifetime.
The VFS must recheck owner/domain throughout a subtree and bind
every descriptor operation to the trusted current app profile.

Durable `nullify(path)!void` is a separate file-only operation. It first checks
room for **two** generations, then volatile-clears historical RAM, removes the
target node, normalizes unused tails and retains two clean copies of the current
tree. It reconstructs the complete inactive 2 MiB bank, including unused tail
sectors, flushes payload/header and compares every readback byte against the
expected sanitized encoding. Only after that bank is verified does it reconstruct
and verify the former active bank. Success requires both clean committed banks.
Current other files, owners and explicitly copied file contents are preserved.
Ordinary `unlink` remains a single transaction and makes no erasure claim.

Any write, flush or readback failure after RAM sanitization poisons the instance.
Readback mismatches return `NullifyVerificationFailed`; further operations return
`RemountRequired`. A failed or interrupted nullify may leave the file gone while
older logical bytes remain, so no erasure success or rollback is promised.
Preflight failures occur before RAM/device mutation. All path/content borrows
expire when nullify begins sanitization, including when later I/O fails.

The success guarantee covers target records/history in the **current Bedrock
logical banks and filesystem-owned RAM snapshots**, assuming the device honors
reads, writes and successful flushes. It excludes caller-held copies, application
previews, other files containing copies, device caches, earlier VM/image snapshots,
backups and physical storage hidden by remapping. Logical readback cannot prove
that old NAND cells or host-filesystem copies were erased. NIST explains that
flash spare cells and wear leveling can keep old data beyond the ordinary native
read/write interface; Bedrock does not claim device purge or certified media
sanitization. See [NIST SP 800-88 Rev. 2](https://csrc.nist.gov/pubs/sp/800/88/r2/final).

The kernel's storage runtime mounts this backend once per boot on the dedicated
`bedrock-data` device. Stable launcher IDs keep acceptance workload 1 separate
from native Files 2 across reboot. Files uses checked VFS directory/file
requests; its protected client never receives the block device or raw image.

See [persistent filesystem format](../docs/persistent-filesystem.md) for the
wire layout, recovery assumptions and ordinary-file image creation commands.

Run independently from this directory:

```text
zig build
zig build check
zig build test
```

The default build installs the static `bedrock-filesystem` compile-probe library.
The `check` step compiles it without installing or running tests. Its exported
C-compatible functions force the block-device, RAM and durable backend's actual API
paths to compile for the selected target; they are compile probes rather than
the filesystem API. The `test` step runs host boundary tests for block callback
forwarding, tree lookup, immutable borrows, short reads, zero-filled gaps,
atomic capacity failures, overlapping bytes, truncation, enumeration and stale
IDs, durable reopen/recovery, commit failures, CRC/record validation, subtree
mutations and serial exhaustion, including when a different compile target is selected.
Nullify tests also inspect both complete raw banks, old versions/renamed paths,
RAM/tail clearing, corruption fallback, unrelated copies/owners, two-generation
preflight, silent ignored writes and failures in both erase phases. They exercise
every payload-sector boundary, first/middle/final identical tail batches, every
header/flush/readback path and uncertain failed flushes using in-memory fake
devices only.
