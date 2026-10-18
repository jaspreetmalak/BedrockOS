#!/usr/bin/env python3
"""Boot installed applications with fresh ordinary data media and owned QEMU.

Acceptance verifies three fault/relaunch rounds and complete resource teardown.
Persistent mode verifies one round and observes a still-live supervisor. Missing
mode checks archive refusal without an embedded acceptance-program fallback.
"""
import argparse
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path, PureWindowsPath
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent
ARCHITECTURES = ("x86_64", "arm64", "riscv64")
BOOT_NAMES = {"x86_64": "BOOTX64.EFI", "arm64": "BOOTAA64.EFI", "riscv64": "BOOTRISCV64.EFI"}
MARKERS = {
    "archive": "[bootloader] application archive staged",
    "init": "[kernel] installed native init ready; persistent supervisor",
    "observer": "[app] observer ready",
    "fault": "[app] worker fault requested",
    "restart": "[app] worker restart verified",
    "reclaimed": "[kernel] worker generation reclaimed; observer retained",
    "worker": "[app] worker running",
    "identities": "[kernel] installed app identities 101/102/103 verified",
    "survival": "[kernel] observer survived worker faults; zeroed heaps and relaunch cleanup verified",
    "supervision": "[app] init supervision verified",
    "balanced": "[kernel] installed app teardown balanced; pages handles pipes reclaimed",
    "complete": "[kernel] application runtime acceptance complete",
}
MISSING_ERROR = "InstalledApplicationArchiveMissing"
LEGACY_MARKERS = ("[user] init lifecycle verified", "[kernel] native process lifecycle verified",
                  "[kernel] native process cleanup verified", "[user] protected Files ready")
MAX_LOG_BYTES = 4 * 1024 * 1024


