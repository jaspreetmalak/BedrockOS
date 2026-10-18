#!/usr/bin/env python3
"""Run Bedrock's native installer or installed OS against an ordinary virtual disk."""
import argparse
import importlib.util
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('bedrock_image_paths', ROOT / 'make-uefi-image.py')
paths = importlib.util.module_from_spec(spec)
spec.loader.exec_module(paths)

def drive(path):
    return str(path.resolve()).replace(',', ',,')

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--arch', required=True, choices=('x86_64', 'arm64', 'riscv64'))
    parser.add_argument('--image', required=True, type=Path)
    parser.add_argument('--target', required=True, type=Path)
    parser.add_argument('--qemu', required=True)
    parser.add_argument('--code', required=True, type=Path)
    parser.add_argument('--vars', required=True, type=Path)
    parser.add_argument('--boot-installed', action='store_true')
    args = parser.parse_args()
    try:
        for path in (args.image, args.code, args.vars):
            paths.ordinary_path(path)
        paths.validate_path_syntax(str(args.target))
        args.target.parent.mkdir(parents=True, exist_ok=True)
        paths.ordinary_path(args.target, output=True)
        if args.target.is_symlink() or any(paths.same_path(args.target, path) for path in (args.image, args.code, args.vars)):
            raise ValueError('the virtual target must differ from installer and firmware inputs')
        if args.boot_installed and not args.target.exists():
            raise ValueError('install Bedrock to this virtual target first')
        if not args.target.exists():
            with args.target.open('xb') as output:
                output.truncate(80 * 1024 * 1024)
                output.flush()
                os.fsync(output.fileno())
        if args.target.stat().st_size < 139297 * 512 or args.target.stat().st_size % 512:
            raise ValueError('the virtual target must contain at least 139297 whole sectors')
        x86, arm = args.arch == 'x86_64', args.arch == 'arm64'
        machine = 'pc-q35-10.1' if x86 else 'virt-10.1,secure=off,virtualization=off,acpi=off' if arm else 'virt,acpi=off'
        cpu = 'qemu64' if x86 else 'cortex-a57' if arm else 'rv64'
        command = [args.qemu, '-machine', machine, '-cpu', cpu, '-accel', 'tcg', '-smp', '1', '-m', '256M',
                   '-serial', 'stdio', '-monitor', 'none', '-no-reboot', '-nic', 'none',
                   '-drive', f'if=pflash,format=raw,readonly=on,file={drive(args.code)}',
                   '-drive', f'if=pflash,format=raw,snapshot=on,file={drive(args.vars)}']
        bus = 'virtio-blk-pci' if x86 else 'virtio-blk-device'
        modern = ',disable-legacy=on' if x86 else ''
        if not x86:
            command += ['-global', 'virtio-mmio.force-legacy=false', '-device', 'ramfb']
            command += ['-semihosting-config', 'enable=on,target=native'] if arm else ['-bios', 'default']
        if not args.boot_installed:
            command += ['-drive', f'if=none,id=source,format=raw,readonly=on,file={drive(args.image)}',
                        '-device', f'{bus},drive=source,bootindex=1{modern}',
                        '-device', 'qemu-xhci', '-device', 'usb-kbd', '-device', 'usb-tablet']
        else:
            input_bus = 'pci' if x86 else 'device'
            command += ['-device', f'virtio-keyboard-{input_bus}{modern}', '-device', f'virtio-tablet-{input_bus}{modern}']
        command += ['-drive', f'if=none,id=target,format=raw,file={drive(args.target)}',
                    '-device', f'{bus},drive=target,serial=bedrock-installed,bootindex={1 if args.boot_installed else 2}{modern}']
        print(f'Virtual target: {args.target.resolve()}', flush=True)
        return subprocess.call(command)
    except (OSError, ValueError) as error:
        print(f'Bedrock virtual installer: {error}', file=sys.stderr)
        return 1
if __name__ == '__main__':
    sys.exit(main())
