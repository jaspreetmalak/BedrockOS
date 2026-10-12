#!/usr/bin/env python3
"""Package one x86-64 UEFI application in a deterministic GPT/FAT32 image.

Python standard library only. Creates an ordinary image file; never formats,
mounts, or opens a host block device. See docs/uefi-image.md for the disk layout.
"""

import argparse
import binascii
import hashlib
import os
from pathlib import Path, PureWindowsPath
import stat
import struct
import sys
import tempfile
import uuid


SECTOR_SIZE = 512
IMAGE_SIZE = 64 * 1024 * 1024
DISK_SECTORS = IMAGE_SIZE // SECTOR_SIZE
ENTRY_COUNT = 128
ENTRY_SIZE = 128
ENTRY_SECTORS = ENTRY_COUNT * ENTRY_SIZE // SECTOR_SIZE
FIRST_USABLE = 2 + ENTRY_SECTORS
LAST_USABLE = DISK_SECTORS - ENTRY_SECTORS - 2
ESP_FIRST = 2048
ESP_LAST = LAST_USABLE
ESP_SECTORS = ESP_LAST - ESP_FIRST + 1
ESP_TYPE = uuid.UUID("c12a7328-f81f-11d2-ba4b-00a0c93ec93b")
END_OF_CHAIN = 0x0FFFFFFF
ROOT_CLUSTER = 2
EFI_CLUSTER = 3
BOOT_CLUSTER = 4
FILE_CLUSTER = 5
FAT_DATE = 0x0021  # 1980-01-01, the FAT epoch; fixed for reproducibility.


def geometry():
    """Return reserved sectors, sectors per FAT, and usable data clusters.

    One sector per cluster makes a 64 MiB image unambiguously FAT32. Adjust the
    reserved area so the data region also starts on a 4 KiB boundary.
    """
    entries_per_sector = SECTOR_SIZE // 4
    for reserved in range(32, 64):
        fat_sectors = (ESP_SECTORS - reserved + 2 + entries_per_sector + 1) // (
            entries_per_sector + 2
        )
        clusters = ESP_SECTORS - reserved - 2 * fat_sectors
        if (ESP_FIRST + reserved + 2 * fat_sectors) % 8 == 0:
            if clusters < 65525 or fat_sectors * entries_per_sector < clusters + 2:
                raise ValueError("internal FAT32 geometry is invalid")
            return reserved, fat_sectors, clusters
    raise ValueError("cannot align FAT32 data region")


RESERVED_SECTORS, FAT_SECTORS, CLUSTER_COUNT = geometry()
MAX_PAYLOAD_SIZE = (CLUSTER_COUNT - 3) * SECTOR_SIZE


def gpt_header(my_lba, other_lba, entries_lba, disk_guid, entries_crc):
    header = bytearray(SECTOR_SIZE)
    struct.pack_into(
        "<8sIIIIQQQQ16sQIII", header, 0,
        b"EFI PART", 0x00010000, 92, 0, 0,
        my_lba, other_lba, FIRST_USABLE, LAST_USABLE, disk_guid.bytes_le,
        entries_lba, ENTRY_COUNT, ENTRY_SIZE, entries_crc,
    )
    struct.pack_into("<I", header, 16, binascii.crc32(header[:92]) & 0xFFFFFFFF)
    return header


def directory_entry(name, attributes, cluster=0, size=0):
    if len(name) != 11:
        raise ValueError("short directory names must be exactly 11 bytes")
    entry = bytearray(32)
    entry[:11] = name
    entry[11] = attributes
    struct.pack_into("<H", entry, 16, FAT_DATE)  # Creation date.
    struct.pack_into("<H", entry, 18, FAT_DATE)  # Last access date.
    struct.pack_into("<H", entry, 20, cluster >> 16)
    struct.pack_into("<H", entry, 24, FAT_DATE)  # Last write date.
    struct.pack_into("<H", entry, 26, cluster & 0xFFFF)
    struct.pack_into("<I", entry, 28, size)
    return entry


