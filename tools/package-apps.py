#!/usr/bin/env python3
"""Build a bounded installed application archive, using ordinary files only.

The catalogue describes identities and entry paths, never runtime permissions.
The kernel selects launch grants from its own trusted application policy.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path, PureWindowsPath
import re
import stat
import struct
import tempfile

MAGIC = b"BEDAPP01"
VERSION = 1
HEADER_BYTES = 64
RECORD_BYTES = 160
MAX_APPS = 8
MAX_FILE_BYTES = 2 * 1024 * 1024
MAX_ARCHIVE_BYTES = 16 * 1024 * 1024
MAX_CATALOGUE_BYTES = 16384
PAYLOAD_ALIGNMENT = 16
ARCHITECTURES = {"x86_64": 62, "aarch64": 183, "arm64": 183, "riscv64": 243}
DEFAULT_CATALOGUE = Path(__file__).resolve().parents[1] / "userspace/runtime/installed-apps.json"


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def read_file(path, maximum):
    path = Path(path)
    validate_path_syntax(str(path))
    if path.is_symlink() or not stat.S_ISREG(path.stat().st_mode):
        raise ValueError("application input must be an ordinary non-symlink file")
    with path.open("rb") as stream:
        data = stream.read(maximum + 1)
    if len(data) > maximum:
        raise ValueError("application input exceeds its bounded size")
    return data


def validate_path_syntax(text, windows=None):
    """Reject Windows devices and aliases before any filesystem query."""
    if windows is None:
        windows = os.name == "nt"
    if not windows:
        return
    normalized = text.replace("/", "\\")
    if normalized.startswith(("\\\\.\\", "\\\\?\\", "\\??\\")):
        raise ValueError("Windows device/namespace paths are not ordinary files")
    parsed = PureWindowsPath(normalized)
    reserved = {"CON", "PRN", "AUX", "NUL", "CONIN$", "CONOUT$"}
    reserved.update(prefix + digit for prefix in ("COM", "LPT") for digit in "123456789\u00b9\u00b2\u00b3")
    for component in parsed.parts:
        if component == parsed.anchor or component in (".", ".."):
            continue
        base = component.rstrip(" .").partition(".")[0].rstrip(" ").upper()
        if base in reserved:
            raise ValueError("Windows DOS device aliases are not ordinary files")
        if component.endswith((" ", ".")) or any(character in '<>:"|?*' or ord(character) < 32 for character in component):
            raise ValueError("Windows path components contain unsupported bytes")


def validate_name(name):
    if type(name) is not str or not 3 <= len(name) < 32 or not re.fullmatch(r"[a-z0-9.-]+", name) or "." not in name or name.startswith(".") or name.endswith(".") or ".." in name:
        raise ValueError("invalid application reverse-DNS identity")


def validate_path(path):
    if type(path) is not str or len(path) >= 64 or not path.startswith("/bundle/") or not path.endswith(".elf"):
        raise ValueError("invalid bundle executable path")
    for component in path[8:].split("/"):
        if not component or component in (".", "..") or not re.fullmatch(r"[A-Za-z0-9._-]+", component):
            raise ValueError("invalid bundle executable path component")


def validate_catalogue(value):
    if type(value) is not dict or set(value) != {"format", "apps"} or value["format"] != "bedrock-apps-v1" or type(value["apps"]) is not list or not 1 <= len(value["apps"]) <= MAX_APPS:
        raise ValueError("invalid bounded application catalogue")
    ids, names = set(), set()
    for app in value["apps"]:
        if type(app) is not dict or set(app) != {"id", "name", "version", "entry"} or type(app["id"]) is not int or not 0 < app["id"] < 1 << 64 or type(app["version"]) is not int or app["version"] != 1:
            raise ValueError("invalid application catalogue record")
        validate_name(app["name"])
        validate_path(app["entry"])
        if app["id"] in ids or app["name"] in names:
            raise ValueError("duplicate application catalogue identity")
        ids.add(app["id"])
        names.add(app["name"])
    return value["apps"]


def read_catalogue(path):
    try:
        value = json.loads(read_file(path, MAX_CATALOGUE_BYTES).decode("utf-8"), object_pairs_hook=unique_object)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ValueError("invalid application catalogue UTF-8 JSON") from error
    return validate_catalogue(value)


def validate_executable(data, machine):
    if type(data) not in (bytes, bytearray) or not 64 <= len(data) <= MAX_FILE_BYTES or data[:7] != b"\x7fELF\x02\x01\x01" or struct.unpack_from("<HHI", data, 16) != (2, machine, 1) or struct.unpack_from("<H", data, 52)[0] != 64:
        raise ValueError("application must be a bounded little-endian ELF64 ET_EXEC for the selected architecture")


def build_archive(catalogue, executables, architecture):
    apps = validate_catalogue({"format": "bedrock-apps-v1", "apps": catalogue})
    if architecture not in ARCHITECTURES or type(executables) is not dict or set(executables) != {app["name"] for app in apps}:
        raise ValueError("executable inputs must exactly match the selected application catalogue")
    machine = ARCHITECTURES[architecture]
    table = bytearray(len(apps) * RECORD_BYTES)
    data = bytearray(HEADER_BYTES + len(table))
    for index, app in enumerate(apps):
        executable = executables[app["name"]]
        validate_executable(executable, machine)
        data.extend(b"\0" * (-len(data) % PAYLOAD_ALIGNMENT))
        offset = len(data)
        if len(data) + len(executable) > MAX_ARCHIVE_BYTES:
            raise ValueError("application archive exceeds its bounded size")
        data.extend(executable)
        struct.pack_into("<QII32s64sQQ32s", table, index * RECORD_BYTES, app["id"], app["version"], 1, app["name"].encode("ascii"), app["entry"].encode("ascii"), offset, len(executable), hashlib.sha256(executable).digest())
    struct.pack_into("<8sHHIIIQ32s", data, 0, MAGIC, VERSION, machine, HEADER_BYTES, RECORD_BYTES, len(apps), len(data), hashlib.sha256(table).digest())
    data[HEADER_BYTES:HEADER_BYTES + len(table)] = table
    validate_archive(data, architecture)
    return bytes(data)


def terminated(data):
    end = data.find(b"\0")
    if end <= 0 or any(data[end:]):
        raise ValueError("noncanonical archive string")
    try:
        return data[:end].decode("ascii")
    except UnicodeDecodeError as error:
        raise ValueError("archive strings must be ASCII") from error


def validate_archive(data, architecture):
    """Pure archive checks also used by image packaging; returns bounded metadata."""
    if architecture not in ARCHITECTURES or type(data) not in (bytes, bytearray) or not HEADER_BYTES <= len(data) <= MAX_ARCHIVE_BYTES:
        raise ValueError("invalid bounded application archive")
    magic, version, machine, header, record, count, total, digest = struct.unpack_from("<8sHHIIIQ32s", data)
    if magic != MAGIC or version != VERSION or machine != ARCHITECTURES[architecture] or header != HEADER_BYTES or record != RECORD_BYTES or total != len(data) or not 1 <= count <= MAX_APPS:
        raise ValueError("incompatible application archive header")
    table_end = HEADER_BYTES + count * RECORD_BYTES
    if table_end > len(data) or hashlib.sha256(data[HEADER_BYTES:table_end]).digest() != digest:
        raise ValueError("invalid application archive table")
    previous_end = table_end
    ids, names, result = set(), set(), []
    for index in range(count):
        app_id, app_version, flags, raw_name, raw_path, offset, length, file_digest = struct.unpack_from("<QII32s64sQQ32s", data, HEADER_BYTES + index * RECORD_BYTES)
        name, path = terminated(raw_name), terminated(raw_path)
        validate_name(name)
        validate_path(path)
        if app_id == 0 or app_version != 1 or flags != 1 or app_id in ids or name in names:
            raise ValueError("invalid or duplicate application archive identity")
        if offset != (previous_end + PAYLOAD_ALIGNMENT - 1) & ~(PAYLOAD_ALIGNMENT - 1) or not 64 <= length <= MAX_FILE_BYTES or offset > len(data) or length > len(data) - offset or any(data[previous_end:offset]):
            raise ValueError("invalid application archive extent or padding")
        executable = data[offset:offset + length]
        if hashlib.sha256(executable).digest() != file_digest:
            raise ValueError("application executable hash mismatch")
        validate_executable(executable, machine)
        ids.add(app_id)
        names.add(name)
        result.append({"id": app_id, "version": app_version, "name": name, "entry": path, "offset": offset, "length": length, "sha256": file_digest.hex()})
        previous_end = offset + length
    if previous_end != len(data):
        raise ValueError("trailing application archive bytes")
    return result


def atomic_write(path, data):
    path = Path(path)
    validate_path_syntax(str(path))
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.is_symlink() or path.exists() and not stat.S_ISREG(path.stat().st_mode):
        raise ValueError("archive output must be an ordinary file")
    descriptor, temporary = tempfile.mkstemp(prefix=".bedrock-apps-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--arch", choices=tuple(ARCHITECTURES), required=True)
    parser.add_argument("--catalogue", type=Path, default=DEFAULT_CATALOGUE)
    parser.add_argument("--app", action="append", default=[], metavar="NAME=ELF")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--verify", type=Path)
    args = parser.parse_args()
    try:
        if args.verify:
            if args.output or args.app:
                raise ValueError("verification cannot be combined with archive creation")
            entries = validate_archive(read_file(args.verify, MAX_ARCHIVE_BYTES), args.arch)
            print(json.dumps({"archive": str(args.verify), "arch": args.arch, "apps": entries}, indent=2))
            return
        if args.output is None:
            raise ValueError("archive creation requires --output")
        validate_path_syntax(str(args.output))
        inputs = {}
        input_paths = [args.catalogue]
        for argument in args.app:
            name, separator, path = argument.partition("=")
            if not separator or not path or name in inputs:
                raise ValueError("--app requires unique NAME=ELF inputs")
            inputs[name] = read_file(path, MAX_FILE_BYTES)
            input_paths.append(Path(path))
        for source in input_paths:
            if source.resolve() == args.output.resolve() or source.exists() and args.output.exists() and os.path.samefile(source, args.output):
                raise ValueError("application archive output must differ from every input file")
        archive = build_archive(read_catalogue(args.catalogue), inputs, args.arch)
        atomic_write(args.output, archive)
        print(f"installed application archive: {len(inputs)} apps, {len(archive)} bytes -> {args.output}")
    except (ValueError, OSError) as error:
        parser.error(str(error))


if __name__ == "__main__":
    main()
