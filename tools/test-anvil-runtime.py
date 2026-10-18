#!/usr/bin/env python3
"""Exercise the runtime evidence gate independently of a successful QEMU run."""
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("anvil_menus", Path(__file__).with_name("test-system-menus.py"))
menus = importlib.util.module_from_spec(spec)
spec.loader.exec_module(menus)
SELECTED = "[kernel] Anvil backend=software hardware_acceleration=0\n"
COMPLETED = "[kernel] Anvil first presentation completed\n"


class BackendEvidenceTests(unittest.TestCase):
    def test_actual_software_selection_precedes_completed_work(self):
        result = menus.verify_anvil_backend(SELECTED + COMPLETED, required=True)
        self.assertEqual(result, {"backend": "software", "hardware_acceleration": False,
                                  "first_presentation_completed": True})

    def test_absent_optional_backend_keeps_historical_images_distinct(self):
        self.assertIsNone(menus.verify_anvil_backend("[kernel] legacy display\n"))
        with self.assertRaises(AssertionError):
            menus.verify_anvil_backend("[kernel] legacy display\n", required=True)

    def test_missing_duplicate_or_false_acceleration_evidence_rejected(self):
        for body in (SELECTED, COMPLETED, SELECTED + SELECTED + COMPLETED,
                     SELECTED + COMPLETED + COMPLETED,
                     SELECTED.replace("hardware_acceleration=0", "hardware_acceleration=1") + COMPLETED,
                     SELECTED.replace("backend=software", "backend=hardware") + COMPLETED):
            with self.subTest(body=body), self.assertRaises(AssertionError):
                menus.verify_anvil_backend(body, required=True)

    def test_completion_before_initialization_rejected(self):
        with self.assertRaises(AssertionError):
            menus.verify_anvil_backend(COMPLETED + SELECTED, required=True)


if __name__ == "__main__":
    unittest.main()
