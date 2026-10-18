#!/usr/bin/env python3
"""Install in owned QEMU, validate GPT, then boot and save on the installed disk.

Only ordinary image files are accepted. The installer source is read-only, and
each run creates a new blank 80 MiB destination in its artifact directory.
"""
import argparse
import binascii
import hashlib
import importlib.util
import json
import math
from pathlib import Path
import re
import socket
import struct
import subprocess
import sys
import time
import uuid

ROOT = Path(__file__).resolve().parent.parent


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, ROOT / "tools" / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


windows = load("bedrock_installer_windows", "test-window-desktop.py")
menus = load("bedrock_installer_pixels", "test-system-menus.py")
service, runtime, display = windows.service, windows.runtime, windows.display
SECTOR = 512
ESP_FIRST, ESP_END = 2048, 131039
DATA_FIRST, DATA_END = 131072, 139264
TARGET_BYTES = 80 * 1024 * 1024
NOTE = b"installed\n"
DATA_TYPE = bytes.fromhex("52444542434f444b8000444154410001")
ESP_TYPE = bytes.fromhex("28732ac11ff8d211ba4b00a0c93ec93b")
READY = re.compile(r"^\[installer\] ready architecture=(x86_64|ARM64|RISC-V64) width=(\d+) height=(\d+)$", re.M)
DEVICES = re.compile(r"^\[installer\] devices eligible=(\d+) protected=(\d+)$", re.M)
COMPLETE = re.compile(r"^\[installer\] complete selected=(\d+) blocks=(\d+)$", re.M)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def filesystem(data):
    """Decode bounded committed banks independently of the live filesystem."""
    if len(data) != 4 * 1024 * 1024:
        raise AssertionError("installed data partition has the wrong length")
    banks = []
    for start in (0, 2097152):
        header = bytearray(data[start:start + SECTOR])
        if header[:8] != b"BEDFS001":
            continue
        crc = struct.unpack_from("<I", header, 60)[0]
        header[60:64] = b"\0" * 4
        if binascii.crc32(header) & 0xffffffff != crc:
            raise AssertionError("installed filesystem bank header CRC differs")
        version, sector = struct.unpack_from("<II", header, 8)
        generation, blocks = struct.unpack_from("<QQ", header, 16)
        bank_blocks, nodes, file_bytes, path_bytes = struct.unpack_from("<IIII", header, 32)
        size, payload_crc = struct.unpack_from("<QI", header, 48)
        if (version, sector, blocks, bank_blocks, nodes, file_bytes, path_bytes, size) != (1, 512, 8192, 4096, 32, 4096, 128, 32 * 4288):
            raise AssertionError("installed filesystem geometry differs")
        if generation == 0 or struct.unpack_from("<I", header, 68)[0] != start // 2097152 or any(header[72:]):
            raise AssertionError("installed filesystem bank identity differs")
        payload = data[start + SECTOR:start + SECTOR + size]
        if binascii.crc32(payload) & 0xffffffff != payload_crc:
            raise AssertionError("installed filesystem payload CRC differs")
        records = {}
        for index in range(nodes):
            record = payload[index * 4288:(index + 1) * 4288]
            if not record[0]:
                if any(record):
                    raise AssertionError("unused filesystem slot is not zero")
                continue
            length = struct.unpack_from("<I", record, 20)[0]
            content_len = struct.unpack_from("<Q", record, 24)[0]
            if record[0] != 1 or record[1] not in (1, 2) or not 1 <= length <= 128 or content_len > 4096:
                raise AssertionError("invalid installed filesystem record")
            name = record[64:64 + length].decode("ascii")
            if name in records or not name.startswith("/"):
                raise AssertionError("duplicate or non-absolute installed filesystem path")
            records[name] = {"kind": record[1], "owner": struct.unpack_from("<Q", record, 8)[0], "content": record[192:192 + content_len].hex()}
        banks.append({"generation": generation, "records": records, "payload_sha256": digest(payload)})
    if not banks:
        raise AssertionError("no committed installed filesystem bank")
    active = max(banks, key=lambda bank: bank["generation"])
    return {"sha256": digest(data), "banks": banks, "active_generation": active["generation"], "records": active["records"]}


def data_partition(path):
    with path.open("rb") as stream:
        stream.seek(DATA_FIRST * SECTOR)
        data = stream.read((DATA_END - DATA_FIRST) * SECTOR)
    return data


