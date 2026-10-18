# AnvilCore

The private, trusted implementation of [Anvil](../../public/Anvil). `Software(N)` is an allocation-free CPU backend with a fixed texture table, synchronous fill/copy commands and completed fences. It reports software execution; it does not claim GPU acceleration.

The owner imports an authorized, mapped `Image` and gives its provider to one serialized `anvil.Queue`. Images support XRGB/XBGR storage, explicit row stride and read-only or read-write access. Fill colors use canonical `0x00RRGGBB`; copies convert channel order and clear reserved high bits. Same-texture copies use memmove ordering. Distinct imported images may not overlap.

Keep a device at a stable address after importing images or borrowing its provider. Keep imported memory mapped and alive until release; serialize submissions, imports and releases. The provider validates the complete batch, resource ownership, access and bounds before writing any pixels or advancing a fence. It rejects image/metadata and image/command-storage aliases. Handles use a boot-local, globally unique slot identity plus a nonwrapping generation; exhausted slots retire instead of becoming valid again.

The kernel retains authority over mappings and app access. This backend adds no device discovery, DMA, GPU register access or app-facing syscall. Physical GPU backends will need separate vendor/device drivers and must accurately advertise their capabilities.

Run native tests with `zig build test` in this directory. Root workspace checks compile the backend for the supported freestanding architectures.
