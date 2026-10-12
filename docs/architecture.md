# Bedrock workspace architecture

## Confirmed requirements

- Zig is the implementation language, with small architecture-specific assembly
  routines where CPU entry and exception handling require them.
- Use the latest stable compiler at setup, then pin the exact version: 0.17.0.
- x86-64 and ARM64 are required. RISC-V is required, using RV64 for the initial
  profile; RV32 is outside the initial profile.
- Bootloader, kernel, and filesystem code live in separate packages and can be
  built independently. A small fourth package defines their boot handoff.
- UEFI is the primary boot environment. Bedrock owns its loader and kernel;
  existing platform firmware supplies hardware initialization and image access.
- Use a Unix-style modular monolithic kernel and a private Bedrock64 syscall ABI,
  followed by POSIX source compatibility and a Hyprland-inspired, tiling-first
  desktop with keyboard controls, workspaces and native app bundles.
- Apps are sandboxed by default, without an app opt-out or root bypass.

Universal means a portable implementation with documented architecture and
platform ports. Each ISA has its own native code, executable format settings,
entry state, and board-specific startup paths. Supporting an ISA does not imply
that every board or peripheral using it is supported.

## Dependencies and ownership

| Package | Owns | Allowed dependencies |
| --- | --- | --- |
| `boot-protocol` | Versioned handoff records, layout and bounds checks | Zig language and portable library facilities |
| `bootloader` | Startup integration, image loading, boot policy, handoff construction | Boot protocol; portable filesystem when boot-file access is added |
| `filesystem` | Portable read/write/flush block interface, bounded RAM backend and durable snapshot format | Caller-supplied I/O, borrowed immutable images and explicit storage |
| `kernel` | Memory, execution, IPC, drivers, VFS authority, disk/input access and current desktop host | Boot protocol, filesystem, Bedrock64 ABI/embedded ELF artifacts and native UI/shell modules |
| `userspace` | Bedrock64 ABI/runtime, entry/linker and native init/service/fault/I/O/exec executables | Zig facilities and its own ABI; no kernel implementation imports |
| `frameworks/public/AxisUI` | App-facing native views, layout and software rendering | Zig facilities and explicit caller-supplied render targets |
| `userspace/apps/shell` | Desktop themes, workspace/status views and shell composition | Public AxisUI |
| `userspace/apps/Files` | Native two-pane model/view, file actions and protected executable entry | Public AxisUI and Bedrock64 runtime interfaces |

Neither executable imports the other's implementation. Filesystem code cannot
import kernel, bootloader, architecture, firmware, or device drivers. Common
records contain fixed-width values and physical addresses, not Zig pointers,
slices, allocators, or firmware-native structures.

The root `build.zig` orchestrates local packages; it owns no runtime OS code.
Tests live beside the portable implementation they verify. Bounded boot
acceptance runners live in `tools/`; the build supplies their emulator and
generated boot-image paths.

Native UI code is separate from kernel and firmware mechanisms. AxisUI is the
public app-facing framework. [`userspace/apps/shell`](../userspace/apps/shell/README.md) owns
the actual desktop composition, themes, workspace bar and view layout. Its Zig
module is `desktop_shell`, with compile-probe artifact `bedrock-desktop-shell`.
Neither imports bootloader, kernel or firmware code. `userspace/apps/` contains
application sources. `userspace/services/` is the future home for service
processes, such as display/compositor, input, launch and broker services; those
processes are not implemented yet. The shell still renders through the privileged
kernel desktop host; a separately compiled Files client now runs in a protected
user address space. Moving shell source alone does not create a user-space shell process.
The future shell application will communicate with protected services through
checked IPC. Source paths do not prescribe installed bundle or service paths.

`frameworks/private/` is reserved for reusable internal OS APIs and service
mechanisms, such as future display IPC clients, surface-handle operations and
internal broker interfaces. It currently contains no implemented private
framework package. Themes, bars and desktop views belong to `userspace/apps/shell`.
Public/private describes API support and distribution. Private address spaces
and checked capability/syscall rights enforce authority; directory placement
does not.

AxisUI borrows immutable text and child-view slices for a synchronous render.
`renderWithWorkspace` takes a caller-owned `Workspace` for bounded layout and
clipping scratch. The kernel's temporary preview bridge retains this storage in
BSS and calls `desktop_shell.renderWithWorkspace` to preserve its 64 KiB guarded
stack. The single-CPU caller serializes access. Surface mapping, memory ownership
and lifetime remain the caller's responsibilities; the native frameworks perform
no physical-memory allocation. Files uses a bounded command surface whose draw
requests are clipped to its kernel-issued client area; its user process has no
framebuffer pointer.

