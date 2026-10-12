#!/usr/bin/env python3
"""Strict, deterministic wireless-regdb -> native Zig facts. Offline by default.

This is an independently written parser for the pinned db.txt grammar, not an
execution/import of upstream's compiler. It retains restrictions the upstream
compiler may omit. Decimal mW conversion is rounded down and verified with exact
integer inequalities; float logarithms never authorize additional power.
"""
from __future__ import annotations

import argparse
import base64
from dataclasses import dataclass
from decimal import Decimal, localcontext, ROUND_FLOOR
from fractions import Fraction
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import tempfile
import urllib.request

COMMIT = "389b9b702cf9018e9a9078ccc4fa8eaae2e054e3"
LINUX_COMMIT = "7d0a66e4bb9081d75c82ec4957c50034cb0ea449"
SOURCE_SHA256 = "b71c815bd90c284131a27ab5af6fb4951b3580dc8af83345f31fcd34c5cd0581"
LICENSE_SHA256 = "678b0df753c86198fc496d1f1033429bbd57f101472132ee7eaaf9f5e0a7fae1"
REPOSITORY = "https://kernel.googlesource.com/pub/scm/linux/kernel/git/wens/wireless-regdb"
MAX_SOURCE_BYTES = 2 * 1024 * 1024
MAX_COUNTRIES = 256
MAX_RULES = 8192
MAX_LINE_BYTES = 2048
FLAGS = {
    "NO-IR": 1 << 0, "DFS": 1 << 1, "NO-OUTDOOR": 1 << 2,
    "NO-INDOOR": 1 << 3, "NO-OFDM": 1 << 4, "NO-CCK": 1 << 5,
    "NO-HT40": (1 << 6) | (1 << 7), "AUTO-BW": 1 << 10,
}
DFS = {"": "unset", "DFS-FCC": "fcc", "DFS-ETSI": "etsi", "DFS-JP": "jp"}
AC_NAMES = ("vo_c", "vi_c", "be_c", "bk_c", "vo_ap", "vi_ap", "be_ap", "bk_ap")
NUMBER = r"-?[0-9]+(?:\.[0-9]+)?"
RULE_PATTERN = re.compile(
    rf"\(\s*({NUMBER})\s*-\s*({NUMBER})\s*@\s*({NUMBER})\s*\)\s*,\s*"
    rf"\(\s*({NUMBER})(?:\s*(mW|dBm))?\s*\)(.*)"
)


class ImportError(ValueError):
    """Input cannot be represented without losing regulatory semantics."""


@dataclass(frozen=True)
class Rule:
    start_khz: int
    end_khz: int
    max_bandwidth_khz: int
    max_eirp_mbm: int
    flags: int = 0
    wmm: str = "none"
    max_antenna_gain_mbi: int | None = None
    psd_mbm_mhz: int | None = None


@dataclass(frozen=True)
class Country:
    alpha2: str
    dfs_region: str
    rules: tuple[Rule, ...]


@dataclass(frozen=True)
class WmmAccessCategory:
    name: str
    cw_min: int
    cw_max: int
    aifsn: int
    cot_us: int


@dataclass(frozen=True)
class Database:
    countries: tuple[Country, ...]
    wmm_etsi: tuple[WmmAccessCategory, ...]

    @property
    def rule_count(self) -> int:
        return sum(len(country.rules) for country in self.countries)


def decimal_value(text: str) -> Decimal:
    if len(text) > 20 or not re.fullmatch(NUMBER, text):
        raise ImportError("unsupported numeric spelling")
    return Decimal(text)


def scaled_exact(text: str, scale: int, low: int, high: int) -> int:
    value = decimal_value(text) * scale
    if value != value.to_integral_value() or not low <= value <= high:
        raise ImportError("numeric value is out of bounds or loses precision")
    return int(value)


