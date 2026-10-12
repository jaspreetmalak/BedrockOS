# First bounded Unix I/O profile

Bedrock64 connects native processes to durable private files, generational file
descriptors, bounded pipes, path-based spawn and staged exec replacement. These
are the first Unix I/O mechanisms, not a complete POSIX implementation.
The implementation lives in [the durable backend](../filesystem/src/durable.zig),
[VFS](../kernel/src/core/vfs.zig), [pipes](../kernel/src/core/pipe.zig) and
[process runtime](../kernel/src/core/process_runtime.zig). The independent
[RAM backend](../filesystem/src/ramfs.zig) remains available for portable use and tests.

## Storage and authority

The kernel retains `DurableFs(32, 4096, 128)` in permanent storage. Its 32-node bound
includes the root and all directories and files; each mutable file has at most
4,096 bytes, and full backend paths have at most 128 bytes. A dedicated 4 MiB
data image persists mutable file bytes and directory records across reboot and
process exit; immutable bundle overlay nodes also consume the node capacity.
They are not physical-page allocations returned by process cleanup and are
not yet charged as app filesystem storage. App ID 1 belongs to acceptance
workloads; the protected Files client has stable app ID 2. Frame-owner IDs and
PIDs do not select persistent container identities.

Immutable kernel-embedded ELF artifacts are borrowed into app-owned read-only
`/bundle` nodes; their lengths are independent of mutable-file capacity. User
`/container` paths resolve inside the current trusted app identity's private
namespace. The kernel inserts that identity into the backend path; user text
cannot select another app's identity. Each descriptor operation rechecks node
domain, owner and requested rights. Executable loading additionally requires
an immutable borrowed bundle node marked executable. Mutable container bytes
cannot become executable through a path or metadata flag.

Canonical paths reject traversal and namespace-prefix confusion. Open checks
descriptor capacity before creating or truncating a file. Reads return short
counts or EOF; writes complete or fail, with zero-filled gaps. Truncation clears
removed bytes. Seek positions are nonnegative signed 64-bit values; rejected
seeks do not change the offset. Native `list`, `mkdir`, `copy`, `rename` and
`unlink` requests now use the same checked namespace. Copy and rename preflight
whole subtrees and refuse destination replacement. Rename preserves open-node
identities; deletion makes old descriptors fail even after slot reuse. Directory
deletion requires emptiness. Names are copied into bounded directory records;
the caller resets enumeration after a mutation.

Every mutable operation writes the inactive snapshot bank, flushes its payload,
writes its CRC/generation header, then flushes again before publishing the RAM
tree. Mount selects the highest fully valid bank and never formats a corrupt or
missing image. Any commit I/O error poisons the current backend. A failed final
write/flush can leave a complete old or complete new snapshot; recovery needs a
fresh mount after invalidating live descriptors and views. The
[persistent filesystem contract](persistent-filesystem.md) documents the format,
ordinary-file formatter and recovery assumptions.

## Descriptors and pipes

Each acceptance process has separate tables of eight file descriptors, eight pipe
descriptors and eight IPC/stdout handles. Tokens are process-local and
generational; closed tokens cannot identify replacement entries. All classes
share the app-tree handle budget of 64. `open`, `read`, `write`, `seek` and
`close` consume current-process authority. Path requests and transfers are
bounded to 128 and 256 bytes respectively, with user ranges checked before
copying or consuming data.

The protected desktop Files client has a separate eight-file-descriptor table.
Its memory and descriptors have fixed bounds; integrating its charges with the
shared app-tree budget remains future work.

Four kernel pipes each hold at most 256 copied bytes. They are nonblocking:
an empty pipe with live writers or a full pipe returns `Again`; an empty pipe
after its last writer closes returns EOF; writing after the last reader closes
returns `EPIPE`. Queued bytes can drain after writer closure. Final-reference
cleanup releases buffered-byte charges and the pipe object. Pipes are not
seekable. `dup` currently applies only to pipe descriptors and can preserve or
reduce rights. `spawn_pipe` explicitly grants one authorized writer to a
child-local descriptor; ordinary path spawn inherits no file or pipe handles.

## Path launch and exec

`spawn_path` resolves an approved immutable executable through the current
app's bundle. Legacy catalog spawn resolves into the same mounted bundle.
`exec` keeps PID, parent and trusted app profile while preparing a new zeroed
code/data/stack image and saved entry context. The first ELF layout still has
one RX page, one RW/NX data page and one RW/NX stack page with an unmapped guard.

Validation, allocation and fresh stdout issuance complete while the old image
remains usable. Failure rolls back the replacement and returns an error to that
image. Commit closes every old file, pipe and IPC/stdout handle except the
freshly issued stdout, publishes the new image, then destroys the old context,
tables and payload. Success enters the replacement and never returns to the
old syscall. Container data survives this descriptor cleanup.

The shared payload quota is 27 pages, allowing three transient replacement
frames in addition to eight three-page process images. PID, address-space and
context registries remain bounded to eight each. A full registry or handle
table may therefore make exec return safe `ENOMEM`; exec never frees the old
image first to manufacture room. Private table and permanent kernel/BSS
overhead remain separately bounded and are not fully app-accounted.

