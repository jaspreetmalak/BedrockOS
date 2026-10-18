#!/usr/bin/env python3
# SPDX-License-Identifier: ISC
# Copyright (C) 2026 Bedrock contributors
"""Describe a built MT7922 module and publish its bounded local package tree.

This inspects ELF bytes without executing them. Compiling/describing an ARM or
RISC-V package does not change its unavailable native platform catalogue status.
"""

import argparse
import hashlib
import importlib.util
import os
from pathlib import Path
import shutil
import sys
import tempfile


spec = importlib.util.spec_from_file_location('bedrock_driver_packager', Path(__file__).with_name('package-drivers.py'))
packager = importlib.util.module_from_spec(spec)
spec.loader.exec_module(packager)


def describe_package(module_file, output_directory, architecture):
    if architecture not in packager.ARCHITECTURES:
        raise ValueError('architecture requires x86_64, aarch64, or riscv64')
    catalogue = packager.validate_catalogue(packager.read_json(packager.DEFAULT_CATALOGUE))
    package = next((item for item in catalogue['packages'] if item['id'] == 'org.bedrock.mt7922'), None)
    if package is None:
        raise ValueError('MT7922 package is absent from the local catalogue')
    data = packager.read_file(module_file, packager.MAX_MODULE_BYTES, 64)
    packager.validate_module(data, architecture, package)
    metadata = {'schema_version': 1, 'id': package['id'],
                'package_version': package['package_version'], 'architecture': architecture,
                'driver_abi': dict(packager.DRIVER_ABI),
                'module': {'file': package['module'], 'byte_length': len(data),
                           'sha256': hashlib.sha256(data).hexdigest()}}

    root = packager.check_ordinary_path(output_directory).absolute()
    # Zig's Run output-directory argument may create this directory first.
    # Existing package paths are still never overwritten.
    if not os.path.lexists(root):
        root.mkdir(parents=True)
    packager.check_directory(root)
    parent = root / architecture
    if not os.path.lexists(parent):
        parent.mkdir()
    packager.check_directory(parent)
    destination = parent / package['directory']
    if os.path.lexists(destination):
        raise FileExistsError(f'package output already exists: {destination}')
    staging = Path(tempfile.mkdtemp(prefix='.bedrock-package-', dir=parent))
    try:
        for name, content in ((package['module'], data), ('package.json', packager.json_bytes(metadata))):
            with (staging / name).open('xb') as stream:
                stream.write(content)
                stream.flush()
                os.fsync(stream.fileno())
        packager.atomic_directory_publish(staging, destination)
    finally:
        if staging.exists():
            resolved = staging.resolve(strict=True)
            if resolved.parent != parent.resolve(strict=True) or not resolved.name.startswith('.bedrock-package-'):
                raise ValueError('refusing cleanup outside the owned package staging directory')
            shutil.rmtree(resolved)
    return metadata


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('module_file', type=Path)
    parser.add_argument('output_directory', type=Path)
    parser.add_argument('--arch', required=True, choices=packager.ARCHITECTURES)
    args = parser.parse_args(argv)
    try:
        metadata = describe_package(args.module_file, args.output_directory, args.arch)
    except (ValueError, OSError) as error:
        parser.exit(1, f'driver package description failed: {error}\n')
    print(f"Described {metadata['id']} for {args.arch}: {metadata['module']['byte_length']} bytes, SHA-256 {metadata['module']['sha256']}")
    return 0


if __name__ == '__main__':
    sys.exit(main())
