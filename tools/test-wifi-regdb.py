#!/usr/bin/env python3
"""Offline importer tests. --source adds a full pinned-source regeneration check."""
from __future__ import annotations

import argparse
import base64
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location("wifi_regdb_importer", ROOT / "tools/update-wifi-regdb.py")
regdb = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = regdb
SPEC.loader.exec_module(regdb)
SOURCE: Path | None = None
GENERATED_SHA256 = "25478770e860a08d3628dc389a4d8130234f56ba15c168b7a0985eb7b72dafb6"
WMM = """wmmrule ETSI:
vo_c: cw_min=3, cw_max=7, aifsn=2, cot=2
vi_c: cw_min=7, cw_max=15, aifsn=2, cot=4
be_c: cw_min=15, cw_max=1023, aifsn=3, cot=6
bk_c: cw_min=15, cw_max=1023, aifsn=7, cot=6
vo_ap: cw_min=3, cw_max=7, aifsn=1, cot=2
vi_ap: cw_min=7, cw_max=15, aifsn=1, cot=4
be_ap: cw_min=15, cw_max=63, aifsn=3, cot=6
bk_ap: cw_min=15, cw_max=1023, aifsn=7, cot=6
"""
RULE = "(2400 - 2483.5 @ 40), (100 mW)"


def parse(text: str):
    return regdb.parse(text.encode("utf-8"))


