#!/usr/bin/env python3
"""Verify a protected NetworkKit caller against an isolated Ethernet peer.

QEMU's datagram backend and this peer bind only to localhost. Frames exercise
the real NIC, ARP and IPv4/UDP; no external host or ordinary user disk is used.
"""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parent.parent
GUEST_IP = bytes((10, 0, 2, 15))
HOST_IP = bytes((10, 0, 2, 2))
GUEST_MAC = bytes.fromhex("525400123457")
HOST_MAC = bytes.fromhex("525400123456")
ECHO_PORT = 32123
MESSAGES = (b"NetworkKit echo one", b"NetworkKit different reply", b"")


def checksum(data):
    if len(data) & 1:
        data += b"\0"
    value = sum(struct.unpack(f"!{len(data) // 2}H", data))
    while value >> 16:
        value = (value & 65535) + (value >> 16)
    return (~value) & 65535


def udp_frame(destination_mac, source_ip, destination_ip, source_port,
              destination_port, payload, identifier=0x1782):
    udp = bytearray(struct.pack("!HHHH", source_port, destination_port,
                                len(payload) + 8, 0) + payload)
    pseudo = source_ip + destination_ip + struct.pack("!BBH", 0, 17, len(udp))
    struct.pack_into("!H", udp, 6, checksum(pseudo + udp) or 65535)
    ip = bytearray(struct.pack("!BBHHHBBH4s4s", 0x45, 0, 20 + len(udp),
                               identifier, 0x4000, 64, 17, 0,
                               source_ip, destination_ip))
    struct.pack_into("!H", ip, 10, checksum(ip))
    frame = destination_mac + HOST_MAC + b"\x08\x00" + ip + udp
    return frame + b"\0" * max(0, 60 - len(frame))


class Peer:
    def __init__(self):
        self.socket = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.socket.bind(("127.0.0.1", 0))
        self.socket.settimeout(.1)
        self.port = self.socket.getsockname()[1]
        self.stop = threading.Event()
        self.error = None
        self.arp_requests = 0
        self.payloads = []
        self.local_ports = []
        self.injected = 0
        self.thread = threading.Thread(target=self.run, daemon=True)

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *_):
        self.stop.set()
        self.thread.join(timeout=2)
        self.socket.close()
        assert not self.thread.is_alive(), "Owned Ethernet peer did not stop"

    def reply(self, frame, address):
        self.socket.sendto(frame, address)

    def run(self):
        try:
            while not self.stop.is_set():
                try:
                    frame, address = self.socket.recvfrom(65536)
                except socket.timeout:
                    continue
                if len(frame) < 14 or frame[6:12] != GUEST_MAC:
                    continue
                kind = frame[12:14]
                if kind == b"\x08\x06":
                    if len(frame) < 42:
                        continue
                    arp = struct.unpack("!HHBBH6s4s6s4s", frame[14:42])
                    if arp[:5] != (1, 0x0800, 6, 4, 1) or arp[6] != GUEST_IP or arp[8] != HOST_IP:
                        continue  # Firmware DHCP/PXE is outside this probe.
                    assert arp[5] == GUEST_MAC
                    self.arp_requests += 1
                    response = (GUEST_MAC + HOST_MAC + b"\x08\x06" +
                                struct.pack("!HHBBH6s4s6s4s", 1, 0x0800, 6, 4, 2,
                                            HOST_MAC, HOST_IP, GUEST_MAC, GUEST_IP))
                    self.reply(response + b"\0" * (60 - len(response)), address)
                    continue
                if kind != b"\x08\x00" or len(frame) < 42:
                    continue
                ip = frame[14:34]
                # Skip firmware broadcasts, then independently check every
                # field relevant to the owned static IPv4/UDP acceptance.
                if ip[12:16] != GUEST_IP or ip[16:20] != HOST_IP or ip[9] != 17:
                    continue
                assert frame[:6] == HOST_MAC and ip[0] == 0x45
                assert checksum(ip) == 0 and ip[8] != 0
                length = struct.unpack_from("!H", ip, 2)[0]
                assert 28 <= length <= 284 and len(frame) >= 14 + length
                assert struct.unpack_from("!H", ip, 6)[0] & ~0x4000 == 0
                udp = frame[34:14 + length]
                source, destination, size, checked = struct.unpack_from("!HHHH", udp)
                assert destination == ECHO_PORT and 49152 <= source <= 65535
                assert size == len(udp) and checked != 0
                pseudo = GUEST_IP + HOST_IP + struct.pack("!BBH", 0, 17, size)
                assert checksum(pseudo + udp) == 0
                payload = udp[8:]
                assert payload == MESSAGES[len(self.payloads)], "Unexpected/duplicate probe datagram"
                self.payloads.append(payload)
                self.local_ports.append(source)
                if len(self.payloads) == 1:
                    # Valid checksums cannot excuse a different connected peer
                    # or local port. Any accidental delivery fails the caller's
                    # exact payload comparison before its legitimate reply.
                    bad = bytearray(udp_frame(GUEST_MAC, HOST_IP, GUEST_IP,
                                              ECHO_PORT, source, b"bad-checksum"))
                    bad[40] ^= 1
                    noise = [bytes(bad),
                             udp_frame(GUEST_MAC, bytes((10, 0, 2, 99)), GUEST_IP,
                                       ECHO_PORT, source, b"wrong-peer-address"),
                             udp_frame(GUEST_MAC, HOST_IP, GUEST_IP,
                                       ECHO_PORT + 1, source, b"wrong-peer-port"),
                             udp_frame(GUEST_MAC, HOST_IP, GUEST_IP,
                                       ECHO_PORT, source + 1, b"wrong-local-port")]
                    for packet in noise:
                        self.reply(packet, address)
                        self.injected += 1
                response = bytearray(udp_frame(GUEST_MAC, HOST_IP, GUEST_IP,
                                               ECHO_PORT, source, payload))
                if len(self.payloads) == 2:
                    # RFC768 permits an absent UDP checksum in IPv4. The
                    # stack must distinguish this from an invalid nonzero sum.
                    response[40:42] = b"\0\0"
                self.reply(response, address)
        except BaseException as error:
            self.error = error
            self.stop.set()


