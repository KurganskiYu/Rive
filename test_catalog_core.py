import contextlib
import csv
import io
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

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


class CustomCatalogTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        (self.root / "riv").mkdir()
        (self.root / "pages").mkdir()
        (self.root / "head.html").write_text(
            '<!DOCTYPE html>\n<html><head><link href="RiveIcon2.svg">'
            '<link href="styles.css"></head><body><div class="animation-wrapper">\n',
            encoding="utf-8",
        )
        self.sets = self.root / "_videos_sets.csv"
        self.descriptions = self.root / "_videos_descriptions.txt"
        self.descriptions.write_text("# Add descriptions here.\n", encoding="utf-8")
        patcher = patch.multiple(
            generator,
            script_dir=str(self.root),
            csv_path=str(self.root / "_videos.csv"),
            names_path=str(self.root / "_videos_names.csv"),
            sets_path=str(self.sets),
            descriptions_path=str(self.descriptions),
            output_html=str(self.root / "index.html"),
            head_html_path=str(self.root / "head.html"),
            pages_dir=str(self.root / "pages"),
        )
        patcher.start()
        self.addCleanup(patcher.stop)
        generator.get_html_head.cache_clear()
        self.addCleanup(generator.get_html_head.cache_clear)

    def write_catalog(self, rows, names):
        with (self.root / "_videos.csv").open("w", newline="", encoding="utf-8") as file:
            writer = csv.writer(file)
            writer.writerow(["src", "size", "preview", "params..."])
            writer.writerows(rows)
        with (self.root / "_videos_names.csv").open("w", newline="", encoding="utf-8") as file:
            writer = csv.writer(file)
            writer.writerow(["filename", "name"])
            writer.writerows(names)
        for row in rows:
            (self.root / "riv" / f"{row[0]}.riv").write_bytes(b"fixture")

    def generate(self):
        with contextlib.redirect_stdout(io.StringIO()):
            generator.main()

    def test_custom_content_and_shared_numbers_leave_main_presentation_unchanged(self):
        self.write_catalog(
            [
                ["01_demo_v1", "80x80", "120x120", "artboard:First", "trigger:Go"],
                ["01_demo_v1", "80x80", "", "artboard:Second", "trigger:Go"],
                ["02_other_v1", "393xlayout", "", "trigger:Go",
                 "font:Typeface(Font.otf)", "img:Photo(test.png)"],
                ["03_unused_v1", "80x80", ""],
            ],
            [
                ["01_demo--First", "First favorite"],
                ["01_demo--Second", "Second & special"],
                ["02_other", "Other favorite"],
                ["03_unused", "Not selected"],
            ],
        )
        self.sets.write_text("client,02,01,1\n", encoding="utf-8")
        self.descriptions.write_text(
            "01: A <useful> description, with & punctuation.\n"
            "02: Another description: with a colon.\n",
            encoding="utf-8",
        )
        self.generate()

        catalog = (self.root / "client" / "index.html").read_text(encoding="utf-8")
        detail = (self.root / "client" / "01_demo_v1--First.html").read_text(encoding="utf-8")
        main_catalog = (self.root / "index.html").read_text(encoding="utf-8")
        main_detail = (self.root / "pages" / "01_demo_v1--First.html").read_text(encoding="utf-8")

        self.assertIn('href="02_other_v1.html">02 Other favorite</a>', catalog)
        self.assertIn('href="01_demo_v1--Second.html">01 Second &amp; special</a>', catalog)
        self.assertIn('href="01_demo_v1--First.html">01 First favorite</a>', catalog)
        self.assertLess(catalog.index("02 Other favorite"), catalog.index("01 Second &amp; special"))
        self.assertEqual(catalog.count("A &lt;useful&gt; description, with &amp; punctuation."), 2)
        self.assertIn("A &lt;useful&gt; description, with &amp; punctuation.", detail)
        self.assertIn("01 First favorite", detail)
        self.assertFalse((self.root / "client" / "03_unused_v1.html").exists())
        self.assertNotIn('href="../riv/', catalog + detail)
        self.assertNotIn('class="riv-file-size"', catalog + detail)
        self.assertNotIn(">Trigger</button>", catalog + detail)
        self.assertIn(">Run</button>", catalog)
        self.assertEqual(detail.count(">Run</button>"), 2)
        self.assertIn('src: "../riv/01_demo_v1.riv"', catalog)
        self.assertIn('href="../styles.css"', catalog)
        self.assertIn('href="../RiveIcon2.svg"', detail)
        self.assertIn('data-auto-h', catalog)
        self.assertIn('fetch("../img/test.png")', catalog)
        self.assertIn('"../fonts/"', catalog)
        self.assertIn('class="riv-file-size"', main_catalog + main_detail)
        self.assertIn(">Trigger</button>", main_catalog)
        self.assertIn('href="../riv/01_demo_v1.riv"', main_detail)
        self.assertNotIn("A &lt;useful&gt; description", main_catalog + main_detail)

    def test_pagination_and_removing_a_number_remove_only_generated_pages(self):
        rows = [[f"{number:02}_demo_v1", "80x80", ""] for number in range(1, 11)]
        names = [[f"{number:02}_demo", f"Demo {number}"] for number in range(1, 11)]
        self.write_catalog(rows, names)
        self.sets.write_text("client," + ",".join(str(number) for number in range(1, 11)) + "\n")
        self.generate()

        output = self.root / "client"
        first = (output / "index.html").read_text(encoding="utf-8")
        second = (output / "catalog-page-2.html").read_text(encoding="utf-8")
        self.assertIn('href="catalog-page-2.html"', first)
        self.assertIn('href="index.html"', second)
        self.assertIn('href="09_demo_v1.html"', second)
        self.assertIn('src: "../riv/09_demo_v1.riv"', second)

        unrelated = output / "notes.html"
        unrelated.write_text("Keep this file.", encoding="utf-8")
        self.sets.write_text("client,01\n", encoding="utf-8")
        self.generate()
        self.assertFalse((output / "catalog-page-2.html").exists())
        self.assertFalse((output / "09_demo_v1.html").exists())
        self.assertTrue((output / "01_demo_v1.html").exists())
        self.assertEqual(unrelated.read_text(encoding="utf-8"), "Keep this file.")

        self.sets.write_text("client\n", encoding="utf-8")
        self.generate()
        self.assertTrue((output / "index.html").exists())
        self.assertFalse((output / "01_demo_v1.html").exists())
        self.assertEqual(unrelated.read_text(encoding="utf-8"), "Keep this file.")

    def test_invalid_input_and_directory_collisions_fail_before_rewriting_main(self):
        self.write_catalog([["01_demo_v1", "80x80", ""]], [["01_demo", "Demo"]])
        main_page = self.root / "index.html"
        main_page.write_text("Existing main catalog.", encoding="utf-8")
        for contents, error in (
            ("../escape,01\n", "set names"),
            ("client,99\n", "no animations found"),
            ("client,01\nCLIENT,01\n", "duplicate set name"),
            ("CON,01\n", "reserved set name"),
            ("riv,01\n", "not a generated custom catalog"),
        ):
            with self.subTest(contents=contents):
                self.sets.write_text(contents, encoding="utf-8")
                with self.assertRaisesRegex(ValueError, error):
                    self.generate()
                self.assertEqual(main_page.read_text(encoding="utf-8"), "Existing main catalog.")
                self.assertEqual((self.root / "riv" / "01_demo_v1.riv").read_bytes(), b"fixture")

        self.sets.write_text("client,01\n", encoding="utf-8")
        self.descriptions.write_text("01: One description\n1: Another description\n", encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "duplicate number"):
            self.generate()
        self.assertEqual(main_page.read_text(encoding="utf-8"), "Existing main catalog.")

    def test_generated_pages_do_not_overwrite_unrelated_files(self):
        self.write_catalog([["01_demo_v1", "80x80", ""]], [["01_demo", "Demo"]])
        self.sets.write_text("client,01\n", encoding="utf-8")
        self.generate()
        detail = self.root / "client" / "01_demo_v1.html"
        detail.write_text("Manually written page.", encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "Cannot replace non-generated file"):
            self.generate()
        self.assertEqual(detail.read_text(encoding="utf-8"), "Manually written page.")


if __name__ == "__main__":
    unittest.main()
