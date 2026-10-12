# Bedrock

A Zig workspace for a bare-metal OS and bootloader targeting x86-64, ARM64
(AArch64), and RISC-V 64. The bootloader, kernel, filesystem, and boot protocol
are independent local packages, alongside Bedrock's native UI frameworks and
user-space application sources.

UEFI is the primary boot path on all three architectures. Existing platform
firmware initializes hardware and launches Bedrock's own Zig bootloader. The
loader exits boot services and enters Bedrock's own kernel, which runs directly
on hardware. The reset loaders remain QEMU reference targets for early startup
and architecture debugging.

The OS direction is a Unix-style modular monolithic kernel with a private
Bedrock64 syscall ABI, later POSIX source compatibility and a Hyprland-inspired
desktop built from user-space services: tiling first, keyboard controls,
workspaces and optional floating windows. Apps will use native `.app` bundles and mandatory
sandboxes: private containers, read-only bundles, explicit runtime access and
brokered object grants. There is no app opt-out or root bypass. See the
[application model](docs/application-model.md) for the design and acceptance rules.
The UEFI kernels now run user-mode isolation probes and timer-preempted tasks
with private address spaces, protected kernel mappings and checked syscall entry,
then load separately linked native Zig ELF programs. Bedrock64 now provides
init, spawn/exit/wait, yield/sleep and bounded capability IPC with real blocking
and wakeup. The first Unix I/O profile adds app-scoped files, nonblocking
pipes, path-based spawn and same-PID exec replacement. The current desktop
extension adds a bounded durable filesystem and a separately linked protected
Files ELF with its own larger executable layout. Full app installation and
general executable layouts remain future work. See
[native processes and IPC](docs/native-processes.md) and [Unix I/O](docs/unix-io.md).
Owned fixtures now release their payload frames, private tables, saved contexts
and test grants; complete app sandboxes still require those later mechanisms. See
[protected userspace](docs/protected-userspace.md) and
[preemptive scheduling](docs/preemptive-scheduling.md), with ownership rules in
[resource lifecycle](docs/resource-lifecycle.md).

The public [AxisUI framework](frameworks/public/AxisUI/README.md) is written from
scratch in Zig: declarative native views, stack layout, modifiers, clipping and
software rendering. The [desktop shell](userspace/apps/shell/README.md) composes
Bedrock's Hyprland-inspired desktop through those public APIs. Reusable internal
OS APIs belong in [private frameworks](frameworks/private/README.md); the desktop's
views and theme belong in its own application package. Normal UEFI graphical
boots start the native [Files client](userspace/apps/files/README.md) after the
kernel checks. Files opens with one file list and a Home/Documents/Downloads
sidebar, bounded Back/Forward history and an optional Split view. Its clean
header contains navigation, breadcrumb, Split and More; native right-click and
More menus provide file actions. Copy/Cut/Paste,
double-click open, file/folder creation, rename/delete and drag-and-drop use its
checked private namespace. Name editing offers mouse Save/Create/Cancel;
file preview remains read-only. The native mixed-case bitmap font and compact
charcoal/rose launch bar keep the desktop restrained. AxisUI's native frosted
materials tint an immutable blurred wallpaper cache behind Files and the bar;
labels, selections and window controls retain sharp edges. See
[frosted materials](docs/frosted-materials.md) for the rendering contract.
The distinct Nullify menu command immediately overwrites/deletes a writable
private file through checked authority. It verifies both complete logical
storage banks and reports its Bedrock-only scope; remapped SSD cells, backups
and independent copies are outside that guarantee. See
[context menus and Nullify](docs/context-menus-and-nullify.md).
Files runs in user mode without a framebuffer or raw disk grant. The kernel host
currently handles modern VirtIO input, clipped drawing, title dragging and the
single window's close, minimize, maximize/restore and fullscreen policy. F11
toggles fullscreen, Escape exits it and Alt+F4 closes the focused client.
Minimize retains the client; close reclaims its descriptors, context, mappings
and owned frames. The Files launch chip or Super+E starts a fresh client over
the same persisted app-2 data. A standalone user-space compositor,
multiple app windows, animation and GPU rendering follow.
See the [desktop design](docs/desktop-design.md) and
[framework boundaries](frameworks/README.md).

