#!/usr/bin/env python3
# SPDX-License-Identifier: ISC
# Copyright (C) 2026 Bedrock contributors
"""Driver selection/publication tests with synthetic module bytes; no hardware access."""

import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import struct
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock


spec = importlib.util.spec_from_file_location('package_drivers', Path(__file__).with_name('package-drivers.py'))
packager = importlib.util.module_from_spec(spec)
spec.loader.exec_module(packager)
describe_spec = importlib.util.spec_from_file_location('describe_driver_package', Path(__file__).with_name('describe-driver-package.py'))
descriptor = importlib.util.module_from_spec(describe_spec)
describe_spec.loader.exec_module(descriptor)
build_stage_spec = importlib.util.spec_from_file_location('stage_driver_build', Path(__file__).with_name('stage-driver-build.py'))
build_stage = importlib.util.module_from_spec(build_stage_spec)
build_stage_spec.loader.exec_module(build_stage)


def catalogue():
    return packager.read_json(packager.DEFAULT_CATALOGUE)


def inventory(*identities):
    return {'schema_version': 1, 'devices': [{'vendor': vendor, 'device': product} for vendor, product in identities]}


def synthetic_module(architecture='x86_64'):
    """An ELF-shaped data fixture, never an executable test payload."""
    machine = packager.ARCHITECTURES[architecture]
    data = bytearray(0x2020)
    struct.pack_into('<16sHHIQQQIHHHHHH', data, 0,
                     b'\x7fELF\x02\x01\x01' + bytes(9), 3, machine, 1,
                     0x1000, 64, 0, 0, 64, 56, 4, 0, 0, 0)
    segments = ((1, 4, 0, 0, 0, 0x400, 0x400, 4096),
                (1, 5, 0x1000, 0x1000, 0, 64, 64, 4096),
                (1, 6, 0x2000, 0x2000, 0, 32, 4096, 4096),
                (4, 4, 0x180, 0x180, 0, 84 * 3, 84 * 3, 4))
    for index, header in enumerate(segments):
        struct.pack_into('<IIQQQQQQ', data, 64 + index * 56, *header)
    for index, (vendor, device) in enumerate(((0x14c3, 0x7922), (0x14c3, 0x0616), (0x0b48, 0x7922))):
        offset = 0x180 + index * 84
        struct.pack_into('<III8s8sIHHIIHHHHHHI24s', data, offset,
                         8, 64, packager.NOTE_TYPE, packager.NOTE_NAME, packager.NOTE_MAGIC,
                         64, 1, 0, 1, 1, vendor, device, 0xffff, 0xffff, machine, 0, 3,
                         b'org.bedrock.mt7922' + bytes(6))
    return bytes(data)


def write_package(root, data=None, architecture='x86_64'):
    data = synthetic_module(architecture) if data is None else data
    path = root / architecture / 'mt7922'
    path.mkdir(parents=True)
    metadata = {'schema_version': 1, 'id': 'org.bedrock.mt7922',
                'package_version': '0.1.0', 'architecture': architecture,
                'driver_abi': {'major': 1, 'minor': 0},
                'module': {'file': 'mt7922.bdm', 'byte_length': len(data),
                           'sha256': hashlib.sha256(data).hexdigest()}}
    (path / 'package.json').write_bytes(packager.json_bytes(metadata))
    (path / 'mt7922.bdm').write_bytes(data)
    return path, metadata


class SelectionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.base = Path(self.temp.name)
        self.modules = self.base / 'modules'
        self.modules.mkdir()
        self.catalogue = catalogue()

    def tearDown(self):
        self.temp.cleanup()

    def select(self, devices, architecture='x86_64', offline=False):
        return packager.select_packages(self.catalogue, devices, architecture, self.modules, offline)

    def test_exact_matching_stages_one_package_for_multiple_cards(self):
        source, metadata = write_package(self.modules)
        document = inventory(('14c3', '7922'), (0x14c3, 0x0616), ('0b48', '7922'))
        output = self.base / 'selected'
        receipt = packager.stage_packages(self.catalogue, document, 'x86_64', self.modules, output)
        self.assertEqual([device['status'] for device in receipt['devices']], ['package-staged'] * 3)
        self.assertEqual(len(receipt['selected']), 1)
        self.assertFalse(receipt['physical_radio_verified'])
        self.assertEqual(receipt['boot_essentials']['delivery'], 'built-in')
        target = output / 'EFI' / 'Bedrock' / 'Drivers'
        self.assertEqual((target / 'mt7922.bdm').read_bytes(), synthetic_module())
        manifest = json.loads((target / 'manifest.json').read_text())
        self.assertEqual(manifest['packages'], [metadata])
        self.assertEqual(sorted(str(file.relative_to(output)).replace('\\', '/') for file in output.rglob('*') if file.is_file()),
                         ['EFI/Bedrock/Drivers/manifest.json', 'EFI/Bedrock/Drivers/mt7922.bdm', 'driver-selection.json'])

    def test_missing_package_and_missing_module_are_explicit(self):
        _, receipt, loaded = self.select(inventory(('14c3', '0616')))
        self.assertEqual(receipt['devices'][0]['status'], 'module-unavailable')
        self.assertEqual(receipt['unavailable_modules'], ['org.bedrock.mt7922'])
        self.assertFalse(loaded)
        path, _ = write_package(self.modules)
        (path / 'mt7922.bdm').unlink()
        _, receipt, loaded = self.select(inventory(('14c3', '0616')))
        self.assertEqual(receipt['devices'][0]['status'], 'module-unavailable')
        self.assertFalse(loaded)

    def test_vendor_only_does_not_match_or_inspect_unneeded_module(self):
        path, _ = write_package(self.modules)
        (path / 'package.json').write_text('{bad-json')
        _, receipt, loaded = self.select(inventory(('14c3', '1234'), ('8086', '0616'), ('0b48', '0616')))
        self.assertEqual([device['status'] for device in receipt['devices']], ['no-hardware-match'] * 3)
        self.assertFalse(loaded)

    def test_known_family_members_are_unimplemented(self):
        _, receipt, loaded = self.select(inventory(('14c3', '7961'), ('14c3', '0608'), ('14c3', '7920')))
        self.assertEqual([device['status'] for device in receipt['devices']], ['driver-unimplemented'] * 3)
        self.assertFalse(loaded)

    def test_other_architectures_do_not_claim_hardware_support(self):
        for architecture in ('aarch64', 'riscv64'):
            with self.subTest(architecture=architecture):
                _, receipt, loaded = self.select(inventory(('14c3', '0616')), architecture, True)
                self.assertEqual(receipt['devices'][0]['status'], 'platform-unsupported')
                self.assertFalse(loaded)
                self.assertEqual(receipt['unavailable_modules'], [])
        with self.assertRaises(ValueError):
            self.select(inventory(), 'arm64')

    def test_offline_fallback_includes_only_available_target_compatible_package(self):
        write_package(self.modules)
        _, receipt, loaded = self.select(inventory(('8086', '1234')), offline=True)
        self.assertEqual(receipt['policy'], 'all-compatible')
        self.assertEqual(receipt['devices'][0]['status'], 'no-hardware-match')
        self.assertEqual(receipt['selected'][0]['reason'], 'offline-fallback')
        self.assertEqual(list(loaded), ['org.bedrock.mt7922'])

    def test_abi_hash_length_arch_and_package_version_are_not_trusted(self):
        path, metadata = write_package(self.modules)
        for route, replacement in ((('driver_abi', 'major'), 2), (('module', 'sha256'), '0' * 64),
                                   (('module', 'byte_length'), len(synthetic_module()) + 1),
                                   (('architecture',), 'riscv64'), (('package_version',), '9.0.0'),
                                   (('module', 'file'), '../other.bdm'), (('module', 'sha256'), 'A' * 64)):
            document = copy.deepcopy(metadata)
            parent = document
            for part in route[:-1]:
                parent = parent[part]
            parent[route[-1]] = replacement
            (path / 'package.json').write_bytes(packager.json_bytes(document))
            with self.subTest(route=route), self.assertRaises(ValueError):
                self.select(inventory(('14c3', '0616')))

    def test_invalid_selected_package_never_publishes_partial_output(self):
        path, metadata = write_package(self.modules)
        metadata['module']['sha256'] = '0' * 64
        (path / 'package.json').write_bytes(packager.json_bytes(metadata))
        output = self.base / 'selected'
        with self.assertRaises(ValueError):
            packager.stage_packages(self.catalogue, inventory(('14c3', '0616')), 'x86_64', self.modules, output)
        self.assertFalse(output.exists())
        self.assertFalse(list(self.base.glob('.bedrock-drivers-*')))

    def test_existing_output_is_preserved(self):
        write_package(self.modules)
        output = self.base / 'selected'
        output.mkdir()
        (output / 'keep.txt').write_text('original')
        with self.assertRaises(FileExistsError):
            packager.stage_packages(self.catalogue, inventory(('14c3', '0616')), 'x86_64', self.modules, output)
        self.assertEqual((output / 'keep.txt').read_text(), 'original')
        self.assertEqual([file.name for file in output.iterdir()], ['keep.txt'])

    def test_publication_race_preserves_another_publishers_directory(self):
        write_package(self.modules)
        output = self.base / 'selected'
        original = packager.atomic_directory_publish

        def raced(staging, destination):
            destination.mkdir()
            (destination / 'keep.txt').write_text('other publisher')
            return original(staging, destination)

        with mock.patch.object(packager, 'atomic_directory_publish', side_effect=raced), self.assertRaises(OSError):
            packager.stage_packages(self.catalogue, inventory(('14c3', '0616')), 'x86_64', self.modules, output)
        self.assertEqual((output / 'keep.txt').read_text(), 'other publisher')
        self.assertFalse(list(self.base.glob('.bedrock-drivers-*')))

    def test_cli_consumes_explicit_inventory_and_returns_inspectable_receipt(self):
        write_package(self.modules)
        source = self.base / 'inventory.json'
        source.write_bytes(packager.json_bytes(inventory(('14c3', '0616'))))
        output = self.base / 'selected'
        with mock.patch('builtins.print'):
            result = packager.main(['--inventory', str(source), '--arch', 'x86_64',
                                    '--modules', str(self.modules), '--output', str(output)])
        self.assertEqual(result, 0)
        self.assertEqual(json.loads((output / 'driver-selection.json').read_text())['selected'][0]['id'], 'org.bedrock.mt7922')

    def test_cli_offline_selection_requires_no_inventory_and_never_queries_host(self):
        write_package(self.modules)
        output = self.base / 'offline'
        with mock.patch('builtins.print'), mock.patch.object(packager, 'windows_inventory', side_effect=AssertionError('unexpected host query')):
            result = packager.main(['--arch', 'x86_64', '--modules', str(self.modules),
                                    '--output', str(output), '--all-compatible'])
        self.assertEqual(result, 0)
        receipt = json.loads((output / 'driver-selection.json').read_text())
        self.assertEqual(receipt['devices'], [])
        self.assertEqual(receipt['selected'][0]['reason'], 'offline-fallback')


