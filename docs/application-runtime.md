# Installed applications and persistent init

The installed application path starts with ordinary native ELF files on the
UEFI system partition. The bootloader reads one bounded archive from
`EFI/Bedrock/Apps/apps.bap` while firmware file services are still available.
The kernel mounts each validated entry under that application's own read-only
`/bundle` namespace. Mutable container files never gain executable authority.

The three initial identities are `org.bedrock.init` (101),
`org.bedrock.observer` (102), and `org.bedrock.worker` (103). Each has an entry at
`/bundle/main.elf`; these paths resolve to separate app-owned VFS namespaces.
The package catalogue contains identities and entry paths. The kernel's trusted
launch catalogue supplies permissions, launch relationships and memory limits.
Archive metadata cannot request extra permissions or choose an address-space
layout. Applications do not supply their own effective sandbox identity.

## Booting the runtime

The installed runtime has a dedicated headless UEFI profile. It uses serial
QEMU output and keeps the existing native Files desktop on its own profile.
The production and acceptance profiles load the same installed application
bytes from `apps.bap`; neither has an embedded application fallback. Missing
installed code therefore fails this profile rather than selecting a fixture.

```powershell
zig build app-runtime -j1
zig build app-runtime-x86_64 -j1
zig build app-runtime-arm64 -j1
zig build app-runtime-riscv64 -j1
zig build run-apps-x86_64 -j1
zig build run-apps-arm64 -j1
zig build run-apps-riscv64 -j1
zig build test-apps -j1
zig build test-apps -Doptimize=ReleaseSafe -j1
```

`app-runtime` packages the three loaders and installed-app archives into bootable
media. `run-apps-*` boots the selected persistent supervisor with a retained
container disk; Ctrl+C stops QEMU. These commands operate on ordinary image
files. They do not install to a host disk or establish physical hardware support.
`test-apps` boots the acceptance media and verifies independent app identities,
contained faults, repeated worker cleanup and final teardown on all three
reference machines. Its bounded host runner also checks that production media
keep running after the supervision milestone. Test runs use isolated disk files.

The kernel acceptance flag is the difference between the two runtime profiles.
It appears in the immutable startup record so the same native init performs
three crash/restart cycles in acceptance and one in the production demonstration.
Both then retain Observer and a persistent Worker. Production init continues
waiting and restarting a failed Worker after backoff. Only the acceptance kernel
performs controlled teardown after checking its own lifecycle counters.

## Processes, startup and sandbox boundaries

Only trusted init has `app_launch` approval. `spawn_app` takes a trusted numeric
package ID, a numeric launch argument and an optional already-authorized pipe
writer. The kernel selects the target profile and private namespace, and
attenuates that transferred descriptor to its writer right. Observer and Worker
cannot launch another package or acquire launch permission from an argument.
The old `spawn`, `spawn_path` and `spawn_pipe` interfaces remain fixture APIs
and return `not_supported` in the installed profile. `exec` can replace a
process only with executable code from its own read-only bundle, retaining its
PID, parent and sandbox identity while closing old descriptors and replacing
the complete image, startup record and heap. It cannot change app identity.

Each installed process receives a version-1, 1112-byte startup record on its own
RO/NX page. It records trusted identity and entry arguments, up to eight bounded
arguments and eight environment entries, and the actual mapped heap lease.
The current catalogue supplies the canonical package name as argument zero and
`BEDROCK_ROLE` in the environment. The SDK validates all sizes, bounds, flags,
reserved fields and entry-register consistency before accessing the heap.

The trusted catalogue permits up to 128 KiB RX code/read-only content and
128 KiB RW/NX data, a guarded 16 KiB stack and a 32 KiB preallocated zeroed
RW/NX heap. Native ELF inputs cannot map the startup page or heap themselves.
The userspace allocator supports alignment, free/reuse and resizing with at
most 64 live allocations. It can return `OutOfMemory` without modifying
existing allocations. There is no heap growth, demand paging, dynamic linker
or POSIX binary ABI in this revision.

Observer opens its private `/container/session.txt`, holds a heap allocation
and writes pipe heartbeats with its original PID and increasing sequence.
Init waits for the first heartbeat before launching Worker so Observer has
completed its file/heap initialization. Worker uses the same virtual file path
in its independent container. Its faulting generation writes `FAULTED`, leaves
a descriptor and allocation live, then attempts an architectural store into
the protected startup page. The kernel retires that process with status 139;
the next generation sees retained private file content with fresh zeroed BSS
and heap, then closes/frees its resources and exits 23. Observer keeps checking
its own `OBSERVER` file throughout these worker generations.

The kernel charges actual process payload pages and descriptors, bounds global
process/handle/pipe queues and reclaims contexts, address spaces and owned frames
on retirement. Shared archive pages stay reserved for VFS borrows. Default app
profiles deny launcher/system requests, network creation, bundle writes and
foreign namespaces. These applications also execute those denial checks.
Moving the GUI host into protected services, general package management and
dynamic paging remain subsequent milestones. See the [runtime SDK](../userspace/runtime/README.md).

## Package and boot ownership

