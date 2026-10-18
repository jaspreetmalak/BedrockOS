#!/usr/bin/env python3
# SPDX-License-Identifier: ISC
# Copyright (C) 2026 Bedrock contributors
"""Bounded synthetic profile encoder tests; no hardware access or RF proof."""
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import struct
import tempfile
import unittest
from unittest import mock

spec = importlib.util.spec_from_file_location("make_wifi_board_profile", Path(__file__).with_name("make-wifi-board-profile.py"))
encoder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(encoder)


def fixture():
    return {
        "version": 1,
        "identity": {"vendor": 0x14c3, "device": 0x0616, "subsystem_vendor": 0x1028,
                     "subsystem_device": 0x1234, "revision": 1},
        "hardware": {"antenna_mask": 3, "encapsulation": 1, "power_type": 1,
                     "acpi_conf": 0, "mtcl_conf": 255, "clc_event_supported": True},
        "platform": {"opt_in": True, "coherent_identity_dma": True,
                     "iommu_disabled": True, "exclusive_takeover": True},
        "country": "US", "environment": "indoor", "provenance_sha256": None,
        "efuse": {"address": 0x550, "validity": 1, "data_hex": "21" * 16},
        "channels": [{"band": "2ghz", "channel": 6, "available_rx": True,
                      "calibrated_rx": True, "known_tx_power": True,
                      "antenna_gain_mbi": 300, "board_conducted_mbm": 2000,
                      "sar_conducted_mbm": 1500, "max_bandwidth_khz": 20000,
                      "rates_half_dbm": [30] * 161}]
    }


