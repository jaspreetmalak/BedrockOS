# Bedrock kernel

Independent Zig package for memory management, scheduling, processes, IPC,
hardware drivers, and filesystem integration. It imports the boot protocol and
portable filesystem package; it never imports bootloader implementation code.

The chosen model is a Unix-style modular monolithic kernel. Native ELF processes
now have private address spaces and one saved user context, with spawn/wait/exit,
yield/sleep and bounded IPC through Bedrock64. The first Unix I/O profile adds
app-scoped file descriptors, nonblocking pipes, path spawn and safe same-PID
exec replacement. The current extension mounts a bounded durable backend and
runs a protected native Files client through checked drawing/input syscalls.
A later POSIX layer targets source compatibility. Apps have trusted
launcher-issued identities separately from UID/PID and mandatory sandboxes
without root bypass. See the [application model](../docs/application-model.md).

The networking extension hosts private NetworkCore and a modern VirtIO-net
driver on the named QEMU UEFI profiles. Checked connected-UDP syscalls require
`network_client` approval and per-process socket grants. Packet/endpoint bounds,
generation checks, peer filtering and cleanup remain kernel-owned; public
NetworkKit clients receive no frame, device or DMA grant. NIC absence leaves
other OS features usable. This initial static IPv4 profile does not supply TCP,
TLS, DNS, DHCP, an operational physical Wi-Fi backend or a standalone network service. See the
[network framework](../docs/network-framework.md).

`src/core/` holds portable kernel code. `src/arch/` owns CPU mechanisms;
`src/platform/` owns board mechanisms; `src/drivers/` holds device drivers;
`src/storage/` adapts kernel device access to the filesystem interface.
`src/security/` owns portable app policy, generational handle tables and resource
budget bookkeeping.

```text
src/core/memory.zig          discovered-memory summaries and page enumeration
src/core/physical_memory.zig bounded layout planning and bitmap frame allocator
src/core/memory_init.zig     shared allocator startup, zeroing and RAM checks
src/core/owned_frames.zig    bounded ownership ledgers and allocation tickets
src/core/kernel_heap.zig     page-backed kernel allocation and checked release
src/core/user_elf.zig        validated bounded ELF64 executable inspection
src/core/process.zig         PID generations, lifecycle, scheduling and blocking policy
src/core/ipc.zig             bounded FIFO mailbox identities and copied messages
src/core/vfs.zig             app-owned bundle/container resolution and file descriptors
src/core/pipe.zig            bounded pipe bytes and attenuated descriptor references
src/core/process_runtime.zig native image ownership and syscall/IPC/I/O integration
src/core/storage_runtime.zig modern VirtIO discovery and retained durable VFS
src/core/desktop_runtime.zig protected Files host, input routing and clipped drawing
src/arch/physical_memory.zig CPU address limits, physical access and ordering
src/arch/<isa>/              entry assembly and exception machinery
src/platform/<board>/       trusted handoff checks and console selection
src/security/               app authority and checked object-handle foundations
src/drivers/desktop_preview.zig validated framebuffer adapter to the desktop shell
src/drivers/pci/            bounded read-only inventory, BAR decoding, legacy/verified ECAM access
src/drivers/wifi/           chipset protocol ports, owned MT7922 transport and shared 802.11/WPA2
```

The [Wi-Fi translation layer](../docs/wifi-driver-porting.md) is independent of
the public NetworkKit control API. Its MediaTek, Intel and Realtek directories
retain their pinned upstream notices; shared IEEE protocol code is original.
The MT7922 transport owns in-place DMA leases and real polling ring callbacks,
checks intact firmware hashes, retains exposed storage after failed stop and
never treats firmware readiness as a connection. Clock/coherency/resource policy,
NIC calibration, regulatory/MAC setup and a complete radio data backend remain
required. Normal kernel startup only inventories x86-64 PCI and leaves Wi-Fi
unavailable. ARM64/RV64 ECAM must come from verified platform description.
Kernel `zig build test check` includes native driver tests and complete compile
probes; the workspace additionally checks all three PIC targets.

