#!/usr/bin/env python3
"""Verify protected native surfaces, focused input, and display-client recovery.

Only owned QEMU, localhost QMP, snapshotted boot media, and freshly formatted
ordinary data media are used. Screenshots come from the actual guest scanout.
"""
import argparse
import hashlib
import importlib.util
import json
import math
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent


def load_module(name, filename):
    spec = importlib.util.spec_from_file_location(name, ROOT / "tools" / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


runtime_runner = load_module("bedrock_display_runtime_helpers", "test-application-runtime.py")
desktop_runner = load_module("bedrock_display_qmp_helpers", "test-desktop.py")
MARKERS = {
    "archive": "[bootloader] application archive staged",
    "init": "[kernel] installed native init ready; persistent supervisor",
    "broker": "[kernel] protected surface broker ready",
    "server": "[display-server] protected compositor ready",
    "fault": "[display-client] surface A fault requested",
    "restart": "[display-client] surface A restart verified",
    "reclaimed": "[kernel] surface A generation reclaimed; surface B retained",
    "survival": "[display-init] two surfaces and client survival verified",
    "identities": "[kernel] display identities and surface ownership verified",
    "input": "[display-client] focused input accepted",
    "focused": "[kernel] focused display input verified",
    "balanced": "[kernel] display teardown balanced",
    "complete": "[kernel] display acceptance complete",
}
PINK = bytes((212, 149, 173))
BLUE = bytes((139, 174, 192))
GREEN = bytes((168, 197, 165))
WINDOW_BASE = bytes((30, 32, 42))
TEXT = bytes((228, 223, 213))
TEXT_INK = frozenset(bytes((foreground * coverage + background * (255 - coverage) + 127) // 255
                           for foreground, background in zip(TEXT, WINDOW_BASE)) for coverage in range(128, 256))
MUTED_TEXT = bytes((153, 158, 174))
WINDOW_A = (24, 64, 320, 240)
WINDOW_B = (456, 64, 320, 240)


def counts(body):
    return {name: body.count(marker) for name, marker in MARKERS.items()}


def verify_markers(body, errors, persistent, complete):
    if "[panic]" in body + errors or "[fault]" in body + errors:
        raise AssertionError("display runtime reported a kernel failure")
    found = counts(body)
    cycles = 1 if persistent else 3
    for name in ("archive", "init", "broker", "server", "survival", "identities"):
        if found[name] != 1:
            raise AssertionError(f"missing/duplicate display marker {name}: {found[name]}")
    if found["fault"] != cycles or found["restart"] != cycles:
        raise AssertionError("display client fault/restart round counts differ from the trusted profile")
    readiness = body.index(MARKERS["identities"])
    before = body[:readiness]
    if before.count(MARKERS["reclaimed"]) != cycles * 2:
        raise AssertionError("pre-readiness surface generations were not all reclaimed")
    sequence = []
    for line in before.splitlines():
        for name in ("fault", "restart", "reclaimed"):
            if MARKERS[name] in line:
                sequence.append(name)
    if sequence != ["fault", "reclaimed", "reclaimed", "restart"] * cycles:
        # Successful A explicitly closes its surface before printing restart;
        # failed A prints fault before root releases its surface allocation.
        raise AssertionError("surface fault/reclaim/reclaim/restart ordering is invalid")
    if not body.index(MARKERS["archive"]) < body.index(MARKERS["broker"]) < body.index(MARKERS["init"]) < body.index(MARKERS["server"]) < body.index(MARKERS["survival"]) < readiness:
        raise AssertionError("display setup or authenticated readiness ordering is invalid")
    if complete:
        expected = {"reclaimed": 2 if persistent else 7, "input": 1,
                    "focused": 0 if persistent else 1,
                    "balanced": 0 if persistent else 1,
                    "complete": 0 if persistent else 1}
        for name, amount in expected.items():
            if found[name] != amount:
                raise AssertionError(f"display marker {name}: expected {amount}, observed {found[name]}")
        if not persistent and not readiness < body.index(MARKERS["focused"]) < body.index(MARKERS["balanced"]) < body.index(MARKERS["complete"]):
            raise AssertionError("display teardown preceded focused input or completion preceded cleanup")
    elif found["balanced"] or found["complete"]:
        raise AssertionError("display acceptance ended before the host verified scene pixels")
    for marker in runtime_runner.LEGACY_MARKERS + (runtime_runner.MARKERS["complete"],):
        if marker in body:
            raise AssertionError("display boot entered an embedded or alternate runtime profile")
    return found


def pixel_counts(pixels, width, rectangle):
    x, y, columns, rows = rectangle
    result = {"pink": 0, "blue": 0, "green": 0, "base": 0, "text": 0, "muted_text": 0}
    palette = {PINK: "pink", BLUE: "blue", GREEN: "green", WINDOW_BASE: "base", TEXT: "text", MUTED_TEXT: "muted_text"}
    for row in range(y, y + rows):
        start = (row * width + x) * 3
        data = pixels[start:start + columns * 3]
        for index in range(0, len(data), 3):
            name = palette.get(data[index:index + 3])
            if name is None and data[index:index + 3] in TEXT_INK:
                name = "text"
            if name is not None:
                result[name] += 1
    return result


def verify_scene(pixels, width, height, toggled):
    if not 800 <= width <= 1280 or not 600 <= height <= 800 or len(pixels) != width * height * 3:
        raise AssertionError("unexpected protected display dimensions or scanout extent")
    a = pixel_counts(pixels, width, WINDOW_A)
    b = pixel_counts(pixels, width, WINDOW_B)
    expected_b = "green" if toggled else "blue"
    if a["pink"] < 256 or a["base"] < 30000 or a["green"] != 0 or a["text"] < 128 or a["muted_text"] < 64:
        raise AssertionError(f"Surface A native window pixels differ: {a}")
    if b[expected_b] < 256 or b["base"] < 30000 or b["text"] < 128 or b["muted_text"] < 64:
        raise AssertionError(f"Surface B native window pixels differ: {b}")
    if toggled and b["blue"] != 0:
        raise AssertionError("Surface B did not replace its blue accent after focused input")
    return {"surface_a": a, "surface_b": b, "width": width, "height": height}


def parse_ppm(data):
    """Pure reader for the bounded P6 artifact emitted by QMP screendump."""
    if type(data) not in (bytes, bytearray) or not 12 <= len(data) <= 1280 * 800 * 3 + 128:
        raise AssertionError("invalid bounded QMP screenshot bytes")
    parts = bytes(data).split(b"\n", 3)
    if len(parts) != 4 or parts[0].strip() != b"P6" or parts[2].strip() != b"255":
        raise AssertionError("invalid QMP P6 screenshot header")
    try:
        dimensions = parts[1].split()
        if len(dimensions) != 2:
            raise ValueError("two dimensions required")
        width, height = (int(value) for value in dimensions)
    except ValueError as error:
        raise AssertionError("invalid QMP screenshot dimensions") from error
    if not 800 <= width <= 1280 or not 600 <= height <= 800 or len(parts[3]) != width * height * 3:
        raise AssertionError("QMP screenshot pixels are truncated, trailing or out of bounds")
    return width, height, parts[3]


def verify_receipt(receipt, serial, stderr, before_ppm, after_ppm, image=None):
    """Cross-check saved evidence without opening receipt-supplied file paths.

    Callers supply the bytes from their selected artifacts. A successful status
    or boolean claim is insufficient without matching logs, lifecycle, hashes
    and independently recounted screenshot pixels. Current QEMU run behavior
    remains unchanged; this function also supports offline evidence audits.
    """
    if type(receipt) is not dict or receipt.get("status") != "passed" or receipt.get("architecture") not in runtime_runner.ARCHITECTURES or receipt.get("mode") not in ("acceptance", "persistent"):
        raise AssertionError("malformed display verification receipt")
    if type(serial) not in (bytes, bytearray) or type(stderr) not in (bytes, bytearray):
        raise AssertionError("receipt logs must be explicit byte artifacts")
    if len(serial) > runtime_runner.MAX_LOG_BYTES or len(stderr) > runtime_runner.MAX_LOG_BYTES:
        raise AssertionError("receipt log evidence exceeds the captured size bound")
    persistent = receipt["mode"] == "persistent"
    body = bytes(serial).decode("utf-8", errors="replace")
    errors = bytes(stderr).decode("utf-8", errors="replace")
    observed = verify_markers(body, errors, persistent, complete=True)
    recorded_counts = receipt.get("marker_counts")
    if type(recorded_counts) is not dict or any(type(value) is not int for value in recorded_counts.values()) or recorded_counts != observed or receipt.get("marker_text") != MARKERS:
        raise AssertionError("receipt marker counts or definitions differ from captured evidence")
    for field, data in (("serial_sha256", serial), ("stderr_sha256", stderr)):
        if receipt.get(field) != hashlib.sha256(data).hexdigest():
            raise AssertionError("receipt log hash differs from captured evidence")
    for claim in ("native_framebuffer_pixels_verified", "focused_input_changed_only_surface_b", "surface_a_survived_as_pink", "surviving_client_b_kept_same_process", "queued_snapshot_grants_read_only", "fresh_ordinary_data_image"):
        if receipt.get(claim) is not True:
            raise AssertionError("receipt is missing a required verified evidence claim")
    if any(type(receipt.get(field)) is not int for field in ("fault_rounds", "pre_readiness_reclaimed_generations", "total_reclaimed_generations")) or receipt.get("fault_rounds") != observed["fault"] or receipt.get("pre_readiness_reclaimed_generations") != (2 if persistent else 6) or receipt.get("total_reclaimed_generations") != observed["reclaimed"]:
        raise AssertionError("receipt recovery counters differ from the log")
    if receipt.get("teardown_balanced") is not (not persistent) or receipt.get("owned_qemu_terminated_by_runner") is not persistent:
        raise AssertionError("receipt termination ownership or teardown mode is inconsistent")
    if type(receipt.get("qemu_exit")) is not int or (not persistent and receipt["qemu_exit"] != (33 if receipt["architecture"] == "x86_64" else 0)):
        raise AssertionError("receipt QEMU exit does not match its profile")
    live = receipt.get("persistent_seconds_after_readiness")
    elapsed = receipt.get("elapsed_seconds")
    if type(live) not in (int, float) or type(elapsed) not in (int, float) or not math.isfinite(live) or not math.isfinite(elapsed) or elapsed < live or live < (1.0 if persistent else 0.0) or (not persistent and live != 0):
        raise AssertionError("receipt live-process timing is invalid")
    for key, data, toggled in (("before_input", before_ppm, False), ("after_input", after_ppm, True)):
        width, height, pixels = parse_ppm(data)
        actual = verify_scene(pixels, width, height, toggled)
        recorded = receipt.get(key)
        if type(recorded) is not dict or any(recorded.get(field) != value for field, value in actual.items()) or recorded.get("sha256") != hashlib.sha256(data).hexdigest() or type(recorded.get("ppm")) is not str or not recorded["ppm"]:
            raise AssertionError("receipt screenshot metadata differs from actual pixels")
        for field in ("surface_a", "surface_b"):
            if any(type(value) is not int for value in recorded[field].values()):
                raise AssertionError("receipt screenshot pixel counters must be integers")
    if receipt.get("image_kind") not in ("raw-image", "esp-directory", "efi-file") or type(receipt.get("image")) is not str or not receipt["image"]:
        raise AssertionError("receipt boot input is missing or malformed")
    if receipt["image_kind"] == "raw-image":
        digest = receipt.get("image_sha256")
        if type(digest) is not str or len(digest) != 64 or any(character not in "0123456789abcdef" for character in digest):
            raise AssertionError("receipt raw boot-image digest is missing or malformed")
        if image is not None and (type(image) not in (bytes, bytearray) or hashlib.sha256(image).hexdigest() != digest):
            raise AssertionError("receipt raw boot-image digest differs from supplied bytes")
    return observed


class Machine:
    # Reuse the existing real QMP/input implementation, without its Files boot
    # assumptions, media seeding, UI geometry, or unbounded scenario timeout.
    qmp = desktop_runner.Machine.qmp
    input = desktop_runner.Machine.input
    point = desktop_runner.Machine.point
    button = desktop_runner.Machine.button
    click = desktop_runner.Machine.click
    key = desktop_runner.Machine.key

    def __init__(self, args, formatter, code, variables, media, data, outputs):
        self.args = args
        self.formatter = formatter
        self.code, self.variables, self.media, self.data = code, variables, media, data
        self.outputs = outputs
        self.process = self.socket = self.reader = self.log = self.error_log = None
        self.deadline = time.monotonic() + args.timeout
        self.width = self.height = 0

    def __enter__(self):
        with socket.socket() as reservation:
            reservation.bind(("127.0.0.1", 0))
            port = reservation.getsockname()[1]
        command = runtime_runner.command_line(self.args, self.code, self.variables, self.media, self.data)
        command += ["-qmp", f"tcp:127.0.0.1:{port},server=on,wait=off"]
        self.log = self.outputs["serial"].open("wb")
        self.error_log = self.outputs["stderr"].open("wb")
        startup = None
        if sys.platform == "win32":
            startup = subprocess.STARTUPINFO()
            startup.dwFlags |= subprocess.STARTF_USESHOWWINDOW
            startup.wShowWindow = 0
        try:
            self.process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=self.log, stderr=self.error_log,
                                           startupinfo=startup, creationflags=subprocess.CREATE_NO_WINDOW if sys.platform == "win32" else 0)
            while True:
                if time.monotonic() >= self.deadline or self.process.poll() is not None:
                    raise AssertionError("QEMU ended or timed out before QMP became available")
                try:
                    self.socket = socket.create_connection(("127.0.0.1", port), timeout=2)
                    break
                except OSError:
                    time.sleep(.025)
            self.reader = self.socket.makefile("rb")
            greeting = json.loads(self.reader.readline())
            if "QMP" not in greeting:
                raise AssertionError("unexpected localhost QMP greeting")
            self.qmp("qmp_capabilities")
            return self
        except BaseException:
            self.__exit__(*sys.exc_info())
            raise

    def __exit__(self, exception_type, *_):
        try:
            if exception_type is not None and self.socket and self.process and self.process.poll() is None:
                try:
                    self.capture("failure")
                except Exception:
                    pass
            if self.process:
                runtime_runner.stop_owned(self.process)
        finally:
            for handle in (self.reader, self.socket, self.log, self.error_log):
                if handle:
                    try:
                        handle.close()
                    except OSError:
                        pass

    def body(self):
        return runtime_runner.read_log(self.outputs["serial"])

    def errors(self):
        return runtime_runner.read_log(self.outputs["stderr"])

    def check(self):
        if time.monotonic() >= self.deadline:
            raise AssertionError("display runtime scenario exceeded its 60-second bound")
        body = self.body()
        if "[panic]" in body or "[fault]" in body:
            raise AssertionError("display runtime reported a kernel failure")
        if self.process.poll() is not None:
            raise AssertionError(f"display runtime ended before scene verification: {self.process.returncode}")
        return body

    def wait(self, predicate, label):
        while True:
            self.check()
            if predicate():
                return
            time.sleep(.04)

    def capture(self, label):
        path = self.outputs[label]
        self.formatter.validate_output(path)
        self.qmp("screendump", {"filename": str(path.resolve())})
        with path.open("rb") as stream:
            if stream.readline().strip() != b"P6":
                raise AssertionError("QMP did not return a binary RGB screenshot")
            self.width, self.height = map(int, stream.readline().split())
            if not 800 <= self.width <= 1280 or not 600 <= self.height <= 800 or stream.readline().strip() != b"255":
                raise AssertionError("QMP screenshot dimensions or component size are invalid")
            pixels = stream.read(1280 * 800 * 3 + 1)
        if len(pixels) != self.width * self.height * 3:
            raise AssertionError("QMP screenshot has truncated or trailing pixels")
        return pixels

    def scene(self, label, toggled):
        result = None
        def ready():
            nonlocal result
            pixels = self.capture(label)
            try:
                result = verify_scene(pixels, self.width, self.height, toggled)
            except AssertionError:
                return False
            return True
        self.wait(ready, "two protected native window pixels")
        result["ppm"] = str(self.outputs[label].resolve())
        result["sha256"] = hashlib.sha256(self.outputs[label].read_bytes()).hexdigest()
        try:
            from PIL import Image
            with Image.open(self.outputs[label]) as image:
                image.save(self.outputs[label].with_suffix(".png"))
            result["png"] = str(self.outputs[label].with_suffix(".png").resolve())
        except ImportError:
            pass
        return result