class BoardProfileTests(unittest.TestCase):
    def test_literal_format_hash_and_signed_rate_units(self):
        source = fixture()
        result = encoder.build_profile(source)
        self.assertEqual(len(result), 320)
        self.assertEqual(struct.unpack_from("<8sHHIHHHHHH", result),
                         (b"BRDBRD01", 1, 128, 320, 1, 192, 0x14c3, 0x0616, 0x1028, 0x1234))
        self.assertEqual(result[28:40], bytes((1, 3, 1, 1, 0, 255, 1, 15)) + b"US\x01\x00")
        self.assertEqual(result[72:104], bytes(32))
        self.assertEqual(struct.unpack_from("<II", result, 104), (0x550, 1))
        self.assertEqual(result[112:128], bytes([0x21]) * 16)
        self.assertEqual(struct.unpack_from("<BBHiiiI", result, 128), (1, 6, 7, 300, 2000, 1500, 20000))
        self.assertEqual(result[148:309], bytes([30]) * 161)
        self.assertEqual(result[309:320], bytes(11))
        zeroed = result[:40] + bytes(32) + result[72:]
        self.assertEqual(result[40:72], hashlib.sha256(zeroed).digest())
        channel = source["channels"][0]
        channel["board_conducted_mbm"] = -1251
        channel["sar_conducted_mbm"] = -1250
        channel["rates_half_dbm"] = [-26] * 161
        self.assertEqual(encoder.build_profile(source)[148:309], bytes([230]) * 161)

    def test_missing_or_unknown_facts_and_boolean_numbers_reject(self):
        for path in (("identity", "revision"), ("hardware", "antenna_mask"),
                     ("platform", "iommu_disabled"), ("channels", 0, "sar_conducted_mbm"),
                     ("channels", 0, "rates_half_dbm")):
            document = fixture()
            parent = document
            for component in path[:-1]:
                parent = parent[component]
            del parent[path[-1]]
            with self.subTest(path=path), self.assertRaises(ValueError):
                encoder.build_profile(document)
        document = fixture()
        document["qualification_approved"] = True
        with self.assertRaises(ValueError):
            encoder.build_profile(document)
        for value in (True, 1.5, "3", None):
            document = fixture()
            document["hardware"]["antenna_mask"] = value
            with self.subTest(value=value), self.assertRaises(ValueError):
                encoder.build_profile(document)
        document = fixture()
        document["platform"]["iommu_disabled"] = False
        self.assertEqual(encoder.build_profile(document)[35], 11)

    def test_channel_capacity_duplicates_unsupported_and_power_widening_reject(self):
        for field, value in (("band", "6ghz"), ("channel", 15), ("available_rx", False),
                             ("calibrated_rx", False), ("known_tx_power", False),
                             ("max_bandwidth_khz", 40000), ("antenna_gain_mbi", 20001),
                             ("sar_conducted_mbm", 1499), ("rates_half_dbm", [30] * 160),
                             ("rates_half_dbm", [128] * 161)):
            document = fixture()
            document["channels"][0][field] = value
            with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                encoder.build_profile(document)
        for count in (0, 2, 65):
            document = fixture()
            document["channels"] = [copy.deepcopy(document["channels"][0]) for _ in range(count)]
            with self.subTest(count=count), self.assertRaises(ValueError):
                encoder.build_profile(document)
        document = fixture()
        document["channels"][0].update(band="5ghz", channel=37)
        with self.assertRaises(ValueError):
            encoder.build_profile(document)

    def test_exact_device_and_efuse_binding_preserves_real_values(self):
        document = fixture()
        for identity_key, value in (("vendor", 0x1234), ("device", 0xffff),
                                    ("subsystem_vendor", 0), ("subsystem_device", 0xffff), ("revision", 256)):
            changed = copy.deepcopy(document)
            changed["identity"][identity_key] = value
            with self.subTest(key=identity_key), self.assertRaises(ValueError):
                encoder.build_profile(changed)
        for key, value in (("address", 0x55b), ("validity", -1), ("data_hex", "00" * 16),
                           ("data_hex", "21 " * 16)):
            changed = copy.deepcopy(document)
            changed["efuse"][key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                encoder.build_profile(changed)
        document["efuse"]["validity"] = 0x87654321
        document["provenance_sha256"] = "ab" * 32
        self.assertEqual(encoder.build_profile(document)[72:104], bytes([0xab]) * 32)
        self.assertEqual(struct.unpack_from("<I", encoder.build_profile(document), 108)[0], 0x87654321)

    def test_json_duplicates_nonfinite_bounded_input_and_valid_read(self):
        cache = Path(__file__).resolve().parent.parent / ".zig-cache"
        cache.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="board-json-", dir=cache) as directory:
            path = Path(directory) / "facts.json"
            for data in (b'{"version":1,"version":2}', b'{"gain":NaN}', b'{"gain":Infinity}',
                         b" " * (encoder.MAX_JSON_SIZE + 1), b"\xff"):
                path.write_bytes(data)
                with self.subTest(data=data[:50]), self.assertRaises(ValueError):
                    encoder.read_document(path)
            source = fixture()
            path.write_text(json.dumps(source), encoding="utf-8")
            self.assertEqual(encoder.read_document(path), source)

    def test_device_path_aliases_reject_before_file_operations(self):
        for name in ("NUL.txt", "prn", "COM1.board", "lPt9.efi", "COM\u00b9.board",
                     "folder/AUX/facts.json", "file. ", "\\\\.\\PhysicalDrive0", "\\\\?\\C:\\foo"):
            with self.subTest(name=name), self.assertRaises(ValueError):
                encoder.ordinary_path(Path(name), output=True, windows=True)

    def test_atomic_publish_existing_file_and_race_are_preserved(self):
        cache = Path(__file__).resolve().parent.parent / ".zig-cache"
        cache.mkdir(exist_ok=True)
        data = encoder.build_profile(fixture())
        with tempfile.TemporaryDirectory(prefix="board-publish-", dir=cache) as directory:
            path = Path(directory) / "MT7922.board"
            encoder.write_profile(path, data)
            self.assertEqual(path.read_bytes(), data)
            with self.assertRaises(FileExistsError):
                encoder.write_profile(path, b"replacement")
            self.assertEqual(path.read_bytes(), data)
            encoder.write_profile(path, b"explicit replacement", force=True)
            self.assertEqual(path.read_bytes(), b"explicit replacement")
            race = Path(directory) / "race.board"
            real_link = encoder.os.link

            def competing_publish(source, destination):
                race.write_bytes(b"other publisher")
                return real_link(source, destination)

            with mock.patch.object(encoder.os, "link", side_effect=competing_publish):
                with self.assertRaises(FileExistsError):
                    encoder.write_profile(race, data)
            self.assertEqual(race.read_bytes(), b"other publisher")
            self.assertEqual(sorted(item.name for item in Path(directory).iterdir()),
                             ["MT7922.board", "race.board"])


if __name__ == "__main__":
    unittest.main()
