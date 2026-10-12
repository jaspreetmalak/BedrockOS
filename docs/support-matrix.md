# Support matrix

UEFI is Bedrock's primary boot path. `zig build` builds the three UEFI images
and compile probes; `zig build uefi` builds only the UEFI artifacts, and
`zig build test-uefi` verifies those three boot paths. The reset profiles remain
reference targets and are included in the full `images` and `test-boot` steps.

## Workspace compile profiles

| Profile | Zig target | Current support level |
| --- | --- | --- |
| Intel/AMD x86-64 | `x86_64-freestanding-none` | Compile checks, primary Q35 UEFI and pc-i440fx-10.1 reset reference |
| ARM64 / AArch64 | `aarch64-freestanding-none` | Compile checks, primary virt-10.1 UEFI and reset reference |
| RISC-V 64 | `riscv64-freestanding-none` | Compile checks, primary virt UEFI/S mode and M-mode reset reference |

All three are required architecture profiles. Compile probes use baseline CPU
models. ARM64 boot images use Cortex-A57 plus strict alignment; this is not a
claim that all hardware using these ISAs is supported.
ARM32, RV32, and non-MMU microcontrollers are outside the initial profile.

Initial workspace verification on 2026-10-11 with Zig 0.17.0 on Windows: all twelve component/profile
probe libraries compiled in Debug and ReleaseSafe and installed by the default
Debug build. All 119 native Zig tests passed in both modes, including cached
unchanged storage tests. Zig formatting and host-script syntax checks passed.

## Platform support

The preceding networking milestone added public NetworkKit and private NetworkCore
with modern VirtIO-net on the same three UEFI references. Six protected network
boots passed across Debug and ReleaseSafe: twelve nonempty and six empty UDP
datagrams, twenty-four injected bad-checksum/wrong-peer frames, checked buffer and
handle authority, and six live-endpoint process-exit reclamations. Both root
`test check test-uefi test-network test-desktop` runs passed 213/213 build steps;
the existing Files workflows also passed with network access denied.
This is connected nonblocking IPv4/UDP with static reference configuration and
256-byte datagrams. TCP, TLS, DNS, DHCP, IPv6, listening sockets and physical
NIC qualification remain future work. See the [network framework](network-framework.md)
and `.zig-cache/network-verification.json` for that historical scoped acceptance.

The current [Wi-Fi control foundation](wifi-framework.md) adds native
status/scan/join/enable APIs, a bounded trusted controller, separate observation
and control permissions, and canonical wire decoding. Dedicated protected UEFI
profiles use an explicitly simulated radio or exercise the production
unavailable-radio path. The known Wi-Fi image has a trusted cap of four code
pages, one data page and four stack pages; other fixtures keep their existing
bounds. Normal kernels report unavailable, and no physical Wi-Fi adapter, RF
operation or WPA authentication is qualified by these tests.