## Native Files integration

`userspace/apps/Files` is a separately compiled protected native executable.
Its two-pane AxisUI client calls checked file/namespace syscalls and receives
copied keyboard/pointer events. The kernel owns virtio device access, disk
mounting, window policy and bounded drawing; the client gets no framebuffer or
raw-disk pointer. It can create files/directories, copy or move by drag release,
rename, remove empty directories/files and open a copied read-only preview.
The Documents/Downloads seed is initialized only for a fresh app-2 container.
Acceptance app-1 writes must preserve that separate data.

This is one protected Files client with a privileged desktop host, not a
general user-space compositor or installed-app launcher. Its bounded desktop
ELF profile permits larger static code/data segments and a guarded stack; the
original process acceptance profile retains its one-page segment limits.
Native package checks cover durable recovery and VFS authority in Debug and
ReleaseSafe. Real storage, input and restart acceptance has passed for the
three named UEFI/QEMU profiles; the previous RAM-profile results below describe
the earlier in-memory implementation.

The durable storage and protected Files extension passed fresh native tests,
both boot matrices and actual disk/input workflows in Debug and ReleaseSafe.
See [storage and Files verification](storage-and-files-verification.md) for
commands, recovery evidence and current limits.

## Previous RAM-profile acceptance

The native I/O workload checks file bytes, gaps, EOF, rejected pointers and
rights, descriptor exhaustion/reuse, pipe `Again`/EOF/`EPIPE`, an explicitly
granted writer child, failed exec preservation and same-PID successful exec.
Kernel checks require file/pipe/exec proof markers and full transient-resource
cleanup. A startup probe fills all eight address-space/context slots, requires
a valid replacement to fail without changing the old PID, context, stdout or
resource counts, then releases the seven temporary children. Serial acceptance
requires `exec capacity rollback verified`, `filesystem I/O verified`,
`pipe lifecycle verified` and `filesystem exec replacement verified` in addition
to the existing isolation, scheduling, IPC and cleanup checks.

The preceding RAM-backed Unix I/O verification passed on 2026-10-11:

| Check | Result |
| --- | --- |
| Debug native tests and three-target compile checks | 96/96 build steps; cached results included |
| ReleaseSafe native tests and three-target compile checks | 96/96 build steps, 236/236 executed native checks |
| Debug boot matrix | 18/18 boots: nine UEFI native I/O workloads and nine reset regressions |
| ReleaseSafe boot matrix | 18/18 boots: nine UEFI native I/O workloads and nine reset regressions |
| ReleaseSafe x86-64 high placement | Passed with 4 GiB RAM and the kernel at physical `0x100000000` |
| Independent kernel package, Debug tests and checks | 39/39 build steps, 146/146 executed native checks |
| Normal UEFI GOP previews | All six passed: three architectures in Debug and ReleaseSafe |
| Debug and ReleaseSafe default builds and installation | Passed |

Each matrix covers all three architectures, with UEFI RAM sizes of 128, 256 and
512 MiB and reset RAM sizes of 64, 128 and 512 MiB. Together the two matrices
contain 18 native I/O workload boots and 18 reset regression boots. Executed
native-check totals include repeated imported tests; they are not counts of
unique test definitions. The six normal graphical checks passed pixel checks,
stayed alive and exited through QMP; the ARM64 capture was also inspected
visually. The Python body of the Unix boot runner additionally passed an ARM64
UEFI ReleaseSafe boot at 128 MiB using installed Python on Windows. This does
not establish a native Unix shell run. All results cover the named QEMU profiles;
physical hardware has not been validated. The local verification receipt is
`.zig-cache/unix-io-verification.json`.

Run these commands from the workspace root with the pinned Zig version, QEMU
and matching firmware images configured as described in the
[build instructions](../README.md):

```powershell
.\tools\zig.ps1 build test check -Doptimize=Debug --summary all
.\tools\zig.ps1 build test check -Doptimize=ReleaseSafe --summary all
.\tools\zig.ps1 build test-boot-matrix -Doptimize=Debug --summary all
.\tools\zig.ps1 build test-boot-matrix -Doptimize=ReleaseSafe --summary all
.\tools\zig.ps1 build test-uefi-x86_64 -Doptimize=ReleaseSafe -Dram-mib=4096 -Duefi-kernel-min=0x100000000 --summary all
.\tools\zig.ps1 build -Doptimize=Debug --summary all
.\tools\zig.ps1 build -Doptimize=ReleaseSafe --summary all
```

On Unix, substitute `./tools/zig.sh` for `.\tools\zig.ps1`. Earlier
[process/IPC results](native-processes.md) describe the preceding stage.

Fork, libc, general ELF layouts, a dynamic linker and complete POSIX remain
future work. File stat is an internal VFS operation rather than a general stat
syscall. Trusted installation, `.app` manifests, broker grants and separately
protected display/input services are also pending. The kernel currently hosts
window policy while the native Files client runs in its own address space.
