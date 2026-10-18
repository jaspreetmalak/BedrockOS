# Installed service desktop

Bedrock's primary UEFI image installs four separately linked native Zig ELF
programs: init, the compositor, shell and Files. Files and shell render their
own AxisUI pixel surfaces; the compositor owns the retained scene, window
controls and input routing. The kernel supplies checked resource mappings,
authenticated IPC, storage/input drivers and final framebuffer presentation.

## Build and run

Use the workspace's pinned Zig 0.17.0 toolchain and an installed QEMU:

```powershell
zig build desktop -j1
zig build run-uefi-x86_64 -j1
zig build run-uefi-arm64 -j1
zig build run-uefi-riscv64 -j1
```

`run-desktop-<architecture>` selects the same runtime. Desktop runs use at least
256 MiB RAM and modern VirtIO storage, keyboard and tablet devices. QEMU UEFI
references provide an 800×600 or 1280×800 GOP framebuffer. These named emulated
machines establish architecture coverage; physical computers require their
own firmware/device qualification.

`desktop-<architecture>` installs `zig-out/desktop/<architecture>/` with:

```text
EFI/BOOT/BOOTX64.EFI       # BOOTAA64.EFI or BOOTRISCV64.EFI on other ISAs
EFI/Bedrock/Apps/apps.bap  # four native executables, checked at boot
kernel.elf
bedrock-desktop.img        # ordinary GPT/FAT32 image
```

`uefi`, `uefi-<architecture>` and `uefi-image-<architecture>` build this primary
desktop and also install `zig-out/uefi/<architecture>/bedrock-uefi.img` with its
matching EFI/archive tree. The interactive runner keeps
`zig-out/data/<architecture>.img`; Files continues using app ID 2, so existing
Bedrock Files data stays in the same private namespace. Fresh disks get the
same welcome file and Documents/Downloads folders. A complete installer remains
future work.

## Programs and authority

| Program | Trusted ID | Responsibility |
| --- | --- | --- |
| init | 101 | Launch installed programs, monitor progress, reap and restart Files generations |
| compositor | 104 | Register display service, read device input, retain caches, compose scene and request scanout |
| shell | 107 | Native wallpaper, frosted launch bar and authenticated Files launch requests |
| Files | 2 | Native file manager model, private pixels and checked persistent file operations |

The trusted catalogue binds IDs, roles, permissions and image bounds. An archive
or app cannot assign itself display-service or launch rights. Only init launches
these trusted packages; only compositor 104 receives raw display input and
scanout authority. Shell and Files cannot register that service, inspect another
app's surface, map the framebuffer or use raw storage. Files also verifies denied
network/Wi-Fi control, foreign namespace access and bundle writes.

Each process has private code/data, an immutable startup page, guarded stack and
bounded 32 KiB heap. Desktop applications permit up to 128 KiB RX code and 512
KiB RW/NX data, including native layout/blur scratch in BSS. Four optional pixel
slots start 8 MiB above the architecture's user base, spaced 4 MiB apart. Slots
and unused gaps remain inaccessible until a checked surface lease is mapped.

## Pixels, frames and input

Five surfaces remain live while Files is open: one each for Files and shell,
plus three compositor-owned surfaces for the Files cache, shell cache and
composed scene. A client renders its configured viewport at source origin zero
using the full-screen row stride. The compositor's slots 1–3 retain the caches
and scene; incoming snapshots use RO/NX slot 0 only while copying.

Submission revokes a producer's RW/NX mapping before publishing its authenticated
frame and read-only grant. The compositor validates PID, app, geometry and
sequence, copies the viewport, releases its snapshot mapping/grant and presents
the composed scene. It acknowledges a current frame after presentation. A stale
frame is released and acknowledged so the client can retire its old lease;
a newer configuration precedes that older ACK.

Configuration messages carry screen dimensions, viewport size/origin and a
nonzero increasing epoch. Frame sequences combine that epoch with a per-epoch
counter. Old geometry, duplicate counters and retired PIDs cannot replace a
visible cache. The shell and Files have no scanout readback; frosted materials
sample their own immutable cache of the shared procedural wallpaper.

Input follows focused app identity and client-local coordinates. Pointer capture
preserves outside releases, and caption controls consume their own gestures.
Per-peer pending ACK/configuration/close state and a 32-event queue isolate a
slow reader. Adjacent compatible pointer moves coalesce. On queue overflow,
an explicit redraw/cancellation precedes the latest event, clearing stale
gestures instead of silently losing an individual release. A stalled client
can lose its obsolete input backlog; unbounded input retention is not provided.

## Desktop interaction

The compact Files app retains sidebar/history, optional Split view, clipboard,
native context menus, rename/create/delete, drag move and Ctrl-drag copy, and a
read-only text preview. Its checked provider uses the same durable filesystem
as the older hosted Files app. Nullify verifies overwrite/deletion across both
logical banks; SSD remapping, backups and independent copies are outside that
contract. See [Files](../userspace/apps/files/README.md) and
[Nullify](context-menus-and-nullify.md).

The user-space compositor supplies close, minimize, maximize/restore, fullscreen,
title dragging, shadow, frosted chrome and cursor. F11 toggles fullscreen;
Escape exits it; Alt+F4 closes focused Files. The Files launch chip, Super+E or
Super+Enter restores a minimized window or requests a new Files process.

Minimize configures a hidden 0×0 viewport and preserves PID, surface and app
model. Close removes its pixels, retires its resources and lets init reap it.
Relaunch waits for process retirement and peer closure, then starts a fresh PID
against the same app-2 disk data. Floating geometry survives these transitions.
Init can restart a crashed Files process while compositor and shell retain
their PIDs; automatic compositor/shell recovery is not implemented.

This remains one Files window and a CPU compositor. Edge resizing, arbitrary
GUI program launch, multiple app windows, tiling/workspaces, event-driven service
waits, GPU acceleration and dynamic memory growth remain future work.

## Verification and regression profiles

```powershell
zig build test-service-desktop test check desktop -j1 --summary all
zig build test-service-desktop test check desktop -Doptimize=ReleaseSafe -j1 --summary all
```

`test-service-desktop-<architecture>` runs persistent and acceptance variants;
each uses two fresh QEMU boots sharing one ordinary test data image. The host
drives real input, reads actual framebuffer pixels, checks both complete disk
banks and validates trusted kernel resource/PID telemetry. Its second boot
closes/relaunches Files twice while retaining server/shell identities. Normal
sessions stay running; F12 ends only the dedicated acceptance profile after
host evidence, requiring exact final ownership balance.

Logs, PPM/PNG captures, saved disk bytes and verification receipts live under
`zig-out/service-desktop-tests/<debug|safe>/<persistent|acceptance>/`.
[Verification results](service-desktop-verification.md) record completed gates.

The earlier fixed two-window demonstration remains `display`/`test-display`.
The older kernel-hosted Files app remains `test-desktop`, with interactive
`run-legacy-uefi-<architecture>` targets. These profiles preserve their original
tests without supplying evidence for the installed service desktop.