def build_image(payload):
    """Return the complete 64 MiB raw image as a bytearray."""
    if not payload:
        raise ValueError("the UEFI application must not be empty")
    if len(payload) > MAX_PAYLOAD_SIZE:
        raise ValueError(f"application exceeds the ESP capacity ({MAX_PAYLOAD_SIZE} bytes)")
    digest = hashlib.sha256(payload).hexdigest()
    disk_guid = uuid.uuid5(uuid.NAMESPACE_OID, "bedrock-uefi-disk:" + digest)
    partition_guid = uuid.uuid5(uuid.NAMESPACE_OID, "bedrock-uefi-esp:" + digest)
    volume_id = int.from_bytes(hashlib.sha256(payload).digest()[:4], "little")
    image = bytearray(IMAGE_SIZE)

    def write_sector(lba, data):
        if lba < 0 or lba >= DISK_SECTORS or len(data) > SECTOR_SIZE:
            raise ValueError("internal sector bounds error")
        offset = lba * SECTOR_SIZE
        image[offset:offset + len(data)] = data

    # A protective MBR claims the disk after LBA 0; other records stay zero.
    mbr = bytearray(SECTOR_SIZE)
    mbr[446:450] = b"\x00\x00\x02\x00"
    mbr[450:454] = b"\xee\xff\xff\xff"
    struct.pack_into("<II", mbr, 454, 1, DISK_SECTORS - 1)
    mbr[510:512] = b"\x55\xaa"
    write_sector(0, mbr)

    entries = bytearray(ENTRY_COUNT * ENTRY_SIZE)
    entries[:16] = ESP_TYPE.bytes_le
    entries[16:32] = partition_guid.bytes_le
    struct.pack_into("<QQQ", entries, 32, ESP_FIRST, ESP_LAST, 0)
    name = "Bedrock ESP".encode("utf-16le")
    entries[56:56 + len(name)] = name
    entries_crc = binascii.crc32(entries) & 0xFFFFFFFF
    primary_entries = 2 * SECTOR_SIZE
    backup_entries_lba = DISK_SECTORS - 1 - ENTRY_SECTORS
    backup_entries = backup_entries_lba * SECTOR_SIZE
    image[primary_entries:primary_entries + len(entries)] = entries
    image[backup_entries:backup_entries + len(entries)] = entries
    write_sector(1, gpt_header(1, DISK_SECTORS - 1, 2, disk_guid, entries_crc))
    write_sector(DISK_SECTORS - 1, gpt_header(
        DISK_SECTORS - 1, 1, backup_entries_lba, disk_guid, entries_crc))

    boot = bytearray(SECTOR_SIZE)
    boot[:3] = b"\xeb\x58\x90"
    boot[3:11] = b"BEDROCK "
    struct.pack_into("<H", boot, 11, SECTOR_SIZE)
    boot[13] = 1
    struct.pack_into("<H", boot, 14, RESERVED_SECTORS)
    boot[16] = 2
    boot[21] = 0xF8
    struct.pack_into("<HHII", boot, 24, 63, 255, ESP_FIRST, ESP_SECTORS)
    struct.pack_into("<IHHIHH", boot, 36, FAT_SECTORS, 0, 0, ROOT_CLUSTER, 1, 6)
    boot[64] = 0x80
    boot[66] = 0x29
    struct.pack_into("<I", boot, 67, volume_id)
    boot[71:82] = b"BEDROCK ESP"
    boot[82:90] = b"FAT32   "
    boot[90:94] = b"\xfa\xf4\xeb\xfd"  # Legacy execution halts; UEFI reads the BPB.
    boot[510:512] = b"\x55\xaa"
    write_sector(ESP_FIRST, boot)
    write_sector(ESP_FIRST + 6, boot)

    file_clusters = (len(payload) + SECTOR_SIZE - 1) // SECTOR_SIZE
    used_clusters = 3 + file_clusters
    free_clusters = CLUSTER_COUNT - used_clusters
    fsinfo = bytearray(SECTOR_SIZE)
    struct.pack_into("<I", fsinfo, 0, 0x41615252)
    struct.pack_into("<IIII", fsinfo, 484,
                     0x61417272, free_clusters,
                     FILE_CLUSTER + file_clusters if free_clusters else 0xFFFFFFFF, 0)
    struct.pack_into("<I", fsinfo, 508, 0xAA550000)
    write_sector(ESP_FIRST + 1, fsinfo)
    write_sector(ESP_FIRST + 7, fsinfo)

    fat = bytearray(FAT_SECTORS * SECTOR_SIZE)
    struct.pack_into("<II", fat, 0, 0x0FFFFFF8, END_OF_CHAIN)
    for cluster in (ROOT_CLUSTER, EFI_CLUSTER, BOOT_CLUSTER):
        struct.pack_into("<I", fat, cluster * 4, END_OF_CHAIN)
    for index in range(file_clusters):
        cluster = FILE_CLUSTER + index
        following = cluster + 1 if index + 1 < file_clusters else END_OF_CHAIN
        struct.pack_into("<I", fat, cluster * 4, following)
    fat_offset = (ESP_FIRST + RESERVED_SECTORS) * SECTOR_SIZE
    image[fat_offset:fat_offset + len(fat)] = fat
    image[fat_offset + len(fat):fat_offset + 2 * len(fat)] = fat

    data_lba = ESP_FIRST + RESERVED_SECTORS + 2 * FAT_SECTORS

    def directory(cluster, records):
        data = bytearray(SECTOR_SIZE)
        for index, record in enumerate(records):
            data[index * 32:(index + 1) * 32] = record
        write_sector(data_lba + cluster - 2, data)

    directory(ROOT_CLUSTER, [directory_entry(b"BEDROCK ESP", 0x08),
                             directory_entry(b"EFI        ", 0x10, EFI_CLUSTER)])
    directory(EFI_CLUSTER, [directory_entry(b".          ", 0x10, EFI_CLUSTER),
                            directory_entry(b"..         ", 0x10, 0),
                            directory_entry(b"BOOT       ", 0x10, BOOT_CLUSTER)])
    directory(BOOT_CLUSTER, [directory_entry(b".          ", 0x10, BOOT_CLUSTER),
                             directory_entry(b"..         ", 0x10, EFI_CLUSTER),
                             directory_entry(b"BOOTX64 EFI", 0x20, FILE_CLUSTER, len(payload))])
    file_offset = (data_lba + FILE_CLUSTER - 2) * SECTOR_SIZE
    image[file_offset:file_offset + len(payload)] = payload
    return image