class ValidationTests(unittest.TestCase):
    def setUp(self):
        self.package = catalogue()['packages'][0]

    def test_synthetic_module_declares_exact_three_aliases(self):
        for architecture in packager.ARCHITECTURES:
            result = packager.validate_module(synthetic_module(architecture), architecture, self.package)
            self.assertEqual(len(result), 3)
            self.assertEqual(struct.unpack_from('<HH', result[1], 24), (0x14c3, 0x0616))

    def test_load_alignment_accepts_large_target_page_alignment(self):
        for architecture in packager.ARCHITECTURES:
            for alignment in (4096, 65536, packager.MAX_IMAGE_BYTES):
                data = bytearray(synthetic_module(architecture))
                for index in range(3):
                    struct.pack_into('<Q', data, 64 + index * 56 + 48, alignment)
                with self.subTest(architecture=architecture, alignment=alignment):
                    self.assertEqual(len(packager.validate_module(data, architecture, self.package)), 3)

    def test_load_alignment_rejects_too_small_non_power_of_two_and_mismatched_pages(self):
        for alignment in (0, 1, 2048, 4095, 8191, packager.MAX_IMAGE_BYTES * 2):
            data = bytearray(synthetic_module())
            struct.pack_into('<Q', data, 64 + 48, alignment)
            with self.subTest(alignment=alignment), self.assertRaises(ValueError):
                packager.validate_module(data, 'x86_64', self.package)
        data = bytearray(synthetic_module())
        struct.pack_into('<Q', data, 64 + 56 + 48, 65536)
        struct.pack_into('<Q', data, 64 + 56 + 8, 0x2000)
        with self.assertRaises(ValueError):
            packager.validate_module(data, 'x86_64', self.package)
        # Congruent file/virtual offsets alone do not establish page separation.
        data = bytearray(synthetic_module())
        struct.pack_into('<Q', data, 64 + 56 + 8, 0x1001)
        struct.pack_into('<Q', data, 64 + 56 + 16, 0x1001)
        with self.assertRaises(ValueError):
            packager.validate_module(data, 'x86_64', self.package)

    def test_malformed_elf_layout_rejects_before_execution(self):
        mutations = ((18, '<H', 243), (16, '<H', 2), (24, '<Q', 0x2000), (54, '<H', 1),
                     (64 + 4, '<I', 7), (64 + 32, '<Q', 0xffffffffffffffff),
                     (64 + 56 + 16, '<Q', 0), (64 + 56 + 40, '<Q', packager.MAX_IMAGE_BYTES),
                     (64 + 3 * 56 + 8, '<Q', 0xffffffffffffffff), (0x180 + 4, '<I', 0xffffffff))
        for offset, format_string, value in mutations:
            data = bytearray(synthetic_module())
            struct.pack_into(format_string, data, offset, value)
            with self.subTest(offset=offset, value=value), self.assertRaises(ValueError):
                packager.validate_module(data, 'x86_64', self.package)

    def test_note_metadata_identity_integrity_and_readonly_placement_reject(self):
        mutations = ((0x180 + 20, '<8s', b'WRONGABI'), (0x180 + 20 + 8, '<I', 63),
                     (0x180 + 20 + 12, '<H', 2), (0x180 + 20 + 16, '<I', 2),
                     (0x180 + 20 + 20, '<I', 0), (0x180 + 20 + 24, '<H', 0x8086),
                     (0x180 + 20 + 32, '<H', 243), (0x180 + 20 + 34, '<H', 1),
                     (0x180 + 20 + 36, '<I', 4), (0x180 + 20 + 40, '<B', ord('x')),
                     (64 + 4, '<I', 5), (0x180 + 84 + 20 + 20, '<I', 2),
                     (0x180 + 84 + 20 + 26, '<H', 0x7922))
        for offset, format_string, value in mutations:
            data = bytearray(synthetic_module())
            struct.pack_into(format_string, data, offset, value)
            with self.subTest(offset=offset, value=value), self.assertRaises(ValueError):
                packager.validate_module(data, 'x86_64', self.package)

    def test_json_schema_aliases_booleans_and_duplicates_reject(self):
        for source in ({'schema_version': True, 'devices': []},
                       {'schema_version': 1, 'devices': [{'vendor': True, 'device': 0x0616}]},
                       {'schema_version': 1, 'devices': [{'vendor': '14c3', 'device': '*'}]},
                       {'schema_version': 1, 'devices': [{'vendor': '14c3', 'device': '0616', 'subsystem_vendor': '1028'}]},
                       {'schema_version': 1, 'devices': [{'vendor': '14c3', 'device': '0616', 'location': '1'},
                                                       {'vendor': '14c3', 'device': '0616', 'location': '1'}]},
                       {'schema_version': 1, 'devices': [], 'vendor_wildcard': True}):
            with self.subTest(source=source), self.assertRaises(ValueError):
                packager.validate_inventory(source)
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'duplicate.json'
            path.write_text('{"schema_version":1,"schema_version":2,"devices":[]}')
            with self.assertRaises(ValueError):
                packager.read_json(path)

    def test_catalogue_ambiguous_matches_and_case_collisions_reject(self):
        for mode in ('match', 'id', 'directory', 'module'):
            document = catalogue()
            extra = copy.deepcopy(document['packages'][0])
            extra.update(id='org.bedrock.other', directory='other', module='other.bdm',
                         pci_matches=[{'vendor': '1234', 'device': '5678'}])
            if mode == 'match':
                extra['pci_matches'] = copy.deepcopy(document['packages'][0]['pci_matches'])
            elif mode == 'id':
                extra['id'] = document['packages'][0]['id']
            else:
                extra[mode] = document['packages'][0][mode].upper()
            document['packages'].append(extra)
            with self.subTest(mode=mode), self.assertRaises(ValueError):
                packager.validate_catalogue(document)

    def test_device_paths_and_unsafe_names_reject(self):
        for source in ('NUL', 'nul.txt', 'COM1', 'x/y.bdm', '..', 'x:stream', 'module.bdm '):
            with self.subTest(source=source), self.assertRaises(ValueError):
                packager.safe_name(source, 'module')
        for source in (r'\\.\PhysicalDrive0', r'\\server\share\module.bdm', r'C:\output\NUL',
                       r'C:\output\file:stream', r'C:\output\name. '):
            with self.subTest(source=source), self.assertRaises(ValueError):
                packager.check_ordinary_path(source)

    def test_input_symlink_and_oversized_json_reject(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            target = root / 'inventory.json'
            target.write_text('{}')
            link = root / 'link.json'
            try:
                link.symlink_to(target)
            except (OSError, NotImplementedError):
                pass
            else:
                with self.assertRaises(ValueError):
                    packager.read_json(link)
            target.write_bytes(b' ' * (packager.MAX_JSON_BYTES + 1))
            with self.assertRaises(ValueError):
                packager.read_json(target)

    @unittest.skipUnless(os.name == 'nt', 'fixed Windows CIM inventory path')
    def test_windows_inventory_extracts_pci_subsystem_and_revision_without_mutation(self):
        response = [
            {'id': r'PCI\VEN_14C3&DEV_0616&SUBSYS_12341028&REV_01\3&ABC',
             'hardware_ids': [r'PCI\VEN_14C3&DEV_0616&SUBSYS_12341028&REV_01',
                              r'PCI\VEN_14C3&DEV_0616']},
            {'id': r'PCI\VEN_8086&DEV_5678\3&DEF',
             'hardware_ids': [r'PCI\VEN_8086&DEV_5678']}
        ]
        run = SimpleNamespace(returncode=0, stdout=json.dumps(response).encode('utf-8'))
        with mock.patch.object(packager.subprocess, 'run', return_value=run) as command:
            result = packager.windows_inventory()
        self.assertEqual(result['devices'][0]['vendor'], '14c3')
        self.assertEqual(result['devices'][0]['device'], '0616')
        self.assertEqual(result['devices'][0]['subsystem_vendor'], '1028')
        self.assertEqual(result['devices'][0]['subsystem_device'], '1234')
        self.assertEqual(result['devices'][0]['revision'], 1)
        self.assertEqual(result['devices'][1]['device'], '5678')
        args, options = command.call_args
        self.assertEqual(args[0][:5], ['powershell.exe', '-NoLogo', '-NoProfile', '-NonInteractive', '-Command'])
        self.assertIn('Get-CimInstance', args[0][5])
        self.assertNotIn('Set-', args[0][5])
        self.assertEqual(options['timeout'], 30)

    @unittest.skipUnless(os.name == 'nt', 'fixed Windows CIM inventory path')
    def test_windows_inventory_failure_does_not_substitute_guessed_hardware(self):
        for response in (SimpleNamespace(returncode=1, stdout=b''),
                         SimpleNamespace(returncode=0, stdout=b'not-json'),
                         SimpleNamespace(returncode=0, stdout=json.dumps(
                             [{'id': r'PCI\VEN_14C3&DEV_0616', 'hardware_ids': 'wrong-type'}]).encode('utf-8'))):
            with self.subTest(response=response), mock.patch.object(packager.subprocess, 'run', return_value=response), self.assertRaises(ValueError):
                packager.windows_inventory()


class DescriptionTests(unittest.TestCase):
    def test_description_builds_all_arch_packages_without_claiming_native_support(self):
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp)
            output = base / 'described'
            output.mkdir()  # Models Zig Run's pre-created output directory.
            for architecture in packager.ARCHITECTURES:
                source = base / (architecture + '.elf')
                source.write_bytes(synthetic_module(architecture))
                metadata = descriptor.describe_package(source, output, architecture)
                package = output / architecture / 'mt7922'
                self.assertEqual((package / 'mt7922.bdm').read_bytes(), source.read_bytes())
                self.assertEqual(json.loads((package / 'package.json').read_text()), metadata)
                self.assertEqual(metadata['module']['sha256'], hashlib.sha256(source.read_bytes()).hexdigest())
                manifest, receipt, loaded = packager.select_packages(catalogue(), inventory(('14c3', '0616')), architecture, output)
                self.assertEqual(receipt['devices'][0]['status'],
                                 'package-staged' if architecture == 'x86_64' else 'platform-unsupported')

    def test_invalid_compiled_input_has_no_output_side_effects(self):
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp)
            source = base / 'wrong.elf'
            source.write_bytes(synthetic_module('riscv64'))
            output = base / 'described'
            with self.assertRaises(ValueError):
                descriptor.describe_package(source, output, 'x86_64')
            self.assertFalse(output.exists())

    def test_existing_package_is_never_overwritten(self):
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp)
            source = base / 'module.elf'
            source.write_bytes(synthetic_module())
            output = base / 'described'
            descriptor.describe_package(source, output, 'x86_64')
            original = (output / 'x86_64' / 'mt7922' / 'package.json').read_bytes()
            with self.assertRaises(FileExistsError):
                descriptor.describe_package(source, output, 'x86_64')
            self.assertEqual((output / 'x86_64' / 'mt7922' / 'package.json').read_bytes(), original)
            self.assertFalse(list((output / 'x86_64').glob('.bedrock-package-*')))


