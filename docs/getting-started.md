# Getting started

[Back to Bedrock](../README.md)

Build and run Bedrock from the repository root. The current reference machines
are x86-64 Q35, ARM64 `virt` and RV64 `virt` in QEMU. Physical machines have not
been qualified; the installer currently requires VirtIO storage.

## Requirements

- **Zig 0.17.0**, pinned in [`.zigversion`](../.zigversion) and checked by the build.
- **QEMU**, including the system emulator and matching UEFI firmware for each
  architecture you want to run. The reference profiles use QEMU 10.1 machine types.
- **Python 3.9+** for image packaging, acceptance tools and RV64 ELF-to-PE conversion.
- **Pillow** for acceptance tests that verify PNG screenshots.

Use the existing zvm installation to select the pinned compiler:

```powershell
zvm install --nomirror 0.17.0
zvm use 0.17.0
zig version
```

The workspace wrappers read `.zigversion` and invoke that exact version through
zvm, even when another compiler is active:

```powershell
.\tools\zig.ps1 build check
.\tools\zig.ps1 build test
```

On Unix, use `sh tools/zig.sh build check` and `sh tools/zig.sh build test`.
Run wrappers from the repository root; they retain the caller's current directory.

## Run the desktop

Choose a reference architecture:

```text
zig build run-uefi-x86_64 -Doptimize=ReleaseSafe -j1
zig build run-uefi-arm64 -Doptimize=ReleaseSafe -j1
zig build run-uefi-riscv64 -Doptimize=ReleaseSafe -j1
```

Each command builds and launches the native window desktop with Files, Notes and
the shell. The build searches PATH and the standard Windows QEMU installation.
Close the emulator window or stop the launch command with Ctrl+C when finished.
Use `ReleaseSafe` for interactive runs: the default Debug kernel makes software
scanout substantially slower. The reference launcher uses QEMU's TCG CPU
emulator; desktop frame rate depends on the host and the amount being repainted.
See [desktop performance](desktop-performance.md) for measurements and limits.

Normal runs retain app data in `zig-out/data/<arch>.img`. Existing data images
are mounted rather than automatically reformatted. Acceptance tests use their
own disposable images. Normal runs are offline; `-Dnetwork=true` explicitly
attaches a VirtIO NIC without changing app permissions. Physical Wi-Fi remains
unqualified; see the [network framework](network-framework.md) and
[Wi-Fi setup](wifi-boot-setup.md) for the implemented scope.

### Desktop controls

| Action | Control |
| --- | --- |
| Open, focus or restore Files | Files chip or Super+E |
| Open, focus or restore Notes | Notes chip or Super+N |
| Edit the Files location | Click its path or press Ctrl+L |
| Open or close a Files tab | + / Ctrl+T; tab X / Ctrl+W |
| Reorder tabs | Drag a tab across its neighbor |
| Pull a tab into its own window | Drag above or below the tab strip and release |
| Switch workspace | Super+1 through Super+4 |
| Move a window to another workspace | Super+Shift+1 through Super+Shift+4 |
| Toggle tiling | Super+T |
| Cycle visible windows | Super+Tab |
| Move or resize a floating window | Drag its caption, border or corner |
| Close the focused window | Right-side Close button or Alt+F4 |
| Minimize; maximize or restore | Right-side window buttons |
| Toggle fullscreen | F11; Escape leaves fullscreen |

Files provides private folders, creation, rename, Copy/Cut/Paste and drag-and-drop.
Notes saves with its Save button or Ctrl+S. The right-side system bar opens
Control Center for layout, workspaces and software display dimming. See the
[window desktop guide](window-desktop.md) for the complete interaction model.

## Try the installer

```text
zig build run-installer-x86_64 -j1
```

The launcher creates an 80 MiB ordinary virtual disk at
`zig-out/installed/x86_64/bedrock-installed.img` only when that file is absent.
The native installer shows the partition layout and requires exactly `ERASE`
before replacing the selected virtual drive's layout. The launcher never opens
host block devices.

After installation, close the installer VM and boot the installed disk alone:

```text
zig build run-installed-x86_64 -j1
```

Use `arm64` or `riscv64` in place of `x86_64` for the other reference machines.
The current layout allocates about 63 MiB to the EFI system partition and 4 MiB
to Bedrock data, leaving the rest unallocated. Existing-partition resizing,
dual boot and physical SSD drivers are unfinished. The current filesystem is
bounded to 32 nodes, 4096 bytes per mutable file and 128-byte internal paths.
Read the [installer guide](installer.md) and its
[verification record](installer-verification.md) for the full contract.

## Build and verify

```text
zig build -j1
zig build check test -j1
zig build check test -Doptimize=ReleaseSafe -j1
```

The default build produces primary UEFI images for all three architectures and
component compile probes. `check` cross-compiles components; `test` runs native
suites. Build outputs live under `zig-out/`.

Run actual emulator workflows separately:

```text
zig build test-system-menus -j1
zig build test-window-desktop -j1
zig build test-installer -j1
```

