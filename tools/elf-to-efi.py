#!/usr/bin/env python3
"""Convert a bounded RV64 static PIE loader to a relocatable UEFI PE32+ image.

Zig 0.17 cannot emit RISC-V COFF directly. This preserves ELF segment RVAs and
translates symbol-free R_RISCV_RELATIVE records to PE DIR64 base relocations.
"""
import argparse
import importlib.util
from pathlib import Path
import struct
import sys

MAX_SIZE = 32 * 1024 * 1024
MAX_SPAN = 16 * 1024 * 1024

def require(condition, message):
    if not condition:
        raise ValueError(message)

def align(value, alignment):
    return (value + alignment - 1) & -alignment

def convert(source):
    require(64 <= len(source) <= MAX_SIZE, 'ELF input size')
    require(source[:7] == b'\x7fELF\x02\x01\x01' and source[7:9] == b'\0\0', 'ELF64 little-endian SYSV required')
    def read(fmt, offset):
        size = struct.calcsize(fmt)
        require(0 <= offset <= len(source) - size, 'ELF file bounds')
        return struct.unpack_from(fmt, source, offset)
    kind, machine, version, entry, phoff = read('<HHIQQ', 16)
    require(kind == 3 and machine == 243 and version == 1 and entry % 2 == 0, 'RV64 PIE entry required')
    flags, ehsize, phsize, phcount = read('<IHHH', 48)
    require(flags & ~1 == 0 and ehsize == 64 and phsize == 56 and 0 < phcount <= 64, 'RV64 soft-float ELF ABI/header')
    segments, dynamic = [], None
    for index in range(phcount):
        values = read('<IIQQQQQQ', phoff + index * 56)
        ptype, pflags, offset, address, physical, filesz, memsz, alignment = values
        require(ptype not in (3, 7), 'ELF interpreter/TLS unsupported')
        if ptype not in (1, 2):
            continue
        require(filesz <= memsz and offset <= len(source) - filesz and address == physical,
                'ELF segment bounds')
        require(pflags & ~7 == 0 and address + memsz <= MAX_SPAN and alignment <= 4096 and
                (alignment <= 1 or alignment & (alignment - 1) == 0 and address % alignment == offset % alignment),
                'ELF segment alignment/span')
        if ptype == 2:
            require(dynamic is None and 0 < filesz == memsz <= 65536 and filesz % 16 == 0, 'ELF dynamic geometry')
            dynamic = (offset, address, filesz)
        elif memsz:
            require(address >= 4096 and address % 4096 == 0, 'ELF load RVA alignment')
            require(all(address + memsz <= s['rva'] or s['rva'] + s['size'] <= address for s in segments), 'ELF segment overlap')
            segments.append(dict(rva=address, size=memsz, data=bytearray(source[offset:offset+filesz]), flags=pflags))
    require(segments and any(s['flags'] & 1 and s['rva'] <= entry < s['rva'] + len(s['data']) for s in segments), 'ELF executable entry')
    segments.sort(key=lambda s: s['rva'])
    span = max(s['rva'] + s['size'] for s in segments)
    def location(address, size):
        for segment in segments:
            if segment['rva'] <= address and address + size <= segment['rva'] + len(segment['data']):
                return segment, address - segment['rva']
        raise ValueError('ELF metadata/relocation outside file-backed load segment')
    relocations, seen_targets = [], set()
    if dynamic:
        offset, address, size = dynamic
        segment, position = location(address, size)
        require(segment['data'][position:position+size] == source[offset:offset+size], 'ELF dynamic mapping')
        tags, terminated = {}, False
        for cursor in range(offset, offset + size, 16):
            tag, value = read('<QQ', cursor)
            if tag == 0:
                terminated = True
                break
            require(tag not in (1, 2, 17, 18, 19, 20, 22, 23, 35, 36, 37), 'ELF unsupported relocation dependency')
            require(tag in (4,5,6,7,8,9,10,11,21,30,0x6ffffef5,0x6ffffff9,0x6ffffffb), 'ELF unsupported dynamic tag')
            if tag in (7,8,9):
                require(tag not in tags, 'ELF duplicate relocation tag')
                tags[tag] = value
        require(terminated, 'ELF unterminated dynamic table')
        if tags:
            require(set(tags) == {7,8,9} and tags[9] == 24 and tags[8] % 24 == 0 and tags[8] // 24 <= 65536,
                    'ELF RELA geometry')
            rela_segment, rela_start = location(tags[7], tags[8])
            records = bytes(rela_segment['data'][rela_start:rela_start+tags[8]])
            for cursor in range(0, len(records), 24):
                target, info, addend = struct.unpack_from('<QQq', records, cursor)
                if info == 0:
                    continue
                require(info == 3 and target % 8 == 0 and 0 <= addend <= span, 'ELF symbol-free relative relocation required')
                target_segment, target_offset = location(target, 8)
                require(target_segment['flags'] & 2 and target not in seen_targets, 'ELF writable unique relocation target required')
                struct.pack_into('<Q', target_segment['data'], target_offset, addend)
                seen_targets.add(target)
                relocations.append(target)
    reloc_data = bytearray()
    pages = {}
    for target in sorted(relocations):
        pages.setdefault(target & ~4095, []).append(0xA000 | (target & 4095))
    for page, records in sorted(pages.items()):
        if len(records) % 2:
            records.append(0)  # PE ABSOLUTE padding; each block is 4-byte aligned.
        reloc_data += struct.pack('<II', page, 8 + len(records) * 2)
        reloc_data += struct.pack('<' + 'H' * len(records), *records)
    # An empty relocation directory is valid only for a truly relative image.
    reloc_rva = align(span, 4096)
    if reloc_data:
        segments.append(dict(rva=reloc_rva, size=len(reloc_data), data=reloc_data, flags=4, reloc=True))
    header_size = align(128 + 4 + 20 + 240 + 40 * len(segments), 512)
    require(header_size <= segments[0]['rva'], 'PE headers overlap load RVA')
    image = bytearray(header_size)
    image[:2] = b'MZ'
    struct.pack_into('<I', image, 60, 128)
    image[128:132] = b'PE\0\0'
    struct.pack_into('<HHIIIHH', image, 132, 0x5064, len(segments), 0, 0, 0, 240, 0x22)
    opt = 152
    struct.pack_into('<H', image, opt, 0x20B)
    code_size = sum(align(len(s['data']),512) for s in segments if s['flags'] & 1)
    data_size = sum(align(len(s['data']),512) for s in segments if not s['flags'] & 1)
    code_rva = next(s['rva'] for s in segments if s['flags'] & 1)
    struct.pack_into('<IIIII', image, opt+4, code_size, data_size, 0, entry, code_rva)
    struct.pack_into('<QII', image, opt+24, 0, 4096, 512)
    struct.pack_into('<HH', image, opt+48, 2, 0)
    image_size = align(max(s['rva'] + s['size'] for s in segments), 4096)
    struct.pack_into('<II', image, opt+56, image_size, header_size)
    struct.pack_into('<HH', image, opt+68, 10, 0x140)
    struct.pack_into('<QQQQII', image, opt+72, 0x100000, 4096, 0x100000, 4096, 0, 16)
    if reloc_data:
        struct.pack_into('<II', image, opt+112+5*8, reloc_rva, len(reloc_data))
    for index, segment in enumerate(segments):
        raw_size = align(len(segment['data']), 512)
        raw_offset = len(image) if raw_size else 0
        name = b'.reloc' if segment.get('reloc') else ('.seg' + str(index)).encode()
        characteristics = (0x20 if segment['flags'] & 1 else 0x40)
        if segment['flags'] & 1: characteristics |= 0x20000000
        if segment['flags'] & 4: characteristics |= 0x40000000
        if segment['flags'] & 2: characteristics |= 0x80000000
        struct.pack_into('<8sIIIIIIHHI', image, opt+240+index*40, name, segment['size'], segment['rva'], raw_size,
                         raw_offset, 0, 0, 0, 0, characteristics)
        image += segment['data']
        image += bytes(raw_size - len(segment['data']))
    require(len(image) <= MAX_SIZE, 'PE output size')
    return image