class RegulatoryImporterTests(unittest.TestCase):
    def test_exact_decimal_frequency_and_dbm_units(self):
        database = parse("country GB: DFS-ETSI\n(2400 - 2483.5 @ 40), (23.00 dBm)\n")
        rule = database.countries[0].rules[0]
        self.assertEqual((rule.start_khz, rule.end_khz, rule.max_bandwidth_khz), (2400000, 2483500, 40000))
        self.assertEqual(rule.max_eirp_mbm, 2300)
        self.assertIsNone(rule.max_antenna_gain_mbi)
        self.assertIsNone(rule.psd_mbm_mhz)
        self.assertEqual(regdb.power_mbm("-2.75", "dBm"), -275)

    def test_mw_rounding_proven_not_to_exceed_limit(self):
        # Independent exact proof of the floor for each expected result.
        from fractions import Fraction
        for text, expected in (("1", 0), ("10", 1000), ("100", 2000), ("200", 2301),
                               ("250", 2397), ("500", 2698), ("125", 2096),
                               ("0.5", -302), ("10000", 4000), ("1.00000000001", 0)):
            with self.subTest(text=text):
                result = regdb.power_mbm(text, "mW")
                self.assertEqual(result, expected)
                numerator, denominator = Fraction(text).as_integer_ratio()
                left, right = numerator ** 1000, denominator ** 1000
                lower_ok = left >= right * 10 ** result if result >= 0 else left * 10 ** (-result) >= right
                upper = result + 1
                upper_ok = left >= right * 10 ** upper if upper >= 0 else left * 10 ** (-upper) >= right
                self.assertTrue(lower_ok)
                self.assertFalse(upper_ok)

    def test_flags_wmm_and_no_indoor_are_preserved(self):
        database = parse(WMM + "country GB: DFS-ETSI\n" + RULE +
                         ", NO-INDOOR, DFS, AUTO-BW, wmmrule=ETSI\n")
        rule = database.countries[0].rules[0]
        self.assertEqual(rule.flags, (1 << 3) | (1 << 1) | (1 << 10))
        self.assertEqual(rule.wmm, "etsi")
        self.assertEqual(len(database.wmm_etsi), 8)
        self.assertEqual(database.wmm_etsi[2].cot_us, 6000)
        self.assertEqual(database.wmm_etsi[6].cw_max, 63)
        self.assertEqual(parse("country US:\n" + RULE + ", NO-HT40\n").countries[0].rules[0].flags, 192)

    def test_source_order_determinism_and_world_retention(self):
        database = parse("country US: DFS-FCC\n" + RULE + "\ncountry 00:\n" + RULE + ", NO-IR\n")
        self.assertEqual([country.alpha2 for country in database.countries], ["00", "US"])
        one = regdb.render(database, "a" * 64)
        two = regdb.render(database, "a" * 64)
        self.assertEqual(one, two)
        self.assertIn(b".flags = 1", one)

    def test_no_silent_unsupported_flag_or_syntax_drops(self):
        malformed = (
            RULE + ", FUTURE-FLAG", RULE + ", PTP-ONLY", RULE + ", PSD=-1",
            RULE + ", NO-IR, NO-IR", RULE + ",", RULE + "garbage",
            "(2400 - 2483.5 @ 40), (N/A)", "(2400 - 2483.5 @ 40), (3, 20)",
            "(2400 - 2483.5 @ 40), (200 W)", "(2400 - 2483.5), (20)",
            "band legacy: 2400-2483.5", "power named:20",
        )
        for rule in malformed:
            with self.subTest(rule=rule):
                with self.assertRaises(regdb.ImportError):
                    parse("country US: DFS-FCC\n" + rule + "\n")

    def test_malformed_numeric_ranges_and_precision_reject(self):
        for rule in (
            "(2483.5 - 2400 @ 40), (20)", "(2400 - 2400 @ 20), (20)",
            "(2400 - 2483.5 @ 100), (20)", "(0 - 2483.5 @ 40), (20)",
            "(2400 - 2483.5 @ 0), (20)", "(2400.0001 - 2483.5 @ 40), (20)",
            "(2400 - 2483.5 @ 40), (20.001)", "(2400 - 2483.5 @ 40), (0 mW)",
            "(2400 - 2483.5 @ 40), (-1 mW)", "(NaN - 2483.5 @ 40), (20)",
            "(2400 - 2483.5 @ 40), (1e3 mW)", "(5000000 - 5000020 @ 20), (20)",
        ):
            with self.subTest(rule=rule):
                with self.assertRaises(regdb.ImportError):
                    parse("country US:\n" + rule)

    def test_duplicate_country_rule_and_unknown_dfs_reject(self):
        for source in (
            "country US:\n" + RULE + "\ncountry US:\n" + RULE,
            "country US:\n" + RULE + "\n" + RULE,
            "country US: DFS-FUTURE\n" + RULE,
            "country us:\n" + RULE, "country US,GB:\n" + RULE,
            "country US:\n", RULE, "", "country U1:\n" + RULE,
        ):
            with self.subTest(source=source):
                with self.assertRaises(regdb.ImportError):
                    parse(source)

    def test_wmm_incomplete_duplicate_unknown_and_bounds(self):
        for prefix in (
            WMM.replace("cw_min=3", "cw_min=4", 1),
            WMM.replace("cot=2", "cot=66", 1),
            WMM.replace("aifsn=2", "aifsn=0", 1),
            WMM.replace("vo_c:", "future:", 1),
            WMM + WMM,
            "\n".join(WMM.splitlines()[:-1]) + "\n",
            WMM + "vo_c: cw_min=3, cw_max=7, aifsn=2, cot=2\n",
        ):
            with self.subTest(prefix=prefix):
                with self.assertRaises(regdb.ImportError):
                    parse(prefix + "country GB:\n" + RULE + ", wmmrule=ETSI")
        with self.assertRaises(regdb.ImportError):
            parse("country GB:\n" + RULE + ", wmmrule=ETSI")

    def test_source_bounds_and_capacity(self):
        for source in (b"\0", b"\xff", b"x" * (regdb.MAX_SOURCE_BYTES + 1),
                       b"#" + b"x" * regdb.MAX_LINE_BYTES):
            with self.assertRaises(regdb.ImportError):
                regdb.parse(source)
        with mock.patch.object(regdb, "MAX_COUNTRIES", 1):
            with self.assertRaises(regdb.ImportError):
                parse("country US:\n" + RULE + "\ncountry 00:\n" + RULE)
        with mock.patch.object(regdb, "MAX_RULES", 1):
            with self.assertRaises(regdb.ImportError):
                parse("country US:\n" + RULE + "\n(5170 - 5250 @ 80), (20)")

    def test_failed_cli_leaves_output_untouched(self):
        with tempfile.TemporaryDirectory(prefix="bedrock-regdb-") as directory:
            directory = Path(directory)
            source, output = directory / "db.txt", directory / "database.zig"
            source.write_bytes(b"country US:\n" + RULE.encode())
            output.write_bytes(b"existing output sentinel")
            process = subprocess.run([sys.executable, str(ROOT / "tools/update-wifi-regdb.py"),
                                      str(source), str(output)], capture_output=True, timeout=10)
            self.assertEqual(process.returncode, 1)
            self.assertEqual(output.read_bytes(), b"existing output sentinel")
            self.assertEqual(sorted(path.name for path in directory.iterdir()), ["database.zig", "db.txt"])

    def test_explicit_fetch_verifies_pin_before_cache_publication(self):
        class Response:
            def __enter__(self):
                return self

            def __exit__(self, *_):
                pass

            def read(self, bound):
                self.bound = bound
                return base64.b64encode(b"untrusted database bytes")

        with tempfile.TemporaryDirectory(prefix="bedrock-regdb-") as directory:
            response = Response()
            with mock.patch.object(regdb.urllib.request, "urlopen", return_value=response) as open_url:
                with self.assertRaises(regdb.ImportError):
                    regdb.fetch(Path(directory))
            self.assertEqual(list(Path(directory).iterdir()), [])
            url = open_url.call_args.args[0]
            self.assertTrue(url.startswith("https://kernel.googlesource.com/"))
            self.assertIn(regdb.COMMIT, url)
            self.assertEqual(response.bound, regdb.MAX_SOURCE_BYTES * 2 + 1)

    def test_atomic_write_replaces_only_regular_output(self):
        with tempfile.TemporaryDirectory(prefix="bedrock-regdb-") as directory:
            directory = Path(directory)
            output = directory / "database.zig"
            output.write_bytes(b"old")
            regdb.atomic_write(output, b"new complete file")
            self.assertEqual(output.read_bytes(), b"new complete file")
            self.assertEqual([path.name for path in directory.iterdir()], ["database.zig"])
            with self.assertRaises(regdb.ImportError):
                regdb.atomic_write(directory, b"must not write to directory")

    def test_ordinary_file_and_path_alias_guards(self):
        with tempfile.TemporaryDirectory(prefix="bedrock-regdb-") as directory:
            directory = Path(directory)
            with self.assertRaises(regdb.ImportError):
                regdb.ordinary_path(directory)
            missing = directory / "missing" / "database.zig"
            with self.assertRaises(regdb.ImportError):
                regdb.ordinary_path(missing, output=True)
        with mock.patch.object(regdb.os, "name", "nt"):
            for name in ("NUL", "nul.txt", "folder/CON.log", "LPT¹.foo", "COM9", "a:stream.zig"):
                with self.subTest(name=name), self.assertRaises(regdb.ImportError):
                    # Construct before patching os.name, preserving host Path type.
                    regdb.ordinary_path(type(ROOT)(name), output=True)

    def test_generated_golden_hash_counts_license_and_metadata(self):
        directory = ROOT / "kernel/src/drivers/wifi/regulatory"
        generated = (directory / "database.zig").read_bytes()
        metadata = json.loads((directory / "provenance.json").read_text(encoding="utf-8"))
        self.assertEqual(hashlib.sha256(generated).hexdigest(), GENERATED_SHA256)
        self.assertEqual(metadata["generated_sha256"], GENERATED_SHA256)
        self.assertEqual(metadata["source_sha256"], regdb.SOURCE_SHA256)
        self.assertEqual(metadata["commit"], regdb.COMMIT)
        self.assertEqual((metadata["country_count"], metadata["rule_count"]), (182, 1016))
        self.assertEqual(hashlib.sha256((directory / "LICENSE").read_bytes()).hexdigest(), regdb.LICENSE_SHA256)
        self.assertEqual(generated.count(b".alpha2 ="), 182)
        self.assertEqual(generated.count(b".start_khz ="), 1016)

    def test_actual_pinned_source_regenerates_and_official_country_facts(self):
        if SOURCE is None:
            self.skipTest("pass --source for the independently fetched pinned db.txt")
        source = SOURCE.read_bytes()
        self.assertEqual(hashlib.sha256(source).hexdigest(), regdb.SOURCE_SHA256)
        database = regdb.parse(source)
        self.assertEqual((len(database.countries), database.rule_count), (182, 1016))
        generated = regdb.render(database, regdb.SOURCE_SHA256)
        self.assertEqual(hashlib.sha256(generated).hexdigest(), GENERATED_SHA256)
        self.assertEqual(generated, (ROOT / "kernel/src/drivers/wifi/regulatory/database.zig").read_bytes())
        countries = {country.alpha2: country for country in database.countries}
        us, gb, jp, world = [countries[code] for code in ("US", "GB", "JP", "00")]
        self.assertEqual([country.dfs_region for country in (us, gb, jp, world)], ["fcc", "etsi", "jp", "unset"])
        self.assertEqual([len(country.rules) for country in (us, gb, jp, world)], [11, 7, 8, 9])
        self.assertEqual(us.rules[3], regdb.Rule(2400000, 2472000, 40000, 3000))
        self.assertEqual(us.rules[9], regdb.Rule(5925000, 7125000, 320000, 1200, 5))
        self.assertEqual(gb.rules[1], regdb.Rule(5150000, 5250000, 80000, 2301, 1028, "etsi"))
        self.assertEqual(gb.rules[3].max_eirp_mbm, 2698)
        self.assertEqual(jp.rules[1], regdb.Rule(2474000, 2494000, 20000, 2000, 16))
        self.assertEqual(world.rules[2], regdb.Rule(2457000, 2482000, 20000, 2000, 1025))
        self.assertEqual(sum(bool(rule.flags & 8) for country in database.countries for rule in country.rules), 2)


if __name__ == "__main__":
    cli = argparse.ArgumentParser(add_help=False)
    cli.add_argument("--source", type=Path)
    options, rest = cli.parse_known_args()
    SOURCE = options.source
    unittest.main(argv=[sys.argv[0], *rest])
