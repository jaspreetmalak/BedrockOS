# Native Bedrock64 runtime

The independent `userspace/` Zig package exports `bedrock64` from
`runtime/src/abi.zig` and `userspace_runtime` from `runtime/src/root.zig`.
The ABI file is the single shared
definition used by the kernel and native programs. Runtime calls use x86-64
`int 0x80`, ARM64 `svc #0` or RV64 `ecall`, with three integer arguments and a
raw 64-bit return. Use `abi.isError`, rather than the sign bit, to distinguish
errors from opaque handles.

The package supplies `bedrock-user-init`, `bedrock-user-service`,
`bedrock-user-fault`, `bedrock-user-io`, `bedrock-user-exec`,
`bedrock-user-files`, `bedrock-user-network` and `bedrock-user-wifi` artifacts.
`build_support.zig` builds them from the real application sources under `../apps/` without a
kernel dependency. Their native entry assembly establishes the C call boundary;
RV64 also establishes its global pointer. These are static ELF64 `ET_EXEC`
images, not embedded kernel instruction fixtures.

The package always compiles user programs in `ReleaseSmall`, independently
of the kernel's optimization mode. The acceptance-profile linker bounds code and
read-only content to one RX page at `0x2000000000` and data/BSS to one RW page at
`0x2000001000`.
The kernel supplies an unmapped guard at `0x2000002000` and a RW stack page at
`0x2000003000`. The fault artifact has a four-byte syscall probe at the end of
its full RX page; init and service retain their smaller code images. Code/data
overflows fail linking. ARM64 excludes FP/NEON and uses
strict alignment; RV64 uses integer IMAC without F/D. There is no TLS, dynamic
linker, libc, argv/environment layout, POSIX binary ABI or general allocator.
Files uses a separate trusted desktop profile: at most 128 KiB RX code/read-only
content at `0x2000010000`, 1 MiB RW/NX data at `0x2000040000`, and 64 KiB RW/NX
stack at `0x20001e0000`, with an unmapped preceding guard. This bounded profile
does not let a client choose arbitrary mappings.
The known Wi-Fi acceptance image uses the same validated `TaskMemory` mechanism
with a trusted cap of four code pages, one data page and four stack pages.
It is selected only for the kernel's dedicated probe path; app-supplied ELF
metadata cannot widen the layout. Other fixtures retain their one-page bounds,
and payload quotas/teardown use the actual number of pages.

The wrappers additionally expose app-scoped file open/read/write/seek/close,
path spawn and exec, and nonblocking pipes with pipe-only rights-attenuating
duplication and explicit child-writer grants. `exec` preserves PID and trusted
profile, closes old descriptors, and enters a fresh zeroed image; failure leaves
the caller's old image usable. Directory listing, mkdir, copy, rename and remove
now support the Files client; general stat and POSIX interfaces remain future work.
`network.provider()` supplies the public NetworkKit connected-UDP adapter.
`udp_open` (`0x140`) reads an eight-byte `UdpConnect` with IPv4 address, port and
zero reserved field; the other two arguments must be zero. `udp_send`/`udp_receive`
(`0x141`/`0x142`) take a task-local socket token, buffer pointer and capacity or
length at most 256. Empty datagrams return zero; an empty receive queue returns
`again`. Short or invalid receive buffers retain the queued datagram. Existing
`close` releases the socket; successful exec, fault and process exit release its
authority too. The kernel requires explicit `network_client` approval; public
framework linkage supplies no network permission. See the
[network framework](../../docs/network-framework.md) for actual scope and checks.

`wifi.provider()` adapts `networkkit.wifi.Radio` to checked Wi-Fi calls
`0x160`–`0x165`: status, scan start/read, join, disconnect and enable/disable.
Their fixed status/scan/join records are 64/720/80 bytes. The pure wire decoder
rejects unknown tags, noncanonical flags, reserved bytes and inactive/unused
fields. Status/scan preflight complete writable buffers; joins copy and validate
bounded requests and volatile-clear explicit credential copies on every return.
Observation requires `wifi_observe` or `wifi_control`; changes require
`wifi_control`. `network_client` grants neither permission. Normal kernels report
unavailable. Dedicated tests exercise an explicitly simulated radio and the
production observer-only unavailable path, without RF or WPA authentication.
See the [Wi-Fi control foundation](../../docs/wifi-framework.md).

`nullify` (`0x135`) takes a readable canonical path pointer, its byte length and
a zero reserved third argument. The kernel rechecks trusted app identity,
private-container write authority and mutable file kind; bundles and directories
are rejected. Success follows overwrite/flush/exact readback of both complete
logical storage banks. An I/O failure can retain old data or a committed deletion
and poisons the live backend until fresh mount. This is a scoped Bedrock logical
file operation, not a hardware sanitization or independent-copy guarantee. See
[context menus and Nullify](../../docs/context-menus-and-nullify.md).
See [Unix I/O](../../docs/unix-io.md) for exact bounds and ownership.

These programs exercise launch, child waiting, timer sleep, yield, attenuated
IPC, files, pipes and executable replacement. They are acceptance applications, not a complete
init system, filesystem service or desktop runtime. The kernel's temporary
native shell renderer remains kernel-hosted. Files is a real protected ELF;
its command surface invokes checked rectangle, frosted material and presentation calls,
and its event call receives only host-routed input. The kernel handles modern
VirtIO devices and window policy until standalone display/input services exist.
`ui_material` (`0x154`) accepts a readable 32-byte `DrawMaterial`: four `u32`
client coordinates/dimensions, `u32` RGB tint, `u32` opacity (0 through 255),
and a zero `u64` reserved field. Other syscall arguments must be zero. The host
clips to the current client and samples its immutable wallpaper blur cache.
Malformed requests are rejected before drawing; clients receive no framebuffer
address or readback. See [frosted materials](../../docs/frosted-materials.md).
`ui_event` blocks for a routed event. `ui_pending` (`0x155`) returns the next
already routed event or zero without blocking; all arguments must be zero.
Files handles at most 32 events per paint, reducing repeated frost work while
retaining event order and an explicit bound before the next presentation.
See [Files](../apps/files/README.md) and the [desktop contract](../../docs/desktop-design.md)
for the integration scope. Its
[verification record](../../docs/storage-and-files-verification.md) covers
actual checked syscall authority, input, file/window operations and reboot
recovery on all three UEFI references in Debug and ReleaseSafe.
The newer clean-header, native context-menu and Nullify revision has its own
[completed acceptance](../../docs/context-menus-and-nullify.md): Files 31/31 and
filesystem 35/35 native tests per mode, 172/172 root build steps in Debug and
ReleaseSafe, and six real QEMU workflows. Checked syscall authority, complete
logical-bank inspection, a presented result frame and fresh-boot absence cover
all three architectures in both modes.
