#!/usr/bin/env python3
"""Explicitly format an ordinary image file with Bedrock data format v1.

The 4 MiB image is dedicated OS data media, not a partitioned boot disk.
Existing files require --force. No block devices, mounting, or external tools.
"""
import argparse
import binascii
import os
from pathlib import Path, PureWindowsPath
import stat
import struct
import sys
import tempfile

SECTOR_SIZE = 512
BANK_BLOCKS = 4096
IMAGE_SIZE = 2 * BANK_BLOCKS * SECTOR_SIZE
RECORD_HEADER_SIZE = 64
MAGIC = b"BEDFS001"


def validate_output(path, windows=None):
    """Validate syntax before filesystem queries, including DOS device aliases."""
    if windows is None:
        windows = os.name == "nt"
    if windows:
        text = str(path).replace("/", "\\")
        if text.startswith(("\\\\.\\", "\\\\?\\", "\\??\\")):
            raise ValueError("device and namespace paths are not supported")
        parsed = PureWindowsPath(text)
        reserved = {"CON", "PRN", "AUX", "NUL", "CONIN$", "CONOUT$"}
        reserved.update(prefix + digit for prefix in ("COM", "LPT")
                        for digit in "123456789\u00b9\u00b2\u00b3")
        for part in parsed.parts:
            if part == parsed.anchor or part in (".", ".."):
                continue
            name = part.rstrip(" .").partition(".")[0].rstrip(" ").upper()
            if name in reserved or part.endswith((" ", ".")) or any(
                    char in '<>:"|?*' or ord(char) < 32 for char in part):
                raise ValueError("the output must be an ordinary Windows file path")
    if path.is_symlink():
        raise ValueError("the output must not be a symbolic link")
    if path.exists() and not stat.S_ISREG(path.stat().st_mode):
        raise ValueError("the output must be an ordinary file")
    if not path.parent.is_dir():
        raise ValueError("the output directory must already exist")


def build_image(nodes=32, file_bytes=4096, path_bytes=128):
    if not 1 <= nodes <= 65535 or not 1 <= path_bytes <= 65535 or file_bytes < 0:
        raise ValueError("invalid filesystem capacities")
    record_bytes = RECORD_HEADER_SIZE + path_bytes + file_bytes
    payload_size = nodes * record_bytes
    if payload_size > (BANK_BLOCKS - 1) * SECTOR_SIZE:
        raise ValueError("the configured snapshot does not fit one bank")
    image = bytearray(IMAGE_SIZE)
    payload = bytearray(payload_size)
    # Root: directory, system domain, serial 1, owner 0, parent slot 0, path '/'.
    struct.pack_into("<BBBBIQIIQ", payload, 0, 1, 1, 0, 0, 1, 0, 0, 1, 0)
    payload[RECORD_HEADER_SIZE] = ord("/")
    image[SECTOR_SIZE:SECTOR_SIZE + payload_size] = payload
    header = bytearray(SECTOR_SIZE)
    struct.pack_into("<8sIIQQIIIIQI I II", header, 0,
                     MAGIC, 1, SECTOR_SIZE, 1, 2 * BANK_BLOCKS, BANK_BLOCKS,
                     nodes, file_bytes, path_bytes, payload_size,
                     binascii.crc32(payload) & 0xffffffff, 0, 2, 0)
    struct.pack_into("<I", header, 60, binascii.crc32(header) & 0xffffffff)
    image[:SECTOR_SIZE] = header
    # Bank 1 is intentionally invalid until the first successful transaction.
    return image


def write_image(path, *, force=False, nodes=32, file_bytes=4096, path_bytes=128):
    validate_output(path)
    if path.exists() and not force:
        raise ValueError("the output exists; --force explicitly replaces this data image")
    image = build_image(nodes, file_bytes, path_bytes)
    temporary_path = None
    try:
        with tempfile.NamedTemporaryFile(dir=path.parent, prefix=path.name + ".",
                                         suffix=".tmp", delete=False) as temporary:
            temporary_path = Path(temporary.name)
            temporary.write(image)
            temporary.flush()
            os.fsync(temporary.fileno())
        if force:
            os.replace(temporary_path, path)
        else:
            # Atomic no-replacement publication. A second launcher can create
            # the final path after validation without losing its data here.
            # The sibling temporary file is on the same filesystem; unsupported
            # hard links fail explicitly rather than falling back to overwrite.
            os.link(temporary_path, path)
            temporary_path.unlink()
        temporary_path = None
    finally:
        if temporary_path is not None:
            temporary_path.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    parser.add_argument("--force", action="store_true", help="explicitly replace an existing image file")
    parser.add_argument("--nodes", type=int, default=32)
    parser.add_argument("--file-bytes", type=int, default=4096)
    parser.add_argument("--path-bytes", type=int, default=128)
    args = parser.parse_args()
    try:
        write_image(args.output, force=args.force, nodes=args.nodes,
                    file_bytes=args.file_bytes, path_bytes=args.path_bytes)
    except (OSError, ValueError, struct.error) as error:
        print(f"make-data-image: {error}", file=sys.stderr)
        return 1
    print(f"Created {args.output} ({IMAGE_SIZE} bytes, Bedrock data v1)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