Those workflows cover native input and pixels, app lifetimes, window controls,
menus, installer confirmation and persistence across reboot. Saved receipts and
captures are generated under `zig-out/`; build logs and aggregate receipts also
live under `.zig-cache/`. These directories are ignored by Git.

## Emulator and firmware configuration

Override emulator paths with `-Dqemu-x86_64="<absolute path>"`,
`-Dqemu-arm64="<absolute path>"` or `-Dqemu-riscv64="<absolute path>"`.
The earlier ARM64 `-Dqemu` option remains supported.

UEFI runs use the installed QEMU firmware on Windows. Override matching code
and variable-store files with:

| Architecture | Code image option | Variable-store option |
| --- | --- | --- |
| x86-64 | `-Dovmf-code="<path>"` | `-Dovmf-vars="<path>"` |
| ARM64 | `-Duefi-code-arm64="<path>"` | `-Duefi-vars-arm64="<path>"` |
| RV64 | `-Duefi-code-riscv64="<path>"` | `-Duefi-vars-riscv64="<path>"` |

Variable-store changes use a private QEMU snapshot. Reference runs use TCG and
one CPU/hart. General boot profiles default to 128 MiB RAM; `-Dram-mib=512`
selects another size. Desktop and installer workflows may enforce their own
minimums. RV64 UEFI uses a bounded ELF-to-PE converter because the pinned
compiler cannot emit RISC-V COFF directly.

See the [x86-64 firmware contract](x86_64-uefi.md) and
[ARM64/RV64 firmware contract](arm64-riscv64-uefi.md) for platform requirements.

## Workspace layout

```text
BedrockOS/
  bootloader/       independent loader package; CPU and platform startup
  kernel/           independent kernel package; CPU and platform mechanisms
  filesystem/       portable filesystem package and storage interface
  boot-protocol/    versioned data shared by loader and kernel
  drivers/          optional chipset implementations, module entry and hardware catalogue
  frameworks/public/AxisUI/    native declarative UI API for applications
  frameworks/public/NetworkKit/ connected UDP and Wi-Fi control provider APIs
  frameworks/private/DriverKit/ shared versioned driver ABI and bounded loader/linker tools
  frameworks/private/NetworkCore/ trusted packet/endpoint and radio-controller mechanisms
  userspace/apps/shell/        native desktop application, theme and view composition
  userspace/runtime/           Bedrock64 ABI, startup/heap SDK, archive and ELF entry/linker
  userspace/apps/init/         persistent installed init and separate lifecycle fixture
  userspace/apps/observer/     independently sandboxed persistent heartbeat application
  userspace/apps/worker/       independently sandboxed crash/restart and heap application
  userspace/apps/lifecycle-test/ native service and adversarial child executable
  userspace/apps/io-test/      native files, pipes and executable replacement tests
  userspace/apps/exec-test/    same-PID replacement and granted pipe-writer child
  userspace/apps/files/        protected file manager; sidebar/list and optional split
  userspace/apps/notes/        private native ASCII editor and checked Save
  userspace/apps/installer/    native UEFI installer, partition preview and verified copying
  userspace/apps/network-test/ protected NetworkKit echo and authority probe
  userspace/apps/wifi-test/    protected simulated/unavailable-radio control probe
  userspace/services/display-server/ native compositor, retained scene and focused input
  userspace/services/window-server/ reusable window geometry and control policy
  userspace/        independent native executable package and application sources
  docs/             architecture, handoff rules, support matrix, roadmap
  tools/            pinned-toolchain wrappers and bounded emulator tests
  build.zig         orchestration for the three required architectures
  build.zig.zon     local package dependencies
  .zigversion       exact compiler version
```

```text
bootloader --> boot-protocol <-- kernel --> filesystem
      |                           |
      +--> private DriverKit <----+--> generic class adapters <-- separately loaded drivers/
                                 |
                                 +--> installed app archive --> persistent init + sandboxed apps
                                 +--> embedded native ELF fixtures <-- userspace/runtime + apps/init
                                 +--> checked surfaces + IPC --> user-space compositor --> scanout
                                 +--> sandboxed shell + Files + Notes --> native AxisUI pixels + checked files
```

The filesystem accepts caller-supplied storage access. It does not import the
kernel, CPU startup, firmware, or hardware drivers. A future loader can use it
without depending on kernel internals.

## Command reference

