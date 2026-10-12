# Realtek rtw89 protocol port

`root.zig` exports `firmware`, `h2c` and `profiles`. This standalone Zig subset uses the BSD-3-Clause option of pinned Linux v6.18 sources. See [NOTICE.md](NOTICE.md), [LICENSE](LICENSE) and [upstream.json](upstream.json).

`firmware.inspect(blob, .{ .cut = 2, .kind = .normal }, &image)` borrows immutable bytes. Selection types are `.normal`, `.wowlan` and `.normal_ce`. For MFW containers it validates all entry extents and nonoverlap, rejects ambiguous selectors, excludes MP images, then selects the closest cut not newer than the requested cut. A legacy single image supports normal type only; its cut is unknown. Limits are 16 MiB input, 32 MFW entries and 10 image sections. Failures clear output references.

The selected **v0** image parser checks its 32-byte header and 16-byte section table, bounded dynamic-header aggregate length/count, complete section/checksum/unformatted MSSC extents, destination masking/arithmetic and overlapping destinations. Checksum trailers and signatures are borrowed, not verified. Dynamic nested metadata, trailing firmware elements and raw signature fields remain opaque. The upstream format does not define a trusted chip-family selector in the image header; caller policy must choose the correct profile/file and trusted hash. Version 1 and formatted MSSC fail explicitly. This is a format inspector, not a validated DMA or secure-boot plan.

`h2c.encode(output, Header, payload)` emits an actual eight-byte H2C wire header using upstream category/class/function/sequence/length/ACK masks. It bounds the entire packet to 2048 bytes and rejects overlapping input/output buffers. As in upstream normal commands, every fourth sequence requests a receive ACK. Submission, ACK tracking, timeouts and firmware completion require a future transport owner.

`profiles.identify(vendor, device)` identifies PCI IDs `10ec:8852/a85a` (RTL8852A), `10ec:b852/b85b` (RTL8852B), and `10ec:c852` (RTL8852C). Every profile has `hardware_backend=false`. The port does not provide hardware scan, association or RF-qualified support.

Zig 0.17.0 verification passed **14 executed native checks per mode** in Debug and ReleaseSafe, plus six PIC compilation probes for x86_64, strict-alignment ARM64 and integer-only RISC-V64. Three additional native format-reference checks passed in each mode against intact, cache-only RTL8852A/B/C blobs from linux-firmware commit `afabaf773c4c2e2c841429933a6a084a5af4d14d`. [Reference hashes and URLs](firmware-references.json) record those exact files. The separate Realtek firmware license was reviewed before downloading; no vendor binary is included in this source package or production artifacts. Reference checks inspect published container fields and never execute or disassemble instructions.

```powershell
zig test kernel/src/drivers/wifi/realtek/root.zig -O Debug
zig test kernel/src/drivers/wifi/realtek/root.zig -O ReleaseSafe
```

Optional `reference_check.zig` requires a caller-supplied `reference_files` module exporting borrowed `rtl8852a`, `rtl8852b` and `rtl8852c` byte slices from the reviewed local cache. It is deliberately excluded from normal tests/builds and has no embedded vendor bytes.
