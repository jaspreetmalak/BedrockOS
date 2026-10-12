# Conservative channel policy

This original, allocation-free private module intersects immutable country rules
with explicitly supplied per-channel board/firmware capability records. It does
not identify a location, certify a radio or permit applications to choose a
country. The trusted kernel authority owns selection, immutable snapshots and
their non-reused generations. Generated `database.zig` is maintained separately
from this policy implementation and retains its source/license/provenance.

`lookup([2]u8)` returns an immutable country pointer or null. Unknown countries
must be rejected; the kernel may explicitly choose the world domain `00` as its
passive-only startup default. `evaluate(country,cap,environment,request)` returns
one copied `Decision`. `validateCaps` accepts at most128 unique band/channel
records; empty, malformed, duplicate and oversized capability lists fail closed.
Country rule count is bounded to128 and malformed rules invalidate the country.

Frequencies and bandwidths use exact kHz. The current profile supports only20MHz
requests in2.4/5GHz; it requires an exact board channel/center-frequency match and
full occupied-band containment by at least one rule. Every positive-overlap rule
intersects limits and restrictions, including a narrower overlapping rule. Rules
are never joined to invent a wider allowed span; `AUTO-BW` and `IR-CONCURRENT` do
not loosen this profile. The driver remains responsible for its actual channel
whitelist.4.9GHz and6GHz are unsupported.

`allow_passive_scan` requires calibrated available RX, supported width, matching
rules and permitted indoor/outdoor environment. Unknown environment cannot
satisfy an indoor-only or outdoor-only restriction. `allow_initiate_tx` also
requires certified conducted-power and actual antenna-gain records. Country
EIRP (mBm) minus actual antenna gain (mBi) gives a conducted ceiling, intersected
with the device ceiling. Negative power/gain remain signed; overflow rejects.
Explicit country antenna-gain maxima also constrain initiation.

World, `NO-IR`, DFS, unconfigured ETSI WMM and `NO-OFDM`/`NO-CCK` prevent initiation.
Neither a passive-listen permit nor a country rule permits active DFS scanning,
radar/CAC behavior or a modulation the backend has not proved. AFC and6GHz are
denied entirely. WMM rule references are retained by the generated database;
the trusted backend must explicitly prove ETSI settings were applied before a
WMM-constrained channel permits TX.

Optional PSD is preserved and supplies the additional rounded-down20MHz
total-power ceiling `PSD_mBm_per_MHz +1301`. That ceiling alone does not prove
per-MHz spectral-density enforcement, so PSD-marked TX stays denied until an
actual implementation exists. Passive reception may remain permitted. Every
decision retains flags, reason bits and computed ceilings; a denied decision
must never be treated as a transmit permit just because it has a power value.

`approvedScanList` validates all immutable input first, then publishes only
passive-approved copied decisions. Too-small output, input/output overlap or any
preflight error leaves output untouched. Caller-owned buffers avoid heap use;
the caller must serialize and keep borrowed inputs unchanged throughout a call.

Primary references:

- [Linux regulatory model and EEPROM restrictions](https://docs.kernel.org/networking/regulatory.html).
- [Official wireless-regdb pinned source](https://kernel.googlesource.com/pub/scm/linux/kernel/git/wens/wireless-regdb/+/389b9b702cf9018e9a9078ccc4fa8eaae2e054e3/db.txt).
- [Linux v6.18 regulatory rule/channel definitions](https://github.com/torvalds/linux/blob/v6.18/include/uapi/linux/nl80211.h).

The policy is implemented from scratch; these references supply facts and units,
not copied Linux implementation code. Native tests cover containment boundaries,
overlap intersection, flags/environments, calibrated capabilities, signed power,
gain, PSD, malformed inputs, list publication and every imported country's shape.
