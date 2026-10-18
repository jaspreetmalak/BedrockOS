#!/usr/bin/env python3
"""Portable negative and round-trip tests for installed application archives."""
import hashlib
import importlib.util
import json
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("bedrock_app_packages", Path(__file__).with_name("package-apps.py"))
packages = importlib.util.module_from_spec(spec)
spec.loader.exec_module(packages)


def elf(machine=62, length=65):
    data = bytearray(length)
    data[:7] = b"\x7fELF\x02\x01\x01"
    struct.pack_into("<HHI", data, 16, 2, machine, 1)
    struct.pack_into("<H", data, 52, 64)
    return bytes(data)


def catalogue():
    return [
        {"id": 101, "name": "org.bedrock.init", "version": 1, "entry": "/bundle/main.elf"},
        {"id": 102, "name": "org.bedrock.observer", "version": 1, "entry": "/bundle/main.elf"},
        {"id": 103, "name": "org.bedrock.worker", "version": 1, "entry": "/bundle/main.elf"},
    ]


def archive():
    return bytearray(packages.build_archive(catalogue(), {app["name"]: elf() for app in catalogue()}, "x86_64"))


def table_hash(data):
    count = struct.unpack_from("<I", data, 20)[0]
    data[32:64] = hashlib.sha256(data[64:64 + count * 160]).digest()