def validate_path_syntax(text, windows=None):
    """Reject Windows device aliases before even querying the filesystem.

    Device aliases apply to every directory and remain aliases with extensions.
    An explicit platform flag permits tests to check this policy without probing
    devices, while ordinary POSIX filenames retain POSIX semantics.
    """
    if windows is None:
        windows = os.name == "nt"
    if not windows:
        return
    normalized = text.replace("/", "\\")
    if normalized.startswith(("\\\\.\\", "\\\\?\\", "\\??\\")):
        raise ValueError("Windows device/namespace paths are not supported")
    parsed = PureWindowsPath(normalized)
    reserved = {"CON", "PRN", "AUX", "NUL", "CONIN$", "CONOUT$"}
    reserved.update(prefix + digit for prefix in ("COM", "LPT") for digit in "123456789\u00b9\u00b2\u00b3")
    for component in parsed.parts:
        if component == parsed.anchor or component in (".", ".."):
            continue
        # Win32 trims trailing spaces/dots. Reject them rather than allowing a
        # path to silently identify a different destination or device alias.
        base = component.rstrip(" .").partition(".")[0].rstrip(" ").upper()
        if base in reserved:
            raise ValueError("Windows DOS device aliases are not ordinary files")
        if component.endswith((" ", ".")) or any(
            character in '<>:"|?*' or ord(character) < 32 for character in component
        ):
            raise ValueError("Windows path components contain unsupported characters or trailing spaces/dots")


def ordinary_path(path, output=False):
    """Reject devices and special files before any read/write is attempted."""
    validate_path_syntax(str(path))
    if path.is_symlink() and output:
        raise ValueError("the output must not be a symbolic link")
    if path.exists():
        if not stat.S_ISREG(path.stat().st_mode):
            raise ValueError("input and output must be ordinary files")
    elif not output:
        raise ValueError("the input application does not exist")
    if output and not path.parent.is_dir():
        raise ValueError("the output directory must already exist")


def write_image(input_path, output_path):
    ordinary_path(input_path)
    ordinary_path(output_path, output=True)
    if input_path.resolve() == output_path.resolve() or (
        output_path.exists() and os.path.samefile(input_path, output_path)
    ):
        raise ValueError("input and output must be different files")
    with input_path.open("rb") as source:
        payload = source.read(MAX_PAYLOAD_SIZE + 1)
    image = build_image(payload)
    temporary = None
    try:
        # A sibling temporary file makes replacement atomic, even on Windows.
        with tempfile.NamedTemporaryFile(
            dir=output_path.parent, prefix=output_path.name + ".", suffix=".tmp", delete=False
        ) as destination:
            temporary = Path(destination.name)
            destination.write(image)
            destination.flush()
            os.fsync(destination.fileno())
        os.replace(temporary, output_path)
        temporary = None
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)
    return len(payload)


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("application", type=Path, help="input x86-64 UEFI .EFI application")
    parser.add_argument("image", type=Path, help="output ordinary raw image file (64 MiB)")
    args = parser.parse_args()
    try:
        payload_size = write_image(args.application, args.image)
    except (OSError, ValueError) as error:
        print(f"UEFI image creation failed: {error}", file=sys.stderr)
        return 1
    print(f"Created {args.image}: {IMAGE_SIZE} bytes, BOOTX64.EFI {payload_size} bytes")
    return 0


if __name__ == "__main__":
    sys.exit(main())