| Command | Result |
| --- | --- |
| `zig build installer` | Package the native firmware installer for all three architectures |
| `zig build run-installer-x86_64` / `run-installer-arm64` / `run-installer-riscv64` | Open the native installer against an ordinary virtual target |
| `zig build run-installed-x86_64` / `run-installed-arm64` / `run-installed-riscv64` | Boot an installed virtual disk alone |
| `zig build test-installer-units` | Run native consent, payload, source protection and copy-failure checks |
| `zig build test-installer` | Install to owned virtual disks and verify target-only boots and persistence |
| `zig build test-system-menus` | Verify native app/system menus, clock, icons and Control Center |
| `zig build` | Build the three primary UEFI images and compile probes; RV64 UEFI requires Python 3 |
| `zig build uefi` / `zig build desktop` / `zig build windows` | Package the primary native window desktop for all three architectures |
| `zig build desktop-x86_64` / `desktop-arm64` / `desktop-riscv64` | Package one installed desktop |
| `zig build test-window-desktop` | Primary desktop gate: Files/Notes, native input, resizing, tiling, workspaces, independent lifecycle and disk recovery |
| `zig build test-window-desktop-x86_64` / `test-window-desktop-arm64` / `test-window-desktop-riscv64` | Run primary persistent and acceptance workflows for one architecture |
| `zig build test-window-units` | Verify native window policy, SDK and independent receipt evidence |
| `zig build test-anvil` | Verify graphics commands, CPU resources, fences and scanout bounds |
| `zig build test-anvil-desktop -Doptimize=ReleaseSafe` | Verify Anvil CPU presentation and native desktop pixels on all three QEMU references |
| `zig build service-desktop` / `zig build test-service-desktop` | Build or verify the retained single-window Files service desktop |
| `zig build display` / `zig build test-display` | Build or verify the earlier fixed two-client surface demonstration |
| `zig build app-runtime` | Package the dedicated headless installed-app runtime for all three architectures |
| `zig build app-runtime-x86_64` / `app-runtime-arm64` / `app-runtime-riscv64` | Package one installed-app runtime profile |
| `zig build run-apps-x86_64` / `run-apps-arm64` / `run-apps-riscv64` | Boot persistent user-space init, Observer and Worker; Ctrl+C stops QEMU |
| `zig build test-apps` | Verify installed app launch, independent identities, crash/restart, observer survival and cleanup on all three UEFI references |
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
| `zig build uefi-image-x86_64` / `uefi-image-arm64` / `uefi-image-riscv64` | Package a primary GPT/FAT32 desktop image; requires Python 3 |
| `zig build test-uefi-image-x86_64` | Check GPT/FAT32 and boot the packaged disk image through UEFI |
| `zig build run-uefi-x86_64` / `run-uefi-arm64` / `run-uefi-riscv64` | Boot the installed compositor, shell and Files with a retained data image; Ctrl+C stops it |
| `zig build test-uefi-x86_64` / `test-uefi-arm64` / `test-uefi-riscv64` | Verify firmware exit, ownership/isolation, timer switching, native processes, IPC, file/pipe I/O, exec and cleanup |
| `zig build test-uefi` | Verify the underlying UEFI boot and embedded lifecycle fixtures on all three architectures |
| `zig build test-desktop` | Retain the older kernel-hosted Files/input/storage regression on all three UEFI references |
| `zig build run-legacy-uefi-x86_64` / `run-legacy-uefi-arm64` / `run-legacy-uefi-riscv64` | Run the earlier kernel-hosted desktop explicitly |
| `zig build test-desktop-x86_64` / `test-desktop-arm64` / `test-desktop-riscv64` | Run that native desktop workflow for one architecture |
| `zig build test-boot` | Verify all three reset paths and all three UEFI paths |
| `zig build test-boot-matrix` | Check 18 RAM/boot-path configurations |
| `zig build test-network` | Verify the protected UDP probe over VirtIO on all three UEFI references |
| `zig build test-network-x86_64` / `test-network-arm64` / `test-network-riscv64` | Run that isolated network workflow for one architecture |
| `zig build test-wifi` | Verify simulated Wi-Fi controls and production unavailable-radio policy on all three UEFI references |
| `zig build test-wifi-x86_64` / `test-wifi-arm64` / `test-wifi-riscv64` | Run both isolated Wi-Fi control variants for one architecture |
| `zig build test-wifi-boot-assets` | Check EFI firmware/profile/RNG staging, boot preflight, image/profile tools and strong cross probes |
| `zig build test-wifi-boot` | Boot valid and damaged firmware files on all three UEFI QEMU references |
| `zig build wifi-uefi` | Create ordinary firmware-bearing ESP trees and GPT/FAT32 images; optional actual-board profile |
| `zig build drivers` | Build separate architecture-specific driver modules and validated package metadata |
| `zig build test-driver-modules` | Verify ABI/ELF/package rules, module execution on all three UEFI references and production rejection policy |

Each package also builds independently. For example, from `kernel/`, run
`zig build check -Dtarget=aarch64-freestanding-none` or `zig build test` for
native memory, console and security-foundation tests. The filesystem and
boot-protocol packages also provide native `zig build test` steps.

## Further reading

- [Architecture](architecture.md), [boot protocol](boot-protocol.md) and
  [memory management](memory-management.md).
- [Application model](application-model.md), [native processes](native-processes.md),
  [installed runtime](application-runtime.md) and [Unix I/O](unix-io.md).
- [Native desktop](window-desktop.md), [menu APIs](system-menus.md),
  [AxisUI](../frameworks/public/AxisUI/README.md) and
  [framework boundaries](../frameworks/README.md).
- [Persistent filesystem](persistent-filesystem.md),
  [driver packages](driver-packages.md) and [DriverKit](../frameworks/private/DriverKit/README.md).
- [Support matrix](support-matrix.md), [porting guide](portability.md) and
  [roadmap](roadmap.md).
