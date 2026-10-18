#!/usr/bin/env python3
# SPDX-License-Identifier: ISC
# Copyright (C) 2026 Bedrock contributors
"""Adapt Zig's pre-created output root to the public new-directory driver stager.

The managed root must be an ordinary empty directory. The complete selected
tree is published atomically at its new `selected` child; nothing is replaced.
"""

import argparse
import importlib.util
from pathlib import Path
import sys


spec = importlib.util.spec_from_file_location('bedrock_build_driver_packages', Path(__file__).with_name('package-drivers.py'))
packager = importlib.util.module_from_spec(spec)
spec.loader.exec_module(packager)


def stage_build_tree(catalogue, module_root, architecture, output_root, all_compatible=False):
    root = packager.check_directory(output_root)
    if any(root.iterdir()):
        raise FileExistsError(f'build output root must be empty: {root}')
    return packager.stage_packages(catalogue, {'schema_version': 1, 'devices': []},
                                   architecture, module_root, root / 'selected', all_compatible)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--catalogue', type=Path, default=packager.DEFAULT_CATALOGUE)
    parser.add_argument('--arch', required=True, choices=packager.ARCHITECTURES)
    parser.add_argument('--modules', required=True, type=Path)
    parser.add_argument('--output-root', required=True, type=Path,
                        help='pre-created ordinary empty build directory; publishes its new selected child')
    parser.add_argument('--all-compatible', action='store_true', help='include compatible local packages for explicit offline media')
    args = parser.parse_args(argv)
    try:
        receipt = stage_build_tree(packager.read_json(args.catalogue), args.modules, args.arch,
                                   args.output_root, args.all_compatible)
    except (ValueError, OSError) as error:
        parser.exit(1, f'driver build staging failed: {error}\n')
    print(f"Staged {len(receipt['selected'])} driver package(s) at {args.output_root / 'selected'}")
    return 0


if __name__ == '__main__':
    sys.exit(main())
