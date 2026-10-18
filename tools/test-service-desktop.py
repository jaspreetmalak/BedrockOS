#!/usr/bin/env python3
"""Drive installed Files through the native user compositor and reboot its disk.

Uses only owned QEMU processes, localhost QMP, snapshotted firmware/boot media,
and a fresh ordinary Bedrock data image. The legacy desktop gate remains intact.
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
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent
FONT_MANIFEST = ROOT / "frameworks/public/AxisUI/axis-sans.json"


def font_metrics():
    """Read bounded logical metrics for the original native ASCII face."""
    metrics = json.loads(FONT_MANIFEST.read_text(encoding="utf-8"))
    advances = metrics.get("advances")
    width, height = metrics.get("glyph_width"), metrics.get("glyph_height")
    line, baseline = metrics.get("line_height"), metrics.get("baseline")
    cap, lower, editor = metrics.get("cap_height"), metrics.get("x_height"), metrics.get("editor_advance")
    numbers = (width, height, line, baseline, cap, lower, editor)
    if (metrics.get("family") != "Axis Sans" or metrics.get("first_codepoint") != 32 or
            type(metrics.get("first_codepoint")) is not int or metrics.get("glyph_count") != 95 or
            type(metrics.get("glyph_count")) is not int or
            metrics.get("format") != "gray8 glyph-major, then row-major" or
            metrics.get("coverage_asset") != "src/axis_sans.bin" or
            any(type(value) is not int for value in numbers) or
            not 1 <= width <= 64 or not 1 <= height <= 64 or not height <= line <= 128 or
            not 1 <= lower <= cap <= baseline < height or not 1 <= editor <= width or
            not isinstance(advances, list) or len(advances) != 95 or
            any(type(advance) is not int or not 0 < advance <= editor for advance in advances)):
        raise AssertionError("invalid original native font metrics")
    return metrics


def font_atlas():
    metrics = font_metrics()
    atlas = (FONT_MANIFEST.parent / "src/axis_sans.bin").read_bytes()
    if len(atlas) != metrics["glyph_count"] * metrics["glyph_width"] * metrics["glyph_height"]:
        raise AssertionError("invalid native glyph atlas dimensions")
    return metrics, atlas


def font_samples(label):
    """Exact native gray8 samples, including transparent coverage, for pixel QA."""
    metrics, atlas = font_atlas()
    width, height = metrics["glyph_width"], metrics["glyph_height"]
    points, pen = [], 0
    for char in label:
        index = ord(char) - metrics["first_codepoint"]
        if not 0 <= index < metrics["glyph_count"]:
            raise AssertionError("pixel QA labels must be printable ASCII")
        for y in range(height):
            for x in range(metrics["advances"][index]):
                points.append((pen + x, y, atlas[index * width * height + y * width + x]))
        pen += metrics["advances"][index]
    return tuple(points)


def control_text_origin(top, height):
    metrics = font_metrics()
    return top + (height - metrics["cap_height"]) // 2 - (metrics["baseline"] - metrics["cap_height"])


def text_width(value):
    advances = font_metrics()["advances"]
    return sum(advances[ord(char) - 32 if 32 <= ord(char) <= 126 else ord('?') - 32] for char in value)


def is_text_ink(rgb):
    # The qualified desktop's footer/backdrop is darker than these bounds.
    # Count visible grayscale coverage as well as fully covered text pixels.
    return rgb[0] >= 85 and rgb[1] >= 95 and rgb[2] >= 105


def load_module(name, filename):
    spec = importlib.util.spec_from_file_location(name, ROOT / "tools" / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


legacy = load_module("bedrock_service_desktop_workflows", "test-desktop.py")
runtime = load_module("bedrock_service_desktop_boot", "test-application-runtime.py")
display = load_module("bedrock_service_desktop_pixels", "test-display-runtime.py")
PREFIX, WELCOME, NULLIFY_SECRET = legacy.PREFIX, legacy.WELCOME, legacy.NULLIFY_SECRET
MARKERS = {
    "archive": "[bootloader] application archive staged",
    "broker": "[kernel] protected surface broker ready",
    "server": "[desktop-server] native desktop compositor ready",
    "shell": "[desktop-shell] protected shell ready",
    "init": "[desktop-init] protected desktop ready",
    "identities": "[kernel] desktop service identities verified",
    "files": "[desktop-files] protected Files ready",
    "frame": "[desktop-files] frame presented",
    "authority": "[desktop-files] authority checks passed",
    "frost": "[desktop-files] frosted backdrop ready",
    "display_denied": "[desktop-files] display and raw input authority denied",
    "nullify_authority": "[user] Nullify namespace authority checks passed",
    "network_denied": "[user] Files network access denied",
    "wifi_denied": "[user] Files Wi-Fi control denied",
    "closed": "[desktop-client] Files closed cleanly",
    "nullified": "Files nullify logical banks verified",
    "nullify_frame": "Files nullify result frame presented",
    "balanced": "[kernel] service desktop teardown balanced",
    "complete": "[kernel] service desktop acceptance complete",
}
PID_RE = re.compile(r"^\[desktop-init\] pids server=([0-9a-f]+) shell=([0-9a-f]+) files=([0-9a-f]+)$", re.MULTILINE)
REAP_RE = re.compile(r"^\[desktop-init\] Files process reaped pid=([0-9a-f]+)$", re.MULTILINE)
RECLAIM_RE = re.compile(r"^\[kernel\] desktop Files generation reclaimed pid=([0-9]+) app=2$", re.MULTILINE)
START_RE = re.compile(r"^\[kernel\] desktop process started pid=([0-9]+) app=([0-9]+)$", re.MULTILINE)
STATE_RE = re.compile(r"^\[kernel\] service desktop state state=(ready|minimized|closed|relaunched|maximized|fullscreen|restored) server_pid=([0-9]+) shell_pid=([0-9]+) files_pid=([0-9]+) files_app=2 surface_count=([0-9]+)$", re.MULTILINE)
MINIMIZE_RE = re.compile(r"^\[desktop-server\] Files minimized pid=([0-9a-f]+)$", re.MULTILINE)
RESTORE_RE = re.compile(r"^\[desktop-server\] Files restored pid=([0-9a-f]+)$", re.MULTILINE)
OPERATIONS = ["rename", "sidebar_drag_move", "sidebar_control_drag_copy", "clipboard_copy_paste_collision",
              "clipboard_copy_paste", "clipboard_cut_paste", "history_back_forward", "invalid_drop_cancelled",
              "delete", "mouse_confirm_mkdir", "mouse_confirm_create", "background_context_menu", "file_context_menu",
              "nullify_two_banks", "nullify_reboot_absence", "double_click_preview", "window_drag", "maximize_restore",
              "fullscreen_restore", "fullscreen_keyboard_escape", "minimize_reopen", "close_resource_reclamation",
              "fresh_client_relaunch", "optional_split_view"]
REQUIRED_SCENES = ("initial", "preview", "listing", "maximized", "fullscreen", "frosted-before-minimize",
                   "unobscured-wallpaper", "frosted-restored", "closed-1", "relaunch-1", "closed-2", "relaunch-2", "final")


def digest(data):
    return hashlib.sha256(data).hexdigest()


def ordinary_output(path, formatter, inputs):
    formatter.validate_output(path)
    if any(path.resolve() == source or path.exists() and path.samefile(source) for source in inputs):
        raise ValueError("verification artifacts must differ from every boot input")


def boot_sources(image, kind, formatter):
    if kind == "raw-image": return image.resolve(), [image.resolve()]
    directory = image.resolve() if kind == "esp-directory" else image.resolve().parent.parent.parent
    files = []
    for path in directory.rglob("*"):
        if path.is_symlink(): raise ValueError("boot ESP entries must not be symbolic links")
        if path.is_file():
            files.append(runtime.ordinary_file(path, formatter))
            if len(files) > 256: raise ValueError("boot ESP inventory exceeds the bounded reference profile")
    return directory, files


def same_evidence(value, expected):
    # JSON booleans compare equal to 0/1 in Python; they cannot stand in for
    # kernel counts, PIDs, filesystem kinds or authenticated ownership values.
    if type(value) is not type(expected): return False
    if type(expected) is dict:
        return value.keys() == expected.keys() and all(same_evidence(value[key], item) for key, item in expected.items())
    if type(expected) is list:
        return len(value) == len(expected) and all(same_evidence(a, b) for a, b in zip(value, expected))
    return value == expected


def verify_markers(body, errors, relaunches=0, nullified=False, acceptance=False):
    """Require the service profile and authenticated PID continuity, not labels alone."""
    # ARM/RV UART consoles write CRLF; x86's serial console writes LF.
    # Normalize complete line endings without accepting embedded carriage returns.
    body = body.replace("\r\n", "\n")
    combined = body + "\n" + errors
    if "[panic]" in combined or "[fault]" in combined or "InstalledApplicationArchiveMissing" in combined:
        raise AssertionError("service desktop reported a failure")
    if any(marker in body for marker in ("[kernel] protected desktop ready", "[kernel] protected Files frame presented",
                                         "[kernel] display acceptance complete", "[kernel] application runtime acceptance complete")):
        raise AssertionError("an embedded or alternate desktop profile supplied the evidence")
    counts = {key: body.count(marker) for key, marker in MARKERS.items()}
    for key in ("archive", "broker", "server", "shell", "init", "identities"):
        if counts[key] != 1:
            raise AssertionError(f"missing/duplicate service desktop marker {key}: {counts[key]}")
    for key in ("files", "authority", "frost", "display_denied", "nullify_authority", "network_denied", "wifi_denied"):
        if counts[key] != relaunches + 1:
            raise AssertionError(f"Files launch authority count differs for {key}: {counts[key]}")
    if counts["frame"] < relaunches + 1 or counts["closed"] != relaunches:
        raise AssertionError("Files presentation/clean close evidence is incomplete")
    if counts["nullified"] != int(nullified) or counts["nullify_frame"] != int(nullified):
        raise AssertionError("Nullify readback and result repaint evidence differ from this boot")
    if counts["balanced"] != int(acceptance) or counts["complete"] != int(acceptance):
        raise AssertionError("service desktop termination does not match the selected mode")
    for prefix, pattern in (("[desktop-init] pids ", PID_RE), ("[desktop-init] Files process reaped ", REAP_RE),
                            ("[kernel] desktop process started ", START_RE), ("[kernel] desktop Files generation reclaimed ", RECLAIM_RE),
                            ("[kernel] service desktop state ", STATE_RE)):
        for line in body.splitlines():
            if line.startswith(prefix) and pattern.fullmatch(line) is None:
                raise AssertionError("malformed lifecycle telemetry: " + line)
    if not body.index(MARKERS["archive"]) < body.index(MARKERS["broker"]) < body.index(MARKERS["server"]) < body.index(MARKERS["init"]) < body.index(MARKERS["identities"]):
        raise AssertionError("service profile startup ordering is invalid")
    pids = [{"server": int(match[0], 16), "shell": int(match[1], 16), "files": int(match[2], 16)} for match in PID_RE.findall(body)]
    if len(pids) != relaunches + 1 or any(len(set(value.values())) != 3 or min(value.values()) <= 0 for value in pids):
        raise AssertionError("missing, duplicate or colliding desktop PID identities")
    first = pids[0]
    if any(value["server"] != first["server"] or value["shell"] != first["shell"] for value in pids) or len({value["files"] for value in pids}) != len(pids):
        raise AssertionError("desktop services restarted or Files reused a retired PID")
    reaped = [int(value, 16) for value in REAP_RE.findall(body)]
    reclaimed = [int(value) for value in RECLAIM_RE.findall(body)]
    if reaped != [value["files"] for value in pids[:-1]] or reclaimed != reaped + ([pids[-1]["files"]] if acceptance else []):
        raise AssertionError("close did not reap and reclaim precisely the old Files processes")
    pid_events = list(PID_RE.finditer(body))
    for index, (reap, reclaim) in enumerate(zip(REAP_RE.finditer(body), RECLAIM_RE.finditer(body))):
        if not pid_events[index].start() < reclaim.start() < reap.start() < pid_events[index + 1].start():
            raise AssertionError("Files relaunch preceded resource reclamation and process reap")
    if relaunches:
        minimized = [int(value, 16) for value in MINIMIZE_RE.findall(body)]
        restored = [int(value, 16) for value in RESTORE_RE.findall(body)]
        if minimized != [first["files"]] or restored != minimized or MINIMIZE_RE.search(body).start() >= RESTORE_RE.search(body).start():
            raise AssertionError("minimize/restore changed Files identity or lifecycle order")
    started = [(int(pid), int(app)) for pid, app in START_RE.findall(body)]
    for pid, app in ((first["server"], 104), (first["shell"], 107)):
        if started.count((pid, app)) != 1: raise AssertionError("kernel did not start the installed desktop service identity")
    if [pid for pid, app in started if app == 2] != [value["files"] for value in pids]:
        raise AssertionError("kernel Files process identities differ from supervised launches")
    states = [{"state": state, "server": int(server), "shell": int(shell), "files": int(files), "surfaces": int(surfaces)}
              for state, server, shell, files, surfaces in STATE_RE.findall(body)]
    lifecycle = [value["state"] for value in states if value["state"] in ("ready", "minimized", "closed", "relaunched")]
    expected_states = ["ready"] + (["minimized"] + ["closed", "relaunched"] * relaunches if relaunches else [])
    if lifecycle != expected_states or not states or any(value["server"] != first["server"] or value["shell"] != first["shell"] for value in states):
        raise AssertionError("trusted desktop lifecycle or service continuity is incomplete")
    baseline = states[0]["surfaces"]
    if baseline != 5: raise AssertionError("ready desktop did not retain both client surfaces and all three compositor surfaces")
    current = 0
    for state in states:
        if state["state"] == "relaunched": current += 1
        closed = state["state"] == "closed"
        if state["files"] != (0 if closed else pids[current]["files"]) or state["surfaces"] != baseline - int(closed):
            raise AssertionError("trusted minimize/close/relaunch did not retain or release exactly the Files surface")
    if relaunches:
        minimized_at = next(index for index, value in enumerate(states) if value["state"] == "minimized")
        closed_at = next(index for index, value in enumerate(states) if value["state"] == "closed")
        if not any(value["state"] == "restored" and value["files"] == first["files"] for value in states[minimized_at + 1:closed_at]):
            raise AssertionError("trusted compositor did not restore the retained minimized Files process")
    if acceptance and not body.rindex(MARKERS["frame"]) < body.index(MARKERS["balanced"]) < body.index(MARKERS["complete"]):
        raise AssertionError("acceptance completed before the last client presentation/cleanup")
    return {"marker_counts": counts, "pids": pids, "reaped": reaped, "reclaimed": reclaimed, "states": states, "started": [list(item) for item in started]}


def disk_evidence(data):
    """Independent bounded disk decoder; verify both committed banks and wipe tails."""
    if type(data) not in (bytes, bytearray) or len(data) != 4194304:
        raise AssertionError("invalid ordinary data artifact size")
    if NULLIFY_SECRET in data or (PREFIX + "Documents/nullify.txt").encode() in data:
        raise AssertionError("logical Nullify left fixture content or path bytes")
    banks = []
    for bank in (0, 2097152):
        header = bytearray(data[bank:bank + 512])
        if struct.unpack_from("<8sII", header) != (b"BEDFS001", 1, 512) or struct.unpack_from("<QI", header, 24) != (8192, 4096) or struct.unpack_from("<IIIQ", header, 36) != (32, 4096, 128, 137216):
            raise AssertionError("data artifact has an incompatible filesystem layout")
        if struct.unpack_from("<I", header, 68)[0] != bank // 2097152 or any(header[72:]):
            raise AssertionError("filesystem bank identity or reserved fields differ")
        checksum = struct.unpack_from("<I", header, 60)[0]
        header[60:64] = b"\0" * 4
        if binascii.crc32(header) & 0xffffffff != checksum:
            raise AssertionError("filesystem bank header checksum failed")
        generation = struct.unpack_from("<Q", header, 16)[0]
        size, crc = struct.unpack_from("<QI", header, 48)
        payload = bytes(data[bank + 512:bank + 512 + size])
        if generation == 0 or binascii.crc32(payload) & 0xffffffff != crc or any(data[bank + 512 + size:bank + 2097152]):
            raise AssertionError("filesystem payload, generation or sanitized tail failed")
        records = {}
        for index in range(32):
            record = payload[index * 4288:(index + 1) * 4288]
            if record[0] == 0:
                if any(record): raise AssertionError("unused record retained deleted bytes")
                continue
            path_length, length = struct.unpack_from("<IQ", record, 20)
            if record[0] != 1 or record[1] not in (1, 2) or not 1 <= path_length <= 128 or length > 4096:
                raise AssertionError("filesystem record bounds are invalid")
            try: name = record[64:64 + path_length].decode("ascii")
            except UnicodeDecodeError as error: raise AssertionError("filesystem path is not ASCII") from error
            if name in records or not name.startswith("/"):
                raise AssertionError("filesystem record paths collide or are not absolute")
            owner = struct.unpack_from("<Q", record, 8)[0]
            records[name] = {"kind": record[1], "owner": owner, "content": record[192:192 + length].hex()}
        banks.append({"generation": generation, "records": records, "next_serial": struct.unpack_from("<I", header, 64)[0], "payload_sha256": digest(payload)})
    if abs(banks[0]["generation"] - banks[1]["generation"]) != 1 or banks[0]["records"] != banks[1]["records"] or banks[0]["next_serial"] != banks[1]["next_serial"]:
        raise AssertionError("sanitized banks do not describe the same surviving filesystem")
    records = banks[0]["records"]
    for name, kind, content in (("Downloads/persisted.txt", 2, WELCOME), ("Documents/keepfolder", 1, b""),
                                ("Documents/created.txt", 2, b""), ("Downloads/created.txt", 2, b"")):
        if records.get(PREFIX + name) != {"kind": kind, "owner": 2, "content": content.hex()}:
            raise AssertionError("saved Files content/ownership differs: " + name)
    for name in ("Documents/nullify.txt", "Documents/persisted.txt", "Documents/welcome.txt"):
        if PREFIX + name in records:
            raise AssertionError("removed Files path survived: " + name)
    return {"sha256": digest(data), "generations": [bank["generation"] for bank in banks], "records": records}


def geometry(width, height, mode="floating", moved=False):
    if mode == "floating":
        w, h = min(width - 96, 960), min(height - 140, 620)
        x, y = (width - w) // 2 + (20 if moved else 0), 72 + (12 if moved else 0)
    elif mode == "maximized": x, y, w, h = 0, 42, width, height - 54
    else: x, y, w, h = 0, 0, width, height
    inset = 0 if mode == "fullscreen" else 2
    return {"x": x, "y": y, "width": w, "height": h, "cx": x + inset, "cy": y + inset + 32,
            "client_width": w - inset * 2, "client_height": h - inset * 2 - 32}


def shot_evidence(data, mode="floating", moved=False, visible=True):
    width, height, pixels = display.parse_ppm(data)
    g = geometry(width, height, mode, moved)
    def rgb(x, y): return pixels[(y * width + x) * 3:(y * width + x) * 3 + 3]
    border = rgb(g["x"], g["y"]) == bytes((84, 75, 89)) if mode != "fullscreen" else rgb(20, 21) == bytes((213, 150, 172))
    footer = sum(is_text_ink(rgb(x, y))
                 for y in range(g["cy"] + g["client_height"] - 24, g["cy"] + g["client_height"])
                 for x in range(g["cx"] + 8, g["cx"] + g["client_width"] - 8))
    if border is not visible or (visible and footer <= 20) or (not visible and footer != 0):
        raise AssertionError("screenshot lacks the actual Files frame/footer or retains a hidden window")
    return {"sha256": digest(data), "width": width, "height": height, "geometry": g, "visible": visible, "footer_ink": footer}


def verify_receipt(receipt, logs, screenshots, before_disk, after_disk, image=None):
    """Audit explicit artifact bytes without following paths supplied by a receipt."""
    if type(receipt) is not dict or receipt.get("status") != "passed" or receipt.get("architecture") not in runtime.ARCHITECTURES or receipt.get("mode") not in ("persistent", "acceptance"):
        raise AssertionError("malformed service desktop receipt")
    if type(logs) is not dict or set(logs) != {"first", "reboot"} or type(screenshots) is not dict or any(name not in screenshots for name in REQUIRED_SCENES):
        raise AssertionError("missing boot log or required scene artifacts")
    boots = receipt.get("boots")
    if type(boots) is not dict or set(boots) != set(logs): raise AssertionError("receipt boot evidence is missing")
    for name, relaunches in (("first", 0), ("reboot", 2)):
        item = logs[name]
        if type(item) not in (list, tuple) or len(item) != 2 or any(type(data) not in (bytes, bytearray) or len(data) > runtime.MAX_LOG_BYTES for data in item):
            raise AssertionError("invalid bounded serial/error artifacts")
        serial, stderr = item
        observed = verify_markers(bytes(serial).decode("utf-8", errors="replace"), bytes(stderr).decode("utf-8", errors="replace"), relaunches, name == "first", receipt["mode"] == "acceptance" and name == "reboot")
        recorded = boots[name]
        if type(recorded) is not dict or recorded.get("serial_sha256") != digest(serial) or recorded.get("stderr_sha256") != digest(stderr) or not same_evidence(recorded.get("evidence"), observed):
            raise AssertionError("receipt boot hashes, PIDs or marker evidence differ from captured logs")
        expected_termination = "runner-kill" if name == "first" else "guest-acceptance" if receipt["mode"] == "acceptance" else "runner-stop"
        exit_code = recorded.get("qemu_exit")
        expected_codes = (-9, 1) if name == "first" else ((33 if receipt["architecture"] == "x86_64" else 0),) if receipt["mode"] == "acceptance" else (-15, -9, 1)
        if recorded.get("termination") != expected_termination or type(exit_code) is not int or exit_code not in expected_codes:
            raise AssertionError("receipt QEMU termination differs from its owned live/acceptance profile")
        if any(type(value) is not int for value in recorded["evidence"]["marker_counts"].values()) or any(type(value) is not int for pids in recorded["evidence"]["pids"] for value in pids.values()):
            raise AssertionError("receipt numeric evidence uses non-integer values")
    before, after = disk_evidence(before_disk), disk_evidence(after_disk)
    if not same_evidence(receipt.get("before_reboot_disk"), before) or not same_evidence(receipt.get("final_disk"), after) or before != after:
        raise AssertionError("unclean reboot or window lifecycle changed durable filesystem bytes")
    if receipt.get("reboots") != 1 or type(receipt.get("reboots")) is not int or receipt.get("operations") != OPERATIONS:
        raise AssertionError("receipt omitted the complete Files and window workflow")
    if any(receipt.get(claim) is not True for claim in ("fresh_ordinary_data_image", "unclean_shutdown", "server_shell_survived_files_close", "minimize_retained_files_pid", "native_frost_verified", "owned_qemu_processes_only")):
        raise AssertionError("receipt omitted a required ownership or lifecycle proof")
    scene_records = receipt.get("scenes")
    if type(scene_records) is not dict: raise AssertionError("missing screenshot receipt evidence")
    for name in REQUIRED_SCENES:
        mode = "maximized" if name == "maximized" else "fullscreen" if name == "fullscreen" else "floating"
        moved = name not in ("initial", "preview", "listing", "maximized", "fullscreen")
        visible = name != "unobscured-wallpaper" and not name.startswith("closed-")
        actual = shot_evidence(screenshots[name], mode, moved, visible)
        if not same_evidence(scene_records.get(name), actual):
            raise AssertionError("receipt screenshot evidence differs from actual pixels: " + name)
    w, h, wallpaper = display.parse_ppm(screenshots["unobscured-wallpaper"])
    a_w, a_h, initial = display.parse_ppm(screenshots["frosted-before-minimize"])
    b_w, b_h, restored = display.parse_ppm(screenshots["frosted-restored"])
    if (w, h) != (a_w, a_h) or (w, h) != (b_w, b_h): raise AssertionError("frost scenes have different dimensions")
    g = geometry(w, h, moved=True)
    expected = []
    for fraction in (1, 2, 3):
        for y in (g["client_height"] // 2, g["client_height"] - 60):
            x, y = g["cx"] + 148 + (g["client_width"] - 148) * fraction // 4, g["cy"] + y
            reference = legacy.reference_frost(wallpaper, w, h, x, y)
            offset = (y * w + x) * 3
            if initial[offset:offset + 3] != reference or restored[offset:offset + 3] != reference:
                raise AssertionError("saved frosted material differs from immutable wallpaper reference")
            expected.append(reference)
    if len(set(expected)) <= 1: raise AssertionError("flat-color screenshots do not prove backdrop frost")
    _, _, preview = display.parse_ppm(screenshots["preview"])
    _, _, listing = display.parse_ppm(screenshots["listing"])
    if len(preview) != len(listing) or sum(a != b for a, b in zip(preview, listing)) <= 2000:
        raise AssertionError("native file preview did not differ from its listing")
    if receipt.get("image_kind") not in ("raw-image", "esp-directory", "efi-file") or type(receipt.get("image")) is not str or not receipt["image"]:
        raise AssertionError("missing boot input identity")
    if receipt["image_kind"] == "raw-image":
        value = receipt.get("image_sha256")
        if type(value) is not str or not re.fullmatch("[0-9a-f]{64}", value) or image is not None and digest(image) != value:
            raise AssertionError("raw boot image digest is missing or differs")
    live = receipt.get("seconds_live_after_final_frame")
    elapsed = receipt.get("elapsed_seconds")
    if type(live) not in (int, float) or type(elapsed) not in (int, float) or not math.isfinite(live) or not math.isfinite(elapsed) or live < 1 or elapsed < live:
        raise AssertionError("missing live compositor observation after the complete workflow")
    return {"first": boots["first"]["evidence"], "reboot": boots["reboot"]["evidence"], "disk": after}


class Machine(legacy.Machine):
    def __init__(self, args, formatter, code, variables, media, directory, data, suffix):
        super().__init__(args, directory, data, suffix)
        self.formatter, self.code, self.variables, self.media = formatter, code, variables, media
        self.log = self.error_log = None
        self.deadline = time.monotonic() + args.timeout
        self.log_path = args.artifacts / f"service-desktop-{args.arch}-{suffix}.log"
        self.error_path = args.artifacts / f"service-desktop-{args.arch}-{suffix}.stderr.log"
        self.saved_scenes = {}
        self.boot_files = args.boot_files

    def paint_ready(self):
        def complete():
            pixels = self.capture("paint-ready")
            return sum(is_text_ink(pixels[(y * self.width + x) * 3:(y * self.width + x) * 3 + 3])
                       for y in range(self.cy + self.client_height - 24, self.cy + self.client_height)
                       for x in range(self.cx + 8, self.cx + self.client_width - 8)) > 20
        self.wait(complete, "completed antialiased protected client paint", timeout=30)

    def selected_shortcut(self, index):
        def selected():
            pixels = self.capture("navigation-check")
            # The row starts at x8, its icon at x16 and label at x48. Probe
            # the clear left inset at the row center, independent of text size.
            x, y = self.cx + 14, self.cy + 88 + index * 36
            return all(pixels[((y + dy) * self.width + x + dx) * 3:
                              ((y + dy) * self.width + x + dx) * 3 + 3] == bytes((63, 60, 78))
                       for dy in (-1, 0, 1) for dx in (-1, 0, 1))
        self.wait(selected, "sidebar navigation", timeout=30)

    def error_status(self, visible):
        def complete():
            pixels = self.capture("status-check")
            # Error text stays distinctly red even with partial glyph coverage.
            count = sum(rgb[0] >= 100 and rgb[0] >= rgb[1] + 35 and rgb[0] >= rgb[2] + 35
                        for y in range(self.cy + self.client_height - 24, self.cy + self.client_height)
                        for x in range(self.cx + 12, self.cx + self.client_width - 12)
                        for rgb in (pixels[(y * self.width + x) * 3:(y * self.width + x) * 3 + 3],))
            return (count > 20) == visible
        self.wait(complete, "native operation error status", timeout=30)

    def wallpaper_ready(self, previously_visible):
        footer = [(y * self.width + x) * 3
                  for y in range(self.cy + self.client_height - 24, self.cy + self.client_height)
                  for x in range(self.cx + 8, self.cx + self.client_width - 8)
                  if is_text_ink(previously_visible[(y * self.width + x) * 3:(y * self.width + x) * 3 + 3])]
        launch = [(y * self.width + x) * 3 for y in range(36) for x in range(94, 166)
                  if previously_visible[(y * self.width + x) * 3:(y * self.width + x) * 3 + 3] in legacy.LAUNCH_TEXT_INK]
        probes = [(y * self.width + x) * 3 for x, y in self.frost_probes()]
        if len(footer) <= 20 or len(launch) <= 35: raise AssertionError("missing initial native client/bar paint")
        previous, stable, wallpaper = None, 0, None
        def complete():
            nonlocal previous, stable, wallpaper
            current = self.capture("unobscured-wallpaper")
            if (any(current[offset:offset + 3] == previously_visible[offset:offset + 3] for offset in footer + probes)
                    or any(current[offset:offset + 3] != previously_visible[offset:offset + 3] for offset in launch)):
                previous, stable = None, 0
                return False
            stable = stable + 1 if current == previous else 1
            previous = current
            if stable < 3: return False
            wallpaper = current
            return True
        self.wait(complete, "complete stable wallpaper after minimize", timeout=30)
        return wallpaper

    def edit_ready(self, prefix, name):
        def typed():
            pixels = self.capture("edit-ready")
            compact = self.client_width < 640
            leading = 20 if compact else 136
            crumb_width = self.client_width - (12 if compact else 128) - 144
            visible = max(1, (crumb_width - 16) // 8 - len(prefix) - 1)
            start = max(0, len(name) - (visible - 1))
            x = self.cx + leading + text_width(prefix + name[start:])
            ink = sum(pixels[(y * self.width + px) * 3] > 100 and
                      pixels[(y * self.width + px) * 3 + 1] < 190 and
                      pixels[(y * self.width + px) * 3 + 2] < 205
                      for y in range(self.cy + 12, self.cy + 28)
                      for px in range(x, x + text_width("|")))
            return ink >= 6
        self.wait(typed, "completed proportional name editing", timeout=30)

    def menu_geometry(self, kind, x, y):
        left, top, _, actions = super().menu_geometry(kind, x, y)
        row = min(28, (self.client_height - 8) // len(actions))
        height = len(actions) * row + 8
        return left, self.cy + max(0, min(y, self.client_height - height)), height, actions

    def menu_choose(self, action):
        x, y, height, actions = self.menu_rect
        row = (height - 8) // len(actions)
        self.click(x + 80, y + 4 + actions.index(action) * row + row // 2)
        self.menu_dismissed()

    def row_named(self, relative, pane=0):
        point = super().row_named(relative, pane)
        if type(self) is Machine:
            self._retained_row = (point, pane)
        return point

    def click(self, x, y):
        # The primary window runner supplies its own selection barrier. This
        # wrapper is only for the retained single-window profile.
        if type(self) is not Machine:
            return super().click(x, y)
        pending = getattr(self, "_retained_row", None)
        self._retained_row = None
        super().click(x, y)
        if pending is not None and pending[0] == (x, y):
            pane = pending[1]
            def selected():
                pixels = self.capture("row-selection")
                probe_x = self.cx + 148 + pane * (self.pane_width + 1) + 10
                offset = (y * self.width + probe_x) * 3
                return pixels[offset:offset + 3] == bytes((63, 60, 78))
            self.wait(selected, "Files row selection before keyboard input", timeout=30)

    def __enter__(self):
        with socket.socket() as reservation:
            reservation.bind(("127.0.0.1", 0)); port = reservation.getsockname()[1]
        command = runtime.command_line(self.args, self.code, self.variables, self.media, self.data)
        command += ["-qmp", f"tcp:127.0.0.1:{port},server=on,wait=off"]
        for path in (self.log_path, self.error_path): ordinary_output(path, self.formatter, self.boot_files)
        self.log, self.error_log = self.log_path.open("wb"), self.error_path.open("wb")
        startup = None
        if sys.platform == "win32":
            startup = subprocess.STARTUPINFO(); startup.dwFlags |= subprocess.STARTF_USESHOWWINDOW; startup.wShowWindow = 0
        try:
            self.process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=self.log, stderr=self.error_log,
                                           startupinfo=startup, creationflags=subprocess.CREATE_NO_WINDOW if sys.platform == "win32" else 0)
            while True:
                self.check()
                try: self.socket = socket.create_connection(("127.0.0.1", port), timeout=2); break
                except OSError: time.sleep(.04)
            self.reader = self.socket.makefile("rb")
            if "QMP" not in json.loads(self.reader.readline()): raise AssertionError("unexpected localhost QMP greeting")
            self.qmp("qmp_capabilities")
            self.wait(lambda: MARKERS["identities"] in self.body() and MARKERS["frame"] in self.body() and STATE_RE.search(self.body()) is not None, "actual service desktop readiness")
            verify_markers(self.body(), self.errors())
            self.capture("initial")
            self.floating_width, self.floating_height = min(self.width - 96, 960), min(self.height - 140, 620)
            self.floating_x, self.floating_y = (self.width - self.floating_width) // 2, 72
            self.split = False; self.geometry("floating"); self.visible(); self.capture("initial")
            return self
        except BaseException:
            self.__exit__(*sys.exc_info()); raise

    def __exit__(self, exception_type, *_):
        try:
            if exception_type and self.socket and self.process and self.process.poll() is None:
                try: self.capture("failure")
                except Exception: pass
            if self.process: runtime.stop_owned(self.process)
        finally:
            for handle in (self.reader, self.socket, self.log, self.error_log):
                if handle:
                    try: handle.close()
                    except OSError: pass

    def body(self): return runtime.read_log(self.log_path).replace("\r\n", "\n")
    def errors(self): return runtime.read_log(self.error_path)
    def check(self):
        if time.monotonic() >= self.deadline: raise AssertionError("service desktop scenario exceeded its bounded deadline")
        if self.process is not None and self.process.poll() is not None: raise AssertionError("service desktop ended before the host completed its workflow: " + self.errors()[-3000:])
        if "[panic]" in self.body() + self.errors() or "[fault]" in self.body() + self.errors(): raise AssertionError("service desktop reported a failure: " + self.body()[-3000:])

    def wait(self, predicate, label, timeout=90):
        deadline = min(self.deadline, time.monotonic() + timeout)
        while time.monotonic() < deadline:
            self.check()
            if predicate(): return
            time.sleep(.08)
        raise AssertionError("Timed out: " + label + "; " + self.body()[-3500:])

    def capture(self, label):
        path = self.args.artifacts / f"service-desktop-{self.args.arch}-{self.suffix}-{label}.ppm"
        for output in (path, path.with_suffix(".png")):
            ordinary_output(output, self.formatter, self.boot_files)
        self.qmp("screendump", {"filename": str(path.resolve())})
        data = path.read_bytes()
        self.width, self.height, pixels = display.parse_ppm(data)
        self.saved_scenes[label] = data
        if label in REQUIRED_SCENES:
            try:
                from PIL import Image
                with Image.open(path) as image: image.save(path.with_suffix(".png"))
            except ImportError: pass
        return pixels


def file_workflow(machine):
    # The same native Model/layout/provider used by the legacy desktop gate.
    machine.wait(lambda: machine.exists("Documents/welcome.txt"), "seeded file")
    machine.click(*machine.row_named("Documents/welcome.txt")); machine.key("f2")
    machine.edit_ready("Rename: ", "welcome.txt")
    for _ in "welcome.txt": machine.key("backspace")
    machine.text("persisted.txt"); machine.key("ret")
    machine.wait(lambda: machine.exists("Documents/persisted.txt"), "native rename")
    machine.drag(machine.row_named("Documents/persisted.txt"), machine.sidebar(2))
    machine.wait(lambda: machine.exists("Downloads/persisted.txt") and not machine.exists("Documents/persisted.txt"), "native drag move")
    machine.shortcut(2); machine.drag(machine.row_named("Downloads/persisted.txt"), machine.sidebar(1), copy=True)
    machine.wait(lambda: machine.exists("Documents/persisted.txt") and machine.exists("Downloads/persisted.txt"), "Ctrl-drag copy")
    machine.key("ctrl", False); unchanged = legacy.snapshot(machine.data)
    machine.click(*machine.row_named("Downloads/persisted.txt")); machine.toolbar(3)
    machine.shortcut(1); machine.toolbar(12); machine.error_status(True)
    if legacy.snapshot(machine.data) != unchanged: raise AssertionError("colliding copy changed durable data")
    machine.drag(machine.row_named("Documents/persisted.txt"), (machine.width - 16, machine.height - 16))
    machine.toolbar(1); machine.error_status(False)
    if legacy.snapshot(machine.data) != unchanged: raise AssertionError("invalid drop changed durable data")
    machine.key("esc"); machine.click(*machine.row_named("Documents/persisted.txt")); machine.key("delete")
    machine.wait(lambda: not machine.exists("Documents/persisted.txt"), "native delete")
    for action, prefix, name, path in ((2, "New folder: ", "keepfolder", "Documents/keepfolder"),
                                      (1, "New file: ", "created.txt", "Documents/created.txt")):
        machine.toolbar(action); machine.edit_ready(prefix, ""); machine.text(name); machine.edit_ready(prefix, name)
        machine.click(machine.cx + machine.client_width - 108, machine.cy + 20)
        machine.wait(lambda: machine.exists(path), "native mouse-confirmed creation")
    machine.click(*machine.row_named("Documents/created.txt")); machine.toolbar(3); machine.shortcut(2); machine.toolbar(12)
    machine.wait(lambda: machine.exists("Downloads/created.txt"), "clipboard Copy and Paste")
    machine.click(*machine.row_named("Downloads/persisted.txt")); machine.toolbar(4); machine.shortcut(1); machine.toolbar(12)
    machine.wait(lambda: machine.exists("Documents/persisted.txt") and not machine.exists("Downloads/persisted.txt"), "clipboard Cut and Paste")
    machine.click(*machine.row_named("Documents/persisted.txt")); machine.toolbar(3); machine.shortcut(2); machine.toolbar(12)
    machine.wait(lambda: machine.exists("Downloads/persisted.txt"), "clipboard copy of saved bytes")
    machine.shortcut(1); machine.click(*machine.row_named("Documents/persisted.txt")); machine.key("delete")
    machine.wait(lambda: not machine.exists("Documents/persisted.txt"), "delete clipboard source copy")
    machine.shortcut(2); machine.toolbar(9); machine.selected_shortcut(1); machine.toolbar(10); machine.selected_shortcut(2)
    unchanged = legacy.snapshot(machine.data)
    machine.right_click((machine.cx + machine.client_width - 20, machine.cy + machine.client_height - 40), "background")
    machine.capture("background-context-menu"); machine.key("esc"); machine.menu_dismissed()
    if legacy.snapshot(machine.data) != unchanged: raise AssertionError("dismissing a context menu mutated disk data")
    machine.shortcut(1); machine.right_click(machine.row_named("Documents/nullify.txt")); machine.capture("nullify-context-menu")
    completed, presented = machine.body().count(MARKERS["nullified"]), machine.body().count(MARKERS["nullify_frame"])
    if NULLIFY_SECRET not in machine.data.read_bytes(): raise AssertionError("missing initial Nullify fixture bytes")
    machine.menu_choose(13)
    machine.wait(lambda: machine.body().count(MARKERS["nullified"]) > completed, "two-bank Nullify readback")
    machine.wait(lambda: machine.body().count(MARKERS["nullify_frame"]) > presented, "completed Nullify result repaint")
    machine.wait(lambda: not machine.exists("Documents/nullify.txt"), "nullified path removed")
    legacy.verify_nullified_banks(machine.data); disk_evidence(machine.data.read_bytes())
    machine.paint_ready(); machine.capture("nullified")


def window_workflow(machine):
    machine.shortcut(2)
    machine.click(*machine.row_named("Downloads/persisted.txt")); machine.click(*machine.row_named("Downloads/persisted.txt"))
    time.sleep(1); preview = machine.capture("preview"); machine.key("esc"); time.sleep(.5); listing = machine.capture("listing")
    if sum(a != b for a, b in zip(preview, listing)) <= 2000: raise AssertionError("native preview did not open/dismiss")
    old_x, old_y = machine.window_x, machine.window_y
    machine.drag((old_x + 150, old_y + 18), (old_x + 170, old_y + 30))
    machine.floating_x += 20; machine.floating_y += 12; machine.geometry("floating")
    machine.visible(); machine.border(old_x, old_y, False)
    machine.control("maximize"); machine.geometry("maximized"); machine.visible(); machine.capture("maximized")
    machine.control("fullscreen"); machine.geometry("fullscreen"); machine.visible(); machine.capture("fullscreen")
    machine.control("fullscreen"); machine.geometry("maximized"); machine.visible()
    machine.control("maximize"); machine.geometry("floating"); machine.visible()
    machine.key("f11"); machine.geometry("fullscreen"); machine.visible()
    machine.key("esc"); machine.geometry("floating"); machine.visible()
    frosted_before = machine.capture("frosted-before-minimize")
    machine.control("minimize"); machine.visible(False); wallpaper = machine.wallpaper_ready(frosted_before)
    machine.click(130, 18); machine.visible(); machine.check_frost(wallpaper, frosted_before)
    # Repeated fresh launches must replace Files, retaining both desktop services.
    for index in (1, 2):
        closes = len(REAP_RE.findall(machine.body()))
        machine.control("close")
        machine.wait(lambda: len(REAP_RE.findall(machine.body())) > closes, "Files process reap")
        machine.visible(False)
        def cleared():
            machine.capture("closed-" + str(index))
            try: shot_evidence(machine.saved_scenes["closed-" + str(index)], moved=True, visible=False)
            except AssertionError: return False
            return True
        machine.wait(cleared, "closed window scanout cleared")
        launches = len(PID_RE.findall(machine.body())); frames = machine.body().count(MARKERS["frame"])
        if index == 1: machine.click(130, 18)
        else:
            machine.key("meta_l", True); machine.key("e"); machine.key("meta_l", False)
        machine.wait(lambda: len(PID_RE.findall(machine.body())) > launches and machine.body().count(MARKERS["frame"]) > frames, "fresh installed Files PID and frame")
        # The service preserves the user's floating window placement on reopen.
        machine.visible(); machine.capture("relaunch-" + str(index))
        if machine.records()[PREFIX + "Downloads/persisted.txt"]["content"] != WELCOME: raise AssertionError("Files relaunch changed private data")
    machine.toolbar(11); machine.paint_ready(); machine.capture("final")


def run(args):
    formatter = runtime.formatter_module()
    for path in (args.image, args.code, args.vars, args.artifacts): runtime.validate_path_syntax(path)
    code, variables = runtime.ordinary_file(args.code, formatter), runtime.ordinary_file(args.vars, formatter)
    media, kind = runtime.image_drive(args.image, args.arch, formatter)
    args.artifacts.mkdir(parents=True, exist_ok=True)
    if args.artifacts.is_symlink(): raise ValueError("artifact directory must not be a symbolic link")
    formatter.validate_output(args.artifacts / "owned-probe.tmp")
    boot_directory, media_files = boot_sources(args.image, kind, formatter)
    sources = [code, variables] + media_files
    args.boot_files = sources
    artifact_directory = args.artifacts.resolve()
    if kind != "raw-image" and (artifact_directory == boot_directory or boot_directory in artifact_directory.parents):
        raise ValueError("verification artifacts must not be written inside the boot ESP")
    if any(source.parent == artifact_directory and source.name.startswith(f"service-desktop-{args.arch}-") for source in sources):
        raise ValueError("verification output names must differ from every boot input")
    receipt_path = args.artifacts / f"service-desktop-{args.arch}-verification.json"
    ordinary_output(receipt_path, formatter, sources); receipt_path.unlink(missing_ok=True)
    started = time.monotonic(); logs = {}; scenes = {}; machines = {}
    try:
        with tempfile.TemporaryDirectory(prefix="bedrock-service-desktop-") as temporary:
            directory = Path(temporary); data = directory / "data.img"
            legacy.seed_owned_test_image(data, formatter)
            with Machine(args, formatter, code, variables, media, directory, data, "first") as machine:
                file_workflow(machine)
                verify_markers(machine.body(), machine.errors(), nullified=True)
                before_disk = data.read_bytes()
                machine.power_off()  # Real unclean restart, with no guest/backend shutdown flush.
            machines["first"] = machine; logs["first"] = (machine.log_path.read_bytes(), machine.error_path.read_bytes())
            scenes["initial"] = machine.saved_scenes["initial"]
            with Machine(args, formatter, code, variables, media, directory, data, "reboot") as machine:
                if disk_evidence(data.read_bytes()) != disk_evidence(before_disk): raise AssertionError("reboot changed committed Files data")
                window_workflow(machine)
                ready_at = time.monotonic()
                while time.monotonic() - ready_at < 1:
                    machine.check(); time.sleep(.04)
                live = time.monotonic() - ready_at
                if args.acceptance:
                    machine.key("f12")
                    while machine.process.poll() is None:
                        if time.monotonic() >= machine.deadline: raise AssertionError("service desktop acceptance did not finish after host F12")
                        time.sleep(.04)
                    if machine.process.returncode != (33 if args.arch == "x86_64" else 0): raise AssertionError("service desktop acceptance exited unsuccessfully")
                verify_markers(machine.body(), machine.errors(), 2, acceptance=args.acceptance)
                after_disk = data.read_bytes()
            machines["reboot"] = machine; logs["reboot"] = (machine.log_path.read_bytes(), machine.error_path.read_bytes())
            scenes.update({name: machine.saved_scenes[name] for name in REQUIRED_SCENES if name != "initial"})
            receipt = {
                "status": "passed", "architecture": args.arch, "mode": "acceptance" if args.acceptance else "persistent",
                "image": str(args.image.resolve()), "image_kind": kind, "reboots": 1, "operations": OPERATIONS,
                "fresh_ordinary_data_image": True, "unclean_shutdown": True, "owned_qemu_processes_only": True,
                "server_shell_survived_files_close": True, "minimize_retained_files_pid": True, "native_frost_verified": True,
                "seconds_live_after_final_frame": live, "elapsed_seconds": time.monotonic() - started,
                "before_reboot_disk": disk_evidence(before_disk), "final_disk": disk_evidence(after_disk),
                "boots": {}, "scenes": {},
            }
            if kind == "raw-image": receipt["image_sha256"] = digest(args.image.read_bytes())
            for name, (serial, stderr) in logs.items():
                receipt["boots"][name] = {"serial_sha256": digest(serial), "stderr_sha256": digest(stderr),
                                           "qemu_exit": machines[name].process.returncode,
                                           "termination": "runner-kill" if name == "first" else "guest-acceptance" if args.acceptance else "runner-stop",
                                           "evidence": verify_markers(serial.decode(errors="replace"), stderr.decode(errors="replace"), 2 if name == "reboot" else 0, name == "first", args.acceptance and name == "reboot")}
            for name, pixels in scenes.items():
                mode = "maximized" if name == "maximized" else "fullscreen" if name == "fullscreen" else "floating"
                moved = name not in ("initial", "preview", "listing", "maximized", "fullscreen")
                receipt["scenes"][name] = shot_evidence(pixels, mode, moved, name != "unobscured-wallpaper" and not name.startswith("closed-"))
            verify_receipt(receipt, logs, scenes, before_disk, after_disk)
            for label, artifact in (("before-reboot", before_disk), ("final-data", after_disk)):
                path = args.artifacts / f"service-desktop-{args.arch}-{label}.img"
                ordinary_output(path, formatter, sources); path.write_bytes(artifact)
            receipt_path.write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
    except BaseException:
        for suffix in ("first", "reboot"):
            for extension in (".log", ".stderr.log"):
                path = args.artifacts / f"service-desktop-{args.arch}-{suffix}{extension}"
                if path.exists(): print(runtime.read_log(path)[-5000:], file=sys.stderr)
        raise
    print(f"{args.arch}: installed service desktop passed; native Files/window/frost input, two fresh Files PIDs, logical Nullify and unclean reboot")
    print(f"Verification receipt: {receipt_path}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--arch", required=True, choices=runtime.ARCHITECTURES)
    media = parser.add_mutually_exclusive_group(required=True)
    media.add_argument("--esp", type=Path); media.add_argument("--image", type=Path)
    parser.add_argument("--qemu"); parser.add_argument("--code", type=Path); parser.add_argument("--vars", type=Path)
    parser.add_argument("--ram-mib", type=int, default=256); parser.add_argument("--timeout", type=float, default=180)
    parser.add_argument("--acceptance", action="store_true")
    parser.add_argument("--artifacts", type=Path, default=ROOT / "zig-out/service-desktop-tests")
    args = parser.parse_args()
    if not math.isfinite(args.timeout) or not 30 <= args.timeout <= 600: parser.error("timeout must be finite and between 30 and 600 seconds per boot")
    if not 256 <= args.ram_mib <= 65536: parser.error("ram-mib must be between 256 and 65536")
    qemu, code, variables = runtime.default_paths(args.arch)
    args.qemu, args.code, args.vars = args.qemu or qemu, args.code or code, args.vars or variables
    args.image = args.image or args.esp
    try: run(args)
    except (AssertionError, ValueError, OSError, subprocess.SubprocessError) as error:
        print(f"Service desktop verification failed: {error}", file=sys.stderr); return 1
    return 0


if __name__ == "__main__": sys.exit(main())
