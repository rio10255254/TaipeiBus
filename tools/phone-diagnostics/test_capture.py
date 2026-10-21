import json
from pathlib import Path
import tempfile
import unittest
import zipfile

from capture import filtered_record, redact, write_report


class CaptureTests(unittest.TestCase):
    def test_retains_app_rendering_error_but_redacts_identifiers(self):
        value = filtered_record("chronod", 'TaipeiBusWidgets Archive was nil 01234567-89AB-CDEF-0123-456789ABCDEF "User stop"', "ERROR", "now")
        self.assertIn("Archive was nil", value["message"])
        self.assertNotIn("User stop", value["message"])
        self.assertNotIn("01234567", value["message"])

    def test_drops_unrelated_messages_and_reduces_unscoped_errors(self):
        self.assertIsNone(filtered_record("Mail", "Private email", "ERROR", "now"))
        self.assertIsNone(filtered_record("chronod", "AnotherApp private status", "INFO", "now"))
        value = filtered_record("chronod", "AnotherApp SecretName: Archive was nil", "ERROR", "now")
        self.assertEqual(value["message"], "[Unscoped renderer error] Archive was nil")

    def test_navigation_payload_and_coordinates_do_not_enter_report(self):
        self.assertEqual(redact('ContentState headline=Private shop, latitude=25.0415'), "[Navigation payload omitted]")
        self.assertNotIn("25.0415", redact("TaipeiBus location 25.0415,121.5436"))
        self.assertNotIn("person@example.com", redact("TaipeiBus person@example.com"))

    def test_archive_contains_only_filtered_output(self):
        with tempfile.TemporaryDirectory() as directory:
            archive = write_report(Path(directory) / "report", {"status": "captured"}, [{"message": "Archive was nil"}])
            with zipfile.ZipFile(archive) as z:
                self.assertEqual(set(z.namelist()), {"summary.json", "rendering.jsonl"})
                self.assertEqual(json.loads(z.read("summary.json"))["status"], "captured")
                self.assertIn(b"Archive was nil", z.read("rendering.jsonl"))


if __name__ == "__main__":
    unittest.main()
