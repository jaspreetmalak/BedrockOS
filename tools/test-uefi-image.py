#!/usr/bin/env python3
"""Independently inspect Bedrock GPT/FAT32 images or run builder selftests.

Usage: python tools/test-uefi-image.py [INPUT.EFI OUTPUT.img]
No arguments run structural and corruption tests without writing image files.
"""

import binascii
import importlib.util
import os
from pathlib import Path
import struct
import sys
import unittest
from unittest import mock
import uuid


SECTOR = 512
DISK_BYTES = 64 * 1024 * 1024
ESP_GUID = uuid.UUID("c12a7328-f81f-11d2-ba4b-00a0c93ec93b").bytes_le


def require(condition, message):
    if not condition:
        raise ValueError(message)


def inspect_image(image, expected_payload):
    """Check both GPTs, FAT geometry/mirrors/backups and the complete file chain.

    This reader derives all FAT positions from the serialized BPB and does not
    import builder geometry or layout helpers.
    """
    require(len(image) == DISK_BYTES, "image must be exactly 64 MiB")
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
        for offset in range(0, len(data), 32):
            entry = data[offset:offset + 32]
            if entry[0] == 0:
                return records
            require(entry[0] != 0xE5 and entry[11] != 0x0F, "unexpected deleted/LFN entry")
            name = entry[:11]
            require(name not in records, "duplicate short directory name")
            first_cluster = struct.unpack_from("<H", entry, 20)[0] << 16 | struct.unpack_from("<H", entry, 26)[0]
            records[name] = (entry[11], first_cluster, struct.unpack_from("<I", entry, 28)[0])
        raise ValueError("directory lacks an end marker")

    root_entries = directory(root)
    require(set(root_entries) == {b"BEDROCK ESP", b"EFI        "}, "root directory entries")
    require(root_entries[b"BEDROCK ESP"] == (0x08, 0, 0), "volume-label entry")
    efi_attribute, efi_cluster, efi_size = root_entries[b"EFI        "]
    require(efi_attribute == 0x10 and efi_size == 0, "EFI directory attributes")
    efi_entries = directory(efi_cluster)
    require(set(efi_entries) == {b".          ", b"..         ", b"BOOT       "}, "EFI directory entries")
    require(efi_entries[b".          "] == (0x10, efi_cluster, 0) and
            efi_entries[b"..         "] == (0x10, 0, 0), "EFI dot entries")
    boot_attribute, boot_cluster, boot_size = efi_entries[b"BOOT       "]
    require(boot_attribute == 0x10 and boot_size == 0, "BOOT directory attributes")
    boot_entries = directory(boot_cluster)
    require(set(boot_entries) == {b".          ", b"..         ", b"BOOTX64 EFI"}, "BOOT directory entries")
    require(boot_entries[b".          "] == (0x10, boot_cluster, 0) and
            boot_entries[b"..         "] == (0x10, efi_cluster, 0), "BOOT dot entries")
    file_attribute, file_cluster, file_size = boot_entries[b"BOOTX64 EFI"]
    require(file_attribute == 0x20 and file_size == len(expected) and file_size > 0, "BOOTX64.EFI size/attributes")
    file_chain = chain(file_cluster)
    require(len(file_chain) == (file_size + cluster_bytes - 1) // cluster_bytes, "BOOTX64.EFI chain length")
    for index, cluster in enumerate(file_chain):
        position = index * cluster_bytes
        amount = min(cluster_bytes, file_size - position)
        data = cluster_data(cluster)
        require(data[:amount] == expected[position:position + amount], "BOOTX64.EFI payload differs")
        require(not any(data[amount:]), "BOOTX64.EFI final-cluster padding")
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
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    try:
        application, image_path = Path(sys.argv[1]), Path(sys.argv[2])
        builder = load_builder()
        builder.ordinary_path(application)
        builder.ordinary_path(image_path)
        require(image_path.stat().st_size == DISK_BYTES, "image must be exactly 64 MiB")
        with application.open("rb") as source:
            expected = source.read(builder.MAX_PAYLOAD_SIZE + 1)
        require(len(expected) <= builder.MAX_PAYLOAD_SIZE, "application exceeds ESP capacity")
        result = inspect_image(image_path.read_bytes(), expected)
    except (OSError, ValueError) as error:
        print(f"UEFI image check failed: {error}", file=sys.stderr)
        return 1
    print(f"UEFI image valid: {result['image_bytes']} bytes, FAT32 {result['data_clusters']} clusters, BOOTX64.EFI {result['file_bytes']} bytes")
    return 0


if __name__ == "__main__":
    sys.exit(main())