The public [NetworkKit](frameworks/public/NetworkKit/README.md) provides a
native connected UDP API with IPv4 endpoints, explicit lifetime and bounded
256-byte datagrams. The runtime adapter uses checked socket syscalls, while
private [NetworkCore](frameworks/private/NetworkCore/README.md) supplies trusted
Ethernet/ARP/IPv4/UDP mechanisms behind a VirtIO NIC. A separately linked
protected probe exercises echo, authority and exit cleanup. The preceding
network milestone passed independent package checks and integrated acceptance
in both modes: six real network boots
verified twelve nonempty/six empty datagrams, rejected twenty-four malformed or
wrong-tuple frames and reclaimed live sockets at exit. Root Debug/ReleaseSafe
runs each passed 213/213 steps, and default installation passed 139/139. The same
runs passed all six Files regression workflows with its network permission
denied. Normal runs remain offline; `zig build run-uefi-arm64 -Dnetwork=true`
(or either other architecture) explicitly attaches a NIC without changing app
rights. TCP, TLS, DNS, DHCP, IPv6 and a standalone network service remain
future work. Those results are recorded in `.zig-cache/network-verification.json`
and the
[network framework](docs/network-framework.md).

NetworkKit also exposes native Wi-Fi status, scan, join and enable/disable
controls through a supplied provider. NetworkCore supplies the bounded controller;
the runtime checks separate observation/control permissions and canonical wire
records. Dedicated protected tests use an explicitly simulated radio or the
production unavailable-radio path. Normal kernels report Wi-Fi unavailable:
no physical adapter has an operational, qualified backend. The known
Wi-Fi acceptance image has a trusted allowance of up to four code pages, one data
page and four stack pages; other fixture profiles retain their existing bounds.
See the [Wi-Fi control foundation](docs/wifi-framework.md).

The Wi-Fi milestone passed **269/269 aggregate build steps** in both Debug and
ReleaseSafe; default Debug build/install passed **202/202**. All twelve protected
Wi-Fi boots passed, split equally between simulated and production unavailable
variants across the three architectures and two modes. Component native suites
passed 27 NetworkKit, 23 NetworkCore, 10 Wi-Fi broker and 7 wire-decoder cases per
mode, with six PIC probes each for NetworkKit and NetworkCore. The same runs
passed six UDP boots and six Files workflows: twelve desktop boots, twenty-four
client starts and twelve checked closes. Receipts and hashes are checked in
`.zig-cache/wifi-verification.json`. These aggregates include cached unchanged
checks; physical radio/WPA authentication tests total zero.

```text
zig build test check test-uefi test-network test-wifi test-desktop -j2 --summary all
zig build test check test-uefi test-network test-wifi test-desktop -Doptimize=ReleaseSafe -j2 --summary all
```

Selected Linux Wi-Fi protocols now have native Zig ports under
`kernel/src/drivers/wifi/`, with pinned source provenance and retained licenses.
The MediaTek MT7922 subset includes reset, owned polling DMA, validated firmware
download, packet and scan-command codecs. Intel and Realtek subsets provide
targeted PCI identification and firmware inspection, plus Realtek H2C framing.
Shared original 802.11/WPA2 code covers discovery, authentication/association
frames and a bounded CCMP four-way handshake with GTK unwrap and install-once
retransmissions. Read-only x86-64 PCI discovery is connected to kernel startup;
ARM64/RV64 require a verified platform ECAM resource before PCI discovery.
The firmware transport requires explicit clock, DMA mapping/cache maintenance
and firmware inputs. These ports do not yet form an operational Wi-Fi backend.
See [driver translation scope](docs/wifi-driver-porting.md) for implemented
interfaces, verification and remaining physical-radio gates.

