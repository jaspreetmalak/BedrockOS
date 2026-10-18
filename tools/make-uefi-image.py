#!/usr/bin/env python3
"""Package a UEFI loader, installed applications and optional drivers in GPT/FAT32.

Python standard library only. Creates an ordinary image file; never formats,
mounts, or opens a host block device. See docs/uefi-image.md for the disk layout.
"""

import argparse
import binascii
import hashlib
import importlib.util
import json
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
BOOT_NAMES = {"x86_64": "BOOTX64.EFI", "arm64": "BOOTAA64.EFI", "riscv64": "BOOTRISCV64.EFI"}
FIRMWARE_FILES = {
    "WIFI_MT7922_patch_mcu_1_1_hdr.bin": (137632, "7fc9075d6d54b31e0539734614ca971fa52caf41b642a3000c8a4501591a4d98"),
    "WIFI_RAM_CODE_MT7922_1.bin": (1231252, "d100e5e04c324fc8da6302112d1e0b4fac952286447d2419eabcd8fb0a1f5b93"),
    "LICENCE.mediatek": (561, "a90d3f66704d85889945fec5525ea77622549da83aced1aac99828383f8f1805"),
}
PROFILE_NAME = "MT7922.board"
PROFILE_MAX = 12416
DRIVER_ARCHITECTURES = {"x86_64": "x86_64", "arm64": "aarch64", "riscv64": "riscv64"}


