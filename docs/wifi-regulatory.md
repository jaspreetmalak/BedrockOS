# Wi-Fi regulatory policy and source data

Bedrock now has a native, allocation-free regulatory data layer and a conservative 20 MHz policy intersection. It separates country facts from trusted radio capabilities. Importing a country or recognizing a PCI card does not establish calibration, permission to transmit, hardware availability or RF qualification. Production Wi-Fi remains unavailable until a real backend supplies those missing proofs; [driver porting boundaries](wifi-driver-porting.md) still apply.

The official wireless-regdb source is pinned to **`389b9b702cf9018e9a9078ccc4fa8eaae2e054e3`**, dated **2026-09-03**, which was the maintainer's current master when fetched. Its [immutable db.txt](https://kernel.googlesource.com/pub/scm/linux/kernel/git/wens/wireless-regdb/+/389b9b702cf9018e9a9078ccc4fa8eaae2e054e3/db.txt) contains **182 countries and 1,016 rules**. All are retained, including world domain `00`, sub-GHz/60 GHz facts outside the runtime profile, indoor restrictions and ETSI WMM references. The source is the maintainer's database, rather than a fresh legal determination for any deployment. Its [README](https://kernel.googlesource.com/pub/scm/linux/kernel/git/wens/wireless-regdb/+/389b9b702cf9018e9a9078ccc4fa8eaae2e054e3/README) describes the database's purpose and limitations.

## Native facts and conservative decisions

[database.zig](../drivers/wifi/src/regulatory/database.zig) exports a static `countries` slice, `lookup(alpha2: [2]u8) ?*const Country`, source identifiers, counts and the eight ETSI WMM access-category records. [types.zig](../drivers/wifi/src/regulatory/types.zig) supplies the shared rule/capability schema. Frequency endpoints and bandwidth use exact kHz; EIRP/conducted power use mBm and antenna gain uses mBi, both 100 units per dB. DFS region, flags and WMM references remain explicit. The pinned source has no antenna-gain or PSD fields, so those optional rule fields are null; they are not inferred from a device or a power limit.

The importer accepts the pinned grammar strictly. Unknown declarations, flags, units, duplicate countries/rules, missing WMM definitions, invalid ranges and precision loss fail the import. It preserves the two `NO-INDOOR` rules rather than reproducing their omission by upstream's compiler. Source dBm values convert exactly to mBm. Decimal milliwatt limits round down to the largest permitted integer mBm, verified with exact rational powers of ten: 200 mW becomes 2,301 mBm. Binary floating-point rounding never authorizes a larger limit. See the [pinned upstream compiler](https://kernel.googlesource.com/pub/scm/linux/kernel/git/wens/wireless-regdb/+/389b9b702cf9018e9a9078ccc4fa8eaae2e054e3/dbparse.py) for the original file grammar.

The [policy](../drivers/wifi/src/regulatory/policy.zig) combines a trusted country, environment and explicit board/firmware channel-capability records. A channel must have complete 20 MHz coverage; every positively overlapping source rule contributes its restrictions and minimum power ceiling. A permissive broad rule cannot override a narrower restriction. The decision separately reports passive-scan and transmit permission with denial reasons. Unavailable or uncalibrated receive capability is denied; transmit also needs proven conducted-power and antenna limits. Indoor/outdoor uncertainty, NO-IR, DFS, world-domain TX, missing required WMM setup and unsupported channel/bandwidth profiles cannot become transmit permission. DFS/AFC are not implemented. The initial evaluator denies 6 GHz and wider bandwidths; retained database facts do not enable them.

Country/environment selection belongs to a trusted kernel authority. Application requests, unauthenticated beacons and a test-radio result cannot select a more permissive domain. A future hardware backend must use approved decisions for scans and enforce power/channel limits again before management, association and data transmission. Calibration, antenna configuration, firmware/regulatory tables, channel-switch handling and recovery remain real backend responsibilities.

The in-place [radio policy authority](../drivers/wifi/src/radio_policy.zig)
copies trusted capabilities, defaults to passive world policy and issues
nonreused policy generations. Scan and TX descriptor candidates are checked
against the current snapshot before bytes are written. The adapter prevents
output/input aliases from corrupting validated policy, and failed refresh after a
new physical reset immediately retires old permissions. An incomplete reset can
receive corrected capability data at the same pending epoch; completed epochs
cannot be reused. Copied owners and reentrant country changes are rejected.

Its firmware adapter builds a bounded MediaTek domain from approved decisions
and submits actual CLC (`0x5c`), channel-domain (`0x0f`) and rate-power (`0x5d`)
commands through the owned MCU transport. It requires authentic matching CLC
data plus actual board/SAR/rate limits; it never fills missing calibration with
default power tables. Each signed half-dBm rate is bounded by the minimum
country/antenna, device and board ceiling, with negative ceilings rounded down.
Partial I/O failure poisons the submission session until a newer trusted reset.
Submitted DMA is a separate stage from firmware acceptance and effective RF
limits. Descriptor construction also remains separate from actual transmission.
These adapters are available to the future hardware backend; they do not enable
the production radio or implement NIC capability discovery/calibration.

## Offline regeneration and provenance

[The importer](../tools/update-wifi-regdb.py) is offline by default. It requires a local `db.txt` whose SHA-256 matches the fixed pin and writes an ordinary generated file by atomic replacement only after parsing succeeds. Its explicit `--fetch` option retrieves that same immutable source and license over HTTPS, checks their fixed hashes, and stores them in the local cache. It does not chase a branch during a build. Updating the source pin requires an intentional importer/provenance review and new golden tests.

```text
python tools/update-wifi-regdb.py .zig-cache/upstream-wifi/regdb/389b9b702cf9018e9a9078ccc4fa8eaae2e054e3/db.txt drivers/wifi/src/regulatory/database.zig --provenance drivers/wifi/src/regulatory/provenance.json
python tools/update-wifi-regdb.py - drivers/wifi/src/regulatory/database.zig --fetch --provenance drivers/wifi/src/regulatory/provenance.json
python tools/test-wifi-regdb.py --source .zig-cache/upstream-wifi/regdb/389b9b702cf9018e9a9078ccc4fa8eaae2e054e3/db.txt
```

Source SHA-256 is `b71c815bd90c284131a27ab5af6fb4951b3580dc8af83345f31fcd34c5cd0581`. [provenance.json](../drivers/wifi/src/regulatory/provenance.json) records this hash, immutable URLs, generated-output hash, source counts, license hash and the related Linux v6.18 protocol-reference pin. A fetched `db.txt` stays in `.zig-cache/upstream-wifi/regdb/`; no source database or network fetch is required at runtime. Hash pinning establishes reproducible source identity, not country-rule correctness or a verification of the upstream signed binary database.

The upstream [ISC LICENSE](../drivers/wifi/src/regulatory/LICENSE) and [notices](../drivers/wifi/src/regulatory/NOTICE.md) are retained. They apply to imported data and do not change unrelated OS licenses. The parser is independently written and does not execute the upstream compiler.

## Verification scope

The importer currently passes **15 host checks**, including full regeneration from the independently fetched pinned input. The suite checks exact golden hashes/counts, representative US/GB/JP/world facts, retention of all restrictions, conservative numeric proofs, malformed inputs, capacity limits, ordinary-file output guards and failed-import preservation. A default offline test run checks shipped generated facts and licenses; without `--source`, the separate full-input regeneration test is explicitly skipped.

Final integrated Debug and ReleaseSafe runs each passed **237/237 steps** for
`test check test-uefi test-wifi`. The complete driver suite passed **149 native
checks per mode**, including the new common policy, owner/reset/alias guards and
real command-framing tests. Complete baseline and PIC probes compile on x86-64,
ARM64 and RV64; PIC uses strict-alignment ARM64 and integer RV64 profiles. The
independent kernel package passed **46/46 Debug steps** and default workspace
build/install passed **208/208 steps**. Summaries include cached unchanged checks.

All twelve protected Wi-Fi control boots passed across both modes: six simulated
and six production-unavailable. UEFI smoke checks passed on all three reference
architectures in each mode. The full local-source importer suite passed **15/15**
normally and with Python optimization enabled. MediaTek's standalone suite
passed **49/49** per mode, including submission/epoch/copy guards; a separate
real pinned-firmware CLC parser check passed in both modes. The common suite
passed **10/10** per mode. Package counts include transitive checks and are not
additive to the integrated total.

```text
zig build test-wifi-regulatory check
zig build test-wifi-regulatory check -Doptimize=ReleaseSafe
```

The local `.zig-cache/wifi-regulatory-verification.json` records source/data,
artifact, log and control-boot hashes. Physical RF tests and operational hardware
backends still total zero. These software checks do not qualify physical cards,
location selection, RF emissions or regulatory certification.

The subsequent [native station integration](wifi-station.md) connects these
policies to NIC/MAC initialization, owned data queues, separate TXS ACK evidence,
MAC/WPA2/CCMP and trusted SDK/static-IPv4 attachment. Actual board inputs,
platform boot preparation and named-card RF acceptance remain required.
