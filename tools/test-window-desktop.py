#!/usr/bin/env python3
"""Exercise independent native windows through owned QEMU and real VirtIO input."""
import argparse
import hashlib
import json
import math
from pathlib import Path
import re
import socket
import subprocess
import sys
import tempfile
import time
import importlib.util

ROOT = Path(__file__).resolve().parent.parent

def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, ROOT / "tools" / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

service = load("bedrock_window_helpers", "test-service-desktop.py")
legacy, runtime, display = service.legacy, service.runtime, service.display
digest = service.digest
text_width = service.text_width
ICON_MANIFEST = ROOT / "frameworks/public/AxisUI/icon-coverage.json"

def caption_icon_probes():
    """Opaque pixels from the original vector renderer, independent of glass tint."""
    manifest = json.loads(ICON_MANIFEST.read_text(encoding="utf-8"))
    source = manifest.get("source", {})
    if manifest.get("size") != 16 or source.get("path") != "src/icons.zig" or source.get("sha256") != digest((ICON_MANIFEST.parent / "src/icons.zig").read_bytes()):
        raise AssertionError("stale or invalid native icon coverage manifest")
    result = {}
    for name in ("minimize", "maximize", "restore", "close"):
        coverage = manifest.get("icons", {}).get(name)
        if not isinstance(coverage, list) or len(coverage) != 256 or any(type(value) is not int or not 0 <= value <= 255 for value in coverage):
            raise AssertionError("invalid native caption icon coverage")
        result[name] = tuple((offset % 16, offset // 16) for offset, value in enumerate(coverage) if value == 255)
        if not result[name]: raise AssertionError("native caption icon lacks opaque probes")
    return result

CAPTION_ICON_PROBES = caption_icon_probes()
NOTES_PATH = "/container/000000000000006c/notes.txt"
NOTE = b"bedrock native notes\n"
START = re.compile(r"^\[kernel\] window process started pid=([0-9]+) app=([0-9]+)$", re.M)
RECLAIM = re.compile(r"^\[kernel\] window generation reclaimed pid=([0-9]+) app=(2|108)$", re.M)
REAP = re.compile(r"^\[window-init\] (Files|Notes) process reaped pid=([0-9]+) status=([0-9]+)$", re.M)
FAULT = re.compile(r"^\[kernel\] window process fault pid=([0-9]+) app=([0-9]+)$", re.M)
STATE = re.compile(r"^\[kernel\] window desktop state state=(ready|minimized|closed|relaunched|maximized|fullscreen|restored|resized|workspace|tiled|focused) app=([0-9]+) aux=([0-9]+) server_pid=([0-9]+) shell_pid=([0-9]+) files_pid=([0-9]+) notes_pid=([0-9]+) surface_count=([0-9]+) process_count=([0-9]+)$", re.M)
CONFIG = re.compile(r"^\[window-server\] configured app=(2|108) pid=([0-9]+) epoch=([0-9]+) frame_x=([0-9]+) frame_y=([0-9]+) frame_w=([0-9]+) frame_h=([0-9]+) visible=([01]) mode=(floating|maximized|fullscreen) header_content=([01]) window_id=([0-9]+) header_tabs=([01])$", re.M)
WINDOW_RETIRED = re.compile(r"^\[window-server\] window retired app=(2|108) pid=([0-9]+) window_id=([0-9]+)$", re.M)
MARKERS = ("[bootloader] application archive staged", "[kernel] protected surface broker ready",
           "[window-server] native window compositor ready", "[window-shell] protected shell ready",
           "[window-init] protected windows ready", "[kernel] window desktop identities verified")
FIRST_SCENES = ("initial", "path-edited", "path-rejected", "notes-saved", "files-workflow")
SCENES = FIRST_SCENES + ("tiled", "workspace-empty", "workspace-return",
          "resized", "fullscreen", "minimized-notes", "closed-files", "relaunched-files",
          "closed-notes", "relaunched-notes", "final")
OPERATIONS = ["editable_native_toolbar_path", "invalid_path_preserves_directory", "right_hand_window_controls",
              "private_notes_save", "native_files_operations", "logical_nullify", "unclean_reboot",
              "two_visible_tiled_clients", "focus_keyboard_routing", "workspace_switch",
              "move_window_between_workspaces", "floating_resize", "fullscreen_escape",
              "floating_caption_drag", "keyboard_focus_cycle", "minimize_restore", "independent_files_close_relaunch", "independent_notes_close_relaunch"]

def normalized(serial):
    return serial.decode(errors="replace").replace("\r\n", "\n") if isinstance(serial, bytes) else serial.replace("\r\n", "\n")

def states(body):
    return [dict(zip(("state", "app", "aux", "server", "shell", "files", "notes", "surfaces", "processes"),
                     (row[0], *(int(value) for value in row[1:])))) for row in STATE.findall(body)]

def verify_log(serial, stderr, lifecycle=False, acceptance=False):
    body = normalized(serial)
    errors = normalized(stderr)
    if "\r" in body: raise AssertionError("embedded carriage return in serial evidence")
    if any(value in body + errors for value in ("[panic]", "[fault]", "InstalledApplicationArchiveMissing")):
        raise AssertionError("native window desktop reported a failure")
    if any(value in body for value in ("[desktop-init]", "[desktop-server]", "[desktop-shell]", "[desktop-files]", "[kernel] service desktop acceptance", "[kernel] display acceptance complete", "[kernel] application runtime acceptance complete")):
        raise AssertionError("alternate desktop profile supplied evidence")
    for marker in MARKERS:
        if body.count(marker) != 1: raise AssertionError("missing/duplicate native window marker: " + marker)
    for prefix, pattern in (("[kernel] window process started", START), ("[kernel] window generation reclaimed", RECLAIM),
                            ("[window-init] Files process reaped", REAP), ("[window-init] Notes process reaped", REAP),
                            ("[kernel] window desktop state", STATE), ("[kernel] window process fault", FAULT),
                            ("[window-server] configured app=2 ", CONFIG), ("[window-server] configured app=108 ", CONFIG),
                            ("[window-server] window retired ", WINDOW_RETIRED)):
        for line in body.splitlines():
            if line.startswith(prefix) and not pattern.fullmatch(line): raise AssertionError("malformed native window evidence: " + line)
    started = [(int(pid), int(app)) for pid, app in START.findall(body)]
    if len({pid for pid, _ in started}) != len(started) or any(pid <= 0 for pid, _ in started): raise AssertionError("reused/colliding process generation")
    if any(app not in (101, 104, 107, 2, 108) for _, app in started): raise AssertionError("unexpected installed identity")
    identities = {app: [pid for pid, candidate in started if candidate == app] for app in (101, 104, 107, 2, 108)}
    if any(len(identities[app]) != 1 for app in (101, 104, 107)): raise AssertionError("desktop supervisor/service restarted")
    notes_restarts = int(lifecycle) + int(acceptance)
    if len(identities[2]) != 1 + int(lifecycle) or len(identities[108]) != 1 + notes_restarts: raise AssertionError("missing independent app generations")
    for app, name in ((2, "files"), (108, "notes")):
        for marker in (f"[window-{name}] protected {name.title()} ready", f"[window-{name}] authority checks passed", f"[window-{name}] frame presented"):
            if body.count(marker) != len(identities[app]): raise AssertionError("client authority/presentation generations differ")
    reaped = [(108 if name == "Notes" else 2, int(pid), int(status)) for name, pid, status in REAP.findall(body)]
    reclaimed = [(int(app), int(pid)) for pid, app in RECLAIM.findall(body)]
    expected = []
    if lifecycle: expected += [(2, identities[2][0], 0), (108, identities[108][0], 0)]
    if acceptance: expected += [(108, identities[108][1], 139)]
    if reaped != expected: raise AssertionError("close/crash status or independent reap order differs")
    expected_reclaimed = [(app, pid) for app, pid, _ in expected]
    if acceptance: expected_reclaimed += [(2, identities[2][-1]), (108, identities[108][-1])]
    if sorted(reclaimed) != sorted(expected_reclaimed) or len(reclaimed) != len(expected_reclaimed): raise AssertionError("unbalanced app generation reclamation")
    for app, pid, _ in expected:
        reclaim = next(match.start() for match in RECLAIM.finditer(body) if int(match[1]) == pid and int(match[2]) == app)
        reap = next(match.start() for match in REAP.finditer(body) if int(match[2]) == pid)
        next_pid = identities[app][identities[app].index(pid) + 1]
        start = next(match.start() for match in START.finditer(body) if int(match[1]) == next_pid)
        if not reclaim < reap < start: raise AssertionError("relaunch preceded resource reclamation")
    faulted = [(int(pid), int(app)) for pid, app in FAULT.findall(body)]
    if faulted != ([(identities[108][1], 108)] if acceptance else []): raise AssertionError("actual contained CPU fault evidence differs")
    if body.count("[window-notes] deliberate startup write fault requested") != int(acceptance): raise AssertionError("test-only fault trigger differs")
    if acceptance:
        pid = identities[108][1]
        fault = FAULT.search(body).start()
        reclaim = next(match.start() for match in RECLAIM.finditer(body) if int(match[1]) == pid)
        trigger = body.index("[window-notes] deliberate startup write fault requested")
        if not trigger < fault < reclaim: raise AssertionError("CPU fault preceded trigger or followed recovery")
    observations = states(body)
    live = {}
    timeline = [(match.start(), "start", match) for match in START.finditer(body)] + [(match.start(), "reclaim", match) for match in RECLAIM.finditer(body)] + [(match.start(), "state", match) for match in STATE.finditer(body)]
    for _, kind, match in sorted(timeline, key=lambda event: event[0]):
        if kind == "start":
            pid, app = int(match[1]), int(match[2])
            if app in live: raise AssertionError("concurrent generations for one app")
            live[app] = pid
        elif kind == "reclaim":
            pid, app = int(match[1]), int(match[2])
            if live.pop(app, None) != pid: raise AssertionError("reclaimed an inactive generation")
        else:
            event = states(match[0])[0]
            for app, name in ((104, "server"), (107, "shell"), (2, "files"), (108, "notes")):
                if event[name] != live.get(app, 0): raise AssertionError("state named future or retired generation")
            if event["state"] == "closed":
                other = 108 if event["app"] == 2 else 2
                if other not in live: raise AssertionError("independent close also stopped other app")
    ready = [event for event in observations if event["state"] == "ready"]
    if len(ready) != 1: raise AssertionError("missing/duplicate trusted ready state")
    if ready[0]["surfaces"] != 6 or ready[0]["processes"] != 5: raise AssertionError("incorrect live desktop baseline")
    for state_match, event in zip(STATE.finditer(body), observations):
        if event["server"] != identities[104][0] or event["shell"] != identities[107][0]: raise AssertionError("service identity continuity lost")
        count = 0
        for app, name in ((2, "files"), (108, "notes")):
            if event[name] and event[name] not in identities[app]: raise AssertionError("forged app identity in trusted state")
            count += int(event[name] != 0)
        bound_windows = sum(frame["pid"] != 0 for frame in window_configurations(body[:state_match.end()]).values())
        if event["surfaces"] != 2 + 2 * bound_windows or event["processes"] != 3 + count:
            raise AssertionError("window producers/caches or app processes were not balanced")
        if event["state"] == "closed" and (event["app"] not in (2, 108) or event["files" if event["app"] == 2 else "notes"] != 0): raise AssertionError("closed app retained live identity")
    if lifecycle:
        for label in ("tiled", "workspace", "focused", "resized", "fullscreen", "minimized", "closed", "relaunched"):
            if not any(event["state"] == label for event in observations): raise AssertionError("missing window operation: " + label)
        for app in (2, 108):
            if not any(event["state"] == "closed" and event["app"] == app for event in observations): raise AssertionError("missing independent app close")
        if {event["aux"] for event in observations if event["state"] == "workspace"} != {0, 1, 2, 3}: raise AssertionError("not all four workspaces were exercised")
    for marker in ("[kernel] window desktop teardown balanced", "[kernel] window desktop acceptance complete"):
        if body.count(marker) != int(acceptance): raise AssertionError("profile teardown mode differs")
    return {"started": [list(row) for row in started], "reaped": [list(row) for row in reaped], "reclaimed": [list(row) for row in reclaimed], "faults": [list(row) for row in faulted], "states": observations}

def window_configurations(body):
    """Track each actual window independently; process identity is shared."""
    body = normalized(body)
    result, epochs, retired = {}, {}, set()
    events = ([(match.start(), "config", match) for match in CONFIG.finditer(body)] +
              [(match.start(), "state", match) for match in STATE.finditer(body)] +
              [(match.start(), "retired", match) for match in WINDOW_RETIRED.finditer(body)])
    for _, kind, match in sorted(events, key=lambda event: event[0]):
        if kind == "state":
            if match[1] == "closed":
                for key in tuple(result):
                    if key[0] == int(match[2]):
                        if key[1] == 0:
                            result[key] = {**result[key], "visible": False, "pid": 0}
                        else:
                            del result[key]
            continue
        if kind == "retired":
            app, pid, window_id = map(int, match.groups())
            key = app, window_id
            if key not in result or result[key]["pid"] != pid:
                raise AssertionError("retired an inactive/foreign native window")
            retired.add((app, pid, window_id))
            if window_id == 0:
                result[key] = {**result[key], "visible": False, "pid": 0}
            else:
                del result[key]
            continue
        row = match.groups()
        app, pid, epoch, x, y, width, height, visible = map(int, row[:8])
        window_id, header_tabs = map(int, row[10:12])
        key = app, window_id
        if window_id > 65535 or (app, pid, window_id) in retired:
            raise AssertionError("reused or invalid native window identity")
        live_pid = None
        for event in sorted([(m.start(), True, m) for m in START.finditer(body[:match.start()])] + [(m.start(), False, m) for m in RECLAIM.finditer(body[:match.start()])], key=lambda item: item[0]):
            _, started, item = event
            if int(item[2]) == app: live_pid = int(item[1]) if started else None
        if live_pid != pid: raise AssertionError("configure names an inactive/foreign process")
        if epoch == 0 or epoch <= epochs.get((app, pid, window_id), 0): raise AssertionError("stale configure epoch")
        if int(row[9]) != int(app == 2): raise AssertionError("primary app header contract differs")
        if header_tabs != int(app == 2): raise AssertionError("native tab caption contract differs")
        epochs[(app, pid, window_id)] = epoch
        result[key] = {"pid": pid, "epoch": epoch, "x": x, "y": y, "width": width, "height": height, "visible": bool(visible),
                       "mode": row[8], "header_content": bool(int(row[9])), "window_id": window_id, "header_tabs": bool(header_tabs)}
    return result

def configurations(body):
    """Legacy two-app gates refer only to each app's original window, ID zero."""
    return {app: frame for (app, window_id), frame in window_configurations(body).items() if window_id == 0}

def client_geometry(frame):
    inset = 0 if frame["mode"] == "fullscreen" else 2
    return {**frame, "cx": frame["x"] + inset, "cy": frame["y"] + inset + 32,
            "client_width": frame["width"] - inset * 2, "client_height": frame["height"] - inset * 2 - 32}

def caption_geometry(frame, control):
    """Trusted native caption hitboxes; icons are centered inside each target."""
    g = client_geometry(frame)
    inset = 0 if frame["mode"] == "fullscreen" else 2
    return {"x": g["cx"] + g["client_width"] - {"minimize": 138, "maximize": 92, "close": 46}[control],
            "y": frame["y"] + inset, "width": 46, "height": 32}

def files_path_geometry(frame):
    """Files' editable location field lives in the navigation toolbar."""
    g = client_geometry(frame)
    trailing = 116 if g["client_width"] >= 640 else 64
    return {"x": g["cx"] + 128, "y": g["cy"] + 4,
            "width": g["client_width"] - 128 - trailing, "height": 32}

def files_tabs_geometry(frame, count, active):
    """Client-local AxisUI tabs translated into the trusted caption accessory."""
    if type(count) is not int or type(active) is not int or not 1 <= count <= 8 or not 0 <= active < count:
        raise AssertionError("invalid Files tab count/selection")
    g = client_geometry(frame)
    tabs_only = frame.get("header_tabs", True)
    bounds = {"x": g["cx"] + (8 if tabs_only else 104), "y": g["cy"] - 28,
              "width": g["client_width"] - (154 if tabs_only else 250), "height": 24}
    available = bounds["width"] - 24
    arrows = available < count * 72 and available >= 112
    tabs_width = available - (40 if arrows else 0)
    visible = min(count, max(1, tabs_width // 72))
    first = min(max(0, active - (visible - 1) // 2), count - visible)
    tab_width = min(160, tabs_width // visible)
    tabs, close = {}, {}
    for index in range(first, first + visible):
        rect = {"x": bounds["x"] + (index - first) * tab_width, "y": bounds["y"], "width": tab_width, "height": bounds["height"]}
        tabs[index] = rect
        close[index] = {"x": rect["x"] + rect["width"] - 20, "y": rect["y"] + 4, "width": 16, "height": 16}
    add_x = bounds["x"] + (bounds["width"] - 24 if arrows else visible * tab_width)
    return {"bounds": bounds, "tabs": tabs, "close": close, "first": first, "visible": visible,
            "add": {"x": add_x, "y": bounds["y"], "width": 24, "height": bounds["height"]}}

def scene_evidence(data, body):
    width, height, pixels = display.parse_ppm(data)
    frames = configurations(body)
    if set(frames) != {2, 108}: raise AssertionError("missing native client configure evidence")
    result = {}
    for app, frame in frames.items():
        if not (320 <= frame["width"] <= width and 240 <= frame["height"] <= height and 0 <= frame["x"] <= width - frame["width"] and 0 <= frame["y"] <= height - frame["height"]): raise AssertionError("configure geometry exceeds actual screen")
        g = client_geometry(frame)
        ink, error_ink = 0, 0
        for y in range(g["cy"] + g["client_height"] - 30, g["cy"] + g["client_height"] - 4):
            row = pixels[(y * width + g["cx"] + 8) * 3:(y * width + g["cx"] + g["client_width"] - 8) * 3]
            ink += sum(service.is_text_ink(row[offset:offset + 3]) for offset in range(0, len(row), 3))
            error_ink += sum(row[offset] >= 100 and row[offset] >= row[offset + 1] + 35 and row[offset] >= row[offset + 2] + 35
                             for offset in range(0, len(row), 3))
        header = {}
        for control in ("minimize", "maximize", "close"):
            rect = caption_geometry(frame, control)
            x, y = rect["x"], rect["y"]
            icon = "restore" if control == "maximize" and frame["mode"] == "maximized" else control
            glyph = tuple((x + 15 + dx, y + 8 + dy) for dx, dy in CAPTION_ICON_PROBES[icon])
            glyph_ink = sum(pixels[(py * width + px) * 3:(py * width + px) * 3 + 3] == bytes((217, 221, 232)) for px, py in glyph)
            header[control] = {**rect, "glyph_pixels": glyph_ink, "expected_glyph_pixels": len(glyph)}
        result[str(app)] = {**frame, "footer_ink": ink, "error_ink": error_ink, "header_controls": header}
    return {"sha256": digest(data), "width": width, "height": height, "windows": result}

def disk_evidence(data):
    value = service.disk_evidence(data)
    if value["records"].get(NOTES_PATH) != {"kind": 2, "owner": 108, "content": NOTE.hex()}: raise AssertionError("Notes bytes did not persist in its own private container")
    if value["records"].get(service.PREFIX + "Desktop") != {"kind": 1, "owner": 2, "content": ""}: raise AssertionError("Files Desktop directory did not persist in its own private container")
    return value

PATH_EVENTS = ("[window-files] path editing", "[window-files] path navigated path=/container/Downloads",
               "[window-files] path editing", "[window-files] path rejected",
               "[window-files] path editing", "[window-files] path rejected",
               "[window-files] path editing", "[window-files] path navigated path=/container/Documents")

def path_events(body):
    return tuple(line for line in normalized(body).splitlines() if line.startswith("[window-files] path "))

def verify_receipt(receipt, logs, scenes, before, after, image=None):
    if type(receipt) is not dict or receipt.get("status") != "passed" or receipt.get("architecture") not in runtime.ARCHITECTURES or receipt.get("mode") not in ("persistent", "acceptance"): raise AssertionError("invalid native window receipt")
    acceptance = receipt["mode"] == "acceptance"
    if set(logs) != {"first", "reboot"} or set(scenes) != set(SCENES) | ({"fault-notes"} if acceptance else set()): raise AssertionError("missing captured boot/scenes")
    for name, (serial, stderr) in logs.items():
        record = receipt["boots"][name]
        evidence = verify_log(serial, stderr, name == "reboot", acceptance and name == "reboot")
        if not service.same_evidence(record["evidence"], evidence) or record["serial_sha256"] != digest(serial) or record["stderr_sha256"] != digest(stderr): raise AssertionError("receipt differs from captured serial")
        expected_codes = (-9, 1) if name == "first" else ((33 if receipt["architecture"] == "x86_64" else 0),) if acceptance else (-15, -9, 1)
        if type(record["qemu_exit"]) is not int or record["qemu_exit"] not in expected_codes: raise AssertionError("owned QEMU exit differs from mode")
    if not service.same_evidence(receipt["before_reboot_disk"], disk_evidence(before)) or not service.same_evidence(receipt["final_disk"], disk_evidence(after)) or before != after: raise AssertionError("durable app data changed during lifecycle/reboot")
    for name, data in scenes.items():
        record = receipt["scenes"][name]
        boot = "first" if name in FIRST_SCENES else "reboot"
        body = normalized(logs[boot][0])
        count = record["serial_characters"]
        if type(count) is not int or not 0 < count <= len(body): raise AssertionError("invalid screenshot serial boundary")
        prefix = body[:count]
        if digest(prefix.encode()) != record["serial_prefix_sha256"] or not service.same_evidence(record["pixels"], scene_evidence(data, prefix)): raise AssertionError("screenshot/configuration evidence differs")
    tiled = receipt["scenes"]["tiled"]["pixels"]
    a, b = tiled["windows"]["2"], tiled["windows"]["108"]
    if not a["visible"] or not b["visible"] or min(a["footer_ink"], b["footer_ink"]) <= 20 or sorted((a["x"], b["x"])) != [0, tiled["width"] // 2] or a["width"] + b["width"] != tiled["width"]: raise AssertionError("actual tiled screenshot lacks two painted native clients")
    if any(frame["visible"] or frame["footer_ink"] > 20 for frame in receipt["scenes"]["workspace-empty"]["pixels"]["windows"].values()): raise AssertionError("workspace switch left clients visible")
    minimum = receipt["scenes"]["resized"]["pixels"]["windows"]["2"]
    if (minimum["width"], minimum["height"]) != (320, 240) or minimum["footer_ink"] <= 20: raise AssertionError("minimum resized Files viewport did not paint safely")
    for label in ("path-edited", "path-rejected"):
        window = receipt["scenes"][label]["pixels"]["windows"]["2"]
        if not window["visible"] or window["footer_ink"] <= 20 or any(control["glyph_pixels"] != control["expected_glyph_pixels"] for control in window["header_controls"].values()):
            raise AssertionError("actual right-hand caption controls were erased or not painted")
        prefix = normalized(logs["first"][0])[:receipt["scenes"][label]["serial_characters"]]
        if path_events(prefix) != PATH_EVENTS[:2 if label == "path-edited" else 6]:
            raise AssertionError("path screenshot preceded its actual editing result")
        if label == "path-rejected" and window["error_ink"] <= 20:
            raise AssertionError("path screenshot lacks the actual rejection status paint")
    first = normalized(logs["first"][0])
    if path_events(first) != PATH_EVENTS:
        raise AssertionError("editable header did not complete native path acceptance/rejection workflow")
    if receipt.get("operations") != OPERATIONS + (["contained_notes_fault_recovery"] if acceptance else []) or type(receipt.get("reboots")) is not int or receipt["reboots"] != 1: raise AssertionError("missing complete native window workflow")
    if receipt.get("owned_qemu_processes_only") is not True or receipt.get("unclean_shutdown") is not True: raise AssertionError("missing owned process/unclean restart evidence")
    if image is not None and receipt.get("image_sha256") != digest(image): raise AssertionError("boot image differs")
    return True

class Machine(service.Machine):
    def __init__(self, *args):
        super().__init__(*args)
        self.log_path = self.args.artifacts / f"window-desktop-{self.args.arch}-{self.suffix}.log"
        self.error_path = self.args.artifacts / f"window-desktop-{self.args.arch}-{self.suffix}.stderr.log"
        self.scene_records = {}
        self.split = False
        self.pending_row = None

    def __enter__(self):
        with socket.socket() as reservation:
            reservation.bind(("127.0.0.1", 0)); port = reservation.getsockname()[1]
        command = runtime.command_line(self.args, self.code, self.variables, self.media, self.data)
        command += ["-qmp", f"tcp:127.0.0.1:{port},server=on,wait=off"]
        for path in (self.log_path, self.error_path): service.ordinary_output(path, self.formatter, self.boot_files)
        self.log, self.error_log = self.log_path.open("wb"), self.error_path.open("wb")
        startup = None
        if sys.platform == "win32":
            startup = subprocess.STARTUPINFO(); startup.dwFlags |= subprocess.STARTF_USESHOWWINDOW; startup.wShowWindow = 0
        try:
            self.process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=self.log, stderr=self.error_log, startupinfo=startup, creationflags=subprocess.CREATE_NO_WINDOW if sys.platform == "win32" else 0)
            while True:
                self.check()
                try: self.socket = socket.create_connection(("127.0.0.1", port), timeout=2); break
                except OSError: time.sleep(.04)
            self.reader = self.socket.makefile("rb")
            if "QMP" not in json.loads(self.reader.readline()): raise AssertionError("unexpected owned QMP greeting")
            self.qmp("qmp_capabilities")
            self.wait(lambda: MARKERS[-1] in self.body() and STATE.search(self.body()) is not None, "independent native window readiness")
            verify_log(self.body(), self.errors())
            self.capture("initial")
            self.geometry("floating")
            return self
        except BaseException:
            self.__exit__(*sys.exc_info()); raise

    def capture(self, label):
        path = self.args.artifacts / f"window-desktop-{self.args.arch}-{self.suffix}-{label}.ppm"
        for output in (path, path.with_suffix(".png")): service.ordinary_output(output, self.formatter, self.boot_files)
        self.qmp("screendump", {"filename": str(path.resolve())})
        data = path.read_bytes()
        self.width, self.height, pixels = display.parse_ppm(data)
        self.saved_scenes[label] = data
        body = self.body()
        if label in SCENES or label == "fault-notes":
            self.scene_records[label] = {"serial_characters": len(body), "serial_prefix_sha256": digest(body.encode()), "pixels": scene_evidence(data, body)}
            try:
                from PIL import Image
                with Image.open(path) as image: image.save(path.with_suffix(".png"))
            except ImportError: pass
        return pixels

    def geometry(self, mode="floating"):
        g = client_geometry(configurations(self.body())[2])
        self.mode = g["mode"]
        self.window_x, self.window_y, self.window_width, self.window_height = g["x"], g["y"], g["width"], g["height"]
        self.inset = 0 if self.mode == "fullscreen" else 2
        self.cx, self.cy, self.client_width, self.client_height = g["cx"], g["cy"], g["client_width"], g["client_height"]
        self.pane_width = (self.client_width - 149) // 2 if self.split else self.client_width - 148

    def hotkey(self, key, *modifiers):
        for modifier in modifiers: self.key(modifier, True)
        self.key(key)
        for modifier in reversed(modifiers): self.key(modifier, False)

    def toolbar(self, index):
        # Exercise the same navigation shortcuts across the retained desktop
        # profiles; the focused tab gate also clicks the visible arrow buttons.
        if index in (9, 10):
            self.hotkey("left" if index == 9 else "right", "alt")
        elif index == 0:
            self.key("backspace")
        else:
            super().toolbar(index)

    def text(self, value):
        keys = {".": "dot", "/": "slash", " ": "spc", "-": "minus", "`": "grave_accent"}
        shifted = {"~": "grave_accent", "_": "minus"}
        for char in value:
            if char in shifted or char.isupper():
                self.hotkey(shifted.get(char, char.lower()), "shift")
            else:
                self.key(keys.get(char, char))

    def row_named(self, relative, pane=0):
        point = super().row_named(relative, pane)
        self.pending_row = point
        return point

    def click(self, x, y):
        row = self.pending_row == (x, y)
        self.pending_row = None
        def selected():
            pixels = self.capture("row-selection")
            probe_x = self.cx + 148 + self.pane_width - 120
            offset = (y * self.width + probe_x) * 3
            return pixels[offset:offset + 3] == bytes((63, 60, 78))
        already = selected() if row else False
        super().click(x, y)
        if row and not already: self.wait(selected, "Files row selection before keyboard input", timeout=30)

    def drag(self, source, destination, copy=False):
        if copy:
            # Keyboard and tablet are independently polled. A real Ctrl+C
            # result fences the modifier before the pointer starts a drag;
            # the clipboard operation changes no persistent file bytes.
            self.click(*source)
            metrics = service.font_metrics()
            # This fixture's Downloads folder contains one file. Successful
            # Ctrl+C adds the visible clipboard suffix to its ordinary count.
            probes = [(x, y) for x, y, alpha in service.font_samples("1 item / clipboard ready") if alpha == 255]
            if len(probes) < 20: raise AssertionError("insufficient opaque status glyph probes")
            def copied():
                pixels = self.capture("control-modifier-ready")
                inset = min(7, max(0, 24 - metrics["line_height"]) // 2)
                x = self.cx + inset
                y = self.cy + self.client_height - 24 + service.control_text_origin(0, 24)
                return all(pixels[((y + dy) * self.width + x + dx) * 3:((y + dy) * self.width + x + dx) * 3 + 3] == bytes((173, 179, 195))
                           for dx, dy in probes)
            if copied(): raise AssertionError("modifier fence began with an existing copied status")
            self.key("ctrl", True)
            self.key("c")
            self.wait(copied, "actual Ctrl+C paint before Ctrl-drag")
        super().drag(source, destination, copy=False)

    def focus_app(self, app):
        marker = f"[window-shell] {'Files' if app == 2 else 'Notes'} launch requested"
        before = self.body().count(marker)
        self.click(130 if app == 2 else 214, 18)
        def focused():
            events = [event for event in states(self.body()) if event["state"] == "focused"]
            return self.body().count(marker) > before and events and events[-1]["app"] == app and events[-1]["aux"] == configurations(self.body())[app]["pid"]
        self.wait(focused, "focused app")
        self.geometry()

    def app_control(self, app, control, label=None):
        self.focus_app(app)
        g = client_geometry(configurations(self.body())[app])
        before = len(states(self.body()))
        if control == "fullscreen":
            self.key("f11")
        else:
            rect = caption_geometry(g, control)
            self.click(rect["x"] + rect["width"] // 2, rect["y"] + rect["height"] // 2)
        if label: self.wait(lambda: any(event["state"] == label and event["app"] == app for event in states(self.body())[before:]), control + " state")
        self.geometry()

    def scene(self, label, painted=()):
        def ready():
            self.capture(label)
            return all(self.scene_records[label]["pixels"]["windows"][str(app)]["footer_ink"] > 20 for app in painted)
        self.wait(ready, "completed native paint: " + label, timeout=30)

    def notes_cursor_at(self, row, column):
        metrics = service.font_metrics()
        def rendered():
            g = client_geometry(configurations(self.body())[108])
            pixels = self.capture("notes-editor-ready")
            x, y = g["cx"] + 12 + column * metrics["editor_advance"], g["cy"] + 58 + row * 22
            return all(pixels[((y + dy) * self.width + x) * 3:((y + dy) * self.width + x) * 3 + 3] == bytes((202, 186, 214)) for dy in range(metrics["line_height"]))
        self.wait(rendered, "completed Notes editor paint")

    def notes_cursor_at_end(self):
        self.notes_cursor_at(1, 0)

def notes_workflow(machine):
    machine.focus_app(108)
    # Bound synthetic input to visible guest consumption. The small polled
    # hardware ring cannot absorb an arbitrary burst while an app paints.
    row, column = 0, 0
    for char in NOTE.decode("ascii"):
        key = {" ": "spc", "\n": "ret"}.get(char, char)
        machine.key(key, True)
        row, column = (row + 1, 0) if char == "\n" else (row, column + 1)
        machine.notes_cursor_at(row, column)
        machine.key(key, False)
    machine.hotkey("s", "ctrl")
    machine.wait(lambda: machine.records().get(NOTES_PATH, {}).get("content") == NOTE, "private Notes Save")
    machine.notes_cursor_at_end()
    machine.scene("notes-saved", (108,))

def path_workflow(machine):
    machine.focus_app(2)
    original_disk = machine.data.read_bytes()
    original_pid = configurations(machine.body())[2]["pid"]
    def field_border(expected, label):
        def painted():
            rect = files_path_geometry(configurations(machine.body())[2])
            pixels = machine.capture(label)
            x, y = rect["x"] + rect["width"] // 2, rect["y"]
            return pixels[(y * machine.width + x) * 3:(y * machine.width + x) * 3 + 3] == bytes(expected)
        machine.wait(painted, label)
    def begin(click=False):
        count = machine.body().count("[window-files] path editing")
        if click:
            rect = files_path_geometry(configurations(machine.body())[2])
            machine.click(rect["x"] + rect["width"] // 2, rect["y"] + rect["height"] // 2)
        else:
            machine.hotkey("l", "ctrl")
        machine.wait(lambda: machine.body().count("[window-files] path editing") > count, "native path editor activation")
        field_border((202, 186, 214), "path-active")
    begin(); machine.text("~/Downloads"); machine.key("ret")
    machine.wait(lambda: "[window-files] path navigated path=/container/Downloads" in machine.body(), "typed Downloads navigation")
    machine.scene("path-edited", (2,))
    for path in ("~/Documents/welcome.txt", "/container/../000000000000006c"):
        count = machine.body().count("[window-files] path rejected")
        begin(); machine.text(path); machine.key("ret")
        machine.wait(lambda: machine.body().count("[window-files] path rejected") > count, "processed invalid/non-directory location")
        field_border((202, 186, 214), "path-active")
        machine.error_status(True)
        machine.scene("path-rejected", (2,))
        machine.key("esc")
        field_border((79, 83, 101), "path-cancelled")
    begin(click=True); machine.text("~/Documents"); machine.key("ret")
    machine.wait(lambda: "[window-files] path navigated path=/container/Documents" in machine.body(), "toolbar-click path navigation")
    if machine.data.read_bytes() != original_disk or configurations(machine.body())[2]["pid"] != original_pid:
        raise AssertionError("path editing changed private disk data or closed the app")
    machine.paint_ready()

def lifecycle(machine, app):
    name = "files" if app == 2 else "notes"
    before = len(REAP.findall(machine.body()))
    machine.app_control(app, "close")
    machine.wait(lambda: len(REAP.findall(machine.body())) > before and any(event["state"] == "closed" and event["app"] == app for event in states(machine.body())), "independent close and reclamation")
    machine.scene("closed-" + name, (108 if app == 2 else 2,))
    old = [int(pid) for pid, candidate in START.findall(machine.body()) if int(candidate) == app]
    machine.hotkey("e" if app == 2 else "n", "meta_l")
    machine.wait(lambda: len([pid for pid, candidate in START.findall(machine.body()) if int(candidate) == app]) > len(old) and f"[window-init] {name.title()} restarted" in machine.body(), "new independent process generation")
    machine.focus_app(app)
    machine.scene("relaunched-" + name, (app,))

def window_workflow(machine):
    machine.hotkey("t", "meta_l")
    machine.wait(lambda: any(event["state"] == "tiled" and event["aux"] == 1 for event in states(machine.body())), "native tiling")
    machine.scene("tiled", (2, 108))
    before_disk = machine.data.read_bytes()
    machine.focus_app(2)
    machine.click(*machine.row_named("Documents/keepfolder"))
    machine.text("wrong")
    # A later key in the same keyboard queue proves the text has reached Files
    # before a tablet event changes focus. Separate polled devices have no
    # shared arrival timestamp from which to reconstruct physical event order.
    machine.key("f2")
    def editing(expected):
        g = client_geometry(configurations(machine.body())[2])
        pixels = machine.capture("keyboard-input-barrier")
        ink = sum(pixels[(y * machine.width + x) * 3:(y * machine.width + x) * 3 + 3] == bytes((202, 186, 214))
                  for y in range(g["cy"] + 8, g["cy"] + 24) for x in range(g["cx"] + 8, g["cx"] + g["client_width"] - 148))
        return (ink > 7) == expected
    machine.wait(lambda: editing(True), "Files keyboard queue consumed before focus switch")
    machine.key("esc")
    machine.wait(lambda: editing(False), "Files rename cancelled without mutation")
    if machine.data.read_bytes() != before_disk: raise AssertionError("Files keyboard focus changed Notes disk")
    machine.focus_app(108); machine.hotkey("end", "ctrl"); machine.notes_cursor_at_end()
    saved = machine.body().count("[window-notes] saved bytes=")
    machine.hotkey("s", "ctrl")
    machine.wait(lambda: machine.body().count("[window-notes] saved bytes=") > saved, "Notes Save after Files keyboard input")
    if machine.data.read_bytes() != before_disk: raise AssertionError("keyboard input for Files changed Notes model or disk")
    for expected in (2, 108):
        count = len(states(machine.body()))
        machine.hotkey("tab", "meta_l")
        machine.wait(lambda: any(event["state"] == "focused" and event["app"] == expected for event in states(machine.body())[count:]), "keyboard focus cycle")
    machine.hotkey("2", "meta_l")
    machine.wait(lambda: all(not frame["visible"] for frame in configurations(machine.body()).values()), "empty second workspace")
    machine.scene("workspace-empty")
    for key in ("3", "4"):
        machine.hotkey(key, "meta_l")
        machine.wait(lambda: any(event["state"] == "workspace" and event["aux"] == int(key) - 1 for event in states(machine.body())) and all(not frame["visible"] for frame in configurations(machine.body()).values()), "workspace " + key)
    machine.hotkey("1", "meta_l")
    machine.wait(lambda: all(frame["visible"] for frame in configurations(machine.body()).values()), "restored first workspace")
    machine.scene("workspace-return", (2, 108))
    machine.focus_app(108); machine.hotkey("2", "meta_l", "shift")
    machine.wait(lambda: not configurations(machine.body())[108]["visible"] and configurations(machine.body())[2]["visible"], "move Notes to workspace two")
    machine.hotkey("2", "meta_l")
    machine.wait(lambda: configurations(machine.body())[108]["visible"] and not configurations(machine.body())[2]["visible"], "Notes retained in second workspace")
    machine.hotkey("1", "meta_l", "shift")
    machine.hotkey("1", "meta_l")
    machine.wait(lambda: all(frame["visible"] for frame in configurations(machine.body()).values()), "move Notes back to first workspace")
    machine.hotkey("t", "meta_l")
    machine.wait(lambda: any(event["state"] == "tiled" and event["aux"] == 0 for event in states(machine.body())), "floating restore")
    machine.focus_app(2)
    g = configurations(machine.body())[2]
    before_epoch = g["epoch"]
    machine.drag((g["x"] + 32, g["y"] + 18), (g["x"] + 52, g["y"] + 30))
    machine.wait(lambda: configurations(machine.body())[2]["epoch"] > before_epoch, "floating caption drag")
    g = configurations(machine.body())[2]
    before_epoch = g["epoch"]
    machine.drag((g["x"] + g["width"] - 1, g["y"] + g["height"] - 1), (g["x"] + 319, g["y"] + 239))
    machine.wait(lambda: configurations(machine.body())[2]["epoch"] > before_epoch and any(event["state"] == "resized" for event in states(machine.body())), "native floating resize")
    machine.scene("resized", (2,))
    machine.app_control(2, "fullscreen", "fullscreen"); machine.scene("fullscreen", (2,))
    machine.key("esc"); machine.wait(lambda: configurations(machine.body())[2]["mode"] == "floating", "fullscreen Escape")
    machine.app_control(108, "minimize", "minimized"); machine.scene("minimized-notes", (2,))
    machine.focus_app(108); machine.wait(lambda: configurations(machine.body())[108]["visible"], "retained minimized app reopen")
    lifecycle(machine, 2); lifecycle(machine, 108)
    if machine.args.acceptance:
        before = len(FAULT.findall(machine.body()))
        machine.focus_app(108); machine.hotkey("f5", "ctrl", "shift")
        machine.wait(lambda: len(FAULT.findall(machine.body())) == before + 1 and len([pid for pid, app in START.findall(machine.body()) if app == "108"]) == 3 and machine.body().count("[window-init] Notes restarted") == 2, "actual isolated Notes write fault and fresh restart")
        machine.scene("fault-notes", (108,))
    machine.hotkey("t", "meta_l")
    machine.wait(lambda: sorted(frame["x"] for frame in configurations(machine.body()).values()) == [0, machine.width // 2] and sum(frame["width"] for frame in configurations(machine.body()).values()) == machine.width, "final tiled app frames")
    machine.scene("final", (2, 108))

def run(args):
    formatter = runtime.formatter_module()
    for path in (args.image, args.code, args.vars, args.artifacts): runtime.validate_path_syntax(path)
    code, variables = runtime.ordinary_file(args.code, formatter), runtime.ordinary_file(args.vars, formatter)
    media, kind = runtime.image_drive(args.image, args.arch, formatter)
    args.artifacts.mkdir(parents=True, exist_ok=True)
    if args.artifacts.is_symlink(): raise ValueError("artifact directory must not be a symbolic link")
    boot_directory, media_files = service.boot_sources(args.image, kind, formatter)
    args.boot_files = [code, variables] + media_files
    if kind != "raw-image" and (args.artifacts.resolve() == boot_directory or boot_directory in args.artifacts.resolve().parents): raise ValueError("artifacts must not be written inside boot ESP")
    receipt_path = args.artifacts / f"window-desktop-{args.arch}-verification.json"
    service.ordinary_output(receipt_path, formatter, args.boot_files); receipt_path.unlink(missing_ok=True)
    logs, scenes, machines, records = {}, {}, {}, {}
    started = time.monotonic()
    with tempfile.TemporaryDirectory(prefix="bedrock-window-desktop-") as temporary:
        directory = Path(temporary); data = directory / "data.img"
        legacy.seed_owned_test_image(data, formatter)
        with Machine(args, formatter, code, variables, media, directory, data, "first") as machine:
            path_workflow(machine)
            notes_workflow(machine)
            machine.app_control(2, "maximize", "maximized"); machine.paint_ready()
            service.file_workflow(machine)
            machine.scene("files-workflow", (2,))
            verify_log(machine.body(), machine.errors())
            before = data.read_bytes(); disk_evidence(before)
            machine.power_off()
        machines["first"] = machine; logs["first"] = (machine.log_path.read_bytes(), machine.error_path.read_bytes())
        for name in FIRST_SCENES: scenes[name], records[name] = machine.saved_scenes[name], machine.scene_records[name]
        with Machine(args, formatter, code, variables, media, directory, data, "reboot") as machine:
            if before != data.read_bytes(): raise AssertionError("unclean reboot changed private app data")
            window_workflow(machine)
            ready = time.monotonic()
            while time.monotonic() - ready < 1: machine.check(); time.sleep(.04)
            if args.acceptance:
                machine.key("f12")
                while machine.process.poll() is None:
                    if time.monotonic() >= machine.deadline: raise AssertionError("native window acceptance did not finish")
                    time.sleep(.04)
            verify_log(machine.body(), machine.errors(), True, args.acceptance)
            after = data.read_bytes()
        machines["reboot"] = machine; logs["reboot"] = (machine.log_path.read_bytes(), machine.error_path.read_bytes())
        for name in SCENES[len(FIRST_SCENES):] + (("fault-notes",) if args.acceptance else ()): scenes[name], records[name] = machine.saved_scenes[name], machine.scene_records[name]
        receipt = {"status": "passed", "architecture": args.arch, "mode": "acceptance" if args.acceptance else "persistent", "image": str(args.image.resolve()), "image_kind": kind, "operations": OPERATIONS + (["contained_notes_fault_recovery"] if args.acceptance else []), "reboots": 1, "owned_qemu_processes_only": True, "unclean_shutdown": True, "before_reboot_disk": disk_evidence(before), "final_disk": disk_evidence(after), "elapsed_seconds": time.monotonic() - started, "boots": {}, "scenes": records}
        if kind == "raw-image": receipt["image_sha256"] = digest(args.image.read_bytes())
        for name, (serial, stderr) in logs.items():
            receipt["boots"][name] = {"serial_sha256": digest(serial), "stderr_sha256": digest(stderr), "qemu_exit": machines[name].process.returncode, "evidence": verify_log(serial, stderr, name == "reboot", args.acceptance and name == "reboot")}
        verify_receipt(receipt, logs, scenes, before, after)
        for name, artifact in (("before-reboot", before), ("final-data", after)):
            path = args.artifacts / f"window-desktop-{args.arch}-{name}.img"
            service.ordinary_output(path, formatter, args.boot_files); path.write_bytes(artifact)
        receipt_path.write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
    print(f"{args.arch}: native windows passed; Files+Notes, tiling/workspaces, independent close/relaunch, persistence" + (", contained CPU fault" if args.acceptance else ""))
    print(f"Verification receipt: {receipt_path}")

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--arch", required=True, choices=runtime.ARCHITECTURES)
    parser.add_argument("--image", required=True, type=Path)
    parser.add_argument("--qemu"); parser.add_argument("--code", type=Path); parser.add_argument("--vars", type=Path)
    parser.add_argument("--ram-mib", type=int, default=256); parser.add_argument("--timeout", type=float, default=300)
    parser.add_argument("--acceptance", action="store_true")
    parser.add_argument("--artifacts", type=Path, default=ROOT / "zig-out/window-desktop-tests")
    args = parser.parse_args()
    if not math.isfinite(args.timeout) or not 30 <= args.timeout <= 600: parser.error("timeout must be finite and 30..600 seconds")
    if not 256 <= args.ram_mib <= 65536: parser.error("ram-mib must be 256..65536")
    qemu, code, variables = runtime.default_paths(args.arch)
    args.qemu, args.code, args.vars = args.qemu or qemu, args.code or code, args.vars or variables
    try: run(args)
    except (AssertionError, ValueError, OSError, subprocess.SubprocessError) as error:
        print(f"Native window verification failed: {error}", file=sys.stderr); return 1
    return 0

if __name__ == "__main__": sys.exit(main())