def driver_packager():
    spec = importlib.util.spec_from_file_location("bedrock_image_driver_packages", Path(__file__).with_name("package-drivers.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def app_packager():
    spec = importlib.util.spec_from_file_location("bedrock_image_app_packages", Path(__file__).with_name("package-apps.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def validate_driver_assets(assets, arch):
    """Recheck the catalogue, target, file hashes and normal driver ELF notes."""
    package = driver_packager()
    if type(assets) is not dict or "manifest.json" not in assets or not 1 <= len(assets) <= package.MAX_PACKAGES + 1:
        raise ValueError("drivers require a bounded manifest and its exact declared modules")
    if any(type(data) not in (bytes, bytearray) for data in assets.values()):
        raise ValueError("driver assets must be byte buffers")
    if len(assets["manifest.json"]) > package.MAX_JSON_BYTES:
        raise ValueError("driver manifest exceeds its bounded size")
    try:
        manifest = json.loads(bytes(assets["manifest.json"]).decode("utf-8"), object_pairs_hook=package.unique_object)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ValueError("invalid driver manifest UTF-8 JSON") from error
    catalogue = package.validate_catalogue(package.read_json(package.DEFAULT_CATALOGUE))
    architecture = DRIVER_ARCHITECTURES[arch]
    package.validate_driver_manifest(manifest, architecture, catalogue)
    expected = {"manifest.json"} | {item["module"]["file"] for item in manifest["packages"]}
    if set(assets) != expected:
        raise ValueError("driver assets differ from the manifest's exact file set")
    known = {item["id"]: item for item in catalogue["packages"]}
    for metadata in manifest["packages"]:
        package.validate_package_metadata(metadata, architecture, known[metadata["id"]], assets[metadata["module"]["file"]])
    return manifest


def load_driver_directory(directory, arch="x86_64", output_path=None):
    """Read a previously selected flat EFI/Bedrock/Drivers directory."""
    package = driver_packager()
    if output_path is not None and same_path(package.DEFAULT_CATALOGUE, output_path):
        raise ValueError("driver catalogue input and output must be different files")
    directory = package.check_directory(directory)
    entries = list(directory.iterdir())
    if not 1 <= len(entries) <= package.MAX_PACKAGES + 1 or "manifest.json" not in {path.name for path in entries}:
        raise ValueError("driver directory requires its bounded manifest and exact modules")
    manifest_bytes = package.read_file(directory / "manifest.json", package.MAX_JSON_BYTES)
    # Validate metadata first; no manifest path can request arbitrary files.
    manifest_only = json.loads(manifest_bytes.decode("utf-8"), object_pairs_hook=package.unique_object)
    catalogue = package.validate_catalogue(package.read_json(package.DEFAULT_CATALOGUE))
    package.validate_driver_manifest(manifest_only, DRIVER_ARCHITECTURES[arch], catalogue)
    expected = {"manifest.json"} | {item["module"]["file"] for item in manifest_only["packages"]}
    if {path.name for path in entries} != expected:
        raise ValueError("driver directory contains undeclared files or case collisions")
    assets = {"manifest.json": manifest_bytes}
    for path in entries:
        if output_path is not None and same_path(path, output_path):
            raise ValueError("driver input and output must be different files")
        if path.name != "manifest.json":
            assets[path.name] = package.read_file(path, package.MAX_MODULE_BYTES, 64)
    validate_driver_assets(assets, arch)
    return assets


def select_driver_assets(module_root, arch="x86_64", inventory_path=None, all_compatible=False, output_path=None):
    """Select explicitly local packages without executing or publishing them."""
    package = driver_packager()
    if inventory_path is None and not all_compatible:
        raise ValueError("driver packages require --inventory or explicit --all-compatible")
    if output_path is not None and (same_path(package.DEFAULT_CATALOGUE, output_path) or
                                   inventory_path is not None and same_path(inventory_path, output_path)):
        raise ValueError("driver catalogue/inventory input and output must be different files")
    inventory = package.read_json(inventory_path) if inventory_path is not None else {"schema_version": 1, "devices": []}
    catalogue = package.read_json(package.DEFAULT_CATALOGUE)
    manifest, receipt, loaded = package.select_packages(catalogue, inventory, DRIVER_ARCHITECTURES[arch], module_root, all_compatible)
    if output_path is not None:
        for known in catalogue["packages"]:
            source_directory = Path(module_root) / DRIVER_ARCHITECTURES[arch] / known["directory"]
            if any(same_path(source_directory / name, output_path) for name in ("package.json", known["module"])):
                raise ValueError("driver package input and output must be different files")
    assets = {"manifest.json": package.json_bytes(manifest)}
    for item in loaded.values():
        assets[item["metadata"]["module"]["file"]] = item["bytes"]
    validate_driver_assets(assets, arch)
    return assets


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


def short_name_checksum(name):
    checksum = 0
    for byte in name:
        checksum = (((checksum & 1) << 7) + (checksum >> 1) + byte) & 0xFF
    return checksum


def name_records(name, short_name, attributes, cluster=0, size=0):
    """Encode standard FAT long-name entries followed by their short entry."""
    if not name or len(name) > 255 or any(character in '\\/:*?"<>|' or ord(character) < 32 for character in name):
        raise ValueError("invalid FAT long filename")
    if len(short_name) != 11:
        raise ValueError("invalid FAT short alias")
    encoded = name.encode("utf-16le")
    words = list(struct.unpack("<" + "H" * (len(encoded) // 2), encoded))
    if len(words) > 255:
        raise ValueError("FAT long filename exceeds 255 UTF-16 units")
    # Full 13-unit chunks have no terminator. A partial final chunk has one
    # NUL terminator and 0xffff padding, per the FAT long-name format.
    if len(words) % 13:
        words.append(0)
        words.extend([0xFFFF] * ((-len(words)) % 13))
    count = len(words) // 13
    records = []
    checksum = short_name_checksum(short_name)
    for number in range(count, 0, -1):
        entry = bytearray(32)
        entry[0] = number | (0x40 if number == count else 0)
        entry[11] = 0x0F
        entry[13] = checksum
        chunk = words[(number - 1) * 13:number * 13]
        struct.pack_into("<5H", entry, 1, *chunk[:5])
        struct.pack_into("<6H", entry, 14, *chunk[5:11])
        struct.pack_into("<2H", entry, 28, *chunk[11:])
        records.append(entry)
    records.append(directory_entry(short_name, attributes, cluster, size))
    return records


def validate_profile(data):
    """Packaging preflight only; the loader validates every board-record field."""
    if len(data) < 128 or len(data) > PROFILE_MAX or data[:8] != b"BRDBRD01":
        raise ValueError("invalid MT7922.board size or magic")
    if (len(data) - 128) % 192:
        raise ValueError("invalid MT7922.board record extent")
    checked = bytearray(data)
    digest = bytes(checked[40:72])
    checked[40:72] = bytes(32)
    if hashlib.sha256(checked).digest() != digest:
        raise ValueError("invalid MT7922.board hash")


def validate_firmware(assets):
    if not isinstance(assets, dict) or not set(FIRMWARE_FILES).issubset(assets) or set(assets) - set(FIRMWARE_FILES) - {PROFILE_NAME}:
        raise ValueError("firmware requires the exact pinned pair and MediaTek licence")
    for name, (size, digest) in FIRMWARE_FILES.items():
        if len(assets[name]) != size or hashlib.sha256(assets[name]).hexdigest() != digest:
            raise ValueError(f"pinned firmware size/hash mismatch: {name}")
    if PROFILE_NAME in assets:
        validate_profile(assets[PROFILE_NAME])


def build_image(payload, *, arch="x86_64", firmware=None, drivers=None, apps=None, installer=None):
    """Return the complete 64 MiB raw image as a bytearray."""
    if not payload:
        raise ValueError("the UEFI application must not be empty")
    if len(payload) > MAX_PAYLOAD_SIZE:
        raise ValueError(f"application exceeds the ESP capacity ({MAX_PAYLOAD_SIZE} bytes)")
    if arch not in BOOT_NAMES:
        raise ValueError("unsupported UEFI architecture")
    if firmware is not None:
        validate_firmware(firmware)
    if drivers is not None:
        validate_driver_assets(drivers, arch)
    if apps is not None:
        app_packager().validate_archive(apps, DRIVER_ARCHITECTURES[arch])
    boot_name = BOOT_NAMES[arch]
    # Preserve the original default image byte-for-byte. Other profiles bind
    # their deterministic IDs to all packaged names and byte contents.
    identity = hashlib.sha256(payload)
    if arch != "x86_64" or firmware is not None or drivers is not None or apps is not None or installer is not None:
        identity.update(arch.encode("ascii") + b"\0")
        for name, data in sorted((firmware or {}).items()):
            identity.update(name.encode("utf-8") + b"\0" + struct.pack("<Q", len(data)) + data)
        if drivers is not None:
            identity.update(b"BedrockDrivers\0")
            for name, data in sorted(drivers.items()):
                identity.update(name.encode("utf-8") + b"\0" + struct.pack("<Q", len(data)) + data)
        if apps is not None:
            identity.update(b"BedrockApps\0" + struct.pack("<Q", len(apps)) + apps)
        if installer is not None:
            if len(installer) < 512 or len(installer) > 32 * 1024 * 1024 or installer[:8] != b"BEDIP001" or struct.unpack_from("<H", installer, 12)[0] != {"x86_64": 62, "arm64": 183, "riscv64": 243}[arch]:
                raise ValueError("invalid bounded installer payload architecture")
            identity.update(b"BedrockInstaller\0" + struct.pack("<Q", len(installer)) + installer)
    digest = identity.hexdigest()
    disk_guid = uuid.uuid5(uuid.NAMESPACE_OID, "bedrock-uefi-disk:" + digest)
    partition_guid = uuid.uuid5(uuid.NAMESPACE_OID, "bedrock-uefi-esp:" + digest)
    volume_id = int.from_bytes(identity.digest()[:4], "little")

    allocations = []
    next_cluster = FILE_CLUSTER

    def allocate(data):
        nonlocal next_cluster
        count = (len(data) + SECTOR_SIZE - 1) // SECTOR_SIZE
        if count < 1 or next_cluster + count > CLUSTER_COUNT + 2:
            raise ValueError("application and optional assets exceed the ESP capacity")
        start = next_cluster
        allocations.append((start, count, data))
        next_cluster += count
        return start

    def directory_data(records):
        data = b"".join(records) + bytes(32)  # mandatory end marker
        return data + bytes((-len(data)) % SECTOR_SIZE)

    app_cluster = allocate(payload)
    directories = {
        ROOT_CLUSTER: directory_data([directory_entry(b"BEDROCK ESP", 0x08), directory_entry(b"EFI        ", 0x10, EFI_CLUSTER)]),
    }
    boot_short = {"x86_64": b"BOOTX64 EFI", "arm64": b"BOOTAA64EFI", "riscv64": b"BOOTRI~1EFI"}[arch]
    app_records = [directory_entry(boot_short, 0x20, app_cluster, len(payload))] if arch != "riscv64" else name_records(boot_name, boot_short, 0x20, app_cluster, len(payload))
    directories[BOOT_CLUSTER] = directory_data([directory_entry(b".          ", 0x10, BOOT_CLUSTER), directory_entry(b"..         ", 0x10, EFI_CLUSTER)] + app_records)
    efi_records = [directory_entry(b".          ", 0x10, EFI_CLUSTER), directory_entry(b"..         ", 0x10, 0), directory_entry(b"BOOT       ", 0x10, BOOT_CLUSTER)]
    if firmware is not None or drivers is not None or apps is not None or installer is not None:
        # Allocate directory extents before their contents, retaining their
        # actual linked chains when LFN records occupy multiple clusters.
        bedrock_cluster = next_cluster
        allocate(bytes(SECTOR_SIZE))
        bedrock_records = [directory_entry(b".          ", 0x10, bedrock_cluster), directory_entry(b"..         ", 0x10, EFI_CLUSTER)]
        for folder, assets in ((b"FIRMWARE   ", firmware), (b"DRIVERS    ", drivers),
                               (b"APPS       ", {"apps.bap": apps} if apps is not None else None)):
            if assets is None:
                continue
            aliases = ({
                "WIFI_MT7922_patch_mcu_1_1_hdr.bin": b"PATCH~1 BIN",
                "WIFI_RAM_CODE_MT7922_1.bin": b"RAM~1   BIN",
                "LICENCE.mediatek": b"LICENC~1MED",
                PROFILE_NAME: b"MT7922~1BOA",
            } if folder == b"FIRMWARE   " else {"apps.bap": b"APPS    BAP"} if folder == b"APPS       " else
                {name: b"MANIFE~1JSN" if name == "manifest.json" else f"DRV{index:05d}BDM".encode("ascii")
                 for index, name in enumerate(sorted(assets))})
            names = sorted(assets)
            record_count = 2 + sum((len(name) + 12) // 13 + 1 for name in names)
            asset_cluster = allocate(bytes(((record_count + 1) * 32 + SECTOR_SIZE - 1) // SECTOR_SIZE * SECTOR_SIZE))
            records = [directory_entry(b".          ", 0x10, asset_cluster), directory_entry(b"..         ", 0x10, bedrock_cluster)]
            for name in names:
                data = assets[name]
                cluster = allocate(data)
                records.extend(name_records(name, aliases[name], 0x20, cluster, len(data)))
            bedrock_records.append(directory_entry(folder, 0x10, asset_cluster))
            directories[asset_cluster] = directory_data(records)
        if installer is not None:
            install_cluster = allocate(bytes(SECTOR_SIZE))
            file_cluster = allocate(installer)
            records = [directory_entry(b".          ", 0x10, install_cluster), directory_entry(b"..         ", 0x10, bedrock_cluster), directory_entry(b"OS      BIP", 0x20, file_cluster, len(installer))]
            directories[install_cluster] = directory_data(records)
            bedrock_records.append(directory_entry(b"INSTALL    ", 0x10, install_cluster))
        directories[bedrock_cluster] = directory_data(bedrock_records)
        efi_records.append(directory_entry(b"BEDROCK    ", 0x10, bedrock_cluster))
    directories[EFI_CLUSTER] = directory_data(efi_records)
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

    used_clusters = next_cluster - 2
    free_clusters = CLUSTER_COUNT - used_clusters
    fsinfo = bytearray(SECTOR_SIZE)
    struct.pack_into("<I", fsinfo, 0, 0x41615252)
    struct.pack_into("<IIII", fsinfo, 484,
                     0x61417272, free_clusters,
                     next_cluster if free_clusters else 0xFFFFFFFF, 0)
    struct.pack_into("<I", fsinfo, 508, 0xAA550000)
    write_sector(ESP_FIRST + 1, fsinfo)
    write_sector(ESP_FIRST + 7, fsinfo)

    fat = bytearray(FAT_SECTORS * SECTOR_SIZE)
    struct.pack_into("<II", fat, 0, 0x0FFFFFF8, END_OF_CHAIN)
    for cluster in (ROOT_CLUSTER, EFI_CLUSTER, BOOT_CLUSTER):
        struct.pack_into("<I", fat, cluster * 4, END_OF_CHAIN)
    for start, count, _ in allocations:
        for index in range(count):
            cluster = start + index
            following = cluster + 1 if index + 1 < count else END_OF_CHAIN
            struct.pack_into("<I", fat, cluster * 4, following)
    fat_offset = (ESP_FIRST + RESERVED_SECTORS) * SECTOR_SIZE
    image[fat_offset:fat_offset + len(fat)] = fat
    image[fat_offset + len(fat):fat_offset + 2 * len(fat)] = fat

    data_lba = ESP_FIRST + RESERVED_SECTORS + 2 * FAT_SECTORS

    for start, count, data in allocations:
        data = directories.get(start, data)
        if len(data) > count * SECTOR_SIZE:
            raise ValueError("internal directory extent mismatch")
        offset = (data_lba + start - 2) * SECTOR_SIZE
        image[offset:offset + len(data)] = data
    for cluster in (ROOT_CLUSTER, EFI_CLUSTER, BOOT_CLUSTER):
        offset = (data_lba + cluster - 2) * SECTOR_SIZE
        image[offset:offset + len(directories[cluster])] = directories[cluster]
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


def same_path(first, second):
    return first.resolve() == second.resolve() or (first.exists() and second.exists() and os.path.samefile(first, second))


def load_firmware(directory, output_path=None):
    """Read only the explicit flat directory's pinned ordinary asset files."""
    validate_path_syntax(str(directory))
    if directory.is_symlink() or not directory.is_dir():
        raise ValueError("firmware directory must be an ordinary directory, not a symbolic link")
    assets = {}
    for name in list(FIRMWARE_FILES) + [PROFILE_NAME]:
        path = directory / name
        validate_path_syntax(str(path))
        if name == PROFILE_NAME and not path.exists() and not path.is_symlink():
            continue
        if path.is_symlink():
            raise ValueError("firmware assets must not be symbolic links")
        ordinary_path(path)
        if output_path is not None and same_path(path, output_path):
            raise ValueError("firmware input and output must be different files")
        maximum = PROFILE_MAX if name == PROFILE_NAME else FIRMWARE_FILES[name][0]
        if path.stat().st_size > maximum:
            raise ValueError(f"firmware asset exceeds its bounded size: {name}")
        with path.open("rb") as source:
            assets[name] = source.read(maximum + 1)
    validate_firmware(assets)
    return assets


def load_apps(path, arch="x86_64", output_path=None):
    """Read one explicit bounded ordinary archive; reject output aliases."""
    validate_path_syntax(str(path))
    if path.is_symlink():
        raise ValueError("application archive must not be a symbolic link")
    ordinary_path(path)
    if output_path is not None and same_path(path, output_path):
        raise ValueError("application archive input and output must be different files")
    if arch not in DRIVER_ARCHITECTURES:
        raise ValueError("unsupported UEFI architecture")
    packages = app_packager()
    with path.open("rb") as source:
        data = source.read(packages.MAX_ARCHIVE_BYTES + 1)
    packages.validate_archive(data, DRIVER_ARCHITECTURES[arch])
    return data


def write_image(input_path, output_path, *, arch="x86_64", firmware_dir=None,
                driver_dir=None, driver_packages=None, inventory_path=None, all_compatible=False, apps_path=None, installer_path=None):
    ordinary_path(input_path)
    ordinary_path(output_path, output=True)
    if same_path(input_path, output_path):
        raise ValueError("input and output must be different files")
    if arch not in BOOT_NAMES:
        raise ValueError("unsupported UEFI architecture")
    if driver_dir is not None and (driver_packages is not None or inventory_path is not None or all_compatible):
        raise ValueError("selected driver directory cannot be combined with package selection options")
    if driver_packages is None and (inventory_path is not None or all_compatible):
        raise ValueError("inventory/offline selection requires --driver-packages")
    firmware = load_firmware(firmware_dir, output_path) if firmware_dir is not None else None
    drivers = (load_driver_directory(driver_dir, arch, output_path) if driver_dir is not None else
               select_driver_assets(driver_packages, arch, inventory_path, all_compatible, output_path) if driver_packages is not None else None)
    apps = load_apps(apps_path, arch, output_path) if apps_path is not None else None
    installer = None
    if installer_path is not None:
        ordinary_path(installer_path)
        if same_path(installer_path, output_path) or installer_path.is_symlink() or installer_path.stat().st_size > 32 * 1024 * 1024:
            raise ValueError("installer payload must be a bounded distinct ordinary file")
        installer = installer_path.read_bytes()
    with input_path.open("rb") as source:
        payload = source.read(MAX_PAYLOAD_SIZE + 1)
    image = build_image(payload, arch=arch, firmware=firmware, drivers=drivers, apps=apps, installer=installer)
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
    parser.add_argument("application", type=Path, help="input UEFI .EFI application")
    parser.add_argument("image", type=Path, help="output ordinary raw image file (64 MiB)")
    parser.add_argument("--arch", choices=BOOT_NAMES, default="x86_64", help="removable-media UEFI name (default: x86_64)")
    parser.add_argument("--firmware-dir", type=Path, help="explicit pinned MT7922 pair, LICENCE.mediatek and optional MT7922.board")
    parser.add_argument("--apps", type=Path, help="explicit validated installed apps.bap archive for this architecture")
    parser.add_argument("--installer-payload", type=Path, help="bounded sparse installation payload for native installer media")
    drivers = parser.add_mutually_exclusive_group()
    drivers.add_argument("--driver-dir", type=Path, help="selected flat EFI/Bedrock/Drivers directory with validated manifest/modules")
    drivers.add_argument("--driver-packages", type=Path, help="explicit local <arch>/<driver>/package.json root; requires inventory or --all-compatible")
    parser.add_argument("--inventory", type=Path, help="target PCI inventory for --driver-packages")
    parser.add_argument("--all-compatible", action="store_true", help="include available compatible local packages for offline media")
    args = parser.parse_args()
    try:
        payload_size = write_image(args.application, args.image, arch=args.arch, firmware_dir=args.firmware_dir,
                                   driver_dir=args.driver_dir, driver_packages=args.driver_packages,
                                   inventory_path=args.inventory, all_compatible=args.all_compatible, apps_path=args.apps, installer_path=args.installer_payload)
    except (OSError, ValueError) as error:
        print(f"UEFI image creation failed: {error}", file=sys.stderr)
        return 1
    print(f"Created {args.image}: {IMAGE_SIZE} bytes, {BOOT_NAMES[args.arch]} {payload_size} bytes" + (", pinned MT7922 firmware assets" if args.firmware_dir is not None else "") + (", installed application archive" if args.apps is not None else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