def gpt(data):
    if len(data) != TARGET_BYTES:
        raise AssertionError("owned destination changed length")
    blocks = len(data) // SECTOR
    if data[510:512] != b"\x55\xaa" or data[450] != 0xee or struct.unpack_from("<I", data, 454)[0] != 1 or struct.unpack_from("<I", data, 458)[0] != blocks - 1:
        raise AssertionError("invalid protective MBR")
    headers, tables = [], []
    for lba, alternate, table_lba in ((1, blocks - 1, 2), (blocks - 1, 1, blocks - 33)):
        header = bytearray(data[lba * SECTOR:(lba + 1) * SECTOR])
        if header[:8] != b"EFI PART" or struct.unpack_from("<II", header, 8) != (0x10000, 92) or any(header[92:]):
            raise AssertionError("invalid GPT signature, revision or header geometry")
        crc = struct.unpack_from("<I", header, 16)[0]
        header[16:20] = b"\0" * 4
        if binascii.crc32(header[:92]) & 0xffffffff != crc or struct.unpack_from("<I", header, 20)[0] != 0:
            raise AssertionError("GPT header CRC or reserved fields differ")
        current, other, first, last = struct.unpack_from("<QQQQ", header, 24)
        location, count, entry_size, table_crc = struct.unpack_from("<QIII", header, 72)
        if (current, other, first, last, location, count, entry_size) != (lba, alternate, 34, blocks - 34, table_lba, 128, 128):
            raise AssertionError("GPT is not anchored to the actual destination end")
        table = data[location * SECTOR:location * SECTOR + count * entry_size]
        if binascii.crc32(table) & 0xffffffff != table_crc:
            raise AssertionError("GPT partition-table CRC differs")
        headers.append({"lba": lba, "alternate_lba": other, "table_lba": location, "header_crc32": crc, "table_crc32": table_crc, "disk_guid": bytes(header[56:72]).hex()})
        tables.append(table)
    if headers[0]["disk_guid"] != headers[1]["disk_guid"] or tables[0] != tables[1]:
        raise AssertionError("primary and backup GPT copies differ")
    partitions = []
    for index, expected in enumerate(((ESP_TYPE, ESP_FIRST, ESP_END - 1), (DATA_TYPE, DATA_FIRST, DATA_END - 1))):
        row = tables[0][index * 128:(index + 1) * 128]
        first, last, attributes = struct.unpack_from("<QQQ", row, 32)
        if (row[:16], first, last) != expected or attributes != 0 or not any(row[16:32]):
            raise AssertionError("installed partition type, extent or attributes differ")
        partitions.append({"type_guid": row[:16].hex(), "unique_guid": row[16:32].hex(), "first_lba": first, "last_lba": last})
    if any(tables[0][256:]) or not any(bytes.fromhex(headers[0]["disk_guid"])) or partitions[0]["unique_guid"] == partitions[1]["unique_guid"]:
        raise AssertionError("unexpected partition entries or duplicate/empty identifiers")
    return {"disk_bytes": len(data), "blocks": blocks, "headers": headers, "partitions": partitions, "table_sha256": digest(tables[0])}


def command(args, code, variables, source, target, installer):
    x86, arm = args.arch == "x86_64", args.arch == "arm64"
    machine = "pc-q35-10.1" if x86 else "virt-10.1,secure=off,virtualization=off,acpi=off" if arm else "virt,acpi=off"
    cpu = "qemu64" if x86 else "cortex-a57" if arm else "rv64"
    result = [args.qemu, "-machine", machine, "-cpu", cpu, "-accel", "tcg", "-smp", "1", "-m", f"{args.ram_mib}M",
              "-display", "none", "-serial", "stdio", "-monitor", "none", "-no-reboot", "-nic", "none",
              "-drive", f"if=pflash,format=raw,readonly=on,file={runtime.drive_path(code)}",
              "-drive", f"if=pflash,format=raw,snapshot=on,file={runtime.drive_path(variables)}"]
    device = "virtio-blk-pci,disable-legacy=on" if x86 else "virtio-blk-device"
    if not x86:
        result += ["-global", "virtio-mmio.force-legacy=false", "-device", "ramfb"]
        result += ["-semihosting-config", "enable=on,target=native"] if arm else ["-bios", "default"]
    if installer:
        result += ["-drive", f"if=none,id=installer-source,format=raw,readonly=on,file={runtime.drive_path(source)}", "-device", f"{device},drive=installer-source,serial=bedrock-installer-source,bootindex=1"]
        result += ["-device", "qemu-xhci,id=installer-usb", "-device", "usb-kbd,bus=installer-usb.0"]
    else:
        result += ["-device", "virtio-keyboard-pci,disable-legacy=on" if x86 else "virtio-keyboard-device", "-device", "virtio-tablet-pci,disable-legacy=on" if x86 else "virtio-tablet-device"]
    result += ["-drive", f"if=none,id=installed-target,format=raw,file={runtime.drive_path(target)}", "-device", f"{device},drive=installed-target,serial=bedrock-installed,bootindex={2 if installer else 1}"]
    if x86:
        result += ["-device", "isa-debug-exit,iobase=0xf4,iosize=4"]
    return result


