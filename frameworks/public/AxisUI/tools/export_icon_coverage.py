"""Package output of the native vector exporter as a source-stamped QA oracle."""
import hashlib
import json
import pathlib
import sys


def main() -> None:
    package = pathlib.Path(__file__).resolve().parents[1]
    log = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else package / ".zig-cache/icon-coverage-export.txt"
    output = log.read_text(encoding="utf-8-sig")
    if "All 1 tests passed." not in output:
        raise ValueError("native icon export test did not pass")
    marker = "AXIS_ICON_COVERAGE "
    data, _ = json.JSONDecoder().raw_decode(output.split(marker, 1)[1])
    if data["size"] != 16 or len(data["icons"]) != 10:
        raise ValueError("unexpected icon export schema")
    for name, coverage in data["icons"].items():
        if len(coverage) != 256 or any(type(value) is not int or not 0 <= value <= 255 for value in coverage):
            raise ValueError(f"invalid coverage for {name}")
        if not any(0 < value < 255 for value in coverage):
            raise ValueError(f"missing native antialiasing for {name}")
    data["source"] = {
        "path": "src/icons.zig",
        "sha256": hashlib.sha256((package / "src/icons.zig").read_bytes()).hexdigest(),
    }
    data["purpose"] = "Screenshot QA only; runtime icons evaluate the original vector paths."
    destination = package / "icon-coverage.json"
    destination.write_text(json.dumps(data, separators=(",", ":")) + "\n", encoding="utf-8")
    print(f"Exported {len(data['icons'])} native icon coverage maps; source SHA256 {data['source']['sha256']}")


if __name__ == "__main__":
    main()
