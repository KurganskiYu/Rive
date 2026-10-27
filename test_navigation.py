import csv
import tempfile
import unittest
from pathlib import Path

from _navigation import load_navigation_entries, render_navigation


class NavigationTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.names_path = Path(self.directory.name) / "names.csv"
        self.rows = [
            {"src": "River_v1", "page_stem": "River_v1"},
            {"src": "03_loaders_v4", "page_stem": "03_loaders_v4--Eye"},
            {"src": "03_loaders_v4", "page_stem": "03_loaders_v4--Circle"},
        ]

    def write_names(self, rows):
        with self.names_path.open("w", newline="", encoding="utf-8") as file:
            writer = csv.writer(file)
            writer.writerow(["filename", "name"])
            writer.writerows(rows)

    def test_names_match_repeated_filenames_and_unnumbered_entries(self):
        self.write_names([
            ("03_loaders_v4", "Circle & Light"),
            ("03_loaders_v4", "Eye"),
            ("River_v1", "River"),
        ])
        self.assertEqual(load_navigation_entries(self.rows, self.names_path), [
            ("River_v1", "River"),
            ("03_loaders_v4--Eye", "03 Eye"),
            ("03_loaders_v4--Circle", "03 Circle & Light"),
        ])

    def test_rejects_missing_or_out_of_order_names(self):
        self.write_names([("River_v1", "River")])
        with self.assertRaisesRegex(ValueError, "one name per catalog row"):
            load_navigation_entries(self.rows, self.names_path)
        self.write_names([
            ("River_v1", "River"),
            ("03_loaders_v4", "Eye"),
            ("03_loaders_v4", "Circle"),
        ])
        with self.assertRaisesRegex(ValueError, "match catalog row order"):
            load_navigation_entries(self.rows, self.names_path)

    def test_links_are_relative_and_names_are_escaped(self):
        entries = [("03_name with spaces", '03 <Name> & "More"')]
        root = render_navigation(entries, True)
        nested = render_navigation(entries, False)
        self.assertIn('href="pages/03_name%20with%20spaces.html"', root)
        self.assertIn('href="03_name%20with%20spaces.html"', nested)
        self.assertIn("03 &lt;Name&gt; &amp; &quot;More&quot;", root)


if __name__ == "__main__":
    unittest.main()
