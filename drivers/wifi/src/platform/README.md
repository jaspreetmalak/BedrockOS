# Native MT7922 platform adapter

`x86_64.zig` is an explicit polling provider for a trusted, single CPU x86_64
UEFI board profile. PCI identification and firmware assets do not enable it.
The installed profile must attest opt-in, exclusive device takeover, coherent
identity DMA and a disabled IOMMU, and must match the exact PCI vendor, device,
subsystem identity and revision. The kernel serializes calls with interrupts
masked. These declarations require board verification; this code has not been
qualified on physical Wi-Fi hardware.

The owner sequence is `select`, `prepare`, `takeover`, `bindTransport`, then
`Transport.prepare(config(), device, platform())` and `Transport.start`.
Provider, transport and retained BootInfo must stay in place for the lifetime
of the borrowed callbacks. Failed takeover leaves bus mastering disabled and
does not allocate DMA. Uncertain transport shutdown retains its lease.

Read-only preflight requires BAR0's complete 1 MiB aperture to be supervisor RW,
identity mapped and PAT UC, described as EFI type 11 MMIO, and separate from
usable RAM and protected reservations. PCIe No-Snoop/Relaxed Ordering are
rejected. Takeover clears inherited bus mastering and disables INTx on only
the selected function before real driver ownership, WFDMA stop/reset and
WFSYS reset. No BAR sizing probes, guessed apertures or inherited DMA buffers
are used.

DMA mapping resolves the bound transport's actual generational kernel lease.
The complete 32-bit range must be usable, mapped, supervisor RW and WB under
both PAT and MTRRs. Buffer CPU pointers must equal their DMA physical addresses
and stay inside that lease. Each MMIO transaction and coherent DMA fence
walks the live CR3, including when a protected task's root is current. The
page-table reader uses the kernel's established supervisor identity RAM
aliases; PAT/MTRR settings must remain stable during this single CPU profile.
The adapter never changes mappings, PAT, MTRRs or IOMMU state.

Delay and `nowMicros` require invariant TSC and all three nonzero CPUID.15
ratio fields, including crystal frequency. Rational arithmetic rounds delays
up and elapsed time down. Regression/stall errors fail closed. CPUID.16 CPU
MHz is not a TSC calibration. AMD RZ616 boards without those architectural
facts therefore remain unsupported until a verified timer fallback exists.

Other explicit limits: four-level paging without PCID/PKS, physical width
32..52, at most 32 variable MTRRs, BAR/DMA candidates at or above 1 MiB, complete EFI
MMIO descriptors, no noncoherent DMA, IOMMU port, IRQ handling or SMP. ARM64
and RISC-V reject this provider. A prepared transport is not RF qualification
or proof of a connection; NIC, board calibration, regulatory and station
handshake gates remain separate owners.

The native tests inject configuration, page tables, CPU policy, TSC and MMIO.
They execute no privileged instruction or host hardware write. The strong
compile probe forces actual native adapter bodies for freestanding targets.

Clock/cache semantics follow the [Intel Software Developer's Manuals](https://www.intel.com/content/www/us/en/developer/articles/technical/intel-sdm.html).
PCI/register takeover uses the existing MediaTek translation pinned in
[`../mediatek/PROVENANCE.json`](../mediatek/PROVENANCE.json).