def power_mbm(text: str, unit: str | None = None) -> int:
    if unit != "mW":
        if unit not in (None, "dBm"):
            raise ImportError("unsupported power unit")
        return scaled_exact(text, 100, -10000, 10000)
    value = decimal_value(text)
    if not Decimal("0.0000000001") <= value <= Decimal("10000000000"):
        raise ImportError("mW power out of bounds")
    numerator, denominator = Fraction(value).as_integer_ratio()
    # This approximation only locates a candidate; exact integer comparisons
    # below prove n <= 1000*log10(mW) < n+1 before publishing n mBm.
    with localcontext() as ctx:
        ctx.prec = 80
        candidate = int((value.log10() * 1000).to_integral_value(rounding=ROUND_FLOOR))
    left, right = numerator ** 1000, denominator ** 1000

    def permitted(mbm: int) -> bool:
        return left >= right * 10 ** mbm if mbm >= 0 else left * 10 ** (-mbm) >= right

    while not permitted(candidate):
        candidate -= 1
    while permitted(candidate + 1):
        candidate += 1
    if not -10000 <= candidate <= 10000:
        raise ImportError("converted power out of bounds")
    return candidate


def parse(source: bytes) -> Database:
    if len(source) > MAX_SOURCE_BYTES or b"\0" in source:
        raise ImportError("source size/NUL bound")
    try:
        text = source.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise ImportError("source is not UTF-8") from exc
    countries: dict[str, tuple[str, list[Rule]]] = {}
    wmm: dict[str, WmmAccessCategory] = {}
    current: str | None = None
    in_wmm = False
    seen_wmm = False
    total_rules = 0
    for line_number, raw in enumerate(text.splitlines(), 1):
        if len(raw.encode("utf-8")) > MAX_LINE_BYTES:
            raise ImportError(f"line {line_number}: oversized line")
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        try:
            if line.startswith("wmmrule"):
                if line != "wmmrule ETSI:" or seen_wmm:
                    raise ImportError("unsupported or duplicate WMM definition")
                current = None
                in_wmm = seen_wmm = True
                continue
            if line.startswith("country"):
                match = re.fullmatch(r"country (00|[A-Z]{2}):\s*(DFS-[A-Z]+)?", line)
                if not match or (match[2] or "") not in DFS:
                    raise ImportError("unsupported country/DFS declaration")
                current = match[1]
                if current in countries or len(countries) >= MAX_COUNTRIES:
                    raise ImportError("duplicate country or capacity exceeded")
                countries[current] = (DFS[match[2] or ""], [])
                in_wmm = False
                continue
            if in_wmm:
                match = re.fullmatch(
                    r"(vo_c|vi_c|be_c|bk_c|vo_ap|vi_ap|be_ap|bk_ap):\s*"
                    r"cw_min=([0-9]+),\s*cw_max=([0-9]+),\s*aifsn=([0-9]+),\s*cot=([0-9]+)", line
                )
                if not match or match[1] in wmm:
                    raise ImportError("unsupported/duplicate WMM category")
                name = match[1]
                minimum, maximum, aifsn, cot_ms = (int(s) for s in match.groups()[1:])
                if not (1 <= minimum <= maximum < 32768 and
                        (minimum + 1) & minimum == 0 and (maximum + 1) & maximum == 0 and
                        1 <= aifsn <= 255 and 0 <= cot_ms <= 65):
                    raise ImportError("invalid WMM value")
                wmm[name] = WmmAccessCategory(name, minimum, maximum, aifsn, cot_ms * 1000)
                continue
            if current is None:
                raise ImportError("rule without country or unsupported declaration")
            match = RULE_PATTERN.fullmatch(line)
            if not match:
                raise ImportError("unsupported rule syntax")
            start, end, bandwidth = [scaled_exact(match[i], 1000, 1, 0xFFFFFFFF) for i in (1, 2, 3)]
            if start >= end or bandwidth > end - start:
                raise ImportError("inverted range or bandwidth exceeds range")
            flags, wmm_name = 0, "none"
            suffix = match[6].strip()
            if suffix:
                if not suffix.startswith(","):
                    raise ImportError("unsupported rule suffix")
                tokens = [token.strip() for token in suffix[1:].split(",")]
                if len(tokens) != len(set(tokens)):
                    raise ImportError("duplicate flag")
                for token in tokens:
                    if token == "wmmrule=ETSI":
                        if set(wmm) != set(AC_NAMES):
                            raise ImportError("WMM reference without complete definition")
                        wmm_name = "etsi"
                    elif token in FLAGS:
                        flags |= FLAGS[token]
                    else:
                        raise ImportError(f"unsupported flag: {token!r}")
            rule = Rule(start, end, bandwidth, power_mbm(match[4], match[5]), flags, wmm_name)
            rules = countries[current][1]
            if rule in rules:
                raise ImportError("duplicate rule")
            total_rules += 1
            if total_rules > MAX_RULES:
                raise ImportError("rule capacity exceeded")
            rules.append(rule)
        except (ImportError, ValueError) as exc:
            raise ImportError(f"line {line_number}: {exc}") from exc
    if not countries or any(not rules for _, rules in countries.values()):
        raise ImportError("missing countries or empty country")
    if seen_wmm and set(wmm) != set(AC_NAMES):
        raise ImportError("incomplete WMM definition")
    return Database(
        tuple(Country(code, countries[code][0], tuple(countries[code][1])) for code in sorted(countries)),
        tuple(wmm[name] for name in AC_NAMES if name in wmm),
    )


