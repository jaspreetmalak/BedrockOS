# Unix processes and sandboxed applications

Bedrock uses a Unix-style modular monolithic kernel, with a private
Bedrock64 syscall ABI and an eventual POSIX source-compatibility layer. The
Hyprland-inspired desktop will build on protected processes and user-space
services. Native app bundles, private containers and mediated grants provide
the application model independently of the desktop's appearance.

This document specifies the target design. Portable security policy and
generational handle tables and resource accounting are implemented as portable
foundations. The earlier foundation stage passed its native tests in Debug and
ReleaseSafe, with interface probes for all three architectures. The
UEFI kernels additionally run two fixed user-mode tasks with private address
spaces and checked syscall dispatch. Native ELF processes, capability IPC and
an app-scoped VFS now build on those mechanisms. The first Unix I/O profile
adds private container files, immutable bundle execution, pipes and safe exec;
[integrated verification](unix-io.md) passed on all three UEFI references in
Debug and ReleaseSafe. The preceding desktop extension added a durable bounded
container backend, modern VirtIO input and a native protected Files ELF;
its [integrated verification](storage-and-files-verification.md) passed on all
three UEFI references in Debug and ReleaseSafe, including real input, checked
authority and fresh-boot recovery of committed Files data. The compact Files
redesign now adds sidebar/history navigation, clipboard actions and actual
close/relaunch with maximize/fullscreen controls. Its
[UI verification](files-ui-verification.md) passed on all three named QEMU
references in Debug and ReleaseSafe, with separate receipts for the revised
workflow.
Trusted installation, brokers and
desktop services remain future work, so this is not the complete app sandbox.
See [protected userspace](protected-userspace.md) for the temporary probe ABI
and its limits.

## Process and syscall model

The target process model owns a private virtual address space, an initial single
user thread, a kernel stack, credentials and a descriptor table. Current native
processes have distinct user roots and descriptor tables while serialized trap
handling uses permanent architecture-owned kernel stacks. UID/DAC credentials
remain future work; current file authority checks use trusted app identity.
Kernel pages remain
inaccessible to user code. File descriptors identify kernel-managed objects;
pipes connect processes through bounded kernel objects. The initial lifecycle
provides spawn, exec, wait and exit. Timer-driven user preemption and bounded
round-robin selection already follow protected entry in the boot fixtures;
native spawn/wait/exit and bounded path-based exec now run through Bedrock64.
The [Unix I/O contract](unix-io.md) describes its current storage and descriptor
boundaries. Files now uses a separate bounded desktop ELF layout; arbitrary
executable layouts and general Unix compatibility follow.

The private Bedrock64 ABI defines Bedrock's syscall numbers, argument rules,
errors and structure layouts. Each architecture gets a documented native entry
convention. A later libc/POSIX layer translates supported source interfaces to
that ABI. It does not promise existing Unix executable compatibility, Apple or
Mach interfaces, or POSIX certification.

UID identifies a user, PID identifies a running process, and app identity
identifies the installed application whose authority the process carries.
These values serve different purposes. A trusted launcher issues app identity
and the kernel retains it in process credentials. An app cannot select another
identity through its manifest, a syscall argument or its executable's path.
Multiple processes belonging to one app may share its identity while keeping
their own address spaces and descriptor tables.

## Default sandbox

Every app runs in a sandbox. There is no manifest opt-out and no UID-zero or
root bypass. Ordinary Unix ownership checks and app authority both apply;
passing either check alone does not authorize an operation. Trusted system
services receive narrowly defined authority from trusted system configuration,
not from an app-controlled exemption.

An app starts with:

- A private read/write data container, isolated from other app identities.
- Its own read-only installed bundle.
- Explicitly selected read-only shared runtime objects.
- The initial descriptors and grants deliberately supplied by its launcher.

The remaining user's files, other apps' containers, devices and network resources
require explicit authority. A manifest requests entitlements; it does not grant
them. Effective entitlements are the intersection of those requests and trusted
grants. Unknown, unsupported or ungranted requests grant no access. Changing a
manifest or launching another executable cannot raise authority.

Shared runtime selection is explicit rather than general access to a system
directory. Bundle content remains read-only to the app even when its private
container is writable. Installation, bundle identity verification and trusted
grant storage need their own implementation before untrusted applications can
be admitted.