def main():
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    parser.add_argument('elf', type=Path)
    parser.add_argument('efi', type=Path)
    args = parser.parse_args()
    spec = importlib.util.spec_from_file_location('image_paths', Path(__file__).with_name('make-uefi-image.py'))
    paths = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(paths)
    try:
        paths.ordinary_path(args.elf)
        paths.ordinary_path(args.efi, output=True)
        require(args.elf.resolve() != args.efi.resolve(), 'input and output must differ')
        with args.elf.open('rb') as source:
            result = convert(source.read(MAX_SIZE + 1))
        # Host build cache provides a private output path. Atomic ordinary-file
        # replacement uses the same path checks as the image packager.
        import os
        import tempfile
        temporary = None
        try:
            with tempfile.NamedTemporaryFile(dir=args.efi.parent, prefix=args.efi.name+'.', suffix='.tmp', delete=False) as output:
                temporary = Path(output.name)
                output.write(result)
                output.flush()
                os.fsync(output.fileno())
            os.replace(temporary, args.efi)
            temporary = None
        finally:
            if temporary is not None: temporary.unlink(missing_ok=True)
    except (OSError, ValueError) as error:
        print('ELF-to-EFI failed: ' + str(error), file=sys.stderr)
        return 1
    print(f'Created RV64 UEFI PE32+: {len(result)} bytes')
    return 0

if __name__ == '__main__':
    sys.exit(main())
