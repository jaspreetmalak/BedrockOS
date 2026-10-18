#!/usr/bin/env python3
"""Reject false desktop success using independent logs, disk banks and pixels.

Fixtures use ordinary byte buffers. No build, QEMU process or existing disk is
opened, and receipt-supplied paths are never followed.
"""
import binascii
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import struct
import tempfile
import unittest
from unittest import mock

spec = importlib.util.spec_from_file_location("bedrock_service_desktop_gate_units", Path(__file__).with_name("test-service-desktop.py"))
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)


def fixture_launch(pid):
    return [f"[kernel] desktop process started pid={pid} app=2",
            "[desktop-files] display and raw input authority denied",
            "[user] Nullify namespace authority checks passed",
            "[user] Files network access denied", "[user] Files Wi-Fi control denied",
            "[desktop-files] authority checks passed", "[desktop-files] protected Files ready",
            "[desktop-files] frosted backdrop ready", "[desktop-files] frame presented",
            f"[desktop-init] pids server=11 shell=12 files={pid:x}"]


def fixture_state(state, pid, count=5):
    return f"[kernel] service desktop state state={state} server_pid=17 shell_pid=18 files_pid={pid} files_app=2 surface_count={count}"


def log_fixture(reboot=False, acceptance=False):
    lines = ["[bootloader] application archive staged", "[kernel] protected surface broker ready",
             "[kernel] desktop process started pid=17 app=104", "[desktop-server] native desktop compositor ready",
             "[kernel] desktop process started pid=18 app=107", "[desktop-shell] protected shell ready"]
    lines += fixture_launch(19)
    lines += ["[desktop-init] protected desktop ready", fixture_state("ready", 19),
              "[kernel] desktop service identities verified"]
    if not reboot:
        lines += ["[kernel] Files nullify logical banks verified", "[desktop-files] Files nullify result frame presented"]
    else:
        lines += [fixture_state("maximized", 19), fixture_state("fullscreen", 19), fixture_state("restored", 19),
                  "[desktop-server] Files minimized pid=13", fixture_state("minimized", 19),
                  "[desktop-server] Files restored pid=13", fixture_state("restored", 19)]
        for old, new in ((19, 20), (20, 21)):
            lines += ["[desktop-client] Files closed cleanly", f"[desktop-server] Files disconnected pid={old:x}",
                      f"[kernel] desktop Files generation reclaimed pid={old} app=2",
                      f"[desktop-init] Files process reaped pid={old:x}", fixture_state("closed", 0, 4)]
            lines += fixture_launch(new)
            lines += [fixture_state("relaunched", new)]
    if acceptance:
        lines += ["[kernel] desktop Files generation reclaimed pid=21 app=2",
                  "[kernel] service desktop teardown balanced", "[kernel] service desktop acceptance complete"]
    return ("\n".join(lines) + "\n").encode()