class Packages(unittest.TestCase):
    def test_all_architectures_allow_same_path_in_separate_app_identities(self):
        for architecture, machine in packages.ARCHITECTURES.items():
            data = packages.build_archive(catalogue(), {app["name"]: elf(machine) for app in catalogue()}, architecture)
            records = packages.validate_archive(data, architecture)
            self.assertEqual([101, 102, 103], [entry["id"] for entry in records])
            self.assertTrue(all(entry["entry"] == "/bundle/main.elf" for entry in records))
            self.assertTrue(all(entry["offset"] % 16 == 0 for entry in records))

    def test_reproducible_packaging(self):
        self.assertEqual(archive(), archive())

    def test_bad_or_duplicate_manifest_fields(self):
        for mutation in (lambda x: x[0].update(id=0), lambda x: x[0].update(id=True), lambda x: x[1].update(id=101), lambda x: x[1].update(name=x[0]["name"]), lambda x: x[0].update(permissions=0xffffffff), lambda x: x[0].update(version=2), lambda x: x[0].update(name="org..bedrock")):
            apps = catalogue()
            mutation(apps)
            with self.assertRaises(ValueError):
                packages.validate_catalogue({"format": "bedrock-apps-v1", "apps": apps})

    def test_catalogue_count_is_bounded(self):
        for apps in ([], catalogue() * 3):
            with self.assertRaises(ValueError):
                packages.validate_catalogue({"format": "bedrock-apps-v1", "apps": apps})

    def test_entry_paths_reject_traversal_ambiguous_bytes_and_non_bundle_paths(self):
        for path in ("/container/main.elf", "/bundle/../a.elf", "/bundle/./a.elf", "/bundle//a.elf", "/bundle/a\0.elf", "/bundle/a\\b.elf", "/bundle/a.elf/", "/bundle/a.txt", "/bundle/" + "a" * 60 + ".elf"):
            with self.assertRaises(ValueError):
                packages.validate_path(path)

    def test_inputs_exactly_match_catalogue(self):
        inputs = {app["name"]: elf() for app in catalogue()}
        for changed in (dict(list(inputs.items())[1:]), inputs | {"org.bedrock.foreign": elf()}):
            with self.assertRaises(ValueError):
                packages.build_archive(catalogue(), changed, "x86_64")

    def test_wrong_machine_and_dynamic_images_are_rejected(self):
        with self.assertRaises(ValueError):
            packages.validate_executable(elf(183), 62)
        data = bytearray(elf())
        struct.pack_into("<H", data, 16, 3)
        with self.assertRaises(ValueError):
            packages.validate_executable(data, 62)

    def test_architecture_version_and_header_fields(self):
        for offset, format, value in ((8, "<H", 2), (10, "<H", 183), (12, "<I", 63), (16, "<I", 159), (20, "<I", 9), (24, "<Q", 0)):
            data = archive()
            struct.pack_into(format, data, offset, value)
            with self.assertRaises(ValueError):
                packages.validate_archive(data, "x86_64")

    def test_table_and_executable_hash_corruption(self):
        for offset in (64, -1):
            data = archive()
            data[offset] ^= 1
            with self.assertRaises(ValueError):
                packages.validate_archive(data, "x86_64")

    def test_structurally_invalid_tables_with_correct_hash_are_rejected(self):
        for offset, format, value in ((64, "<Q", 0), (64 + 8, "<I", 2), (64 + 12, "<I", 3), (64 + 160, "<Q", 101), (64 + 112, "<Q", 0xffffffffffffffff), (64 + 120, "<Q", 0xffffffffffffffff)):
            data = archive()
            struct.pack_into(format, data, offset, value)
            table_hash(data)
            with self.assertRaises(ValueError):
                packages.validate_archive(data, "x86_64")

    def test_nonzero_string_padding(self):
        data = archive()
        data[64 + 16 + 31] = 1
        table_hash(data)
        with self.assertRaises(ValueError):
            packages.validate_archive(data, "x86_64")

    def test_nonzero_payload_padding_and_trailing_bytes(self):
        data = archive()
        second_offset = struct.unpack_from("<Q", data, 64 + 160 + 112)[0]
        data[second_offset - 1] = 1
        with self.assertRaises(ValueError):
            packages.validate_archive(data, "x86_64")
        data = archive() + b"\0"
        struct.pack_into("<Q", data, 24, len(data))
        with self.assertRaises(ValueError):
            packages.validate_archive(data, "x86_64")

    def test_duplicate_json_keys_are_rejected(self):
        with self.assertRaises(ValueError):
            json.loads('{"format":"bedrock-apps-v1","format":"other","apps":[]}', object_pairs_hook=packages.unique_object)

    def test_windows_device_aliases_are_rejected_without_probing_them(self):
        for path in (r"\\.\PhysicalDrive0", "//./PhysicalDrive0", r"\\?\C:\apps.bap", "NUL.bap", "sub/CoM1.elf", "PRN", "LPT\u00b2.bap", "apps.bap:stream", "apps.bap."):
            with self.subTest(path=path), self.assertRaises(ValueError):
                packages.validate_path_syntax(path, windows=True)
        for path in ("apps.bap", r"C:\ordinary\init.elf", "COM10.elf"):
            packages.validate_path_syntax(path, windows=True)

    def test_cli_creates_and_verifies_ordinary_file(self):
        with tempfile.TemporaryDirectory(prefix="bedrock-app-packages-") as directory:
            root = Path(directory)
            image = root / "main.elf"
            image.write_bytes(elf())
            target = root / "apps.bap"
            command = [sys.executable, str(Path(__file__).with_name("package-apps.py")), "--arch", "x86_64", "--output", str(target)]
            for app in catalogue():
                command.extend(["--app", app["name"] + "=" + str(image)])
            result = subprocess.run(command, text=True, capture_output=True)
            self.assertEqual(0, result.returncode, result.stderr)
            result = subprocess.run([sys.executable, command[1], "--arch", "x86_64", "--verify", str(target)], text=True, capture_output=True)
            self.assertEqual(0, result.returncode, result.stderr)
            self.assertEqual(3, len(json.loads(result.stdout)["apps"]))
            alias_command = list(command)
            alias_command[alias_command.index("--output") + 1] = str(image)
            result = subprocess.run(alias_command, text=True, capture_output=True)
            self.assertNotEqual(0, result.returncode)
            self.assertEqual(elf(), image.read_bytes())
            command[-1] = "org.bedrock.foreign=" + str(image)
            original = target.read_bytes()
            result = subprocess.run(command, text=True, capture_output=True)
            self.assertNotEqual(0, result.returncode)
            self.assertEqual(original, target.read_bytes())


if __name__ == "__main__":
    unittest.main()
