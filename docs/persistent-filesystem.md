# Persistent filesystem

Bedrock's first durable backend is `filesystem.durable.DurableFs(32, 4096, 128)`.
It mounts a dedicated **4 MiB Bedrock data image** through kernel-owned block
read, write and flush callbacks. The boot ESP remains separate. Filesystem
code is portable and allocation-free; the kernel VFS supplies namespace
authority, process descriptors and serialization. The disk is authoritative
after mount and after every completed transaction.

The first profile allows **32 total nodes**, including the root, system and app
directories, immutable bundle overlay nodes and mutable files. Each mutable
file holds at most **4096 bytes**. Full backend paths hold at most **128 bytes**;
the hidden app-ID prefix consumes part of this bound. Listed basenames hold at
most 96 bytes and fail explicitly rather than being truncated. Empty-directory
deletion is supported; deleting a nonempty directory returns `DirectoryNotEmpty`.

The trusted launcher assigns stable app IDs: acceptance workloads use 1 and
Files uses 2. A caller's virtual `/container/...` resolves only to that app's
persisted private container; `/bundle/...` resolves only to its immutable ROM
bundle overlay. User request text cannot choose an owner. The VFS checks
namespace authority before lookup/create and rechecks owner, domain and rights
on every descriptor operation. Directory copy/rename/remove also validate all
descendants before mutation. Mutable container bytes cannot be executed.

## Data format v1

All multibyte integers are little-endian. Device sectors are 512 bytes. The
first 8192 sectors form two banks of 4096 sectors (2 MiB each); larger devices
have no additional usable capacity in this format. Each bank starts with a
512-byte header followed by a fixed node-record payload. Bytes after the
logical payload are outside the format and ignored. This is a dedicated raw
data format with no partition table or compatibility promise for other filesystems.

| Header offset | Size | Field |
|---|---:|---|
| 0 | 8 | Magic `BEDFS001` |
| 8 | 4 | Version: 1 |
| 12 | 4 | Header bytes: 512 |
| 16 | 8 | Nonzero snapshot generation |
| 24 | 8 | Format disk sectors: 8192 |
| 32 | 4 | Bank sectors: 4096 |
| 36 | 4 | Node capacity |
| 40 | 4 | Mutable bytes per file |
| 44 | 4 | Path bytes per node |
| 48 | 8 | Logical payload bytes |
| 56 | 4 | Payload CRC32 |
| 60 | 4 | Header CRC32, computed with this field zero |
| 64 | 4 | Next node serial; zero means exhausted |
| 68 | 4 | Bank index: 0 or 1 |
| 72 | 440 | Reserved, must be zero |

CRC32 uses the IEEE reflected polynomial `0xedb88320`, initial value
`0xffffffff` and final XOR `0xffffffff`. It detects accidental corruption and
does not authenticate media. The payload CRC covers exactly the logical node
records; padding in the last payload sector is written as zero.

Each node has a 64-byte record header followed by `path_bytes` path storage and
`file_bytes` file storage. The first-profile record size is 4288 bytes and its
32-node payload is 137216 bytes. Record fields are:

| Record offset | Size | Field |
|---|---:|---|
| 0 | 1 | Occupied: 0 or 1 |
| 1 | 1 | Kind: 1 directory, 2 mutable file |
| 2 | 1 | Domain: 0 system, 2 container |
| 3 | 1 | Reserved, zero; persistent nodes are never executable |
| 4 | 4 | Nonzero node serial |
| 8 | 8 | Trusted owner; zero for system, nonzero for container |
| 16 | 4 | Parent slot index |
| 20 | 4 | Path length |
| 24 | 8 | File length; zero for a directory |
| 32 | 32 | Reserved, must be zero |
| 64 | `path_bytes` | Canonical absolute path, then zero padding |
| `64 + path_bytes` | `file_bytes` | File bytes, then zero padding |

An empty or overlay slot serializes as an entirely zero record. Slot 0 is the
system root `/`, with serial 1 and parent 0. Mount validates all bounds,
reserved bytes, kinds, metadata, unique paths/serials and exact directory
parent paths as well as both CRCs. Valid CRCs do not bypass record validation.
Unknown versions or incompatible capacities fail explicitly.

## Commit and recovery

Each mkdir/create/write/truncate/copy/rename/unlink is one bounded transaction.
Two RAM snapshots retain the live tree and staged tree in kernel BSS. The
backend preflights paths, capacity, offsets and serial exhaustion, then:

1. Stages the complete mutation without changing the live snapshot.
2. Writes all payload records into the inactive disk bank.
3. Flushes the payload to durable media.
4. Writes that bank's single-sector header with the new generation and CRCs.
5. Flushes the header, then publishes the staged RAM tree.

The previous active bank remains untouched until a later transaction uses it
as the inactive bank. Reopening in a new instance selects the highest fully
valid generation and can fall back to the previous valid bank. Both-invalid
media returns `NoValidSnapshot`; mount never silently formats it. Recovery
assumes the device honors successful flushes and corruption is detected by the
CRCs. The generation and node serial counters never wrap.

Any commit I/O failure marks the current instance `RemountRequired`. A failed
header write or final flush can leave a complete old **or** complete new
snapshot; the error cannot promise that the mutation was rolled back on disk.
Further reads and writes through that instance fail closed. Close all live
descriptors and borrowed views before mounting a new instance or restarting.