This package validates the handoff and provides CPU startup, exception handling,
and polling consoles for ARM64, x86-64 and RV64 QEMU references. Each also
accepts a dynamically placed UEFI PIE image and its explicit accessible ranges.
Normal UEFI output uses the described framebuffer or supported ARM64/RV64 UART;
after successful kernel checks, a graphical boot renders the native AxisUI
shell and enters a separately linked protected Files ELF. A temporary kernel
host owns scanout, modern VirtIO input and the single window's focus, title drag
and minimize/reopen policy. The app receives bounded events and checked drawing
syscalls, with no physical framebuffer or raw block-device access. Rendering errors restore
the text console and report the failure. Smoke boots keep their diagnostic output.
The RV64 firmware variant has its own S-mode trap path.
Shared memory initialization uses discovered ownership and accessible ranges to
plan a bitmap allocator over complete 4 KiB frames. Its metadata occupies a
permanent reservation in accessible usable RAM. Single-frame and aligned
contiguous allocations support checked release; the shared zeroing helper clears
a frame before returning it. Callers must serialize allocator access until
interrupt and SMP synchronization exists. See the
[memory-management contract](../docs/memory-management.md) for APIs and limits.

The `arm64_kernel`, `x86_64_kernel`, and `riscv64_kernel` modules are linked as separate
executables by the workspace. They check the loader record and BSS, report memory,
run the shared allocation, RAM integrity and reuse checks, handle deliberate
breakpoints and, on UEFI, run user-mode isolation and saved-context timer
preemption checks, then destroy the owned fixtures and execute native init's
process/IPC/file/pipe/exec workload before starting the protected desktop client
on normal graphical boots. Files uses a distinct bounded larger ELF layout;
the earlier acceptance executables retain their one-page code/data/stack layout.
Architecture and platform startup retain trusted pointer, CPU-mode and trap checks.
The reference device path polls modern VirtIO block and keyboard/tablet queues.
Arbitrary ELF/app-bundle loading, general filesystems, device-interrupt handling,
standalone compositor services, POSIX interfaces and SMP remain future milestones.
The [persistent Files/input verification](../docs/storage-and-files-verification.md)
passed Debug/ReleaseSafe native checks, both boot matrices and six two-boot
desktop workflows across the three UEFI references. `src/compile_check.zig`
continues to verify the portable interface for all three architectures.

The bounded page-backed kernel heap returns owned tickets and clears allocated
pages before use. Fixture owners retain code/data/stack frames; architecture
ledgers separately own private page tables and roll back partial construction.
Cleanup destroys contexts before mappings, invalidates translations before
table reuse, then releases payload frames, test handles and resource charges.
Generational references reject stale context and address-space reuse; active
records and spaces with live contexts cannot be destroyed. Shared kernel tables,
trap stacks and allocator metadata remain permanently owned. Each fixture's
three-frame/one-handle/one-process charge is released, while table and other
kernel overhead are not yet fully app-accounted. See
[resource lifecycle](../docs/resource-lifecycle.md) for APIs and limits.

Portable security foundations implement app-grant policy, generational handles
and resource accounting. The earlier foundation stage passed its native tests
in Debug and ReleaseSafe; compile probes cover all three ISAs.
UEFI kernels have private user address spaces, protected kernel mappings,
checked syscall probes and contained fault tests. The native ELF catalog,
process lifecycle, IPC and VFS now consume the same policy. Bundle/container
operations recheck current app ownership and rights; the complete sandbox still
requires installation, trusted brokers and broader object services.
Future process and object operations must consume this policy and recheck rights.
See [native processes](../docs/native-processes.md) for APIs and current limits.
The [Unix I/O contract](../docs/unix-io.md) records the preceding RAMFS stage,
separate descriptor tables, pipe behavior, safe exec staging and remaining scope.
The [durable filesystem contract](../docs/persistent-filesystem.md) records
32-node/4,096-byte files, two CRC-protected disk banks and uncertain-I/O recovery.
Its two RAM snapshots reside in permanent BSS; immutable ELF overlays remain
borrowed. Files carries trusted app identity 2 and cannot choose another app's
container. Window policy has a reusable module under userspace/services, but the
kernel currently executes it. Standalone compositor, launcher and broker services
remain later userspace work.

From this directory:

```powershell
zig build check -Dtarget=riscv64-freestanding-none
zig build test
```

See the workspace README for the pinned Zig toolchain and all three targets.
