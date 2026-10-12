# Proposed Bedrock boot protocol

This independent Zig 0.17.0 package sketches a common handoff ABI for x86-64,
AArch64, and RV64. The wire version is draft major 0/minor 2. The ABI is proposed
and has not been finalized. No bootloader
or kernel entry implementation is provided.

The public Zig module is `boot_protocol`. Its wire records are `extern` structs
with fixed-width integers, no native pointers, and compile-time size/offset
checks. The proposed targets use little-endian records. Records must be obtained
from accessible, appropriately aligned memory before calling validation; this
package does not yet provide a byte-stream decoder.

- `Architecture`: numeric x86-64, AArch64, and RV64 tags.
- `Header`: 24-byte prefix containing magic, major/minor version, declared header
  size, architecture tag, and a reserved field.
- `Header.init(architecture)`: construct the current prefix.
- `Header.validate(available_bytes, expected_architecture)`: reject bad magic,
  unsupported major versions, undersized or truncated headers, and wrong or
  unknown architecture tags, and nonzero reserved fields. Future minor versions and longer accessible headers
  are accepted. Extension semantics are intentionally not defined yet.
- `PhysicalRange`: 16-byte base/length pair; `endExclusive()` returns a checked
  exclusive end or `PhysicalRangeOverflow`. Empty ranges are valid. A range
  reaching an exclusive end of 2^64 is rejected because that end is unrepresentable.
- `MemoryRegion`: 24-byte physical range, numeric kind, and reserved attributes.
  Unknown kinds should be treated as reserved. Producers currently write zero
  reserved fields and attributes.
- `BootInfo`: 2,816-byte record containing the original boot prefix, up to 64
  sorted memory regions, typed console, CPU entry state, firmware environment,
  ACPI/framebuffer descriptions, an owned raw EFI memory-map reference,
  physical-address width and up to 64 explicit accessible ranges. The original
  v0.1 field offsets remain intact, but full consumers require the current size.
  The prefix RAM envelope may contain holes and does not grant allocation/access.
  `validate()` checks the record, metadata and range ownership. Callers must check
  pointer accessibility before reading it and check actual platform geometry
  after validation. `flag_smoke_exit` permits emulator test termination.
- `MemoryMap`: bounded RAM/reservation normalization without allocation.
  Reservations split RAM, stricter kinds win overlaps and adjacent equal regions
  merge. Unknown region kinds are never usable.
- `MappedRanges`: sorted bounded identity coverage, separate from ownership.
  UEFI requires explicit coverage of retained references; reset profiles may
  leave it absent and retain their documented mapping contracts.

Build with `zig build`, run native tests with `zig build test`, and compile without
execution with `zig build check`. Standard target and optimization options are
supported. Tests always run on the host even when a compilation target is selected.

The default build installs a static compile-probe library named
`bedrock-boot-protocol`. A parent package can retrieve the module with
`dependency.module("boot_protocol")` and the probe with
`dependency.artifact("bedrock-boot-protocol")`. The exported C function exercises
validation and overflow paths for compilation; it is not a stable runtime API.