The [regulatory layer](docs/wifi-regulatory.md) adds a pinned native database of
182 countries/1,016 rules, conservative channel/power decisions, stable device
policy snapshots and real MediaTek CLC/domain/rate-power commands. It defaults
to passive world policy and requires actual board calibration inputs. Firmware
submission and physical enforcement remain distinct; normal Wi-Fi is unavailable.

`zig build test-wifi-drivers` runs the native driver/protocol suite. Workspace
`check` compiles the complete port probes, including PIC, on all three targets.
`zig build test-wifi-firmware` optionally checks explicitly supplied local
firmware references; without file options it skips and fetches nothing.

## Toolchain

Zig **0.17.0** is pinned in `.zigversion` and the root build's exact-version
check. Each package manifest declares 0.17.0 as its minimum supported version.
It was the latest stable release in the
[official Zig release index](https://ziglang.org/download/index.json) when this
workspace was created on 2026-10-10. Stable updates should be deliberate and
validated across all three architectures.

Use the existing [zvm](https://github.com/tristanisham/zvm) installation:

```powershell
zvm install --nomirror 0.17.0
zvm use 0.17.0
zig version
zig build
zig build test
```

The workspace wrappers read `.zigversion` and run that exact compiler through
zvm, including when another Zig version is active. `.zigversion` is a workspace
convention consumed by these scripts; no automatic zvm directory switching is
assumed.

```powershell
.\tools\zig.ps1 build check
.\tools\zig.ps1 build test
```

On Unix, use `sh tools/zig.sh build check` or `sh tools/zig.sh build test`.
Wrappers run in the caller's current directory.

## Workspace

```text
BedrockOS/
  bootloader/       independent loader package; CPU and platform startup
  kernel/           independent kernel package; CPU and platform mechanisms
  filesystem/       portable filesystem package and storage interface
  boot-protocol/    versioned data shared by loader and kernel
  frameworks/public/AxisUI/    native declarative UI API for applications
  frameworks/public/NetworkKit/ connected UDP and Wi-Fi control provider APIs
  frameworks/private/NetworkCore/ trusted packet/endpoint and radio-controller mechanisms
  userspace/apps/shell/        native desktop application, theme and view composition
  userspace/runtime/           Bedrock64 ABI, syscall wrappers and ELF entry/linker
  userspace/apps/init/         native init and process/IPC acceptance workload
  userspace/apps/lifecycle-test/ native service and adversarial child executable
  userspace/apps/io-test/      native files, pipes and executable replacement tests
  userspace/apps/exec-test/    same-PID replacement and granted pipe-writer child
  userspace/apps/files/        protected file manager; sidebar/list and optional split
  userspace/apps/network-test/ protected NetworkKit echo and authority probe
  userspace/apps/wifi-test/    protected simulated/unavailable-radio control probe
  userspace/services/window-server/ reusable window policy; currently kernel-hosted
  userspace/        independent native executable package and application sources
  docs/             architecture, handoff rules, support matrix, roadmap
  tools/            pinned-toolchain wrappers and bounded emulator tests
  build.zig         orchestration for the three required architectures
  build.zig.zon     local package dependencies
  .zigversion       exact compiler version
```

```text
bootloader --> boot-protocol <-- kernel --> filesystem
                                 |
                                 +--> embedded native ELF catalog <-- userspace/runtime + apps/init
                                 +--> privileged desktop host --> userspace/apps/shell --> public AxisUI
                                 +--> protected Files ELF --> checked drawing/input/file syscalls
```

The filesystem accepts caller-supplied storage access. It does not import the
kernel, CPU startup, firmware, or hardware drivers. A future loader can use it
without depending on kernel internals.

## Build commands

| Command | Result |
| --- | --- |
| `zig build` | Build the three primary UEFI images and compile probes; RV64 UEFI requires Python 3 |
| `zig build uefi` | Build all three UEFI loaders and relocatable kernels |
| `zig build images` | Build all UEFI artifacts and three reset reference pairs |
| `zig build check` | Compile every component for all three freestanding targets |
| `zig build check-x86_64` | Check only the x86-64 profile |
| `zig build check-aarch64` | Check only the ARM64 profile |
| `zig build check-riscv64` | Check only the RV64 profile |
| `zig build test` | Run native OS, filesystem, AxisUI, Files, window-policy and handoff bridge tests |
| `zig build arm64` | Build the ARM64 reset reference into `zig-out/arm64/` |
| `zig build run-arm64` | Boot the ARM64 reset reference in QEMU; Ctrl+C stops the console |
| `zig build test-arm64` | Run the bounded ARM64 reset-reference boot test |
| `zig build x86_64` / `zig build riscv64` | Build the selected reset-reference image pair |
| `zig build run-x86_64` / `zig build run-riscv64` | Boot the selected reset reference in QEMU; Ctrl+C stops it |
| `zig build test-x86_64` / `zig build test-riscv64` | Run the selected bounded reset-reference boot test |
| `zig build uefi-x86_64` / `uefi-arm64` / `uefi-riscv64` | Build a firmware loader with a separately compiled, relocatable embedded kernel |
| `zig build uefi-image-x86_64` | Package a standalone GPT/FAT32 disk image; requires Python 3 |
| `zig build test-uefi-image-x86_64` | Check GPT/FAT32 and boot the packaged disk image through UEFI |
| `zig build run-uefi-x86_64` / `run-uefi-arm64` / `run-uefi-riscv64` | Boot normal UEFI with native Files and a retained data image; Ctrl+C stops it |
| `zig build test-uefi-x86_64` / `test-uefi-arm64` / `test-uefi-riscv64` | Verify firmware exit, ownership/isolation, timer switching, native processes, IPC, file/pipe I/O, exec and cleanup |
| `zig build test-uefi` | Verify the primary UEFI path on all three architectures |
| `zig build test-desktop` | Drive protected Files through real input, file operations, window controls and abrupt-reboot recovery on all three UEFI references |
| `zig build test-desktop-x86_64` / `test-desktop-arm64` / `test-desktop-riscv64` | Run that native desktop workflow for one architecture |
| `zig build test-boot` | Verify all three reset paths and all three UEFI paths |
| `zig build test-boot-matrix` | Check 18 RAM/boot-path configurations |
| `zig build test-network` | Verify the protected UDP probe over VirtIO on all three UEFI references |
| `zig build test-network-x86_64` / `test-network-arm64` / `test-network-riscv64` | Run that isolated network workflow for one architecture |
| `zig build test-wifi` | Verify simulated Wi-Fi controls and production unavailable-radio policy on all three UEFI references |
| `zig build test-wifi-x86_64` / `test-wifi-arm64` / `test-wifi-riscv64` | Run both isolated Wi-Fi control variants for one architecture |

Each package also builds independently. For example, from `kernel/`, run
`zig build check -Dtarget=aarch64-freestanding-none` or `zig build test` for
native memory, console and security-foundation tests. The filesystem and
boot-protocol packages also provide native `zig build test` steps.

## Current scope

All three architectures have a primary UEFI target and a reset reference.
Each Bedrock loader copies a
separately linked kernel into RAM and passes a checked boot record. The kernel
initializes its console and exception handlers, reports memory, and builds a
shared physical-page allocator. Startup checks exercise zeroed frames, actual
RAM writes and reads, aligned contiguous allocation, release and reuse before
the deliberate breakpoint. UEFI kernels then install protected paging and run
two private user-mode tasks: one attempts forbidden memory accesses while the
other continues to complete its checked syscalls. Two saved contexts then spin
without yielding while hardware timers alternate them for three quanta each.
The core then destroys their saved contexts and private mappings before returning
owned payload frames and grants. Rollback and repeated-reuse checks exercise
the bounded registries and preserve permanent kernel resources.
Native init then starts a service with an attenuated receive-only endpoint,
blocks and wakes both sides of a bounded mailbox, waits for child exit, sleeps
on hardware ticks and collects fault statuses. Final cleanup checks the exact
payload, table, handle and queued-byte ownership baseline. These first native
programs use immutable embedded ELF files mounted in app-owned RAM bundles and
a bounded memory profile. Native I/O tests add private files, descriptor rights,
pipe closure, explicit child writer grants and failed/successful exec.
[Unix I/O verification](docs/unix-io.md) passed both 18-boot matrices and all
six normal UEFI previews in Debug and ReleaseSafe.
Those results describe the preceding Unix I/O stage. The newer
[persistent Files/input verification](docs/storage-and-files-verification.md)
passed fresh Debug/ReleaseSafe native checks, both 18-configuration boot matrices
and six desktop workflows covering all three architectures in both modes.
Each workflow abruptly stops its first QEMU process, then verifies committed
file content and ownership after a fresh boot: 12 normal desktop boots in total.
Those receipts describe the preceding two-pane storage/input extension. The
compact sidebar/history/clipboard and close/relaunch/fullscreen revision has
its own completed [UI verification](docs/files-ui-verification.md). Debug and
ReleaseSafe each passed all three named QEMU profiles: six two-boot workflows
in total, twenty-four native client starts and twelve resource-reclamation
checks, with committed file bytes checked after fresh clients. All workspace
native suites, compile checks and three UEFI smoke paths also passed in both
modes, including cached unchanged tests. Independent native package counts are
AxisUI 24, Files 24 and window policy 9 per mode at that historical milestone;
executed-only summary counts
are not a fresh inventory total. These results cover one hosted window on QEMU.
Use `zig build test-desktop -Doptimize=ReleaseSafe` to select the other mode.
The subsequent [context-menu/Nullify milestone](docs/context-menus-and-nullify.md)
has independent Files 31/31 and filesystem 35/35 native tests passing in both
modes. Its separate integrated acceptance passed 172/172 build steps in each
mode and all six QEMU workflows: twelve normal boots, twenty-four client starts
and twelve checked closes. Six real Nullify actions were checked across twelve
complete logical banks, including independent byte/CRC inspection and absence
after reboot. The default Debug install passed 106/106 steps. These results
remain scoped to the named QEMU references and Bedrock's logical image bytes.
Smoke firmware variants enable an emulator
test exit after those checks; normal images need no test exit backend.

| Architecture | Reference emulator | Firmware entry |
| --- | --- | --- |
| x86-64 UEFI | QEMU `pc-q35-10.1`, EDK2/OVMF | Firmware → Bedrock EFI loader → ExitBootServices → kernel |
| ARM64 UEFI | QEMU `virt-10.1`, EDK2 | Firmware → Bedrock EFI loader → EL1 kernel |
| RV64 UEFI | QEMU RISC-V `virt`, OpenSBI + EDK2 | Firmware → Bedrock EFI loader → S-mode kernel |
| ARM64 reset reference | QEMU `virt-10.1`, Cortex-A57 | Bedrock flash firmware at CPU reset, EL1h |
| x86-64 reset reference | QEMU `pc-i440fx-10.1`, qemu64 | Bedrock reset ROM; 16-bit → 32-bit → long mode |
| RV64 reset reference | QEMU RISC-V `virt`, rv64 | QEMU reset ROM → Bedrock M-mode firmware; no OpenSBI |

All references use TCG and one CPU/hart. RAM defaults to 128 MiB; select another
size with `-Dram-mib=512`. Reset loaders discover memory instead of assuming that
default. ARM64/RV64 read Devicetree memory banks and reservations; the QEMU PC
loader reads firmware configuration RAM/E820 records. The UEFI loaders obtain
the firmware memory map. A shared bounded map separates usable RAM from loader,
kernel, firmware and device reservations. Kernels consume that map and select
their console from the handoff. The build searches PATH
and the standard Windows QEMU installation. Override an executable with
`-Dqemu-arm64="<absolute path>"`, `-Dqemu-x86_64="<absolute path>"`, or
`-Dqemu-riscv64="<absolute path>"`. The earlier ARM64 `-Dqemu` option remains
supported. Unix acceptance tests require Python 3.

UEFI tests use the installed QEMU firmware on Windows. Override x86 firmware
with matching `-Dovmf-code="<path>"` and `-Dovmf-vars="<path>"`; for the other
architectures use `-Duefi-code-arm64`, `-Duefi-vars-arm64`,
`-Duefi-code-riscv64` and `-Duefi-vars-riscv64`. Variable-store writes use a
private QEMU snapshot. RV64 UEFI builds use a bounded ELF-to-PE converter because
Zig 0.17 cannot emit RISC-V COFF directly; Python 3.8+ is a host build dependency.
The reset-only architecture steps need no converter.
See the [x86-64 UEFI contract](docs/x86_64-uefi.md) and
[ARM64/RV64 firmware contract](docs/arm64-riscv64-uefi.md) for addressability,
console and firmware requirements. No physical computer has been qualified.
The optional [disk-image builder](docs/uefi-image.md) produces
`zig-out/uefi/x86_64/bedrock-uefi.img` without mounting or formatting host drives.

Read the reset-reference [ARM64](docs/arm64-qemu.md),
[x86-64](docs/x86_64-qemu.md), and [RV64](docs/riscv64-qemu.md) contracts for
their layouts and debugging.

The filesystem package supplies a portable block interface, RAM backend and
durable 32-node backend with 4,096 bytes per mutable file. Live and staged snapshots
remain in BSS; a dedicated 4 MiB data image stores two CRC-protected snapshot
banks. Immutable bundle ELF bytes are borrowed separately. File and pipe descriptors
recheck the current app's authority; successful exec preserves PID/profile and
closes old descriptors before entering its staged replacement. See
[Unix I/O](docs/unix-io.md) for the preceding profile and
[persistent filesystem](docs/persistent-filesystem.md) for the durable contract.
Normal QEMU runs retain `zig-out/data/<arch>.img`; disposable acceptance images
are separate. Existing media is mounted, never automatically reformatted.
The shared
bitmap allocator uses complete 4 KiB pages in the intersection of discovered
usable memory and current accessible ranges. It reserves its metadata in usable
RAM and retains that reservation for the allocator's lifetime. Architecture
adapters supply physical access and address limits; portable allocation policy
lives in `kernel/src/core/`. See [memory management](docs/memory-management.md)
for the APIs, ownership rules and acceptance checks.
A bounded page-backed kernel heap allocates zeroed pages through owned tickets.
Private table creation rolls back on failure; explicit context and address-space
destruction reject active or stale references and permit safe reuse. Fixture
cleanup returns its three payload-frame, one-handle and one-process charges;
table and other kernel overhead are not yet fully app-accounted. See
[resource lifecycle](docs/resource-lifecycle.md).
UEFI kernels relocate to firmware-selected memory; x86-64 builds sparse identity
mappings and has passed a kernel-placement test above 4 GiB. Kernel-owned
protected paging and user tasks are described in the
[protected-userspace contract](docs/protected-userspace.md) and
[timer-preemption contract](docs/preemptive-scheduling.md). General filesystem
formats and ELF layouts, POSIX interfaces, installed app bundles, a user-space
compositor and physical board qualification remain future milestones.

Read [the architecture](docs/architecture.md), [boot contract](docs/boot-protocol.md),
[application model](docs/application-model.md), [desktop design](docs/desktop-design.md),
[support matrix](docs/support-matrix.md),
[porting guide](docs/portability.md), and [roadmap](docs/roadmap.md).
