#!/usr/bin/env python3
"""Verify production optional-module rejection without touching a host device."""
import argparse
from pathlib import Path
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("case", choices=("unmatched", "malformed"))
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
        print(f"Driver policy boot failed: {error}", file=sys.stderr)
        return 1
    text = result.stdout
    valid = (result.returncode == 0
             and "[kernel] Wi-Fi driver module absent; radio unavailable" in text
             and "[bootloader] matching driver module staged" not in text
             and "DriverModuleLifecycleVerified" not in text)
    if args.case == "malformed":
        valid = valid and "[bootloader] driver module rejected: TruncatedImage" in text
    else:
        valid = valid and "[bootloader] driver module rejected:" not in text
    if not valid:
        print(text)
        print(result.stderr, file=sys.stderr)
        print(f"Driver policy boot failed: {args.case}", file=sys.stderr)
        return 1
    print(f"Production driver policy boot passed: {args.case}; optional code not entered and protected kernel lifecycle verified")
    return 0


if __name__ == "__main__":
    sys.exit(main())
