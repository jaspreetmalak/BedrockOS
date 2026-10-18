# Regulatory data provenance

`database.zig` is generated from the official wireless-regdb `db.txt` at immutable commit `389b9b702cf9018e9a9078ccc4fa8eaae2e054e3` (2026-09-03). The source repository is maintained at https://git.kernel.org/pub/scm/linux/kernel/git/wens/wireless-regdb.git/ and fetched through its HTTPS kernel.googlesource.com mirror.

The upstream ISC copyright, permission and disclaimer text is retained verbatim in [LICENSE](LICENSE). This notice applies to the imported data and does not change unrelated OS licenses. The importer is independently written; it does not execute or copy the upstream Python compiler. [provenance.json](provenance.json) records source/license hashes, counts, exact URLs and the related Linux protocol reference pin.

All 182 countries and 1,016 source rules are retained, including world domain `00`, NO-INDOOR rules and ETSI WMM references. Power conversions round down only when a milliwatt value has no exact integer mBm representation. A complete upstream `db.txt` remains in `.zig-cache/upstream-wifi/regdb/`, not in shipped source. Country source comments and legal-reference URLs remain available at the immutable [original file](https://kernel.googlesource.com/pub/scm/linux/kernel/git/wens/wireless-regdb/+/389b9b702cf9018e9a9078ccc4fa8eaae2e054e3/db.txt).

Imported facts do not prove that a radio, firmware, calibration, antenna or deployment is permitted to transmit. Runtime policy must intersect applicable restrictions and trusted device constraints before physical hardware use.
