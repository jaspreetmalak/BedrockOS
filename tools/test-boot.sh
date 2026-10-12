#!/bin/sh
set -eu

# Requires python3 for subprocess timeout, concurrent pipe capture, and argv
# handling that preserves spaces without invoking a command shell.
# Usage: sh tools/test-boot.sh ARCH QEMU IMAGE [TIMEOUT] [RAM_MIB] [UEFI_CODE] [UEFI_VARS]
if [ "$#" -lt 3 ] || [ "$#" -gt 7 ]; then
    echo 'Usage: test-boot.sh ARCH QEMU IMAGE [TIMEOUT] [RAM_MIB] [UEFI_CODE] [UEFI_VARS]' >&2
    exit 2
fi

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
export BEDROCK_IMAGE_TOOL="$script_directory/make-data-image.py"
exec python3 - "$@" <<'PY'
import argparse
import os
from pathlib import Path
import subprocess
import sys
import tempfile

parser = argparse.ArgumentParser(description="Run a bounded Bedrock emulator smoke test.")
parser.add_argument("architecture", choices=("arm64", "x86_64", "riscv64", "x86_64-uefi", "x86_64-uefi-image", "arm64-uefi", "riscv64-uefi"))
parser.add_argument("qemu_executable")
parser.add_argument("firmware_image")
parser.add_argument("timeout_seconds", nargs="?", type=int, default=60)
parser.add_argument("ram_mib", nargs="?", type=int, default=128)
parser.add_argument("uefi_code", nargs="?")
parser.add_argument("uefi_vars", nargs="?")
args = parser.parse_args()
image_tool = Path(os.environ["BEDROCK_IMAGE_TOOL"])
if not 1 <= args.timeout_seconds <= 3600:
    parser.error("timeout_seconds must be between 1 and 3600")
if not 16 <= args.ram_mib <= 65536:
    parser.error("ram_mib must be between 16 and 65536")
firmware_image = Path(args.firmware_image)
if not firmware_image.is_file():
    parser.error(f"Firmware image does not exist: {firmware_image}")

profiles = {
    "arm64": ("ARM64", "virt-10.1,secure=off,virtualization=off", "cortex-a57", 0),
    "arm64-uefi": ("ARM64", "virt-10.1,secure=off,virtualization=off,acpi=off", "cortex-a57", 0),
    "x86_64": ("x86_64", "pc-i440fx-10.1", "qemu64", 33),
    "x86_64-uefi": ("x86_64", "pc-q35-10.1", "qemu64", 33),
    "x86_64-uefi-image": ("x86_64", "pc-q35-10.1", "qemu64", 33),
    # Installed QEMU has no versioned RISC-V virt machine alias.
    "riscv64": ("riscv64", "virt", "rv64", 0),
    "riscv64-uefi": ("riscv64", "virt,acpi=off", "rv64", 0),
}
architecture_tag, machine, cpu, expected_exit_code = profiles[args.architecture]
command = [
    args.qemu_executable,
    "-machine", machine,
    "-cpu", cpu,
    "-accel", "tcg",
    "-smp", "1",
    "-m", f"{args.ram_mib}M",
    "-display", "none",
    "-serial", "stdio",
    "-monitor", "none",
]
if "-uefi" in args.architecture:
    if not args.uefi_code or not args.uefi_vars or not Path(args.uefi_code).is_file() or not Path(args.uefi_vars).is_file():
        parser.error("UEFI tests require matching firmware code and variable-store files")
    command += [
        "-drive", f"if=pflash,format=raw,readonly=on,file={args.uefi_code}",
        "-drive", f"if=pflash,format=raw,snapshot=on,file={args.uefi_vars}",
    ]
    if args.architecture.startswith("x86_64"):
        data_device = "virtio-blk-pci,drive=bedrock-data,disable-legacy=on,serial=bedrock-data"
    else:
        command += ["-global", "virtio-mmio.force-legacy=false"]
        data_device = "virtio-blk-device,drive=bedrock-data,serial=bedrock-data"
    if args.architecture == "x86_64-uefi-image":
        command += ["-drive", f"format=raw,snapshot=on,file={firmware_image.resolve()}"]
    else:
        esp = firmware_image.resolve().parent.parent.parent
        if args.architecture.startswith("x86_64"):
            command += ["-drive", f"format=raw,snapshot=on,file=fat:{esp}"]
        else:
            command += ["-drive", f"if=none,id=bedrock-esp,format=raw,snapshot=on,file=fat:{esp}", "-device", "virtio-blk-device,drive=bedrock-esp"]
else:
    command += ["-bios", str(firmware_image.resolve())]
if args.architecture.startswith("arm64"):
    command += ["-semihosting-config", "enable=on,target=native"]
    if args.architecture == "arm64-uefi":
        command += ["-no-reboot"]
