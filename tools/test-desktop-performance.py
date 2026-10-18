#!/usr/bin/env python3
"""Bounded host-clock cursor benchmark on a fresh, owned Bedrock data image.

Screendump polling produces latency upper bounds, not display refresh/FPS.
The 60 Hz input trace verifies its final visible result, not every intermediate frame.
"""
import argparse
import ctypes
import importlib.util
import json
import math
import os
from pathlib import Path
import statistics
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("bedrock_performance_windows", ROOT / "tools/test-window-desktop.py")
windows = importlib.util.module_from_spec(spec)
spec.loader.exec_module(windows)
runtime, service = windows.runtime, windows.service
PERFORMANCE_SOURCES = (
    "userspace/services/display-server/src/window_main.zig",
    "userspace/services/display-server/src/window_policy.zig",
    "userspace/services/display-server/src/cursor_layer.zig",
    "userspace/services/display-server/src/frame_fill.zig",
    "userspace/services/display-server/src/wallpaper_cache.zig",
    "userspace/services/display-server/src/retained_frame.zig",
    "userspace/services/display-server/src/glass_frame.zig",
    "userspace/services/window-server/src/root.zig",
    "userspace/services/window-server/src/header.zig",
    "userspace/apps/shell/src/wallpaper.zig",
    "kernel/src/core/display_syscalls.zig",
    "kernel/src/core/present_region.zig",
)


def source_snapshot():
    return [{"path": path, "sha256": windows.digest((ROOT / path).read_bytes())}
            for path in PERFORMANCE_SOURCES if (ROOT / path).is_file()]


def cpu_seconds(pid):
    if os.name != "nt":
        return None
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel.OpenProcess.restype = ctypes.c_void_p
    kernel.GetProcessTimes.argtypes = [ctypes.c_void_p] + [ctypes.c_void_p] * 4
    kernel.CloseHandle.argtypes = [ctypes.c_void_p]
    handle = kernel.OpenProcess(0x1000, False, pid)
    if not handle:
        raise ctypes.WinError(ctypes.get_last_error())
    times = [ctypes.c_uint64() for _ in range(4)]
    try:
        if not kernel.GetProcessTimes(handle, *(ctypes.byref(value) for value in times)):
            raise ctypes.WinError(ctypes.get_last_error())
        return (times[2].value + times[3].value) / 10_000_000
    finally:
        kernel.CloseHandle(handle)


def cursor_visible(pixels, width, point):
    x, y = point
    probes = ((0, 0, (8, 12, 18)), (0, 8, (8, 12, 18)),
              (1, 5, (222, 232, 241)), (2, 8, (222, 232, 241)), (3, 10, (222, 232, 241)))
    return all(pixels[((y + dy) * width + x + dx) * 3:((y + dy) * width + x + dx) * 3 + 3] == bytes(rgb)
               for dx, dy, rgb in probes)


def summarize(values):
    ordered = sorted(values)
    return {"count": len(values), "minimum": min(values), "median": statistics.median(values),
            "p95": ordered[math.ceil(len(ordered) * .95) - 1], "maximum": max(values)}


def patch(pixels, stride, point, width=8, height=20):
    x, y = point
    return b"".join(pixels[((y + row) * stride + x) * 3:((y + row) * stride + x + width) * 3]
                    for row in range(height))