`rename` updates an entire subtree atomically, preserves node IDs and rejects
destination replacement and moving a directory into itself. `copy` makes a
new bounded subtree with new IDs and mutable, non-executable destination files.
Removing a file invalidates its earlier node ID and every descriptor backed by
it; this first profile does not retain POSIX open-but-unlinked files. Reused
slots receive new serials. Mutable borrowed paths/contents expire after the
next successful transaction; copied listing entries remain valid values.

`/bundle` is rebuilt in RAM from trusted immutable ROM bytes after mount and is
excluded from the durable payload. Its nodes share the fixed node capacity.
Copying bundle resources into a private container persists the copied bytes.
The backend treats metadata as trusted labels; only the VFS authorizes access.
All calls require single-caller serialization. General concurrent filesystem
operations, journaling, disk encryption, hard links and symlinks are outside
this profile.

## Nullify: verified logical clearing

`nullify(path)!void` removes one mutable container file while clearing its
retained Bedrock records. The VFS authorizes the trusted current app's ownership
and rejects directories, bundles and foreign containers before calling the
backend. The backend also rejects nonfiles and immutable/system data.
Ordinary `unlink` is unchanged and does not promise erasure: its older bank may
still contain the previous file until another transaction replaces it.

Nullify preflights two strictly increasing generations before changing RAM or
issuing I/O. With two generations available, it:

1. Volatile-clears the historical RAM snapshot, stages the current tree without
   the target node, and clears all unused node/path/data tails.
2. Volatile-clears and rebuilds the other RAM snapshot from this sanitized tree.
   The complete target allocation is gone from both owned snapshots before I/O.
3. Reconstructs the full inactive bank: current surviving records, zero record
   tails, sector padding and every otherwise unused tail sector. Tail transfers
   use bounded 4 KiB batches.
4. Flushes that payload, writes and flushes its new CRC/generation header, then
   reads back the complete bank. Verification compares the exact expected
   header/payload/padding bytes and zero tail sectors, rather than accepting a
   merely self-consistent CRC.
5. Publishes that verified sanitized bank before reconstructing, flushing,
   committing and verifying the former active bank the same way.

Success means both complete 2 MiB banks are clean committed snapshots. Either
bank can be selected alone without resurrecting the target. Rewriting all
records and tails removes unreachable earlier versions, renamed paths, reused
slot contents and invalid old-bank remnants, instead of assuming the target
occupied the same slot in each bank. Other current files and their ownership are
preserved, including intentional copies containing the same bytes.

Any write, flush or readback error after sanitization begins poisons the live
instance. A byte mismatch returns `NullifyVerificationFailed`; subsequent calls
return `RemountRequired`. The caller must show failure and close descriptors and
borrowed views before fresh-mount recovery. It must not silently fall back to
ordinary delete or claim completed clearing. Interruption before the second
verified bank may leave old bytes in a previous bank even when recovery selects
a snapshot where the file is already absent. Failure therefore promises neither
complete erasure nor namespace rollback. Preflight failures leave RAM/media
unchanged; post-sanitization failures still clear the owned RAM snapshots.

This is a guarantee about the **current logical Bedrock image and its owned RAM
snapshots**, conditional on truthful device reads/writes and successful flushes.
It does not clear application previews, caller-held buffers, intentional copies
in other files, earlier host/VM snapshots, backups, driver/device caches or
physical storage inaccessible through the block interface. Readback can detect
ignored/incomplete logical writes; it cannot prove physical erasure or detect a
device that fabricates reads or lies about durability. The operation is not a
device sanitize command or a claim of NIST-certified purge.

[NIST SP 800-88 Rev. 2](https://csrc.nist.gov/pubs/sp/800/88/r2/final) explains that
flash spare cells and wear leveling prevent ordinary reads/writes from reaching
all locations where old data may remain. Device-specific purge or destruction,
and independent management of retained copies, require a separate design.

Native fake-device tests inspect all bytes in both banks and both RAM snapshots,
preserve other owners/copies, mount either bank alone, corrupt the latest header,
and verify atomic generation preflight. Failure coverage includes every payload
sector, first/middle/final identical tail batches, every header and flush in
both phases, all readback paths, uncertain failed flushes and silently ignored
writes. These tests never open a host disk or issue physical-device commands.

## Creating dedicated media

From the repository root:

```text
python tools/make-data-image.py path/to/bedrock-data.img
python tools/test-data-image.py
```

The formatter creates an ordinary file of exactly 4194304 bytes. Bank 0 holds
generation 1 and an empty root; bank 1 starts invalid. It uses Python's standard
library and never opens a host block device or mounts media. Existing files are
preserved unless `--force` is explicitly supplied. Non-force publication is an
atomic no-replacement hard link from a flushed sibling temporary file, so a
concurrent creator cannot be overwritten; a filesystem without hard-link
support fails explicitly. `--force` deliberately replaces the named image.
Optional `--nodes`, `--file-bytes` and `--path-bytes` are for matching bounded
test configurations, not runtime resizing.

The QEMU storage profile selects a separately attached disk with the trusted
`bedrock-data` serial. Interactive runs retain their data image. Acceptance
fixtures are separate disposable image files; the deterministic app-1
`note.txt` workload must not erase app-2 Files data.

Native verification covers all commit failure boundaries, fresh-instance
reopen, corruption fallback, valid-CRC malformed records, subtree operations,
no-wrap serials, namespace isolation and deleted-descriptor rejection. The
formatter has structural, device-path, explicit-overwrite and concurrent
publication tests. Cross-ISA real-device boot verification is recorded by the
root acceptance harness separately. The current Debug/ReleaseSafe results,
including abrupt QEMU termination and fresh-boot readback on all three ISAs,
are recorded in [storage and Files verification](storage-and-files-verification.md).
