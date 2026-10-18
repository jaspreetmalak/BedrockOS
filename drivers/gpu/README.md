# Graphics drivers

GPU and display hardware implementations live here. Reusable graphics commands
belong to public [Anvil](../../frameworks/public/Anvil/README.md); checked resource
execution belongs to private [AnvilCore](../../frameworks/private/AnvilCore/README.md).
Window policy and application views remain in userspace.

`framebuffer.zig` is the working essential boot backend. It imports the existing
firmware framebuffer into AnvilCore's bounded CPU device, borrows each validated
source read-only, submits a copy through Anvil, checks its completion fence and
releases the temporary source. RGB/BGR are supported directly; `pixel_format.zig`
retains exact conversion for unusual firmware channel masks. No extra pages or
graphics surfaces are allocated per presentation.

This is software rendering. It does not drive a GPU's rendering engines,
discover cards or provide vsync. It remains built in so initial boot does not
depend on loading an optional GPU module. The current optional DriverKit loader
understands the Wi-Fi class; GPU modules need a deliberate class/loader extension.

The next device milestone is a complete VirtIO GPU scanout path in QEMU, followed
by rendering acceleration and individually qualified physical GPU families.
See [GPU driver porting](../../docs/anvil-driver-porting.md) for dependencies,
fences, DMA ownership and the distinction between display transfer and rendering.