def run(args):
    for path in (args.image, args.code, args.vars, args.artifacts):
        runtime_runner.validate_path_syntax(path)
    formatter = runtime_runner.formatter_module()
    code = runtime_runner.ordinary_file(args.code, formatter)
    variables = runtime_runner.ordinary_file(args.vars, formatter)
    formatter.validate_output(args.image / "__bedrock_validation__" if args.image.is_dir() else args.image)
    media, image_kind = runtime_runner.image_drive(args.image, args.arch, formatter)
    if args.artifacts.is_symlink():
        raise ValueError("display verification artifact directory must not be a symbolic link")
    args.artifacts.mkdir(parents=True, exist_ok=True)
    mode = "persistent" if args.persistent else "acceptance"
    prefix = f"display-runtime-{args.arch}-{mode}"
    outputs = {"serial": args.artifacts / (prefix + ".log"),
               "stderr": args.artifacts / (prefix + "-stderr.log"),
               "receipt": args.artifacts / (prefix + ".json")}
    for label in ("initial", "toggled", "failure"):
        outputs[label] = args.artifacts / (prefix + "-" + label + ".ppm")
    inputs = (code, variables) + ((args.image.resolve(),) if args.image.is_file() else ())
    for output in list(outputs.values()) + [outputs[x].with_suffix(".png") for x in ("initial", "toggled")]:
        formatter.validate_output(output)
        for source in inputs:
            if output.resolve() == source or output.exists() and output.samefile(source):
                raise ValueError("display verification artifacts must differ from every boot input")
    outputs["receipt"].unlink(missing_ok=True)
    started = time.monotonic()
    live_after_readiness = 0.0
    try:
        with tempfile.TemporaryDirectory(prefix="bedrock-display-runtime-") as temporary:
            data = Path(temporary) / "data.img"
            formatter.write_image(data)
            with Machine(args, formatter, code, variables, media, data, outputs) as machine:
                machine.wait(lambda: MARKERS["identities"] in machine.body(), "display identity and ownership readiness")
                ready_at = time.monotonic()
                verify_markers(machine.body(), machine.errors(), args.persistent, complete=False)
                initial = machine.scene("initial", toggled=False)
                machine.click(500, 276)
                machine.wait(lambda: MARKERS["input"] in machine.body(), "focused Surface B input")
                toggled = machine.scene("toggled", toggled=True)
                if args.persistent:
                    while time.monotonic() - ready_at < 1.0:
                        machine.check()
                        time.sleep(.025)
                    live_after_readiness = time.monotonic() - ready_at
                    verify_markers(machine.body(), machine.errors(), True, complete=True)
                else:
                    # The acceptance kernel interprets this host-only finish
                    # key after readiness and actual focused pointer input.
                    machine.key("f11")
                    while machine.process.poll() is None:
                        if time.monotonic() >= machine.deadline:
                            raise AssertionError("display acceptance did not complete after host finish")
                        if "[panic]" in machine.body() or "[fault]" in machine.body():
                            raise AssertionError("display acceptance failed during teardown")
                        time.sleep(.025)
                    expected = 33 if args.arch == "x86_64" else 0
                    if machine.process.returncode != expected:
                        raise AssertionError(f"display acceptance exit {machine.process.returncode}; expected {expected}")
                    verify_markers(machine.body(), machine.errors(), False, complete=True)
            body = runtime_runner.read_log(outputs["serial"])
            errors = runtime_runner.read_log(outputs["stderr"])
            found = verify_markers(body, errors, args.persistent, complete=True)
            receipt = {
                "architecture": args.arch, "mode": mode, "status": "passed",
                "image": str(args.image.resolve()), "image_kind": image_kind,
                "marker_counts": found, "marker_text": MARKERS,
                "native_framebuffer_pixels_verified": True,
                "focused_input_changed_only_surface_b": True,
                "surface_a_survived_as_pink": True,
                "surviving_client_b_kept_same_process": True,
                "queued_snapshot_grants_read_only": True,
                "before_input": initial, "after_input": toggled,
                "fault_rounds": found["fault"],
                "pre_readiness_reclaimed_generations": 2 if args.persistent else 6,
                "total_reclaimed_generations": found["reclaimed"],
                "teardown_balanced": found["balanced"] == 1,
                "persistent_seconds_after_readiness": live_after_readiness,
                "qemu_exit": machine.process.returncode,
                "owned_qemu_terminated_by_runner": args.persistent,
                "fresh_ordinary_data_image": True,
                "elapsed_seconds": time.monotonic() - started,
                "serial_sha256": hashlib.sha256(outputs["serial"].read_bytes()).hexdigest(),
                "stderr_sha256": hashlib.sha256(outputs["stderr"].read_bytes()).hexdigest(),
                "serial": str(outputs["serial"].resolve()), "stderr": str(outputs["stderr"].resolve()),
            }
            if image_kind == "raw-image":
                receipt["image_sha256"] = hashlib.sha256(args.image.read_bytes()).hexdigest()
            outputs["receipt"].write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
    except BaseException:
        for path in (outputs["serial"], outputs["stderr"]):
            if path.exists():
                print(runtime_runner.read_log(path)[-8000:], file=sys.stderr)
        raise
    print(f"{args.arch}: protected display {mode} passed; native two-window pixels, focused input, {found['fault']} faults and {found['reclaimed']} reclaimed A surfaces")
    print(f"Verification receipt: {outputs['receipt']}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--arch", required=True, choices=runtime_runner.ARCHITECTURES)
    parser.add_argument("--image", type=Path, required=True)
    parser.add_argument("--qemu")
    parser.add_argument("--code", type=Path)
    parser.add_argument("--vars", type=Path)
    parser.add_argument("--ram-mib", type=int, default=256)
    parser.add_argument("--timeout", type=float, default=60)
    parser.add_argument("--persistent", action="store_true")
    parser.add_argument("--artifacts", type=Path, default=ROOT / "zig-out/display-runtime-tests")
    args = parser.parse_args()
    if not math.isfinite(args.timeout) or not 1 <= args.timeout <= 60:
        parser.error("timeout must be a finite duration between 1 and 60 seconds")
    if not 128 <= args.ram_mib <= 65536:
        parser.error("ram-mib must be between 128 and 65536")
    qemu, code, variables = runtime_runner.default_paths(args.arch)
    args.qemu = args.qemu or qemu
    args.code = args.code or code
    args.vars = args.vars or variables
    try:
        run(args)
    except (AssertionError, ValueError, OSError, subprocess.SubprocessError) as error:
        print(f"Display runtime verification failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
