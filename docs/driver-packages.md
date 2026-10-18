# Driver packages and hardware selection

Bedrock separates three jobs: the kernel provides essential boot services, the
installer selects optional driver packages for detected hardware, and the running
OS matches a packaged module against the actual device before entering it. A
package being present does not make an unrelated device supported.

The first optional package is `org.bedrock.mt7922`. Its `mt7922.bdm` contains the
MediaTek station implementation. Console, interrupts/timer and the storage needed
to start the system remain built in. The public NetworkKit interfaces remain
available when no Wi-Fi module is installed; Wi-Fi reports unavailable.

```text
zig build -j2 drivers
```

This builds the separate module/package trees under `zig-out/drivers/` for all
three architectures. Compiled ARM64/RISC-V packages remain excluded from current
hardware installation by the catalogue.

These modules currently execute with kernel privileges through Driver ABI 1.0.
Separate packaging does **not** yet provide a separate driver process or protection
from a faulty driver. The versioned C interface keeps private Zig objects inside
their owning module and makes later isolation possible without putting hardware
details into app APIs.

## Current catalogue

[`drivers/catalogue.json`](../drivers/catalogue.json) is the installer catalogue.
It uses exact PCI vendor/device pairs, never a vendor-only match.

| PCI identity | Package selection | Native platform |
| --- | --- | --- |
| `14c3:7922` | MT7922 package | Experimental x86_64 UEFI port |
| `14c3:0616` | MT7922/RZ616 package | Experimental x86_64 UEFI port |
| `0b48:7922` | MT7922 package | Experimental x86_64 UEFI port |
| `14c3:7961`, `14c3:0608`, `14c3:7920` | Known family members; driver unimplemented | None |
| Any other identity | No catalogue match | No inference from vendor/family |

Architecture values are `x86_64`, `aarch64` and `riscv64`. The latter two are valid
OS/module targets but the current catalogue rejects MT7922 installation there as
`platform-unsupported`; their native PCI/DMA ports are still missing. A successful
file build, a module match and a physical Wi-Fi connection are separate results.
No physical radio connection is verified by the package tests.

The existing MT7922 setup still requires pinned firmware, secure boot-time
randomness, matching board/calibration facts and the explicitly configured native
platform. Packaging does not invent these facts or remove those checks. See
[`wifi-boot-setup.md`](wifi-boot-setup.md).

## Prepare files for one machine

[`tools/package-drivers.py`](../tools/package-drivers.py) prepares an ordinary
directory for installation media. This is the hardware selection and staging
part of an installer; a full on-device OS installer is not implemented here.
The tool reads local files, writes a new staging directory, and never writes a
host block device, mounts a filesystem, downloads code or executes a module.

An inventory is a bounded versioned JSON file. For example, this identity-only
inventory selects an MT7922 package if its local file is available:

```json
{
  "schema_version": 1,
  "devices": [
    {"vendor": "14c3", "device": "0616"}
  ]
}
```

Replace these IDs with the target machine's detected identities. Four-digit hex
strings and integer PCI IDs are accepted. Optional `subsystem_vendor` and
`subsystem_device` must be supplied together; optional `revision` is an integer
0..255 and `location` identifies a particular device. Multiple physical cards
can use the same package. Exact subsystem and board checks also run at startup.

```text
python tools/package-drivers.py --inventory machine.json --arch x86_64 --modules zig-out/drivers --output zig-out/selected-drivers
```

The output parent must exist and the output directory must be new. To read the
current Windows machine's PCI identities through read-only CIM enumeration:

```text
python tools/package-drivers.py --inventory-windows --arch x86_64 --modules zig-out/drivers --output zig-out/selected-drivers
```

The target architecture stays explicit; Windows inventory is useful only when
the host is the intended Bedrock machine. No radio configuration is changed.

The resulting directory contains:

```text
EFI/Bedrock/Drivers/mt7922.bdm   # only when selected and available
EFI/Bedrock/Drivers/manifest.json
driver-selection.json
```

