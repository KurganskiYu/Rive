import csv
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from catalog_cli import execute, read_catalog
from catalog_persistence import (
    CatalogConflict, JOURNAL, RecoveryRequired, catalog_lock, read_tables, recover_tables, save_tables,
)


class PersistenceTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        (self.root / "riv").mkdir()
        for src in ("01_demo_v1", "other_v1", "shared_v1", "01_demo_v2"):
            (self.root / "riv" / f"{src}.riv").write_bytes(b"fixture")
        (self.root / "_anim_list.csv").write_bytes(
            b'\xef\xbb\xbfsrc,size,preview,params...\r\n'
            b'01_demo_v1,80XLayout,,future:value,,note:"hello"\r\n'
            b'\r\n"other_v1",90x90,,artboard:-,\r\n'
        )
        (self.root / "_anim_names.csv").write_bytes(
            'filename,name\r\n01_demo,First\r\nother,"Другой"\r\nunused,Preserved\r\n'.encode("utf-8")
        )
        (self.root / "_catalog.json").write_bytes(b'{"version":1,"unrelated":"preserve"}\n')
        self.snapshot = read_catalog(self.root)
        self.entry = next(entry for entry in self.snapshot["entries"] if entry["src"] == "01_demo_v1")

    def request(self, command="save", edits=None):
        return {
            "version": 1, "command": command, "root": str(self.root),
            "base_revision": self.snapshot["revision"], "edits": [] if edits is None else edits,
        }

    def test_noop_save_is_byte_identical_and_creates_no_backup(self):
        before = read_tables(self.root)
        result = execute(self.request(edits=[{
            "id": self.entry["id"], "fields": self.entry["fields"], "name": self.entry["name"],
        }]))
        self.assertTrue(result["success"])
        self.assertEqual(read_tables(self.root), before)
        self.assertFalse((self.root / ".catalog-backups").exists())

    def test_row_and_name_edit_preserve_other_bytes_and_tokens(self):
        before = read_tables(self.root)
        fields = list(self.entry["fields"])
        fields[1] = "120XLayout"
        result = execute(self.request(edits=[{
            "id": self.entry["id"], "fields": fields, "name": 'Новое, "имя"',
        }]))
        self.assertTrue(result["success"])
        after = read_tables(self.root)
        self.assertEqual(after["_catalog.json"], before["_catalog.json"])
        self.assertTrue(after["_anim_list.csv"].startswith(b"\xef\xbb\xbf"))
        self.assertTrue(after["_anim_list.csv"].endswith(b'\r\n"other_v1",90x90,,artboard:-,\r\n'))
        updated = next(entry for entry in result["data"]["entries"] if entry["id"] == self.entry["id"])
        self.assertEqual(updated["fields"][3:], self.entry["fields"][3:])
        self.assertEqual(updated["size_y"], "layout")
        self.assertEqual(updated["name"], 'Новое, "имя"')
        self.assertTrue(after["_anim_names.csv"].endswith(
            'other,"Другой"\r\nunused,Preserved\r\n'.encode("utf-8")
        ))
        self.assertFalse((self.root / JOURNAL).exists())
        backups = list((self.root / ".catalog-backups").iterdir())
        self.assertEqual(len(backups), 1)
        self.assertEqual((backups[0] / "before-0").read_bytes(), before["_anim_list.csv"])

    def test_validate_draft_does_not_write(self):
        before = read_tables(self.root)
        result = execute(self.request("validate", [{"id": self.entry["id"], "name": "Draft"}]))
        self.assertTrue(result["success"])
        self.assertEqual(read_tables(self.root), before)
        self.assertEqual(next(entry for entry in result["data"]["entries"]
                              if entry["id"] == self.entry["id"])["name"], "Draft")
        self.assertFalse((self.root / ".catalog-backups").exists())

    def test_missing_names_and_metadata_remain_missing_until_needed(self):
        names = self.root / "_anim_names.csv"
        names.unlink()
        (self.root / "_catalog.json").unlink()
        self.snapshot = read_catalog(self.root)
        self.assertTrue(execute(self.request())["success"])
        self.assertFalse(names.exists())
        self.assertFalse((self.root / "_catalog.json").exists())
        result = execute(self.request(edits=[{"id": self.entry["id"], "name": "Created"}]))
        self.assertTrue(result["success"])
        self.assertEqual(next(entry for entry in result["data"]["entries"]
                              if entry["id"] == self.entry["id"])["name"], "Created")
        self.assertFalse((self.root / "_catalog.json").exists())

    def test_names_with_embedded_newlines_survive_another_name_edit(self):
        names = self.root / "_anim_names.csv"
        names.write_bytes(b'filename,name\r\n01_demo,First\r\nother,"Line\rbreak\nnext"\r\n')
        self.snapshot = read_catalog(self.root)
        result = execute(self.request(edits=[{"id": self.entry["id"], "name": "Edited"}]))
        self.assertTrue(result["success"])
        self.assertEqual(result["data"]["entries"][0]["name"], "Line\rbreak\nnext")

    def test_editing_a_name_preserves_shared_id_variants(self):
        table = self.root / "_anim_list.csv"
        table.write_text("src,size,preview\n01_first_v1,80x80,\n01_second_v1,80x80,\n")
        for source in ("01_first_v1", "01_second_v1"):
            (self.root / "riv" / f"{source}.riv").write_bytes(b"fixture")
        names = self.root / "_anim_names.csv"
        names.write_text("filename,name,variant\n01_first,First,a\n01_second,Second,b\n")
        self.snapshot = read_catalog(self.root)
        first = next(entry for entry in self.snapshot["entries"] if entry["src"] == "01_first_v1")
        result = execute(self.request(edits=[{"id": first["id"], "name": "Renamed"}]))
        self.assertTrue(result["success"])
        with names.open(newline="") as file:
            rows = {row["filename"]: row for row in csv.DictReader(file)}
        self.assertEqual((rows["01_first"]["name"], rows["01_first"]["variant"]), ("Renamed", "a"))
        self.assertEqual((rows["01_second"]["name"], rows["01_second"]["variant"]), ("Second", "b"))

    def test_each_table_participates_in_revision_conflicts(self):
        before = read_tables(self.root)
        for name in before:
            with self.subTest(name=name):
                (self.root / name).write_bytes(before[name] + b"\n")
                with self.assertRaises(CatalogConflict):
                    execute(self.request(edits=[{"id": self.entry["id"], "name": "Draft"}]))
                self.assertEqual((self.root / name).read_bytes(), before[name] + b"\n")
                (self.root / name).write_bytes(before[name])

    def test_invalid_draft_returns_located_diagnostics_without_writes(self):
        before = read_tables(self.root)
        fields = [*self.entry["fields"]]
        fields[1] = "0x80"
        result = execute(self.request(edits=[{"id": self.entry["id"], "fields": fields}]))
        self.assertFalse(result["success"])
        self.assertEqual(result["error_code"], "validation")
        self.assertTrue(any(issue["line"] == 2 and issue["field"] == "size"
                            for issue in result["data"]["diagnostics"]))
        self.assertEqual(read_tables(self.root), before)

    def test_invalid_edit_shapes_are_rejected(self):
        for edit in (
            {"id": self.entry["id"], "name": None},
            {"id": self.entry["id"], "fields": ["src", "80x80"]},
            {"id": self.entry["id"], "fields": ["src", "80x80", "\n"]},
            {"id": self.entry["id"], "unknown": True},
            {"id": "missing", "name": "Draft"},
        ):
            with self.subTest(edit=edit), self.assertRaises(ValueError):
                execute(self.request(edits=[edit]))

    def test_final_line_without_newline_and_empty_name(self):
        names = self.root / "_anim_names.csv"
        names.write_bytes(names.read_bytes().rstrip(b"\r\n"))
        table = self.root / "_anim_list.csv"
        table.write_bytes(table.read_bytes().rstrip(b"\r\n"))
        self.snapshot = read_catalog(self.root)
        other = self.snapshot["entries"][0]
        fields = [*other["fields"]]
        fields[1] = "100x100"
        self.assertTrue(execute(self.request(edits=[{
            "id": other["id"], "fields": fields, "name": "",
        }]))["success"])
        self.assertFalse(table.read_bytes().endswith(b"\n"))
        self.assertFalse(names.read_bytes().endswith(b"\n"))
        self.assertEqual(read_catalog(self.root)["entries"][0]["name"], "")

    def test_version_and_artboard_change_keep_name(self):
        fields = [*self.entry["fields"]]
        fields[0] = "01_demo_v2"
        fields.append("artboard:New")
        result = execute(self.request(edits=[{"id": self.entry["id"], "fields": fields}]))
        self.assertTrue(result["success"])
        updated = next(entry for entry in result["data"]["entries"] if entry["src"] == "01_demo_v2")
        self.assertEqual(updated["name"], "First")
        self.assertEqual(updated["artboard_mode"], "named")

    def test_shared_artboards_and_legacy_names_are_resolved(self):
        (self.root / "_anim_list.csv").write_text(
            "src,size,preview\nshared_v1,80x80,,artboard:A\nshared_v1,80x80,,artboard:B\n"
        )
        (self.root / "_anim_names.csv").write_text(
            "filename,name\nshared,Alpha\nshared,Beta\nunused,Retain\n"
        )
        self.snapshot = read_catalog(self.root)
        first = self.snapshot["entries"][0]
        self.assertEqual(first["name"], "Beta")
        result = execute(self.request(edits=[{"id": first["id"], "name": "Updated"}]))
        self.assertTrue(result["success"])
        self.assertEqual([entry["name"] for entry in result["data"]["entries"]], ["Updated", "Alpha"])
        self.assertIn(b"unused,Retain", (self.root / "_anim_names.csv").read_bytes())

    def interrupted_save(self):
        before = read_tables(self.root)
        replace = os.replace

        def fail_second_table(source, destination):
            if Path(destination) == self.root / "_anim_names.csv":
                raise OSError("Simulated interruption between table writes")
            return replace(source, destination)

        fields = [*self.entry["fields"]]
        fields[1] = "120x120"
        with patch("catalog_persistence.os.replace", side_effect=fail_second_table):
            with self.assertRaisesRegex(RecoveryRequired, "Simulated interruption"):
                execute(self.request(edits=[{
                    "id": self.entry["id"], "fields": fields, "name": "Saved",
                }]))
        return before

    def test_interrupted_save_blocks_load_and_rolls_back_all_files(self):
        before = self.interrupted_save()
        self.assertNotEqual(read_tables(self.root)["_anim_list.csv"], before["_anim_list.csv"])
        with self.assertRaises(RecoveryRequired):
            execute(self.request("load"))
        self.assertTrue(execute(self.request("recover"))["success"])
        self.assertEqual(read_tables(self.root), before)
        self.assertFalse((self.root / JOURNAL).exists())

    def test_recovery_succeeds_even_if_assets_disappeared(self):
        self.interrupted_save()
        (self.root / "riv" / "01_demo_v1.riv").unlink()
        result = execute(self.request("recover"))
        self.assertTrue(result["success"])
        self.assertTrue(any(issue["field"] == "src" for issue in result["data"]["diagnostics"]))
        self.assertFalse((self.root / JOURNAL).exists())

    def test_recovery_refuses_external_edits_and_corrupt_backups(self):
        self.interrupted_save()
        path = self.root / "_anim_list.csv"
        current = path.read_bytes()
        path.write_bytes(current + b"\n")
        with self.assertRaises(CatalogConflict):
            recover_tables(self.root)
        self.assertEqual(path.read_bytes(), current + b"\n")
        path.write_bytes(current)
        manifest = json.loads((self.root / JOURNAL).read_bytes())
        (self.root / ".catalog-backups" / manifest["backup"] / "before-0").write_bytes(b"damaged")
        with self.assertRaisesRegex(ValueError, "damaged"):
            recover_tables(self.root)
        self.assertTrue((self.root / JOURNAL).exists())

    def test_interrupted_recovery_can_be_retried(self):
        before = self.interrupted_save()
        replace = os.replace

        def fail_second_restore(source, destination):
            if Path(destination) == self.root / "_anim_names.csv":
                raise OSError("Interrupted during recovery")
            return replace(source, destination)

        with patch("catalog_persistence.os.replace", side_effect=fail_second_restore):
            with self.assertRaisesRegex(OSError, "Interrupted during recovery"):
                recover_tables(self.root)
        self.assertTrue((self.root / JOURNAL).exists())
        recover_tables(self.root)
        self.assertEqual(read_tables(self.root), before)
        self.assertFalse((self.root / JOURNAL).exists())

    def test_file_permissions_survive_save(self):
        names = self.root / "_anim_names.csv"
        names.chmod(0o640)
        result = execute(self.request(edits=[{"id": self.entry["id"], "name": "Changed"}]))
        self.assertTrue(result["success"])
        self.assertEqual(names.stat().st_mode & 0o777, 0o640)

    def test_recovery_removes_new_names_file(self):
        (self.root / "_anim_names.csv").unlink()
        before = read_tables(self.root)
        after = {**before, "_anim_names.csv": b"filename,name\n01_demo,New\n"}
        original_unlink = Path.unlink

        def interrupted_unlink(path, *args, **kwargs):
            if path == self.root / JOURNAL:
                raise OSError("Interrupted before removing journal")
            return original_unlink(path, *args, **kwargs)

        with patch.object(Path, "unlink", interrupted_unlink):
            with self.assertRaises(OSError):
                save_tables(self.root, before, after)
        self.assertTrue((self.root / "_anim_names.csv").exists())
        recover_tables(self.root)
        self.assertEqual(read_tables(self.root), before)

    def test_lock_excludes_other_operations(self):
        with catalog_lock(self.root):
            with self.assertRaises(CatalogConflict):
                execute(self.request("load"))

    def test_cli_returns_recovery_error_code(self):
        self.interrupted_save()
        result = subprocess.run(
            [sys.executable, "-B", str(Path(__file__).with_name("catalog_cli.py"))],
            input=json.dumps(self.request("load")), text=True, capture_output=True, check=False,
        )
        self.assertEqual(result.returncode, 1)
        self.assertEqual(json.loads(result.stdout)["error_code"], "recovery_required")
        self.assertEqual(result.stderr, "")


if __name__ == "__main__":
    unittest.main()