The Wi-Fi milestone passed 269/269 aggregate build steps in each of Debug and
ReleaseSafe and 202/202 default Debug build/install steps. All twelve Wi-Fi
boots passed: simulated and production unavailable variants on all three UEFI
references in both modes. The same aggregates passed six UDP boots and six
two-boot Files workflows. Component counts, commands and hashed receipts are
recorded in [Wi-Fi verification](wifi-framework.md#verification) and
`.zig-cache/wifi-verification.json`; physical radio tests total zero.

Selected [Wi-Fi driver protocols](wifi-driver-porting.md) now compile as native
Zig on all three targets. MT7922 has register/reset, owned polling firmware DMA,
RX/TX and scan-command codecs; targeted Intel/Realtek modules inspect real
firmware formats and identify PCI families. Shared 802.11 code includes a bounded
WPA2-CCMP handshake with GTK validation and install-once retransmission rules.
Production discovery uses x86-64 segment-zero PCI configuration; the ARM64/RV64
ECAM interface requires verified platform resources and is not automatically
discovered. These are protocol ports, not physical card support: calibration,
regulatory/MAC/key/data integration and RF qualification remain incomplete.
Normal Wi-Fi status therefore stays unavailable on every current platform.

The current desktop extension implements modern VirtIO block and keyboard/tablet
drivers for the three named UEFI references: PCI transport on x86-64 and MMIO
transport on ARM64/RV64. A dedicated 4 MiB image holds two CRC-protected filesystem
snapshots with 32 nodes and 4,096 bytes per mutable file. Normal runs retain
app-2 Files data separately from disposable acceptance media; existing media is
mounted without automatic formatting.

The native protected Files ELF now defaults to one list and a Places sidebar,
with eight-location history per pane and optional Split. Copy/Cut/Paste,
double-click open, create/mkdir, rename/delete, drag-and-drop and copied
read-only preview use its checked namespace. Mouse Save/Create/Cancel confirms
name edits; the preview does not edit file contents. A kernel display host
handles input, clipped client drawing and one movable window with distinct
close/minimize, maximize/restore and fullscreen controls; this is not a
standalone user-space compositor. The preceding
[storage/Files verification](storage-and-files-verification.md)
passed fresh Debug and ReleaseSafe native suites: 282 executed Zig checks and
six Python formatter checks per mode, plus all-three-architecture compile checks
and an 18-configuration boot matrix in each mode.

Each architecture also passed the native Files workflow in both modes: rename,
drag move, held-Ctrl copy, delete, mkdir, create, text preview, title drag and
minimize/reopen, alongside real checked-syscall authority at startup. Six
workflows each boot twice, for 12 normal desktop boots. The first QEMU process
is killed abruptly; independent CRC/generation/content/owner readback verifies
committed files before and after fresh boot. ReleaseSafe x86-64 also passed at
4,096 MiB with the kernel at `0x100000000`. These checks do not qualify physical
hardware or arbitrary fast cross-device modifier chords.

The compact redesign's [revised acceptance](files-ui-verification.md) passed
on all three named QEMU references in Debug and ReleaseSafe. Six two-boot
workflows total twelve boots, twenty-four client starts and twelve checked
close/resource-reclamation operations. Saved file bytes are checked after each
fresh client. All workspace native suites, compile checks and three UEFI smoke
paths passed in both modes, including cached results; native package counts
are AxisUI 24, Files 24 and window policy 9 per mode. F11 toggles fullscreen with a retained caption exit strip; Escape leaves
it and Alt+F4 closes the focused client. Minimize preserves the client, while
close retires descriptors, context, private mappings and owned frames before a
fresh bar/Super+E launch. Committed app-2 data is retained. The earlier workflow
counts above remain historical; the linked revised workflow record supplies
coverage of the new operations. This qualifies one hosted QEMU window, not
multiple app windows or physical hardware.

Receipts are `.zig-cache/persistent-verification.json` and
`zig-out/desktop-tests/{debug,safe}/desktop-<arch>-verification.json`.
Reproduce native desktop acceptance with `zig build test-desktop`, then
`zig build test-desktop -Doptimize=ReleaseSafe`. Earlier verified milestones
below retain their historical scopes.
See [desktop design](desktop-design.md) and
[persistent filesystem](persistent-filesystem.md).

The [native process and IPC milestone](native-processes.md) additionally passes
both 18-configuration Debug/ReleaseSafe matrices. All three UEFI profiles load
native ELF init and children, block/wake senders, receivers, sleepers and parents,
contain the three new child fault cases and reclaim their resources. A high
x86-64 UEFI placement test and six normal native desktop captures also pass.
Reset references retain their existing memory/exception scope.

| Named platform | Startup and devices | Current level |
| --- | --- | --- |
| QEMU ARM64 `virt-10.1`, Cortex-A57, TCG, 1 CPU | Bedrock flash firmware; DTB RAM/reservation/PL011 discovery | Handoff, allocation/reuse and breakpoint verified at 64/128/512 MiB |
| QEMU x86-64 `pc-i440fx-10.1`, qemu64, TCG, 1 CPU | Bedrock reset ROM; fw_cfg RAM/E820 discovery; COM1 | Handoff, allocation/reuse and INT3 verified at 64/128/512/4096 MiB |
| QEMU RV64 `virt`, rv64, TCG, 1 hart | Bedrock M-mode firmware; DTB RAM/reservation/16550 discovery; no OpenSBI | Handoff, allocation/reuse and EBREAK verified at 64/128/512 MiB |
| QEMU x86-64 `pc-q35-10.1`, qemu64, TCG, 1 CPU, EDK2/OVMF | Standard UEFI entry, retained EFI map/ACPI/GOP, ExitBootServices | Handoff, allocation/reuse and INT3 verified at 128/256/512/4096 MiB; normal framebuffer output verified |
| QEMU ARM64 `virt-10.1`, Cortex-A57, TCG, 1 CPU, EDK2 | Dynamic PIE, retained EFI map/copied DTB, PL011, EL1h | Handoff, allocation/reuse and BRK verified at 128/256/512 MiB; actual EL2-to-EL1 transition also verified |
| QEMU RV64 `virt`, rv64, TCG, 1 hart, OpenSBI + EDK2 | Converted RV64 PE, dynamic PIE, retained EFI map/copied DTB, NS16550, S mode | Handoff, allocation/reuse and EBREAK verified at 128/256/512 MiB |
| Physical boards/PCs | Firmware, access policy and device qualification required | Unvalidated |

All three named UEFI platforms additionally pass protected user-mode execution,
distinct private data roots, checked syscalls and five contained protection
faults at 128/256/512 MiB in Debug and ReleaseSafe. The second task completes
its checks after every fault. Hardware timers then alternate two non-yielding
saved contexts for three quanta each. The x86 ReleaseSafe check also passes with a
kernel at `0x100000000` and 4096 MiB RAM. Direct-reset references retain their
allocator/breakpoint scope. See [protected userspace](protected-userspace.md).

`zig build test-boot` runs the three reset boot checks and all three UEFI checks.
Individual steps are `test-arm64`, `test-x86_64`, `test-riscv64` and
`test-uefi-x86_64`, `test-uefi-arm64`, `test-uefi-riscv64`. They verify ordered console
milestones and the architecture's expected host exit status. Normal images idle
after startup without a test-exit backend. See the [ARM64](arm64-qemu.md),
[x86-64](x86_64-qemu.md), [RV64](riscv64-qemu.md), [x86 UEFI](x86_64-uefi.md),
and [ARM64/RV64 UEFI](arm64-riscv64-uefi.md) contracts.

All three ports were verified on 2026-10-11 with Zig 0.17.0 and installed QEMU
`10.1.94 (v10.2.0-rc4-12104-gb2a6201393)`. The 18-configuration memory/boot-path
matrix passed in both Debug and ReleaseSafe (36 boot runs): reset images at
64/128/512 MiB and UEFI images at 128/256/512 MiB for each architecture.
`zig build test-boot-matrix` reproduces the RAM matrix; `-Doptimize=ReleaseSafe`
selects the other optimization mode. Normal images also reached completion and remained alive during bounded
three-second checks with test exits disabled. Generated ELF entries, reset
encoding, allocation bounds and file-backed load segments were checked against
the raw images. x86 INT3 verification includes full GPR, SSE, x87 and flags
restoration. RV64 has no versioned `virt` machine alias; its executable version
and fixed platform assumptions are explicit.

Native tests cover 23 handoff/map cases, 15 Devicetree cases, eight EFI memory
conversion cases, seven ELF-loading cases, four sparse paging cases, three
bootstrap page cases, twelve physical-allocator cases, four architecture access
and address-ceiling cases, one framebuffer boundary/scroll case, six app-grant
policy cases, nine handle-authority cases, six quota cases, four checked
user-memory range cases, five scheduler-policy cases, three ARM timer/controller
discovery cases, four RV timebase-discovery cases and five storage
cases. Six independent Python ELF-to-PE tests load serialized sections and apply
DIR64 relocations at different bases. Independent review checked discovery
bounds, reservation ownership, firmware-stack restoration, EFI exit ordering,
CPU transitions and PE relocation semantics.
The normal UEFI framebuffer was captured through QMP and inspected: it displayed
the kernel's memory diagnostics, exception recovery and boot completion without
a test exit. ARM64 and RV64 normal UEFI framebuffer paths were also captured
and visually verified with QEMU `ramfb`; both remained idle until controlled
quit. Their normal serial fallback and virtio-GPU BLT-only fallback also passed.
A further x86 reset check at 4096 MiB verified a discontiguous E820
map with RAM above the PCI hole; that reset path retains its documented 4 GiB
mapping limit. The dynamic UEFI path passed deterministic kernel placement at
`0x100000000` in Debug and ReleaseSafe with 4096 MiB. Separate Debug placement
checks passed with ARM64's kernel at `0x441b0000` and RV64's at `0x84000000`.
UEFI RAM-matrix logs show different firmware-selected kernel/loader addresses.
The optional 64 MiB GPT/FAT32 UEFI image also booted
through OVMF to kernel completion at 128 MiB; its normal application displayed
completion on the framebuffer and stayed alive during a five-second check.
Its independent structure/payload
checker and eight format/corruption tests passed; reproduce them with
`zig build test-uefi-image-x86_64`. See the [image layout](uefi-image.md).
Reset arenas, bounded resources, device subsets and paging/cacheability limits
remain documented; no physical machine is validated. The standard RV64 UEFI
path requires host Python conversion and machine-firmware permissions; its
current physical-width contract is specific to the named QEMU reference.

The 2026-10-11 kernel-memory checks add actual frame allocation, whole-frame
zeroing and RAM integrity, aligned contiguous allocation, release/reuse and
restored allocator counters to every matrix boot. Additional ReleaseSafe checks
passed for x86 reset at 4096 MiB and UEFI kernel placement at `0x100000000` with
4096 MiB. Kernel-local native tests also pass independently (`cd kernel`, then
`zig build test`: 57 cases including security, user-memory, scheduler and timer-discovery checks). See the
[memory-management contract](memory-management.md).

The protected-user milestone passed on 2026-10-11 with the same pinned compiler
and emulator. Both full 18-configuration boot matrices passed; ARM's final
created-root/continuation checks were revalidated separately at all three UEFI
RAM sizes in both modes. Normal ReleaseSafe GOP images for all three also
completed the five protection probes and second-task recovery at 256 MiB;
framebuffers were captured and inspected, and the images stayed alive before
controlled QMP shutdown. No physical disks or firmware templates were written.

Portable policy and handle foundations are now used by the user-mode probe
dispatcher: it rejects invalid pointers, unknown calls and writing through a
read-only test-object handle. Both tasks directly read their distinct private
sentinels, which the kernel checks alongside its copyin path. This establishes
the first hardware memory/entry boundary. Timer-preempted contexts add bounded
single-CPU execution of non-yielding tasks; these remain fixed boot fixtures
in the historical preemption milestone. Native ELF loading and teardown,
then a bounded app-scoped RAM VFS, now follow those fixtures. Full mandatory
app sandbox acceptance still requires installed app identities and trusted
resource brokers.
See the [application model](application-model.md) for the remaining gates.

The [preemption milestone](preemptive-scheduling.md) uses the Q35 PIT/PIC,
DTB-discovered ARM GICv2/architectural timer and RV SBI TIME/DTB clock paths.
Kernel interrupts remain masked, with no SMP or kernel-preemption claim.
Its final Debug and ReleaseSafe 18-configuration matrices passed on 2026-10-11,
and all three normal ReleaseSafe GOP images completed six timer quanta at
256 MiB. Framebuffers were inspected and each image remained alive before
controlled QMP shutdown. The x86 ReleaseSafe high-placement check passed at
`0x100000000` with 4096 MiB RAM. No physical hardware was qualified.

The first [Unix I/O profile](unix-io.md) passed both 18-configuration matrices
on 2026-10-11. Each mode has nine UEFI boots exercising app-scoped RAM files,
pipe transfer, same-PID exec, failed-exec rollback at full registry capacity
and transient-resource cleanup, plus nine reset regressions. ReleaseSafe passed
236 executed native checks and the x86 UEFI placement test above 4 GiB. All
six normal Debug/ReleaseSafe GOP previews completed and remained alive before
controlled QMP shutdown. At that stage files were RAM-resident; these results
precede the durable backend and interactive Files extension. No physical machine
has been qualified.

Track each future named platform through separate levels:

1. Compiles.
2. Boots and reports memory/platform information.
3. Runs protected userspace.
4. Supports the documented console/storage/network devices.
5. Passes cold-boot and recovery checks on physical hardware.

Emulator support and physical support must be reported separately.