class Machine(windows.Machine):
    def __init__(self, args, formatter, code, variables, source, target, suffix, installer=False):
        super().__init__(args, formatter, code, variables, runtime.drive_path(source), target.parent, target, suffix)
        self.source, self.installer = source, installer
        self.log_path = args.artifacts / f"installer-{args.arch}-{suffix}.log"
        self.error_path = args.artifacts / f"installer-{args.arch}-{suffix}.stderr.log"
        self.captures = {}

    def __enter__(self):
        if not self.installer:
            # The reusable window helper owns process/QMP setup and its actual
            # native readiness checks. Scope the command override to one enter.
            original = runtime.command_line
            runtime.command_line = lambda *_: command(self.args, self.code, self.variables, self.source, self.data, False)
            try:
                return super().__enter__()
            finally:
                runtime.command_line = original
        with socket.socket() as reservation:
            reservation.bind(("127.0.0.1", 0))
            port = reservation.getsockname()[1]
        argv = command(self.args, self.code, self.variables, self.source, self.data, True)
        argv += ["-qmp", f"tcp:127.0.0.1:{port},server=on,wait=off"]
        for path in (self.log_path, self.error_path):
            service.ordinary_output(path, self.formatter, self.boot_files)
        self.log, self.error_log = self.log_path.open("wb"), self.error_path.open("wb")
        startup = None
        if sys.platform == "win32":
            startup = subprocess.STARTUPINFO()
            startup.dwFlags |= subprocess.STARTF_USESHOWWINDOW
            startup.wShowWindow = 0
        try:
            self.process = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=self.log, stderr=self.error_log, startupinfo=startup, creationflags=subprocess.CREATE_NO_WINDOW if sys.platform == "win32" else 0)
            while True:
                self.check()
                try:
                    self.socket = socket.create_connection(("127.0.0.1", port), timeout=2)
                    break
                except OSError:
                    time.sleep(.04)
            self.reader = self.socket.makefile("rb")
            if "QMP" not in json.loads(self.reader.readline()):
                raise AssertionError("unexpected owned installer QMP greeting")
            self.qmp("qmp_capabilities")
            self.wait(lambda: READY.search(self.body()), "native installer readiness")
            return self
        except BaseException:
            self.__exit__(*sys.exc_info())
            raise

    def check(self):
        super().check()
        if "[installer] error " in self.body():
            raise AssertionError("native installer failed: " + self.body()[-2500:])

    def records(self):
        try:
            snapshot = filesystem(data_partition(self.data))
        except AssertionError:
            # A host read can cross the guest's inactive-bank transaction.
            # Await commit; final receipts still validate every captured bank.
            return {}
        return {name: {**record, "content": bytes.fromhex(record["content"])} for name, record in snapshot["records"].items()}

    def capture(self, label):
        from PIL import Image
        path = self.args.artifacts / f"installer-{self.args.arch}-{self.suffix}-{label}.ppm"
        for output in (path, path.with_suffix(".png")):
            service.ordinary_output(output, self.formatter, self.boot_files)
        self.qmp("screendump", {"filename": str(path.resolve())})
        data = path.read_bytes()
        self.width, self.height, pixels = display.parse_ppm(data)
        with Image.open(path) as image:
            if image.convert("RGB").tobytes() != pixels:
                raise AssertionError("PPM decoded pixels differ")
            image.save(path.with_suffix(".png"))
        with Image.open(path.with_suffix(".png")) as image:
            if image.size != (self.width, self.height) or image.convert("RGB").tobytes() != pixels:
                raise AssertionError("PNG decoded pixels differ from QMP capture")
        body = self.body()
        self.saved_scenes[label] = data
        self.captures[label] = {"ppm": str(path.resolve()), "png": str(path.with_suffix(".png").resolve()), "ppm_sha256": digest(data), "png_sha256": digest(path.with_suffix(".png").read_bytes()), "pixel_sha256": digest(pixels), "width": self.width, "height": self.height, "serial_characters": len(body), "serial_prefix_sha256": digest(body.encode())}
        return pixels

    def phase(self, label, stage):
        previous = None
        def painted():
            nonlocal previous
            pixels = self.capture(label)
            card_width, card_height = min(680, self.width - 48), min(520, self.height - 48)
            card_top = (self.height - card_height) // 2
            x = (self.width - card_width) // 2 + 24
            y = service.control_text_origin(card_top + 69, 24)
            button_label = "Continue" if stage.startswith("1 /") else "Erase and install" if stage.startswith("2 /") else "Restart"
            button_ink = (161, 162, 177) if stage.startswith("2 /") else (32, 34, 44)
            button_width = service.text_width(button_label)
            bx = (self.width - card_width) // 2 + card_width - 154 + (130 - button_width) // 2
            by = service.control_text_origin(card_top + card_height - 60, 36)
            complete = menus.has_text(pixels, self.width, stage, x, y, (212, 149, 173)) and menus.has_text(pixels, self.width, button_label, bx, by, button_ink)
            stable = complete and pixels == previous
            previous = pixels if complete else None
            return stable
        self.wait(painted, "painted installer phase: " + label)

    def confirmation(self, expected):
        def painted():
            pixels = self.capture("confirmation-input")
            w, h = min(680, self.width - 48), min(520, self.height - 48)
            x, top = (self.width - w) // 2 + 37, (self.height - h) // 2
            y, control_h = top + (322 if h < 500 else 361), 34 if h < 500 else 42
            origin = service.control_text_origin(y, control_h)
            return menus.has_text(pixels, self.width, expected or "ERASE", x, origin, (230, 227, 226) if expected else (161, 162, 177))
        self.wait(painted, "painted exact installer confirmation: " + repr(expected))

    def installer_text(self, text):
        prefix = ""
        for char in text:
            shifted = char.isupper() or char == "!"
            key = "1" if char == "!" else char.lower()
            self.firmware_key(key, shifted)
            prefix += char
            self.confirmation(prefix)

    def firmware_key(self, key, shifted=False):
        keys = (["shift"] if shifted else []) + [key]
        self.qmp("send-key", {"keys": [{"type": "qcode", "data": name} for name in keys], "hold-time": 100})
        # Release before waiting for a full frame: EFI HID typematic is real,
        # and holding a key throughout a slow GOP redraw generates repeats.
        time.sleep(.2)


