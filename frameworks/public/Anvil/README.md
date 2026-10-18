# Anvil

Anvil is Bedrock's native graphics command framework. Its first milestone is a
bounded 2D interface for filling and copying textures, with explicit completion
fences and backend capability reporting. It has no allocator, syscall, kernel,
window system or AxisUI dependency.

A provider determines where commands execute. A CPU provider reports software
execution; a future GPU driver must report only operations it actually supports.
Anvil does not implement a graphics driver, discover adapters or grant access to
display memory. Hardware acceleration requires a separate driver and authorized
provider. Shader programs, 3D rendering, scaling and alpha blending are outside
this initial interface.

```zig
const anvil = @import("anvil");

var queue = try anvil.Queue.init(provider);
var storage: [8]anvil.Command = undefined;
var batch = try anvil.Batch.init(&storage);
try batch.append(.{ .fill = .{
    .target = texture,
    .rect = .{ .x = 0, .y = 0, .width = 800, .height = 600 },
    .color = 0x20242c,
} });
const fence = try queue.submit(1, batch.commands());
batch.reset();
const ready = try queue.isComplete(fence);
```

`Texture` tokens are opaque and local to their provider. Creating, importing and
releasing resources belongs to that provider; knowing a token does not convey
authority. Pixels use `xrgb8888` (`0x00RRGGBB`) or `xbgr8888`
(`0x00BBGGRR`) storage, as reported by the provider. Fill colors always use
canonical `0x00RRGGBB`; reserved upper bits must be zero. Copies preserve logical
colors across supported formats and behave like `memmove` for overlapping regions
of the same texture. Rectangles have checked, nonempty, half-open bounds and are
never silently clipped.

Each batch contains at most 64 commands in caller-owned storage. A failed append
leaves its contents and length unchanged. Queue submission checks the entire
schema, operation capabilities and advertised maximum extent before dispatch.
The provider must check every actual resource bound and authorization in the
whole batch before writes, so an invalid later command cannot partly execute an
otherwise valid batch.

Queue calls are serialized through one owner, with a dedicated provider sequence
domain. Submit a nonzero sequence greater than the preceding accepted sequence.
Provider errors mean the batch was not accepted and may be retried. Successful
submission returns that exact sequence. An invalid acceptance or completion
result poisons the wrapper to prevent accidental duplicate execution. Completion
must never move backwards or acknowledge unsubmitted work.

An asynchronous provider copies command records before `submit` returns. Batch
storage may then be reset, but texture storage and its provider context must stay
alive and must not be modified or released while the relevant fence is in flight.
Completion means preceding writes are finished and visible. CPU providers may
complete synchronously. Fences belong to their original queue; copying a Queue
or Fence does not create an independent resource or sequence domain.

Run `zig build check` and `zig build test` from this directory with the workspace's
pinned Zig version. `-Dtarget=aarch64-freestanding-none`,
`-Dtarget=riscv64-freestanding-none` and `-Dtarget=x86_64-freestanding-none`
compile the same provider interface for Bedrock's supported architectures.