## Runtime layers

Within both executable packages:

- `src/core/`: portable policy and algorithms.
- `src/arch/<isa>/`: CPU modes, registers, traps, page translation, context
  switching, memory ordering, and cache operations.
- `src/platform/`: board resources, interrupt controllers, timers, CPU startup,
  reset, and the selected boot environment.

`kernel/src/drivers/virtio.zig` supplies bounded block and input transport;
`core/storage_runtime.zig` selects the dedicated `bedrock-data` device and
mounts the retained durable backend. The portable VFS maps `/container` and
`/bundle` to the trusted current app's namespace and rechecks node provenance
and descriptor rights. Disk access is never delegated as a raw user pointer.
`kernel/src/security/` owns portable app-authority policy and generational handle
tables; memory and startup algorithms remain in `src/core/`. The current
user-mode probe dispatcher checks this policy and the running task's handles;
the native process runtime and VFS also consume these enforcement boundaries.
Loader and kernel architecture code remain local because their execution
environments and lifetimes differ.

Kernel platform entry points validate their trusted handoff bounds and CPU
state, install exception handling and select the console. They then call
`core/memory_init.zig` for the shared memory report, allocator initialization and
RAM workload. `core/physical_memory.zig` owns bounded extent planning and bitmap
bookkeeping; `arch/physical_memory.zig` supplies physical access, address limits
and memory ordering. The allocator has no firmware, device-driver or bootloader
dependency. Its caller supplies the bitmap storage, which startup reserves from
accessible usable RAM. See [memory management](memory-management.md).

Portable interfaces must describe page geometry, mapping permissions, TLB
invalidation, monotonic time, interrupt sources, CPU lifecycle, and user-memory
access explicitly. CPU physical addresses, virtual addresses, and DMA addresses
are distinct concepts. No portable subsystem may assume x86 memory ordering.

## Startup boundary

Bedrock's primary path starts as its own UEFI application on x86-64, ARM64 or
RV64. Existing firmware initializes platform hardware and RAM and loads the
application. The Bedrock loader gathers those resources, allocates loader pages
and loads a separately compiled ELF64 static PIE kernel into firmware-selected
memory, applying bounded relative relocations. Each loader embeds the opaque
kernel image and never imports kernel source. Physical ports begin with working
UEFI firmware; early board initialization remains the platform's responsibility.

The UEFI adapters retain hardware descriptions and the final EFI memory map,
exit boot services, then establish the architecture's CPU state. Normal output uses GOP
when available or a described supported UART on ARM64/RV64.
x86-64 builds sparse identity mappings with firmware cache attributes and
explicit accessible ranges, including addresses above 4 GiB. ARM64 enters
EL1h with translation/caching disabled; RV64 enters S mode with bare translation
and retains the machine-mode firmware's access permissions. These paths still
have bounded resources and firmware/device requirements. See the
[x86-64](x86_64-uefi.md) and [ARM64/RV64](arm64-riscv64-uefi.md) UEFI contracts.

The direct-reset QEMU profiles remain reference and regression targets. ARM64
and x86-64 use Bedrock-owned ROM/flash code entered from the emulated reset
vector. RV64 uses QEMU's small reset ROM to enter Bedrock-owned M-mode code,
with no OpenSBI/SBI dependency. QEMU provides initialized RAM. These fixed
platform contracts are documented for [ARM64](arm64-qemu.md),
[x86-64](x86_64-qemu.md), and [RV64](riscv64-qemu.md).

The common handoff carries a sorted bounded memory-region map, a typed console,
CPU entry state, boot environment and optional firmware descriptions. UEFI
loaders derive memory ownership from the final EFI map. ARM64/RV64 use a bounded
Devicetree parser for static reservations and serial console properties; their
reset references also discover RAM banks through it. The reset PC path discovers
QEMU RAM and E820 records through fw_cfg; that adapter remains QEMU-specific.
Hardware descriptions identify resources; they still require corresponding
operating drivers.

Memory ownership and addressability are separate handoff properties. Only
normalized usable regions may supply kernel frames, and each frame must also be
fully accessible under the current CPU state. The allocator copies the eligible
extents, excludes page zero and keeps its bitmap reservation for its lifetime.
Loader and firmware reservations remain reserved; reclaiming them needs a later
ownership transition. Current allocator calls require caller serialization on
the single active CPU. UEFI startup subsequently installs kernel-owned protected
tables and enters protected user-mode tasks. Hardware timers interrupt two
non-yielding tasks, whose saved contexts are selected by the shared round-robin
policy. Kernel mutations remain serialized with interrupts masked; see
[preemptive scheduling](preemptive-scheduling.md).

