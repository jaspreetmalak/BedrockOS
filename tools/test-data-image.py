#!/usr/bin/env python3
"""Structural checks for the dedicated Bedrock data-image formatter."""
import binascii
import importlib.util
from pathlib import Path
import struct
import tempfile
import unittest
from unittest import mock

spec = importlib.util.spec_from_file_location("make_data_image", Path(__file__).with_name("make-data-image.py"))
formatter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(formatter)


class DataImageTests(unittest.TestCase):
    def test_header_crc_geometry_and_initial_generation(self):
        image = formatter.build_image()
        self.assertEqual(len(image), 4 * 1024 * 1024)
        self.assertEqual(image[:8], b"BEDFS001")
        self.assertEqual(struct.unpack_from("<IIQQIIIIQ", image, 8),
                         (1, 512, 1, 8192, 4096, 32, 4096, 128, 32 * (64 + 128 + 4096)))
        self.assertEqual(struct.unpack_from("<II", image, 64), (2, 0))
        header = bytearray(image[:512])
        expected = struct.unpack_from("<I", header, 60)[0]
        header[60:64] = bytes(4)
        self.assertEqual(binascii.crc32(header) & 0xffffffff, expected)
        self.assertEqual(header[72:], bytes(440))

    def test_payload_root_padding_and_uncommitted_second_bank(self):
        image = formatter.build_image()
        length = struct.unpack_from("<Q", image, 48)[0]
        payload = image[512:512 + length]
        self.assertEqual(binascii.crc32(payload) & 0xffffffff, struct.unpack_from("<I", image, 56)[0])
        self.assertEqual(struct.unpack_from("<BBBBIQIIQ", payload), (1, 1, 0, 0, 1, 0, 0, 1, 0))
        self.assertEqual(payload[32:64], bytes(32))
        self.assertEqual(payload[64], ord("/"))
        self.assertEqual(payload[65:], bytes(length - 65))
        self.assertEqual(image[512 + length:], bytes(len(image) - 512 - length))
        self.assertEqual(image, formatter.build_image())

    def test_capacity_validation_is_bounded(self):
        for capacities in ((0, 4096, 128), (65536, 0, 1), (32, -1, 128),
                           (32, 4096, 0), (32, 4096, 65536), (64, 65536, 128)):
            with self.subTest(capacities=capacities), self.assertRaises(ValueError):
                formatter.build_image(*capacities)
        image = formatter.build_image(12, 64, 96)
        self.assertEqual(struct.unpack_from("<III", image, 36), (12, 64, 96))

    def test_reserved_device_paths_rejected_without_writes(self):
        for text in ("NUL", "NUL.txt", "prn", "con.efi", "COM1.img", "LPT9",
                     "COM\u00b9.bin", "folder/AUX/child.img", "name. ",
                     "\\\\.\\PhysicalDrive0", "\\\\?\\C:\\data.img"):
            with self.subTest(path=text), self.assertRaises(ValueError):
                formatter.validate_output(Path(text), windows=True)

    def test_existing_image_requires_explicit_force(self):
        # All generated fixtures remain under this workspace's cache.
        cache = Path(__file__).resolve().parent.parent / ".zig-cache"
        cache.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="data-image-test-", dir=cache) as directory:
            target = Path(directory) / "data.img"
            formatter.write_image(target)
            self.assertEqual(target.stat().st_size, formatter.IMAGE_SIZE)
            target.write_bytes(b"existing user data")
            with self.assertRaises(ValueError):
                formatter.write_image(target)
            self.assertEqual(target.read_bytes(), b"existing user data")
            formatter.write_image(target, force=True)
            self.assertEqual(target.read_bytes(), formatter.build_image())
            self.assertEqual(list(Path(directory).iterdir()), [target])

    def test_concurrent_publication_never_replaces_other_launchers_image(self):
        cache = Path(__file__).resolve().parent.parent / ".zig-cache"
        cache.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="data-image-race-", dir=cache) as directory:
            target = Path(directory) / "data.img"
            real_link = formatter.os.link

            def publish_competitor(source, destination):
                target.write_bytes(b"concurrent user data")
                return real_link(source, destination)

            with mock.patch.object(formatter.os, "link", side_effect=publish_competitor):
                with self.assertRaises(FileExistsError):
                    formatter.write_image(target)
            self.assertEqual(target.read_bytes(), b"concurrent user data")
            self.assertEqual(list(Path(directory).iterdir()), [target])


if __name__ == "__main__":
    unittest.main()
