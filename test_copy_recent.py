import contextlib
import io
import os
import tempfile
import time
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch

from _generate_html import copy_recent_riv_files, main


class CopyRecentTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        root = Path(self.directory.name)
        self.source = root / "source"
        self.destination = root / "riv"
        self.source.mkdir()

    def archive(self, name, files):
        path = self.source / name
        with zipfile.ZipFile(path, "w") as archive:
            for filename, contents in files.items():
                archive.writestr(filename, contents)
        return path

    def run_copy(self):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            copy_recent_riv_files(self.source, self.destination)
        return output.getvalue()

    def test_extracts_and_renames_preview_without_extracting_assets(self):
        archive = self.archive("nested_v12_preview.zip", {
            "folder/nested.riv": b"animation",
            "assets/image.png": b"asset",
        })
        output = self.run_copy()
        self.assertEqual(output, "Extracted nested_v12_preview.zip -> nested_v12_preview.riv (copied; archive deleted)\n")
        self.assertEqual((self.source / "nested_v12_preview.riv").read_bytes(), b"animation")
        self.assertEqual((self.destination / "nested_v12_preview.riv").read_bytes(), b"animation")
        self.assertFalse(archive.exists())
        self.assertFalse((self.source / "assets").exists())

    def test_multiple_rive_files_use_unique_unversioned_match(self):
        archive = self.archive("Example_v5.zip", {
            "other.riv": b"other",
            "subdir/Example.riv": b"correct",
        })
        self.run_copy()
        self.assertEqual((self.destination / "Example_v5.riv").read_bytes(), b"correct")
        self.assertFalse(archive.exists())

    def test_invalid_or_ambiguous_archives_are_retained(self):
        invalid = self.archive("empty_v1.zip", {"asset.png": b"asset"})
        unmatched = self.archive("unrelated.zip", {"other.riv": b"other"})
        ambiguous = self.archive("Example_v5.zip", {
            "one/Example.riv": b"one",
            "two/Example.riv": b"two",
        })
        output = self.run_copy()
        self.assertTrue(invalid.exists())
        self.assertTrue(unmatched.exists())
        self.assertTrue(ambiguous.exists())
        self.assertIn("Failed", output)
        self.assertEqual(list(self.destination.iterdir()), [])

    def test_old_archives_are_ignored_and_recent_rive_files_still_copied(self):
        old = self.archive("old_v1.zip", {"old.riv": b"old"})
        old_time = time.time() - 600
        os.utime(old, (old_time, old_time))
        (self.source / "normal_v2.riv").write_bytes(b"normal")
        output = self.run_copy()
        self.assertTrue(old.exists())
        self.assertEqual((self.destination / "normal_v2.riv").read_bytes(), b"normal")
        self.assertEqual(output, "Copied normal_v2.riv\n")

    def test_failed_destination_copy_keeps_archive_for_retry(self):
        archive = self.archive("Example_v5.zip", {"Example.riv": b"data"})
        self.destination.mkdir()
        destination = self.destination / "Example_v5.riv"
        destination.write_bytes(b"previous")
        with patch("_generate_html.shutil.copy2", side_effect=OSError("disk full")):
            output = self.run_copy()
        self.assertTrue(archive.exists())
        self.assertIn("disk full", output)
        self.assertEqual(destination.read_bytes(), b"previous")
        self.run_copy()
        self.assertFalse(archive.exists())
        self.assertEqual(destination.read_bytes(), b"data")

    def test_corrupt_archive_is_retained_and_reported(self):
        archive = self.source / "broken_v1.zip"
        archive.write_bytes(b"not a zip file")
        output = self.run_copy()
        self.assertTrue(archive.exists())
        self.assertIn("Failed", output)
        self.assertEqual(list(self.destination.iterdir()), [])

    def test_newer_source_file_is_not_overwritten_or_archive_deleted(self):
        archive = self.archive("Example_v5.zip", {"Example.riv": b"archived"})
        source = self.source / "Example_v5.riv"
        source.write_bytes(b"newer")
        future = time.time() + 10
        os.utime(source, (future, future))
        output = self.run_copy()
        self.assertTrue(archive.exists())
        self.assertEqual(source.read_bytes(), b"newer")
        self.assertIn("newer", output)
        self.assertNotIn(str(self.source), output)

    def test_os_errors_show_reason_without_paths(self):
        (self.source / "normal.riv").write_bytes(b"normal")
        error = OSError(13, "Permission denied", str(self.destination / "normal.riv"))
        with patch("_generate_html.shutil.copy2", side_effect=error):
            output = self.run_copy()
        self.assertEqual(output, "Failed to process normal.riv: Permission denied\n")

    def test_missing_source_is_reported_once_without_paths(self):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            copy_recent_riv_files(self.source / "missing", self.destination)
        self.assertEqual(output.getvalue(), "No source folder found. Set RIV_SRC_DIR to enable copying.\n")

    def test_generation_summary_shows_names_and_counts_only(self):
        rows = [{"src": f"file{index}"} for index in range(9)]
        output = io.StringIO()
        with (
            patch("_generate_html.load_csv_rows", return_value=rows),
            patch("_generate_html.assign_page_stems"),
            patch("_generate_html.load_navigation_entries", return_value=[]),
            patch("_generate_html.load_custom_catalogs", return_value=[]),
            patch("_generate_html.make_animation_page"),
            patch("_generate_html.write_main_page"),
            contextlib.redirect_stdout(output),
        ):
            main()
        self.assertEqual(output.getvalue(),
                         "Generated index.html, 1 additional page, and 9 animation pages.\n")

    def test_empty_catalog_has_no_negative_page_count(self):
        output = io.StringIO()
        with (
            patch("_generate_html.load_csv_rows", return_value=[]),
            patch("_generate_html.load_navigation_entries", return_value=[]),
            patch("_generate_html.load_custom_catalogs", return_value=[]),
            contextlib.redirect_stdout(output),
        ):
            main()
        self.assertEqual(output.getvalue(), "No pages generated: the catalog is empty.\n")


if __name__ == "__main__":
    unittest.main()