elif args.architecture.startswith("x86_64"):
    command += ["-no-reboot", "-device", "isa-debug-exit,iobase=0xf4,iosize=4"]
else:
    command += ["-no-reboot"]
    if args.architecture == "riscv64-uefi":
        command += ["-bios", "default"]


def emit_output(stdout, stderr):
    # TimeoutExpired may contain bytes even when run() requested text output.
    if isinstance(stdout, bytes):
        stdout = stdout.decode("utf-8", errors="replace")
    if isinstance(stderr, bytes):
        stderr = stderr.decode("utf-8", errors="replace")
    sys.stdout.write(stdout or "")
    sys.stdout.flush()
    sys.stderr.write(stderr or "")
    sys.stderr.flush()


def fail(message):
    print(f"{architecture_tag} smoke test failed: {message}", file=sys.stderr)
    raise SystemExit(1)


try:
    with tempfile.TemporaryDirectory(prefix="bedrock-data-") as temporary:
        if "-uefi" in args.architecture:
            data_image = Path(temporary) / "data.img"
            subprocess.run([sys.executable, str(image_tool), str(data_image)], check=True)
            command += ["-drive", f"if=none,id=bedrock-data,format=raw,file={str(data_image).replace(',', ',,')}", "-device", data_device]
        result = subprocess.run(
            command,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=args.timeout_seconds,
            check=False,
        )
except subprocess.CalledProcessError as error:
    fail(f"Could not format temporary data media: {error}")
except subprocess.TimeoutExpired as error:
    emit_output(error.stdout, error.stderr)
    fail(f"QEMU exceeded the {args.timeout_seconds}-second timeout.")
except OSError as error:
    fail(f"Could not start QEMU: {error}")

emit_output(result.stdout, result.stderr)
combined_output = result.stdout + "\n" + result.stderr
if "[panic]" in combined_output or "[fault]" in combined_output:
    fail("QEMU reported a panic or fault.")
if result.returncode != expected_exit_code:
    fail(f"QEMU exited with code {result.returncode}; expected {expected_exit_code} for {architecture_tag}.")

# Serial stdio is stdout. Preserve its order without fabricating an ordering
# between independently captured stdout and stderr.
markers = [
    f"[bootloader] {architecture_tag} firmware entry",
    "[bootloader] kernel image copied",
    "[bootloader] handoff ready",
    f"[kernel] {architecture_tag} entry",
    "[kernel] handoff valid",
    "[kernel] allocator ready pages=",
    "[kernel] page allocation verified",
    "[kernel] page reuse verified",
    "[kernel] kernel heap verified",
    "[kernel] exception handled",
]
if "-uefi" in args.architecture:
    markers += [
        "[kernel] protected mappings ready",
        "[kernel] user mode verified",
        "[kernel] syscall checks verified",
        "[kernel] isolation probes verified",
        "[kernel] second task survived",
        "[kernel] timer ready",
        "[kernel] no-yield tasks preempted",
        "[kernel] context resume verified",
        "[kernel] preemptive scheduling verified",
        "[kernel] page-table rollback verified",
        "[kernel] task teardown verified",
        "[kernel] resource reuse verified",
        "[kernel] persistent filesystem mounted",
        "[kernel] exec capacity rollback verified",
        "[kernel] native ELF init ready",
        "[user] service ipc verified",
        "[user] file and pipe io verified",
        "[user] same pid exec verified",
        "[user] init lifecycle verified",
        "[kernel] filesystem I/O verified",
        "[kernel] pipe lifecycle verified",
        "[kernel] filesystem exec replacement verified",
        "[kernel] native process lifecycle verified",
        "[kernel] blocking wait verified",
        "[kernel] sleep wakeup verified",
        "[kernel] cooperative sleep progress verified",
        "[kernel] capability IPC verified",
        "[kernel] native process cleanup verified",
    ]
markers.append(f"[kernel] {architecture_tag} boot complete")
search_from = 0
for marker in markers:
    marker_index = result.stdout.find(marker, search_from)
    if marker_index < 0:
        fail(f"Missing or out-of-order serial marker: {marker}")
    search_from = marker_index + len(marker)

if "[kernel] memory regions=" not in result.stdout:
    fail("Kernel did not report its discovered memory map.")
if "-uefi" in args.architecture:
    if result.stdout.count("[kernel] user fault contained mode=") != 5:
        fail("Kernel did not contain all five user fault probes.")
    if result.stdout.count("[kernel] timer preempted task=") != 6:
        fail("Kernel did not preempt both tasks for three quanta each.")
    if "[bootloader] exit boot services" not in result.stdout:
        fail("UEFI loader did not confirm ExitBootServices.")
else:
    if f"RAM discovered length=0x{args.ram_mib * 1024 * 1024:016x}" not in result.stdout:
        fail("Bootloader did not discover the configured RAM size.")

print(f"{args.architecture} smoke test passed ({args.ram_mib} MiB).")
PY
