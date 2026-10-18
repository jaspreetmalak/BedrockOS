# MT7922 driver module

`src/entry.zig` is the entry of a separately linked ELF64 PIE driver image. Its
three metadata notes match `14c3:0616`, `14c3:7922`, and `0b48:7922`. Matching a
note selects the package; the driver still checks the actual subsystem,
revision, firmware, board profile, memory cache policy, and DMA platform before
hardware takeover.

The kernel and module share the versioned C driver ABI in private
[`DriverKit/src/abi.zig`](../../frameworks/private/DriverKit/src/abi.zig).
DriverKit also supplies bounded ELF loader and linker tools; this module's
hardware-specific implementation remains under [`drivers/`](../).
The kernel owns physical allocation tickets and maps each module's opaque token
to its own allocation.
`src/memory_proxy.zig` exposes that service to the driver through C callbacks.
Allocator owners, transport objects, Zig error values, and Zig slices remain
inside their respective linked images. Radio events copy BSS records and
Ethernet bytes into caller-owned ABI records.

`src/boot.zig` retains the native platform, transport, firmware client, country
authority, entropy generator, and station binding in this module's writable
storage. The shared chipset and station implementation lives in
`drivers/wifi/src`; this code is linked into the driver image. Normal kernel
radio controls use only `kernel/src/core/wifi_module_adapter.zig` and the
versioned DriverKit interface. There is no second kernel boot owner tree.

This first module runs with kernel privilege. Separately packaging it does not
provide process isolation. Its native hardware provider remains the explicit
x86 UEFI MT7922 port. ARM64 and RISC-V64 module binaries compile and retain the
same ABI, but report `UnsupportedNativePlatform` if physical setup is attempted.

The loader retains module code and writable state after retirement. Failed DMA
quiescence retains allocation ownership as well. Unloading requires revoking
every callback and proving that the device no longer accesses those allocations.

Native checks cover bootstrap validation and absence without hardware access,
allocator token generations and rollback, copied radio events, malformed ABI
records, retirement, and a synchronous Ethernet reply after the module poll
callback returns. These checks do not establish a physical Wi-Fi connection.

The retained direct binding lifetime tests live under `drivers/wifi/tests`.
They protect station reset and terminal-state behavior without putting chipset
implementation imports back into normal kernel runtime code.
