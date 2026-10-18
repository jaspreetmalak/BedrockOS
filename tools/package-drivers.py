#!/usr/bin/env python3
# SPDX-License-Identifier: ISC
# Copyright (C) 2026 Bedrock contributors
"""Select local driver packages for an explicit target inventory and stage an ESP tree.

This prepares ordinary files only. It neither writes a disk nor executes modules,
downloads drivers, configures radios, or guesses support from a vendor name.
"""

import argparse
import ctypes
import errno
import hashlib
import json
import os
from pathlib import Path, PureWindowsPath
import re
import shutil
import stat
import struct
import subprocess
import sys
import tempfile
import time


ARCHITECTURES = {"x86_64": 62, "aarch64": 183, "riscv64": 243}
MAX_JSON_BYTES = 512 * 1024
MAX_MODULE_BYTES = 8 * 1024 * 1024
MAX_IMAGE_BYTES = 4 * 1024 * 1024
MAX_DEVICES = 1024
MAX_PACKAGES = 64
MAX_LOAD_SEGMENTS = 8
MAX_MATCH_NOTES = 8
DRIVER_ABI = {"major": 1, "minor": 0}
NOTE_NAME = b"BEDROCK\x00"
NOTE_TYPE = 0x42524456
NOTE_MAGIC = b"BDRVABI1"
SAFE_ID = re.compile(r"[a-z][a-z0-9]*(?:[.-][a-z0-9]+)*\Z")
SAFE_FILE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}\Z")
SEMVER = re.compile(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\Z")
SHA256 = re.compile(r"[0-9a-f]{64}\Z")
RESERVED_NAMES = {"CON", "PRN", "AUX", "NUL", "CLOCK$", "CONIN$", "CONOUT$"}
RESERVED_NAMES.update(f"{prefix}{digit}" for prefix in ("COM", "LPT") for digit in range(1, 10))
DEFAULT_CATALOGUE = Path(__file__).resolve().parents[1] / "drivers" / "catalogue.json"


def fields(value, required, label, optional=()):
    if type(value) is not dict or not set(required).issubset(value) or set(value) - set(required) - set(optional):
        raise ValueError(f"{label} requires {', '.join(required)}; optional: {', '.join(optional) or 'none'}")
    return value


def integer(value, low, high, label):
    if type(value) is not int or not low <= value <= high:
        raise ValueError(f"{label} must be an integer in {low}..{high}")
    return value


def text(value, low, high, label):
    if type(value) is not str or not low <= len(value) <= high or any(ord(c) < 32 for c in value):
        raise ValueError(f"{label} must be {low}..{high} printable characters")
    return value


def safe_name(value, label, identifier=False):
    expression = SAFE_ID if identifier else SAFE_FILE
    if type(value) is not str or len(value) > 128 or expression.fullmatch(value) is None:
        raise ValueError(f"{label} must be a simple {'identifier' if identifier else 'filename'}")
    if value.split('.')[0].upper() in RESERVED_NAMES or value.endswith(('.', ' ')):
        raise ValueError(f"{label} is a reserved Windows device name")
    return value


def check_ordinary_path(path):
    """Reject raw devices and Windows aliases even when invoked on another OS."""
    path = Path(path)
    source = str(path)
    windows = PureWindowsPath(source)
    if source.startswith(('\\\\', '//')) or windows.drive.startswith('\\\\'):
        raise ValueError("network/device paths are not permitted")
    for component in windows.parts:
        if component in (windows.anchor, '/', '\\', '.', '..'):
            continue
        if ':' in component or component.rstrip(' .') != component or component.split('.')[0].upper() in RESERVED_NAMES:
            raise ValueError("path contains a device alias, stream, or ambiguous component")
    return path


def is_reparse(info):
    return bool(getattr(info, 'st_file_attributes', 0) & getattr(stat, 'FILE_ATTRIBUTE_REPARSE_POINT', 0x400))


def check_directory(path):
    path = check_ordinary_path(path)
    info = path.lstat()
    if not stat.S_ISDIR(info.st_mode) or is_reparse(info):
        raise ValueError(f"expected an ordinary directory: {path}")
    return path


def read_file(path, maximum, minimum=1):
    path = check_ordinary_path(path)
    before = path.lstat()
    if not stat.S_ISREG(before.st_mode) or is_reparse(before):
        raise ValueError(f"expected an ordinary file: {path}")
    if not minimum <= before.st_size <= maximum:
        raise ValueError(f"file size outside {minimum}..{maximum}: {path}")
    with path.open('rb') as stream:
        opened = os.fstat(stream.fileno())
        if not stat.S_ISREG(opened.st_mode) or (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino):
            raise ValueError(f"input changed while opening: {path}")
        data = stream.read(maximum + 1)
    if len(data) != opened.st_size or not minimum <= len(data) <= maximum:
        raise ValueError(f"input changed size or exceeded bounds: {path}")
    return data


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def read_json(path):
    try:
        return json.loads(read_file(path, MAX_JSON_BYTES).decode('utf-8'), object_pairs_hook=unique_object)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ValueError(f"invalid UTF-8 JSON: {path}") from error


def pci_id(value, label):
    if type(value) is str and re.fullmatch(r"[0-9a-fA-F]{4}", value):
        return int(value, 16)
    return integer(value, 0, 65535, label)


def pci_match(source, label):
    fields(source, ('vendor', 'device'), label)
    vendor, device = pci_id(source['vendor'], label + '.vendor'), pci_id(source['device'], label + '.device')
    if vendor in (0, 65535) or device == 65535:
        raise ValueError(f"{label} requires an actual PCI identity")
    return vendor, device


def validate_abi(source, label):
    fields(source, ('major', 'minor'), label)
    for name in ('major', 'minor'):
        integer(source[name], 0, 65535, label + '.' + name)
    if source != DRIVER_ABI:
        raise ValueError(f"{label} must match supported driver ABI 1.0")


def validate_catalogue(document):
    fields(document, ('schema_version', 'driver_abi', 'boot_essentials', 'packages', 'known_unsupported'), 'catalogue')
    integer(document['schema_version'], 1, 1, 'catalogue.schema_version')
    validate_abi(document['driver_abi'], 'catalogue.driver_abi')
    essentials = document['boot_essentials']
    if type(essentials) is not list or not 1 <= len(essentials) <= 32:
        raise ValueError('catalogue.boot_essentials must be a bounded nonempty list')
    for item in essentials:
        safe_name(item, 'boot essential', identifier=True)
    if len(set(essentials)) != len(essentials):
        raise ValueError('duplicate boot essential')
    packages = document['packages']
    if type(packages) is not list or len(packages) > MAX_PACKAGES:
        raise ValueError('catalogue.packages must be a bounded list')
    identifiers, paths, matched_ids = set(), set(), set()
    for package in packages:
        fields(package, ('id', 'directory', 'package_version', 'class', 'module', 'architectures', 'pci_matches'), 'package')
        safe_name(package['id'], 'package.id', identifier=True)
        if len(package['id']) >= 24:
            raise ValueError('package.id must fit the 24-byte NUL-padded ABI declaration')
        safe_name(package['directory'], 'package.directory')
        safe_name(package['module'], 'package.module')
        if not package['module'].endswith('.bdm') or package['module'].casefold() in ('manifest.json', 'package.json'):
            raise ValueError('module filename requires .bdm extension')
        if type(package['package_version']) is not str or not SEMVER.fullmatch(package['package_version']):
            raise ValueError('package_version requires numeric major.minor.patch')
        if package['class'] != 'wifi':
            raise ValueError('only the Wi-Fi module class is currently supported')
        fields(package['architectures'], ARCHITECTURES, 'package.architectures')
        if any(state not in ('experimental', 'platform-unsupported') for state in package['architectures'].values()):
            raise ValueError('unknown architecture support state')
        if type(package['pci_matches']) is not list or not 1 <= len(package['pci_matches']) <= 16:
            raise ValueError('package requires 1..16 exact PCI matches')
        matches = [pci_match(item, 'package.pci_match') for item in package['pci_matches']]
        if len(set(matches)) != len(matches) or matched_ids.intersection(matches):
            raise ValueError('ambiguous or duplicate PCI match')
        if package['id'] in identifiers or package['directory'].casefold() in paths or package['module'].casefold() in paths:
            raise ValueError('duplicate package identifier or case-insensitive path collision')
        identifiers.add(package['id'])
        paths.update((package['directory'].casefold(), package['module'].casefold()))
        matched_ids.update(matches)
    unsupported = document['known_unsupported']
    if type(unsupported) is not list or len(unsupported) > 256:
        raise ValueError('known_unsupported must be a bounded list')
    for item in unsupported:
        fields(item, ('vendor', 'device', 'name'), 'unsupported device')
        identity = pci_match({'vendor': item['vendor'], 'device': item['device']}, 'unsupported device')
        text(item['name'], 1, 128, 'unsupported device.name')
        if identity in matched_ids:
            raise ValueError('duplicate supported/unsupported PCI match')
        matched_ids.add(identity)
    return document


def validate_inventory(document):
    fields(document, ('schema_version', 'devices'), 'inventory')
    integer(document['schema_version'], 1, 1, 'inventory.schema_version')
    if type(document['devices']) is not list or len(document['devices']) > MAX_DEVICES:
        raise ValueError('inventory.devices must contain at most 1024 PCI devices')
    normalized, locations = [], set()
    for index, device in enumerate(document['devices']):
        fields(device, ('vendor', 'device'), 'inventory device', ('subsystem_vendor', 'subsystem_device', 'revision', 'location'))
        vendor, product = pci_match({'vendor': device['vendor'], 'device': device['device']}, 'inventory device')
        result = {'vendor': f'{vendor:04x}', 'device': f'{product:04x}'}
        subsystem_fields = ('subsystem_vendor', 'subsystem_device')
        if any(key in device for key in subsystem_fields):
            if not all(key in device for key in subsystem_fields):
                raise ValueError('subsystem vendor/device must be supplied together')
            result.update({key: f'{pci_id(device[key], key):04x}' for key in subsystem_fields})
        if 'revision' in device:
            result['revision'] = integer(device['revision'], 0, 255, 'revision')
        if 'location' in device:
            location = text(device['location'], 1, 512, 'location')
            if location in locations:
                raise ValueError('duplicate inventory device location')
            locations.add(location)
            result['location'] = location
        normalized.append(result)
    return {'schema_version': 1, 'devices': normalized}


def windows_inventory():
    """Read PnP identity only; no device state or configuration is modified."""
    if os.name != 'nt':
        raise ValueError('--inventory-windows requires Windows')
    script = r"""$ErrorActionPreference = 'Stop'; @(
Get-CimInstance -ClassName Win32_PnPEntity | Where-Object { $_.PNPDeviceID -like 'PCI\*' } |
ForEach-Object { [pscustomobject]@{ id = $_.PNPDeviceID; hardware_ids = @($_.HardwareID) } }
) | ConvertTo-Json -Depth 4 -Compress"""
    run = subprocess.run(['powershell.exe', '-NoLogo', '-NoProfile', '-NonInteractive', '-Command', script],
                         capture_output=True, timeout=30, check=False)
    if run.returncode != 0 or len(run.stdout) > MAX_JSON_BYTES:
        raise ValueError('read-only Windows PCI inventory failed or exceeded bounds')
    try:
        records = json.loads(run.stdout.decode('utf-8-sig'))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ValueError('invalid Windows inventory response') from error
    if type(records) is dict:
        records = [records]
    if records is None:
        records = []
    if type(records) is not list or len(records) > MAX_DEVICES:
        raise ValueError('invalid Windows inventory list')
    devices = []
    for record in records:
        fields(record, ('id', 'hardware_ids'), 'Windows inventory record')
        location = text(record['id'], 1, 512, 'Windows inventory location')
        hardware_ids = record['hardware_ids']
        if type(hardware_ids) is not list or len(hardware_ids) > 32:
            raise ValueError('invalid Windows hardware identity list')
        identity = next((item for item in hardware_ids if type(item) is str and
                         re.match(r'PCI\\VEN_[0-9A-F]{4}&DEV_[0-9A-F]{4}', item, re.I)), None)
        if identity is None:
            continue
        match = re.search(r'VEN_([0-9A-F]{4})&DEV_([0-9A-F]{4})', identity, re.I)
        device = {'vendor': match[1], 'device': match[2], 'location': location}
        subsystem = re.search(r'&SUBSYS_([0-9A-F]{4})([0-9A-F]{4})', identity, re.I)
        if subsystem:
            device.update(subsystem_device=subsystem[1], subsystem_vendor=subsystem[2])
        revision = re.search(r'&REV_([0-9A-F]{2})', identity, re.I)
        if revision:
            device['revision'] = int(revision[1], 16)
        devices.append(device)
    return validate_inventory({'schema_version': 1, 'devices': devices})


def bounded_region(data, offset, size, label):
    if offset < 0 or size < 0 or offset > len(data) or size > len(data) - offset:
        raise ValueError(f'{label} exceeds module file bounds')
    return data[offset:offset + size]


def validate_module(data, architecture, package):
    """Check bounded ELF identity and the module declaration before copying bytes.

    The kernel's loader additionally validates relocations and page permissions.
    This host validator never loads or executes the module.
    """
    if architecture not in ARCHITECTURES:
        raise ValueError('unsupported target architecture')
    if not 64 <= len(data) <= MAX_MODULE_BYTES:
        raise ValueError('module file requires 64 bytes..8 MiB')
    header = struct.unpack_from('<16sHHIQQQIHHHHHH', data)
    identity, kind, machine, version, entry, phoff, shoff, flags, ehsize, phsize, phcount, shsize, shcount, shstr = header
    if identity[:7] != b'\x7fELF\x02\x01\x01' or kind != 3 or machine != ARCHITECTURES[architecture] or version != 1:
        raise ValueError('module must be target-architecture little-endian ELF64 ET_DYN')
    if ehsize != 64 or phsize != 56 or not 1 <= phcount <= 32:
        raise ValueError('invalid ELF header/program-header table')
    bounded_region(data, phoff, phcount * phsize, 'ELF program headers')
    loads, load_files, notes, executable_entry = [], [], [], False
    for index in range(phcount):
        kind, permissions, offset, address, physical, file_size, memory_size, alignment = struct.unpack_from('<IIQQQQQQ', data, phoff + index * phsize)
        if kind == 1:
            if permissions not in (4, 5, 6) or file_size > memory_size or memory_size == 0:
                raise ValueError('invalid PT_LOAD size or permissions')
            if address >= MAX_IMAGE_BYTES or memory_size > MAX_IMAGE_BYTES - address:
                raise ValueError('module image exceeds 4 MiB')
            if (not 4096 <= alignment <= MAX_IMAGE_BYTES or alignment & (alignment - 1) or
                    address % 4096 != 0 or address % alignment != offset % alignment):
                raise ValueError('invalid PT_LOAD alignment')
            bounded_region(data, offset, file_size, 'PT_LOAD file data')
            page_start, page_end = address & ~4095, (address + memory_size + 4095) & ~4095
            if any(page_start < end and start < page_end for start, end in loads):
                raise ValueError('PT_LOAD segments overlap at page granularity')
            loads.append((page_start, page_end))
            load_files.append((offset, offset + file_size, permissions))
            executable_entry |= permissions == 5 and address <= entry < address + memory_size
        elif kind == 4:
            notes.append((offset, bounded_region(data, offset, file_size, 'PT_NOTE')))
    if not 1 <= len(loads) <= MAX_LOAD_SEGMENTS or not executable_entry:
        raise ValueError('module requires bounded PT_LOAD segments and executable entry')
    declarations = []
    for note_offset, content in notes:
        cursor = 0
        while cursor < len(content):
            if len(content) - cursor < 12:
                raise ValueError('truncated ELF note')
            name_size, descriptor_size, note_type = struct.unpack_from('<III', content, cursor)
            cursor += 12
            name = bounded_region(content, cursor, name_size, 'ELF note name')
            cursor += (name_size + 3) & ~3
            descriptor = bounded_region(content, cursor, descriptor_size, 'ELF note descriptor')
            descriptor_offset = note_offset + cursor
            cursor += (descriptor_size + 3) & ~3
            if cursor > len(content):
                raise ValueError('truncated ELF note alignment')
            if name == NOTE_NAME and note_type == NOTE_TYPE:
                if not any(start <= descriptor_offset and descriptor_offset + descriptor_size <= end and permissions == 4
                           for start, end, permissions in load_files):
                    raise ValueError('Bedrock declaration must be contained in a read-only PT_LOAD')
                declarations.append(descriptor)
    if not 1 <= len(declarations) <= MAX_MATCH_NOTES:
        raise ValueError('module requires 1..8 bounded Bedrock ABI declarations')
    aliases, metadata = set(), None
    for descriptor in declarations:
        if len(descriptor) != 64 or descriptor[:8] != NOTE_MAGIC:
            raise ValueError('invalid Bedrock ABI declaration size/magic')
        size, abi_major, abi_minor, module_class, module_version = struct.unpack_from('<IHHII', descriptor, 8)
        vendor, product, subvendor, subproduct, target, reserved, capabilities = struct.unpack_from('<HHHHHHI', descriptor, 24)
        identifier = descriptor[40:64]
        expected_id = package['id'].encode('ascii')
        if len(expected_id) >= 24 or identifier != expected_id + bytes(24 - len(expected_id)):
            raise ValueError('module declaration id does not match package')
        if size != 64 or abi_major != DRIVER_ABI['major'] or abi_minor != DRIVER_ABI['minor'] or module_class != 1:
            raise ValueError('module declaration ABI/class mismatch')
        if module_version == 0 or target != ARCHITECTURES[architecture] or reserved != 0 or capabilities & ~3:
            raise ValueError('module declaration version/architecture/reserved/capability mismatch')
        current = (abi_major, abi_minor, module_class, module_version, target, capabilities, identifier)
        if metadata is not None and current != metadata:
            raise ValueError('module PCI aliases disagree on ABI metadata')
        metadata = current
        alias = (vendor, product, subvendor, subproduct)
        if alias in aliases:
            raise ValueError('duplicate module PCI alias')
        aliases.add(alias)
    expected_matches = {pci_match(item, 'catalogue PCI match') for item in package['pci_matches']}
    if {(vendor, product) for vendor, product, _, _ in aliases} != expected_matches:
        raise ValueError('module PCI declarations do not match catalogue identities')
    return tuple(declarations)


def validate_package_metadata(metadata, architecture, package, data=None):
    """Shared strict metadata/byte validation for local packages and ESP images."""
    fields(metadata, ('schema_version', 'id', 'package_version', 'architecture', 'driver_abi', 'module'), 'package metadata')
    integer(metadata['schema_version'], 1, 1, 'package metadata.schema_version')
    validate_abi(metadata['driver_abi'], 'package metadata.driver_abi')
    for name in ('id', 'package_version', 'architecture'):
        expected = architecture if name == 'architecture' else package[name]
        if metadata[name] != expected:
            raise ValueError(f'package metadata {name} does not match catalogue/target')
    module = fields(metadata['module'], ('file', 'byte_length', 'sha256'), 'package metadata.module')
    safe_name(module['file'], 'package metadata.module.file')
    if module['file'] != package['module']:
        raise ValueError('module filename does not match catalogue')
    integer(module['byte_length'], 64, MAX_MODULE_BYTES, 'module.byte_length')
    if type(module['sha256']) is not str or not SHA256.fullmatch(module['sha256']):
        raise ValueError('module.sha256 requires 64 lowercase hexadecimal digits')
    if data is not None:
        if len(data) != module['byte_length'] or hashlib.sha256(data).hexdigest() != module['sha256']:
            raise ValueError('module byte length/SHA-256 does not match its local metadata')
        validate_module(data, architecture, package)
    return metadata


def validate_driver_manifest(manifest, architecture, catalogue):
    catalogue = validate_catalogue(catalogue)
    fields(manifest, ('schema_version', 'architecture', 'driver_abi', 'packages'), 'driver manifest')
    integer(manifest['schema_version'], 1, 1, 'driver manifest.schema_version')
    validate_abi(manifest['driver_abi'], 'driver manifest.driver_abi')
    if architecture not in ARCHITECTURES or manifest['architecture'] != architecture:
        raise ValueError('driver manifest architecture does not match target')
    if type(manifest['packages']) is not list or len(manifest['packages']) > MAX_PACKAGES:
        raise ValueError('driver manifest packages must be a bounded list')
    known = {package['id']: package for package in catalogue['packages']}
    identifiers, names = set(), {'manifest.json'}
    for metadata in manifest['packages']:
        if type(metadata) is not dict or type(metadata.get('id')) is not str or metadata['id'] not in known:
            raise ValueError('driver manifest package is absent from the catalogue')
        package = known[metadata['id']]
        if package['architectures'][architecture] != 'experimental':
            raise ValueError('driver manifest package has an unsupported native platform')
        validate_package_metadata(metadata, architecture, package)
        filename = metadata['module']['file'].casefold()
        if metadata['id'] in identifiers or filename in names:
            raise ValueError('driver manifest contains duplicate package or path collision')
        identifiers.add(metadata['id'])
        names.add(filename)
    return manifest


def load_package(module_root, architecture, package):
    directory = check_directory(module_root) / architecture / package['directory']
    metadata_path = directory / 'package.json'
    if not metadata_path.exists() and not metadata_path.is_symlink():
        return None
    check_directory(directory)
    root = Path(module_root).resolve(strict=True)
    if not directory.resolve(strict=True).is_relative_to(root):
        raise ValueError('package directory escapes local module root')
    metadata = validate_package_metadata(read_json(metadata_path), architecture, package)
    module = metadata['module']
    module_path = directory / module['file']
    if not module_path.exists() and not module_path.is_symlink():
        return None
    data = read_file(module_path, MAX_MODULE_BYTES, 64)
    validate_package_metadata(metadata, architecture, package, data)
    declaration = validate_module(data, architecture, package)
    return {'metadata': metadata, 'bytes': data, 'declaration': declaration}


def select_packages(catalogue, inventory, architecture, module_root, all_compatible=False):
    catalogue, inventory = validate_catalogue(catalogue), validate_inventory(inventory)
    if architecture not in ARCHITECTURES:
        raise ValueError('architecture requires x86_64, aarch64, or riscv64')
    if type(all_compatible) is not bool:
        raise ValueError('all_compatible must be an explicit boolean')
    packages = {item['id']: item for item in catalogue['packages']}
    exact = {pci_match(match, 'PCI match'): package for package in packages.values() for match in package['pci_matches']}
    unsupported = {pci_match({'vendor': item['vendor'], 'device': item['device']}, 'unsupported PCI match'): item
                   for item in catalogue['known_unsupported']}
    found, required = [], set()
    for index, device in enumerate(inventory['devices']):
        identity = pci_match({'vendor': device['vendor'], 'device': device['device']}, 'inventory identity')
        row = {'inventory_index': index, 'identity': device}
        package = exact.get(identity)
        if package is None:
            if identity in unsupported:
                row.update(status='driver-unimplemented', name=unsupported[identity]['name'])
            else:
                row['status'] = 'no-hardware-match'
        elif package['architectures'][architecture] == 'platform-unsupported':
            row.update(status='platform-unsupported', package=package['id'])
        else:
            row.update(status='pending', package=package['id'])
            required.add(package['id'])
        found.append(row)
    matched = set(required)
    if all_compatible:
        required.update(package['id'] for package in packages.values()
                        if package['architectures'][architecture] == 'experimental')
    loaded, unavailable = {}, []
    for identifier in sorted(required):
        package = packages[identifier]
        available = load_package(module_root, architecture, package)
        if available is None:
            unavailable.append(identifier)
        else:
            loaded[identifier] = available
    for row in found:
        if row['status'] == 'pending':
            row['status'] = 'package-staged' if row['package'] in loaded else 'module-unavailable'
    manifest = {'schema_version': 1, 'architecture': architecture, 'driver_abi': DRIVER_ABI,
                'packages': [loaded[name]['metadata'] for name in sorted(loaded)]}
    receipt = {'schema_version': 1, 'architecture': architecture,
               'policy': 'all-compatible' if all_compatible else 'hardware-matched',
               'boot_essentials': {'delivery': 'built-in', 'components': catalogue['boot_essentials']},
               'devices': found,
               'selected': [{'id': name, 'reason': 'hardware-match' if name in matched else 'offline-fallback',
                             'module': loaded[name]['metadata']['module'],
                             'path': 'EFI/Bedrock/Drivers/' + loaded[name]['metadata']['module']['file']}
                            for name in sorted(loaded)],
               'unavailable_modules': unavailable,
               'physical_radio_verified': False}
    return manifest, receipt, loaded


def windows_directory_publish(staging, output):
    """Retry only transient Windows sharing failures for our unchanged staging.

    MoveFile remains no-replace. Each retry requires the original ordinary
    sibling directory and absent destination; a competing publisher wins.
    """
    staging, output = Path(staging), Path(output)
    parent = output.parent.resolve(strict=True)
    if (staging.parent.resolve(strict=True) != parent or
            not staging.name.startswith(('.bedrock-drivers-', '.bedrock-package-'))):
        raise ValueError('directory publication requires an owned sibling staging directory')

    def owned_identity():
        info = staging.lstat()
        if (not stat.S_ISDIR(info.st_mode) or is_reparse(info) or
                staging.parent.resolve(strict=True) != parent or output.parent.resolve(strict=True) != parent):
            raise ValueError('staging directory is no longer an ordinary owned sibling')
        return info.st_dev, info.st_ino

    identity = owned_identity()

    def unchanged_and_absent():
        if os.path.lexists(output):
            raise FileExistsError(errno.EEXIST, 'output already exists', str(output))
        if owned_identity() != identity:
            raise ValueError('staging directory ownership changed during publication')

    delays = (0.05, 0.1, 0.2, 0.2)
    deadline = time.monotonic() + 1.0
    last_error = None
    for attempt in range(len(delays) + 1):
        unchanged_and_absent()
        if attempt and time.monotonic() >= deadline:
            raise last_error
        try:
            os.rename(staging, output)  # Windows MoveFile without replacement.
            return
        except OSError as error:
            if getattr(error, 'winerror', None) not in (5, 32, 33) or attempt == len(delays):
                raise
            last_error = error
            unchanged_and_absent()
            if deadline - time.monotonic() <= delays[attempt]:
                raise
            time.sleep(delays[attempt])


def atomic_directory_publish(staging, output):
    """Publish a completed directory without replacing another publisher's path."""
    if os.name == 'nt':
        windows_directory_publish(staging, output)
        return
    if sys.platform.startswith('linux'):
        libc = ctypes.CDLL(None, use_errno=True)
        rename = getattr(libc, 'renameat2', None)
        if rename is None:
            raise ValueError('atomic no-replace directory publication is unavailable on this host')
        rename.argtypes = (ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint)
        rename.restype = ctypes.c_int
        if rename(-100, os.fsencode(staging), -100, os.fsencode(output), 1) != 0:
            error = ctypes.get_errno()
            raise OSError(error, os.strerror(error), str(output))
        return
    if sys.platform == 'darwin':
        libc = ctypes.CDLL(None, use_errno=True)
        rename = getattr(libc, 'renamex_np', None)
        if rename is None:
            raise ValueError('atomic no-replace directory publication is unavailable on this host')
        rename.argtypes = (ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint)
        rename.restype = ctypes.c_int
        if rename(os.fsencode(staging), os.fsencode(output), 4) != 0:  # RENAME_EXCL
            error = ctypes.get_errno()
            raise OSError(error, os.strerror(error), str(output))
        return
    raise ValueError('atomic no-replace directory publication is unavailable on this host')


def json_bytes(value):
    return (json.dumps(value, indent=2, sort_keys=True) + '\n').encode('utf-8')


def stage_packages(catalogue, inventory, architecture, module_root, output, all_compatible=False):
    output = check_ordinary_path(output).absolute()
    parent = check_directory(output.parent)
    if os.path.lexists(output):
        raise FileExistsError(f'output already exists: {output}')
    manifest, receipt, loaded = select_packages(catalogue, inventory, architecture, module_root, all_compatible)
    staging = Path(tempfile.mkdtemp(prefix='.bedrock-drivers-', dir=parent))
    try:
        drivers = staging / 'EFI' / 'Bedrock' / 'Drivers'
        drivers.mkdir(parents=True)
        for name, package in loaded.items():
            target = drivers / package['metadata']['module']['file']
            with target.open('xb') as stream:
                stream.write(package['bytes'])
                stream.flush()
                os.fsync(stream.fileno())
        for target, value in ((drivers / 'manifest.json', manifest), (staging / 'driver-selection.json', receipt)):
            with target.open('xb') as stream:
                stream.write(json_bytes(value))
                stream.flush()
                os.fsync(stream.fileno())
        atomic_directory_publish(staging, output)
        return receipt
    finally:
        # Only remove our unpublished temporary directory, checked against its
        # original intended parent; never delete an existing output directory.
        if staging.exists():
            resolved = staging.resolve(strict=True)
            if resolved.parent != parent.resolve(strict=True) or not resolved.name.startswith('.bedrock-drivers-'):
                raise ValueError('refusing cleanup outside the owned staging directory')
            shutil.rmtree(resolved)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--catalogue', type=Path, default=DEFAULT_CATALOGUE)
    inventory = parser.add_mutually_exclusive_group()
    inventory.add_argument('--inventory', type=Path, help='explicit target PCI inventory JSON')
    inventory.add_argument('--inventory-windows', action='store_true', help='read this Windows host PCI identities; target architecture remains explicit')
    parser.add_argument('--arch', required=True, choices=ARCHITECTURES)
    parser.add_argument('--modules', required=True, type=Path, help='local root containing <arch>/<driver>/package.json and module')
    parser.add_argument('--output', required=True, type=Path, help='new ordinary staging directory; its parent must exist')
    parser.add_argument('--all-compatible', action='store_true', help='include available target-compatible packages for offline media')
    args = parser.parse_args(argv)
    if not args.inventory_windows and args.inventory is None and not args.all_compatible:
        parser.error('provide --inventory/--inventory-windows, or --all-compatible for explicit offline media')
    try:
        source = (windows_inventory() if args.inventory_windows else read_json(args.inventory)
                  if args.inventory is not None else {'schema_version': 1, 'devices': []})
        receipt = stage_packages(read_json(args.catalogue), source, args.arch, args.modules, args.output, args.all_compatible)
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        parser.exit(1, f'driver package preparation failed: {error}\n')
    print(f"Staged {len(receipt['selected'])} driver package(s) for {args.arch}: {args.output}")
    for row in receipt['devices']:
        print(f"  {row['identity']['vendor']}:{row['identity']['device']}: {row['status']}")
    if receipt['unavailable_modules']:
        print('Unavailable local modules: ' + ', '.join(receipt['unavailable_modules']))
    return 0


if __name__ == '__main__':
    sys.exit(main())