def formatter_module():
    spec = importlib.util.spec_from_file_location("bedrock_application_data_formatter", ROOT / "tools/make-data-image.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def validate_path_syntax(path):
    if os.name != "nt":
        return
    text = str(path).replace("/", "\\")
    if text.startswith(("\\\\.\\", "\\\\?\\", "\\??\\")):
        raise ValueError("Windows device and namespace paths are not supported")
    parsed = PureWindowsPath(text)
    reserved = {"CON", "PRN", "AUX", "NUL", "CONIN$", "CONOUT$"}
    reserved.update(prefix + digit for prefix in ("COM", "LPT") for digit in "123456789\u00b9\u00b2\u00b3")
    for component in parsed.parts:
        if component == parsed.anchor or component in (".", ".."):
            continue
        base = component.rstrip(" .").partition(".")[0].rstrip(" ").upper()
        if base in reserved or component.endswith((" ", ".")) or any(character in '<>:"|?*' or ord(character) < 32 for character in component):
            raise ValueError("verification requires ordinary Windows file paths")


def default_paths(arch):
    executable = "qemu-system-" + {"arm64": "aarch64"}.get(arch, arch)
    if sys.platform == "win32":
        directory = Path(os.environ.get("ProgramFiles", "C:/Program Files")) / "qemu"
        qemu = directory / (executable + ".exe")
        share = directory / "share"
        names = {"x86_64": ("edk2-x86_64-code.fd", "edk2-i386-vars.fd"),
                 "arm64": ("edk2-aarch64-code.fd", "edk2-arm-vars.fd"),
                 "riscv64": ("edk2-riscv-code.fd", "edk2-riscv-vars.fd")}[arch]
        return str(qemu), share / names[0], share / names[1]
    if arch == "x86_64":
        code, variables = Path("/usr/share/OVMF/OVMF_CODE.fd"), Path("/usr/share/OVMF/OVMF_VARS.fd")
    else:
        share = Path("/usr/share/qemu")
        code = share / ("edk2-aarch64-code.fd" if arch == "arm64" else "edk2-riscv-code.fd")
        variables = share / ("edk2-arm-vars.fd" if arch == "arm64" else "edk2-riscv-vars.fd")
    return shutil.which(executable) or executable, code, variables


def ordinary_file(path, formatter):
    formatter.validate_output(path)
    if not path.is_file():
        raise ValueError(f"required ordinary file is missing: {path}")
    return path.resolve()


def drive_path(path):
    # QEMU parses commas inside -drive arguments independently of argv quoting.
    return str(path).replace(",", ",,")


def image_drive(path, arch, formatter):
    if path.is_dir():
        if path.is_symlink():
            raise ValueError("the ESP directory must not be a symbolic link")
        ordinary_file(path / "EFI/BOOT" / BOOT_NAMES[arch], formatter)
        return "fat:" + drive_path(path.resolve()), "esp-directory"
    image = ordinary_file(path, formatter)
    if image.suffix.lower() == ".efi":
        if image.name.upper() != BOOT_NAMES[arch] or image.parent.name.upper() != "BOOT" or image.parent.parent.name.upper() != "EFI":
            raise ValueError("an EFI input must occupy its matching EFI/BOOT removable-media path")
        return "fat:" + drive_path(image.parent.parent.parent), "efi-file"
    if image.stat().st_size != 64 * 1024 * 1024:
        raise ValueError("a raw UEFI image must be the ordinary 64 MiB GPT/FAT32 artifact")
    return drive_path(image), "raw-image"


def command_line(args, code, variables, media, data):
    x86 = args.arch == "x86_64"
    arm = args.arch == "arm64"
    machine = "pc-q35-10.1" if x86 else "virt-10.1,secure=off,virtualization=off,acpi=off" if arm else "virt,acpi=off"
    cpu = "qemu64" if x86 else "cortex-a57" if arm else "rv64"
    command = [args.qemu, "-machine", machine, "-cpu", cpu, "-accel", "tcg", "-smp", "1", "-m", f"{args.ram_mib}M",
               "-display", "none", "-serial", "stdio", "-monitor", "none", "-no-reboot", "-nic", "none",
               "-drive", f"if=pflash,format=raw,readonly=on,file={drive_path(code)}",
               "-drive", f"if=pflash,format=raw,snapshot=on,file={drive_path(variables)}"]
    if x86:
        command.extend(["-drive", f"format=raw,snapshot=on,file={media}",
                        "-drive", f"if=none,id=bedrock-data,format=raw,file={drive_path(data)}",
                        "-device", "virtio-blk-pci,drive=bedrock-data,disable-legacy=on,serial=bedrock-data",
                        "-device", "virtio-keyboard-pci,disable-legacy=on", "-device", "virtio-tablet-pci,disable-legacy=on",
                        "-device", "isa-debug-exit,iobase=0xf4,iosize=4"])
    else:
        command.extend(["-global", "virtio-mmio.force-legacy=false",
                        "-drive", f"if=none,id=bedrock-esp,format=raw,snapshot=on,file={media}",
                        "-device", "virtio-blk-device,drive=bedrock-esp", "-device", "ramfb",
                        "-drive", f"if=none,id=bedrock-data,format=raw,file={drive_path(data)}",
                        "-device", "virtio-blk-device,drive=bedrock-data,serial=bedrock-data",
                        "-device", "virtio-keyboard-device", "-device", "virtio-tablet-device"])
        command.extend(["-semihosting-config", "enable=on,target=native"] if arm else ["-bios", "default"])
    return command


def read_log(path):
    with path.open("rb") as stream:
        data = stream.read(MAX_LOG_BYTES + 1)
    if len(data) > MAX_LOG_BYTES:
        raise AssertionError("QEMU exceeded the bounded serial/error log size")
    return data.decode("utf-8", errors="replace")


def marker_counts(body):
    return {key: body.count(marker) for key, marker in MARKERS.items()}


def verify_output(body, errors, mode):
    counts = marker_counts(body)
    combined = body + "\n" + errors
    if mode == "missing":
        if body.count(MISSING_ERROR) != 1:
            raise AssertionError("missing archive did not report its exact installed-runtime failure")
        if any(counts.values()) or any(marker in body for marker in LEGACY_MARKERS):
            raise AssertionError("missing archive entered an installed app or an embedded fallback")
        for line in combined.splitlines():
            if "[panic]" in line or "[fault]" in line and MISSING_ERROR not in line:
                raise AssertionError("missing archive reported an unrelated kernel failure")
        return counts
    if "[panic]" in combined or "[fault]" in combined or MISSING_ERROR in combined:
        raise AssertionError("installed application boot reported a kernel failure")
    cycles = 1 if mode == "persistent" else 3
    required = {"archive": 1, "init": 1, "observer": 1, "fault": cycles,
                "restart": cycles, "reclaimed": cycles * 2, "worker": 1,
                "identities": 1, "survival": 1, "supervision": 1,
                "balanced": 0 if mode == "persistent" else 1,
                "complete": 0 if mode == "persistent" else 1}
    for key, expected in required.items():
        if counts[key] != expected:
            raise AssertionError(f"marker {key!r}: expected {expected}, observed {counts[key]} ({MARKERS[key]})")
    if any(marker in body for marker in LEGACY_MARKERS):
        raise AssertionError("installed application boot entered an embedded legacy profile")
    lifecycle = []
    for line in body.splitlines():
        for key in ("fault", "restart", "reclaimed"):
            if MARKERS[key] in line:
                lifecycle.append(key)
    if lifecycle != ["fault", "reclaimed", "restart", "reclaimed"] * cycles:
        raise AssertionError("worker fault/reap/restart/reap sequence is invalid")
    if not body.index(MARKERS["archive"]) < body.index(MARKERS["init"]) < body.index(MARKERS["observer"]) < body.index(MARKERS["supervision"]):
        raise AssertionError("application archive/init/observer/supervision ordering is invalid")
    if not body.index(MARKERS["supervision"]) < body.index(MARKERS["identities"]) < body.index(MARKERS["survival"]):
        raise AssertionError("installed identity and survival checks preceded init's readiness report")
    if mode == "acceptance" and not body.index(MARKERS["survival"]) < body.index(MARKERS["balanced"]) < body.index(MARKERS["complete"]):
        raise AssertionError("acceptance completed before its survival and resource checks")
    return counts


def stop_owned(process):
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)
    else:
        process.wait(timeout=5)


