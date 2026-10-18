#!/usr/bin/env python3
"""Boot native Files, drive real VirtIO input, and reopen its disk on reboot.

Only a freshly generated ordinary image in an owned temporary directory is
written. Firmware and ESP writes are snapshots. No host disk is opened.
"""
import argparse
import binascii
from functools import lru_cache
import importlib.util
import json
from pathlib import Path
import socket
import struct
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent
PREFIX = "/container/0000000000000002/"
WELCOME = b"Welcome to Bedrock.\nDrag this file into Downloads.\nCtrl-drag copies; F2 renames.\nYour files survive reboot.\n"
NULLIFY_SECRET = b"Bedrock-Nullify-owned-test-secret-68310792\n"
LAUNCH_TEXT_INK = frozenset(bytes((foreground * coverage + background * (255 - coverage) + 127) // 255
                                  for foreground, background in zip((212, 149, 173), (51, 53, 65)))
                           for coverage in range(128, 256))

def seed_owned_test_image(path, formatter):
    """Populate only the fresh, owned temporary image used by this workflow."""
    formatter.write_image(path)
    data = bytearray(path.read_bytes())
    assert len(data) == 4194304 and struct.unpack_from("<Q", data, 16)[0] == 1
    fixture = [
        ("/", 1, 0, 0, 0, b""),
        ("/container", 1, 0, 0, 0, b""),
        (PREFIX[:-1], 1, 2, 2, 1, b""),
        (PREFIX + "Documents", 1, 2, 2, 2, b""),
        (PREFIX + "Downloads", 1, 2, 2, 2, b""),
        (PREFIX + "Documents/welcome.txt", 2, 2, 2, 3, WELCOME),
        (PREFIX + "Documents/nullify.txt", 2, 2, 2, 3, NULLIFY_SECRET),
    ]
    for index, (name, kind, domain, owner, parent, content) in enumerate(fixture):
        record = bytearray(4288)
        record[:3] = bytes((1, kind, domain))
        struct.pack_into("<IQIIQ", record, 4, index + 1, owner, parent, len(name), len(content))
        record[64:64 + len(name)] = name.encode("ascii")
        record[192:192 + len(content)] = content
        start = 512 + index * 4288
        data[start:start + 4288] = record
    payload_size = 32 * 4288
    struct.pack_into("<I", data, 56, binascii.crc32(data[512:512 + payload_size]) & 0xffffffff)
    struct.pack_into("<I", data, 64, len(fixture) + 1)
    struct.pack_into("<I", data, 60, 0)
    struct.pack_into("<I", data, 60, binascii.crc32(data[:512]) & 0xffffffff)
    # Historical residue outside the serialized records exercises tail wiping.
    tail = 512 + ((payload_size + 511) // 512) * 512 + 1024
    for bank in (0, 2097152):
        data[bank + tail:bank + tail + len(NULLIFY_SECRET)] = NULLIFY_SECRET
    path.write_bytes(data)
    assert snapshot(path)[1][PREFIX + "Documents/nullify.txt"]["content"] == NULLIFY_SECRET

def verify_nullified_banks(path):
    raw = path.read_bytes()
    assert len(raw) == 4194304, "Unexpected logical data-image length"
    assert NULLIFY_SECRET not in raw, "Nullify left test bytes in the logical data image"
    assert (PREFIX + "Documents/nullify.txt").encode() not in raw, "Nullify left the deleted record path"
    generations = []
    sanitized = []
    for bank in (0, 2097152):
        header = bytearray(raw[bank:bank + 512])
        assert struct.unpack_from("<8sII", header) == (b"BEDFS001", 1, 512)
        assert struct.unpack_from("<QI", header, 24) == (8192, 4096)
        assert struct.unpack_from("<IIIQ", header, 36) == (32, 4096, 128, 137216)
        assert struct.unpack_from("<I", header, 68)[0] == bank // 2097152
        assert not any(header[72:]), "Nonzero reserved header bytes"
        assert struct.unpack_from("<Q", header, 16)[0] > 0
        expected = struct.unpack_from("<I", header, 60)[0]
        header[60:64] = b"\0" * 4
        assert binascii.crc32(header) & 0xffffffff == expected
        size, crc = struct.unpack_from("<QI", header, 48)
        payload = raw[bank + 512:bank + 512 + size]
        assert binascii.crc32(payload) & 0xffffffff == crc
        sanitized.append((bytes(header[64:68]), payload))
        for index in range(32):
            record = payload[index * 4288:(index + 1) * 4288]
            if not record[0]: assert record == b"\0" * 4288
        assert not any(raw[bank + 512 + size:bank + 2097152]), "Nullify left nonzero padding/tail"
        generations.append(struct.unpack_from("<Q", header, 16)[0])
    assert abs(generations[0] - generations[1]) == 1, "Expected two freshly sanitized generations"
    assert sanitized[0] == sanitized[1], "The verified banks differ in surviving records or next serial"
    return generations

def reference_frost(pixels, width, height, x, y, tint=(36, 40, 51), opacity=100):
    """Independent small-region reference from the unobscured desktop capture."""
    columns, rows = (width + 7) // 8, (height + 7) // 8
    @lru_cache(maxsize=None)
    def tile(cx, cy):
        samples = [pixels[(sy * width + sx) * 3:(sy * width + sx) * 3 + 3]
                   for sy in range(cy * 8, min(cy * 8 + 8, height))
                   for sx in range(cx * 8, min(cx * 8 + 8, width))]
        return tuple((sum(color[channel] for color in samples) + len(samples) // 2) // len(samples)
                     for channel in range(3))
    @lru_cache(maxsize=None)
    def horizontal(cx, cy):
        samples = [tile(max(0, min(columns - 1, cx + offset)), cy) for offset in range(-3, 4)]
        return tuple((sum(color[channel] for color in samples) + 3) // 7 for channel in range(3))
    def blurred(cx, cy):
        samples = [horizontal(cx, max(0, min(rows - 1, cy + offset))) for offset in range(-3, 4)]
        return tuple((sum(color[channel] for color in samples) + 3) // 7 for channel in range(3))
    hx, hy = max(0, min(x, width - 1) * 2 - 7), max(0, min(y, height - 1) * 2 - 7)
    gx, gy = min(hx // 16, columns - 1), min(hy // 16, rows - 1)
    fx, fy = hx % 16, hy % 16
    a, b = blurred(gx, gy), blurred(min(gx + 1, columns - 1), gy)
    c, d = blurred(gx, min(gy + 1, rows - 1)), blurred(min(gx + 1, columns - 1), min(gy + 1, rows - 1))
    expanded = tuple(((a[i] * (16 - fx) + b[i] * fx) * (16 - fy) +
                      (c[i] * (16 - fx) + d[i] * fx) * fy + 128) // 256 for i in range(3))
    return bytes((expanded[i] * (255 - opacity) + tint[i] * opacity + 127) // 255 for i in range(3))

def snapshot(path):
    data = path.read_bytes()
    candidates = []
    for start in (0, 2097152):
        header = bytearray(data[start:start + 512])
        if len(header) != 512 or header[:8] != b"BEDFS001":
            continue
        checksum = struct.unpack_from("<I", header, 60)[0]
        header[60:64] = b"\0" * 4
        if binascii.crc32(header) & 0xffffffff != checksum:
            continue
        generation = struct.unpack_from("<Q", header, 16)[0]
        nodes, file_bytes, path_bytes = struct.unpack_from("<III", header, 36)
        size, payload_crc = struct.unpack_from("<QI", header, 48)
        if (nodes, file_bytes, path_bytes, size) != (32, 4096, 128, 32 * (64 + 128 + 4096)):
            continue
        payload = data[start + 512:start + 512 + size]
        if len(payload) != size or binascii.crc32(payload) & 0xffffffff != payload_crc:
            continue
        records = {}
        for index in range(nodes):
            record = payload[index * 4288:(index + 1) * 4288]
            if not record[0]:
                continue
            path_length = struct.unpack_from("<I", record, 20)[0]
            length = struct.unpack_from("<Q", record, 24)[0]
            name = record[64:64 + path_length].decode("ascii")
            records[name] = {"kind": record[1], "owner": struct.unpack_from("<Q", record, 8)[0],
                             "content": record[192:192 + length]}
        candidates.append((generation, records))
    if not candidates:
        raise AssertionError("No independently validated committed filesystem snapshot")
    return max(candidates, key=lambda entry: entry[0])

class Machine:
    def __init__(self, args, directory, data, suffix):
        self.args, self.directory, self.data, self.suffix = args, directory, data, suffix
        self.process = self.socket = self.reader = None
    def __enter__(self):
        with socket.socket() as reservation:
            reservation.bind(("127.0.0.1", 0))
            port = reservation.getsockname()[1]
        arm = self.args.architecture == "arm64"
        x86 = self.args.architecture == "x86_64"
        machine = "pc-q35-10.1" if x86 else "virt-10.1,secure=off,virtualization=off,acpi=off" if arm else "virt,acpi=off"
        cpu = "qemu64" if x86 else "cortex-a57" if arm else "rv64"
        command = [self.args.qemu, "-machine", machine, "-cpu", cpu, "-accel", "tcg", "-smp", "1", "-m", "256M",
                   "-display", "none", "-serial", "stdio", "-monitor", "none", "-no-reboot", "-nic", "none",
                   "-qmp", f"tcp:127.0.0.1:{port},server=on,wait=off",
                   "-drive", f"if=pflash,format=raw,readonly=on,file={self.args.code}",
                   "-drive", f"if=pflash,format=raw,snapshot=on,file={self.args.variables}"]
        if x86:
            command += ["-drive", f"format=raw,snapshot=on,file=fat:{self.args.esp}"]
        else:
            command += ["-global", "virtio-mmio.force-legacy=false", "-drive", f"if=none,id=bedrock-esp,format=raw,snapshot=on,file=fat:{self.args.esp}",
                        "-device", "virtio-blk-device,drive=bedrock-esp", "-device", "ramfb"]
            if not arm:
                command += ["-bios", "default"]
        device = "pci,disable-legacy=on" if x86 else "device"
        command += ["-drive", f"if=none,id=bedrock-data,format=raw,cache=writeback,file={self.data}",
                    "-device", f"virtio-blk-{device},drive=bedrock-data,serial=bedrock-data",
                    "-device", f"virtio-keyboard-{device}", "-device", f"virtio-tablet-{device}"]
        self.log_path = self.args.artifacts / f"desktop-{self.args.architecture}-{self.suffix}.log"
        self.error_path = self.directory / f"stderr-{self.suffix}.log"
        self.log = self.log_path.open("wb")
        self.error_log = self.error_path.open("wb")
        startup = None
        if sys.platform == "win32":
            startup = subprocess.STARTUPINFO()
            startup.dwFlags |= subprocess.STARTF_USESHOWWINDOW
            startup.wShowWindow = 0
        try:
            self.process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=self.log, stderr=self.error_log, startupinfo=startup)
            deadline = time.monotonic() + 10
            while True:
                try:
                    self.socket = socket.create_connection(("127.0.0.1", port), timeout=3)
                    break
                except OSError:
                    if time.monotonic() > deadline or self.process.poll() is not None:
                        raise RuntimeError(self.error_path.read_text(errors="replace"))
                    time.sleep(.05)
            self.reader = self.socket.makefile("rb")
            self.reader.readline()
            self.qmp("qmp_capabilities")
            self.wait(lambda: "[kernel] protected Files frame presented" in self.log_path.read_text(errors="replace"), "first protected frame")
            assert "[user] Files authority checks passed" in self.log_path.read_text(errors="replace"), "Missing protected syscall authority proof"
            assert "[user] Nullify namespace authority checks passed" in self.log_path.read_text(errors="replace"), "Missing Nullify syscall authority proof"
            assert "[user] Files network access denied" in self.log_path.read_text(errors="replace"), "Files acquired network access without approval"
            assert "[user] Files Wi-Fi control denied" in self.log_path.read_text(errors="replace"), "Files acquired Wi-Fi authority without approval"
            self.wait(lambda: "[kernel] frosted Files frame presented" in self.log_path.read_text(errors="replace"), "first native frosted frame")
            assert "[kernel] immutable frosted backdrop cached" in self.log_path.read_text(errors="replace"), "Missing owned blur cache"
            assert "[user] frosted material authority checks passed" in self.log_path.read_text(errors="replace"), "Missing material syscall boundary checks"
            self.capture("initial")
            self.floating_width = min(self.width - 96, 960)
            self.floating_height = min(self.height - 140, 620)
            self.floating_x = (self.width - self.floating_width) // 2
            self.floating_y = 72
            self.split = False
            self.geometry("floating")
            return self
        except BaseException:
            self.__exit__(*sys.exc_info())
            raise
    def __exit__(self, exception_type, *_):
        try:
            if exception_type is not None and self.socket and self.process and self.process.poll() is None:
                try: self.capture("failure")
                except Exception: pass  # Diagnostics must never prevent cleanup.
            if self.process and self.process.poll() is None:
                try: self.qmp("quit")
                except Exception: pass
                try: self.process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    self.process.kill()
                    self.process.wait(timeout=5)
        finally:
            for handle in (self.reader, self.socket, self.log, self.error_log):
                if handle:
                    try: handle.close()
                    except OSError: pass
    def power_off(self):
        # All accepted filesystem operations already flushed their commit.
        # Terminate without a guest shutdown or a QEMU backend close/flush.
        self.process.kill()
        self.process.wait(timeout=5)
    def qmp(self, execute, arguments=None):
        request = {"execute": execute}
        if arguments is not None: request["arguments"] = arguments
        self.socket.sendall(json.dumps(request).encode() + b"\n")
        while True:
            line = self.reader.readline()
            if not line: raise RuntimeError("QMP closed")
            result = json.loads(line)
            if "error" in result: raise RuntimeError(result["error"])
            if "return" in result: return result["return"]
    def wait(self, predicate, label, timeout=90):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            log = self.log_path.read_text(errors="replace")
            if "[panic]" in log or "[fault]" in log or "Files fault" in log or "Files exited" in log:
                raise AssertionError(f"{label}: {log[-3500:]}")
            if self.process.poll() is not None: raise RuntimeError(self.error_path.read_text(errors="replace"))
            if predicate(): return
            time.sleep(.1)
        raise AssertionError(f"Timed out: {label}; {self.log_path.read_text(errors='replace')[-2200:]}")
    def capture(self, name):
        path = self.args.artifacts / f"files-{self.args.architecture}-{self.suffix}-{name}.ppm"
        self.qmp("screendump", {"filename": str(path.resolve())})
        with path.open("rb") as stream:
            assert stream.readline().strip() == b"P6"
            self.width, self.height = map(int, stream.readline().split())
            assert stream.readline().strip() == b"255"
            pixels = stream.read()
            assert len(pixels) == self.width * self.height * 3
        try:
            from PIL import Image
            with Image.open(path) as image: image.save(path.with_suffix(".png"))
        except ImportError: pass
        return pixels
    def geometry(self, mode):
        self.mode = mode
        if mode == "floating":
            self.window_x, self.window_y = self.floating_x, self.floating_y
            self.window_width, self.window_height = self.floating_width, self.floating_height
        elif mode == "maximized":
            self.window_x, self.window_y = 0, 42
            self.window_width, self.window_height = self.width, self.height - 54
        else:
            self.window_x, self.window_y = 0, 0
            self.window_width, self.window_height = self.width, self.height
        self.inset = 0 if mode == "fullscreen" else 2
        self.cx, self.cy = self.window_x + self.inset, self.window_y + self.inset + 32
        self.client_width, self.client_height = self.window_width - 2 * self.inset, self.window_height - 2 * self.inset - 32
        self.pane_width = (self.client_width - 149) // 2 if self.split else self.client_width - 148
    def border(self, x, y, visible):
        def matches():
            pixels = self.capture("window-check")
            offset = (y * self.width + x) * 3
            return (pixels[offset:offset + 3] == bytes((84, 75, 89))) == visible
        self.wait(matches, "window border state after pointer input", timeout=30)
    def error_status(self, visible):
        def matches():
            pixels = self.capture("status-check")
            count = 0
            for y in range(self.cy + self.client_height - 24, self.cy + self.client_height):
                start = (y * self.width + self.cx + 12) * 3
                row = pixels[start:start + (self.client_width - 24) * 3]
                count += sum(row[x:x + 3] == bytes((255, 160, 150)) for x in range(0, len(row), 3))
            return (count > 20) == visible
        self.wait(matches, "native operation error status", timeout=30)
    def input(self, events): self.qmp("input-send-event", {"events": events})
    def point(self, x, y):
        # Round normalized QMP coordinates upward so the guest's floor-based
        # absolute-axis decoder lands on exactly the requested pixel.
        self.input([{"type": "abs", "data": {"axis": axis, "value": value}} for axis, value in
                    (("x", (x * 32767 + self.width - 2) // (self.width - 1)),
                     ("y", (y * 32767 + self.height - 2) // (self.height - 1)))])
    def button(self, down, name="left"): self.input([{"type": "btn", "data": {"down": down, "button": name}}])
    def click(self, x, y):
        self.point(x, y); time.sleep(.08); self.button(True); time.sleep(.08); self.button(False); time.sleep(.15)
    def key(self, name, down=None):
        for state in (True, False) if down is None else (down,):
            self.input([{"type": "key", "data": {"down": state, "key": {"type": "qcode", "data": name}}}])
        time.sleep(.04)
    def text(self, text):
        for char in text: self.key("dot" if char == "." else char.lower())
    def edit_ready(self, prefix, name):
        def typed():
            pixels = self.capture("edit-ready")
            # The native editor draws a seven-pixel vertical cursor after the
            # completed name. Await it before switching from keyboard to mouse.
            x = self.cx + 136 + (len(prefix) + len(name)) * 6 + 2
            return all(pixels[((self.cy + 13 + row) * self.width + x) * 3:
                              ((self.cy + 13 + row) * self.width + x) * 3 + 3] == bytes((202, 186, 214))
                       for row in range(7))
        self.wait(typed, "completed native name editing", timeout=30)
    def row(self, pane=0, index=0): return self.cx + 148 + 34 + pane * (self.pane_width + 1), self.cy + 68 + 14 + index * 28
    def toolbar(self, index):
        if index in (9, 10, 0):
            self.click(self.cx + {9: 12, 10: 48, 0: 84}[index] + 16, self.cy + 20)
            return
        if index == 11:
            self.click(self.cx + self.client_width - 88, self.cy + 20)
            self.split = not self.split
            self.geometry(self.mode)
            return
        before = self.capture("before-more")
        self.click(self.cx + self.client_width - 36, self.cy + 20)
        self.menu_rect = self.menu_geometry("more", self.client_width - 60, 36)
        self.menu_ready(before)
        self.menu_choose(index)
    def menu_geometry(self, kind, x, y):
        actions = {"file": (8, 3, 4, 12, 6, 5, 13, 7),
                   "directory": (8, 3, 4, 12, 6, 5, 7),
                   "background": (2, 1, 12, 7, 11),
                   "more": (2, 1, 3, 4, 12, 6, 5, 13, 7, 11)}[kind]
        height = len(actions) * 28 + 8
        return (self.cx + max(0, min(x, self.client_width - 208)),
                self.cy + max(0, min(y, self.client_height - height)), height, actions)
    def menu_ready(self, before):
        x, y, height, _ = self.menu_rect
        def appeared():
            current = self.capture("context-menu")
            # Popup borders paint after rows. Mid-edge samples avoid rounded
            # corners and prove the native menu has reached its overlay pass.
            changed = False
            for px, py in ((x, y + height // 2), (x + 104, y)):
                offset = (py * self.width + px) * 3
                if current[offset:offset + 3] != bytes((79, 83, 101)): return False
                changed |= current[offset:offset + 3] != before[offset:offset + 3]
            return changed
        self.wait(appeared, "native context menu", timeout=30)
    def menu_dismissed(self):
        x, y, height, _ = self.menu_rect
        def disappeared():
            current = self.capture("dismissed-menu")
            return any(current[(py * self.width + px) * 3:(py * self.width + px) * 3 + 3] != bytes((79, 83, 101))
                       for px, py in ((x, y + height // 2), (x + 104, y)))
        self.wait(disappeared, "native context menu dismissal", timeout=90)
    def right_click(self, point, kind="file"):
        before = self.capture("before-context")
        self.point(*point); time.sleep(.08)
        self.button(True, "right"); time.sleep(.08); self.button(False, "right")
        self.menu_rect = self.menu_geometry(kind, point[0] - self.cx, point[1] - self.cy)
        self.menu_ready(before)
    def menu_choose(self, action):
        x, y, _, actions = self.menu_rect
        self.click(x + 80, y + 4 + actions.index(action) * 28 + 14)
        self.menu_dismissed()
    def sidebar(self, index): return self.cx + 74, self.cy + 88 + index * 36
    def shortcut(self, index):
        self.click(*self.sidebar(index))
        self.selected_shortcut(index)
    def selected_shortcut(self, index):
        def selected():
            pixels = self.capture("navigation-check")
            offset = ((self.cy + 88 + index * 36) * self.width + self.cx + 128) * 3
            return pixels[offset:offset + 3] == bytes((63, 60, 78))
        self.wait(selected, "sidebar navigation", timeout=30)
    def row_named(self, relative, pane=0):
        parent, name = relative.rsplit("/", 1)
        prefix = PREFIX + parent + "/"
        names = [path[len(prefix):] for path in self.records() if path.startswith(prefix) and
                 "/" not in path[len(prefix):] and not path[len(prefix):].startswith(".")]
        return self.row(pane, names.index(name))
    def control(self, name):
        offset = {"close": 8, "minimize": 36, "maximize": 64, "fullscreen": self.window_width - 2 * self.inset - 32}[name]
        self.click(self.window_x + self.inset + offset + 12, self.window_y + self.inset + 16)
    def visible(self, state=True):
        if self.mode != "fullscreen":
            self.border(self.window_x, self.window_y, state)
        else:
            def matches():
                pixels = self.capture("fullscreen-check")
                # The title background is now position-dependent frost. Check
                # an unobscured pixel of the real close control instead.
                offset = (21 * self.width + 20) * 3
                return (pixels[offset:offset + 3] == bytes((213, 150, 172))) == state
            self.wait(matches, "fullscreen window state", timeout=30)
        if state: self.paint_ready()
    def paint_ready(self):
        def complete():
            pixels = self.capture("paint-ready")
            # Caption/frame paint precedes the protected client. The footer's
            # sharp glyphs appear at the end of its native view paint, so a
            # freshly restored frame alone cannot satisfy this input barrier.
            ink = 0
            for y in range(self.cy + self.client_height - 24, self.cy + self.client_height):
                start = (y * self.width + self.cx + 8) * 3
                row = pixels[start:start + (self.client_width - 16) * 3]
                ink += sum(row[x:x + 3] in (bytes((154, 166, 187)), bytes((255, 160, 150)))
                           for x in range(0, len(row), 3))
            return ink > 20
        self.wait(complete, "completed protected client paint", timeout=30)
    def records(self): return snapshot(self.data)[1]
    def frost_probes(self):
        return [(self.cx + 148 + (self.client_width - 148) * fraction // 4, self.cy + y)
                for fraction in (1, 2, 3)
                for y in (self.client_height // 2, self.client_height - 60)]
    def wallpaper_ready(self, previously_visible):
        # A vanished top border can precede most of the row-by-row wallpaper
        # repaint. Require old client/footer ink gone and the launch bar drawn
        # after that wallpaper pass before accepting a stable complete frame.
        footer_ink = [(y * self.width + x) * 3
                      for y in range(self.cy + self.client_height - 24, self.cy + self.client_height)
                      for x in range(self.cx + 8, self.cx + self.client_width - 8)
                      if previously_visible[(y * self.width + x) * 3:(y * self.width + x) * 3 + 3]
                      in (bytes((154, 166, 187)), bytes((255, 160, 150)))]
        launch_ink = [(y * self.width + x) * 3 for y in range(36) for x in range(94, 166)
                      if previously_visible[(y * self.width + x) * 3:(y * self.width + x) * 3 + 3]
                      in LAUNCH_TEXT_INK]
        probes = [(y * self.width + x) * 3 for x, y in self.frost_probes()]
        assert len(footer_ink) > 20 and len(launch_ink) > 35, "Missing initial client/footer or launch bar paint"
        previous, stable, wallpaper = None, 0, None
        def complete():
            nonlocal previous, stable, wallpaper
            current = self.capture("unobscured-wallpaper")
            if (any(current[offset:offset + 3] == previously_visible[offset:offset + 3] for offset in footer_ink + probes)
                    or any(current[offset:offset + 3] != previously_visible[offset:offset + 3] for offset in launch_ink)):
                previous, stable = None, 0
                return False
            stable = stable + 1 if current == previous else 1
            previous = current
            if stable < 3: return False
            wallpaper = current
            return True
        self.wait(complete, "complete stable wallpaper after minimize", timeout=30)
        return wallpaper
    def check_frost(self, wallpaper, previously_visible):
        expected = {point: reference_frost(wallpaper, self.width, self.height, *point) for point in self.frost_probes()}
        assert len(set(expected.values())) > 1, "Wallpaper frost should retain softly varying color"
        def matches():
            current = self.capture("frosted-restored")
            for (x, y), color in expected.items():
                offset = (y * self.width + x) * 3
                assert previously_visible[offset:offset + 3] == color, "Initial material did not match immutable wallpaper blur"
                if current[offset:offset + 3] != color: return False
            return True
        self.wait(matches, "stable frosted pixels after minimize/restore", timeout=30)
    def exists(self, relative): return PREFIX + relative in self.records()
    def drag(self, source, destination, copy=False):
        self.point(*source); time.sleep(.12)
        if copy: self.key("ctrl", True)
        self.button(True); time.sleep(.15)
        self.point(*destination); time.sleep(.2)
        self.button(False)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("architecture", choices=("x86_64", "arm64", "riscv64"))
    parser.add_argument("qemu")
    parser.add_argument("esp", type=Path)
    parser.add_argument("code", type=Path)
    parser.add_argument("variables", type=Path)
    parser.add_argument("--artifacts", type=Path, default=ROOT / "zig-out" / "desktop-tests")
    args = parser.parse_args()
    args.artifacts.mkdir(parents=True, exist_ok=True)
    receipt_path = args.artifacts / f"desktop-{args.architecture}-verification.json"
    receipt_path.unlink(missing_ok=True)
    spec = importlib.util.spec_from_file_location("data_formatter", ROOT / "tools" / "make-data-image.py")
    formatter = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(formatter)
    with tempfile.TemporaryDirectory(prefix="bedrock-desktop-") as temporary:
        directory = Path(temporary)
        data = directory / "data.img"
        seed_owned_test_image(data, formatter)
        with Machine(args, directory, data, "first") as machine:
            machine.wait(lambda: machine.exists("Documents/welcome.txt"), "seeded file")
            machine.click(*machine.row_named("Documents/welcome.txt"))
            machine.key("f2")
            machine.edit_ready("Rename: ", "welcome.txt")
            for _ in "welcome.txt": machine.key("backspace")
            machine.text("persisted.txt"); machine.key("ret")
            machine.wait(lambda: machine.exists("Documents/persisted.txt"), "native rename")
            machine.drag(machine.row_named("Documents/persisted.txt"), machine.sidebar(2))
            machine.wait(lambda: machine.exists("Downloads/persisted.txt") and not machine.exists("Documents/persisted.txt"), "native drag move")
            machine.shortcut(2)
            machine.drag(machine.row_named("Downloads/persisted.txt"), machine.sidebar(1), copy=True)
            machine.wait(lambda: machine.exists("Documents/persisted.txt") and machine.exists("Downloads/persisted.txt"), "Ctrl-drag copy")
            machine.key("ctrl", False)
            unchanged = snapshot(data)
            machine.click(*machine.row_named("Downloads/persisted.txt")); machine.toolbar(3)
            machine.shortcut(1); machine.toolbar(12)
            machine.error_status(True)
            assert snapshot(data) == unchanged, "A colliding copy changed durable data"
            machine.drag(machine.row_named("Documents/persisted.txt"), (machine.width - 16, machine.height - 16))
            # Begin/cancel an edit as a visible, nonmutating input barrier.
            # Refresh intentionally retains the previous operation's error.
            machine.toolbar(1)
            machine.error_status(False)
            assert snapshot(data) == unchanged, "An invalid drop changed durable data"
            machine.key("esc")
            machine.click(*machine.row_named("Documents/persisted.txt")); machine.key("delete")
            machine.wait(lambda: not machine.exists("Documents/persisted.txt"), "native delete")
            machine.toolbar(2); machine.edit_ready("New folder: ", "")
            machine.text("keepfolder")
            machine.edit_ready("New folder: ", "keepfolder")
            machine.click(machine.cx + machine.client_width - 108, machine.cy + 20)
            machine.wait(lambda: machine.exists("Documents/keepfolder"), "native new folder")
            machine.toolbar(1); machine.edit_ready("New file: ", "")
            machine.text("created.txt")
            machine.edit_ready("New file: ", "created.txt")
            machine.click(machine.cx + machine.client_width - 108, machine.cy + 20)
            machine.wait(lambda: machine.exists("Documents/created.txt"), "native new file")
            machine.click(*machine.row_named("Documents/created.txt")); machine.toolbar(3)
            machine.shortcut(2); machine.toolbar(12)
            machine.wait(lambda: machine.exists("Downloads/created.txt"), "clipboard Copy and Paste")
            machine.click(*machine.row_named("Downloads/persisted.txt")); machine.toolbar(4)
            machine.shortcut(1); machine.toolbar(12)
            machine.wait(lambda: machine.exists("Documents/persisted.txt") and not machine.exists("Downloads/persisted.txt"), "clipboard Cut and Paste")
            machine.click(*machine.row_named("Documents/persisted.txt")); machine.toolbar(3)
            machine.shortcut(2); machine.toolbar(12)
            machine.wait(lambda: machine.exists("Downloads/persisted.txt"), "clipboard copy of saved bytes")
            machine.shortcut(1); machine.click(*machine.row_named("Documents/persisted.txt")); machine.key("delete")
            machine.wait(lambda: not machine.exists("Documents/persisted.txt"), "delete clipboard source copy")
            machine.shortcut(2); machine.toolbar(9); machine.selected_shortcut(1)
            machine.toolbar(10); machine.selected_shortcut(2)
            # Context menus replace mutation shortcuts in the header. Exercise
            # blank space, Escape dismissal and native right-click selection.
            unchanged = snapshot(data)
            blank = (machine.cx + machine.client_width - 20, machine.cy + machine.client_height - 40)
            machine.right_click(blank, "background")
            machine.capture("background-context-menu")
            machine.key("esc")
            machine.menu_dismissed()
            assert snapshot(data) == unchanged, "Dismissing a context menu mutated disk data"
            machine.shortcut(1)
            machine.right_click(machine.row_named("Documents/nullify.txt"))
            machine.capture("nullify-context-menu")
            completed = machine.log_path.read_text(errors="replace").count("Files nullify logical banks verified")
            presented = machine.log_path.read_text(errors="replace").count("Files nullify result frame presented")
            assert NULLIFY_SECRET in data.read_bytes(), "Missing initial nullify test content"
            machine.menu_choose(13)
            machine.wait(lambda: machine.log_path.read_text(errors="replace").count("Files nullify logical banks verified") > completed,
                         "successful two-bank Nullify readback", timeout=90)
            machine.wait(lambda: machine.log_path.read_text(errors="replace").count("Files nullify result frame presented") > presented,
                         "completed Nullify result repaint", timeout=30)
            machine.wait(lambda: not machine.exists("Documents/nullify.txt"), "nullified path removed")
            nullified_generations = verify_nullified_banks(data)
            assert machine.records()[PREFIX + "Downloads/persisted.txt"]["content"] == WELCOME
            machine.paint_ready()
            machine.capture("nullified")
            machine.capture("changed")
            machine.power_off()
        generation, before = snapshot(data)
        with Machine(args, directory, data, "reboot") as machine:
            machine.wait(lambda: machine.exists("Downloads/persisted.txt"), "durable reboot")
            after = machine.records()
            for name in ("Downloads/persisted.txt", "Documents/keepfolder", "Documents/created.txt"):
                assert before[PREFIX + name] == after[PREFIX + name], f"Reboot changed {name}"
            assert after[PREFIX + "Downloads/persisted.txt"]["content"] == WELCOME
            assert after[PREFIX + "Downloads/persisted.txt"]["owner"] == 2
            assert not machine.exists("Documents/nullify.txt")
            assert NULLIFY_SECRET not in data.read_bytes()
            machine.shortcut(2)
            machine.click(*machine.row_named("Downloads/persisted.txt")); machine.click(*machine.row_named("Downloads/persisted.txt"))
            time.sleep(1); preview = machine.capture("preview")
            machine.key("esc")
            time.sleep(.5); listing = machine.capture("listing")
            assert sum(a != b for a, b in zip(preview, listing)) > 2000, "Open/escape did not change native text preview"
            # Move and minimize/reopen the window through actual pointer input.
            machine.drag((machine.window_x + 150, machine.window_y + 18), (machine.window_x + 170, machine.window_y + 30))
            old_x, old_y = machine.window_x, machine.window_y
            machine.floating_x += 20; machine.floating_y += 12
            machine.geometry("floating")
            time.sleep(1)
            machine.visible()
            machine.border(old_x, old_y, False)
            machine.control("maximize"); machine.geometry("maximized"); machine.visible()
            time.sleep(.5); machine.capture("maximized")
            machine.control("fullscreen"); machine.geometry("fullscreen"); machine.visible()
            time.sleep(.5); machine.capture("fullscreen")
            machine.control("fullscreen"); machine.geometry("maximized"); machine.visible()
            machine.control("maximize"); machine.geometry("floating"); machine.visible()
            machine.key("f11"); machine.geometry("fullscreen"); machine.visible()
            machine.key("esc"); machine.geometry("floating"); machine.visible()
            time.sleep(.5)
            frosted_before = machine.capture("frosted-before-minimize")
            machine.control("minimize"); machine.visible(False)
            wallpaper = machine.wallpaper_ready(frosted_before)
            machine.click(130, 18)
            time.sleep(1)
            machine.visible()
            machine.check_frost(wallpaper, frosted_before)
            # Closing actually retires mappings/contexts/frames and a launch
            # starts a zeroed native client against the same private disk.
            for _ in range(2):
                closes = machine.log_path.read_text(errors="replace").count("Files closed; resources reclaimed")
                machine.control("close")
                machine.wait(lambda: machine.log_path.read_text(errors="replace").count("Files closed; resources reclaimed") > closes,
                             "closed client resource reclamation")
                machine.visible(False)
                launches = machine.log_path.read_text(errors="replace").count("protected Files frame presented")
                machine.click(130, 18)
                machine.wait(lambda: machine.log_path.read_text(errors="replace").count("protected Files frame presented") > launches, "fresh protected client launch")
                machine.visible()
                assert machine.records()[PREFIX + "Downloads/persisted.txt"]["content"] == WELCOME
            machine.toolbar(11)
            time.sleep(.5)
            machine.capture("final")
        receipt = {"architecture": args.architecture, "initial_committed_generation": generation,
                   "final_committed_generation": snapshot(data)[0], "reboots": 1,
                   "operations": ["rename", "sidebar_drag_move", "sidebar_control_drag_copy", "clipboard_copy_paste_collision", "clipboard_copy_paste", "clipboard_cut_paste", "history_back_forward", "invalid_drop_cancelled", "delete", "mouse_confirm_mkdir", "mouse_confirm_create", "background_context_menu", "file_context_menu", "nullify_two_banks", "nullify_reboot_absence", "double_click_preview", "window_drag", "maximize_restore", "fullscreen_restore", "fullscreen_keyboard_escape", "minimize_reopen", "close_resource_reclamation", "fresh_client_relaunch", "optional_split_view"],
                   "durable_file_content": WELCOME.decode(), "protected_syscall_checks": True,
                   "frosted_material_authority": True, "frosted_pixel_reference": True,
                   "immutable_frost_redraw": True,
                   "native_context_menus": True, "nullify_logical_banks_verified": True,
                   "nullify_result_frame_presented": True,
                   "nullify_generations": nullified_generations,
                   "window_pixels_asserted": True, "unclean_shutdown": True, "status": "passed"}
        receipt_path.write_text(json.dumps(receipt, indent=2) + "\n")
        print(f"{args.architecture}: protected Files input, namespace operations and reboot persistence passed")

if __name__ == "__main__": main()