[`package-apps.py`](../tools/package-apps.py) creates the deterministic archive
from the catalogue at
[`installed-apps.json`](../userspace/runtime/installed-apps.json). All inputs and
outputs are ordinary files. It rejects extra or missing application inputs,
wrong-architecture executables, ambiguous paths, duplicate identities and
unbounded files. For example, after building the three native artifacts:

```powershell
python tools/package-apps.py --arch x86_64 --output apps.bap `
  --app org.bedrock.init=init.elf `
  --app org.bedrock.observer=observer.elf `
  --app org.bedrock.worker=worker.elf
python tools/package-apps.py --arch x86_64 --verify apps.bap
python tools/make-uefi-image.py boot.efi installed.img --arch x86_64 --apps apps.bap
python tools/test-uefi-image.py boot.efi installed.img --arch x86_64 --apps apps.bap
```

`aarch64` (also `arm64`) and `riscv64` select their respective ELF machines.
UEFI image packaging uses `arm64` for the ARM removable-media boot filename.
Its optional `--apps` input is checked again before creating an `Apps` directory;
the independent FAT reader verifies the complete stored archive byte for byte.
Media without `--apps` retain their existing layout.
Packaging checks the static ELF64 header; the kernel's executable loader must
also check the complete ELF mappings and the selected trusted memory profile
before launching an entry. This is an installation archive for the current
bounded runtime, rather than a dynamic linker or a general package manager.

[`app_assets.zig`](../bootloader/src/platform/uefi/app_assets.zig) opens only the
loaded boot image's own filesystem. A missing archive returns no installed
application handoff. A present invalid archive is rejected; it is never partially
published. Reads have an explicit call budget and must reach exact EOF. The
loader allocates separate page-aligned memory, initializes its padding to zero,
checks the complete archive and closes its file before publishing `AppBoot`.
Failures before publication release that allocation. Loader failures before the
first ExitBootServices attempt may release a successfully staged archive too.

The boot handoff identifies the entire retained reservation, its exact archive
extent and the SHA-256 of those bytes. The kernel reserves the allocation and
maps its source pages read-only and non-executable, with no user access. The VFS
borrows entry bytes for the boot lifetime. Process creation copies accepted ELF
segments into separately owned user pages; process exit reclaims those pages,
not the shared installed archive. The archive allocation remains retained while
its VFS borrows are live. No unmount or replacement operation is exposed to apps.

SHA-256 identifies corruption in the table, individual executables and the boot
handoff. It is not an application signature. The firmware partition and installer
remain trusted code sources, like the bootloader and kernel themselves; this
revision does not implement signed packages or authenticated updates.

## Archive format version 1

[`bundle_archive.zig`](../userspace/runtime/src/bundle_archive.zig) supplies the
allocation-free parser used by the bootloader and kernel. Integers are
little-endian, strings are ASCII terminated with zero, and every byte after a
string's terminator is zero. At most eight executable entries fit within a
16 MiB archive; each executable is between 64 bytes and 2 MiB. Each app has one
executable entry in this first format.

| Header offset | Bytes | Field |
|---|---:|---|
| 0 | 8 | `BEDAPP01` |
| 8 | 2 | Version `1` |
| 10 | 2 | ELF machine: x86-64 `62`, ARM64 `183`, RV64 `243` |
| 12 | 4 | Header size `64` |
| 16 | 4 | Record size `160` |
| 20 | 4 | Entry count, `1..8` |
| 24 | 8 | Exact archive file length |
| 32 | 32 | SHA-256 of all records |

| Record offset | Bytes | Field |
|---|---:|---|
| 0 | 8 | Nonzero installation app ID |
| 8 | 4 | Application version `1` |
| 12 | 4 | Executable-entry flag `1`; no other flags |
| 16 | 32 | Reverse-DNS identity |
| 48 | 64 | Canonical `/bundle/*.elf` path |
| 112 | 8 | Executable offset in the archive |
| 120 | 8 | Exact executable length |
| 128 | 32 | SHA-256 of the executable |

Records follow the header immediately. Each record's executable starts at the
next 16-byte boundary after the preceding extent, in record order. Padding is
zero, extents do not overlap, and the last executable reaches exact file EOF.
Different app IDs may use the same scoped path. Duplicate numeric IDs or names
are rejected. No pointers, permission masks, native Zig slices or kernel handles
appear in the file.

## Focused verification

`tools/test-app-packages.py` exercises all architecture tags, deterministic
output, catalogue bounds, traversal rejection, duplicate/unknown metadata,
input-set matching, ELF/header mismatches, hashes, padding, extent bounds and
the ordinary-file CLI. The archive parser's native tests reject table/file
corruption, overlaps and malformed identities. The EFI provider model verifies
exact reads, file closure, zeroed padding, absence handling and reclamation after
corruption, truncation, close failures, architecture mismatch or address-limit
rejection. `app_assets_compile_check.zig` forces the complete real EFI path
through the x86-64, ARM64 and RV64 compilers.

These focused checks verify installation bytes and their ownership. The complete
runtime gates also boot the installed init and two separately sandboxed
applications, observe crash/relaunch isolation, and check process-resource
reclamation on all three architectures. The
[verification record](application-runtime-verification.md) describes the
Debug/ReleaseSafe acceptance, persistent and missing-archive results.
