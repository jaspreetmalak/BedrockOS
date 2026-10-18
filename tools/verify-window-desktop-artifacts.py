#!/usr/bin/env python3
"""Re-audit explicit saved window artifacts; never follow receipt-selected paths."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("bedrock_window_artifact_gate", Path(__file__).with_name("test-window-desktop.py"))
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)

def verify(directory, architecture, image=None):
    prefix = f"window-desktop-{architecture}"
    receipt = json.loads((directory / f"{prefix}-verification.json").read_text(encoding="utf-8"))
    if receipt.get("architecture") != architecture: raise AssertionError("receipt architecture differs from explicit selection")
    logs = {boot: ((directory / f"{prefix}-{boot}.log").read_bytes(), (directory / f"{prefix}-{boot}.stderr.log").read_bytes()) for boot in ("first", "reboot")}
    names = gate.SCENES + (("fault-notes",) if receipt.get("mode") == "acceptance" else ())
    scenes = {name: (directory / f"{prefix}-{'first' if name in gate.FIRST_SCENES else 'reboot'}-{name}.ppm").read_bytes() for name in names}
    before = (directory / f"{prefix}-before-reboot.img").read_bytes()
    after = (directory / f"{prefix}-final-data.img").read_bytes()
    gate.verify_receipt(receipt, logs, scenes, before, after, image.read_bytes() if image else None)
    files = [directory / f"{prefix}-verification.json", directory / f"{prefix}-before-reboot.img", directory / f"{prefix}-final-data.img"]
    files += [directory / f"{prefix}-{boot}{suffix}" for boot in ("first", "reboot") for suffix in (".log", ".stderr.log")]
    files += [directory / f"{prefix}-{'first' if name in gate.FIRST_SCENES else 'reboot'}-{name}.ppm" for name in names]
    return {"architecture": architecture, "mode": receipt["mode"], "status": "passed", "boots": 2,
            "image_sha256": receipt.get("image_sha256"), "artifacts": [{"path": str(path.resolve()), "sha256": hashlib.sha256(path.read_bytes()).hexdigest()} for path in files],
            "reaped_generations": len(receipt["boots"]["reboot"]["evidence"]["reaped"]), "contained_faults": len(receipt["boots"]["reboot"]["evidence"]["faults"])}

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    parser.add_argument("--arch", required=True, choices=gate.runtime.ARCHITECTURES)
    parser.add_argument("--image", type=Path, help="Explicit original boot image, optional; never taken from receipt")
    args = parser.parse_args()
    result = verify(args.directory, args.arch, args.image)
    print(json.dumps(result, indent=2))

if __name__ == "__main__": main()
