#!/usr/bin/env python3
"""Exercise the window evidence gate with independent in-memory artifacts.

No QEMU, build, installed image or receipt-selected path is opened. Fixtures
include checked disk banks, native RGB pixels and complete process generations.
"""
import binascii
import copy
import importlib.util
from pathlib import Path
import struct
import unittest

spec = importlib.util.spec_from_file_location("bedrock_window_gate_units", Path(__file__).with_name("test-window-desktop.py"))
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)
menus = gate.load("bedrock_tab_pixel_gate_units", "test-system-menus.py")


def state(label, files=14, notes=15, app=0, aux=0, surfaces=None, processes=None):
    count = int(files != 0) + int(notes != 0)
    return (f"[kernel] window desktop state state={label} app={app} aux={aux} server_pid=12 shell_pid=13 "
            f"files_pid={files} notes_pid={notes} surface_count={2 + 2 * count if surfaces is None else surfaces} "
            f"process_count={3 + count if processes is None else processes}")


class Boot:
    def __init__(self):
        self.lines = ["[bootloader] application archive staged", "[kernel] protected surface broker ready",
                      "[kernel] window process started pid=11 app=101", "[kernel] window process started pid=12 app=104",
                      "[window-server] native window compositor ready", "[kernel] window process started pid=13 app=107",
                      "[window-shell] protected shell ready"]
        self.epoch = 0
        self.prefixes = {}
        self.launch(2, 14)
        self.launch(108, 15)
        self.lines += ["[window-init] protected windows ready", "[kernel] window desktop identities verified", state("ready")]

    def configure(self, app, pid, visible=True, x=None, width=400, height=540, mode="floating", window_id=0):
        self.epoch += 1
        x = (0 if app == 2 else 400) if x is None else x
        self.lines.append(f"[window-server] configured app={app} pid={pid} epoch={self.epoch} frame_x={x} "
                          f"frame_y={0 if mode == 'fullscreen' else 42} frame_w={width} frame_h={height} "
                          f"visible={int(visible)} mode={mode} header_content={int(app == 2)} window_id={window_id} header_tabs={int(app == 2)}")

    def launch(self, app, pid):
        name = "Files" if app == 2 else "Notes"
        self.lines += [f"[kernel] window process started pid={pid} app={app}",
                       f"[window-{name.lower()}] protected {name} ready",
                       f"[window-{name.lower()}] duplicate connection and forged window controls denied",
                       f"[window-{name.lower()}] authority checks passed"]
        self.configure(app, pid)
        self.lines.append(f"[window-{name.lower()}] frame presented")

    def close(self, app, pid, files, notes, status=0):
        name = "Files" if app == 2 else "Notes"
        self.lines += [f"[kernel] window generation reclaimed pid={pid} app={app}",
                       f"[window-init] {name} process reaped pid={pid} status={status}",
                       state("closed", files, notes, app)]

    def capture(self, name):
        self.prefixes[name] = self.body()

    def body(self):
        return "\n".join(self.lines) + "\n"