def run(args):
    for path in (args.image, args.code, args.vars, args.artifacts):
        validate_path_syntax(path)
    formatter = formatter_module()
    code = ordinary_file(args.code, formatter)
    variables = ordinary_file(args.vars, formatter)
    # Validate Windows device syntax even when image names a directory.
    formatter.validate_output(args.image / "__bedrock_validation__" if args.image.is_dir() else args.image)
    media, image_kind = image_drive(args.image, args.arch, formatter)
    if args.artifacts.is_symlink():
        raise ValueError("verification artifact directory must not be a symbolic link")
    args.artifacts.mkdir(parents=True, exist_ok=True)
    mode = "persistent" if args.persistent else "missing" if args.missing else "acceptance"
    prefix = f"application-runtime-{args.arch}-{mode}"
    serial_path = args.artifacts / (prefix + ".log")
    error_path = args.artifacts / (prefix + "-stderr.log")
    receipt_path = args.artifacts / (prefix + ".json")
    formatter.validate_output(serial_path)
    formatter.validate_output(error_path)
    formatter.validate_output(receipt_path)
    inputs = (code, variables) + ((args.image.resolve(),) if args.image.is_file() else ())
    for target in (serial_path, error_path, receipt_path):
        for source in inputs:
            if target.resolve() == source or target.exists() and os.path.samefile(target, source):
                raise ValueError("verification logs and receipts must differ from every boot input")
    receipt_path.unlink(missing_ok=True)
    observed_live = 0.0
    terminated_by_runner = False
    started = time.monotonic()
    with tempfile.TemporaryDirectory(prefix="bedrock-application-runtime-") as temporary:
        data = Path(temporary) / "data.img"
        formatter.write_image(data)
        command = command_line(args, code, variables, media, data)
        startup = None
        if sys.platform == "win32":
            startup = subprocess.STARTUPINFO()
            startup.dwFlags |= subprocess.STARTF_USESHOWWINDOW
            startup.wShowWindow = 0
        try:
            with serial_path.open("wb") as serial, error_path.open("wb") as errors:
                process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=serial, stderr=errors,
                                           startupinfo=startup, creationflags=subprocess.CREATE_NO_WINDOW if sys.platform == "win32" else 0)
                try:
                    deadline = time.monotonic() + args.timeout
                    ready_at = None
                    while True:
                        body = read_log(serial_path)
                        error_text = read_log(error_path)
                        status = process.poll()
                        if mode == "persistent" and MARKERS["survival"] in body:
                            verify_output(body, error_text, mode)
                            if status is not None:
                                raise AssertionError("persistent init exited after reporting readiness")
                            if ready_at is None:
                                ready_at = time.monotonic()
                            observed_live = time.monotonic() - ready_at
                            if observed_live >= 1.0:
                                terminated_by_runner = True
                                break
                        elif mode == "missing" and MISSING_ERROR in body:
                            verify_output(body, error_text, mode)
                            terminated_by_runner = status is None
                            break
                        elif status is not None:
                            if mode == "acceptance":
                                verify_output(body, error_text, mode)
                                expected_exit = 33 if args.arch == "x86_64" else 0
                                if status != expected_exit:
                                    raise AssertionError(f"unexpected acceptance QEMU exit {status}; expected {expected_exit}")
                                break
                            raise AssertionError(f"QEMU exited {status} before {mode} verification")
                        if mode != "missing" and ("[panic]" in body or "[fault]" in body):
                            raise AssertionError("QEMU reported a kernel failure before readiness")
                        if time.monotonic() >= deadline:
                            raise AssertionError(f"application runtime {mode} exceeded {args.timeout:g} seconds")
                        time.sleep(.025)
                finally:
                    stop_owned(process)
            body = read_log(serial_path)
            errors = read_log(error_path)
            counts = verify_output(body, errors, mode)
            value = {
                "architecture": args.arch, "mode": mode, "status": "passed",
                "image": str(args.image.resolve()), "image_kind": image_kind,
                "fresh_ordinary_data_image": True, "kernel_failure_absent": mode != "missing",
                "embedded_fallback_absent": True, "marker_counts": counts,
                "marker_text": MARKERS,
                "worker_fault_rounds": counts["fault"], "reclaimed_generations": counts["reclaimed"],
                "teardown_balanced": counts["balanced"] == 1,
                "persistent_seconds_after_readiness": observed_live,
                "owned_qemu_terminated_by_runner": terminated_by_runner,
                "qemu_exit": process.returncode, "elapsed_seconds": time.monotonic() - started,
                "serial_sha256": hashlib.sha256(serial_path.read_bytes()).hexdigest(),
                "stderr_sha256": hashlib.sha256(error_path.read_bytes()).hexdigest(),
                "serial": str(serial_path.resolve()), "stderr": str(error_path.resolve()),
            }
            receipt_path.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")
        except BaseException:
            for path in (serial_path, error_path):
                if path.exists():
                    print(read_log(path)[-8000:], file=sys.stderr)
            raise
    print(f"{args.arch}: application runtime {mode} passed; {counts['fault']} faults, {counts['restart']} restarts, {counts['reclaimed']} reclaimed generations")
    print(f"Verification receipt: {receipt_path}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--arch", required=True, choices=ARCHITECTURES)
    parser.add_argument("--image", type=Path, required=True)
    parser.add_argument("--qemu")
    parser.add_argument("--code", type=Path)
    parser.add_argument("--vars", type=Path)
    parser.add_argument("--ram-mib", type=int, default=256)
    parser.add_argument("--timeout", type=float, default=60)
    parser.add_argument("--artifacts", type=Path, default=ROOT / "zig-out/application-runtime-tests")
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument("--persistent", action="store_true")
    modes.add_argument("--missing", action="store_true")
    args = parser.parse_args()
    if not math.isfinite(args.timeout) or not 1 <= args.timeout <= 60:
        parser.error("timeout must be a finite duration between 1 and 60 seconds")
    if not 128 <= args.ram_mib <= 65536:
        parser.error("ram-mib must be between 128 and 65536")
    qemu, code, variables = default_paths(args.arch)
    args.qemu = args.qemu or qemu
    args.code = args.code or code
    args.vars = args.vars or variables
    try:
        run(args)
    except (AssertionError, ValueError, OSError, subprocess.SubprocessError) as error:
        print(f"Application runtime verification failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
