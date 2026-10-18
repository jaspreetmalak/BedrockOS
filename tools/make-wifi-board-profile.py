#!/usr/bin/env python3
# SPDX-License-Identifier: ISC
# Copyright (C) 2026 Bedrock contributors
"""Encode explicitly supplied MT7922 platform facts as a Bedrock board profile.

No device is queried. Missing calibration, antenna, SAR, rate, or platform facts
are errors rather than guessed defaults. Output is an ordinary file only.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path, PureWindowsPath
import stat
import struct
import sys
import tempfile

HEADER_SIZE = 128
RECORD_SIZE = 192
MAX_CHANNELS = 64
RATE_COUNT = 161
MAX_JSON_SIZE = 128 * 1024
CHANNELS_5GHZ = frozenset((36, 40, 44, 48, 52, 56, 60, 64, 100, 104, 108,
                         112, 116, 120, 124, 128, 132, 136, 140, 144, 149,
                         153, 157, 161, 165, 169, 173, 177))


def fields(value, required, label):
    if type(value) is not dict or set(value) != set(required):
        raise ValueError(f"{label} requires exactly: {', '.join(required)}")
    return value


def integer(value, low, high, label):
    # JSON booleans must not masquerade as numerical hardware facts.
    if type(value) is not int or not low <= value <= high:
        raise ValueError(f"{label} must be an integer in {low}..{high}")
    return value


def boolean(value, label):
    if type(value) is not bool:
        raise ValueError(f"{label} must be an explicit boolean")
    return value


def hex_bytes(value, length, label):
    if type(value) is not str or len(value) != length * 2 or any(
            char not in "0123456789abcdefABCDEF" for char in value):
        raise ValueError(f"{label} requires exactly {length * 2} hexadecimal characters")
    return bytes.fromhex(value)


def build_profile(document):
    fields(document, ("version", "identity", "hardware", "platform", "country",
                      "environment", "provenance_sha256", "efuse", "channels"), "profile")
    integer(document["version"], 1, 1, "version")
    identity = fields(document["identity"], ("vendor", "device", "subsystem_vendor",
                                            "subsystem_device", "revision"), "identity")
    ids = [integer(identity[key], 0, 65535, key) for key in
           ("vendor", "device", "subsystem_vendor", "subsystem_device")]
    if (ids[0], ids[1]) not in ((0x14c3, 0x7922), (0x14c3, 0x0616), (0x0b48, 0x7922)):
        raise ValueError("identity must name a supported exact MT7922 PCI tuple")
    if ids[2] in (0, 65535) or ids[3] == 65535:
        raise ValueError("subsystem identity must be exact, not a wildcard")
    revision = integer(identity["revision"], 0, 255, "revision")
    hardware = fields(document["hardware"], ("antenna_mask", "encapsulation", "power_type",
                                             "acpi_conf", "mtcl_conf", "clc_event_supported"), "hardware")
    antenna_mask = integer(hardware["antenna_mask"], 1, 3, "antenna_mask")
    encapsulation = integer(hardware["encapsulation"], 0, 1, "encapsulation")
    power_type = integer(hardware["power_type"], 0, 1, "power_type")
    acpi_conf = integer(hardware["acpi_conf"], 0, 7, "acpi_conf")
    mtcl_conf = integer(hardware["mtcl_conf"], 0, 255, "mtcl_conf")
    clc = boolean(hardware["clc_event_supported"], "clc_event_supported")
    platform_keys = ("opt_in", "coherent_identity_dma", "iommu_disabled", "exclusive_takeover")
    platform = fields(document["platform"], platform_keys, "platform")
    platform_flags = sum(int(boolean(platform[key], key)) << index
                         for index, key in enumerate(platform_keys))
    country = document["country"]
    if type(country) is not str or len(country) != 2 or not (
            country == "00" or all("A" <= char <= "Z" for char in country)):
        raise ValueError("country must be two uppercase ASCII letters or 00")
    environment = document["environment"]
    if environment not in ("unknown", "indoor", "outdoor") or type(environment) is not str:
        raise ValueError("environment must be unknown, indoor, or outdoor")
    provenance = document["provenance_sha256"]
    provenance = bytes(32) if provenance is None else hex_bytes(provenance, 32, "provenance_sha256")
    efuse = fields(document["efuse"], ("address", "validity", "data_hex"), "efuse")
    efuse_address = integer(efuse["address"], 0x550, 0x550, "efuse.address")
    validity = integer(efuse["validity"], 0, 0xffffffff, "efuse.validity")
    efuse_data = hex_bytes(efuse["data_hex"], 16, "efuse.data_hex")
    if efuse_data[11] & 1 != encapsulation:
        raise ValueError("encapsulation must match the exact EFUSE byte at 0x55b")
    channels = document["channels"]
    if type(channels) is not list or not 1 <= len(channels) <= MAX_CHANNELS:
        raise ValueError("channels must contain 1..64 explicit channel records")
    output = bytearray(HEADER_SIZE + RECORD_SIZE * len(channels))
    struct.pack_into("<8sHHIHHHHHH", output, 0, b"BRDBRD01", 1, HEADER_SIZE,
                     len(output), len(channels), RECORD_SIZE, *ids)
    output[28:36] = bytes((revision, antenna_mask, encapsulation, power_type,
                           acpi_conf, mtcl_conf, int(clc), platform_flags))
    output[36:38] = country.encode("ascii")
    output[38] = ("unknown", "indoor", "outdoor").index(environment)
    output[72:104] = provenance
    struct.pack_into("<II", output, 104, efuse_address, validity)
    output[112:128] = efuse_data
    seen = set()
    for index, channel in enumerate(channels):
        fields(channel, ("band", "channel", "available_rx", "calibrated_rx", "known_tx_power",
                         "antenna_gain_mbi", "board_conducted_mbm", "sar_conducted_mbm",
                         "max_bandwidth_khz", "rates_half_dbm"), f"channel[{index}]")
        band = channel["band"]
        if band not in ("2ghz", "5ghz") or type(band) is not str:
            raise ValueError("only 2ghz and 5ghz channel facts are supported")
        number = integer(channel["channel"], 1, 177, "channel")
        if (band == "2ghz" and number > 14) or (band == "5ghz" and number not in CHANNELS_5GHZ):
            raise ValueError("channel must be a supported 20 MHz center")
        if (band, number) in seen:
            raise ValueError("duplicate band/channel")
        seen.add((band, number))
        for key in ("available_rx", "calibrated_rx", "known_tx_power"):
            if not boolean(channel[key], key):
                raise ValueError(f"{key} is missing; this profile cannot invent it")
        gain = integer(channel["antenna_gain_mbi"], -20000, 20000, "antenna_gain_mbi")
        board = integer(channel["board_conducted_mbm"], -6400, 6350, "board_conducted_mbm")
        sar = integer(channel["sar_conducted_mbm"], -6400, 6350, "sar_conducted_mbm")
        bandwidth = integer(channel["max_bandwidth_khz"], 20000, 20000, "max_bandwidth_khz")
        rates = channel["rates_half_dbm"]
        if type(rates) is not list or len(rates) != RATE_COUNT:
            raise ValueError("rates_half_dbm requires exactly 161 explicit rate ceilings")
        for rate in rates:
            integer(rate, -128, 127, "rate ceiling")
            if rate * 50 > min(board, sar):
                raise ValueError("rate ceiling exceeds the board or SAR conducted ceiling")
        offset = HEADER_SIZE + index * RECORD_SIZE
        struct.pack_into("<BBHiiiI", output, offset, 1 if band == "2ghz" else 2,
                         number, 7, gain, board, sar, bandwidth)
        output[offset + 20:offset + 181] = bytes(rate & 255 for rate in rates)
    output[40:72] = hashlib.sha256(output).digest()
    return bytes(output)


def unique_fields(pairs):
    result = {}
    for name, value in pairs:
        if name in result:
            raise ValueError(f"duplicate JSON field: {name}")
        result[name] = value
    return result


def read_document(path):
    ordinary_path(path)
    with path.open("rb") as source:
        if not stat.S_ISREG(os.fstat(source.fileno()).st_mode):
            raise ValueError("input must be an ordinary file")
        data = source.read(MAX_JSON_SIZE + 1)
    if len(data) > MAX_JSON_SIZE:
        raise ValueError("JSON input exceeds 128 KiB")
    return json.loads(data.decode("utf-8"), object_pairs_hook=unique_fields,
                      parse_constant=lambda value: (_ for _ in ()).throw(ValueError(f"invalid JSON constant: {value}")))


def ordinary_path(path, *, output=False, windows=None):
    if windows is None:
        windows = os.name == "nt"
    if windows:
        text = str(path).replace("/", "\\")
        if text.startswith(("\\\\.\\", "\\\\?\\", "\\??\\")):
            raise ValueError("device and namespace paths are unsupported")
        parsed = PureWindowsPath(text)
        reserved = {"CON", "PRN", "AUX", "NUL", "CONIN$", "CONOUT$"}
        reserved.update(prefix + digit for prefix in ("COM", "LPT")
                        for digit in "123456789\u00b9\u00b2\u00b3")
        for part in parsed.parts:
            if part == parsed.anchor or part in (".", ".."):
                continue
            stem = part.rstrip(" .").partition(".")[0].rstrip(" ").upper()
            if stem in reserved or part.endswith((" ", ".")) or any(
                    char in '<>:"|?*' or ord(char) < 32 for char in part):
                raise ValueError("path must name an ordinary Windows file")
    if path.is_symlink():
        raise ValueError("symbolic-link files are unsupported")
    if path.exists() and not stat.S_ISREG(path.stat().st_mode):
        raise ValueError("path must name an ordinary file")
    if output and not path.parent.is_dir():
        raise ValueError("the output directory must already exist")


def write_profile(path, data, *, force=False):
    ordinary_path(path, output=True)
    if path.exists() and not force:
        raise FileExistsError("output exists; use --force to replace it explicitly")
    temporary_path = None
    try:
        with tempfile.NamedTemporaryFile(dir=path.parent, prefix=path.name + ".",
                                         suffix=".tmp", delete=False) as target:
            temporary_path = Path(target.name)
            target.write(data)
            target.flush()
            os.fsync(target.fileno())
        if force:
            os.replace(temporary_path, path)
        else:
            # Same-directory publication is atomic and cannot replace a race winner.
            # Unsupported hard links fail rather than silently enabling overwrite.
            os.link(temporary_path, path)
            temporary_path.unlink()
        temporary_path = None
    finally:
        if temporary_path is not None:
            temporary_path.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path, help="explicit board-fact JSON")
    parser.add_argument("output", type=Path, help="ordinary output MT7922.board file")
    parser.add_argument("--force", action="store_true", help="explicitly replace an existing output file")
    args = parser.parse_args()
    try:
        ordinary_path(args.input)
        ordinary_path(args.output, output=True)
        if args.input.resolve() == args.output.resolve():
            raise ValueError("input and output must be different files")
        data = build_profile(read_document(args.input))
        write_profile(args.output, data, force=args.force)
    except (OSError, ValueError, struct.error) as error:
        print(f"make-wifi-board-profile: {error}", file=sys.stderr)
        return 1
    print(f"Created {args.output} ({len(data)} bytes; supplied facts only)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