def disk_fixture(secret=False, wrong_owner=False):
    raw = bytearray(4194304)
    payload = bytearray(137216)
    paths = [("/", 1, 0, b""), ("/container", 1, 0, b""),
             ("/container/0000000000000002", 1, 2, b""),
             ("/container/0000000000000002/Documents", 1, 2, b""),
             ("/container/0000000000000002/Downloads", 1, 2, b""),
             ("/container/0000000000000002/Downloads/persisted.txt", 2, 9 if wrong_owner else 2,
              b"Welcome to Bedrock.\nDrag this file into Downloads.\nCtrl-drag copies; F2 renames.\nYour files survive reboot.\n"),
             ("/container/0000000000000002/Documents/keepfolder", 1, 2, b""),
             ("/container/0000000000000002/Documents/created.txt", 2, 2, b""),
             ("/container/0000000000000002/Downloads/created.txt", 2, 2, b"")]
    for index, (path, kind, owner, content) in enumerate(paths):
        offset = index * 4288
        struct.pack_into("<BBBBIQIIQ", payload, offset, 1, kind, int(owner != 0) * 2, 0, index + 1,
                         owner, 0, len(path), len(content))
        payload[offset + 64:offset + 64 + len(path)] = path.encode()
        payload[offset + 192:offset + 192 + len(content)] = content
    for bank, generation in ((0, 39), (2097152, 40)):
        header = bytearray(512)
        struct.pack_into("<8sIIQQIIIIQIIII", header, 0, b"BEDFS001", 1, 512, generation, 8192, 4096,
                         32, 4096, 128, len(payload), binascii.crc32(payload) & 0xffffffff, 0, 10, bank // 2097152)
        struct.pack_into("<I", header, 60, binascii.crc32(header) & 0xffffffff)
        raw[bank:bank + 512] = header
        raw[bank + 512:bank + 512 + len(payload)] = payload
    if secret: raw[-100:-100 + len(gate.NULLIFY_SECRET)] = gate.NULLIFY_SECRET
    return bytes(raw)


def scenes_fixture():
    width, height = 1280, 800
    wallpaper = bytearray()
    for y in range(height):
        for x in range(width):
            wallpaper += bytes((25 + x * 45 // width, 31 + y * 50 // height, 43 + (x + y) * 40 // (width + height)))
    def rectangle(data, x, y, w, h, color):
        for row in range(y, y + h):
            offset = (row * width + x) * 3
            data[offset:offset + w * 3] = bytes(color) * w
    scenes = {}
    for name in gate.REQUIRED_SCENES:
        pixels = bytearray(wallpaper)
        mode = "maximized" if name == "maximized" else "fullscreen" if name == "fullscreen" else "floating"
        moved = name not in ("initial", "preview", "listing", "maximized", "fullscreen")
        g = gate.geometry(width, height, mode, moved)
        visible = name != "unobscured-wallpaper" and not name.startswith("closed-")
        if visible:
            if mode == "fullscreen": rectangle(pixels, 20, 21, 1, 1, (213, 150, 172))
            else: rectangle(pixels, g["x"], g["y"], 1, 1, (84, 75, 89))
            rectangle(pixels, g["cx"] + 12, g["cy"] + g["client_height"] - 20, 12, 7, (154, 166, 187))
        if name == "preview": rectangle(pixels, 500, 300, 60, 50, (220, 212, 206))
        if name in ("frosted-before-minimize", "frosted-restored"):
            for fraction in (1, 2, 3):
                for relative_y in (g["client_height"] // 2, g["client_height"] - 60):
                    x = g["cx"] + 148 + (g["client_width"] - 148) * fraction // 4
                    y = g["cy"] + relative_y
                    color = gate.legacy.reference_frost(wallpaper, width, height, x, y)
                    rectangle(pixels, x, y, 1, 1, color)
        scenes[name] = b"P6\n1280 800\n255\n" + bytes(pixels)
    return scenes


def receipt_fixture(logs, scenes, data, acceptance=False):
    boots = {}
    for name, (serial, stderr) in logs.items():
        boots[name] = {"serial_sha256": hashlib.sha256(serial).hexdigest(), "stderr_sha256": hashlib.sha256(stderr).hexdigest(),
                       "qemu_exit": -9 if name == "first" else 33 if acceptance else -15,
                       "termination": "runner-kill" if name == "first" else "guest-acceptance" if acceptance else "runner-stop",
                       "evidence": gate.verify_markers(serial.decode(), stderr.decode(), 2 if name == "reboot" else 0, name == "first", acceptance and name == "reboot")}
    pixels = {}
    for name, screenshot in scenes.items():
        mode = "maximized" if name == "maximized" else "fullscreen" if name == "fullscreen" else "floating"
        moved = name not in ("initial", "preview", "listing", "maximized", "fullscreen")
        pixels[name] = gate.shot_evidence(screenshot, mode, moved, name != "unobscured-wallpaper" and not name.startswith("closed-"))
    return {"status": "passed", "architecture": "x86_64", "mode": "acceptance" if acceptance else "persistent",
            "image": "/owned/esp", "image_kind": "esp-directory", "reboots": 1, "operations": gate.OPERATIONS[:],
            "fresh_ordinary_data_image": True, "unclean_shutdown": True, "owned_qemu_processes_only": True,
            "server_shell_survived_files_close": True, "minimize_retained_files_pid": True, "native_frost_verified": True,
            "seconds_live_after_final_frame": 1.05, "elapsed_seconds": 45.5, "boots": boots, "scenes": pixels,
            "before_reboot_disk": gate.disk_evidence(data), "final_disk": gate.disk_evidence(data)}


class ServiceDesktopEvidenceTests(unittest.TestCase):
    def test_lf_and_crlf_preserve_strict_lifecycle_proofs(self):
        for acceptance in (False, True):
            body = log_fixture(reboot=True, acceptance=acceptance).decode()
            expected = gate.verify_markers(body, "", 2, acceptance=acceptance)
            self.assertEqual(expected, gate.verify_markers(body.replace("\n", "\r\n"), "", 2, acceptance=acceptance))
            corrupted = body.replace("surface_count=5", "surface_count=5\rforged", 1)
            with self.assertRaises(AssertionError):
                gate.verify_markers(corrupted, "", 2, acceptance=acceptance)

    def test_coherent_but_wrong_surface_baseline_cannot_supply_proof(self):
        body = log_fixture(reboot=True).decode()
        for original, closed in ((4, 3), (6, 5)):
            wrong = body.replace("surface_count=5", "surface_count=LIVE").replace("surface_count=4", f"surface_count={closed}").replace("surface_count=LIVE", f"surface_count={original}")
            with self.assertRaises(AssertionError):
                gate.verify_markers(wrong, "", 2)

    @classmethod
    def setUpClass(cls):
        cls.logs = {"first": (log_fixture(), b""), "reboot": (log_fixture(True), b"")}
        cls.scenes = scenes_fixture()
        cls.disk = disk_fixture()
        cls.receipt = receipt_fixture(cls.logs, cls.scenes, cls.disk)

    def verify(self, receipt=None, logs=None, scenes=None, before=None, after=None, image=None):
        return gate.verify_receipt(self.receipt if receipt is None else receipt, self.logs if logs is None else logs,
                                   self.scenes if scenes is None else scenes, self.disk if before is None else before,
                                   self.disk if after is None else after, image)

    def test_complete_persistent_and_acceptance_evidence_on_all_architectures(self):
        for arch in ("x86_64", "arm64", "riscv64"):
            for acceptance in (False, True):
                logs = {"first": self.logs["first"], "reboot": (log_fixture(True, acceptance), b"")}
                value = receipt_fixture(logs, self.scenes, self.disk, acceptance)
                value["architecture"] = arch
                if acceptance: value["boots"]["reboot"]["qemu_exit"] = 33 if arch == "x86_64" else 0
                with self.subTest(arch=arch, acceptance=acceptance): self.verify(value, logs)

    def test_partial_status_only_or_wrong_profile_receipts_are_rejected(self):
        for value in ({}, [], {"status": "passed"}, dict(self.receipt, status="failed"), dict(self.receipt, mode="legacy")):
            with self.subTest(value=str(value)[:80]), self.assertRaises(AssertionError): self.verify(value)

    def test_missing_authority_proof_and_embedded_fallback_are_rejected(self):
        body = self.logs["reboot"][0].decode()
        for text in (body.replace("[desktop-files] display and raw input authority denied\n", "", 1),
                     body.replace("[user] Files Wi-Fi control denied\n", "", 1),
                     body + "[kernel] protected Files frame presented\n"):
            with self.assertRaises(AssertionError): gate.verify_markers(text, "", 2)

    def test_stable_services_and_fresh_files_pids_are_required(self):
        body = self.logs["reboot"][0].decode()
        for text in (body.replace("server=11 shell=12 files=14", "server=16 shell=12 files=14"),
                     body.replace("server=11 shell=12 files=14", "server=11 shell=16 files=14"),
                     body.replace("server=11 shell=12 files=14", "server=11 shell=12 files=13"),
                     body.replace("server=11 shell=12 files=13", "server=11 shell=12 files=12", 1)):
            with self.assertRaises(AssertionError): gate.verify_markers(text, "", 2)

    def test_correct_marker_counts_cannot_hide_relaunch_before_reclaim(self):
        body = self.logs["reboot"][0].decode().splitlines()
        reclaim = next(index for index, line in enumerate(body) if "generation reclaimed" in line)
        reap = next(index for index, line in enumerate(body) if "Files process reaped" in line)
        body[reclaim], body[reap] = body[reap], body[reclaim]
        with self.assertRaises(AssertionError): gate.verify_markers("\n".join(body), "", 2)

    def test_trusted_close_requires_file_surface_released_and_services_retained(self):
        body = self.logs["reboot"][0].decode()
        for text in (body.replace("files_pid=0 files_app=2 surface_count=4", "files_pid=19 files_app=2 surface_count=5", 1),
                     body.replace("state=minimized server_pid=17", "state=minimized server_pid=99"),
                     body.replace("state=minimized server_pid=17 shell_pid=18 files_pid=19 files_app=2 surface_count=5",
                                  "state=minimized server_pid=17 shell_pid=18 files_pid=19 files_app=2 surface_count=4")):
            with self.assertRaises(AssertionError): gate.verify_markers(text, "", 2)

    def test_kernel_start_identity_must_match_init_and_lifecycle(self):
        body = self.logs["reboot"][0].decode()
        for text in (body.replace("pid=20 app=2", "pid=20 app=103"), body.replace("pid=17 app=104", "pid=17 app=107")):
            with self.assertRaises(AssertionError): gate.verify_markers(text, "", 2)

    def test_malformed_extra_kernel_or_init_telemetry_cannot_be_ignored(self):
        for line in ("[kernel] service desktop state state=closed server_pid=bad shell_pid=18 files_pid=0 files_app=2 surface_count=4",
                     "[desktop-init] pids server=invalid shell=12 files=13", "[kernel] desktop process started pid=19 app=2 garbage"):
            with self.assertRaises(AssertionError): gate.verify_markers(self.logs["reboot"][0].decode() + line + "\n", "", 2)

    def test_success_labels_do_not_override_panic_or_fault_in_either_log(self):
        for errors in ("[panic] compositor\n", "[fault] surface mapping\n"):
            with self.assertRaises(AssertionError): gate.verify_markers(self.logs["reboot"][0].decode(), errors, 2)

    def test_duplicate_nullify_or_readiness_success_does_not_count_as_proof(self):
        for marker in ("[kernel] Files nullify logical banks verified", "[kernel] desktop service identities verified"):
            with self.assertRaises(AssertionError): gate.verify_markers(self.logs["first"][0].decode() + marker + "\n", "", nullified=True)

    def test_log_and_numeric_receipt_forgery_are_rejected(self):
        for field in ("hash", "pid", "boolean"):
            value = copy.deepcopy(self.receipt)
            if field == "hash": value["boots"]["reboot"]["serial_sha256"] = "0" * 64
            elif field == "pid": value["boots"]["reboot"]["evidence"]["pids"][1]["files"] = 900
            else: value["boots"]["first"]["evidence"]["marker_counts"]["server"] = True
            with self.subTest(field=field), self.assertRaises(AssertionError): self.verify(value)

    def test_json_booleans_cannot_replace_zero_pids_or_directory_kinds(self):
        value = copy.deepcopy(self.receipt)
        closed = next(item for item in value["boots"]["reboot"]["evidence"]["states"] if item["state"] == "closed")
        closed["files"] = False
        with self.assertRaises(AssertionError): self.verify(value)
        value = copy.deepcopy(self.receipt)
        value["final_disk"]["records"]["/container/0000000000000002/Documents/keepfolder"]["kind"] = True
        with self.assertRaises(AssertionError): self.verify(value)

    def test_nullify_requires_both_disk_banks_clean_with_correct_owned_content(self):
        corrupted = bytearray(self.disk); corrupted[512] ^= 1
        for data in (disk_fixture(secret=True), disk_fixture(wrong_owner=True), self.disk[:-1], corrupted):
            with self.assertRaises(AssertionError): gate.disk_evidence(data)

    def test_valid_one_bank_cannot_hide_corrupt_or_residual_second_bank(self):
        for offset in (2097152 + 60, 2097152 + 512, 4194304 - 1):
            raw = bytearray(self.disk); raw[offset] ^= 1
            with self.subTest(offset=offset), self.assertRaises(AssertionError): gate.disk_evidence(raw)

    def test_reboot_data_mutation_or_fake_disk_digest_is_rejected(self):
        value = copy.deepcopy(self.receipt); value["final_disk"]["sha256"] = "0" * 64
        with self.assertRaises(AssertionError): self.verify(value)
        with self.assertRaises(AssertionError): self.verify(after=disk_fixture(wrong_owner=True))

    def test_missing_native_scene_or_stale_window_pixels_is_rejected(self):
        scenes = self.scenes.copy(); del scenes["closed-2"]
        with self.assertRaises(AssertionError): self.verify(scenes=scenes)
        scenes = self.scenes.copy(); scenes["closed-1"] = scenes["frosted-before-minimize"]
        with self.assertRaises(AssertionError): self.verify(scenes=scenes)

    def test_flat_frost_or_old_restored_material_is_rejected(self):
        scenes = self.scenes.copy(); raw = bytearray(scenes["frosted-restored"])
        width, height, _ = gate.display.parse_ppm(raw)
        g = gate.geometry(width, height, moved=True)
        x, y = g["cx"] + 148 + (g["client_width"] - 148) // 4, g["cy"] + g["client_height"] // 2
        begin = len(raw) - width * height * 3 + (y * width + x) * 3
        raw[begin:begin + 3] = b"\0\0\0"; scenes["frosted-restored"] = bytes(raw)
        # Updating receipt hashes/counts still cannot change the independent blur reference.
        value = copy.deepcopy(self.receipt); value["scenes"]["frosted-restored"] = gate.shot_evidence(raw, moved=True)
        with self.assertRaises(AssertionError): self.verify(value, scenes=scenes)

    def test_preview_requires_actual_pixels_not_matching_saved_listing(self):
        scenes = self.scenes.copy(); scenes["preview"] = scenes["listing"]
        value = copy.deepcopy(self.receipt); value["scenes"]["preview"] = gate.shot_evidence(scenes["preview"])
        with self.assertRaises(AssertionError): self.verify(value, scenes=scenes)

    def test_malformed_ppm_and_false_live_timing_are_rejected(self):
        for raw in (self.scenes["final"][:-1], self.scenes["final"] + b"\0", b"P6\n5000 5000\n255\n"):
            scenes = self.scenes.copy(); scenes["final"] = raw
            with self.assertRaises(AssertionError): self.verify(scenes=scenes)
        for live in (.1, float("nan"), True):
            value = copy.deepcopy(self.receipt); value["seconds_live_after_final_frame"] = live
            with self.assertRaises(AssertionError): self.verify(value)

    def test_raw_input_image_hash_is_required_and_bound_to_explicit_bytes(self):
        value = copy.deepcopy(self.receipt); value["image_kind"] = "raw-image"
        with self.assertRaises(AssertionError): self.verify(value)
        value["image_sha256"] = hashlib.sha256(b"owned input").hexdigest()
        self.verify(value, image=b"owned input")
        with self.assertRaises(AssertionError): self.verify(value, image=b"changed input")

    def test_normal_guest_exit_or_false_termination_ownership_cannot_prove_liveness(self):
        for field, replacement in (("qemu_exit", 0), ("qemu_exit", True), ("termination", "guest-acceptance")):
            value = copy.deepcopy(self.receipt); value["boots"]["reboot"][field] = replacement
            with self.assertRaises(AssertionError): self.verify(value)


class SidebarSelectionTests(unittest.TestCase):
    def machine(self, pixels, width=320):
        machine = gate.Machine.__new__(gate.Machine)
        machine.width, machine.cx, machine.cy = width, 40, 30
        machine.capture = lambda label: pixels
        def wait(predicate, description, timeout):
            self.assertEqual(description, "sidebar navigation")
            self.assertEqual(timeout, 30)
            if not predicate(): raise AssertionError("selection has not painted")
        machine.wait = wait
        return machine

    def test_selected_rows_remain_detectable_when_long_labels_cover_the_old_probe(self):
        for index in range(3):
            pixels = bytearray(320 * 300 * 3)
            top, left = 30 + 72 + index * 36, 40 + 8
            for y in range(top, top + 32):
                begin = (y * 320 + left) * 3
                pixels[begin:begin + 132 * 3] = bytes((63, 60, 78)) * 132
            # A wide label paints this right-side pixel over the selection.
            old_probe = ((top + 16) * 320 + 40 + 128) * 3
            pixels[old_probe:old_probe + 3] = bytes((233, 235, 243))
            with self.subTest(index=index): self.machine(pixels).selected_shortcut(index)

    def test_label_or_icon_pixels_cannot_prove_an_unselected_row_is_selected(self):
        pixels = bytearray(320 * 300 * 3)
        for index in range(3):
            old_probe = ((30 + 88 + index * 36) * 320 + 40 + 128) * 3
            pixels[old_probe:old_probe + 3] = bytes((63, 60, 78))
            with self.subTest(index=index), self.assertRaises(AssertionError):
                self.machine(pixels).selected_shortcut(index)


class FontMetricsTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.manifest = Path(self.directory.name) / "axis-sans.json"
        self.atlas_path = self.manifest.parent / "src/axis_sans.bin"
        self.atlas_path.parent.mkdir()
        self.metrics = {
            "family": "Axis Sans", "first_codepoint": 32, "glyph_count": 95,
            "format": "gray8 glyph-major, then row-major", "coverage_asset": "src/axis_sans.bin",
            "glyph_width": 14, "glyph_height": 20, "line_height": 20,
            "baseline": 15, "cap_height": 12, "x_height": 9, "editor_advance": 14,
            "advances": [8] * 95,
        }
        self.metrics["advances"][ord('A') - 32] = 11
        self.metrics["advances"][ord('B') - 32] = 12
        atlas = bytearray(95 * 14 * 20)
        atlas[(ord('A') - 32) * 280 + 19 * 14 + 10] = 173
        atlas[(ord('B') - 32) * 280 + 19 * 14 + 11] = 255
        self.atlas_path.write_bytes(atlas)
        self.write_metrics(self.metrics)
        self.patch = mock.patch.object(gate, "FONT_MANIFEST", self.manifest)
        self.patch.start()
        self.addCleanup(self.patch.stop)

    def write_metrics(self, metrics):
        self.manifest.write_text(json.dumps(metrics), encoding="utf-8")

    def test_native_samples_use_manifest_dimensions_advances_and_exact_gray_coverage(self):
        samples = gate.font_samples("AB")
        self.assertEqual(len(samples), (11 + 12) * 20)
        self.assertIn((10, 19, 173), samples)
        self.assertIn((22, 19, 255), samples)
        self.assertEqual(samples[-1], (22, 19, 255))
        self.assertEqual(gate.text_width("AB"), 23)
        self.assertEqual(gate.text_width("\N{SNOWMAN}"), 8)
        self.assertEqual(gate.control_text_origin(0, 36), 9)
        self.assertEqual(gate.control_text_origin(32, 40), 43)
        with self.assertRaises(AssertionError): gate.font_samples("\n")

    def test_invalid_metrics_reject_booleans_bad_dimensions_and_unsupported_layouts(self):
        replacements = {
            "family": "External Face", "first_codepoint": 33, "glyph_count": 94,
            "format": "other", "coverage_asset": "../untrusted.bin", "glyph_width": 65,
            "glyph_height": 0, "line_height": 19, "baseline": 20,
            "cap_height": 16, "x_height": 13, "editor_advance": 15,
        }
        for field, replacement in replacements.items():
            value = copy.deepcopy(self.metrics)
            value[field] = replacement
            self.write_metrics(value)
            with self.subTest(field=field), self.assertRaises(AssertionError): gate.font_metrics()
        for field in ("glyph_width", "glyph_height", "line_height", "baseline", "cap_height", "x_height", "editor_advance"):
            value = copy.deepcopy(self.metrics)
            value[field] = True
            self.write_metrics(value)
            with self.subTest(boolean_field=field), self.assertRaises(AssertionError): gate.font_metrics()
        for replacement in ([8] * 94, [8] * 94 + [True], [8] * 94 + [15]):
            value = copy.deepcopy(self.metrics)
            value["advances"] = replacement
            self.write_metrics(value)
            with self.subTest(advances=replacement[-1]), self.assertRaises(AssertionError): gate.font_metrics()

    def test_mismatched_atlas_lengths_cannot_supply_pixel_evidence(self):
        original = self.atlas_path.read_bytes()
        for payload in (original[:-1], original + b"\0", bytes(95 * 12 * 16)):
            self.atlas_path.write_bytes(payload)
            with self.subTest(length=len(payload)), self.assertRaises(AssertionError): gate.font_samples("AB")


if __name__ == "__main__": unittest.main()
