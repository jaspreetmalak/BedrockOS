# Anvil graphics framework

Anvil is Bedrock's graphics command layer. It separates the API from execution,
so future GPU drivers can share a command interface with the software fallback.
The initial interface supports bounded 2D texture fills and copies, explicit
capabilities, opaque resource tokens and completion fences.

GPU drivers are needed for specific device families, as with Wi-Fi. A common
framework removes device-specific details from its callers; it does not make
unsupported hardware work. The first device-driver target is VirtIO GPU in
QEMU, followed by individually qualified physical families. See the
[driver porting plan](anvil-driver-porting.md).

## Components

| Component | Responsibility |
| --- | --- |
| [`frameworks/public/Anvil`](../frameworks/public/Anvil/README.md) | Portable graphics commands, bounded batches, capabilities and queue/fence API |
| [`frameworks/private/AnvilCore`](../frameworks/private/AnvilCore/README.md) | Trusted CPU execution, checked imports, access rights and resource lifetimes |
| [`drivers/gpu`](../drivers/gpu/README.md) | Essential firmware framebuffer backend and future native device drivers |
| Kernel display broker | App identity, service authority, surface grants, mappings and lease state |
| Userspace display service | Composition, focus, windows, desktop policy and final presentation requests |
| AxisUI | Native application views, layout, fonts, controls and CPU rendering |

The current path is AxisUI surfaces → protected display service → existing
display syscall checks → Anvil queue → CPU framebuffer backend. Linking Anvil
does not give an application a GPU context, raw display access, MMIO or DMA
permissions. A general app GPU resource/submission syscall is not implemented.
Anvil's provider callbacks are an in-process source API, not a stable driver
module ABI or a new user/kernel wire format.

## Working backend

The essential framebuffer driver borrows the validated boot framebuffer and
registers it with a two-resource CPU device. Each presentation temporarily
imports its already authorized source read-only, copies the checked rectangle,
verifies completion and releases that import. Existing full-source placement
and owned-scene cursor damage rectangles keep their original semantics.

RGB and BGR copies preserve logical color and clear reserved upper bits. An
uncommon firmware-mask path retains exact software channel conversion. Source
and destination strides and guards remain independent. There is no per-frame
page allocation or new surface grant, so the compositor's surface accounting
remains unchanged.

The provider reports **software rendering**. This implementation does not offer
hardware acceleration, shaders, 3D, compute, alpha blending, scaling, vsync or a
60 FPS guarantee. A working VirtIO 2D scanout will still require Bedrock to
produce pixels; accelerated rendering is another milestone.
[QEMU's GPU backend documentation](https://www.qemu.org/docs/master/system/devices/virtio/virtio-gpu.html)
distinguishes its 2D, VirGL and rutabaga backends.

## Resource and submission rules

- A batch has at most 64 commands in caller-owned storage. Invalid append leaves
  prior storage unchanged; schema/resource validation rejects a submission
  before pixels change. Provider execution failures are a separate concern.
- The provider resolves every resource, access right and rectangle in the whole
  batch before writing. Read-only images cannot be fill or copy targets.
- CPU resource tokens bind unique slot identities and nonwrapping generations.
  Stale, released and foreign tokens fail. A pinned device cannot be copied and
  used at another address.
- Same-texture overlapping copies use `memmove` semantics. Overlapping imports
  of distinct images are rejected, as are command/image storage aliases.
- A submitted sequence is nonzero and increases. Completion cannot move
  backwards or acknowledge unsubmitted work. An invalid provider result poisons
  the queue wrapper.
- Texture backing and provider context remain alive until completion. The CPU
  provider completes synchronously; an asynchronous driver must retain commands
  and DMA resources until its actual fences or reset establish completion.

For example, trusted code can execute into its own borrowed CPU pixels:

```zig
var pixels: [16]u32 = @splat(0);
var cpu: AnvilCore.Software(1) = .{};
const texture = try cpu.importImage(.{
    .pixels = &pixels, .width = 4, .height = 4, .stride = 4,
    .format = .xrgb8888,
});
var queue = try Anvil.Queue.init(cpu.provider());
const fence = try queue.submit(1, &.{.{ .fill = .{
    .target = texture,
    .rect = .{ .x = 0, .y = 0, .width = 4, .height = 4 },
    .color = 0x29313d,
} }});
if (!try queue.isComplete(fence)) return error.NotCompleted;
try cpu.release(texture);
```

This grants access only to pixels supplied by the trusted caller. It is not a
way to obtain another process's surface or the framebuffer.

## Build and verification

```text
zig build test-anvil -j1
zig build test-anvil -Doptimize=ReleaseSafe -j1
zig build check desktop -Doptimize=ReleaseSafe -j1
zig build test-anvil-desktop -Doptimize=ReleaseSafe -j1
```

Architecture-specific runtime targets are `test-anvil-desktop-x86_64`,
`test-anvil-desktop-arm64` and `test-anvil-desktop-riscv64`. Each uses the normal
native desktop input/pixel suite with an additional gate requiring honest
software-backend selection and a completed first Anvil presentation. Tests use
disposable disk images, preserve source/boot hashes and stop only their own
QEMU instances. They do not modify a running interactive desktop.

The native suite covers command validation, provider failures, fences, resource
identity/exhaustion, read-only access, atomic rejection, RGB/BGR conversion,
overlap, rectangle bounds, unusual masks and repeated source retirement. The
[runtime evidence gate](../tools/test-anvil-runtime.py) independently rejects
missing, duplicated, out-of-order or falsely accelerated backend reports.

### Recorded results, October 18, 2026

Debug and ReleaseSafe native checks pass: 33 tests across the public framework,
private CPU provider and framebuffer adapter, plus four independent Python
evidence-gate tests. Public Anvil and private AnvilCore compile for x86-64,
ARM64 and RV64; the workspace `check` and `desktop` build passes in ReleaseSafe.

Each ReleaseSafe QEMU reference passed all 59 captured desktop scenes with the
Anvil software backend and a completed first presentation. The workflows cover
menus, brightness/dimming, window controls, tab reordering/tear-off, retained
navigation and balanced window retirement. Private data remains unchanged and
the recorded source hashes match the verified tree:

- [x86-64 receipt](../zig-out/anvil-tests/safe/x86_64/system-menus-x86_64-verification.json)
- [ARM64 receipt](../zig-out/anvil-tests/safe/arm64/system-menus-arm64-verification.json)
- [RV64 receipt](../zig-out/anvil-tests/safe/riscv64/system-menus-riscv64-verification.json)

These qualify the CPU/framebuffer path on the named QEMU machines. They do not
qualify native GPU hardware, accelerated rendering, frame rate or physical PCs.

GPU packaging remains future work. DriverKit's existing optional module path
supports Wi-Fi; GPU module descriptors, class dispatch, catalogue matching and
driver callbacks need explicit extensions. The boot framebuffer backend remains
built in. See [GPU driver porting](anvil-driver-porting.md) for the next milestones.
