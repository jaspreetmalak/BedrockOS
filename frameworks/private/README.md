# Private frameworks

This directory provides reusable internal OS APIs used by Bedrock's own
bootloader, kernel, driver modules, services and applications.

```text
frameworks/private/
  DriverKit/    shared versioned driver ABI and bounded loader/linker tools
  AnvilCore/    trusted texture execution, resource lifetimes and graphics validation
  NetworkCore/  trusted packet/endpoint and Wi-Fi controller mechanisms
```

[DriverKit](DriverKit/README.md) supplies the shared versioned C driver ABI,
bounded ELF loader and linker tools, and opaque memory-token records.
Hardware-specific chipset/station implementations, module entry points and
boot ownership remain under `../../drivers/`. Modules currently execute with
kernel privileges; separate packaging and framework placement do not provide
process isolation.

[NetworkCore](NetworkCore/README.md) is the first implemented private framework:
bounded Ethernet/ARP/IPv4/UDP packet mechanisms,
connected endpoint queues, transport callbacks and a bounded Wi-Fi controller
used by the kernel runtime.
Its source directory grants no execution or device privilege.

[AnvilCore](AnvilCore/README.md) implements Anvil's trusted CPU graphics provider:
bounded texture imports, read-only access, generational tokens, prevalidated
fill/copy commands and genuine completion fences. The essential boot backend
lives under [`drivers/gpu/`](../../drivers/gpu/README.md). Display-service identity,
surface grants and lease checks remain in the kernel broker before dispatch.
The public [Anvil](../public/Anvil/README.md) API imports no kernel code. GPU
hardware drivers, optional GPU module loading and general app GPU contexts are
future work; the current backend reports software execution.

Future shared display-service IPC clients, surface-ownership APIs and broker
helpers can live here once their services exist. Internal interfaces may evolve
without the compatibility promises of the public application SDK.

The desktop's views, theme, bar and workspace composition live in
[`userspace/apps/shell/`](../../userspace/apps/shell/README.md). Reusable
application-facing UI primitives live in [AxisUI](../public/AxisUI/README.md).
The application-facing network client lives in
[NetworkKit](../public/NetworkKit/README.md); packet parsing and driver adaptation
remain behind checked socket syscalls. The preceding actual NIC/ELF milestone passed on all
three QEMU architectures in both optimization modes, as recorded in the
[network milestone](../../docs/network-framework.md). This remains a kernel-hosted
bounded UDP mechanism; no standalone network service or physical NIC qualification
is claimed.

Wi-Fi observation/control calls use separate entitlements and bounded wire
records. NetworkCore's explicit test radio validates controller/broker execution;
normal kernels retain the physical-driver-unavailable path. Neither backend
selection nor directory placement grants an app device authority. See the
[Wi-Fi control foundation](../../docs/wifi-framework.md).

Public/private describes API support and distribution. Service authority still
requires protected address spaces and checked syscall/object rights.
