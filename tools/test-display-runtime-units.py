#!/usr/bin/env python3
"""Reject false-positive display evidence using independent byte fixtures.

No QEMU process, device, network connection, build, or existing artifact is used.
"""
import copy
import hashlib
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("bedrock_display_gate_units", Path(__file__).with_name("test-display-runtime.py"))
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)


def serial_fixture(persistent=False, architecture="x86_64"):
    # Independent source-language output protocol, including A's explicit
    # surface close before its successful process reports its restart.
    lines = ["[bootloader] application archive staged", "[kernel] protected surface broker ready",
             "[kernel] installed native init ready; persistent supervisor", "[display-server] protected compositor ready"]
    for _ in range(1 if persistent else 3):
        lines += ["[display-client] surface A fault requested",
                  "[kernel] surface A generation reclaimed; surface B retained",
                  "[kernel] surface A generation reclaimed; surface B retained",
                  "[display-client] surface A restart verified"]
    lines += ["[display-init] two surfaces and client survival verified",
              "[kernel] display identities and surface ownership verified",
              "[display-client] focused input accepted"]
    if not persistent:
        lines += ["[kernel] focused display input verified",
                  "[kernel] surface A generation reclaimed; surface B retained",
                  "[kernel] display teardown balanced", "[kernel] display acceptance complete"]
    return ("\n".join(lines) + "\n").encode()


def screenshot_fixture(toggled=False, a_toggled=False, text=True, stale_blue=False):
    width, height = 800, 600
    pixels = bytearray(bytes((43, 46, 58)) * width * height)
    def rectangle(x, y, w, h, color):
        for row in range(y, y + h):
            begin = (row * width + x) * 3
            pixels[begin:begin + w * 3] = bytes(color) * w
    for x, accent in ((24, (168, 197, 165) if a_toggled else (212, 149, 173)),
                      (456, (168, 197, 165) if toggled else (139, 174, 192))):
        rectangle(x, 64, 320, 240, (30, 32, 42))
        rectangle(x, 64, 320, 2, accent)
        rectangle(x, 302, 320, 2, accent)
        if text:
            rectangle(x + 24, 110, 30, 10, (228, 223, 213))
            rectangle(x + 24, 142, 10, 10, (153, 158, 174))
    if stale_blue:
        rectangle(500, 180, 1, 1, (139, 174, 192))
    return b"P6\n800 600\n255\n" + bytes(pixels)


def receipt_fixture(serial, before, after, persistent=False, architecture="x86_64"):
    def shot(data, name, toggled):
        width, height, pixels = gate.parse_ppm(data)
        value = gate.verify_scene(pixels, width, height, toggled)
        value.update(ppm="/owned/" + name + ".ppm", sha256=hashlib.sha256(data).hexdigest())
        return value
    return {
        "status": "passed", "architecture": architecture,
        "mode": "persistent" if persistent else "acceptance",
        "image": "/owned/esp", "image_kind": "esp-directory",
        "marker_counts": gate.counts(serial.decode()), "marker_text": gate.MARKERS,
        "serial_sha256": hashlib.sha256(serial).hexdigest(),
        "stderr_sha256": hashlib.sha256(b"").hexdigest(),
        "native_framebuffer_pixels_verified": True,
        "focused_input_changed_only_surface_b": True,
        "surface_a_survived_as_pink": True,
        "surviving_client_b_kept_same_process": True,
        "queued_snapshot_grants_read_only": True,
        "fresh_ordinary_data_image": True,
        "fault_rounds": 1 if persistent else 3,
        "pre_readiness_reclaimed_generations": 2 if persistent else 6,
        "total_reclaimed_generations": 2 if persistent else 7,
        "teardown_balanced": not persistent,
        "owned_qemu_terminated_by_runner": persistent,
        "qemu_exit": -15 if persistent else 33 if architecture == "x86_64" else 0,
        "persistent_seconds_after_readiness": 1.05 if persistent else 0,
        "elapsed_seconds": 12.5,
        "before_input": shot(before, "before", False),
        "after_input": shot(after, "after", True),
    }


class DisplayEvidenceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.before = screenshot_fixture()
        cls.after = screenshot_fixture(toggled=True)
        cls.serial = serial_fixture()
        cls.receipt = receipt_fixture(cls.serial, cls.before, cls.after)

    def verify(self, receipt=None, serial=None, errors=b"", before=None, after=None, image=None):
        return gate.verify_receipt(self.receipt if receipt is None else receipt,
                                   self.serial if serial is None else serial, errors,
                                   self.before if before is None else before,
                                   self.after if after is None else after, image)

    def test_acceptance_and_persistent_receipts_crosscheck_complete_evidence(self):
        for architecture in ("x86_64", "arm64", "riscv64"):
            for persistent in (False, True):
                with self.subTest(architecture=architecture, persistent=persistent):
                    serial = serial_fixture(persistent, architecture)
                    receipt = receipt_fixture(serial, self.before, self.after, persistent, architecture)
                    self.verify(receipt, serial)

    def test_antialiased_text_preserves_full_pixel_and_input_requirements(self):
        # 75% coverage of TEXT over the native window background, independently
        # computed from the documented integer coverage compositing formula.
        antialiased = bytes((179, 176, 171))
        before = self.before.replace(bytes((228, 223, 213)), antialiased)
        after = self.after.replace(bytes((228, 223, 213)), antialiased)
        receipt = receipt_fixture(self.serial, before, after)
        self.verify(receipt, before=before, after=after)
        # An unrelated bright color is not text coverage and still fails.
        corrupt = before.replace(antialiased, bytes((179, 175, 175)))
        width, height, pixels = gate.parse_ppm(corrupt)
        with self.assertRaises(AssertionError): gate.verify_scene(pixels, width, height, False)

    def test_empty_partial_non_object_or_unpassed_receipts_are_not_evidence(self):
        for value in ({}, {"status": "passed"}, [], "passed", dict(self.receipt, status="failed")):
            with self.subTest(value=value), self.assertRaises(AssertionError):
                gate.verify_receipt(value, self.serial, b"", self.before, self.after)

    def test_missing_claims_counters_and_artifact_metadata_are_rejected(self):
        for field in ("marker_counts", "serial_sha256", "fresh_ordinary_data_image", "native_framebuffer_pixels_verified", "teardown_balanced", "qemu_exit", "elapsed_seconds", "before_input", "after_input", "image"):
            value = copy.deepcopy(self.receipt)
            del value[field]
            with self.subTest(field=field), self.assertRaises(AssertionError):
                self.verify(value)

    def test_correct_counts_cannot_hide_wrong_round_event_order(self):
        body = self.serial.decode().splitlines()
        body[4], body[7] = body[7], body[4]
        reordered = ("\n".join(body) + "\n").encode()
        self.assertEqual(gate.counts(self.serial.decode()), gate.counts(reordered.decode()))
        value = copy.deepcopy(self.receipt)
        value["serial_sha256"] = hashlib.sha256(reordered).hexdigest()
        with self.assertRaises(AssertionError):
            self.verify(value, reordered)

    def test_final_reclamation_before_readiness_does_not_prove_balance(self):
        body = self.serial.decode().splitlines()
        final = body.pop(-3)
        body.insert(4, final)
        reordered = ("\n".join(body) + "\n").encode()
        self.assertEqual(gate.counts(self.serial.decode()), gate.counts(reordered.decode()))
        with self.assertRaises(AssertionError):
            gate.verify_markers(reordered.decode(), "", False, True)

    def test_survival_without_teardown_or_duplicate_success_markers_is_rejected(self):
        for body in (self.serial.replace(b"[kernel] display teardown balanced\n", b""),
                     self.serial + b"[kernel] display acceptance complete\n",
                     self.serial.replace(b"[display-client] focused input accepted\n", b"")):
            with self.subTest(body=body[-150:]), self.assertRaises(AssertionError):
                gate.verify_markers(body.decode(), "", False, True)

    def test_success_markers_do_not_override_kernel_failure_in_either_stream(self):
        for serial, errors in ((self.serial + b"[panic] kernel\n", b""),
                               (self.serial, b"[fault] kernel: surface leak\n")):
            with self.assertRaises(AssertionError):
                self.verify(serial=serial, errors=errors)

    def test_stale_hashes_and_forged_receipt_counts_are_rejected(self):
        for field, replacement in (("serial_sha256", "0" * 64), ("stderr_sha256", "0" * 64),
                                    ("marker_counts", {}), ("total_reclaimed_generations", 6), ("fault_rounds", 2)):
            value = copy.deepcopy(self.receipt)
            value[field] = replacement
            with self.subTest(field=field), self.assertRaises(AssertionError):
                self.verify(value)

    def test_json_booleans_cannot_masquerade_as_numeric_proof_counters(self):
        serial = serial_fixture(True)
        original = receipt_fixture(serial, self.before, self.after, True)
        for mode in ("marker", "faults", "pixels"):
            value = copy.deepcopy(original)
            if mode == "marker":
                value["marker_counts"]["archive"] = True
            elif mode == "faults":
                value["fault_rounds"] = True
            else:
                value["before_input"]["surface_a"]["green"] = False
            with self.subTest(mode=mode), self.assertRaises(AssertionError):
                self.verify(value, serial)

    def test_wrong_focus_stale_accent_or_missing_native_text_pixels_are_rejected(self):
        for data in (screenshot_fixture(toggled=True, a_toggled=True),
                     screenshot_fixture(), screenshot_fixture(toggled=True, stale_blue=True),
                     screenshot_fixture(toggled=True, text=False)):
            with self.assertRaises(AssertionError):
                self.verify(after=data)

    def test_truncated_trailing_non_rgb_and_oversized_screenshot_headers_are_rejected(self):
        for data in (self.after[:-1], self.after + b"\0", self.after.replace(b"P6", b"P3", 1),
                     self.after.replace(b"255\n", b"65535\n", 1),
                     self.after.replace(b"800 600", b"800 -600", 1),
                     self.after.replace(b"800 600", b"1281 800", 1), b""):
            with self.subTest(header=data[:25]), self.assertRaises(AssertionError):
                self.verify(after=data)

    def test_saved_screenshot_metadata_cannot_claim_other_pixels(self):
        for field, replacement in (("sha256", "0" * 64), ("width", 1280), ("surface_b", {"green": 1000}), ("ppm", "")):
            value = copy.deepcopy(self.receipt)
            value["after_input"][field] = replacement
            with self.subTest(field=field), self.assertRaises(AssertionError):
                self.verify(value)

    def test_raw_image_digest_is_required_and_matches_explicitly_supplied_source(self):
        value = copy.deepcopy(self.receipt)
        value.update(image_kind="raw-image", image="/owned/display.img")
        with self.assertRaises(AssertionError):
            self.verify(value)
        source = b"ordinary raw image fixture"
        value["image_sha256"] = hashlib.sha256(source).hexdigest()
        self.verify(value, image=source)
        with self.assertRaises(AssertionError):
            self.verify(value, image=source + b"changed")

    def test_persistent_receipt_cannot_claim_completed_teardown_or_short_live_observation(self):
        serial = serial_fixture(True)
        receipt = receipt_fixture(serial, self.before, self.after, True)
        for field, replacement in (("teardown_balanced", True), ("owned_qemu_terminated_by_runner", False),
                                    ("persistent_seconds_after_readiness", .99),
                                    ("persistent_seconds_after_readiness", float("nan")),
                                    ("elapsed_seconds", .5)):
            changed = copy.deepcopy(receipt)
            changed[field] = replacement
            with self.subTest(field=field, value=replacement), self.assertRaises(AssertionError):
                self.verify(changed, serial)


if __name__ == "__main__":
    unittest.main()