def run(args):
    args.arch = "x86_64"
    args.acceptance = False
    qemu, code, variables = runtime.default_paths(args.arch)
    args.qemu, args.code, args.vars = args.qemu or qemu, code, variables
    args.artifacts.mkdir(parents=True, exist_ok=True)
    formatter = runtime.formatter_module()
    code, variables = runtime.ordinary_file(code, formatter), runtime.ordinary_file(variables, formatter)
    media, kind = runtime.image_drive(args.image, args.arch, formatter)
    _, media_files = service.boot_sources(args.image, kind, formatter)
    args.boot_files = [code, variables] + media_files
    image_inputs = [{"path": str(path), "sha256": windows.digest(path.read_bytes())} for path in args.boot_files]
    audited_sources = source_snapshot()
    original_command_line = runtime.command_line
    def command_line(*arguments):
        command = original_command_line(*arguments)
        command[command.index("-accel") + 1] = args.accel
        if args.software_irqchip:
            command[command.index("-machine") + 1] += ",kernel-irqchip=off"
        return command
    runtime.command_line = command_line
    receipt_path = args.artifacts / (args.label + "-verification.json")
    receipt_path.unlink(missing_ok=True)
    started = time.perf_counter()
    with tempfile.TemporaryDirectory(prefix="bedrock-desktop-performance-") as temporary:
        directory = Path(temporary)
        data = directory / "data.img"
        windows.legacy.seed_owned_test_image(data, formatter)
        with windows.Machine(args, formatter, code, variables, media, directory, data, args.label) as machine:
            machine.wait(lambda: any(event["state"] == "ready" for event in windows.states(machine.body()))
                         and "[window-files] frame presented" in machine.body()
                         and "[window-notes] frame presented" in machine.body(), "both protected client frames")
            wallpaper_cache_ready = machine.body().count("[window-server] wallpaper cache ready lossless=1") == 1
            if args.require_wallpaper_cache:
                assert wallpaper_cache_ready and "wallpaper cache unavailable" not in machine.body(), "required lossless wallpaper cache did not initialize"
            boot_seconds = time.perf_counter() - started
            initial_disk = data.read_bytes()
            # Raw PPM capture only: no PNG encoding in the timed loop.
            capture_path = args.artifacts / (args.label + "-cursor.ppm")
            capture_times = []
            last_pixels = b""
            def capture():
                nonlocal last_pixels
                before = time.perf_counter()
                machine.qmp("screendump", {"filename": str(capture_path.resolve())})
                width, height, pixels = windows.display.parse_ppm(capture_path.read_bytes())
                assert (width, height) == (machine.width, machine.height)
                capture_times.append((time.perf_counter() - before) * 1000)
                last_pixels = pixels
                return pixels
            # The clear wallpaper below app windows avoids application hover work.
            row = machine.height - 36
            def await_cursor(point, sent, required=True):
                deadline = time.perf_counter() + (8 if required else 2)
                attempts = 0
                pixels = b""
                while time.perf_counter() < deadline:
                    machine.check()
                    attempts += 1
                    pixels = capture()
                    if cursor_visible(pixels, machine.width, point):
                        return {"point": list(point), "visible": True, "input_to_observed_ms": (time.perf_counter() - sent) * 1000, "captures": attempts}
                if required:
                    raise AssertionError("cursor did not visibly reach " + str(point))
                observed = [(x, row) for x in range(machine.width - 8) if cursor_visible(pixels, machine.width, (x, row))]
                return {"point": list(point), "visible": False, "observation_deadline_ms": (time.perf_counter() - sent) * 1000,
                        "captures": attempts, "observed_cursor_points": observed}
            origin = (64, row)
            clean_pixels = capture()
            trail_points = (origin, (120, row))
            clean_patches = {point: patch(clean_pixels, machine.width, point) for point in trail_points}
            assert not any(cursor_visible(clean_pixels, machine.width, point) for point in trail_points), "trail baseline already contains the cursor"
            sent = time.perf_counter()
            machine.point(*origin)
            await_cursor(origin, sent)
            for _ in range(3):
                capture()
            capture_baseline = list(capture_times[-3:])
            idle_start, idle_cpu = time.perf_counter(), cpu_seconds(machine.process.pid)
            time.sleep(args.idle_seconds)
            idle_elapsed = time.perf_counter() - idle_start
            idle_cpu_after = cpu_seconds(machine.process.pid)
            idle_cpu_used = None if idle_cpu is None else idle_cpu_after - idle_cpu
            samples = []
            trails = []
            for index in range(args.samples):
                point = (120 + index * 37, row)
                sent = time.perf_counter()
                machine.point(*point)
                samples.append(await_cursor(point, sent))
                if index < len(trail_points):
                    prior = trail_points[index]
                    restored = patch(last_pixels, machine.width, prior)
                    assert restored == clean_patches[prior], "old cursor pixels were not restored at " + str(prior)
                    trails.append({"old_point": list(prior), "new_point": list(point), "width": 8, "height": 20,
                                   "clean_sha256": windows.digest(clean_patches[prior]), "restored_sha256": windows.digest(restored)})
            # Send a fixed trace at host-clock 60 Hz without intermediate dumps.
            trace_start, trace_rows = time.perf_counter(), []
            for index in range(args.trace_events):
                due = trace_start + index / 60
                remaining = due - time.perf_counter()
                if remaining > 0:
                    time.sleep(remaining)
                point = (96 + (index * 11) % (machine.width - 192), row)
                sent = time.perf_counter()
                machine.point(*point)
                trace_rows.append({"scheduled_ms": index * 1000 / 60, "sent_ms": (sent - trace_start) * 1000,
                                   "qmp_completed_ms": (time.perf_counter() - trace_start) * 1000})
            final_trace = await_cursor(point, sent, required=False)
            # A saturated trace may drop hardware-ring events. Preserve that
            # observation and independently prove a subsequent input recovers.
            recovery = None
            if not final_trace["visible"]:
                sent = time.perf_counter()
                machine.point(*origin)
                recovery = await_cursor(origin, sent)
            drag = None
            if args.with_drag:
                # Notes has a wholly trusted caption, avoiding Files' tab drag.
                machine.focus_app(108)
                machine.scene("final", (108,))
                frame = windows.configurations(machine.body())[108]
                start = (frame["x"] + 40, frame["y"] + 18)
                destination = (start[0] + 24, start[1] + 16)
                sent = time.perf_counter()
                machine.point(*start)
                await_cursor(start, sent)
                machine.button(True)
                time.sleep(.04)
                try:
                    sent = time.perf_counter()
                    machine.point(*destination)
                    drag = await_cursor(destination, sent)
                finally:
                    machine.button(False)
                machine.wait(lambda: windows.configurations(machine.body())[108]["x"] == frame["x"] + 24
                             and windows.configurations(machine.body())[108]["y"] == frame["y"] + 16,
                             "actual full-window drag geometry")
                drag["frame_before"] = frame
                drag["frame_after"] = windows.configurations(machine.body())[108]
                assert all(drag["frame_after"][key] == frame[key] for key in ("pid", "width", "height", "mode"))
                assert drag["frame_after"]["epoch"] > frame["epoch"] and drag["frame_after"]["visible"]
            machine.check()
            assert initial_disk == data.read_bytes(), "performance input changed persistent app data"
            assert not windows.FAULT.findall(machine.body())
            assert len(windows.START.findall(machine.body())) == 5, "performance trace changed process identity"
            receipt = {"status": "passed", "label": args.label, "architecture": args.arch, "acceleration": args.accel,
                "software_irqchip": args.software_irqchip,
                "image_inputs": image_inputs, "boot_to_protected_frames_seconds": boot_seconds,
                "audited_working_tree_sources": audited_sources,
                "wallpaper_cache_ready": wallpaper_cache_ready,
                "source_snapshot_scope": "Working-tree source snapshot at benchmark invocation. The image hash identifies executed code; a supplied historical image may predate this source snapshot.",
                "samples": samples, "latency_upper_bound_ms": summarize([row["input_to_observed_ms"] for row in samples]),
                "capture_only_ms": summarize(capture_baseline), "all_capture_ms": summarize(capture_times),
                "idle_wall_seconds": idle_elapsed, "idle_qemu_cpu_seconds": idle_cpu_used,
                "idle_qemu_one_core_percent": None if idle_cpu_used is None else idle_cpu_used / idle_elapsed * 100,
                "trace_hz_requested": 60, "trace_events": trace_rows, "trace_final_visible": final_trace,
                "trace_recovery": recovery,
                "notes_caption_drag": drag,
                "cursor_trail_restoration": trails,
                "disk_unchanged": True, "owned_qemu_processes_only": True, "display_fps_measured": False,
                "measurement_limit": "Host input-to-screendump-observation upper bounds include QMP and screenshot overhead; fixed input cadence is not displayed FPS.",
                "elapsed_seconds": time.perf_counter() - started}
        receipt.update(serial_sha256=windows.digest(machine.log_path.read_bytes()),
                       stderr_sha256=windows.digest(machine.error_path.read_bytes()), qemu_exit=machine.process.returncode)
        assert image_inputs == [{"path": str(path), "sha256": windows.digest(path.read_bytes())} for path in args.boot_files]
        receipt["working_tree_sources_unchanged"] = audited_sources == source_snapshot()
        receipt_path.write_text(json.dumps(receipt, indent=2) + "\n")
    print(json.dumps({"receipt": str(receipt_path), "accel": args.accel,
                      "latency_upper_bound_ms": receipt["latency_upper_bound_ms"],
                      "capture_only_ms": receipt["capture_only_ms"], "idle_qemu_one_core_percent": receipt["idle_qemu_one_core_percent"]}))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--image", required=True, type=Path)
    parser.add_argument("--label", required=True)
    parser.add_argument("--accel", choices=("tcg", "whpx"), default="tcg")
    parser.add_argument("--software-irqchip", action="store_true")
    parser.add_argument("--with-drag", action="store_true")
    parser.add_argument("--require-wallpaper-cache", action="store_true")
    parser.add_argument("--artifacts", type=Path, default=ROOT / "zig-out/desktop-performance")
    parser.add_argument("--qemu")
    parser.add_argument("--ram-mib", type=int, default=256)
    parser.add_argument("--timeout", type=float, default=150)
    parser.add_argument("--samples", type=int, default=8)
    parser.add_argument("--trace-events", type=int, default=60)
    parser.add_argument("--idle-seconds", type=float, default=2)
    args = parser.parse_args()
    if not args.label or any(char not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_" for char in args.label):
        parser.error("label must contain only letters, digits, dashes or underscores")
    if not 1 <= args.samples <= 20 or not 1 <= args.trace_events <= 120 or not 0 <= args.idle_seconds <= 10:
        parser.error("samples, trace-events or idle-seconds outside bounded benchmark limits")
    if not math.isfinite(args.timeout) or not 30 <= args.timeout <= 600 or not 256 <= args.ram_mib <= 65536:
        parser.error("timeout must be finite and 30..600 seconds; ram-mib must be 256..65536")
    run(args)


if __name__ == "__main__":
    main()
