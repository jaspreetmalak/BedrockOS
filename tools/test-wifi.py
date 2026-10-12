#!/usr/bin/env python3
"""Verify protected Wi-Fi control in simulated or unavailable-radio profiles.

No physical radio, access point, credential or host network is accessed. Each
QEMU run owns a newly formatted temporary data disk; installed ESP/firmware
inputs use read-only or private snapshot overlays.
"""
import argparse
import hashlib
import importlib.util
import json
import math
from pathlib import Path
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent
EFI_NAMES = {"x86_64": "BOOTX64.EFI", "arm64": "BOOTAA64.EFI", "riscv64": "BOOTRISCV64.EFI"}
MARKERS = (
    "[kernel] Wi-Fi simulated test radio active",
    "[user] Wi-Fi scan verified",
    "[user] Wi-Fi authentication policy verified",
    "[user] Wi-Fi control lifecycle verified",
    "[user] Wi-Fi authority checks passed",
    "[kernel] Wi-Fi control cleanup verified",
    "[kernel] native process cleanup verified",
)
ABSENT_MARKERS = (
    "[kernel] Wi-Fi physical driver unavailable",
    "[user] Wi-Fi unavailable status verified",
    "[user] Wi-Fi observer control denied",
    "[kernel] Wi-Fi control cleanup verified",
    "[kernel] native process cleanup verified",
)


def artifact_stem(args):
    suffix = "-absent" if args.radio == "absent" else ""
    return f"wifi-{args.architecture}{suffix}"


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest() if path.is_file() else None


def drive_path(path):
    # QEMU drive options escape literal commas by doubling them. Popen's argv
    # list separately preserves spaces without a shell or command interpolation.
    return str(path).replace(",", ",,")


def command_line(args, data):
    x86 = args.architecture == "x86_64"
    arm = args.architecture == "arm64"
    machine = "pc-q35-10.1" if x86 else "virt-10.1,secure=off,virtualization=off,acpi=off" if arm else "virt,acpi=off"
    cpu = "qemu64" if x86 else "cortex-a57" if arm else "rv64"
    command = [
        args.qemu, "-machine", machine, "-cpu", cpu, "-accel", "tcg",
        "-smp", "1", "-m", "256M", "-display", "none", "-serial", "stdio",
        "-monitor", "none", "-no-reboot", "-nic", "none",
        "-drive", f"if=pflash,format=raw,readonly=on,file={drive_path(args.code)}",
        "-drive", f"if=pflash,format=raw,snapshot=on,file={drive_path(args.variables)}",
    ]
    if x86:
        command += [
            "-drive", f"format=raw,snapshot=on,file=fat:{drive_path(args.esp)}",
            "-drive", f"if=none,id=bedrock-data,format=raw,file={drive_path(data)}",
            "-device", "virtio-blk-pci,drive=bedrock-data,disable-legacy=on,serial=bedrock-data",
            "-device", "isa-debug-exit,iobase=0xf4,iosize=4",
        ]
    else:
        command += [
            "-global", "virtio-mmio.force-legacy=false",
            "-drive", f"if=none,id=bedrock-esp,format=raw,snapshot=on,file=fat:{drive_path(args.esp)}",
            "-device", "virtio-blk-device,drive=bedrock-esp",
            "-drive", f"if=none,id=bedrock-data,format=raw,file={drive_path(data)}",
            "-device", "virtio-blk-device,drive=bedrock-data,serial=bedrock-data",
        ]
        command += ["-semihosting-config", "enable=on,target=native"] if arm else ["-bios", "default"]
    return command


def check_output(body, stderr, architecture, returncode, radio="simulated"):
    expected = 33 if architecture == "x86_64" else 0
    if returncode != expected:
        raise AssertionError(f"Unexpected QEMU exit {returncode}; expected {expected}")
    combined = (body + stderr).lower()
    if "[panic]" in combined or "panic:" in combined or "[fault]" in combined:
        raise AssertionError("QEMU reported a kernel panic or fault")
    markers = ABSENT_MARKERS if radio == "absent" else MARKERS
    forbidden = MARKERS[:5] if radio == "absent" else ABSENT_MARKERS[:3]
    if any(marker in body for marker in forbidden):
        raise AssertionError(f"Contradictory {radio} radio checkpoints")
    counts = {marker: body.count(marker) for marker in markers}
    for marker, count in counts.items():
        if count != 1:
            raise AssertionError(f"Missing/duplicate marker ({count}): {marker}")
    # These ordered checkpoints are emitted by the protected caller and then
    # kernel teardown; their presence proves policy/lifecycle, not RF or WPA.
    activation = body.index(markers[0])
    caller = [body.index(marker) for marker in markers[1:-2]]
    cleanup = body.index(markers[-2])
    native_cleanup = body.index(markers[-1])
    if not (activation < min(caller) and max(caller) < cleanup < native_cleanup):
        raise AssertionError("Wi-Fi caller and cleanup checkpoints appeared out of order")
    return counts


def stop_owned_process(process):
    if process.poll() is None:
        process.kill()
    process.wait(timeout=5)


