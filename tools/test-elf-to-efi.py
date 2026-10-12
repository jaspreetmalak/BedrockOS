#!/usr/bin/env python3
"""Check RV64 PE serialization and malformed ELF rejection without device I/O."""
import importlib.util
from pathlib import Path
import struct
import unittest

spec = importlib.util.spec_from_file_location('elf_to_efi', Path(__file__).with_name('elf-to-efi.py'))
converter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(converter)

def fixture():
    data = bytearray(0x2200)
    data[:7] = b'\x7fELF\x02\x01\x01'
    struct.pack_into('<HHIQQ', data, 16, 3, 243, 1, 0x1010, 64)
    struct.pack_into('<IHHH', data, 48, 1, 64, 56, 3)
    struct.pack_into('<IIQQQQQQ', data, 64, 1, 5, 0x1000, 0x1000, 0x1000, 0x100, 0x100, 4096)
    struct.pack_into('<IIQQQQQQ', data, 120, 1, 6, 0x2000, 0x2000, 0x2000, 0x200, 0x400, 4096)
    struct.pack_into('<IIQQQQQQ', data, 176, 2, 6, 0x2100, 0x2100, 0x2100, 64, 64, 8)
    struct.pack_into('<QQQQQQ', data, 0x2100, 7, 0x2080, 8, 24, 9, 24)
    struct.pack_into('<QQq', data, 0x2080, 0x2040, 3, 0x1010)
    return data

class ConversionTests(unittest.TestCase):
    def test_pe_headers_sections_and_firmware_base_relocation(self):
        image = converter.convert(fixture())
        pe, = struct.unpack_from('<I', image, 60)
        self.assertEqual(image[pe:pe+4], b'PE\0\0')
        machine, count = struct.unpack_from('<HH', image, pe+4)
        self.assertEqual((machine,count),(0x5064,3))
        opt = pe+24
        self.assertEqual(struct.unpack_from('<H',image,opt)[0],0x20B)
        self.assertEqual(struct.unpack_from('<I',image,opt+16)[0],0x1010)
        self.assertEqual(struct.unpack_from('<H',image,opt+68)[0],10)
        sections = [struct.unpack_from('<8sIIIIIIHHI',image,opt+240+i*40) for i in range(count)]
        for section in sections:
            self.assertEqual(section[2] % 4096,0)
            self.assertEqual(section[4] % 512,0)
            self.assertLessEqual(section[4]+section[3],len(image))
        data = sections[1]
        pointer = struct.unpack_from('<Q',image,data[4]+0x40)[0]
        self.assertEqual(pointer,0x1010)
        reloc = sections[2]
        self.assertEqual(struct.unpack_from('<IIHH',image,reloc[4]),(0x2000,12,0xA040,0))
        # Independently load serialized sections, zero BSS, and apply the actual
        # PE directory records as firmware does at two nonzero image bases.
        size, headers = struct.unpack_from('<II', image, opt+56)
        directory, length = struct.unpack_from('<II', image, opt+112+5*8)
        for base in (0x80000000, 0x100000000):
            virtual = bytearray(size)
            virtual[:headers] = image[:headers]
            for section in sections:
                virtual[section[2]:section[2]+section[3]] = image[section[4]:section[4]+section[3]]
            cursor = directory
            applied = []
            while cursor < directory+length:
                page, block_size = struct.unpack_from('<II', virtual, cursor)
                self.assertGreaterEqual(block_size, 8)
                self.assertLessEqual(cursor+block_size, directory+length)
                for offset in range(cursor+8, cursor+block_size, 2):
                    record, = struct.unpack_from('<H', virtual, offset)
                    if record == 0: continue
                    self.assertEqual(record >> 12, 10)
                    target = page+(record & 4095)
                    value, = struct.unpack_from('<Q', virtual, target)
                    struct.pack_into('<Q', virtual, target, value+base)
                    applied.append(target)
                cursor += block_size
            self.assertEqual(cursor, directory+length)
            self.assertEqual(applied, [0x2040])
            self.assertEqual(struct.unpack_from('<Q', virtual, 0x2040)[0], base+0x1010)
            self.assertEqual(virtual[0x2200:0x2400], bytes(0x200))
        self.assertEqual(image,converter.convert(fixture()))

    def test_base_of_code_uses_executable_section(self):
        data = fixture()
        # A valid image may place a data segment before executable code.
        struct.pack_into('<I', data, 68, 6)
        struct.pack_into('<I', data, 124, 7)
        struct.pack_into('<Q', data, 24, 0x2050)
        image = converter.convert(data)
        pe, = struct.unpack_from('<I', image, 60)
        self.assertEqual(struct.unpack_from('<I', image, pe+24+20)[0], 0x2000)

    def test_duplicate_relocation_target_rejected(self):
        data = fixture()
        struct.pack_into('<Q', data, 0x2118, 48)
        struct.pack_into('<QQq', data, 0x2098, 0x2040, 3, 0x1010)
        with self.assertRaisesRegex(ValueError, 'unique'):
            converter.convert(data)

    def test_wrong_architecture_and_truncated_file_rejected(self):
        data = fixture()
        struct.pack_into('<H',data,18,62)
        with self.assertRaisesRegex(ValueError,'RV64 PIE'): converter.convert(data)
        with self.assertRaisesRegex(ValueError,'bounds'): converter.convert(fixture()[:0x2100])

    def test_symbol_relocation_escaped_target_and_misalignment_rejected(self):
        for target, info in ((0x2040,0x100000003),(0x2400,3),(0x2041,3)):
            data = fixture()
            struct.pack_into('<QQ',data,0x2080,target,info)
            with self.assertRaises(ValueError): converter.convert(data)

    def test_dynamic_geometry_and_segment_overlap_rejected(self):
        data = fixture()
        struct.pack_into('<Q',data,0x2128,16)
        with self.assertRaisesRegex(ValueError,'RELA geometry'): converter.convert(data)
        data = fixture()
        struct.pack_into('<QQ',data,136,0x1000,0x1000)
        with self.assertRaisesRegex(ValueError,'overlap'): converter.convert(data)

if __name__ == '__main__':
    unittest.main()