class BuildAdapterTests(unittest.TestCase):
    def test_precreated_empty_build_root_gets_complete_new_selected_child(self):
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp)
            modules = base / 'modules'
            modules.mkdir()
            write_package(modules)
            output_root = base / 'managed-output'
            output_root.mkdir()
            with mock.patch('builtins.print'):
                result = build_stage.main(['--arch', 'x86_64', '--modules', str(modules),
                                           '--output-root', str(output_root), '--all-compatible'])
            self.assertEqual(result, 0)
            self.assertEqual([path.name for path in output_root.iterdir()], ['selected'])
            selected = output_root / 'selected'
            self.assertEqual((selected / 'EFI/Bedrock/Drivers/mt7922.bdm').read_bytes(), synthetic_module())
            self.assertEqual(json.loads((selected / 'driver-selection.json').read_text())['selected'][0]['reason'], 'offline-fallback')
            with self.assertRaises(FileExistsError):
                build_stage.stage_build_tree(catalogue(), modules, 'x86_64', output_root, True)

    def test_occupied_build_root_is_preserved_and_never_published_into(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / 'keep.txt').write_text('original')
            with self.assertRaises(FileExistsError):
                build_stage.stage_build_tree(catalogue(), root, 'x86_64', root, True)
            self.assertEqual((root / 'keep.txt').read_text(), 'original')
            self.assertFalse((root / 'selected').exists())

    def test_public_stager_still_rejects_precreated_empty_destination(self):
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp)
            output = base / 'public-output'
            output.mkdir()
            with self.assertRaises(FileExistsError):
                packager.stage_packages(catalogue(), inventory(), 'x86_64', base, output, True)
            self.assertEqual(list(output.iterdir()), [])