def render(database: Database, source_hash: str) -> bytes:
    lines = [
        "// SPDX-License-Identifier: ISC",
        "// Copyright (c) 2008, Luis R. Rodriguez <mcgrof@gmail.com>",
        "// Copyright (c) 2008, Johannes Berg <johannes@sipsolutions.net>",
        "// Copyright (c) 2008, Michael Green <Michael.Green@Atheros.com>",
        "// Generated by tools/update-wifi-regdb.py. Do not edit.",
        "// Source data: wireless-regdb; original notices are retained in LICENSE.",
        f'pub const source_commit = "{COMMIT}";',
        f'pub const source_sha256 = "{source_hash}";',
        'const types = @import("types.zig");',
        "pub const country_count = " + str(len(database.countries)) + ";",
        "pub const rule_count = " + str(database.rule_count) + ";",
        "pub const WmmAccessCategory = struct {",
        "    name: []const u8,",
        "    cw_min: u16,",
        "    cw_max: u16,",
        "    aifsn: u8,",
        "    cot_us: u16,",
        "};",
        "pub const wmm_etsi = [_]WmmAccessCategory{",
    ]
    for entry in database.wmm_etsi:
        lines.append(f'    .{{ .name = "{entry.name}", .cw_min = {entry.cw_min}, .cw_max = {entry.cw_max}, .aifsn = {entry.aifsn}, .cot_us = {entry.cot_us} }},')
    lines.extend(["};", "pub const countries: []const types.Country = &.{"])
    for country in database.countries:
        lines.append(f"    .{{ .alpha2 = .{{ '{country.alpha2[0]}', '{country.alpha2[1]}' }}, .dfs_region = .{country.dfs_region}, .rules = &.{{")
        for rule in country.rules:
            lines.append("        .{ " +
                         f".start_khz = {rule.start_khz}, .end_khz = {rule.end_khz}, .max_bandwidth_khz = {rule.max_bandwidth_khz}, " +
                         f".max_eirp_mbm = {rule.max_eirp_mbm}, .flags = {rule.flags}, .wmm = .{rule.wmm}" + " },")
        lines.append("    } },")
    lines.extend([
        "};", "pub fn lookup(alpha2: [2]u8) ?*const types.Country {",
        "    for (countries) |*country| {",
        "        if (country.alpha2[0] == alpha2[0] and country.alpha2[1] == alpha2[1]) return country;",
        "    }", "    return null;", "}", "",
    ])
    return "\n".join(lines).encode("utf-8")


def provenance(database: Database, output: bytes) -> bytes:
    record = {
        "format": 1, "repository": REPOSITORY, "commit": COMMIT,
        "source_url": f"{REPOSITORY}/+/{COMMIT}/db.txt",
        "source_sha256": SOURCE_SHA256, "license": "ISC", "license_sha256": LICENSE_SHA256,
        "license_url": f"{REPOSITORY}/+/{COMMIT}/LICENSE",
        "linux_protocol_reference_commit": LINUX_COMMIT,
        "country_count": len(database.countries), "rule_count": database.rule_count,
        "generated_sha256": hashlib.sha256(output).hexdigest(),
        "power_conversion": "exact dBm*100; mW -> floor(mBm) with exact rational inequality verification",
        "preserved_restrictions": "all source rules/flags/WMM references; no NO-INDOOR drop",
        "source_only_in_cache": True,
    }
    return (json.dumps(record, sort_keys=True, indent=2) + "\n").encode("utf-8")


