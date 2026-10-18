#!/usr/bin/env python3
"""Exercise native Python argument quoting through Windows PowerShell 5.1."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
POWERSHELL = shutil.which("powershell.exe")


@unittest.skipUnless(os.name == "nt" and POWERSHELL, "requires Windows PowerShell 5.1")
class LauncherTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="bedrock launch quote ")
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.esp = self.directory / "boot esp"
        boot = self.esp / "EFI/BOOT/BOOTX64.EFI"
        boot.parent.mkdir(parents=True)
        boot.write_bytes(b"owned boot fixture")
        self.code, self.variables = self.directory / "code firmware.fd", self.directory / "vars firmware.fd"
        self.code.write_bytes(b"owned code fixture")
        self.variables.write_bytes(b"owned vars fixture")
        self.invocation = self.directory / "qemu invocation.txt"
        self.qemu = self.directory / "fake qemu.ps1"
        self.qemu.write_text("[IO.File]::WriteAllText($env:BEDROCK_LAUNCH_TEST_CAPTURE, ($args -join [Environment]::NewLine))\n$global:LASTEXITCODE = 0\n")

    def launch(self, data):
        environment = dict(os.environ, BEDROCK_LAUNCH_TEST_CAPTURE=str(self.invocation))
        result = subprocess.run([POWERSHELL, "-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
            str(ROOT / "tools/run-uefi.ps1"), "-QemuExecutable", str(self.qemu),
            "-EspDirectory", str(self.esp), "-UefiCode", str(self.code), "-UefiVars", str(self.variables),
            "-RamMiB", "256", "-Architecture", "x86_64", "-DataImage", str(data)],
            env=environment, capture_output=True, text=True, timeout=30)
        return result

    def test_existing_image_with_spaces_reaches_qemu_without_modification(self):
        data = self.directory / "existing data.img"
        original = b"existing media must never be formatted"
        data.write_bytes(original)
        result = self.launch(data)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(data.read_bytes(), original)
        invocation = self.invocation.read_text()
        self.assertIn("file=" + str(data), invocation)
        self.assertIn("virtio-keyboard-pci", invocation)

    def test_missing_image_with_spaces_is_created_before_qemu(self):
        data = self.directory / "new data.img"
        result = self.launch(data)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(data.stat().st_size, 4 * 1024 * 1024)
        self.assertEqual(data.read_bytes()[:8], b"BEDFS001")
        self.assertTrue(self.invocation.is_file())

    def test_directory_is_rejected_before_qemu(self):
        result = self.launch(self.directory)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.invocation.exists())
        self.assertIn("ordinary file", result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
