#!/usr/bin/env python3
"""Build a bounded sparse Bedrock installation payload from ordinary files."""
import argparse
import binascii
import hashlib
import importlib.util
from pathlib import Path
import struct
import sys

ROOT = Path(__file__).resolve().parent
def module(name):
    spec = importlib.util.spec_from_file_location(name.replace('-', '_'), ROOT / (name + '.py'))
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result
images, data = module('make-uefi-image'), module('make-data-image')
MACHINES = {'x86_64': 62, 'arm64': 183, 'riscv64': 243}
ESP_FIRST, ESP_BLOCKS, DATA_FIRST, DATA_BLOCKS = 2048, 128991, 131072, 8192

def build(boot, arch):
    if len(boot) != images.IMAGE_SIZE or boot[:512][510:] != b'\x55\xaa' or boot[512:520] != b'EFI PART':
        raise ValueError('source must be a complete Bedrock GPT/FAT32 boot image')
    table = boot[1024:17408]
    if table[:16] != images.ESP_TYPE.bytes_le or struct.unpack_from('<QQ', table, 32) != (ESP_FIRST, ESP_FIRST + ESP_BLOCKS - 1):
        raise ValueError('unsupported source partition layout')
    if any(table[128:]):
        raise ValueError('source must have only the boot ESP')
    seed = data.build_image()
    ranges = [(ESP_FIRST, boot[ESP_FIRST * 512:(ESP_FIRST + ESP_BLOCKS) * 512]), (DATA_FIRST, seed)]
    extents = []
    for first, content in ranges:
        start = None
        for block in range(0, len(content) // 512 + 64, 64):
            nonzero = block < len(content) // 512 and any(content[block * 512:min(block + 64, len(content) // 512) * 512])
            if nonzero and start is None:
                start = block
            elif not nonzero and start is not None:
                extents.append((first + start, content[start * 512:min(block, len(content) // 512) * 512]))
                start = None
    if not 0 < len(extents) <= 256:
        raise ValueError('installation payload exceeds bounded extent count')
    records, body = bytearray(), bytearray()
    offset = 512 + len(extents) * 32
    for first, content in extents:
        records += struct.pack('<QQQII', first, len(content) // 512, offset, binascii.crc32(content) & 0xffffffff, 0)
        body += content
        offset += len(content)
    header = bytearray(512)
    struct.pack_into('<8sIHHQQQQQII', header, 0, b'BEDIP001', 1, MACHINES[arch], 512, offset,
                     ESP_FIRST, ESP_BLOCKS, DATA_FIRST, DATA_BLOCKS, len(extents), binascii.crc32(records) & 0xffffffff)
    header[64:96] = hashlib.sha256(boot + seed).digest()
    struct.pack_into('<I', header, 124, binascii.crc32(header) & 0xffffffff)
    return bytes(header + records + body)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('boot_image', type=Path)
    parser.add_argument('payload', type=Path)
    parser.add_argument('--arch', required=True, choices=MACHINES)
    args = parser.parse_args()
    try:
        images.ordinary_path(args.boot_image)
        images.ordinary_path(args.payload, output=True)
        if images.same_path(args.boot_image, args.payload):
            raise ValueError('source and output must differ')
        if args.boot_image.stat().st_size != images.IMAGE_SIZE:
            raise ValueError('unexpected source image size')
        output = build(args.boot_image.read_bytes(), args.arch)
        args.payload.write_bytes(output)
        print(f'Created {args.payload}: {len(output)} bytes, sparse ESP and persistent data seed')
        return 0
    except (OSError, ValueError) as error:
        print(f'Installer payload creation failed: {error}', file=sys.stderr)
        return 1
if __name__ == '__main__':
    sys.exit(main())
