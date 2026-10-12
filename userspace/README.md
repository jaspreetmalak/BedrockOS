# Bedrock userspace

This independent Zig package owns native init/test executables, their Bedrock64
ABI/runtime and application sources. It also reserves the future service tree.
Reusable public APIs remain in framework packages; future reusable internal OS
APIs belong under private frameworks.

```text
userspace/
  runtime/        Bedrock64 definitions, syscall wrappers and native ELF entry/linker
  apps/
    init/         separately linked native init and lifecycle/IPC workload
    lifecycle-test/ native IPC service and fault child from shared source
    io-test/      native file, pipe, path-spawn and exec acceptance
    exec-test/    same-PID replacement and explicitly granted pipe-writer child
    files/        protected Files client; sidebar/list, optional split and provider model
    network-test/ protected connected-UDP echo and authority acceptance
    wifi-test/    protected simulated/unavailable-radio control acceptance
    shell/        compact native wallpaper, Files launch bar and theme
  services/
    window-server/ portable single-window policy, currently called by the kernel host
```

[`apps/shell/`](apps/shell/README.md) uses the public
[AxisUI framework](../frameworks/public/AxisUI/README.md) for Bedrock's
Hyprland-inspired desktop. Future bundled applications such as a terminal and
settings will also belong under `apps/`. `apps/files/` already contains a
protected native ELF client. Service-process implementations such as display,
input and launch belong under `services/`; the window policy module is present,
but no standalone compositor/input/launcher service process exists yet.

The shell's source location expresses its intended role. It currently runs as
software rendering through a temporary kernel display host after boot checks.
That host launches Files with private user mappings and mediates its input,
drawing and app-2 container operations. Init, lifecycle-test, io-test, exec-test,
Files and the dedicated network/Wi-Fi probes are actual user-mode ELF executables.
The host implements one movable
Files window with close, minimize, maximize/restore and fullscreen controls;
a compositor process and multiwindow desktop remain future work. The preceding
[integrated verification](../docs/storage-and-files-verification.md)
passed the native Files workflow on each architecture in Debug and ReleaseSafe,
including abrupt shutdown and fresh-boot recovery of committed files. The
compact visual/control revision's own
[verification](../docs/files-ui-verification.md) passed on all three named QEMU
profiles in Debug and ReleaseSafe. Six workflows cover twelve boots,
twenty-four client starts and twelve checked close/resource-reclamation operations.
F11 toggles fullscreen, Escape exits it and Alt+F4 closes the focused client.
Minimize keeps that client alive; close retires its descriptors, context,
address space and owned frames before the bar or Super+E launches a fresh
instance over the retained disk data.

The temporary host supplies a validated supervisor framebuffer and caller-owned
AxisUI `Workspace` in BSS to `desktop_shell.renderWithWorkspace`. Borrowed view
arrays remain live through the synchronous call; scratch access is serialized
by the single-CPU boot path. The shell performs no physical-memory allocation.

The root build compiles init, service, fault, I/O, exec, Files, network and Wi-Fi ELF artifacts for each
required architecture. The kernel mounts their immutable embedded bytes in the
current app's read-only bundle. A full workspace install also writes
`zig-out/userspace/<arch>/{init,service,fault,io,exec,files,network,wifi}.elf`. These
programs use ReleaseSmall. Other acceptance fixtures retain the one-code-page
profile; Files uses its separate bounded desktop code/data/stack layout. The
known Wi-Fi probe is allowed at most four code pages, one data page and four
stack pages through trusted, validated `TaskMemory`; an ELF cannot choose a
wider layout. Actual payload pages are charged and reclaimed. Standalone
package builds accept `-Dtarget=<arch>-freestanding-none`; integer ARM/RV CPU
features and page bounds are enforced by the package build.

The Wi-Fi probe runs only in dedicated acceptance images: one uses the explicit
software test radio, and another checks the production unavailable status with
observation-only authority. Normal images have no physical Wi-Fi driver. See the
[Wi-Fi control contract](../docs/wifi-framework.md).

The [native process contract](../docs/native-processes.md) describes loading,
spawn/wait/exit, blocked mailbox operations and sleep/wakeup. The
[first Unix I/O profile](../docs/unix-io.md) adds app-scoped files, pipe
descriptors, path launch and same-PID exec. The current
[durable backend](../docs/persistent-filesystem.md) retains container files on a
dedicated image, while embedded bundles remain read-only overlays. Files provides
one default list and Home/Documents/Downloads sidebar, eight-location history
per pane, optional Split, Copy/Cut/Paste, double-click open, create/mkdir,
rename/delete and a copied read-only text preview. Save/Create/Cancel confirm
name editing by mouse; file contents are not edited by the preview. Its callbacks
carry host-selected authority rather than backend access. Next come
general app loading, standalone display/input services, automatic UI bindings
and broader executable layouts. Application sources, service processes and
reusable [private framework APIs](../frameworks/private/README.md) have separate
ownership. Process authority comes from private address spaces and checked
object/syscall rights. See the [desktop design](../docs/desktop-design.md) and
[application model](../docs/application-model.md).
