#!/usr/bin/env python3
"""Independently inspect Bedrock GPT/FAT32 images or run builder selftests.

Usage: python tools/test-uefi-image.py [INPUT.EFI OUTPUT.img]
No arguments run structural and corruption tests without writing image files.
"""

import binascii
import argparse
import copy
import importlib.util
import hashlib
import os
from pathlib import Path
import struct
import sys
import tempfile
import unittest
from unittest import mock
import uuid


SECTOR = 512
DISK_BYTES = 64 * 1024 * 1024
ESP_GUID = uuid.UUID("c12a7328-f81f-11d2-ba4b-00a0c93ec93b").bytes_le


def require(condition, message):
    if not condition:
        raise ValueError(message)


def inspect_image(image, expected_payload, *, arch="x86_64", expected_firmware=None, expected_drivers=None, expected_apps=None):
    """Check both GPTs, FAT geometry/mirrors/backups and the complete file chain.

    This reader derives all FAT positions from the serialized BPB and does not
    import builder geometry or layout helpers.
    """
    require(len(image) == DISK_BYTES, "image must be exactly 64 MiB")
    if expected_apps is not None:
        spec = importlib.util.spec_from_file_location("bedrock_image_check_app_packages", Path(__file__).with_name("package-apps.py"))
        package = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(package)
        package.validate_archive(expected_apps, {"x86_64": "x86_64", "arm64": "aarch64", "riscv64": "riscv64"}[arch])
    raw = memoryview(image)
    expected = memoryview(expected_payload)
    sectors = len(image) // SECTOR

    def u16(offset):
        return struct.unpack_from("<H", raw, offset)[0]

    def u32(offset):
        return struct.unpack_from("<I", raw, offset)[0]

    require(raw[510:512] == b"\x55\xaa", "protective MBR signature")
    require(raw[446] == 0 and raw[450] == 0xEE and u32(454) == 1 and u32(458) == sectors - 1,
            "protective MBR partition coverage")
    require(not any(raw[462:510]), "protective MBR must have only one record")

    def header(lba, other_lba):
        offset = lba * SECTOR
        fields = struct.unpack_from("<8sIIIIQQQQ16sQIII", raw, offset)
        signature, revision, size, crc, reserved, my, alternate, first, last, guid, entries_lba, count, entry_size, entries_crc = fields
        require(signature == b"EFI PART" and revision == 0x00010000 and size == 92,
                "GPT signature, revision or header size")
        require(reserved == 0 and my == lba and alternate == other_lba, "GPT header locations")
        require(not any(raw[offset + size:offset + SECTOR]), "GPT header reserved bytes")
        checked_header = bytearray(raw[offset:offset + size])
        struct.pack_into("<I", checked_header, 16, 0)
        require(binascii.crc32(checked_header) & 0xFFFFFFFF == crc, "GPT header CRC")
        require(count == 128 and entry_size == 128, "GPT entry-array geometry")
        array_size = count * entry_size
        array_sectors = (array_size + SECTOR - 1) // SECTOR
        require(0 < entries_lba < sectors and entries_lba + array_sectors <= sectors, "GPT array bounds")
        require(first >= 2 + array_sectors and last < sectors - 1 - array_sectors and first <= last,
                "GPT usable LBA bounds")
        require((entries_lba + array_sectors <= first or entries_lba > last), "GPT array overlaps usable LBAs")
        entries = raw[entries_lba * SECTOR:entries_lba * SECTOR + array_size]
        require(binascii.crc32(entries) & 0xFFFFFFFF == entries_crc, "GPT array CRC")
        require(any(guid), "GPT disk GUID is empty")
        return fields, entries

    primary, entries = header(1, sectors - 1)
    secondary, backup_entries = header(sectors - 1, 1)
    require(primary[7:10] == secondary[7:10] and primary[11:] == secondary[11:], "GPT copies disagree")
    require(primary[10] == 2 and secondary[10] == sectors - 33, "GPT entry-array placement")
    require(entries == backup_entries, "mirrored GPT arrays disagree")
    require(entries[:16] == ESP_GUID and any(entries[16:32]), "EFI System Partition GUID")
    require(entries[16:32] != primary[9], "disk and partition GUIDs must differ")
    require(not any(entries[128:]), "GPT must contain exactly one partition")
    first, last, attributes = struct.unpack_from("<QQQ", entries, 32)
    require(primary[7] <= first <= last <= primary[8] and first % 2048 == 0 and attributes == 0,
            "ESP range, alignment or attributes")
    partition_sectors = last - first + 1
    base = first * SECTOR
    require(raw[base + 510:base + 512] == b"\x55\xaa", "FAT boot signature")
    require(raw[base] in (0xEB, 0xE9), "FAT boot jump")
    bytes_per_sector, sectors_per_cluster = u16(base + 11), raw[base + 13]
    reserved, fat_count = u16(base + 14), raw[base + 16]
    total, fat_sectors = u32(base + 32), u32(base + 36)
    root = u32(base + 44)
    fsinfo_sector, backup_sector = u16(base + 48), u16(base + 50)
    require(bytes_per_sector == SECTOR and sectors_per_cluster == 1, "FAT sector/cluster size")
    require(reserved >= 8 and fat_count == 2 and total == partition_sectors and fat_sectors > 0,
            "FAT reserved/total/FAT geometry")
    require(u16(base + 17) == 0 and u16(base + 19) == 0 and u16(base + 22) == 0,
            "FAT32 legacy BPB fields")
    require(u32(base + 28) == first and u16(base + 40) == 0 and u16(base + 42) == 0,
            "FAT hidden sectors, mirroring flags or version")
    data_start = reserved + fat_count * fat_sectors
    require(data_start < total and (first + data_start) % 8 == 0, "FAT data bounds/alignment")
    clusters = (total - data_start) // sectors_per_cluster
    require(65525 <= clusters < 0x0FFFFFF5 and fat_sectors * SECTOR // 4 >= clusters + 2,
            "FAT32 cluster count or FAT capacity")
    cluster_bytes = bytes_per_sector * sectors_per_cluster
    fat_start = base + reserved * SECTOR
    fat_length = fat_sectors * SECTOR
    fat = raw[fat_start:fat_start + fat_length]
    second_fat = raw[fat_start + fat_length:fat_start + 2 * fat_length]
    require(fat == second_fat, "mirrored FATs disagree")

    def fat_value(cluster):
        require(0 <= cluster < clusters + 2, "FAT cluster index outside data region")
        return struct.unpack_from("<I", fat, cluster * 4)[0] & 0x0FFFFFFF

    require(fat_value(0) == 0x0FFFFF00 | raw[base + 21] and fat_value(1) == 0x0FFFFFFF,
            "FAT reserved entries")
    require(0 < fsinfo_sector < reserved and 0 < backup_sector < reserved and
            backup_sector + fsinfo_sector < reserved, "FAT backup/FSInfo locations")
    require(raw[base:base + SECTOR] == raw[base + backup_sector * SECTOR:base + (backup_sector + 1) * SECTOR],
            "FAT backup boot sector differs")
    info = base + fsinfo_sector * SECTOR
    require(u32(info) == 0x41615252 and u32(info + 484) == 0x61417272 and u32(info + 508) == 0xAA550000,
            "FSInfo signatures")
    backup_info = base + (backup_sector + fsinfo_sector) * SECTOR
    require(raw[info:info + SECTOR] == raw[backup_info:backup_info + SECTOR], "backup FSInfo differs")
    free_clusters = sum(fat_value(cluster) == 0 for cluster in range(2, clusters + 2))
    require(u32(info + 488) == free_clusters, "FSInfo free cluster count")
    next_free = u32(info + 492)
    if free_clusters:
        require(2 <= next_free < clusters + 2 and fat_value(next_free) == 0, "FSInfo next free cluster")
    else:
        require(next_free == 0xFFFFFFFF, "full-volume FSInfo next free cluster")

    data_base = base + data_start * SECTOR
    allocated = set()
    long_names = {}

    def chain(start):
        chain_clusters = []
        current = start
        while True:
            require(2 <= current < clusters + 2, "FAT chain points outside data region")
            require(current not in allocated, "FAT chain cycle or cross-linked clusters")
            allocated.add(current)
            chain_clusters.append(current)
            following = fat_value(current)
            if following >= 0x0FFFFFF8:
                return chain_clusters
            require(following not in (0, 1, 0x0FFFFFF7), "FAT chain reaches free/reserved/bad cluster")
            current = following

    def cluster_data(cluster):
        offset = data_base + (cluster - 2) * cluster_bytes
        require(offset + cluster_bytes <= base + total * SECTOR, "cluster extends past ESP")
        return raw[offset:offset + cluster_bytes]

    def directory(start):
        data = b"".join(bytes(cluster_data(cluster)) for cluster in chain(start))
        records = {}
        pending = []
        for offset in range(0, len(data), 32):
            entry = data[offset:offset + 32]
            if entry[0] == 0:
                require(not pending, "dangling FAT LFN records")
                return records
            require(entry[0] != 0xE5, "unexpected deleted entry")
            if entry[11] == 0x0F:
                number = entry[0] & 0x3F
                require(1 <= number <= 20 and entry[0] & 0x80 == 0 and entry[12] == 0 and entry[26:28] == bytes(2), "invalid FAT LFN fields")
                if not pending:
                    require(entry[0] & 0x40, "FAT LFN missing final flag")
                else:
                    require(entry[0] & 0x40 == 0 and number == pending[-1][0] - 1 and entry[13] == pending[0][1], "FAT LFN sequence or checksum")
                words = struct.unpack_from("<5H", entry, 1) + struct.unpack_from("<6H", entry, 14) + struct.unpack_from("<2H", entry, 28)
                pending.append((number, entry[13], words))
                continue
            name = entry[:11]
            require(name not in records, "duplicate short directory name")
            if pending:
                require(pending[-1][0] == 1 and len(pending) == pending[0][0], "incomplete FAT LFN sequence")
                checksum = 0
                for byte in name:
                    checksum = (((checksum & 1) << 7) + (checksum >> 1) + byte) & 255
                require(checksum == pending[0][1], "FAT LFN short-name checksum")
                words = sum((list(record[2]) for record in reversed(pending)), [])
                if 0 in words:
                    boundary = words.index(0)
                    require(all(word == 0xFFFF for word in words[boundary + 1:]), "FAT LFN padding")
                    words = words[:boundary]
                require(0 < len(words) <= 255 and 0xFFFF not in words, "FAT LFN name extent")
                try:
                    decoded = struct.pack("<" + "H" * len(words), *words).decode("utf-16le")
                except UnicodeDecodeError as error:
                    raise ValueError("invalid FAT LFN UTF-16") from error
                require(decoded not in (".", "..") and not any(character in '\\/:*?"<>|' or ord(character) < 32 for character in decoded), "invalid FAT LFN name")
                require(decoded.casefold() not in {value.casefold() for (owner, _), value in long_names.items() if owner == start}, "duplicate FAT long name")
                long_names[start, name] = decoded
                pending.clear()
            first_cluster = struct.unpack_from("<H", entry, 20)[0] << 16 | struct.unpack_from("<H", entry, 26)[0]
            records[name] = (entry[11], first_cluster, struct.unpack_from("<I", entry, 28)[0])
        raise ValueError("directory lacks an end marker")

    root_entries = directory(root)
    require(set(root_entries) == {b"BEDROCK ESP", b"EFI        "}, "root directory entries")
    require(root_entries[b"BEDROCK ESP"] == (0x08, 0, 0), "volume-label entry")
    efi_attribute, efi_cluster, efi_size = root_entries[b"EFI        "]
    require(efi_attribute == 0x10 and efi_size == 0, "EFI directory attributes")
    efi_entries = directory(efi_cluster)
    has_bedrock = expected_firmware is not None or expected_drivers is not None or expected_apps is not None
    require(set(efi_entries) == {b".          ", b"..         ", b"BOOT       "} | ({b"BEDROCK    "} if has_bedrock else set()), "EFI directory entries")
    require(efi_entries[b".          "] == (0x10, efi_cluster, 0) and
            efi_entries[b"..         "] == (0x10, 0, 0), "EFI dot entries")
    boot_attribute, boot_cluster, boot_size = efi_entries[b"BOOT       "]
    require(boot_attribute == 0x10 and boot_size == 0, "BOOT directory attributes")
    boot_entries = directory(boot_cluster)
    short_boot = {"x86_64": b"BOOTX64 EFI", "arm64": b"BOOTAA64EFI", "riscv64": b"BOOTRI~1EFI"}[arch]
    require(set(boot_entries) == {b".          ", b"..         ", short_boot}, "BOOT directory entries")
    if arch == "riscv64":
        require(long_names.get((boot_cluster, short_boot)) == "BOOTRISCV64.EFI", "RISC-V removable LFN")
    require(boot_entries[b".          "] == (0x10, boot_cluster, 0) and
            boot_entries[b"..         "] == (0x10, efi_cluster, 0), "BOOT dot entries")
    file_attribute, file_cluster, file_size = boot_entries[short_boot]
    require(file_attribute == 0x20 and file_size == len(expected) and file_size > 0, "BOOTX64.EFI size/attributes")
    file_chain = chain(file_cluster)
    require(len(file_chain) == (file_size + cluster_bytes - 1) // cluster_bytes, "BOOTX64.EFI chain length")
    for index, cluster in enumerate(file_chain):
        position = index * cluster_bytes
        amount = min(cluster_bytes, file_size - position)
        data = cluster_data(cluster)
        require(data[:amount] == expected[position:position + amount], "BOOTX64.EFI payload differs")
        require(not any(data[amount:]), "BOOTX64.EFI final-cluster padding")
    if has_bedrock:
        attributes, bedrock_cluster, size = efi_entries[b"BEDROCK    "]
        require(attributes == 0x10 and size == 0, "Bedrock directory attributes")
        bedrock = directory(bedrock_cluster)
        expected_children = {b".          ", b"..         "}
        if expected_firmware is not None:
            expected_children.add(b"FIRMWARE   ")
        if expected_drivers is not None:
            expected_children.add(b"DRIVERS    ")
        if expected_apps is not None:
            expected_children.add(b"APPS       ")
        require(set(bedrock) == expected_children and bedrock[b".          "] == (0x10, bedrock_cluster, 0) and bedrock[b"..         "] == (0x10, efi_cluster, 0), "Bedrock directory entries")
        for folder, expected_assets, label in ((b"FIRMWARE   ", expected_firmware, "Firmware"),
                                               (b"DRIVERS    ", expected_drivers, "Drivers"),
                                               (b"APPS       ", {"apps.bap": expected_apps} if expected_apps is not None else None, "Apps")):
            if expected_assets is None:
                continue
            attributes, asset_cluster, size = bedrock[folder]
            require(attributes == 0x10 and size == 0, label + " directory attributes")
            asset_directory = directory(asset_cluster)
            require(asset_directory[b".          "] == (0x10, asset_cluster, 0) and asset_directory[b"..         "] == (0x10, bedrock_cluster, 0), label + " dot entries")
            named = {long_names.get((asset_cluster, name)): record for name, record in asset_directory.items() if name not in (b".          ", b"..         ")}
            require(set(named) == set(expected_assets), label + " long names differ")
            for name, expected_bytes in expected_assets.items():
                attributes, start, size = named[name]
                require(attributes == 0x20 and size == len(expected_bytes), label + " size/attributes")
                blocks = chain(start)
                require(len(blocks) == (size + cluster_bytes - 1) // cluster_bytes, label + " chain length")
                for index, cluster in enumerate(blocks):
                    position = index * cluster_bytes
                    amount = min(cluster_bytes, size - position)
                    data = cluster_data(cluster)
                    require(data[:amount] == expected_bytes[position:position + amount], label + " payload differs")
                    require(not any(data[amount:]), label + " final-cluster padding")
    require(sum(fat_value(cluster) != 0 for cluster in range(2, clusters + 2)) == len(allocated),
            "orphaned FAT allocations")
    return {
        "image_bytes": len(image), "file_bytes": file_size, "data_clusters": clusters,
        "free_clusters": free_clusters, "fat_offset": fat_start, "fat_bytes": fat_length,
        "file_offset": data_base + (file_cluster - 2) * cluster_bytes, "fsinfo_offset": info,
        "backup_fsinfo_offset": backup_info,
    }


def load_builder():
    spec = importlib.util.spec_from_file_location("bedrock_uefi_image", Path(__file__).with_name("make-uefi-image.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class ImageTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.builder = load_builder()
        cls.payload = b"MZ" + bytes(range(256)) * 37 + b"partial-cluster-tail"
        cls.image = cls.builder.build_image(cls.payload)
        cls.layout = inspect_image(cls.image, cls.payload)

    def corrupted(self, changes, message):
        originals = [(offset, bytes(self.image[offset:offset + len(value)])) for offset, value in changes]
        try:
            for offset, value in changes:
                self.image[offset:offset + len(value)] = value
            with self.assertRaisesRegex(ValueError, message):
                inspect_image(self.image, self.payload)
        finally:
            for offset, value in originals:
                self.image[offset:offset + len(value)] = value

    def test_structure_and_exact_partial_cluster_payload(self):
        self.assertGreaterEqual(self.layout["data_clusters"], 65525)
        self.assertEqual(self.layout["file_bytes"], len(self.payload))

    def test_primary_and_backup_gpt_crcs_detect_corruption(self):
        for lba in (1, len(self.image) // SECTOR - 1):
            self.corrupted([(lba * SECTOR + 56, b"\xff")], "GPT header CRC")
        self.corrupted([(2 * SECTOR + 160, b"\xff")], "GPT array CRC")

    def test_mirrored_fats_and_shortened_chain_detect_corruption(self):
        first = self.layout["fat_offset"] + 5 * 4
        second = first + self.layout["fat_bytes"]
        self.corrupted([(first, b"\xff\xff\xff\x0f")], "mirrored FATs")
        self.corrupted([(first, b"\xff\xff\xff\x0f"), (second, b"\xff\xff\xff\x0f")], "chain length")

    def test_fsinfo_and_file_bytes_detect_corruption(self):
        bad_count = struct.pack("<I", self.layout["free_clusters"] + 1)
        self.corrupted([(self.layout["fsinfo_offset"] + 488, bad_count),
                        (self.layout["backup_fsinfo_offset"] + 488, bad_count)], "FSInfo free cluster count")
        self.corrupted([(self.layout["file_offset"], b"\xff")], "payload differs")

    def test_single_sector_boundary_and_determinism(self):
        for size in (1, 512, 513):
            payload = b"x" * size
            image = self.builder.build_image(payload)
            inspect_image(image, payload)
        self.assertEqual(self.image, self.builder.build_image(self.payload))

    def test_empty_and_oversize_payloads_are_rejected_before_image_creation(self):
        with self.assertRaisesRegex(ValueError, "empty"):
            self.builder.build_image(b"")
        with self.assertRaisesRegex(ValueError, "capacity"):
            self.builder.build_image(b"x" * (self.builder.MAX_PAYLOAD_SIZE + 1))

    def test_full_capacity_uses_last_data_cluster_and_has_no_free_cluster(self):
        payload = b"x" * self.builder.MAX_PAYLOAD_SIZE
        image = self.builder.build_image(payload)
        result = inspect_image(image, payload)
        self.assertEqual(result["free_clusters"], 0)

    def firmware_fixture(self):
        data = {
            "WIFI_MT7922_patch_mcu_1_1_hdr.bin": b"patch-model" * 67,
            "WIFI_RAM_CODE_MT7922_1.bin": b"ram-model" * 125,
            "LICENCE.mediatek": b"model licence only - not a distributable vendor licence",
        }
        expected = {name: (len(value), hashlib.sha256(value).hexdigest()) for name, value in data.items()}
        return data, expected

    def profile_fixture(self):
        data = bytearray(128 + 192)
        data[:8] = b"BRDBRD01"
        data[40:72] = hashlib.sha256(data).digest()
        return bytes(data)

    def driver_fixture(self):
        # Synthetic bytes are checked by the ordinary production metadata/ELF
        # validator. There is no fixture switch in the image builder.
        spec = importlib.util.spec_from_file_location("image_driver_test_helpers", Path(__file__).with_name("test-driver-packages.py"))
        helper = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(helper)
        data = helper.synthetic_module()
        metadata = {"schema_version": 1, "id": "org.bedrock.mt7922", "package_version": "0.1.0",
                    "architecture": "x86_64", "driver_abi": {"major": 1, "minor": 0},
                    "module": {"file": "mt7922.bdm", "byte_length": len(data), "sha256": hashlib.sha256(data).hexdigest()}}
        manifest = {"schema_version": 1, "architecture": "x86_64", "driver_abi": {"major": 1, "minor": 0}, "packages": [metadata]}
        return {"manifest.json": helper.packager.json_bytes(manifest), "mt7922.bdm": data}, manifest, helper

    def apps_fixture(self, arch="x86_64", variant=0):
        package = self.builder.app_packager()
        catalogue = package.read_catalogue(package.DEFAULT_CATALOGUE)
        machine = package.ARCHITECTURES[arch]
        executable = bytearray(65)
        executable[:7] = b"\x7fELF\x02\x01\x01"
        struct.pack_into("<HHI", executable, 16, 2, machine, 1)
        struct.pack_into("<H", executable, 52, 64)
        executable[-1] = variant
        return package.build_archive(catalogue, {app["name"]: bytes(executable) for app in catalogue}, arch)

    def test_installed_apps_extract_exactly_on_all_three_architectures(self):
        for arch in ("x86_64", "arm64", "riscv64"):
            with self.subTest(arch=arch):
                apps = self.apps_fixture(arch)
                image = self.builder.build_image(self.payload, arch=arch, apps=apps)
                inspect_image(image, self.payload, arch=arch, expected_apps=apps)
                self.assertEqual(image, self.builder.build_image(self.payload, arch=arch, apps=apps))
                with self.assertRaisesRegex(ValueError, "EFI directory entries"):
                    inspect_image(image, self.payload, arch=arch)

    def test_apps_coexist_with_firmware_and_selected_drivers(self):
        apps = self.apps_fixture()
        drivers, _, _ = self.driver_fixture()
        firmware, expected = self.firmware_fixture()
        with mock.patch.object(self.builder, "FIRMWARE_FILES", expected):
            image = self.builder.build_image(self.payload, apps=apps, drivers=drivers, firmware=firmware)
            inspect_image(image, self.payload, expected_apps=apps, expected_drivers=drivers, expected_firmware=firmware)

    def test_apps_wrong_target_and_corrupt_hashes_fail_before_image_creation(self):
        apps = self.apps_fixture()
        for arch in ("arm64", "riscv64"):
            with self.subTest(arch=arch), self.assertRaisesRegex(ValueError, "header"):
                self.builder.build_image(self.payload, arch=arch, apps=apps)
        for offset in (64, len(apps) - 1):
            changed = bytearray(apps)
            changed[offset] ^= 1
            with self.subTest(offset=offset), self.assertRaises(ValueError):
                self.builder.build_image(self.payload, apps=changed)
            with self.assertRaises(ValueError):
                inspect_image(self.image, self.payload, expected_apps=changed)

    def test_apps_disk_payload_corruption_and_identity_binding(self):
        apps = self.apps_fixture()
        image = self.builder.build_image(self.payload, apps=apps)
        offset = image.find(apps)
        self.assertGreater(offset, 0)
        self.assertEqual(offset, image.rfind(apps))
        image[offset + len(apps) - 1] ^= 1
        with self.assertRaisesRegex(ValueError, "Apps payload differs"):
            inspect_image(image, self.payload, expected_apps=apps)
        original = self.builder.build_image(self.payload, apps=apps)
        changed = self.builder.build_image(self.payload, apps=self.apps_fixture(variant=1))
        self.assertNotEqual(original[512:604], self.image[512:604])
        self.assertNotEqual(original[512:604], changed[512:604])

    def test_explicit_apps_file_roundtrip_and_output_aliases_are_safe(self):
        apps = self.apps_fixture()
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            source = directory / "apps.bap"
            source.write_bytes(apps)
            application = directory / "boot.efi"
            application.write_bytes(self.payload)
            output = directory / "image.img"
            self.builder.write_image(application, output, apps_path=source)
            original = output.read_bytes()
            inspect_image(original, self.payload, expected_apps=apps)
            with self.assertRaisesRegex(ValueError, "different files"):
                self.builder.write_image(application, source, apps_path=source)
            self.assertEqual(apps, source.read_bytes())
            source.write_bytes(apps[:-1] + b"!")
            with self.assertRaisesRegex(ValueError, "hash mismatch"):
                self.builder.write_image(application, output, apps_path=source)
            self.assertEqual(original, output.read_bytes())

    def test_apps_special_sources_are_rejected_before_opening(self):
        with self.assertRaisesRegex(ValueError, "ordinary files"):
            self.builder.load_apps(Path(__file__).parent)
        with mock.patch.object(self.builder, "os") as operating_system:
            operating_system.name = "nt"
            with self.assertRaisesRegex(ValueError, "device/namespace"):
                self.builder.load_apps(Path("//./PhysicalDrive0"))

    def test_driver_files_and_firmware_roundtrip_and_identity_bind_all_bytes(self):
        drivers, _, _ = self.driver_fixture()
        firmware, expected = self.firmware_fixture()
        with mock.patch.object(self.builder, "FIRMWARE_FILES", expected):
            for assets in (None, firmware):
                image = self.builder.build_image(self.payload, drivers=drivers, firmware=assets)
                inspect_image(image, self.payload, expected_drivers=drivers, expected_firmware=assets)
                self.assertEqual(image, self.builder.build_image(self.payload, drivers=dict(reversed(list(drivers.items()))), firmware=assets))
                self.assertNotEqual(image[512:604], self.builder.build_image(self.payload, firmware=assets)[512:604])

    def test_other_architectures_can_package_empty_selected_driver_manifests(self):
        package = self.builder.driver_packager()
        for arch, driver_arch in (("arm64", "aarch64"), ("riscv64", "riscv64")):
            manifest = {"schema_version": 1, "architecture": driver_arch, "driver_abi": {"major": 1, "minor": 0}, "packages": []}
            assets = {"manifest.json": package.json_bytes(manifest)}
            with self.subTest(arch=arch):
                inspect_image(self.builder.build_image(self.payload, arch=arch, drivers=assets), self.payload, arch=arch, expected_drivers=assets)

    def test_driver_preflight_rejects_wrong_hash_target_unknown_packages_and_extra_files(self):
        drivers, manifest, helper = self.driver_fixture()
        changed = dict(drivers)
        changed["mt7922.bdm"] = changed["mt7922.bdm"][:-1] + b"!"
        with self.assertRaisesRegex(ValueError, "SHA-256"):
            self.builder.build_image(self.payload, drivers=changed)
        for mode in ("architecture", "unknown", "unsupported-platform", "duplicate", "fixture-id"):
            metadata = copy.deepcopy(manifest)
            assets = dict(drivers)
            if mode == "architecture":
                metadata["architecture"] = "riscv64"
            elif mode == "unknown":
                metadata["packages"][0]["id"] = "org.bedrock.fixture"
            elif mode == "unsupported-platform":
                metadata["architecture"] = metadata["packages"][0]["architecture"] = "aarch64"
            elif mode == "duplicate":
                metadata["packages"].append(copy.deepcopy(metadata["packages"][0]))
            else:
                data = bytearray(assets["mt7922.bdm"])
                data[0x180 + 20 + 40:0x180 + 20 + 64] = b"org.bedrock.fixture" + bytes(5)
                assets["mt7922.bdm"] = bytes(data)
                metadata["packages"][0]["module"]["sha256"] = hashlib.sha256(data).hexdigest()
            assets["manifest.json"] = helper.packager.json_bytes(metadata)
            with self.subTest(mode=mode), self.assertRaises(ValueError):
                self.builder.build_image(self.payload, arch="arm64" if mode == "unsupported-platform" else "x86_64", drivers=assets)
        for assets in ({}, {"manifest.json": drivers["manifest.json"]}, dict(drivers, unexpected=b"extra")):
            with self.subTest(names=list(assets)), self.assertRaises(ValueError):
                self.builder.build_image(self.payload, drivers=assets)

    def test_selected_driver_directory_safe_alias_and_exact_files(self):
        drivers, _, _ = self.driver_fixture()
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            directory = root / "drivers"
            directory.mkdir()
            for name, data in drivers.items():
                (directory / name).write_bytes(data)
            application = root / "app.efi"
            application.write_bytes(self.payload)
            output = root / "image.img"
            self.builder.write_image(application, output, driver_dir=directory)
            inspect_image(output.read_bytes(), self.payload, expected_drivers=drivers)
            for name in drivers:
                source = directory / name
                original = source.read_bytes()
                with self.subTest(alias=name), self.assertRaisesRegex(ValueError, "different files"):
                    self.builder.write_image(application, source, driver_dir=directory)
                self.assertEqual(source.read_bytes(), original)
            (directory / "extra.bdm").write_bytes(b"undeclared")
            before = output.read_bytes()
            with self.assertRaisesRegex(ValueError, "undeclared"):
                self.builder.write_image(application, output, driver_dir=directory)
            self.assertEqual(output.read_bytes(), before)

    def test_local_package_convenience_matches_selected_tree_and_guards_inputs(self):
        _, _, helper = self.driver_fixture()
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            modules = root / "modules"
            modules.mkdir()
            directory, _ = helper.write_package(modules)
            selected = root / "selected"
            helper.packager.stage_packages(helper.catalogue(), helper.inventory(), "x86_64", modules, selected, True)
            expected = self.builder.load_driver_directory(selected / "EFI/Bedrock/Drivers")
            application = root / "app.efi"
            application.write_bytes(self.payload)
            output = root / "image.img"
            self.builder.write_image(application, output, driver_packages=modules, all_compatible=True)
            inspect_image(output.read_bytes(), self.payload, expected_drivers=expected)
            for name in ("package.json", "mt7922.bdm"):
                source = directory / name
                original = source.read_bytes()
                with self.subTest(alias=name), self.assertRaisesRegex(ValueError, "different files"):
                    self.builder.write_image(application, source, driver_packages=modules, all_compatible=True)
                self.assertEqual(source.read_bytes(), original)
            before = output.read_bytes()
            with self.assertRaisesRegex(ValueError, "inventory"):
                self.builder.write_image(application, output, driver_packages=modules)
            self.assertEqual(output.read_bytes(), before)

    def test_actual_cached_module_selected_and_serialized_when_built(self):
        root = Path(__file__).resolve().parent.parent
        source = root / "zig-out/drivers"
        if not (source / "x86_64/mt7922/package.json").is_file():
            self.skipTest("actual driver build unavailable; no build or download is attempted")
        assets = self.builder.select_driver_assets(source, all_compatible=True)
        image = self.builder.build_image(self.payload, drivers=assets)
        inspect_image(image, self.payload, expected_drivers=assets)
        self.assertEqual(assets["mt7922.bdm"], (source / "x86_64/mt7922/mt7922.bdm").read_bytes())

    def test_all_removable_names_and_firmware_lfn_bytes_extract_exactly(self):
        assets, expected = self.firmware_fixture()
        assets[self.builder.PROFILE_NAME] = self.profile_fixture()
        with mock.patch.object(self.builder, "FIRMWARE_FILES", expected):
            for arch in ("x86_64", "arm64", "riscv64"):
                with self.subTest(arch=arch):
                    image = self.builder.build_image(self.payload, arch=arch, firmware=assets)
                    inspect_image(image, self.payload, arch=arch, expected_firmware=assets)
            first = self.builder.build_image(self.payload, arch="riscv64", firmware=assets)
            self.assertEqual(first, self.builder.build_image(self.payload, arch="riscv64", firmware=dict(reversed(list(assets.items())))))
        for arch in ("arm64", "riscv64"):
            inspect_image(self.builder.build_image(self.payload, arch=arch), self.payload, arch=arch)

    def test_lfn_checksum_sequence_and_padding_corruption_are_detected(self):
        assets, expected = self.firmware_fixture()
        with mock.patch.object(self.builder, "FIRMWARE_FILES", expected):
            image = self.builder.build_image(self.payload, firmware=assets)
        inspect_image(image, self.payload, expected_firmware=assets)
        # The first asset is LICENCE.mediatek. Its highest LFN entry is at the
        # Firmware directory's byte64, identified from its UTF-16 tail.
        marker = "tek".encode("utf-16le") + bytes(2)
        candidates = [offset for offset in range(self.layout["file_offset"], len(image) - 32, 32)
                      if image[offset + 11] == 0x0F and image[offset + 1:offset + 9] == marker]
        self.assertEqual(len(candidates), 1)
        entry = candidates[0]
        for position, value, message in ((entry + 13, image[entry + 13] ^ 1, "checksum"),
                                         (entry, 0x41, "sequence"),
                                         (entry + 9, 0x00, "padding")):
            with self.subTest(position=position):
                previous = image[position]
                image[position] = value
                with self.assertRaisesRegex(ValueError, message):
                    inspect_image(image, self.payload, expected_firmware=assets)
                image[position] = previous

    def test_firmware_missing_wrong_hash_license_and_profile_rejected_preflight(self):
        assets, expected = self.firmware_fixture()
        with mock.patch.object(self.builder, "FIRMWARE_FILES", expected):
            bad = dict(assets)
            bad.pop("LICENCE.mediatek")
            with self.assertRaisesRegex(ValueError, "licence"):
                self.builder.build_image(self.payload, firmware=bad)
            for name in assets:
                bad = dict(assets)
                bad[name] = b"!" + bad[name][1:]
                with self.subTest(name=name), self.assertRaisesRegex(ValueError, "size/hash"):
                    self.builder.build_image(self.payload, firmware=bad)
            for profile in (b"bad", bytes(128), self.profile_fixture()[:-1], self.profile_fixture() + bytes(192)):
                bad = dict(assets)
                bad[self.builder.PROFILE_NAME] = profile
                with self.assertRaisesRegex(ValueError, "MT7922.board"):
                    self.builder.build_image(self.payload, firmware=bad)
            bad = dict(assets, unexpected=b"not packaged")
            with self.assertRaisesRegex(ValueError, "exact pinned"):
                self.builder.build_image(self.payload, firmware=bad)
        with self.assertRaisesRegex(ValueError, "unsupported"):
            self.builder.build_image(self.payload, arch="other")

    def test_explicit_firmware_directory_roundtrip_and_output_alias_are_safe(self):
        assets, expected = self.firmware_fixture()
        with tempfile.TemporaryDirectory() as temporary, mock.patch.object(self.builder, "FIRMWARE_FILES", expected):
            directory = Path(temporary)
            for name, data in assets.items():
                (directory / name).write_bytes(data)
            application = directory / "app.efi"
            application.write_bytes(self.payload)
            output = directory / "image.img"
            self.builder.write_image(application, output, arch="arm64", firmware_dir=directory)
            inspect_image(output.read_bytes(), self.payload, arch="arm64", expected_firmware=assets)
            firmware_output = directory / "LICENCE.mediatek"
            before = firmware_output.read_bytes()
            with self.assertRaisesRegex(ValueError, "different files"):
                self.builder.write_image(application, firmware_output, firmware_dir=directory)
            self.assertEqual(before, firmware_output.read_bytes())
            (directory / "LICENCE.mediatek").unlink()
            with self.assertRaisesRegex(ValueError, "does not exist"):
                self.builder.write_image(application, output, firmware_dir=directory)
            # Input failure never replaces the prior complete image.
            inspect_image(output.read_bytes(), self.payload, arch="arm64", expected_firmware=assets)

    def test_firmware_directory_rejects_special_or_symlink_sources(self):
        with self.assertRaisesRegex(ValueError, "ordinary directory"):
            self.builder.load_firmware(Path(__file__))
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            (directory / next(iter(self.builder.FIRMWARE_FILES))).mkdir()
            with self.assertRaisesRegex(ValueError, "ordinary files"):
                self.builder.load_firmware(directory)
        # No device pathname is opened, even with the optional directory path.
        with mock.patch.object(self.builder, "os") as operating_system:
            operating_system.name = "nt"
            with self.assertRaisesRegex(ValueError, "device/namespace"):
                self.builder.load_firmware(Path("//./PhysicalDrive0"))

    def test_real_pinned_vendor_bytes_extract_on_all_three_profiles_when_cached(self):
        cache = Path(__file__).resolve().parent.parent / ".zig-cache/upstream-wifi/firmware/afabaf773c4c2e2c841429933a6a084a5af4d14d"
        paths = {name: cache / ("LICENSES" if name == "LICENCE.mediatek" else "mediatek") / name for name in self.builder.FIRMWARE_FILES}
        if not all(path.is_file() for path in paths.values()):
            self.skipTest("pinned linux-firmware cache is not available; no download is attempted")
        assets = {}
        for name, path in paths.items():
            self.builder.ordinary_path(path)
            with path.open("rb") as source:
                assets[name] = source.read(self.builder.FIRMWARE_FILES[name][0] + 1)
        self.builder.validate_firmware(assets)
        for arch in ("x86_64", "arm64", "riscv64"):
            with self.subTest(arch=arch):
                image = self.builder.build_image(self.payload, arch=arch, firmware=assets)
                inspect_image(image, self.payload, arch=arch, expected_firmware=assets)

    def test_file_only_paths_and_same_file_output_are_rejected_before_writing(self):
        script = Path(__file__)
        with self.assertRaisesRegex(ValueError, "different files"):
            self.builder.write_image(script, script)
        with self.assertRaisesRegex(ValueError, "ordinary files"):
            self.builder.ordinary_path(script.parent, output=True)
        with self.assertRaisesRegex(ValueError, "device/namespace"):
            self.builder.validate_path_syntax(r"\\.\PhysicalDrive0", windows=True)
        self.check_windows_device_aliases()
        self.check_windows_and_posix_names()
        if os.name == "nt":
            self.check_windows_output_aliases_before_write()

    def check_windows_device_aliases(self):
        bases = ["CON", "PRN", "AUX", "NUL", "CONIN$", "CONOUT$"]
        bases += [prefix + digit for prefix in ("COM", "LPT") for digit in "123456789\u00b9\u00b2\u00b3"]
        for base in bases:
            for name in (base, base.lower() + ".img", base + ".tar.gz", base + ".", base + " ", base + " .txt"):
                for path in (name, "ordinary/" + name, "ordinary/" + name + "/disk.img"):
                    with self.subTest(path=path), self.assertRaisesRegex(ValueError, "DOS device"):
                        self.builder.validate_path_syntax(path, windows=True)
        for path in (r"\\.\PhysicalDrive0", r"\\?\C:\disk.img", "//./PhysicalDrive0"):
            with self.subTest(path=path), self.assertRaisesRegex(ValueError, "device/namespace"):
                self.builder.validate_path_syntax(path, windows=True)

    def check_windows_and_posix_names(self):
        for path in ("disk.img.", "disk.img ", "directory./disk.img", "disk.img:stream"):
            with self.subTest(path=path), self.assertRaisesRegex(ValueError, "unsupported"):
                self.builder.validate_path_syntax(path, windows=True)
        for path in ("disk.img", "console.img", "COM10.img", "LPT0.img", ".cache/disk.img", r"C:\ordinary\disk.img"):
            self.builder.validate_path_syntax(path, windows=True)
        for path in ("NUL.txt", "COM1.img", "disk.img.", "disk.img ", "disk.img:stream"):
            self.builder.validate_path_syntax(path, windows=False)
        if os.name != "nt":
            self.builder.ordinary_path(Path("NUL.txt"), output=True)

    def check_windows_output_aliases_before_write(self):
        with mock.patch.object(self.builder.tempfile, "NamedTemporaryFile", side_effect=AssertionError("unexpected write")) as temporary:
            for name in ("NUL.txt", "PRN", "CoM1.img", "NUL. ", "LPT\u00b2.img", "COM\u00b9.img", "ordinary/PRN.txt/disk.img"):
                with self.subTest(name=name), self.assertRaisesRegex(ValueError, "DOS device"):
                    self.builder.write_image(Path(__file__), Path(name))
            temporary.assert_not_called()


def main():
    if len(sys.argv) == 1:
        return 0 if unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(ImageTests)).wasSuccessful() else 1
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("application", type=Path)
    parser.add_argument("image", type=Path)
    parser.add_argument("--arch", choices=("x86_64", "arm64", "riscv64"), default="x86_64")
    parser.add_argument("--firmware-dir", type=Path)
    parser.add_argument("--apps", type=Path)
    drivers = parser.add_mutually_exclusive_group()
    drivers.add_argument("--driver-dir", type=Path)
    drivers.add_argument("--driver-packages", type=Path)
    parser.add_argument("--inventory", type=Path)
    parser.add_argument("--all-compatible", action="store_true")
    args = parser.parse_args()
    try:
        application, image_path = args.application, args.image
        builder = load_builder()
        builder.ordinary_path(application)
        builder.ordinary_path(image_path)
        require(image_path.stat().st_size == DISK_BYTES, "image must be exactly 64 MiB")
        with application.open("rb") as source:
            expected = source.read(builder.MAX_PAYLOAD_SIZE + 1)
        require(len(expected) <= builder.MAX_PAYLOAD_SIZE, "application exceeds ESP capacity")
        firmware = builder.load_firmware(args.firmware_dir) if args.firmware_dir is not None else None
        if args.driver_dir is not None and (args.inventory is not None or args.all_compatible):
            raise ValueError("selected driver directory cannot be combined with package selection options")
        if args.driver_packages is None and (args.inventory is not None or args.all_compatible):
            raise ValueError("inventory/offline selection requires --driver-packages")
        driver_assets = (builder.load_driver_directory(args.driver_dir, args.arch) if args.driver_dir is not None else
                         builder.select_driver_assets(args.driver_packages, args.arch, args.inventory, args.all_compatible) if args.driver_packages is not None else None)
        apps = builder.load_apps(args.apps, args.arch) if args.apps is not None else None
        result = inspect_image(image_path.read_bytes(), expected, arch=args.arch, expected_firmware=firmware, expected_drivers=driver_assets, expected_apps=apps)
    except (OSError, ValueError) as error:
        print(f"UEFI image check failed: {error}", file=sys.stderr)
        return 1
    print(f"UEFI image valid: {result['image_bytes']} bytes, FAT32 {result['data_clusters']} clusters, {builder.BOOT_NAMES[args.arch]} {result['file_bytes']} bytes")
    return 0


if __name__ == "__main__":
    sys.exit(main())