def run(args):
    args.artifacts.mkdir(parents=True, exist_ok=True)
    stem = artifact_stem(args)
    receipt = args.artifacts / f"{stem}-verification.json"
    receipt.unlink(missing_ok=True)
    log_path = args.artifacts / f"{stem}.log"
    error_path = args.artifacts / f"{stem}-stderr.log"
    # Clear previous diagnostic files even if input preflight fails.
    log_path.write_bytes(b"")
    error_path.write_bytes(b"")
    efi = args.esp / "EFI" / "BOOT" / EFI_NAMES[args.architecture]
    value = {
        "architecture": args.architecture,
        "mode": args.mode,
        "status": "failed",
        "radio_mode": args.radio,
        "simulated": args.radio == "simulated",
        "physical_supported": False,
        "radio_backend": "deterministic simulated test radio" if args.radio == "simulated" else "physical-driver-unavailable",
        "physical_radio_accessed": False,
        "host_network_accessed": False,
        "network_device_attached": False,
        "data_disk": "owned ephemeral formatted image",
        "timeout_seconds": args.timeout,
        "expected_exit": 33 if args.architecture == "x86_64" else 0,
        "qemu_exit": None,
        "boot_efi": str(efi),
        "boot_efi_sha256": None,
        "serial_sha256": None,
        "stderr_sha256": None,
        "physical_authentication_verified": False,
    }
    started = time.monotonic()
    try:
        if not math.isfinite(args.timeout) or args.timeout <= 0:
            raise ValueError("Timeout must be finite and positive")
        for path in (args.code, args.variables, efi):
            if not path.is_file():
                raise ValueError(f"Missing UEFI input file: {path}")
        value["boot_efi_sha256"] = digest(efi)
        specification = importlib.util.spec_from_file_location("wifi_data_formatter", ROOT / "tools/make-data-image.py")
        formatter = importlib.util.module_from_spec(specification)
        specification.loader.exec_module(formatter)
        with tempfile.TemporaryDirectory(prefix=f"bedrock-wifi-{args.radio}-") as temporary:
            data = Path(temporary) / "data.img"
            formatter.write_image(data)
            startup = None
            if sys.platform == "win32":
                startup = subprocess.STARTUPINFO()
                startup.dwFlags |= subprocess.STARTF_USESHOWWINDOW
                startup.wShowWindow = 0
            flags = subprocess.CREATE_NO_WINDOW if sys.platform == "win32" else 0
            with log_path.open("wb") as log, error_path.open("wb") as stderr:
                process = subprocess.Popen(
                    command_line(args, data), stdin=subprocess.DEVNULL,
                    stdout=log, stderr=stderr, startupinfo=startup,
                    creationflags=flags,
                )
                try:
                    try:
                        process.wait(timeout=args.timeout)
                    except subprocess.TimeoutExpired as error:
                        raise AssertionError("QEMU Wi-Fi control acceptance timed out") from error
                    value["qemu_exit"] = process.returncode
                finally:
                    stop_owned_process(process)
                    value["qemu_exit"] = process.returncode
            body = log_path.read_text(errors="replace")
            errors = error_path.read_text(errors="replace")
            value["marker_counts"] = check_output(body, errors, args.architecture, process.returncode, args.radio)
            if digest(efi) != value["boot_efi_sha256"]:
                raise AssertionError("Boot EFI input changed during the acceptance run")
            value.update({
                "status": "passed",
                "protected_caller": True,
                "control_cleanup_verified": True,
                "native_process_cleanup_verified": True,
            })
            if args.radio == "simulated":
                value.update({
                    "simulated_scan_verified": True,
                    "authentication_policy_verified": True,
                    "control_lifecycle_verified": True,
                    "authority_checks_verified": True,
                })
            else:
                value.update({
                    "production_unavailable_path_verified": True,
                    "unavailable_status_verified": True,
                    "observer_control_denied": True,
                })
    except BaseException as error:
        value["error"] = f"{type(error).__name__}: {error}"
        raise
    finally:
        value["elapsed_seconds"] = round(time.monotonic() - started, 3)
        value["serial_sha256"] = digest(log_path)
        value["stderr_sha256"] = digest(error_path)
        receipt.write_text(json.dumps(value, indent=2) + "\n")
    scope = "SIMULATED Wi-Fi scan, policy and control lifecycle" if args.radio == "simulated" else "production unavailable-radio status and observer control denial"
    print(f"{args.architecture}: {scope} and cleanup passed; physical Wi-Fi unsupported")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("architecture", choices=tuple(EFI_NAMES))
    parser.add_argument("qemu")
    parser.add_argument("esp", type=Path)
    parser.add_argument("code", type=Path)
    parser.add_argument("variables", type=Path)
    parser.add_argument("--mode", choices=("debug", "safe"), default="debug")
    parser.add_argument("--radio", choices=("simulated", "absent"), default="simulated")
    parser.add_argument("--artifacts", type=Path)
    parser.add_argument("--timeout", type=float, default=80)
    args = parser.parse_args()
    args.esp = args.esp.resolve()
    args.code = args.code.resolve()
    args.variables = args.variables.resolve()
    if args.artifacts is None:
        args.artifacts = ROOT / "zig-out" / "wifi-tests" / args.mode
    try:
        run(args)
    except BaseException:
        stem = artifact_stem(args)
        for path in (args.artifacts / f"{stem}.log",
                     args.artifacts / f"{stem}-stderr.log"):
            if path.exists():
                print(path.read_text(errors="replace")[-4000:], file=sys.stderr)
        raise


if __name__ == "__main__":
    main()