def run(args):
    args.artifacts.mkdir(parents=True, exist_ok=True)
    receipt = args.artifacts / f"network-{args.architecture}-verification.json"
    receipt.unlink(missing_ok=True)
    log_path = args.artifacts / f"network-{args.architecture}.log"
    error_path = args.artifacts / f"network-{args.architecture}-stderr.log"
    spec = importlib.util.spec_from_file_location("data_formatter", ROOT / "tools/make-data-image.py")
    formatter = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(formatter)
    with tempfile.TemporaryDirectory(prefix="bedrock-network-") as temporary, Peer() as peer:
        data = Path(temporary) / "data.img"
        formatter.write_image(data)
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as reservation:
            reservation.bind(("127.0.0.1", 0))
            guest_port = reservation.getsockname()[1]
        x86, arm = args.architecture == "x86_64", args.architecture == "arm64"
        machine = "pc-q35-10.1" if x86 else "virt-10.1,secure=off,virtualization=off,acpi=off" if arm else "virt,acpi=off"
        cpu = "qemu64" if x86 else "cortex-a57" if arm else "rv64"
        command = [args.qemu, "-machine", machine, "-cpu", cpu, "-accel", "tcg", "-smp", "1", "-m", "256M",
                   "-display", "none", "-serial", "stdio", "-monitor", "none", "-no-reboot", "-nic", "none",
                   "-drive", f"if=pflash,format=raw,readonly=on,file={args.code}",
                   "-drive", f"if=pflash,format=raw,snapshot=on,file={args.variables}",
                   "-netdev", (f"dgram,id=bedrock-net,local.type=inet,local.host=127.0.0.1,local.port={guest_port},"
                               f"remote.type=inet,remote.host=127.0.0.1,remote.port={peer.port}")]
        if x86:
            command += ["-drive", f"format=raw,snapshot=on,file=fat:{args.esp}",
                        "-drive", f"if=none,id=bedrock-data,format=raw,file={data}",
                        "-device", "virtio-blk-pci,drive=bedrock-data,disable-legacy=on,serial=bedrock-data",
                        "-device", "virtio-net-pci,netdev=bedrock-net,disable-legacy=on,romfile=,mac=52:54:00:12:34:57",
                        "-device", "isa-debug-exit,iobase=0xf4,iosize=4"]
        else:
            command += ["-global", "virtio-mmio.force-legacy=false",
                        "-drive", f"if=none,id=bedrock-esp,format=raw,snapshot=on,file=fat:{args.esp}",
                        "-device", "virtio-blk-device,drive=bedrock-esp",
                        "-drive", f"if=none,id=bedrock-data,format=raw,file={data}",
                        "-device", "virtio-blk-device,drive=bedrock-data,serial=bedrock-data",
                        "-device", "virtio-net-device,netdev=bedrock-net,mac=52:54:00:12:34:57"]
            command += ["-semihosting-config", "enable=on,target=native"] if arm else ["-bios", "default"]
        startup = None
        if sys.platform == "win32":
            startup = subprocess.STARTUPINFO()
            startup.dwFlags |= subprocess.STARTF_USESHOWWINDOW
            startup.wShowWindow = 0
        with log_path.open("wb") as log, error_path.open("wb") as stderr:
            process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=log, stderr=stderr, startupinfo=startup)
            try:
                deadline = time.monotonic() + args.timeout
                while process.poll() is None:
                    if peer.error is not None:
                        raise AssertionError(f"Ethernet peer validation: {peer.error}")
                    if time.monotonic() >= deadline:
                        raise AssertionError("QEMU networking acceptance timed out")
                    time.sleep(.05)
                assert process.returncode == (33 if x86 else 0), f"Unexpected QEMU exit {process.returncode}"
            except BaseException:
                if process.poll() is None:
                    process.kill()
                raise
            finally:
                process.wait(timeout=5)
        body = log_path.read_text(errors="replace")
        for marker in ("[kernel] network device ready", "[user] NetworkKit UDP echo verified",
                       "[user] NetworkKit authority checks passed", "[user] NetworkKit zero datagram verified",
                       "[user] NetworkKit exit cleanup armed", "[kernel] network endpoint cleanup verified",
                       "[kernel] native process cleanup verified"):
            assert body.count(marker) == 1, f"Missing/duplicate marker: {marker}"
        assert "[panic]" not in body and "[fault] kernel" not in body
        assert peer.error is None and peer.payloads == list(MESSAGES)
        assert peer.arp_requests >= 1 and peer.injected == 4
        assert peer.local_ports[0] == peer.local_ports[1] and peer.local_ports[2] > peer.local_ports[0]
        value = {"architecture": args.architecture, "status": "passed", "protected_framework_echo": True,
                 "arp_verified": True, "ipv4_udp_checksums_verified": True,
                 "bad_checksum_and_wrong_tuple_rejected": True, "short_receive_preserved": True,
                 "checked_user_pointers": True, "stale_handle_denied": True,
                 "zero_datagram_verified": True, "exit_cleanup_verified": True,
                 "ipv4_absent_udp_checksum_supported": True,
                 "loopback_only_peer": True, "datagram_lengths": [len(p) for p in peer.payloads],
                 "local_ports": peer.local_ports, "invalid_frames_injected": peer.injected,
                 "arp_requests": peer.arp_requests,
                 "serial_sha256": hashlib.sha256(log_path.read_bytes()).hexdigest()}
        receipt.write_text(json.dumps(value, indent=2) + "\n")
    print(f"{args.architecture}: protected NetworkKit, ARP/UDP echo, authority and endpoint cleanup passed")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("architecture", choices=("x86_64", "arm64", "riscv64"))
    parser.add_argument("qemu")
    parser.add_argument("esp", type=Path)
    parser.add_argument("code", type=Path)
    parser.add_argument("variables", type=Path)
    parser.add_argument("--artifacts", type=Path, default=ROOT / "zig-out/network-tests")
    parser.add_argument("--timeout", type=float, default=80)
    args = parser.parse_args()
    try:
        run(args)
    except BaseException:
        for path in (args.artifacts / f"network-{args.architecture}.log",
                     args.artifacts / f"network-{args.architecture}-stderr.log"):
            if path.exists():
                print(path.read_text(errors="replace")[-4000:], file=sys.stderr)
        raise


if __name__ == "__main__":
    main()