def boot_fixture(lifecycle=False, acceptance=False):
    boot = Boot()
    if not lifecycle:
        boot.capture("initial")
        boot.lines += ["[window-files] path editing", "[window-files] path navigated path=/container/Downloads"]
        boot.capture("path-edited")
        for _ in range(2): boot.lines += ["[window-files] path editing", "[window-files] path rejected"]
        boot.capture("path-rejected")
        boot.lines += ["[window-files] path editing", "[window-files] path navigated path=/container/Documents"]
        boot.lines.append("[window-notes] saved bytes=21")
        boot.capture("notes-saved")
        boot.lines += ["[kernel] Files nullify logical banks verified", "[window-files] Files nullify result frame presented"]
        boot.capture("files-workflow")
        return boot
    boot.lines += [state("focused", app=108, aux=15), state("tiled", aux=1)]
    boot.capture("tiled")
    boot.configure(2, 14, False)
    boot.configure(108, 15, False)
    boot.lines.append(state("workspace", aux=1))
    boot.capture("workspace-empty")
    boot.lines += [state("workspace", aux=2), state("workspace", aux=3)]
    boot.configure(2, 14)
    boot.configure(108, 15)
    boot.lines.append(state("workspace", aux=0))
    boot.capture("workspace-return")
    boot.configure(2, 14, width=320, height=240)
    boot.lines.append(state("resized", app=2))
    boot.capture("resized")
    boot.configure(2, 14, x=0, width=800, height=600, mode="fullscreen")
    boot.lines.append(state("fullscreen", app=2))
    boot.capture("fullscreen")
    boot.configure(2, 14)
    boot.lines.append(state("restored", app=2))
    boot.configure(108, 15, False)
    boot.lines.append(state("minimized", app=108))
    boot.capture("minimized-notes")
    boot.configure(108, 15)
    boot.lines.append(state("restored", app=108))
    boot.close(2, 14, 0, 15)
    boot.capture("closed-files")
    boot.launch(2, 16)
    boot.lines.append(state("relaunched", 16, 15, 2))
    boot.capture("relaunched-files")
    boot.close(108, 15, 16, 0)
    boot.capture("closed-notes")
    boot.launch(108, 17)
    boot.lines.append(state("relaunched", 16, 17, 108))
    boot.capture("relaunched-notes")
    notes = 17
    if acceptance:
        boot.lines += ["[window-notes] deliberate startup write fault requested", "[kernel] window process fault pid=17 app=108"]
        boot.close(108, 17, 16, 0, 139)
        boot.launch(108, 18)
        notes = 18
        boot.lines.append(state("relaunched", 16, notes, 108))
        boot.capture("fault-notes")
    boot.configure(2, 16)
    boot.configure(108, notes)
    boot.lines.append(state("tiled", 16, notes, aux=1))
    boot.capture("final")
    if acceptance:
        boot.lines += ["[kernel] window generation reclaimed pid=16 app=2", "[kernel] window generation reclaimed pid=18 app=108",
                       "[kernel] window desktop teardown balanced", "[kernel] window desktop acceptance complete"]
    return boot