## Object grants and handle checks

A trusted broker or file picker can return a handle to a user-selected file or
other object, with explicit read, write or operation rights. The grant attaches
to that resolved object; a path-prefix match is not authorization. Symlinks,
renames and similarly named paths cannot turn the grant into access to a
different object. Any directory grant must describe the allowed operations and
object scope explicitly.

Descriptor and capability tables use bounded slots with generation numbers.
The kernel checks slot generation, object type, required rights and applicable
policy when an operation uses a handle. A closed or recycled slot cannot make
an old handle refer to a newly installed object. Guessing a descriptor number
does not create authority. Tokens are local to the selected process table;
they are not globally unique identities or secrets. Transferring an object
requires trusted policy checks and a new receiving-table entry, not copying
the raw token into another process.

Duplicating or transferring a handle can preserve or reduce rights, never add
them. A child process receives an explicit subset of its parent's authority;
spawn and exec cannot acquire extra grants. The receiving process's authority
ceiling also applies. Descriptor inheritance and exec retention are explicit.
The first exec profile closes all old file, pipe and IPC/stdout handles and
issues fresh stdout; selective retention/close-on-exec flags are future work.
These rules are enforced by syscall and object operations, not only by the
launcher or manifest parser.

The current portable files live in `kernel/src/security/`: `sandbox.zig`
intersects requested/approved permissions and checks trusted object provenance;
`handles.zig` validates table tokens, object kinds and rights; `quotas.zig`
tracks bounded resource budgets. They do not establish object lifetimes,
resolve paths or enforce memory protection on their own. Process, VFS and syscall
code select the current table, authenticate grants and serialize access.
The current VFS inserts the trusted app identity into backend paths and
rechecks owner/domain metadata and rights on file operations. `/bundle` is
read-only and executable only through immutable marked nodes; `/container` is
private read/write storage for the current app identity. Children of one app
share that identity and container, with separate process descriptor tables.
The durable backend retains 32 nodes, at most 4,096 bytes per mutable file and
live and staged snapshots in BSS. Two CRC-protected banks on a dedicated 4 MiB image
retain committed container data across mounts. A validation failure leaves the
namespace unchanged; uncertain storage I/O can preserve a complete old or new
snapshot and requires fresh-mount recovery. See
[persistent storage](persistent-filesystem.md). This is not a general disk format
or a trusted installation mechanism.

## Application bundle

The planned native bundle is an ordinary directory with a `.app` suffix:

```text
Example.app/
  Contents/
    Manifest.toml
    Executables/
      x86_64/main.elf
      arm64/main.elf
      riscv64/main.elf
    Resources/
```

The manifest will describe app metadata, supported native executables, shared
runtime requirements and requested entitlements. A trusted launcher selects
the current architecture's executable and checks the installed identity and
grants. The directory layout does not authorize access or imply compatibility
with an Apple app bundle. Native ELF loading now works from immutable
kernel-embedded bundle overlays; manifest parsing, installation and persistent
bundle storage remain future work.

## Desktop direction and inspiration

