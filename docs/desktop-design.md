# Bedrock desktop direction

Bedrock's desktop direction combines a compact, Hyprland-inspired dark pastel
theme with familiar file-manager navigation and native window controls. The
inspiration comes from [Hyprland's official site](https://hypr.land/) and
[project repository](https://github.com/hyprwm/Hyprland). Bedrock is building its
own desktop on its own kernel and application model. This is not a Hyprland
port, and it promises no Wayland, Linux or external API/binary compatibility.

## Interaction and visual direction

- The current window floats above a charcoal wallpaper with a quiet border,
  subtle shadow and rose, cream and blue caption controls.
- Frosted window backgrounds, navigation and the launch bar use AxisUI materials
  over an immutable blurred wallpaper cache. Text and controls remain crisp.
- A 36-pixel bar contains the actual Files launcher and a small architecture
  label. Decorative workspaces, simulated system status and debug panels are
  absent from the current desktop.
- Files defaults to one list with Places, breadcrumbs, back/forward/up navigation
  and a single 40-pixel header with Split/More. File actions appear in native
  background/item right-click menus and More; no mutation command strip remains.
- Mouse close, minimize, maximize/restore and fullscreen controls are independent
  actions. F11 toggles fullscreen, Escape exits it, and Alt+F4 closes Files.
- Tiling, multiple apps and workspaces remain future service/compositor work.

Sizes, colors, layouts and bindings should remain adjustable without changing
app authority or kernel policy. The initial native design uses charcoal
surfaces, muted pastel accents, mixed-case text and small reusable native icons.
AxisUI shares the font's six-pixel advance and ten-pixel line height between
measurement and drawing; filenames retain their case.

## Native UI and shell architecture

Bedrock builds its UI framework from scratch in Zig. `frameworks/public/AxisUI/`
provides the app-facing declarative model: `View`, `Text`, `HStack`, `VStack`,
`ZStack`, `Spacer` and layout/style modifiers. It computes native view layout and
draws through a software renderer. A pixel surface uses caller-owned storage;
a command surface sends clipped drawing to supplied callbacks. The initial
public API is experimental. Applications compose views;
they do not receive unrestricted access to another app's surface or the display.

Text and child-view slices are borrowed and must remain valid and unchanged
through synchronous rendering. `Workspace` supplies bounded caller-owned layout
and clipping scratch. `AxisUI.renderWithWorkspace(surface, workspace, view)`
uses that storage without allocating. Initialize scratch as `undefined` and keep
exclusive access through the call; its contents are transient implementation
state. The convenience `render` uses stack scratch and requires sufficient
caller stack space.

[`userspace/apps/shell`](../userspace/apps/shell/README.md) composes the desktop with AxisUI.
It owns the wallpaper, theme and compact launch bar. The Zig module
is `desktop_shell`, with compile-probe artifact `bedrock-desktop-shell`.
These visual components are desktop code; AxisUI supplies reusable app-facing
primitives.

`userspace/apps/` contains application sources, including this shell.
`userspace/services/` is the home for future display/compositor, input, launch
and broker processes. Its window-server module currently supplies portable
single-window policy to the kernel host; no standalone service process exists.
Source paths are independent of installed bundles and service paths. Moving the
shell source does not create a user-space process: its renderer still runs
through the temporary kernel display host.

`frameworks/private/` is reserved for reusable internal OS APIs and service
mechanisms, such as future display IPC clients, surface-handle operations and
internal broker interfaces. Private NetworkCore now supplies reusable IPv4/UDP
packet mechanisms behind the public NetworkKit/runtime boundary; see the
[network framework](network-framework.md). Display IPC remains future work.
Desktop themes, bars and view composition stay in the shell package.

Public and private describe the API, support and distribution boundary. A private
directory is not a security boundary. Shell and app processes must use
private address spaces, checked capability syscalls and explicit surface/input
grants. AxisUI and the shell composition remain usable without kernel or firmware
imports. The current kernel hosts the shell renderer and window/display policy.
Its bridge adapts the validated supervisor framebuffer into an AxisUI `Surface`
and calls the shell's wallpaper and bar renderers with layout scratch retained
in kernel BSS. It builds a separate downsampled blur cache from wallpaper alone
before painting bars, windows or the pointer, then retains it across redraws.
The single-CPU boot path owns this scratch exclusively, keeping the large layout
plan off the guarded execution stack. Framework code takes no ownership of the
view tree or surface.

AxisCore and additional native service frameworks are future work. Their APIs
and implementations will follow concrete process, IPC and object-lifetime needs;
the current framework milestone does not claim those services exist.

## Current protected Files desktop

| Layer | Scope | What it demonstrates |
| --- | --- | --- |
| Kernel framebuffer console | Startup and fault diagnostics | Existing memory, isolation, lifecycle and timer checks |
| Public AxisUI | Declarative views, layout, software drawing, events and explicit revision state | Pixel and command surfaces, bounded queues/hit tests and clipped cursor |
| `userspace/apps/shell` | Desktop background, theme and launch bar | Charcoal/pastel appearance with an actual bounded Files launch target |
| `userspace/apps/files` | Separately linked protected native ELF | Single list/sidebar, optional Split, clipboard and text preview through checked authority callbacks |
| Current kernel display host | Modern VirtIO input, clipped drawing, focus and window policy | Movable Files window with close, minimize, maximize/restore and fullscreen |
| Future standalone compositor | Independent app surfaces and display IPC | Multiple protected application windows and service ownership |

Files begins in `/container/Documents` and `/container/Downloads` under trusted
app identity 2. User paths cannot choose another app ID. The app owns no raw
device or framebuffer mapping: its provider adapts checked file syscalls, while
AxisUI command callbacks submit drawing that the kernel clips to client bounds.

Places provides Home, Documents and Downloads. Each pane has a bounded history
of eight locations. Copy and Cut record a copied source path; Paste transfers to
the current folder through the checked provider. Context menus select their
targeted row, disable unavailable/read-only actions and activate only on a
matched left press/release. Outside clicks, Escape, keyboard navigation, refresh
and geometry changes dismiss stale menu targets. Create/Save/Cancel buttons and
Enter/Escape operate name editing. Up stops at the app's home boundary.

Dragging onto a Places folder, a list folder or the other split pane moves once
on valid release. Ctrl at drag start or release selects copy. Invalid drops
leave files unchanged. Double-click, Enter or Open displays a copied read-only
preview of the first 512 bytes; Escape or Back closes it. Names and text input
are ASCII in this first font/editor profile. Failures use plain messages;
the application neither retries mutations nor silently replaces destinations.
Ordinary Delete removes the namespace entry. The separate red
“Nullify (overwrite + delete)” item is file-only and requires a matched menu
release, with no extra confirmation or hotkey. Its protected syscall overwrites,
flushes and exactly reads back both complete logical storage banks. Success
shows “File nullified in Bedrock”; failure stays visibly incomplete and may
require fresh-mount recovery. Matching preview/clipboard caches are cleared.
SSD remapping, host backups and independent copies remain outside its scope.
See [context menus and Nullify](context-menus-and-nullify.md) for the precise
storage and authority contract.

Modern VirtIO block and keyboard/tablet devices supply the reference QEMU paths
on x86-64, ARM64 and RV64. The durable backend retains 32 nodes and 4,096 bytes
per mutable file, with two CRC-protected snapshots on a dedicated 4 MiB image;
live and staged snapshots remain in BSS. Bundles are immutable embedded overlays.
See the [filesystem contract](persistent-filesystem.md) for commit ordering and
fresh-mount recovery after uncertain I/O.

The title bar moves the single window. Minimize preserves its live client state;
Close returns to the trusted kernel continuation before releasing descriptors,
context, private tables and payload frames. The host verifies that allocated
pages return to the pre-launch baseline. The Files chip or Super+E restores a
minimized window or launches a zeroed fresh client against the same disk.

Maximize fills the work area; fullscreen fills the display and retains a
32-pixel caption strip with an exit button. Restoring returns to the saved
floating geometry or preceding mode. Geometry changes discard old queued
coordinates, cancel pointer capture and request a native redraw event. Paint
from obsolete dimensions is ignored. Redraw preserves selection, history,
clipboard, edited names and preview state.
Input routes only to the focused client, retaining pointer capture through a
release outside client bounds. The client redraws on explicit model revisions.
Automatic bindings/reconciliation, multiple windows, real tiling/workspace
switching, a user-space compositor and GPU acceleration remain future work.
The graphical path follows the existing boot checks; a desktop image does not
replace them or establish the complete application sandbox.

## Native desktop sequence

1. Native AxisUI layout/rendering, shell composition, bounded input/state
   primitives and a protected Files client are implemented. Their integrated
   persistence/input/window verification passed on all three UEFI references
   in Debug and ReleaseSafe. The compact Files and window-control extension is
   recorded separately in [Files UI verification](files-ui-verification.md).
   The newer menu/Nullify revision separately passed native/compile/UEFI checks
   and all six Debug/ReleaseSafe QEMU workflows, including twelve independently
   inspected logical banks and reboot absence, as recorded in
   [the milestone record](context-menus-and-nullify.md).
2. Move display ownership, input routing and window management into protected
   service processes with checked surface IPC. Run the shell as a protected app
   instead of through the kernel display host.
3. Add installed bundle launching and multiple native app windows while retaining
   per-app file, surface and input authority.
4. Add event-driven state bindings and reconciliation so native view updates
   preserve identity and do not require rebuilding unrelated state.
5. Add native `.app` windows, launch, tiling, keyboard focus, workspaces and an
   optional floating mode once process loading and display/input ownership work.
6. Extend the current software wallpaper frost to independently composited app
   surfaces, damage tracking and animation as the display services develop.

The current [frosted materials](frosted-materials.md) sample a wallpaper cache;
they do not capture other applications. The framework offers an integer-only
blur and tint with caller-owned storage. Protected Files asks for material
rectangles through a checked syscall, retaining its existing client bounds.

The current runtime desktop uses a software framebuffer renderer. It must not
depend on GPU acceleration or advanced visual effects being available. Rendering
mechanisms and driver support remain separate engineering milestones.

A native renderer must encode the handoff's explicit framebuffer color masks,
respect scanline stride and byte coverage, and clip all drawing. Integer drawing
keeps the current RV64 execution contract intact.

A successful desktop startup replaces the graphical startup text. Failed startup
checks stop before it; a renderer failure clears the display and reports its
new fault through the diagnostic console. Existing serial smoke acceptance logs
retain the full check output from those runs. Retaining the normal boot log and
providing a diagnostic viewport remain future work.

## App authority remains mandatory

The [application model](application-model.md) stays unchanged: native `.app`
bundles, private containers, read-only installed content, explicit shared runtime
access and brokered object grants. There is no app sandbox opt-out or root bypass.
Desktop appearance and window placement cannot grant extra filesystem, device,
network or process authority.

A display-surface handle must authorize only its own surface, never another
app's memory or content. The current host scopes Files drawing and focused input;
future service processes must retain that policy. Launchers and file pickers
remain brokers with explicit authority;
they do not make requested entitlements into grants. These services and complete
resource isolation remain future work, beyond the current bounded processes.

## Acceptance boundaries

The current implementation covers native view layout, clipped pixel/command
rendering, a protected Files ELF, durable private files and reference VirtIO
input. Its [verification record](storage-and-files-verification.md) confirms
fresh Debug/ReleaseSafe native checks, both 18-configuration boot matrices and
six native desktop workflows: all three architectures in both modes, with two
normal boots per workflow. Each checks startup authority, rename, drag move,
held-Ctrl copy, delete, mkdir, create, preview, title drag and minimize/reopen.
The first QEMU process is killed abruptly; independent CRC/generation/content
and owner readback checks committed Files data before and after a fresh boot.
This covers held-Ctrl interaction and latched client intent, not a total ordering
guarantee for arbitrarily fast chords across independent input-device queues.
Layout and renderer
tests must cover constrained sizes, modifier behavior, framebuffer stride and
color masks, clipped edges and untouched bytes outside the drawing bounds.
QEMU acceptance must exercise actual input and mutations, valid/invalid drops,
error presentation, minimize/reopen, and fresh-boot recovery of committed Files
data after the existing boot workload. No physical hardware is validated by
these checks.

Before claiming the complete service-based desktop, the same native workflow
must run on x86-64, ARM64 and RV64 UEFI: init starts the services, the launcher selects the correct
native bundle executable, and input follows the focused app across workspace
and layout changes. A failed app must leave the other apps and desktop service
running. Desktop services must preserve the application's granted authority.

Before claiming per-app composition, workloads must prove that one app cannot
read or alter another app's surface or receive its input without an explicit
grant. Animation and blur are subsequent rendering acceptance checks, not
evidence of application isolation. See the [roadmap](roadmap.md) for the
surrounding runtime milestones.