def disk_fixture(notes_owner=108, desktop_owner=2, desktop_kind=1):
    payload = bytearray(137216)
    base = "/container/0000000000000002/"
    entries = [("/", 1, 0, b""), ("/container", 1, 0, b""),
               (base[:-1], 1, 2, b""), (base + "Documents", 1, 2, b""), (base + "Downloads", 1, 2, b""),
               (base + "Desktop", desktop_kind, desktop_owner, b""),
               (base + "Downloads/persisted.txt", 2, 2, gate.service.WELCOME),
               (base + "Documents/keepfolder", 1, 2, b""), (base + "Documents/created.txt", 2, 2, b""),
               (base + "Downloads/created.txt", 2, 2, b""), ("/container/000000000000006c", 1, 108, b""),
               (gate.NOTES_PATH, 2, notes_owner, gate.NOTE)]
    for index, (path, kind, owner, content) in enumerate(entries):
        offset = index * 4288
        struct.pack_into("<BBBBIQIIQ", payload, offset, 1, kind, int(owner != 0) * 2, 0, index + 1, owner, 0, len(path), len(content))
        payload[offset + 64:offset + 64 + len(path)] = path.encode("ascii")
        payload[offset + 192:offset + 192 + len(content)] = content
    raw = bytearray(4194304)
    for bank, generation in ((0, 39), (2097152, 40)):
        header = bytearray(512)
        struct.pack_into("<8sIIQQIIIIQIIII", header, 0, b"BEDFS001", 1, 512, generation, 8192, 4096,
                         32, 4096, 128, len(payload), binascii.crc32(payload) & 0xffffffff, 0, len(entries) + 1, bank // 2097152)
        struct.pack_into("<I", header, 60, binascii.crc32(header) & 0xffffffff)
        raw[bank:bank + 512] = header
        raw[bank + 512:bank + 512 + len(payload)] = payload
    return bytes(raw)


def ppm_fixture(body):
    width, height = 800, 600
    pixels = bytearray(bytes((24, 27, 35)) * width * height)
    frames, live = {}, {}
    for line in body.splitlines():
        if match := gate.START.fullmatch(line):
            live[int(match[2])] = int(match[1])
        elif match := gate.RECLAIM.fullmatch(line):
            live.pop(int(match[2]), None)
        elif match := gate.CONFIG.fullmatch(line):
            app, pid, epoch, x, y, w, h, visible = map(int, match.groups()[:8])
            frames[app] = {"pid": pid, "epoch": epoch, "x": x, "y": y, "width": w, "height": h, "visible": visible,
                           "mode": match[9], "header_content": bool(int(match[10])), "window_id": int(match[11]), "header_tabs": bool(int(match[12]))}
    for app, frame in frames.items():
        if not frame["visible"] or live.get(app) != frame["pid"]:
            continue
        g = gate.client_geometry(frame)
        for control, right in (("minimize", 138), ("maximize", 92), ("close", 46)):
            x, y = g["cx"] + g["client_width"] - right, frame["y"] + (0 if frame["mode"] == "fullscreen" else 2)
            icon = "restore" if control == "maximize" and frame["mode"] == "maximized" else control
            glyph = [(x + 15 + dx, y + 8 + dy) for dx, dy in gate.CAPTION_ICON_PROBES[icon]]
            for px, py in glyph: pixels[(py * width + px) * 3:(py * width + px) * 3 + 3] = bytes((217, 221, 232))
        ink = bytes((154, 166, 187)) if app == 2 else bytes((153, 164, 179))
        for y in range(g["cy"] + g["client_height"] - 24, g["cy"] + g["client_height"] - 18):
            begin = (y * width + g["cx"] + 10) * 3
            pixels[begin:begin + 180] = ink * 60
    return f"P6\n{width} {height}\n255\n".encode() + pixels


def receipt_fixture(acceptance=False, architecture="x86_64"):
    first, reboot = boot_fixture(), boot_fixture(True, acceptance)
    logs = {"first": (first.body().encode(), b""), "reboot": (reboot.body().encode(), b"")}
    prefixes = first.prefixes | reboot.prefixes
    scenes = {name: ppm_fixture(body) for name, body in prefixes.items()}
    # Rejection status must have actually painted when its screenshot is taken.
    scenes["path-rejected"] = scenes["path-rejected"].replace(bytes((154, 166, 187)), bytes((255, 160, 150)))
    disk = disk_fixture()
    receipt = {"status": "passed", "architecture": architecture, "mode": "acceptance" if acceptance else "persistent",
               "image_kind": "raw-image", "image_sha256": gate.digest(b"owned image"), "reboots": 1,
               "owned_qemu_processes_only": True, "unclean_shutdown": True,
               "operations": gate.OPERATIONS + (["contained_notes_fault_recovery"] if acceptance else []),
               "before_reboot_disk": gate.disk_evidence(disk), "final_disk": gate.disk_evidence(disk), "boots": {}, "scenes": {}}
    for name, (serial, stderr) in logs.items():
        receipt["boots"][name] = {"serial_sha256": gate.digest(serial), "stderr_sha256": gate.digest(stderr),
                                  "qemu_exit": -9 if name == "first" else (33 if architecture == "x86_64" else 0) if acceptance else -15,
                                  "evidence": gate.verify_log(serial, stderr, name == "reboot", acceptance and name == "reboot")}
    for name, body in prefixes.items():
        receipt["scenes"][name] = {"serial_characters": len(body), "serial_prefix_sha256": gate.digest(body.encode()),
                                   "pixels": gate.scene_evidence(scenes[name], body)}
    return receipt, logs, scenes, disk


class NativeWindowEvidenceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.receipt, cls.logs, cls.scenes, cls.disk = receipt_fixture()

    def verify(self, receipt=None, logs=None, scenes=None, before=None, after=None, image=b"owned image"):
        return gate.verify_receipt(self.receipt if receipt is None else receipt, self.logs if logs is None else logs,
                                   self.scenes if scenes is None else scenes, self.disk if before is None else before,
                                   self.disk if after is None else after, image)

    def test_complete_persistent_and_real_fault_acceptance_on_all_architectures(self):
        self.assertTrue(self.verify())
        for arch in ("x86_64", "arm64", "riscv64"):
            value, logs, scenes, disk = receipt_fixture(True, arch)
            with self.subTest(arch=arch):
                self.assertTrue(gate.verify_receipt(value, logs, scenes, disk, disk, b"owned image"))

    def test_desktop_requires_real_directory_owned_by_files(self):
        for parameters in ({"desktop_owner": 108}, {"desktop_owner": 0}, {"desktop_kind": 2}):
            with self.subTest(parameters=parameters), self.assertRaisesRegex(AssertionError, "Desktop directory"):
                gate.disk_evidence(disk_fixture(**parameters))

    def test_tab_pixel_gate_rejects_missing_labels_close_and_add_icons(self):
        width, height = 800, 600
        frame = {"x": 0, "y": 42, "width": 800, "height": 546, "mode": "maximized"}
        state = {"count": 2, "active": 1, "id": 2}
        labels = ["Documents", "Downloads"]
        pixels = bytearray(bytes((20, 21, 26)) * width * height)
        def paint(x, y, color):
            offset = (y * width + x) * 3
            pixels[offset:offset + 3] = bytes(color)
        # Independent reference for this 796px client: tabs-only x10/y48,
        # 160px tabs, close icons at x150/310 and adjacent add icon at x342.
        manifest = menus.oracle()
        probes = [(index % 16, index // 16) for index, value in enumerate(manifest["icons"]["close"]) if value == 255]
        for index, color in ((0, menus.TAB_INACTIVE_INK), (1, menus.TAB_INK)):
            for dx, dy in probes:
                paint(150 + index * 160 + dx, 52 + dy, color)
            for dx, dy, alpha in gate.service.font_samples(labels[index]):
                if alpha == 255:
                    paint(36 + index * 160 + dx, 51 + dy, color)
        for dx in range(10): paint(337 + dx, 60, menus.TAB_INK)
        for dy in range(-5, 6): paint(342, 60 + dy, menus.TAB_INK)
        self.assertIsNotNone(menus.tabs_evidence(pixels, width, frame, state, labels, manifest))
        label_point = next((x, y) for x, y, alpha in gate.service.font_samples("Downloads") if alpha == 255)
        for name, point in (("close", (310 + probes[0][0], 52 + probes[0][1])),
                            ("add", (337, 60)), ("label", (196 + label_point[0], 51 + label_point[1]))):
            erased = bytearray(pixels)
            offset = (point[1] * width + point[0]) * 3
            erased[offset:offset + 3] = bytes((20, 21, 26))
            with self.subTest(name=name):
                self.assertIsNone(menus.tabs_evidence(erased, width, frame, state, labels, manifest))

    def test_tab_log_state_rejects_invalid_count_selection_and_identity(self):
        self.assertEqual(menus.tab_states("[window-files] tabs count=2 active=1 id=17 window_id=0\n"), [{"count": 2, "active": 1, "id": 17, "window_id": 0}])
        for count, active, identifier in ((0, 0, 1), (9, 0, 1), (2, 2, 1), (1, 0, 0), (1, 0, 1 << 32)):
            with self.subTest(count=count, active=active, identifier=identifier), self.assertRaises(AssertionError):
                menus.tab_states(f"[window-files] tabs count={count} active={active} id={identifier} window_id=0\n")

    def test_tab_orders_require_unique_bounded_ids_and_keep_window_streams_separate(self):
        body = ("[window-files] tabs count=2 active=0 id=1 window_id=0\n"
                "[window-files] tab order window_id=0 ids=1,2\n"
                "[window-files] tabs count=1 active=0 id=3 window_id=1\n"
                "[window-files] tab order window_id=1 ids=3\n")
        self.assertEqual(menus.tab_orders(body), [[1, 2]])
        self.assertEqual(menus.tab_orders(body, 1), [[3]])
        self.assertEqual(menus.tab_states(body)[-1]["id"], 1)
        self.assertEqual(menus.tab_states(body, 1)[-1]["id"], 3)
        for ids in ("1,1", "0", "4294967296", "1,2,3,4,5,6,7,8,9", "1,,2"):
            with self.subTest(ids=ids), self.assertRaises(AssertionError):
                menus.tab_orders(f"[window-files] tab order window_id=0 ids={ids}\n")

    def test_multiple_same_pid_windows_have_independent_geometry_epochs_and_balanced_retirement(self):
        boot = Boot()
        primary = gate.configurations(boot.body())[2]
        boot.configure(2, 14, x=100, width=320, height=240, window_id=1)
        boot.lines.append(state("focused", app=2, aux=14, surfaces=8))
        all_windows = gate.window_configurations(boot.body())
        self.assertEqual(set(all_windows), {(2, 0), (2, 1), (108, 0)})
        self.assertEqual(all_windows[2, 0]["pid"], all_windows[2, 1]["pid"])
        self.assertEqual(gate.configurations(boot.body())[2], primary)
        self.assertEqual(all_windows[2, 1]["width"], 320)
        gate.verify_log(boot.body(), "")
        before = boot.body()
        boot.lines += ["[window-server] window retired app=2 pid=14 window_id=1", state("focused", app=2, aux=14)]
        self.assertEqual(set(gate.window_configurations(boot.body())), {(2, 0), (108, 0)})
        gate.verify_log(boot.body(), "")
        with self.assertRaises(AssertionError):
            gate.verify_log(before.replace("surface_count=8", "surface_count=6"), "")
        with self.assertRaises(AssertionError):
            gate.window_configurations(boot.body() + "[window-server] window retired app=2 pid=14 window_id=1\n")
        boot.configure(2, 14, window_id=1)
        with self.assertRaises(AssertionError):
            gate.window_configurations(boot.body())

    def test_files_tabs_only_caption_is_left_aligned_and_legacy_accessory_remains_explicit(self):
        frame = {"x": 0, "y": 42, "width": 800, "height": 540, "mode": "floating"}
        native = gate.files_tabs_geometry(frame, 2, 0)
        self.assertEqual(native["bounds"], {"x": 10, "y": 48, "width": 642, "height": 24})
        legacy = gate.files_tabs_geometry({**frame, "header_tabs": False}, 2, 0)
        self.assertEqual(legacy["bounds"], {"x": 106, "y": 48, "width": 546, "height": 24})

    def test_detached_source_caption_requires_its_actual_unfocused_icon_ink(self):
        width, height = 800, 600
        frame = {"x": 0, "y": 42, "width": 800, "height": 540, "mode": "floating"}
        pixels = bytearray(width * height * 3)
        manifest = menus.oracle()
        first = None
        for icon in ("minimize", "maximize", "close"):
            rect = gate.caption_geometry(frame, icon)
            for offset, alpha in enumerate(manifest["icons"][icon]):
                if alpha != 255:
                    continue
                x, y = rect["x"] + 15 + offset % 16, rect["y"] + 8 + offset // 16
                index = (y * width + x) * 3
                pixels[index:index + 3] = bytes(menus.UNFOCUSED_CONTROL_INK)
                first = index if first is None else first
        self.assertIsNone(menus.icon_evidence(pixels, width, frame, manifest))
        self.assertIsNotNone(menus.icon_evidence(pixels, width, frame, manifest, menus.UNFOCUSED_CONTROL_INK))
        pixels[first:first + 3] = b"\0\0\0"
        self.assertIsNone(menus.icon_evidence(pixels, width, frame, manifest, menus.UNFOCUSED_CONTROL_INK))

    def test_lf_and_crlf_valid_but_embedded_carriage_return_invalid(self):
        body = self.logs["reboot"][0].decode()
        expected = gate.verify_log(body, "", True)
        self.assertEqual(expected, gate.verify_log(body.replace("\n", "\r\n"), "", True))
        corrupt = body.replace("[window-init] protected windows ready", "[window-init] protected windows ready\rforged", 1)
        with self.assertRaises(AssertionError):
            gate.verify_log(corrupt, "", True)

    def test_spoofed_service_app_and_colliding_pid_are_rejected(self):
        body = self.logs["reboot"][0].decode()
        for bad in (body.replace("server_pid=12", "server_pid=999", 1),
                    body.replace("pid=15 app=108", "pid=14 app=108", 1),
                    body.replace("pid=15 app=108", "pid=15 app=999", 1)):
            with self.subTest(bad=bad[-90:]), self.assertRaises(AssertionError):
                gate.verify_log(bad, "", True)

    def test_independent_close_counts_cannot_hide_missing_other_app(self):
        body = self.logs["reboot"][0].decode()
        old = state("closed", 0, 15, 2)
        for replacement in (state("closed", 0, 15, 2, surfaces=6), state("closed", 0, 15, 2, processes=5), state("closed", 0, 0, 2)):
            with self.subTest(replacement=replacement), self.assertRaises(AssertionError):
                gate.verify_log(body.replace(old, replacement, 1), "", True)

    def test_fault_trigger_and_status139_cannot_replace_actual_cpu_fault(self):
        body = boot_fixture(True, True).body()
        fault = "[kernel] window process fault pid=17 app=108\n"
        for bad in (body.replace("[kernel] window process fault pid=17 app=108\n", ""),
                    body.replace("fault pid=17 app=108", "fault pid=16 app=2"),
                    body.replace("Notes process reaped pid=17 status=139", "Notes process reaped pid=17 status=0"),
                    body.replace(fault, "") + fault):
            with self.subTest(bad=bad[-180:]), self.assertRaises(AssertionError):
                gate.verify_log(bad, "", True, True)

    def test_relaunch_requires_prior_reclaim_and_reap_in_order(self):
        lines = self.logs["reboot"][0].decode().splitlines()
        reclaim = next(i for i, line in enumerate(lines) if "generation reclaimed pid=14" in line)
        reap = next(i for i, line in enumerate(lines) if "Files process reaped pid=14" in line)
        lines[reclaim], lines[reap] = lines[reap], lines[reclaim]
        with self.assertRaises(AssertionError):
            gate.verify_log("\n".join(lines) + "\n", "", True)

    def test_state_cannot_refer_to_future_or_retired_process_generation(self):
        body = self.logs["reboot"][0].decode()
        for bad in (body.replace(state("ready"), state("ready", files=16), 1),
                    body.replace(state("relaunched", 16, 15, 2), state("relaunched", 14, 15, 2), 1)):
            with self.subTest(bad=bad[-90:]), self.assertRaises(AssertionError):
                gate.verify_log(bad, "", True)

    def test_mixed_legacy_profile_and_failure_evidence_is_rejected(self):
        for marker in ("[desktop-init] protected desktop ready", "[desktop-shell] protected shell ready",
                       "[desktop-files] authority checks passed", "[kernel] service desktop acceptance complete"):
            with self.subTest(marker=marker), self.assertRaises(AssertionError):
                gate.verify_log(self.logs["reboot"][0] + (marker + "\n").encode(), b"", True)
        for error in (b"[panic] compositor\n", b"[fault] surface\n"):
            with self.assertRaises(AssertionError):
                gate.verify_log(self.logs["reboot"][0], error, True)

    def test_configure_epoch_must_increase_without_duplicate_or_stale_frame(self):
        body = self.logs["reboot"][0].decode()
        first = next(gate.CONFIG.finditer(body)).group(0)
        with self.assertRaises(AssertionError):
            gate.configurations(body + first + "\n")
        with self.assertRaises(AssertionError):
            gate.configurations(body.replace("epoch=1 ", "epoch=0 ", 1))

    def test_configure_identity_must_be_current_authenticated_generation(self):
        body = self.logs["first"][0].decode()
        for bad in (body.replace("configured app=108 pid=15", "configured app=108 pid=999", 1),
                    body.replace("configured app=108 pid=15", "configured app=108 pid=14", 1)):
            with self.subTest(bad=bad[-90:]), self.assertRaises(AssertionError):
                gate.scene_evidence(self.scenes["initial"], bad)
        reboot = self.logs["reboot"][0].decode()
        latest = list(gate.CONFIG.finditer(reboot))[-1]
        bad = latest.group(0).replace(f"pid={latest[2]} ", "pid=15 ").replace(f"epoch={latest[3]} ", "epoch=999 ")
        with self.assertRaises(AssertionError):
            gate.scene_evidence(self.scenes["final"], reboot + bad + "\n")

    def test_scene_requires_bounded_configure_and_exact_ppm_bytes(self):
        body = self.logs["first"][0].decode()
        for pixels in (self.scenes["initial"][:-1], self.scenes["initial"] + b"\0", b"P6\n800 600\n255\n"):
            with self.assertRaises(AssertionError):
                gate.scene_evidence(pixels, body)
        with self.assertRaises(AssertionError):
            gate.scene_evidence(self.scenes["initial"], body.replace("frame_w=400", "frame_w=801", 1))
        with self.assertRaises(AssertionError):
            gate.scene_evidence(self.scenes["initial"], "\n".join(line for line in body.splitlines() if not line.startswith("[window-server] configured app=108")))

    def test_receipt_cannot_replace_integer_counts_or_exit_status_with_booleans(self):
        for target in ("reboots", "exit", "boundary", "pid", "closed_pid"):
            value = copy.deepcopy(self.receipt)
            if target == "reboots": value["reboots"] = True
            elif target == "exit": value["boots"]["first"]["qemu_exit"] = True
            elif target == "boundary": value["scenes"]["initial"]["serial_characters"] = True
            elif target == "pid": value["boots"]["first"]["evidence"]["started"][0][0] = True
            else: next(item for item in value["boots"]["reboot"]["evidence"]["states"] if item["state"] == "closed")["files"] = False
            with self.subTest(target=target), self.assertRaises(AssertionError):
                self.verify(value)

    def test_receipt_is_bound_to_logs_pixel_prefix_and_owned_image(self):
        for target in ("serial", "pixels", "prefix", "image"):
            value = copy.deepcopy(self.receipt)
            if target == "serial": value["boots"]["reboot"]["serial_sha256"] = "0" * 64
            elif target == "pixels": value["scenes"]["tiled"]["pixels"]["sha256"] = "0" * 64
            elif target == "prefix": value["scenes"]["initial"]["serial_prefix_sha256"] = "0" * 64
            else: value["image_sha256"] = "0" * 64
            with self.subTest(target=target), self.assertRaises(AssertionError):
                self.verify(value)

    def test_two_native_paints_and_empty_workspace_require_pixels_and_visibility(self):
        blank = b"P6\n800 600\n255\n" + bytes((24, 27, 35)) * 800 * 600
        scenes = self.scenes.copy()
        scenes["tiled"] = blank
        value = copy.deepcopy(self.receipt)
        prefix = self.logs["reboot"][0].decode()[:value["scenes"]["tiled"]["serial_characters"]]
        value["scenes"]["tiled"]["pixels"] = gate.scene_evidence(blank, prefix)
        with self.assertRaises(AssertionError):
            self.verify(value, scenes=scenes)
        scenes = self.scenes.copy()
        del scenes["workspace-empty"]
        with self.assertRaises(AssertionError):
            self.verify(scenes=scenes)
        # Matching fresh hashes cannot make retained client pixels prove hiding.
        scenes = self.scenes.copy()
        scenes["workspace-empty"] = self.scenes["tiled"]
        value = copy.deepcopy(self.receipt)
        prefix = self.logs["reboot"][0].decode()[:value["scenes"]["workspace-empty"]["serial_characters"]]
        with self.assertRaises(AssertionError):
            value["scenes"]["workspace-empty"]["pixels"] = gate.scene_evidence(scenes["workspace-empty"], prefix)
            self.verify(value, scenes=scenes)

    def test_disk_requires_notes_private_owner_and_identical_reboot_bytes(self):
        wrong_owner = disk_fixture(notes_owner=2)
        with self.assertRaises(AssertionError):
            gate.disk_evidence(wrong_owner)
        with self.assertRaises(AssertionError):
            self.verify(after=wrong_owner)
        value = copy.deepcopy(self.receipt)
        value["final_disk"]["records"][gate.NOTES_PATH]["owner"] = 2
        with self.assertRaises(AssertionError):
            self.verify(value)

    def test_header_contract_requires_explicit_opt_in_and_rejects_unknown_flags(self):
        body = self.logs["first"][0].decode()
        for bad in (body.replace("header_content=1", "header_content=0", 1),
                    body.replace("header_content=0", "header_content=1", 1),
                    body.replace(" header_content=1", "", 1),
                    body.replace("header_content=1", "header_content=2", 1),
                    body.replace("header_tabs=1", "header_tabs=0", 1),
                    body.replace("header_tabs=0", "header_tabs=1", 1),
                    body.replace(" window_id=0 header_tabs=1", "", 1)):
            with self.subTest(bad=bad[-100:]), self.assertRaises(AssertionError):
                gate.verify_log(bad, "")
                gate.scene_evidence(self.scenes["initial"], bad)

    def test_path_proof_requires_actual_order_and_screenshot_result(self):
        for kind in ("missing", "reordered", "future_capture"):
            receipt, logs, scenes, disk = receipt_fixture()
            first = logs["first"][0].decode()
            if kind == "future_capture":
                prefix = first[:first.index("[window-files] path editing")]
                record = receipt["scenes"]["path-edited"]
                record["serial_characters"] = len(prefix)
                record["serial_prefix_sha256"] = gate.digest(prefix.encode())
                record["pixels"] = gate.scene_evidence(scenes["path-edited"], prefix)
            else:
                line = "[window-files] path navigated path=/container/Downloads\n"
                first = first.replace(line, "", 1)
                if kind == "reordered": first += line
                logs["first"] = (first.encode(), b"")
                receipt["boots"]["first"]["serial_sha256"] = gate.digest(first.encode())
                for name in gate.FIRST_SCENES:
                    prefix = first if name != "initial" else first[:first.index("[window-files] path editing")]
                    record = receipt["scenes"][name]
                    record["serial_characters"] = len(prefix)
                    record["serial_prefix_sha256"] = gate.digest(prefix.encode())
                    record["pixels"] = gate.scene_evidence(scenes[name], prefix)
            with self.subTest(kind=kind), self.assertRaises(AssertionError):
                gate.verify_receipt(receipt, logs, scenes, disk, disk, b"owned image")

    def test_fresh_matching_hashes_cannot_hide_erased_privileged_header_control(self):
        for name in ("path-edited", "path-rejected"):
            value = copy.deepcopy(self.receipt)
            scenes = self.scenes.copy()
            data = bytearray(scenes[name])
            width, height, pixels = gate.display.parse_ppm(data)
            offset = len(data) - len(pixels)
            control = value["scenes"][name]["pixels"]["windows"]["2"]["header_controls"]["close"]
            dx, dy = gate.CAPTION_ICON_PROBES["close"][0]
            index = offset + ((control["y"] + 8 + dy) * width + control["x"] + 15 + dx) * 3
            data[index:index + 3] = bytes((24, 27, 35))
            scenes[name] = bytes(data)
            prefix = self.logs["first"][0].decode()[:value["scenes"][name]["serial_characters"]]
            value["scenes"][name]["pixels"] = gate.scene_evidence(scenes[name], prefix)
            with self.subTest(name=name), self.assertRaises(AssertionError):
                self.verify(value, scenes=scenes)

    def test_rejection_log_and_matching_hash_cannot_replace_visible_error_paint(self):
        value = copy.deepcopy(self.receipt)
        scenes = self.scenes.copy()
        scenes["path-rejected"] = scenes["path-rejected"].replace(bytes((255, 160, 150)), bytes((154, 166, 187)))
        prefix = self.logs["first"][0].decode()[:value["scenes"]["path-rejected"]["serial_characters"]]
        value["scenes"]["path-rejected"]["pixels"] = gate.scene_evidence(scenes["path-rejected"], prefix)
        with self.assertRaises(AssertionError): self.verify(value, scenes=scenes)

    def test_path_keyboard_input_preserves_case_tilde_and_slash(self):
        class Keyboard:
            def __init__(self): self.events = []
            def key(self, code): self.events.append((code, ()))
            def hotkey(self, code, *modifiers): self.events.append((code, modifiers))
        keyboard = Keyboard()
        gate.Machine.text(keyboard, "~/Downloads")
        self.assertEqual(keyboard.events, [("grave_accent", ("shift",)), ("slash", ()),
                                          ("d", ("shift",)), *((char, ()) for char in "ownloads")])

    def test_minimum_viewport_menu_stays_bounded_and_clicks_actual_compact_row(self):
        machine = object.__new__(gate.Machine)
        machine.cx, machine.cy, machine.client_width, machine.client_height = 5, 37, 316, 204
        machine.menu_rect = machine.menu_geometry("more", 256, 36)
        self.assertEqual(machine.menu_rect[:3], (113, 43, 198))
        clicked = []
        machine.click = lambda x, y: clicked.append((x, y))
        machine.menu_dismissed = lambda: None
        machine.menu_choose(11)
        self.assertEqual(clicked, [(193, 227)])


if __name__ == "__main__":
    unittest.main()