The eventual desktop takes its interaction direction from
[Hyprland](https://hypr.land/) and its [official project](https://github.com/hyprwm/Hyprland):
tiling first, keyboard controls, workspaces and optional floating windows.
Gaps, rounded focused borders and a compact bar make focus and layout visible.
This is design inspiration, not a Hyprland port or a promise of Wayland, Linux
or external API/binary compatibility.

The native UI framework is implemented from scratch in Zig. Public AxisUI,
under `frameworks/public/AxisUI/`, supplies declarative `View`, `Text`, `HStack`,
`VStack`, `ZStack`, `Spacer`, modifiers and software rendering. Private
frameworks hold reusable internal OS APIs and service mechanisms. Private
[NetworkCore](../frameworks/private/NetworkCore/README.md) implements the first
bounded packet stack; public [NetworkKit](../frameworks/public/NetworkKit/README.md)
provides connected UDP APIs through a checked runtime provider. These modules
retain mandatory network entitlements and task-local socket grants.
Desktop composition, themes
and the compact launch bar live in [`userspace/apps/shell`](../userspace/apps/shell/README.md),
using the `desktop_shell` module and public AxisUI. Public and private describe
API support and distribution, not sandbox authority.
Linking a framework or using its directory does not confer filesystem, display,
input or process rights. AxisCore and additional native service frameworks remain
planned work.

`userspace/apps/` organizes application sources, including the shell.
`userspace/services/` is the source home for future display/compositor, input,
launch and broker processes. The window-server module supplies portable policy
to the current kernel host; none of those standalone service processes exists yet.
Source placement is separate from installed app bundles and service paths. The
directory move does not implement user-space execution: the shell still runs
through the privileged kernel desktop host.

The current normal UEFI graphical path launches a separately linked protected
Files ELF after the boot checks. Files carries trusted app identity 2 and sees
its own read-only bundle and durable private container. Its provider callbacks
adapt checked syscalls; paths cannot select another identity, and the client
receives neither raw storage nor the physical framebuffer. The default client
uses one file list with a Places sidebar for Home, Documents and Downloads.
Back/Forward/Up and an eight-location history per pane support navigation;
Split optionally shows the second pane. Copy/Cut capture a bounded source path
and Paste resolves it through checked VFS operations in the current location.
Directory/file double-click opens navigation or a copied read-only preview.
Rename and new-file/folder name editing have mouse Save/Create/Cancel controls
as well as keyboard confirmation. Drag release moves, and held-Ctrl drag copies.

The temporary kernel display host executes the shell renderer and single-window
policy, handles modern VirtIO input and clips client drawing. Caption controls
support close, minimize, maximize/restore and fullscreen. F11 toggles fullscreen,
Escape leaves it, and Alt+F4 closes the focused client. Fullscreen retains a
caption exit strip. Minimize preserves the running client; close returns to a
trusted kernel continuation, destroys its context and address space, releases
owned frames and closes descriptors. Files launch from the compact bar or
Super+E then creates a fresh protected client; committed app-2 files remain on
disk. Input reaches only the focused client. AxisUI
supplies explicit revision state, packed events and bounded queues/hit tests;
automatic bindings and reconciliation remain future work. There is no standalone
user-space compositor, GPU renderer or multiwindow/tiling runtime yet.
Successful graphical startup replaces boot text; normal boot-log retention and
a diagnostic viewport remain future work.

Next come protected display/compositor IPC, service ownership and installed
`.app` launching beyond the trusted embedded catalog. Future window,
compositor and resource-broker services use explicit IPC and object grants.
An app's access to a surface or input stream cannot authorize access to another
app's memory, surfaces or private files. The mandatory sandbox, private containers
and native bundle contract above remain unchanged. See
[desktop design](desktop-design.md) for the current host boundary and runtime
acceptance plan.

## Acceptance before claiming isolation

Portable tests can establish policy intersections, rights attenuation and stale
handle rejection. Actual sandbox acceptance requires user-mode workloads on
x86-64, ARM64 and RV64:

- App A cannot read or write app B's memory or container, or kernel memory.
- Invalid pointers, denied descriptors and forbidden syscalls fail without
  changing protected objects.
- UID-zero credentials, forged identity, modified requests, duplicated handles
  and child execution cannot expand authority.
- A selected-object grant exposes only its approved object and rights, including
  after symlink or rename attempts.
- A fault in app A is contained while app B and the kernel keep running.

Protected paging, checked user/kernel transitions and timer-preempted saved
contexts now support [native ELF init, process lifecycle and blocking IPC](native-processes.md)
on the UEFI references, alongside the retained isolation fixtures. The first
profile uses immutable RAM-mounted executables, private address spaces,
attenuated handles and one shared app-tree budget. The first app-scoped VFS,
pipe and exec mechanisms are implemented, alongside a bounded durable container
and protected Files client; general app loading, persistent
service launch and trusted broker grants remain next steps. The current
backend supports scoped rename/copy/remove but has no symlinks or external object
grants, so the corresponding full sandbox
acceptance cases remain pending.
The current Files window uses that foundation and reference VirtIO input. It has
its own bounded descriptor table and frame ownership; full app-tree accounting
for that desktop profile remains separate work. Its integrated acceptance is
distinct from complete service/sandbox qualification. The compact revision has
its own completed workflow record; these checks cover one kernel-hosted window
and do not qualify arbitrary app admission or physical hardware.
See the [roadmap](roadmap.md).