## Kernel and application model

Bedrock adopts a Unix-style modular monolithic kernel. The first native profile
has private process address spaces, one user thread, guarded user stacks and
descriptor tables; single-CPU kernel entry uses owned shared trap/continuation
stacks. Pipes and spawn/exec/wait/exit form the initial process model.
The private Bedrock64 syscall ABI comes first; a later POSIX layer targets source
compatibility. Existing Unix executables, external platform APIs and POSIX
certification are outside the claim.

A trusted launcher issues app identity separately from UID and PID. App
authority defaults to a private read/write container, read-only bundle and
explicit shared runtime. Manifest requests are intersected with trusted grants.
Broker and file-picker grants identify objects through handles; a path prefix
does not confer authority. Children and copied or duplicated handles cannot gain
rights, and the kernel rechecks authority when handles are used. Root credentials
do not bypass an app's sandbox.

The Hyprland-inspired desktop uses tiling, keyboard-driven focus and workspaces
as its intended interaction model, with optional floating windows, gaps, rounded
focused borders and a compact bar. Native AxisUI is implemented from scratch in
Zig: `View`, `Text`, `HStack`, `VStack`, `ZStack`, `Spacer` and modifiers compose
layout for a software framebuffer renderer. `userspace/apps/shell` composes the
desktop with these public primitives and owns its theme, workspace bar and tiled
views.

Normal UEFI GOP paths render the shell background and launch the protected native
Files executable after the process/isolation checks. Virtio keyboard and pointer
input feeds bounded events; the kernel currently owns window layout, focus,
dragging and drawing bounds. Files renders its own AxisUI client through checked
commands and manipulates only its app-2 container via VFS syscalls. Its data uses
the dedicated 4 MiB two-bank snapshot image, with ROM bundles rebuilt as an
immutable overlay. See [persistent storage](persistent-filesystem.md) and
[Unix I/O](unix-io.md) for current limits and acceptance scope.

Startup failures stop before the desktop, and renderer/client failures report
through the diagnostic console. Serial smoke runs retain acceptance output;
normal boot-log retention and a diagnostic viewport remain future work.
Protected user-space display/compositor and input services, general app launch,
event-driven state bindings/reconciliation and multi-client surfaces are next.
Desktop launch/layout policy ultimately belongs to the protected shell application
and supporting services, with explicit object grants at each boundary.
GPU acceleration, animation, blur,
AxisCore and additional native service frameworks remain future work. Bedrock does not claim a Hyprland
port or external compositor/API compatibility.

Native `.app` bundles contain a manifest, resources and architecture-specific
ELF executables. See the [application model](application-model.md) for the process
and authority contract, and [desktop design](desktop-design.md) for the visual
direction and runtime stages.
Portable security policy, handle bookkeeping and resource budgets are implemented
foundations. UEFI boot images now exercise private user address spaces, safe
syscall dispatch, fault containment, user-mode timer preemption, bounded native
process loading and app-scoped durable VFS operations. Trusted installation,
general app/service loading and brokered resources remain future work; the full
app sandbox claim still depends on those boundaries. See
[protected userspace](protected-userspace.md). Independent build packages remain implementation boundaries; they
do not imply separate runtime processes.

## Build foundation

The root build uses baseline `x86_64-freestanding-none`,
`aarch64-freestanding-none`, and `riscv64-freestanding-none` targets. Static probe
libraries force analysis and code generation of actual component interfaces.
The probe libraries are independent of the boot images. Runtime targets use
explicit platform linker layouts: Cortex-A57 plus strict alignment for ARM64,
baseline x86-64/SSE2, and integer-only RV64IMAC plus Zicsr/Zifencei. The root
build links fixed reset kernels to raw bytes and relocatable UEFI kernels to
ELF images, supplying opaque anonymous image imports to their loaders. The
default `zig build` compiles the component probes and all three UEFI applications.
`uefi` builds the UEFI set, and `test-uefi` runs its bounded emulator acceptance
checks. `images` builds all three reset pairs and all three UEFI applications;
`test-boot` checks both sets. Individual reset steps remain available for
reference work. A host Python converter preserves the RV64 loader's ELF section
addresses and translates relative relocations to PE DIR64 records because Zig
0.17 lacks native RV64 COFF emission.
The optional `uefi-image-x86_64` step packages a GPT/FAT32 disk image,
and `test-uefi-image-x86_64` checks its format and boots it through OVMF. Package
runtime dependencies retain the direction shown above.