class WindowsPublicationTests(unittest.TestCase):
    @staticmethod
    def failure(code):
        error = OSError(13, 'mocked Windows rename failure')
        error.winerror = code
        return error

    def test_only_transient_codes_retry_unchanged_owned_source_then_publish(self):
        for code in (5, 32, 33):
            with self.subTest(code=code), tempfile.TemporaryDirectory() as temp:
                base = Path(temp)
                source, output = base / '.bedrock-drivers-owned', base / 'selected'
                source.mkdir()
                (source / 'keep.txt').write_text('complete')
                rename = packager.os.rename
                failures = [self.failure(code), self.failure(code)]

                def retry(staging, destination):
                    if failures:
                        raise failures.pop()
                    return rename(staging, destination)

                with mock.patch.object(packager.os, 'rename', side_effect=retry) as calls, \
                        mock.patch.object(packager.time, 'sleep') as sleeps, \
                        mock.patch.object(packager.time, 'monotonic', return_value=0):
                    packager.windows_directory_publish(source, output)
                self.assertEqual(calls.call_count, 3)
                self.assertEqual(sleeps.call_args_list, [mock.call(0.05), mock.call(0.1)])
                self.assertEqual((output / 'keep.txt').read_text(), 'complete')
                self.assertFalse(source.exists())

    def test_retry_limit_and_deadline_stop_without_overwriting(self):
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp)
            source, output = base / '.bedrock-drivers-owned', base / 'selected'
            source.mkdir()
            with mock.patch.object(packager.os, 'rename', side_effect=self.failure(5)) as calls, \
                    mock.patch.object(packager.time, 'sleep') as sleeps, \
                    mock.patch.object(packager.time, 'monotonic', return_value=0), self.assertRaises(OSError):
                packager.windows_directory_publish(source, output)
            self.assertEqual(calls.call_count, 5)
            self.assertEqual(sleeps.call_args_list, [mock.call(0.05), mock.call(0.1), mock.call(0.2), mock.call(0.2)])
            self.assertLessEqual(sum(call.args[0] for call in sleeps.call_args_list), 1)
            self.assertFalse(output.exists())
            with mock.patch.object(packager.os, 'rename', side_effect=self.failure(5)) as calls, \
                    mock.patch.object(packager.time, 'sleep') as sleeps, \
                    mock.patch.object(packager.time, 'monotonic', side_effect=[0, 2]), self.assertRaises(OSError):
                packager.windows_directory_publish(source, output)
            self.assertEqual(calls.call_count, 1)
            sleeps.assert_not_called()

    def test_nontransient_failure_never_retries(self):
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp)
            source, output = base / '.bedrock-drivers-owned', base / 'selected'
            source.mkdir()
            with mock.patch.object(packager.os, 'rename', side_effect=self.failure(87)) as calls, \
                    mock.patch.object(packager.time, 'sleep') as sleeps, self.assertRaises(OSError):
                packager.windows_directory_publish(source, output)
            self.assertEqual(calls.call_count, 1)
            sleeps.assert_not_called()

    def test_competing_publisher_is_preserved_without_wait_or_retry(self):
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp)
            source, output = base / '.bedrock-drivers-owned', base / 'selected'
            source.mkdir()

            def publish_other(staging, destination):
                destination.mkdir()
                (destination / 'keep.txt').write_text('other publisher')
                raise self.failure(5)

            with mock.patch.object(packager.os, 'rename', side_effect=publish_other) as calls, \
                    mock.patch.object(packager.time, 'sleep') as sleeps, self.assertRaises(FileExistsError):
                packager.windows_directory_publish(source, output)
            self.assertEqual(calls.call_count, 1)
            sleeps.assert_not_called()
            self.assertEqual((output / 'keep.txt').read_text(), 'other publisher')

    def test_source_identity_change_never_retries(self):
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp)
            source, output = base / '.bedrock-drivers-owned', base / 'selected'
            source.mkdir()
            rename = packager.os.rename

            def replace_source(staging, destination):
                rename(staging, base / 'retained-original')
                staging.mkdir()
                raise self.failure(32)

            with mock.patch.object(packager.os, 'rename', side_effect=replace_source) as calls, \
                    mock.patch.object(packager.time, 'sleep') as sleeps, self.assertRaises(ValueError):
                packager.windows_directory_publish(source, output)
            self.assertEqual(calls.call_count, 1)
            sleeps.assert_not_called()
            self.assertFalse(output.exists())


if __name__ == '__main__':
    unittest.main()