def note_pixels(machine):
    pixels = machine.capture("notes-persisted")
    geometry = windows.client_geometry(windows.configurations(machine.body())[108])
    metrics = service.font_metrics()
    cell_width = metrics["editor_advance"]
    x, y = geometry["cx"] + 12, geometry["cy"] + 58
    # Native client buffers retain screen-sized private wallpaper/backdrop
    # storage while the host exposes only the current client rectangle.
    width, height = machine.width, machine.height
    def background(local_x, local_y):
        local_x += geometry["cx"]
        local_y += geometry["cy"]
        hx, hy = max(0, local_x * 2 - 7), max(0, local_y * 2 - 7)
        gx, gy, fx, fy = hx // 16, hy // 16, hx % 16, hy % 16
        a = menus.wallpaper_blurred(width, height, gx, gy)
        b = menus.wallpaper_blurred(width, height, min(gx + 1, (width + 7) // 8 - 1), gy)
        c = menus.wallpaper_blurred(width, height, gx, min(gy + 1, (height + 7) // 8 - 1))
        d = menus.wallpaper_blurred(width, height, min(gx + 1, (width + 7) // 8 - 1), min(gy + 1, (height + 7) // 8 - 1))
        expanded = tuple(((a[i] * (16 - fx) + b[i] * fx) * (16 - fy) + (c[i] * (16 - fx) + d[i] * fx) * fy + 128) // 256 for i in range(3))
        return tuple((expanded[i] * 143 + tint * 112 + 127) // 255 for i, tint in enumerate((45, 49, 63)))
    for index, char in enumerate("installed"):
        inset = (cell_width - metrics["advances"][ord(char) - 32]) // 2
        for dx, dy, alpha in menus.font_samples(char):
            if alpha == 0:
                continue
            local_x, local_y = 12 + index * cell_width + inset + dx, 58 + dy
            expected = tuple((ink * alpha + old * (255 - alpha) + 127) // 255 for ink, old in zip((233, 235, 243), background(local_x, local_y)))
            if menus.rgb(pixels, machine.width, x + index * cell_width + inset + dx, y + dy) != expected:
                return False
    return True


def run(args):
    formatter = runtime.formatter_module()
    for path in (args.image, args.os_image, args.code, args.vars, args.artifacts):
        runtime.validate_path_syntax(path)
    args.artifacts.mkdir(parents=True, exist_ok=True)
    if args.artifacts.is_symlink():
        raise ValueError("artifact directory must be ordinary")
    source, code, variables, os_image = (runtime.ordinary_file(path, formatter) for path in (args.image, args.code, args.vars, args.os_image))
    if source.stat().st_size != 64 * 1024 * 1024 or os_image.stat().st_size != 64 * 1024 * 1024:
        raise ValueError("installer and OS inputs must be ordinary 64 MiB raw artifacts")
    args.boot_files = [source, code, variables, os_image]
    before_inputs = {str(path): digest(path.read_bytes()) for path in args.boot_files}
    receipt_path = args.artifacts / f"installer-{args.arch}-verification.json"
    service.ordinary_output(receipt_path, formatter, args.boot_files)
    receipt_path.unlink(missing_ok=True)
    target = args.artifacts / f"installer-{args.arch}-target-{uuid.uuid4().hex}.img"
    service.ordinary_output(target, formatter, args.boot_files)
    with target.open("xb") as stream:
        stream.truncate(TARGET_BYTES)
    blank_hash = digest(target.read_bytes())
    scenes, boots = {}, {}
    started = time.monotonic()
    with Machine(args, formatter, code, variables, source, target, "install", True) as machine:
        ready, devices = READY.search(machine.body()), DEVICES.search(machine.body())
        if not devices or tuple(map(int, devices.groups())) != (1, 1) or ready.group(1) != {"x86_64": "x86_64", "arm64": "ARM64", "riscv64": "RISC-V64"}[args.arch]:
            raise AssertionError("installer did not protect its single source and expose exactly one destination")
        machine.phase("drive-selection", "1 / Choose a drive")
        machine.firmware_key("ret")
        machine.phase("partition-review", "2 / Review partitions")
        machine.installer_text("erase")
        machine.firmware_key("ret")
        machine.phase("rejected-confirmation", "2 / Review partitions")
        if digest(target.read_bytes()) != blank_hash or "[installer] installing " in machine.body():
            raise AssertionError("incorrect confirmation wrote destination bytes")
        machine.firmware_key("esc")
        machine.phase("back-to-selection", "1 / Choose a drive")
        machine.firmware_key("ret")
        machine.phase("review-cleared", "2 / Review partitions")
        machine.confirmation("")
        machine.installer_text("ERASE")
        machine.firmware_key("ret")
        machine.wait(lambda: COMPLETE.search(machine.body()), "native installer readback completion", timeout=180)
        machine.phase("installation-complete", "Ready to boot")
        installed = target.read_bytes()
        gpt_before = gpt(installed)
        expected_esp = os_image.read_bytes()[ESP_FIRST * SECTOR:ESP_END * SECTOR]
        if installed[ESP_FIRST * SECTOR:ESP_END * SECTOR] != expected_esp:
            raise AssertionError("installed ESP bytes differ from normal bootable OS image")
        expected_data = bytes(formatter.build_image())
        if installed[DATA_FIRST * SECTOR:DATA_END * SECTOR] != expected_data:
            raise AssertionError("installed Bedrock data seed differs")
        seed = filesystem(expected_data)
        install_log = machine.body()
        scenes["install"] = machine.captures
    boots["install"] = {"serial": str(machine.log_path.resolve()), "serial_sha256": digest(machine.log_path.read_bytes()), "stderr": str(machine.error_path.resolve()), "stderr_sha256": digest(machine.error_path.read_bytes()), "qemu_exit": machine.process.returncode}
    with Machine(args, formatter, code, variables, source, target, "installed") as machine:
        machine.wait(lambda: "[kernel] Bedrock data GPT partition mounted" in machine.body(), "installed GPT data mount")
        machine.focus_app(108)
        machine.notes_cursor_at(0, 0)
        row, column = 0, 0
        for char in NOTE.decode("ascii"):
            key = "ret" if char == "\n" else char
            machine.key(key, True)
            row, column = (row + 1, 0) if char == "\n" else (row, column + 1)
            machine.notes_cursor_at(row, column)
            machine.key(key, False)
        saved = machine.body().count("[window-notes] saved bytes=")
        machine.key("ctrl", True)
        time.sleep(.15)
        machine.key("s", True)
        machine.wait(lambda: machine.body().count("[window-notes] saved bytes=") > saved and machine.records().get(windows.NOTES_PATH, {}).get("content") == NOTE, "Notes Save inside installed GPT partition")
        machine.key("s", False)
        machine.key("ctrl", False)
        machine.wait(lambda: note_pixels(machine), "actual installed Notes text paint")
        before_reboot = filesystem(data_partition(target))
        windows.verify_log(machine.body(), machine.errors())
        scenes["installed"] = machine.captures
    boots["installed"] = {"serial": str(machine.log_path.resolve()), "serial_sha256": digest(machine.log_path.read_bytes()), "stderr": str(machine.error_path.resolve()), "stderr_sha256": digest(machine.error_path.read_bytes()), "qemu_exit": machine.process.returncode}
    with Machine(args, formatter, code, variables, source, target, "reboot") as machine:
        machine.wait(lambda: "[kernel] Bedrock data GPT partition mounted" in machine.body(), "rebooted GPT data mount")
        machine.focus_app(108)
        machine.wait(lambda: note_pixels(machine), "rebooted Notes loaded saved installed bytes")
        windows.verify_log(machine.body(), machine.errors())
        scenes["reboot"] = machine.captures
        final_data = filesystem(data_partition(target))
    boots["reboot"] = {"serial": str(machine.log_path.resolve()), "serial_sha256": digest(machine.log_path.read_bytes()), "stderr": str(machine.error_path.resolve()), "stderr_sha256": digest(machine.error_path.read_bytes()), "qemu_exit": machine.process.returncode}
    if final_data["records"].get(windows.NOTES_PATH) != {"kind": 2, "owner": 108, "content": NOTE.hex()} or before_reboot["records"] != final_data["records"]:
        raise AssertionError("private Notes record or owner differs after target-only reboot")
    final_target = target.read_bytes()
    if gpt(final_target) != gpt_before or final_target[ESP_FIRST * SECTOR:ESP_END * SECTOR] != expected_esp:
        raise AssertionError("normal filesystem writes altered ESP or GPT metadata")
    if {str(path): digest(path.read_bytes()) for path in args.boot_files} != before_inputs:
        raise AssertionError("read-only installer/OS/firmware inputs changed")
    receipt = {"status": "passed", "architecture": args.arch, "owned_qemu_processes_only": True, "ordinary_image_files_only": True, "installer_source_readonly": True, "target_only_boots": 2, "incorrect_confirmation_preserved_target": True, "blank_target_sha256": blank_hash, "input_sha256": before_inputs, "target": str(target.resolve()), "target_sha256": digest(final_target), "gpt": gpt_before, "seed": seed, "before_reboot_data": before_reboot, "final_data": final_data, "esp_sha256": digest(expected_esp), "boots": boots, "scenes": scenes, "elapsed_seconds": time.monotonic() - started, "installer_selection_markers": re.findall(r"^\[installer\] selected index=(\d+)$", install_log, re.M)}
    receipt_path.write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
    print(f"{args.arch}: native installer passed; protected source, confirmed GPT/ESP/data, target-only boot, Notes save and persistence")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--arch", required=True, choices=runtime.ARCHITECTURES)
    parser.add_argument("--image", required=True, type=Path)
    parser.add_argument("--os-image", required=True, type=Path)
    parser.add_argument("--qemu")
    parser.add_argument("--code", type=Path)
    parser.add_argument("--vars", type=Path)
    parser.add_argument("--artifacts", type=Path, default=ROOT / "zig-out/installer-tests")
    parser.add_argument("--ram-mib", type=int, default=256)
    parser.add_argument("--timeout", type=float, default=300)
    args = parser.parse_args()
    if not math.isfinite(args.timeout) or not 60 <= args.timeout <= 600:
        parser.error("timeout must be finite and 60..600 seconds per owned boot")
    if not 256 <= args.ram_mib <= 65536:
        parser.error("ram-mib must be 256..65536")
    qemu, code, variables = runtime.default_paths(args.arch)
    args.qemu, args.code, args.vars = args.qemu or qemu, args.code or code, args.vars or variables
    args.acceptance = False
    try:
        run(args)
    except (AssertionError, ValueError, OSError, RuntimeError, subprocess.SubprocessError) as error:
        print(f"Native installer verification failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