def ordinary_path(path: Path, *, output: bool = False) -> Path:
    if os.name == "nt":
        text = str(path)
        if text.startswith(("\\\\", "//")):
            raise ImportError("device/UNC paths are unsupported")
        for part in path.parts[1:] if path.drive else path.parts:
            stem = part.rstrip(" .").split(".", 1)[0].upper()
            if (stem in {"CON", "PRN", "AUX", "NUL", "CONIN$", "CONOUT$"} or
                re.fullmatch(r"(?:COM|LPT)[1-9¹²³]", stem) or any(c in part for c in '<>:"|?*')):
                raise ImportError("invalid ordinary-file name")
    if path.is_symlink() or (path.exists() and not stat.S_ISREG(path.stat().st_mode)):
        raise ImportError("expected ordinary file")
    if not output and not path.exists():
        raise ImportError("input file does not exist")
    if output and not path.parent.is_dir():
        raise ImportError("output parent must exist")
    return path.resolve()


def atomic_write(path: Path, data: bytes) -> None:
    destination = ordinary_path(path, output=True)
    name: str | None = None
    try:
        with tempfile.NamedTemporaryFile(dir=destination.parent, prefix=".regdb-", delete=False) as stream:
            name = stream.name
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, destination)
        name = None
    finally:
        if name is not None:
            os.unlink(name)


def fetch(cache: Path) -> Path:
    cache.mkdir(parents=True, exist_ok=True)
    for name, expected in (("db.txt", SOURCE_SHA256), ("LICENSE", LICENSE_SHA256)):
        url = f"{REPOSITORY}/+/{COMMIT}/{name}?format=TEXT"
        with urllib.request.urlopen(url, timeout=30) as response:
            encoded = response.read(MAX_SOURCE_BYTES * 2 + 1)
        if len(encoded) > MAX_SOURCE_BYTES * 2:
            raise ImportError("oversized HTTPS response")
        data = base64.b64decode(encoded, validate=True)
        if hashlib.sha256(data).hexdigest() != expected:
            raise ImportError("pinned HTTPS source hash mismatch")
        atomic_write(cache / name, data)
    return cache / "db.txt"


def main() -> None:
    cli = argparse.ArgumentParser(description=__doc__)
    cli.add_argument("source", type=Path, help="local pinned db.txt (or '-' with --fetch)")
    cli.add_argument("output", type=Path, help="ordinary generated database.zig file")
    cli.add_argument("--provenance", type=Path, help="optional ordinary JSON provenance file")
    cli.add_argument("--fetch", action="store_true", help="explicitly fetch the fixed pin over HTTPS")
    cli.add_argument("--cache-dir", type=Path, default=Path(".zig-cache/upstream-wifi/regdb") / COMMIT)
    args = cli.parse_args()
    try:
        source_path = fetch(args.cache_dir) if args.fetch else ordinary_path(args.source)
        output_path = ordinary_path(args.output, output=True)
        metadata_path = ordinary_path(args.provenance, output=True) if args.provenance else None
        if output_path == source_path.resolve() or metadata_path in (source_path.resolve(), output_path):
            raise ImportError("input/output/provenance paths must differ")
        with source_path.open("rb") as stream:
            source = stream.read(MAX_SOURCE_BYTES + 1)
        if hashlib.sha256(source).hexdigest() != SOURCE_SHA256:
            raise ImportError("db.txt differs from the pinned SHA-256")
        database = parse(source)
        output = render(database, SOURCE_SHA256)
        atomic_write(output_path, output)
        if metadata_path is not None:
            atomic_write(metadata_path, provenance(database, output))
        print(f"Imported {len(database.countries)} countries, {database.rule_count} rules from {COMMIT}")
    except (ImportError, OSError, ValueError) as exc:
        cli.exit(1, f"regdb import failed: {exc}\n")


if __name__ == "__main__":
    main()
