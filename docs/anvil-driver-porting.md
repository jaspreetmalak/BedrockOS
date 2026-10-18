# Anvil and GPU driver porting

Anvil separates the graphics API from the device that executes it. Applications
should keep the same API when Bedrock gains another graphics driver; each driver
must still implement and qualify the specific hardware it supports.

```text
frameworks/public/Anvil/       portable graphics types, commands and provider API
frameworks/private/AnvilCore/  checked execution, ownership and backend mechanisms
drivers/gpu/                  device protocols and hardware implementations
kernel/src/core/              privileged resource and display integration
userspace/services/display-server/  composition, windows and presentation policy
```

AxisUI remains the application UI framework. Anvil supplies rendering mechanisms;
window layout, application views and desktop appearance stay in userspace.

## Initial backend

The initial runtime backend executes on the CPU and presents to the framebuffer
retained from firmware. The kernel routes presentation through Anvil only after
the existing display broker has checked service identity, permissions, surface
ownership, mapping state and the requested region. Existing surface leases and
read-only snapshots remain the authority boundary.

This establishes an executable graphics framework while retaining a useful
fallback. It does not claim GPU acceleration, a native GPU driver, vsync or a
particular frame rate. Anvil v0.1 does not implement shaders, 3D rendering,
compute kernels, Vulkan, OpenGL or a shader compiler. Adding an API directory or
a command encoder does not make those features available.

## First device backend: VirtIO GPU

VirtIO GPU is a practical reference device for driver development in QEMU. Its
device ID is **16**. Follow [OASIS VirtIO 1.3, section 5.7](https://docs.oasis-open.org/virtio/virtio/v1.3/virtio-v1.3.html)
for the device protocol and the transport requirements in section 4. The first
device milestone should be an actual scanout path:

1. Discover a supported, mapped transport and negotiate supported features.
2. Create control queue 0 and cursor queue 1, with owned DMA buffers.
3. Read display information and choose a supported scanout and geometry.
4. Create a 2D resource and attach checked guest-memory backing to it.
5. Select that resource with `SET_SCANOUT`.
6. Transfer changed pixels with `TRANSFER_TO_HOST_2D`, then `RESOURCE_FLUSH`.
7. Validate responses and fences; exercise cleanup, reset and failure paths.

The control queue can return commands before processing finishes. Requests that
need proof of completion must use `VIRTIO_GPU_FLAG_FENCE` and validate the
returned fence identity. The cursor queue is a separate fast path. Cursor images
use 64 by 64 resources whose population must finish before cursor updates.
These are device completion rules, not proof of a display refresh or vsync.
[VirtIO GPU operation and fencing](https://docs.oasis-open.org/virtio/virtio/v1.3/virtio-v1.3.html).

Basic VirtIO 2D provides resource transfer and display operations while Bedrock
still renders pixels in software. Accelerated rendering requires an implemented
and negotiated rendering backend. QEMU distinguishes its default 2D backend
from VirGL and rutabaga; enabling a host option alone does not implement the
guest driver. [QEMU VirtIO GPU documentation](https://www.qemu.org/docs/master/system/devices/virtio/virtio-gpu.html).

Protocol encoders and host tests are useful foundations. Runtime support needs
real device negotiation, DMA, command completion and visible pixels under QEMU;
cross-compiling a driver is a separate result. Qualify x86_64, ARM64 and RISC-V64
on named platforms rather than inferring support from the CPU architecture.

## Optional driver modules

GPU implementations belong under `drivers/gpu/`. Bedrock's current optional
DriverKit loader is specific to Wi-Fi: its ABI descriptor, firmware selection,
module filename and kernel dispatch currently expect the radio class. A GPU
source directory is not yet an installable GPU module.

Before optional GPU packages can use that loader, implement:

- A versioned GPU module class and function table, with explicit capabilities.
- Catalogue and bootloader selection for exact supported device identities.
- Kernel class dispatch and validation of every returned context and callback.
- Authorized device-register mappings and bounded, owned DMA allocations.
- Completion and reset rules that prove DMA quiescence before memory reuse.
- Resource revocation and IOMMU/device-address-space policy before giving apps
  GPU-visible mappings or accepting app-controlled DMA submissions.

Directory placement and separate packaging do not isolate a driver. Current
DriverKit modules execute with kernel privileges. Apps must retain checked
handles and bounded requests; they must never supply arbitrary physical
addresses. Failed reset or uncertain completion requires retaining memory the
device may still access. See [DriverKit](../frameworks/private/DriverKit/README.md)
and [driver packages](driver-packages.md).

## Physical hardware

AMD, Intel and NVIDIA require separate hardware-family work: discovery, display
engines, modesetting, memory management, interrupts, reset and power handling.
Rendering also needs command validation, scheduling and the relevant instruction
and shader support. Firmware availability, redistribution licenses and upstream
source licenses must be checked for each port.

Start with a documented family and exact PCI identities, keep unsupported
features explicit, and qualify named machines. One driver may support several
related devices after validation; neither a vendor match nor a CPU architecture
promises support for every card. Keep the firmware framebuffer fallback when
native device initialization is unavailable and it remains safe to use.
