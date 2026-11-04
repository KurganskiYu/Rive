import contextlib
import csv
import io
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import _generate_html as generator
import catalog_core as core
from catalog_cli import read_catalog


class CatalogTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        (self.root / "riv").mkdir()
        self.table = self.root / "_videos.csv"

    def write_rows(self, rows):
        with self.table.open("w", newline="", encoding="utf-8") as file:
            writer = csv.writer(file)
            writer.writerow(["src", "size", "preview", "params..."])
            writer.writerows(rows)
        for row in rows:
            src = row[0].removesuffix(".riv")
            if "/" not in src:
                (self.root / "riv" / f"{src}.riv").write_bytes(b"fixture")

    def test_generator_reexports_shared_helpers(self):
        for name in (
            "load_csv_rows", "assign_page_stems", "parse_input_spec", "parse_font_spec",
            "parse_enum_spec", "parse_number_range", "parse_size_spec",
        ):
            self.assertIs(getattr(generator, name), getattr(core, name))

    def test_all_tokens_notes_and_legacy_warnings(self):
        tokens = [
            "num:Legacy(80)", "bol:Flag", "v_num:Percent(79.4:0-100)", "v_bol:Dark(True)",
            'txt:Text("Hello, world")', "col:Tint", "img:Photo(test.png)",
            "list:Bars[num:Height]", "enum:Language(EN:EN|ES)", 'font:"Font.otf"',
        ]
        self.write_rows([["01_demo_v2.riv", "393xlayout", "", *tokens,
                          'note:"first"', 'note:"second"', "future:value", "malformed", ""]])
        for folder, filename in (("fonts", "Font.otf"), ("img", "test.png")):
            (self.root / folder).mkdir()
            (self.root / folder / filename).write_bytes(b"asset")
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            row = core.load_csv_rows(self.table)[0]
        self.assertEqual(row["inputs"], tokens)
        self.assertEqual(row["notes"], ["first", "second"])
        self.assertEqual(row["src"], "01_demo_v2")
        self.assertEqual(output.getvalue(),
                         "Warning: unknown key 'future' in token 'future:value' for 01_demo_v2\n"
                         "Warning: ignoring malformed token 'malformed' for 01_demo_v2\n")
        snapshot = read_catalog(self.root)
        self.assertEqual(snapshot["entries"][0]["fields"][-3:], ["future:value", "malformed", ""])
        self.assertEqual(len(snapshot["diagnostics"]), 2)

    def test_loading_does_not_write_names_or_tables(self):
        self.write_rows([["01_demo_v1", "80x80", ""]])
        before = self.table.read_bytes()
        read_catalog(self.root)
        self.assertFalse((self.root / "_videos_names.csv").exists())
        names = self.root / "_videos_names.csv"
        names.write_bytes(b"filename,name\r\n01_demo,Custom name\r\nunused,Retained\r\n")
        names_before = names.read_bytes()
        snapshot = read_catalog(self.root)
        self.assertEqual(snapshot["entries"][0]["label"], "01 Custom name")
        self.assertEqual(names.read_bytes(), names_before)
        self.assertEqual(self.table.read_bytes(), before)

    def test_default_artboard_modes_and_shared_pages(self):
        self.write_rows([
            ["demo_v1", "80x80", "", "artboard:Circle"],
            ["demo_v1", "80x80", "", "artboard:Wave"],
            ["implicit_v1", "80x80", ""],
            ["default_v1", "80x80", "", "artboard:-"],
        ])
        entries = read_catalog(self.root)["entries"]
        self.assertEqual([entry["page_stem"] for entry in entries],
                         ["default_v1", "implicit_v1", "demo_v1--Wave", "demo_v1--Circle"])
        self.assertEqual((entries[0]["artboard_mode"], entries[0]["artboard"]), ("default", ""))
        self.assertEqual((entries[1]["artboard_mode"], entries[1]["artboard"]), ("implicit", "main"))
        self.assertEqual(len({entry["id"] for entry in entries}), 4)

    def test_version_change_preserves_read_identity(self):
        self.write_rows([["demo_v1", "80x80", ""]])
        first = read_catalog(self.root)["entries"][0]["id"]
        self.write_rows([["demo_v2", "80x80", ""]])
        self.assertEqual(first, read_catalog(self.root)["entries"][0]["id"])

    def test_sizes_and_range_precision(self):
        for size, auto_w, auto_h in (
            ("393x852", False, False), ("layoutx393", True, False),
            ("393xlayout", False, True), ("layoutxlayout", True, True),
        ):
            with self.subTest(size=size):
                spec = core.parse_size_spec(size)
                self.assertEqual((spec["auto_w"], spec["auto_h"]), (auto_w, auto_h))
        self.assertEqual(core.parse_size_spec("invalid")["width"], 0)
        self.assertEqual(core.parse_number_range("-0.5:-1.0-2.0"), ("-0.5", "-1.0", "2.0", "0.1"))
        self.assertEqual(core.parse_font_spec("font:Asset(Font.otf)"), ("Asset", "Font.otf"))
        self.assertEqual(core.parse_enum_spec("ES:EN|ES|RU"), ("ES", ["EN", "ES", "RU"]))

    def test_dimension_labels_use_shared_case_insensitive_parser(self):
        for size, labels in (
            ("393X852", ("393", "852")),
            ("LAYOUTx393", ("layout", "393")),
            ("393XLayout", ("393", "layout")),
            ("LayoutXLAYOUT", ("layout", "layout")),
        ):
            with self.subTest(size=size):
                self.write_rows([["demo_v1", size, ""]])
                entry = read_catalog(self.root)["entries"][0]
                self.assertEqual((entry["size_x"], entry["size_y"]), labels)

    def test_missing_files_and_invalid_sizes_are_located(self):
        self.write_rows([["missing_v1", "0x80", "invalid"]])
        (self.root / "riv" / "missing_v1.riv").unlink()
        issues = read_catalog(self.root)["diagnostics"]
        self.assertEqual({issue["field"] for issue in issues}, {"src", "size", "preview"})
        self.assertTrue(all(issue["line"] == 2 and issue["severity"] == "error" for issue in issues))

    def test_protocol_rejects_writes_and_returns_json_errors(self):
        self.write_rows([["demo_v1", "80x80", ""]])
        for command, exit_code in (("load", 0), ("validate", 0), ("save", 1)):
            result = subprocess.run(
                [sys.executable, "-B", str(Path(__file__).with_name("catalog_cli.py"))],
                input=json.dumps({"version": 1, "command": command, "root": str(self.root)}),
                text=True, capture_output=True, check=False,
            )
            self.assertEqual(result.returncode, exit_code, result.stderr)
            self.assertEqual(json.loads(result.stdout)["success"], exit_code == 0)
            self.assertEqual(result.stderr, "")

    def test_empty_catalog_and_ambiguous_names(self):
        self.write_rows([])
        self.assertEqual(read_catalog(self.root)["entries"], [])
        self.write_rows([["demo_v1", "80x80", ""], ["demo_v1", "80x80", ""]])
        with self.assertRaisesRegex(ValueError, "Ambiguous"):
            read_catalog(self.root)

    def test_invalid_parameter_defaults_and_assets_are_reported(self):
        tokens = [
            "num:Bad(NaN)", "v_num:Range(120:0-100)", "v_num:Malformed(words)",
            "v_bol:Flag(maybe)", "enum:Options", "txt:", "font:Missing.otf",
            "img:Photo(../outside.png)",
        ]
        self.write_rows([["demo_v1", "80x80", "", *tokens]])
        issues = read_catalog(self.root)["diagnostics"]
        self.assertEqual({issue["field"] for issue in issues}, set(tokens))
        self.assertTrue(all(issue["line"] == 2 and issue["severity"] == "error" for issue in issues))

    def test_validate_reports_errors_without_discarding_records(self):
        self.write_rows([["demo_v1", "0x80", ""]])
        result = subprocess.run(
            [sys.executable, "-B", str(Path(__file__).with_name("catalog_cli.py"))],
            input=json.dumps({"version": 1, "command": "validate", "root": str(self.root)}),
            text=True, capture_output=True, check=False,
        )
        response = json.loads(result.stdout)
        self.assertEqual(result.returncode, 1)
        self.assertFalse(response["success"])
        self.assertEqual(len(response["data"]["entries"]), 1)
        self.assertEqual(response["data"]["diagnostics"][0]["field"], "size")

    def test_bad_csv_is_rejected(self):
        self.table.write_text('src,size,preview\n"unterminated,80x80,\n')
        with self.assertRaises(csv.Error):
            read_catalog(self.root)


if __name__ == "__main__":
    unittest.main()