The manifest records the architecture, ABI, package versions, module lengths and
SHA-256 hashes. The selection receipt records each device's result and the
kernel's built-in boot essentials. It does not copy a bootloader or claim that
the full OS was installed. Firmware and a trusted board profile retain their
separate EFI paths; the [Wi-Fi image builder](wifi-boot-setup.md#image-creation)
provides them.

An installer can display these receipt states directly:

| State | Meaning |
| --- | --- |
| `package-staged` | Exact hardware match and validated local package copied |
| `module-unavailable` | Hardware is in the catalogue, but its local package or module is absent |
| `platform-unsupported` | Known package lacks the target's native platform port |
| `driver-unimplemented` | Recognized exact device has no implemented package |
| `no-hardware-match` | Device is not in this catalogue |

A missing optional module produces an inspectable receipt and an empty module
manifest; it leaves essential boot support available. Malformed selected
packages fail preparation before anything is published. A catalogue match never
substitutes a different card's module. Invalid unselected packages are not read.

For offline media that should carry all currently available optional packages
for one architecture, add `--all-compatible`. Those extra packages receive the
`offline-fallback` selection reason. The OS still matches actual hardware at
startup, and unsupported architectures remain excluded. Later installations can
use the same selection format when hardware changes.

Offline selection does not need a hardware inventory and never queries the host:

```text
python tools/package-drivers.py --arch x86_64 --modules zig-out/drivers --output zig-out/offline-drivers --all-compatible
```

This uses an explicit empty inventory. It carries available compatible packages
for later boot-time matching without claiming that a card was detected.

## Put selected drivers into an image

The ordinary image builder accepts the exact selected driver directory and
checks the catalogue, architecture, hashes and ELF/ABI declarations again:

```text
python tools/make-uefi-image.py INPUT.EFI OUTPUT.img --arch x86_64 --driver-dir zig-out/selected-drivers/EFI/Bedrock/Drivers
python tools/test-uefi-image.py INPUT.EFI OUTPUT.img --arch x86_64 --driver-dir zig-out/selected-drivers/EFI/Bedrock/Drivers
```

Add `--firmware-dir` with the same explicit pinned asset directory to both
commands when making a Wi-Fi image. The driver bytes and manifest appear under
`EFI/Bedrock/Drivers/` alongside the separate firmware folder. The independent
checker verifies every serialized file, long filename, FAT chain and padding.
Only declared files are accepted; adding a test module or arbitrary `.bdm`
beside the manifest fails preparation.

For a direct image from local packages:

```text
python tools/make-uefi-image.py INPUT.EFI OUTPUT.img --arch x86_64 --driver-packages zig-out/drivers --inventory machine.json
python tools/test-uefi-image.py INPUT.EFI OUTPUT.img --arch x86_64 --driver-packages zig-out/drivers --inventory machine.json
```

Replace `--inventory machine.json` with `--all-compatible` in both commands
for offline media. These produce the same driver files as prior selection.
Package selection and `--driver-dir` are mutually exclusive. Missing packages
yield an empty manifest; malformed packages fail before the image is replaced.
Source manifests, modules and inventories cannot be used as image output files.

The Zig build uses `tools/stage-driver-build.py` to adapt its pre-created empty
cache output directory. The adapter publishes the complete selection at a new
`selected` child and rejects occupied roots. The public `package-drivers.py`
command continues to require a new output directory.

The explicit `wifi-uefi` build uses offline-compatible selection and publishes
the same EFI files into its directory tree and raw image. Its x86 image carries
the production MT7922 module; ARM64/RISC-V images carry an empty driver manifest
because the catalogue still excludes their native ports. Ordinary media can
continue to omit optional drivers. None of these paths enables fixture execution
in a production image or claims a physical connection.

This prepares installer media and optional packages. A full on-device installer,
driver update service and signed package distribution remain future work.

## Local package format

The local module root contains `<architecture>/<driver-directory>/package.json`
and its `.bdm` file. For this package:

```text
drivers/x86_64/mt7922/package.json
drivers/x86_64/mt7922/mt7922.bdm
```

The build uses [`tools/describe-driver-package.py`](../tools/describe-driver-package.py)
to inspect the linked ELF and generate this tree from actual bytes:

```text
python tools/describe-driver-package.py built-module.elf local-packages --arch x86_64
```

The output root may already exist; the individual package directory must be
new. ARM64/RISC-V modules can be described for compile checking, while hardware
selection continues to exclude those packages until their native ports exist.

`package.json` requires exactly these fields; the length/hash are generated from
the actual built module:

```json
{
  "schema_version": 1,
  "id": "org.bedrock.mt7922",
  "package_version": "0.1.0",
  "architecture": "x86_64",
  "driver_abi": {"major": 1, "minor": 0},
  "module": {
    "file": "mt7922.bdm",
    "byte_length": 123456,
    "sha256": "0000000000000000000000000000000000000000000000000000000000000000"
  }
}
```

The example length/hash are placeholders and are not usable package metadata.
Package semantic versions and the module's integer ABI declaration version are
distinct. A manifest SHA verifies the bytes against trusted local metadata;
it is not a publisher signature. Installing kernel modules requires trusted
system configuration. Signed package distribution and app permission policy
remain later work.

The stager verifies ordinary bounded files, duplicate JSON keys, safe names,
case-insensitive output collisions, ABI and target architecture, SHA-256/length,
bounded ELF64 ET_DYN load segments and executable entry, and the read-only
`BEDROCK` notes. Notes must agree on module identity/ABI/class/capabilities and
declare all catalogue PCI aliases. The runtime loader additionally checks
relocations, allocated memory and final page permissions before calling entry.
Neither validator invokes arbitrary local code during package inspection.
Load segments start on 4 KiB boundaries, have nonoverlapping page ranges, and
use a power-of-two alignment from 4 KiB through 4 MiB with congruent file and
virtual offsets. ARM64's 64 KiB linker alignment is accepted.

Input JSON is limited to 512 KiB; inventories to 1024 devices; catalogues to 64
packages; modules to 8 MiB file size, eight load segments and a 4 MiB mapped
image. No wildcards, traversal paths, Windows device aliases or named streams
are accepted. New staging directories publish atomically without replacement.
Failures remove only the tool's own unpublished temporary directory.
On Windows, publication may retry only access-denied/sharing/lock rename errors
while its original staging directory remains unchanged and the destination is
absent. There are at most five attempts and 0.55 seconds of scheduled waits,
with a one-second retry deadline. An existing destination always ends publication
without replacement.

## Verification

```text
python tools/test-driver-packages.py -v
zig build -j2 test-driver-modules
```

The tests use synthetic ELF/note bytes and temporary directories. They cover
the three exact aliases, unrelated devices, missing modules, offline selection,
unsupported native platforms, hashes/ABI/architecture mismatches, invalid ELF
bounds/permissions/notes, malformed inventories, safe path rules and competing
publication. They neither execute those synthetic bytes nor access host devices.
The module build gate separately checks the ABI/ELF loader and boots a small
test module on all three UEFI reference machines; this does not test a Wi-Fi
radio. The packaging suite currently passes 34 tests; the image suite passes
20 tests, including actual module serialization and a firmware/driver combined
roundtrip. Actual generated x86_64
and ARM64 module files also passed host-side description/selection checks; the
ARM64 package remained excluded by the native platform policy.

The integration passed module execution on all three UEFI reference machines
in Debug and ReleaseSafe, plus two production rejection-policy boots per mode.
Existing reset/UEFI boots, UDP networking, simulated/unavailable Wi-Fi controls,
firmware-file boots and Files desktop workflows also passed in both modes.
Native tests and cross checks passed 178/178 steps per mode; the final
ReleaseSafe build/install and validated image publication passed 246/246 steps.
Native test counts include imported/cached checks and are not additive.

Local evidence is preserved in `.zig-cache/driver-modules-verification.json`
and `.zig-cache/driver-images-{debug,safe}-verification.json`, including source,
log, module and image hashes. Resolved output-directory, Windows rename and
desktop screenshot synchronization failures are recorded there. The desktop
test still checks exact independent blur pixels. Physical RF tests remain zero.
