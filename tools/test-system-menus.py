#!/usr/bin/env python3
"""Verify native app/system menus, live firmware time and smooth icons in owned QEMU."""
import argparse
from functools import lru_cache
import hashlib
import importlib.util
import json
import math
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("bedrock_system_menu_window_helpers", ROOT / "tools/test-window-desktop.py")
windows = importlib.util.module_from_spec(spec)
spec.loader.exec_module(windows)
service, runtime, display = windows.service, windows.runtime, windows.display
ICON_MANIFEST = ROOT / "frameworks/public/AxisUI/icon-coverage.json"
FONT_DIRECTORY = ROOT / "frameworks/public/AxisUI"
CLOCK_BASE = re.compile(r"^\[kernel\] wall clock epoch/offset/flags=(0x[0-9a-f]{16}) (0x[0-9a-f]{16}) (0x[0-9a-f]{16})$", re.M)
CLOCK = re.compile(r"^\[window-server\] clock local_seconds=(-?[0-9]+) available=([01]) observed_ticks=([0-9]+)$", re.M)
COMMAND = re.compile(r"^\[window-server\] system menu command=([0-9]+)$", re.M)
TABS = re.compile(r"^\[window-files\] tabs count=([0-9]+) active=([0-9]+) id=([0-9]+) window_id=([0-9]+)$", re.M)
TAB_ORDER = re.compile(r"^\[window-files\] tab order window_id=([0-9]+) ids=([0-9]+(?:,[0-9]+)*)$", re.M)
SYSTEM_INK = (222, 227, 238)
APP_INK = (233, 235, 243)
CONTROL_INK = (217, 221, 232)
UNFOCUSED_CONTROL_INK = (151, 159, 176)
TITLE_BACKGROUND = (20, 21, 26)
TAB_INK = (219, 224, 234)
TAB_INACTIVE_INK = (158, 166, 182)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def signed64(value):
    parsed = int(value, 16)
    return parsed - (1 << 64) if parsed & (1 << 63) else parsed


def oracle():
    data = json.loads(ICON_MANIFEST.read_text(encoding="utf-8"))
    source = FONT_DIRECTORY / "src/icons.zig"
    if data.get("size") != 16 or data.get("source", {}).get("sha256") != digest(source.read_bytes()):
        raise AssertionError("native icon coverage oracle is stale")
    for name, values in data["icons"].items():
        if len(values) != 256 or any(type(value) is not int or not 0 <= value <= 255 for value in values):
            raise AssertionError("invalid native icon coverage: " + name)
    return data


@lru_cache(maxsize=None)
def font_samples(label):
    return service.font_samples(label)


def font_probes(label):
    points = [(x, y) for x, y, alpha in font_samples(label) if alpha == 255]
    if not points:
        raise AssertionError("insufficient native opaque glyph probes: " + label)
    return points


def trunc_div(value, divisor):
    return value // divisor if value >= 0 else -((-value) // divisor)


