#!/usr/bin/env python3
"""Execute a separately mapped fixture module through the ordinary QEMU gate."""
import argparse
from pathlib import Path
import subprocess
import sys

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("runner", type=Path)
parser.add_argument("boot_args", nargs=argparse.REMAINDER)
args = parser.parse_args()
command = (["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File"]
           if args.runner.suffix == ".ps1" else ["sh"])
try:
    result = subprocess.run(command + [str(args.runner)] + args.boot_args,
                            stdin=subprocess.DEVNULL, capture_output=True,
                            encoding="utf-8", errors="replace", timeout=55)
except (OSError, subprocess.TimeoutExpired) as error:
    print(f"Driver module boot failed: {error}", file=sys.stderr)
    sys.exit(1)
if result.returncode or "[bootloader] matching driver module staged" not in result.stdout or "[kernel] driver module: DriverModuleLifecycleVerified" not in result.stdout:
    print(result.stdout)
    print(result.stderr, file=sys.stderr)
    sys.exit("Driver module boot failed: separate image entry/ABI/lease lifecycle not verified")
print("Driver module boot passed: separately relocated executable image, C ABI, generation checked allocations, balanced release and protected kernel lifecycle; TEST ONLY, no physical radio")
