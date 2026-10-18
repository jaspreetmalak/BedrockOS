#!/usr/bin/env python3
"""Check real EFI asset loading while reusing the ordinary isolated QEMU gate."""
import argparse
from pathlib import Path
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("case", choices=("valid", "bad-patch"))
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
        print(f"Wi-Fi asset boot failed: {error}", file=sys.stderr)
        return 1
    expected = ("[bootloader] Wi-Fi firmware assets verified" if args.case == "valid"
                else "[bootloader] Wi-Fi assets unavailable: FirmwareLengthMismatch")
    if result.returncode or expected not in result.stdout:
        print(result.stdout)
        print(result.stderr, file=sys.stderr)
        print(f"Wi-Fi asset boot failed: expected {expected}", file=sys.stderr)
        return 1
    if args.case == "valid" and "[kernel] Wi-Fi driver module absent; radio unavailable" not in result.stdout:
        print(result.stdout)
        print("Wi-Fi asset boot failed: an unmatched module was not kept unavailable", file=sys.stderr)
        return 1
    if "[kernel] Wi-Fi native station prepared" in result.stdout:
        print("Wi-Fi asset boot failed: an unconfigured QEMU boot attached a physical radio", file=sys.stderr)
        return 1
    print(f"Wi-Fi EFI asset boot passed: {args.case}; firmware check and protected kernel lifecycle verified")
    return 0


if __name__ == "__main__":
    sys.exit(main())