@lru_cache(maxsize=None)
def wallpaper_color(width, height, x, y):
    """Independent integer reference for the immutable procedural wallpaper."""
    columns = min(width, 128)
    column = ((x + 1) * columns - 1) // width
    left, right = column * width // columns, (column + 1) * width // columns
    horizontal, vertical = (left + right) * 512 // width, y * 1024 // height
    def field(cx, cy, rx, ry):
        dx, dy = trunc_div((horizontal - cx) * 1024, rx), trunc_div((vertical - cy) * 1024, ry)
        remaining = max(0, 1024 - (dx * dx + dy * dy) // 1024)
        return remaining * remaining // 1024
    warm = field(180, 750, 950, 900) * 112 // 1024
    cool = field(930, 190, 860, 800) * 122 // 1024
    light = field(480, 480, 900, 900) * 12 // 1024
    shade = y * 5 // height
    return tuple(base - shade + (rose - base + shade) * warm // 255 +
                 (blue - base + shade) * cool // 255 + light
                 for base, rose, blue in zip((27, 30, 40), (116, 75, 93), (71, 111, 142)))


@lru_cache(maxsize=None)
def wallpaper_tile(width, height, cx, cy):
    samples = [wallpaper_color(width, height, x, y)
               for y in range(cy * 8, min(cy * 8 + 8, height))
               for x in range(cx * 8, min(cx * 8 + 8, width))]
    return tuple((sum(color[channel] for color in samples) + len(samples) // 2) // len(samples)
                 for channel in range(3))


@lru_cache(maxsize=None)
def wallpaper_horizontal(width, height, cx, cy):
    samples = [wallpaper_tile(width, height, max(0, min((width + 7) // 8 - 1, cx + dx)), cy)
               for dx in range(-3, 4)]
    return tuple((sum(color[channel] for color in samples) + 3) // 7 for channel in range(3))


@lru_cache(maxsize=None)
def wallpaper_blurred(width, height, cx, cy):
    samples = [wallpaper_horizontal(width, height, cx, max(0, min((height + 7) // 8 - 1, cy + dy)))
               for dy in range(-3, 4)]
    return tuple((sum(color[channel] for color in samples) + 3) // 7 for channel in range(3))


@lru_cache(maxsize=None)
def clock_background(width, height, x, y):
    hx, hy = max(0, x * 2 - 7), max(0, y * 2 - 7)
    gx, gy, fx, fy = hx // 16, hy // 16, hx % 16, hy % 16
    a, b = wallpaper_blurred(width, height, gx, gy), wallpaper_blurred(width, height, min(gx + 1, (width + 7) // 8 - 1), gy)
    c, d = wallpaper_blurred(width, height, gx, min(gy + 1, (height + 7) // 8 - 1)), wallpaper_blurred(width, height, min(gx + 1, (width + 7) // 8 - 1), min(gy + 1, (height + 7) // 8 - 1))
    expanded = tuple(((a[i] * (16 - fx) + b[i] * fx) * (16 - fy) +
                      (c[i] * (16 - fx) + d[i] * fx) * fy + 128) // 256 for i in range(3))
    return tuple((expanded[i] * 147 + tint * 108 + 127) // 255
                 for i, tint in enumerate((22, 27, 38)))


def has_clock_text(pixels, width, label, x, y, dim=255):
    height = len(pixels) // (width * 3)
    for dx, dy, alpha in font_samples(label):
        background = clock_background(width, height, x + dx, y + dy)
        expected = tuple(((ink * alpha + base * (255 - alpha) + 127) // 255) * dim // 255
                         for ink, base in zip(SYSTEM_INK, background))
        if rgb(pixels, width, x + dx, y + dy) != expected:
            return False
    return True


def rgb(pixels, width, x, y):
    offset = (y * width + x) * 3
    return tuple(pixels[offset:offset + 3])


def has_text(pixels, width, label, x, y, ink):
    return all(rgb(pixels, width, x + dx, y + dy) == ink for dx, dy in font_probes(label))


def firmware_clock(body):
    matches = CLOCK_BASE.findall(body)
    if len(matches) != 1:
        raise AssertionError("named QEMU UEFI did not supply one available wall-clock baseline")
    seconds, offset, flags = signed64(matches[0][0]), signed64(matches[0][1]), int(matches[0][2], 16)
    known_offset = flags == 3 and -1440 <= offset <= 1440
    unspecified_offset = flags == 1 and offset == 2047
    if not (known_offset or unspecified_offset) or not -2208988800 <= seconds <= 253402300799:
        raise AssertionError("invalid actual firmware clock flags/offset")
    local = seconds + (offset * 60 if flags & 2 else 0)
    return {"epoch_seconds": seconds, "utc_offset_minutes": offset, "flags": flags, "local_seconds": local}


def clock_evidence(pixels, width, body, dim=255):
    baseline = firmware_clock(body)
    snapshots = CLOCK.findall(body)
    if not snapshots or snapshots[-1][1] != "1":
        raise AssertionError("native display server did not read an available clock")
    seconds, _, ticks = map(int, snapshots[-1])
    # Kernel initialization precedes observed timer quanta; firmware nanoseconds
    # can carry into the next second. Never accept an invented uptime calendar.
    elapsed = seconds - baseline["local_seconds"]
    if not max(0, ticks // 100 - 1) <= elapsed <= ticks // 100 + 1:
        raise AssertionError("display clock does not advance the captured firmware baseline")
    hour, minute = (seconds % 86400) // 3600, (seconds % 3600) // 60
    label = f"{hour:02d}:{minute:02d}"
    if not has_clock_text(pixels, width, label, width - 101, service.control_text_origin(0, 36), dim):
        return None
    return {**baseline, "display_local_seconds": seconds, "observed_ticks": ticks,
            "painted_time": label, "exact_gray8_pixel_probes": len(font_samples(label)), "dim": dim}


def icon_evidence(pixels, width, frame, manifest, ink=CONTROL_INK):
    evidence = {}
    for name in ("minimize", "maximize", "close"):
        rect = windows.caption_geometry(frame, name)
        icon = "restore" if name == "maximize" and frame["mode"] == "maximized" else name
        left = rect["x"] + 15
        top = rect["y"] + 8
        probes = [(index % 16, index // 16) for index, alpha in enumerate(manifest["icons"][icon]) if alpha == 255]
        if len(probes) < 8:
            raise AssertionError("insufficient actual opaque control probes")
        found = sum(rgb(pixels, width, left + dx, top + dy) == ink for dx, dy in probes)
        evidence[name] = {"icon": icon, "opaque_probes": len(probes), "painted_probes": found, "rgb": list(ink)}
        if found != len(probes):
            return None
    return evidence

def close_highlight_evidence(pixels, width, frame, manifest, pressed=False):
    """Check the actual Windows-style red target and centered white close icon."""
    rect = windows.caption_geometry(frame, "close")
    background = (155, 31, 22) if pressed else (196, 43, 28)
    probes = [(index % 16, index // 16) for index, alpha in enumerate(manifest["icons"]["close"]) if alpha == 255]
    if len(probes) < 8:
        raise AssertionError("insufficient actual opaque close probes")
    if any(rgb(pixels, width, rect["x"] + dx, rect["y"] + dy) != background
           for dx, dy in ((4, 4), (8, 4), (4, 12))):
        return None
    found = sum(rgb(pixels, width, rect["x"] + 15 + dx, rect["y"] + 8 + dy) == (255, 255, 255) for dx, dy in probes)
    if found != len(probes):
        return None
    return {"rect": rect, "background_rgb": list(background), "white_icon_probes": found}

def tab_states(body, window_id=0):
    result = []
    body = windows.normalized(body)
    for line in body.splitlines():
        if line.startswith("[window-files] tabs ") and not TABS.fullmatch(line):
            raise AssertionError("malformed native Files tab state")
    for count, active, identifier, owner in TABS.findall(body):
        count, active, identifier, owner = map(int, (count, active, identifier, owner))
        if not 1 <= count <= 8 or not 0 <= active < count or not 1 <= identifier <= 0xffffffff or not 0 <= owner <= 65535:
            raise AssertionError("invalid native Files tab state")
        if window_id is None or owner == window_id:
            result.append({"count": count, "active": active, "id": identifier, "window_id": owner})
    return result

def tab_orders(body, window_id=0):
    result = []
    for line in windows.normalized(body).splitlines():
        if not line.startswith("[window-files] tab order "):
            continue
        match = TAB_ORDER.fullmatch(line)
        if match is None:
            raise AssertionError("malformed native Files tab order")
        owner = int(match[1])
        ids = [int(value) for value in match[2].split(",")]
        if not 0 <= owner <= 65535 or not 1 <= len(ids) <= 8 or len(set(ids)) != len(ids) or any(not 1 <= value <= 0xffffffff for value in ids):
            raise AssertionError("invalid native Files tab order")
        if owner == window_id:
            result.append(ids)
    return result

def title_background_painted(pixels, width, frame):
    geometry = windows.client_geometry(frame)
    # The left inset is trusted caption chrome, outside app accessories, text,
    # rounded corners and Control Center's overlap with the right tiled app.
    return all(rgb(pixels, width, geometry["cx"] + 3, geometry["cy"] - 32 + dy) == TITLE_BACKGROUND
               for dy in (8, 16, 24))

def tabs_evidence(pixels, width, frame, state, labels, manifest):
    if len(labels) != state["count"]:
        raise AssertionError("tab pixel labels differ from observed native tab count")
    geometry = windows.files_tabs_geometry(frame, state["count"], state["active"])
    add = geometry["add"]
    middle = add["y"] + add["height"] // 2
    plus = {(add["x"] + 7 + dx, middle) for dx in range(10)} | {(add["x"] + 12, middle + dy) for dy in range(-5, 6)}
    if any(rgb(pixels, width, x, y) != TAB_INK for x, y in plus):
        return None
    close_probes = [(index % 16, index // 16) for index, alpha in enumerate(manifest["icons"]["close"]) if alpha == 255]
    visible = []
    for index, rect in geometry["tabs"].items():
        close = geometry["close"][index]
        ink = TAB_INK if index == state["active"] else TAB_INACTIVE_INK
        if any(rgb(pixels, width, close["x"] + dx, close["y"] + dy) != ink for dx, dy in close_probes):
            return None
        label_x = rect["x"] + (26 if rect["width"] >= 40 else 8)
        available = close["x"] - 4 - label_x
        prefix = ""
        for char in labels[index]:
            if service.text_width(prefix + char) > available:
                break
            prefix += char
        if prefix and not has_text(pixels, width, prefix, label_x,
                                   service.control_text_origin(rect["y"], rect["height"]), ink):
            return None
        visible.append({"index": index, "painted_label_prefix": prefix, "close_icon_probes": len(close_probes)})
    return {"count": state["count"], "active": state["active"], "id": state["id"],
            "add_icon_probes": len(plus), "visible_tabs": visible}


class Machine(windows.Machine):
    def __init__(self, *args):
        super().__init__(*args)
        self.log_path = self.args.artifacts / f"system-menus-{self.args.arch}.log"
        self.error_path = self.args.artifacts / f"system-menus-{self.args.arch}.stderr.log"

    def capture(self, label):
        from PIL import Image
        path = self.args.artifacts / f"system-menus-{self.args.arch}-{label}.ppm"
        png = path.with_suffix(".png")
        for output in (path, png):
            service.ordinary_output(output, self.formatter, self.boot_files)
        self.qmp("screendump", {"filename": str(path.resolve())})
        data = path.read_bytes()
        self.width, self.height, pixels = display.parse_ppm(data)
        with Image.open(path) as image:
            if image.size != (self.width, self.height) or image.convert("RGB").tobytes() != pixels:
                raise AssertionError("native screenshot decoder differs from QMP bytes")
            image.save(png)
        with Image.open(png) as image:
            if image.size != (self.width, self.height) or image.convert("RGB").tobytes() != pixels:
                raise AssertionError("PNG pixels differ from native PPM")
        body = self.body()
        self.saved_scenes[label] = data
        self.scene_records[label] = {"ppm_sha256": digest(data), "png_sha256": digest(png.read_bytes()),
            "width": self.width, "height": self.height, "png_matches_ppm_pixels": True,
            "serial_characters": len(body), "serial_prefix_sha256": digest(body.encode())}
        return pixels

    def clear_pointer(self):
        self.point(6, self.height - 6)

    def panel_text(self, label, open_expected=True, dim=255):
        def painted():
            pixels = self.capture(label)
            ink = tuple(channel * dim // 255 for channel in SYSTEM_INK)
            return has_text(pixels, self.width, "Control Center", self.width - 300, 60, ink) == open_expected
        self.wait(painted, "actual Control Center paint: " + label, timeout=30)

    def open_panel(self, label="control-center"):
        self.click(self.width - 28, 18)
        self.clear_pointer()
        self.panel_text(label)

    def panel_command(self, command, x, y, label, state=None, dim=255):
        before = len(COMMAND.findall(self.body()))
        self.click(self.width - 316 + x, 44 + y)
        self.clear_pointer()
        self.wait(lambda: str(command) in COMMAND.findall(self.body())[before:], "trusted system command " + str(command), timeout=30)
        if state is not None:
            self.wait(state, "actual window policy result: " + label, timeout=30)
        self.panel_text(label, dim=dim)


def workflow(machine, manifest):
    machine.focus_app(2)
    machine.clear_pointer()
    proofs = {}
    def controls():
        pixels = machine.capture("smooth-icons")
        result = icon_evidence(pixels, machine.width, windows.configurations(machine.body())[2], manifest)
        if result:
            proofs["window_controls"] = result
        return result is not None
    machine.wait(controls, "smooth native caption icon paint", timeout=30)
    close_frame = windows.configurations(machine.body())[2]
    close_rect = windows.caption_geometry(close_frame, "close")
    original_pid = close_frame["pid"]
    machine.point(close_rect["x"] + 6, close_rect["y"] + 27)
    for pressed, label in ((False, "close-hover"), (True, "close-pressed")):
        if pressed:
            machine.button(True)
        def highlighted():
            pixels = machine.capture(label)
            result = close_highlight_evidence(pixels, machine.width, close_frame, manifest, pressed)
            if result:
                proofs[label] = result
            return result is not None
        machine.wait(highlighted, "actual caption " + label + " red background and white X", timeout=30)
    machine.clear_pointer()
    machine.button(False)
    machine.wait(controls, "caption press canceled outside without closing Files", timeout=30)
    if windows.configurations(machine.body())[2]["pid"] != original_pid:
        raise AssertionError("canceling the caption press closed or replaced Files")
    proofs["close_press_cancelled_outside"] = True
    def clock():
        pixels = machine.capture("clock")
        result = clock_evidence(pixels, machine.width, machine.body())
        if result:
            proofs["clock"] = result
        return result is not None
    machine.wait(clock, "live HH:mm from actual UEFI clock", timeout=30)

    def files_path_painted(pixels, frame, label):
        rect = windows.files_path_geometry(frame)
        return has_text(pixels, machine.width, label, rect["x"] + 6,
                        service.control_text_origin(rect["y"], rect["height"]), APP_INK)

    def mode_scene(mode):
        frame = windows.configurations(machine.body())[2]
        if frame["mode"] != mode or frame["x"] != 0 or frame["width"] != machine.width:
            return False
        if mode == "fullscreen" and (frame["y"] != 0 or frame["height"] != machine.height):
            return False
        pixels = machine.capture(mode)
        icons = icon_evidence(pixels, machine.width, frame, manifest)
        if icons is None:
            return False
        # The compositor paints its caption before Files receives the new
        # viewport. Require the native toolbar path and actual title tabs too.
        observed_tabs = tab_states(machine.body())
        if (not files_path_painted(pixels, frame, "~/Documents") or
                not title_background_painted(pixels, machine.width, frame) or not observed_tabs or
                tabs_evidence(pixels, machine.width, frame, observed_tabs[-1], ["Documents"], manifest) is None):
            return False
        proofs[mode] = {"frame": frame, "window_controls": icons,
                        "screen_width": machine.width, "screen_height": machine.height,
                        "app_path": "~/Documents", "native_tabs_painted": True, "title_background_rgb": list(TITLE_BACKGROUND)}
        return True

    machine.app_control(2, "maximize", "maximized")
    machine.clear_pointer()
    machine.wait(lambda: mode_scene("maximized"), "maximized Files bounds and native restore icon", timeout=30)
    machine.key("f11")
    machine.clear_pointer()
    machine.wait(lambda: mode_scene("fullscreen"), "fullscreen Files bounds and native caption icons", timeout=30)
    machine.key("esc")
    machine.wait(lambda: windows.configurations(machine.body())[2]["mode"] == "maximized", "Escape restored maximized Files")
    machine.app_control(2, "maximize")
    machine.clear_pointer()
    machine.wait(lambda: windows.configurations(machine.body())[2]["mode"] == "floating", "caption restore returned Files to floating")
    machine.wait(controls, "floating Files caption icons repainted after maximize and fullscreen", timeout=30)
    # Configure arrives asynchronously after the caption release. Refresh the
    # inherited sidebar click coordinates only after its floating epoch exists.
    machine.geometry()

    def desktop_label():
        geometry = windows.client_geometry(windows.configurations(machine.body())[2])
        pixels = machine.capture("desktop-shortcut")
        return has_text(pixels, machine.width, "Desktop", geometry["cx"] + 40,
                        geometry["cy"] + service.control_text_origin(180, 32), APP_INK)
    machine.wait(desktop_label, "actual Files Desktop sidebar label", timeout=30)
    if machine.records().get(service.PREFIX + "Desktop") != {"kind": 1, "owner": 2, "content": b""}:
        raise AssertionError("Desktop shortcut lacks its real private filesystem directory")
    machine.shortcut(3)
    machine.clear_pointer()
    def desktop_path():
        pixels = machine.capture("desktop-navigated")
        return files_path_painted(pixels, windows.configurations(machine.body())[2], "~/Desktop")
    machine.wait(desktop_path, "Desktop sidebar click navigated the actual editable path", timeout=30)
    machine.shortcut(1)
    machine.clear_pointer()
    proofs["desktop_directory"] = {"private_path": service.PREFIX + "Desktop", "owner": 2,
                                   "native_label_verified": True, "pointer_navigation_verified": True}

    def path_ready(path, scene):
        return files_path_painted(machine.capture(scene), windows.configurations(machine.body())[2], path)
    machine.wait(lambda: path_ready("~/Documents", "tabs-documents-ready"), "Documents restored before tab checks", timeout=30)
    initial_tabs = tab_states(machine.body())[-1]
    if (initial_tabs["count"], initial_tabs["active"]) != (1, 0):
        raise AssertionError("Files did not start with precisely one active tab")
    first_id, files_pid = initial_tabs["id"], windows.configurations(machine.body())[2]["pid"]
    tab_proofs = []

    def tab_paint(labels, path, scene):
        frame = windows.configurations(machine.body())[2]
        pixels = machine.capture(scene)
        current = tab_states(machine.body())[-1]
        if current["count"] != len(labels) or not files_path_painted(pixels, frame, path):
            return False
        evidence = tabs_evidence(pixels, machine.width, frame, current, labels, manifest)
        if evidence is None or not title_background_painted(pixels, machine.width, frame):
            return False
        if frame["pid"] != files_pid:
            raise AssertionError("Files tab operation closed or replaced its window process")
        return evidence

    def painted_tabs(labels, path, scene):
        result = None
        def painted():
            nonlocal result
            result = tab_paint(labels, path, scene)
            return result is not False
        machine.wait(painted, "native tabs and isolated location: " + scene, timeout=30)
        tab_proofs.append({"scene": scene, "path": path, "pixels": result})

    def tab_action(action, count, active, label, expected_id=None):
        before = len(tab_states(machine.body()))
        action()
        machine.clear_pointer()
        def observed():
            values = tab_states(machine.body())
            return (len(values) > before and (values[-1]["count"], values[-1]["active"]) == (count, active) and
                    (expected_id is None or values[-1]["id"] == expected_id))
        machine.wait(observed, "actual Files tab state: " + label, timeout=30)
        return tab_states(machine.body())[-1]

    def tab_point(index=None, close=False, add=False):
        current = tab_states(machine.body())[-1]
        layout = windows.files_tabs_geometry(windows.configurations(machine.body())[2], current["count"], current["active"])
        rect = layout["add"] if add else layout["close" if close else "tabs"][index]
        machine.click(rect["x"] + rect["width"] // 2, rect["y"] + rect["height"] // 2)

    painted_tabs(["Documents"], "~/Documents", "tabs-initial")
    second = tab_action(lambda: tab_point(add=True), 2, 1, "pointer add")
    second_id = second["id"]
    if second_id == first_id:
        raise AssertionError("new Files tab reused the first tab identity")
    painted_tabs(["Documents", "Documents"], "~/Documents", "tabs-two-created")
    machine.shortcut(2); machine.clear_pointer()
    painted_tabs(["Documents", "Downloads"], "~/Downloads", "tabs-two")
    tab_action(lambda: tab_point(0), 2, 0, "pointer select first", first_id)
    painted_tabs(["Documents", "Downloads"], "~/Documents", "tabs-first-restored")
    # This tab visited Desktop before the second tab existed. Its own Back
    # must reach Desktop, independently of the other tab's Downloads visit.
    machine.click(machine.cx + 28, machine.cy + 20); machine.clear_pointer()
    painted_tabs(["Desktop", "Downloads"], "~/Desktop", "tabs-independent-back")
    machine.click(machine.cx + 64, machine.cy + 20); machine.clear_pointer()
    painted_tabs(["Documents", "Downloads"], "~/Documents", "tabs-independent-forward")

    def current_order(window_id=0):
        values = tab_states(machine.body(), window_id)
        orders = tab_orders(machine.body(), window_id)
        if not values or not orders:
            return None
        value, order = values[-1], orders[-1]
        return order if len(order) == value["count"] and order[value["active"]] == value["id"] else None

    def source_layout():
        current = tab_states(machine.body())[-1]
        return windows.files_tabs_geometry(windows.configurations(machine.body())[2], current["count"], current["active"])

    def drag_reorder(index, destination_index, expected, labels, scene):
        layout = source_layout()
        source, destination = layout["tabs"][index], layout["tabs"][destination_index]
        x = destination["x"] + destination["width"] // 2 + (8 if destination_index > index else -8)
        y = source["y"] + 12
        machine.point(source["x"] + 28, y); time.sleep(.1)
        machine.button(True); time.sleep(.12)
        machine.point(x, y)
        machine.wait(lambda: current_order() == expected, "stable-ID tab reorder " + scene, timeout=30)
        machine.button(False); machine.clear_pointer()
        painted_tabs(labels, "~/Documents", scene)
        if tab_states(machine.body())[-1]["id"] != first_id:
            raise AssertionError("reorder changed the dragged Documents tab identity")

    machine.wait(lambda: current_order() == [first_id, second_id], "initial stable tab order", timeout=30)
    drag_reorder(0, 1, [second_id, first_id], ["Downloads", "Documents"], "tabs-reordered")
    drag_reorder(1, 0, [first_id, second_id], ["Documents", "Downloads"], "tabs-order-restored")

    def cancellation_fence(expected_path, scene):
        deadline = time.monotonic() + 1
        def unchanged():
            frames = windows.window_configurations(machine.body())
            return (time.monotonic() >= deadline and set(frames) == {(2, 0), (108, 0)} and
                    current_order() == [first_id, second_id] and path_ready(expected_path, scene))
        machine.wait(unchanged, "canceled drag retained both tabs and created no window", timeout=30)

    first_rect = source_layout()["tabs"][0]
    machine.point(first_rect["x"] + 28, first_rect["y"] + 12); time.sleep(.1)
    machine.button(True); time.sleep(.1)
    machine.point(first_rect["x"] + 33, first_rect["y"] + 15); time.sleep(.15)
    machine.button(False); machine.clear_pointer()
    cancellation_fence("~/Documents", "tabs-small-move")

    # Paint the native held tab before canceling a real drag. Its label moves
    # twelve pixels left, and the original slot receives the renderer's marker.
    # Hold the folder-icon area so the native cursor cannot obscure its text.
    second_rect = source_layout()["tabs"][1]
    machine.point(second_rect["x"] + 10, second_rect["y"] + 12); time.sleep(.1)
    machine.button(True); time.sleep(.12)
    machine.point(second_rect["x"] - 2, second_rect["y"] + 12)
    def drag_preview():
        pixels = machine.capture("tabs-drag-preview")
        return (tab_states(machine.body())[-1]["id"] == second_id and
                rgb(pixels, machine.width, second_rect["x"], second_rect["y"] + 3) == (180, 190, 211) and
                has_text(pixels, machine.width, "Downloads", second_rect["x"] + 14,
                         service.control_text_origin(second_rect["y"], second_rect["height"]), TAB_INK))
    machine.wait(drag_preview, "actual dragged tab label and native insertion marker", timeout=30)
    machine.key("esc")
    machine.point(second_rect["x"] + 40, second_rect["y"] + 70); time.sleep(.15)
    machine.button(False); machine.clear_pointer()
    cancellation_fence("~/Downloads", "tabs-escape-canceled")

    # Move the original frame to the workarea top using its small trusted
    # caption gap, leaving its path visible behind a drop-clamped new frame.
    frame = windows.configurations(machine.body())[2]
    geometry = windows.client_geometry(frame)
    drag_x, drag_y = geometry["cx"] + geometry["client_width"] - 142, geometry["cy"] - 16
    machine.point(drag_x, drag_y); time.sleep(.1); machine.button(True); time.sleep(.12)
    machine.point(drag_x, drag_y + 42 - frame["y"]); time.sleep(.2); machine.button(False)
    machine.wait(lambda: windows.configurations(machine.body())[2]["y"] == 42, "original Files frame moved through trusted caption gap", timeout=30)
    machine.geometry(); machine.clear_pointer()
    painted_tabs(["Documents", "Downloads"], "~/Downloads", "tabs-before-tear")

    second_rect = source_layout()["tabs"][1]
    drop = (machine.width - 10, machine.height - 10)
    source_frame = windows.configurations(machine.body())[2]
    if source_frame["x"] <= drop[0] < source_frame["x"] + source_frame["width"] and source_frame["y"] <= drop[1] < source_frame["y"] + source_frame["height"]:
        raise AssertionError("tear-off test drop is still inside the source window")
    commit_marker = "[window-files] tab detached after destination frame accepted"
    committed_before = machine.body().count(commit_marker)
    detached_tab_id = None
    machine.point(second_rect["x"] + 28, second_rect["y"] + 12); time.sleep(.1)
    machine.button(True); time.sleep(.12)
    machine.point(*drop); time.sleep(.25); machine.button(False)
    machine.clear_pointer()
    def torn_state():
        nonlocal detached_tab_id
        frames = windows.window_configurations(machine.body())
        if set(frames) != {(2, 0), (2, 1), (108, 0)}:
            return False
        if frames[2, 0]["pid"] != files_pid or frames[2, 1]["pid"] != files_pid:
            raise AssertionError("tearing a tab spawned or replaced the Files process")
        destination = current_order(1)
        if (current_order() != [first_id] or destination is None or len(destination) != 1 or
                machine.body().count(commit_marker) <= committed_before):
            return False
        # Tab IDs are scoped to their owning window. Import creates a fresh
        # destination identity, then ACK commits removal of the original ID.
        if destination[0] in (first_id, second_id):
            raise AssertionError("detached destination reused a source tab identity")
        if detached_tab_id is None:
            detached_tab_id = destination[0]
        elif destination != [detached_tab_id]:
            raise AssertionError("detached tab identity changed in its retained window")
        return True
    machine.wait(torn_state, "real second native Files window after acknowledged tab transfer", timeout=30)

    compact_separation = None
    if machine.height <= 600:
        # A drop-clamped 470px window at y118 casts a real shadow over the
        # source path's lowest glyph pixel. Resize/move only the destination
        # through native controls, keeping strict unoccluded RGB font probes.
        secondary = windows.window_configurations(machine.body())[2, 1]
        source_before = windows.configurations(machine.body())[2]
        corner_x = secondary["x"] + secondary["width"] - 2
        corner_y = secondary["y"] + secondary["height"] - 2
        machine.point(corner_x, corner_y); time.sleep(.1); machine.button(True); time.sleep(.12)
        machine.point(corner_x, corner_y - 24); time.sleep(.2); machine.button(False); machine.clear_pointer()
        machine.wait(lambda: windows.window_configurations(machine.body())[2, 1]["height"] == secondary["height"] - 24,
                     "compact detached window resized through its own native corner", timeout=30)
        shortened = windows.window_configurations(machine.body())[2, 1]
        g = windows.client_geometry(shortened)
        x, y = g["cx"] + g["client_width"] - 142, g["cy"] - 16
        machine.point(x, y); time.sleep(.1); machine.button(True); time.sleep(.12)
        machine.point(x, y + 24); time.sleep(.2); machine.button(False); machine.clear_pointer()
        machine.wait(lambda: windows.window_configurations(machine.body())[2, 1]["y"] == secondary["y"] + 24,
                     "compact detached window moved below the source path shadow boundary", timeout=30)
        after = windows.configurations(machine.body())[2]
        if any(after[key] != source_before[key] for key in ("pid", "x", "y", "width", "height", "visible")):
            raise AssertionError("resizing/moving the detached window changed its source window")
        compact_separation = {"before": secondary, "after": windows.window_configurations(machine.body())[2, 1],
                              "native_corner_resize": True, "native_caption_move": True, "source_unchanged": True}

    def torn_paint(scene="tabs-torn-off"):
        if not torn_state():
            return False
        frames = windows.window_configurations(machine.body())
        pixels = machine.capture(scene)
        result = {}
        for window_id, label in ((0, "Documents"), (1, "Downloads")):
            frame = frames[2, window_id]
            if not frame["visible"] or frame["mode"] != "floating" or frame["x"] < 0 or frame["y"] < 42 or frame["x"] + frame["width"] > machine.width or frame["y"] + frame["height"] > machine.height:
                return False
            state = tab_states(machine.body(), window_id)[-1]
            ink = tabs_evidence(pixels, machine.width, frame, state, [label], manifest)
            controls = icon_evidence(pixels, machine.width, frame, manifest, UNFOCUSED_CONTROL_INK if window_id == 0 else CONTROL_INK)
            if ink is None or not files_path_painted(pixels, frame, "~/" + label) or controls is None:
                return False
            result[str(window_id)] = {"frame": frame, "tab_pixels": ink, "window_controls": controls, "path": "~/" + label}
        return result
    torn_pixels = None
    def initial_torn_paint():
        nonlocal torn_pixels
        torn_pixels = torn_paint()
        return torn_pixels is not False
    machine.wait(initial_torn_paint, "two actual Files captions, paths and window controls", timeout=30)

    # The target retains its existing Documents -> Downloads history. These
    # shortcuts operate only after an actual pointer focus of that new frame.
    machine.hotkey("left", "alt"); machine.clear_pointer()
    machine.wait(lambda: files_path_painted(machine.capture("tabs-detached-back"), windows.window_configurations(machine.body())[2, 1], "~/Documents"),
                 "detached tab retained Documents Back history", timeout=30)
    machine.hotkey("right", "alt"); machine.clear_pointer()
    machine.wait(lambda: torn_paint("tabs-detached-forward") is not False, "detached tab retained Downloads Forward history", timeout=30)

    secondary = windows.window_configurations(machine.body())[2, 1]
    secondary_geometry = windows.client_geometry(secondary)
    x, y = secondary_geometry["cx"] + secondary_geometry["client_width"] - 142, secondary_geometry["cy"] - 16
    destination_x = x - min(16, secondary["x"])
    if destination_x == x:
        destination_x = x + min(16, machine.width - secondary["x"] - secondary["width"])
    if destination_x == x:
        raise AssertionError("second Files window has no room for its independent move probe")
    machine.point(x, y); time.sleep(.1); machine.button(True); time.sleep(.12)
    machine.point(destination_x, y); time.sleep(.2); machine.button(False); machine.clear_pointer()
    machine.wait(lambda: windows.window_configurations(machine.body())[2, 1]["x"] != secondary["x"], "only the second Files window moved", timeout=30)
    if windows.configurations(machine.body())[2]["x"] != source_frame["x"]:
        raise AssertionError("moving a detached window moved the original window")

    source_tab = windows.files_tabs_geometry(windows.configurations(machine.body())[2], 1, 0)["tabs"][0]
    machine.click(source_tab["x"] + 28, source_tab["y"] + 12)
    secondary = windows.window_configurations(machine.body())[2, 1]
    machine.click(secondary["x"] + secondary["width"] - 12, secondary["y"] + secondary["height"] - 16)
    minimize = windows.caption_geometry(secondary, "minimize")
    machine.click(minimize["x"] + 23, minimize["y"] + 16); machine.clear_pointer()
    machine.wait(lambda: not windows.window_configurations(machine.body())[2, 1]["visible"] and windows.configurations(machine.body())[2]["visible"],
                 "minimize retained only the detached window", timeout=30)
    machine.focus_app(2); machine.clear_pointer()
    machine.wait(lambda: torn_paint("tabs-detached-restored") is not False, "Files launch chip restored its retained detached window", timeout=30)
    secondary = windows.window_configurations(machine.body())[2, 1]
    close = windows.caption_geometry(secondary, "close")
    machine.click(close["x"] + 23, close["y"] + 16); machine.clear_pointer()
    def retirement_balanced():
        body = machine.body()
        retired = [match for match in windows.WINDOW_RETIRED.finditer(body)
                   if int(match[1]) == 2 and int(match[2]) == files_pid and int(match[3]) == 1]
        if not retired:
            return False
        after = windows.states(body[retired[-1].end():])
        return any(value["surfaces"] == 6 and value["processes"] == 5 and value["files"] == files_pid for value in after)
    machine.wait(retirement_balanced, "detached window retirement released its actual producer and cache", timeout=30)
    machine.wait(lambda: set(windows.window_configurations(machine.body())) == {(2, 0), (108, 0)}, "two original desktop windows remain", timeout=30)
    machine.focus_app(2); machine.clear_pointer(); machine.geometry()
    painted_tabs(["Documents"], "~/Documents", "tabs-source-after-detached-close")
    proofs["files_tab_drag"] = {"files_pid": files_pid, "original_window_id": 0, "detached_window_id": 1,
                                "source_stable_ids": [first_id, second_id], "detached_tab_id": detached_tab_id,
                                "fresh_destination_identity": True, "source_removed_after_frame_ack": True,
                                "reordered_both_directions": True,
                                "small_move_no_detach": True, "escape_canceled_drag": True, "native_drag_preview": True,
                                "drop_outside_source_frame": list(drop), "two_native_windows": torn_pixels,
                                "history_back_forward": True, "independent_move_focus_minimize_restore_close": True,
                                "retired_surface_count": 6, "retained_process_count": 5,
                                "compact_window_separation": compact_separation}

    pointer_tab = tab_action(lambda: tab_point(add=True), 2, 1, "pointer add for close")
    pointer_id = pointer_tab["id"]
    painted_tabs(["Documents", "Documents"], "~/Documents", "tabs-pointer-close-ready")
    tab_action(lambda: tab_point(1, close=True), 1, 0, "pointer close second", first_id)
    painted_tabs(["Documents"], "~/Documents", "tabs-pointer-closed")

    third = tab_action(lambda: machine.hotkey("t", "ctrl"), 2, 1, "Ctrl+T second")
    third_id = third["id"]
    painted_tabs(["Documents", "Documents"], "~/Documents", "tabs-keyboard-two")
    machine.shortcut(3); machine.clear_pointer()
    painted_tabs(["Documents", "Desktop"], "~/Desktop", "tabs-keyboard-second-location")
    fourth = tab_action(lambda: machine.hotkey("t", "ctrl"), 3, 2, "Ctrl+T third")
    fourth_id = fourth["id"]
    # These IDs all came from window zero's filtered stream. A separate
    # window has its own ID domain and may legitimately contain the same value.
    if len({first_id, second_id, pointer_id, third_id, fourth_id}) != 5:
        raise AssertionError("Files reused a retired or live tab identity in window zero")
    painted_tabs(["Documents", "Desktop", "Desktop"], "~/Desktop", "tabs-keyboard-three")
    tab_action(lambda: machine.hotkey("tab", "ctrl"), 3, 0, "Ctrl+Tab wrapped forward", first_id)
    painted_tabs(["Documents", "Desktop", "Desktop"], "~/Documents", "tabs-keyboard-next")
    tab_action(lambda: machine.hotkey("tab", "ctrl", "shift"), 3, 2, "Ctrl+Shift+Tab wrapped reverse", fourth_id)
    painted_tabs(["Documents", "Desktop", "Desktop"], "~/Desktop", "tabs-keyboard-previous")
    tab_action(lambda: machine.hotkey("w", "ctrl"), 2, 1, "Ctrl+W third", third_id)
    painted_tabs(["Documents", "Desktop"], "~/Desktop", "tabs-keyboard-close-three")
    tab_action(lambda: machine.hotkey("w", "ctrl"), 1, 0, "Ctrl+W second", first_id)
    painted_tabs(["Documents"], "~/Documents", "tabs-keyboard-closed")
    proofs["files_tabs"] = {"files_pid": files_pid, "original_tab_id": first_id,
                            "independent_history": True, "same_process_after_tab_close": True, "scenes": tab_proofs}

    machine.open_panel()
    machine.key("esc")
    machine.panel_text("control-center-escaped", False)
    machine.open_panel("control-center-reopened")
    def tiled_geometry():
        frames = windows.configurations(machine.body()).values()
        return sorted(frame["x"] for frame in frames) == [0, machine.width // 2] and all(frame["visible"] for frame in frames) and sum(frame["width"] for frame in frames) == machine.width
    machine.panel_command(21, 224, 111, "tiled", tiled_geometry)
    machine.key("esc")
    machine.panel_text("tiled-panel-escaped", False)
    def tiled_clients():
        pixels = machine.capture("tiled")
        frames = windows.configurations(machine.body())
        for app in (2, 108):
            geometry = windows.client_geometry(frames[app])
            if not title_background_painted(pixels, machine.width, frames[app]):
                return False
            if app == 2:
                if (not files_path_painted(pixels, frames[app], "~/Documents") or
                        tabs_evidence(pixels, machine.width, frames[app], tab_states(machine.body())[-1], ["Documents"], manifest) is None):
                    return False
            else:
                if (not has_text(pixels, machine.width, "File", geometry["cx"] + 26,
                                 geometry["cy"] + service.control_text_origin(12, 28), APP_INK) or
                        rgb(pixels, machine.width, geometry["cx"] + 4, geometry["cy"] + 1) != (32, 35, 44)):
                    return False
        return True
    machine.wait(tiled_clients, "actual tiled tabs, toolbar path and Notes menu painted", timeout=30)
    proofs["title_bars"] = {"rgb": list(TITLE_BACKGROUND), "outside_client_accessory": True, "both_tiled_clients_verified": True}
    proofs["notes_menu_background"] = {"rgb": [32, 35, 44], "separate_from_caption": True}
    machine.open_panel("tiled-control-center")
    machine.panel_command(20, 82, 111, "floating", lambda: all(frame["visible"] for frame in windows.configurations(machine.body()).values()) and all(frame["width"] != machine.width // 2 for frame in windows.configurations(machine.body()).values()))
    machine.panel_command(11, 115, 165, "workspace-two", lambda: all(not frame["visible"] for frame in windows.configurations(machine.body()).values()))
    machine.panel_command(10, 45, 165, "workspace-one", lambda: all(frame["visible"] for frame in windows.configurations(machine.body()).values()))

    base = machine.capture("before-dimming")
    samples = [(x, machine.height - 30) for x in range(20, machine.width - 20, 40)]
    original = [rgb(base, machine.width, x, y) for x, y in samples]
    if any(min(color) <= 0 for color in original):
        raise AssertionError("dimming proof lacks meaningful native wallpaper pixels")
    machine.panel_command(30, 45, 236, "dim-25", dim=64)
    def dimmed():
        pixels = machine.capture("dim-25")
        return all(rgb(pixels, machine.width, x, y) == tuple(channel * 64 // 255 for channel in color) for (x, y), color in zip(samples, original))
    machine.wait(dimmed, "actual scene pixels dimmed to 25 percent", timeout=30)
    proofs["dimming"] = {"sample_count": len(samples), "levels": [64, 255], "actual_integer_rgb_math": True}
    machine.panel_command(33, 255, 236, "dim-100")
    def restored():
        pixels = machine.capture("dim-100")
        return all(rgb(pixels, machine.width, x, y) == color for (x, y), color in zip(samples, original))
    machine.wait(restored, "actual scene pixels restored to 100 percent", timeout=30)
    machine.key("esc"); machine.panel_text("restored-panel-escaped", False)

    machine.click(30, 18); machine.clear_pointer()
    machine.wait(lambda: has_text(machine.capture("bedrock-menu"), machine.width, "Control Center", 38, service.control_text_origin(42, 26), (225, 230, 239)), "actual independent Bedrock menu", timeout=30)
    count = len(COMMAND.findall(machine.body()))
    machine.click(100, 55); machine.clear_pointer()
    machine.wait(lambda: "1" in COMMAND.findall(machine.body())[count:], "Bedrock menu Control Center command", timeout=30)
    machine.panel_text("bedrock-control-center")
    machine.key("esc"); machine.panel_text("bedrock-panel-escaped", False)

    for app, name, label, row_top in ((2, "files", "New folder", 74), (108, "notes", "Save", 46)):
        machine.focus_app(app)
        machine.clear_pointer()
        geometry = windows.client_geometry(windows.configurations(machine.body())[app])
        origin_y = geometry["y"] + 2 if app == 2 else geometry["cy"]
        x, y = geometry["cx"] + 44, origin_y + service.control_text_origin(row_top, 26)
        machine.hotkey("f", "alt")
        machine.wait(lambda: has_text(machine.capture(name + "-menu"), machine.width, label, x, y, APP_INK), "actual " + name + " Alt+F app menu", timeout=30)
        machine.key("esc")
        machine.wait(lambda: not has_text(machine.capture(name + "-menu-escaped"), machine.width, label, x, y, APP_INK), "actual " + name + " app menu Escape", timeout=30)
        proofs[name + "_menu"] = {"activation": "Alt+F", "escape_cancels": True, "label": label, "opaque_glyph_probes": len(font_probes(label))}
    machine.open_panel("notes-control-center")
    machine.key("esc"); machine.panel_text("final", False)
    return proofs


def run(args):
    formatter = runtime.formatter_module()
    for path in (args.image, args.code, args.vars, args.artifacts):
        runtime.validate_path_syntax(path)
    code, variables = runtime.ordinary_file(args.code, formatter), runtime.ordinary_file(args.vars, formatter)
    media, kind = runtime.image_drive(args.image, args.arch, formatter)
    args.artifacts.mkdir(parents=True, exist_ok=True)
    if args.artifacts.is_symlink():
        raise ValueError("artifact directory must not be a symbolic link")
    boot_directory, media_files = service.boot_sources(args.image, kind, formatter)
    args.boot_files = [code, variables] + media_files
    if kind != "raw-image" and (args.artifacts.resolve() == boot_directory or boot_directory in args.artifacts.resolve().parents):
        raise ValueError("menu artifacts must differ from the boot ESP")
    manifest = oracle()
    image_inputs = [{"path": str(path), "sha256": digest(path.read_bytes())} for path in args.boot_files]
    reference_paths = [FONT_DIRECTORY / "src/axis_sans.bin", FONT_DIRECTORY / "axis-sans.json",
                       FONT_DIRECTORY / "src/font.zig", FONT_DIRECTORY / "src/materials.zig",
                       FONT_DIRECTORY / "src/tabs.zig", ROOT / "userspace/apps/files/src/window_main.zig",
                       ROOT / "userspace/apps/files/src/layout.zig", ROOT / "userspace/apps/files/src/view.zig",
                       ROOT / "userspace/services/display-server/src/window_main.zig",
                       ROOT / "userspace/services/display-server/src/window_policy.zig",
                       ROOT / "userspace/services/display-server/src/cursor_layer.zig",
                       ROOT / "userspace/services/display-server/src/frame_fill.zig",
                       ROOT / "userspace/services/display-server/src/wallpaper_cache.zig",
                       ROOT / "userspace/services/display-server/src/retained_frame.zig",
                       ROOT / "kernel/src/core/display_syscalls.zig",
                       ROOT / "kernel/src/core/present_region.zig",
                       ROOT / "drivers/gpu/framebuffer.zig", ROOT / "drivers/gpu/pixel_format.zig",
                       ROOT / "frameworks/public/Anvil/src/root.zig",
                       ROOT / "frameworks/private/AnvilCore/src/software.zig",
                       ROOT / "userspace/apps/shell/src/wallpaper.zig",
                       ROOT / "userspace/apps/shell/src/system_bar.zig"]
    reference_sources = [{"path": str(path.relative_to(ROOT)), "sha256": digest(path.read_bytes())}
                         for path in reference_paths]
    receipt_path = args.artifacts / f"system-menus-{args.arch}-verification.json"
    service.ordinary_output(receipt_path, formatter, args.boot_files)
    receipt_path.unlink(missing_ok=True)
    started = time.monotonic()
    with tempfile.TemporaryDirectory(prefix="bedrock-system-menus-") as temporary:
        directory = Path(temporary)
        data = directory / "data.img"
        windows.legacy.seed_owned_test_image(data, formatter)
        with Machine(args, formatter, code, variables, media, directory, data, "menus") as machine:
            initial_disk = data.read_bytes()
            proofs = workflow(machine, manifest)
            evidence = windows.verify_log(machine.body(), machine.errors())
            if data.read_bytes() != initial_disk:
                raise AssertionError("presentation/menu probes changed private app disk bytes")
            scenes = dict(machine.scene_records)
        serial, stderr = machine.log_path.read_bytes(), machine.error_path.read_bytes()
        if image_inputs != [{"path": str(path), "sha256": digest(path.read_bytes())} for path in args.boot_files]:
            raise AssertionError("boot inputs changed during QEMU verification; freeze images before running")
        if reference_sources != [{"path": str(path.relative_to(ROOT)), "sha256": digest(path.read_bytes())}
                                 for path in reference_paths]:
            raise AssertionError("native pixel-reference sources changed during verification")
        commands = [int(value) for value in COMMAND.findall(windows.normalized(serial))]
        graphics = verify_anvil_backend(windows.normalized(serial), getattr(args, "require_anvil", False))
        if commands != [21, 20, 11, 10, 30, 33, 1]:
            raise AssertionError("trusted system command order/count differs from matched clicks")
        # Re-read all saved artifacts instead of trusting capture's booleans.
        from PIL import Image
        for label, record in scenes.items():
            ppm = args.artifacts / f"system-menus-{args.arch}-{label}.ppm"
            png = ppm.with_suffix(".png")
            raw = ppm.read_bytes()
            width, height, pixels = display.parse_ppm(raw)
            with Image.open(png) as image:
                if image.size != (width, height) or image.convert("RGB").tobytes() != pixels:
                    raise AssertionError("saved native PNG/PPM mismatch: " + label)
            if digest(raw) != record["ppm_sha256"] or digest(png.read_bytes()) != record["png_sha256"]:
                raise AssertionError("captured screenshot changed during verification")
            prefix = windows.normalized(serial)[:record["serial_characters"]]
            if digest(prefix.encode()) != record["serial_prefix_sha256"]:
                raise AssertionError("screenshot serial prefix differs from captured evidence")
        receipt = {"status": "passed", "architecture": args.arch, "image": str(args.image.resolve()),
            "image_kind": kind, "image_inputs": image_inputs,
            "owned_qemu_processes_only": True, "fresh_ordinary_data_image": True, "disk_unchanged": True,
            "elapsed_seconds": time.monotonic() - started, "qemu_exit": machine.process.returncode,
            "serial_sha256": digest(serial), "stderr_sha256": digest(stderr), "startup": evidence,
            "trusted_commands": commands,
            "graphics_backend": graphics,
            "icon_source": manifest["source"], "icon_manifest_sha256": digest(ICON_MANIFEST.read_bytes()),
            "pixel_reference_sources": reference_sources, "proofs": proofs, "scenes": scenes}
        receipt_path.write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
    print(f"{args.arch}: native system/app menus, firmware clock, smooth icons and actual scene dimming passed")
    print(f"Verification receipt: {receipt_path}")


def verify_anvil_backend(body, required=False):
    lines = body.splitlines()
    selections = [line for line in lines if line.startswith("[kernel] Anvil backend=")]
    if not selections and not required:
        return None
    expected = "[kernel] Anvil backend=software hardware_acceleration=0"
    complete = "[kernel] Anvil first presentation completed"
    if selections != [expected] or lines.count(complete) != 1:
        raise AssertionError("Anvil requires one honest software selection and completed presentation")
    if lines.index(expected) >= lines.index(complete):
        raise AssertionError("Anvil presentation completed before backend selection")
    return {"backend": "software", "hardware_acceleration": False, "first_presentation_completed": True}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--arch", required=True, choices=runtime.ARCHITECTURES)
    parser.add_argument("--image", required=True, type=Path)
    parser.add_argument("--qemu")
    parser.add_argument("--code", type=Path)
    parser.add_argument("--vars", type=Path)
    parser.add_argument("--ram-mib", type=int, default=256)
    parser.add_argument("--timeout", type=float, default=240)
    parser.add_argument("--artifacts", type=Path)
    parser.add_argument("--require-anvil", action="store_true", help="require actual Anvil CPU-backend selection and completion")
    args = parser.parse_args()
    if not math.isfinite(args.timeout) or not 30 <= args.timeout <= 600:
        parser.error("timeout must be finite and 30..600 seconds")
    if not 256 <= args.ram_mib <= 65536:
        parser.error("ram-mib must be 256..65536")
    qemu, code, variables = runtime.default_paths(args.arch)
    args.qemu, args.code, args.vars = args.qemu or qemu, args.code or code, args.vars or variables
    args.artifacts = args.artifacts or ROOT / "zig-out/system-menu-tests" / args.arch
    args.acceptance = False
    try:
        run(args)
    except (AssertionError, ValueError, OSError, subprocess.SubprocessError) as error:
        print(f"System menu verification failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
