# Intel Wi-Fi protocol port

`root.zig` exports `firmware` and `profiles`. These are allocation-free, freestanding Zig components derived from the pinned Linux v6.18 source under its BSD-3-Clause option. See [NOTICE.md](NOTICE.md), [LICENSE](LICENSE), and the exact source hashes in [upstream.json](upstream.json).

`firmware.inspect(blob, &container)` borrows immutable container bytes and clears its output on failure. Limits are 16 MiB input, 4096 TLVs and 64 section records, including delimiters. It checks little-endian header and TLV extents, complete four-byte padding extents, section destination arithmetic and same-image/same-CPU nonpaged overlap, delimiter ordering, CPU counts, paging size, metadata sizes/duplicates, and the pinned API/capability bitmap bounds. Alignment bytes and the upstream ignored header field may be nonzero. Byte slices remain borrowed; callers must retain the original buffer.

The API number follows the upstream version-format capability. `Container.requireApi(minimum, maximum)` lets a future hardware-specific firmware selector enforce its selected profile. Unknown metadata is counted in `unhandled_tlvs`; its structure is bounded but its content is not interpreted. The parser supports section-offset TLVs; legacy INST/DATA images are rejected. Paging sections are preserved as opaque borrowed records rather than a validated DMA plan. Firmware signatures, PNVM content, calibration, NVM and exact device memory windows are outside this parser.

`profiles.identify(vendor, device)` identifies targeted Intel PCI families only. A matching ID does not establish an exact RF revision, compatible firmware, or a working backend. Every inventory record has `hardware_backend=false`. Subsystem IDs and hardware revision still matter.

Local verification used Zig 0.17.0: 15 executed native checks in each of Debug and ReleaseSafe, plus six PIC compilation probes across x86_64, ARM64 with strict alignment, and integer-only RISC-V64. Fixtures contain synthetic format bytes, never vendor firmware. No radio, PCI register, host hardware, or user credential was touched.

```powershell
zig test kernel/src/drivers/wifi/intel/root.zig -O Debug
zig test kernel/src/drivers/wifi/intel/root.zig -O ReleaseSafe
```
