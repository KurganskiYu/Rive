"""Versioned JSON bridge for catalog drafts and recoverable saves."""

import csv
import hashlib
import io
import json
import math
import re
import sys
from pathlib import Path

from _navigation import (
    animation_id, name_key, navigation_labels, parse_navigation_names, resolve_navigation_names,
)
from catalog_persistence import (
    CatalogConflict, JOURNAL, RecoveryRequired, catalog_lock, read_tables,
    recover_tables, require_recovered, revision, save_tables,
)
from catalog_core import (
    DEFAULT_ARTBOARD,
    DEFAULT_STATE_MACHINE,
    assign_page_stems,
    parse_csv_row,
    parse_input_spec,
    parse_font_spec,
    parse_enum_spec,
    parse_number_range,
    parse_size_spec,
)

PROTOCOL_VERSION = 1


def read_catalog(root: Path, *, tables=None) -> dict:
    tables = read_tables(root) if tables is None else tables
    contents = tables["_anim_list.csv"]
    if contents is None:
        raise ValueError("_anim_list.csv is missing.")
    lines = contents.decode("utf-8-sig").splitlines()
    if not lines or next(csv.reader([lines[0]]))[:3] != ["src", "size", "preview"]:
        raise ValueError("_anim_list.csv must start with src,size,preview")

    diagnostics = []
    records = []
    for line_number, raw_line in enumerate(lines[1:], 2):
        if not raw_line.strip():
            continue
        values = next(csv.reader([raw_line], strict=True))
        warnings = []
        row = parse_csv_row(values, warnings.append)
        diagnostics.extend(
            {"severity": "warning", "line": line_number, "field": "params", "message": warning}
            for warning in warnings
        )
        row["state_machine"] = row.get("state_machine") or DEFAULT_STATE_MACHINE
        artboard_mode = "implicit" if "artboard" not in row else (
            "named" if row["artboard"] else "default"
        )
        row.setdefault("artboard", DEFAULT_ARTBOARD)
        row.update(parse_size_spec(row["size"]))
        records.append((line_number, raw_line, values, row, artboard_mode))

    rows = [record[3] for record in reversed(records)]
    assign_page_stems(rows)
    names_contents = tables["_anim_names.csv"]
    existing = parse_navigation_names(names_contents) if names_contents is not None else []
    resolved_names, catalog = resolve_navigation_names(rows, existing)
    labels = dict(navigation_labels(catalog, resolved_names))
    keys = {row["page_stem"]: key for row, key in catalog}
    names = {key: name for key, name, _ in resolved_names}
    variants = {key: variant for key, _, variant in resolved_names}
    entries = []
    identities = set()
    for line_number, raw_line, values, row, mode in reversed(records):
        def error(field, message):
            diagnostics.append(
                {"severity": "error", "line": line_number, "field": field, "message": message}
            )

        src = row["src"]
        safe_source = bool(src) and src not in (".", "..") and not any(
            char in src for char in ("/", "\\", "\0")
        )
        if not safe_source:
            error("src", "Source must be a filename stem, not a path.")
        for field in ("size", "preview"):
            if field == "preview" and not row[field]:
                continue
            size = parse_size_spec(row[field])
            if size["width"] <= 0 or size["height"] <= 0:
                error(field, "Dimensions must be positive integers or layout.")
        identity = json.dumps(
            [name_key(src), mode, row["artboard"], row.get("trigger", "")],
            ensure_ascii=False,
        )
        entry_id = hashlib.sha256(identity.encode("utf-8")).hexdigest()
        if entry_id in identities:
            raise ValueError(f"Ambiguous logical animation/artboard entry at CSV line {line_number}.")
        identities.add(entry_id)
        riv_path = root / "riv" / f"{src}.riv"
        file_size = None
        if safe_source:
            if riv_path.is_file():
                file_size = riv_path.stat().st_size
            else:
                error("src", f"Missing animation file: {src}.riv")
        version_match = re.search(r"_v(\d+)[a-zA-Z0-9]*$", src, re.IGNORECASE)
        number_match = re.match(r"^(\d+)_", src)
        parameters = [
            {"token": token, "kind": kind, "name": name, "default": default}
            for token in row["inputs"]
            for kind, name, default in [parse_input_spec(token)]
        ]
        for parameter in parameters:
            kind, name, default = parameter["kind"], parameter["name"], parameter["default"]
            field = parameter["token"]
            if not name:
                error(field, "A parameter name is required.")
            if kind in ("num", "v_num") and default is not None:
                number_range = parse_number_range(default) if kind == "v_num" else None
                try:
                    numbers = [float(value) for value in (
                        number_range[:3] if number_range else [default]
                    )]
                except ValueError:
                    error(field, "Numeric defaults must be finite numbers or current:min-max ranges.")
                else:
                    if not all(math.isfinite(value) for value in numbers):
                        error(field, "Numeric defaults and bounds must be finite.")
                    elif number_range and not numbers[1] <= numbers[0] <= numbers[2]:
                        error(field, "A range must satisfy minimum <= current <= maximum.")
            if kind == "v_bol" and default is not None and default.strip().lower() not in (
                "true", "false", "1", "0", "yes", "no", "y", "n", "on", "off",
                "checked", "unchecked",
            ):
                error(field, "Unrecognized boolean default.")
            if kind == "enum" and not parse_enum_spec(default)[1]:
                error(field, "Enum options must be supplied.")
            asset = None
            if kind == "font":
                asset = ("fonts", parse_font_spec(field)[1])
            elif kind == "img" and default:
                asset = ("img", default)
            if asset:
                folder, filename = asset
                if not filename or Path(filename).name != filename or "\\" in filename:
                    error(field, "An asset reference must be a filename, not a path.")
                elif not (root / folder / filename).is_file():
                    error(field, f"Missing {folder} asset: {filename}")
        preview_file = root / "riv" / f"{src}_preview.riv"
        entries.append({
            "id": entry_id,
            "line": line_number,
            "raw_line": raw_line,
            "fields": values,
            "src": src,
            "animation_id": animation_id(src),
            "hidden": row["hidden"],
            "label": labels[row["page_stem"]],
            "name": names[keys[row["page_stem"]]],
            "variant": variants[keys[row["page_stem"]]],
            "name_key": keys[row["page_stem"]],
            "size": row["size"],
            "size_x": "layout" if row["auto_w"] else str(row["width"]),
            "size_y": "layout" if row["auto_h"] else str(row["height"]),
            "preview": row["preview"],
            "has_preview": bool(row["preview"]) or (safe_source and preview_file.is_file()),
            "artboard": row["artboard"],
            "artboard_mode": mode,
            "state_machine": row["state_machine"],
            "trigger": row.get("trigger"),
            "version": int(version_match.group(1)) if version_match else None,
            "number": int(number_match.group(1)) if number_match else None,
            "file_size": file_size,
            "page_stem": row["page_stem"],
            "parameters": parameters,
            "notes": row["notes"],
        })
    return {
        "entries": entries,
        "diagnostics": diagnostics,
        "revision": revision(tables),
    }


def _csv_record(fields, ending):
    output = io.StringIO(newline="")
    csv.writer(output, lineterminator="\r\n").writerow(fields)
    return output.getvalue()[:-2] + ending


def _encode_like(text, original):
    return (b"\xef\xbb\xbf" if original and original.startswith(b"\xef\xbb\xbf") else b"") + text.encode("utf-8")


def prepare_draft(root, before, request):
    if request.get("base_revision") != revision(before):
        raise CatalogConflict("Catalog CSV, names or metadata changed outside the app. Reload before saving.")
    edits = request.get("edits")
    if not isinstance(edits, list):
        raise ValueError("A draft must contain an edits array.")
    snapshot = read_catalog(root, tables=before)
    entries = {entry["id"]: entry for entry in snapshot["entries"]}
    lines = before["_anim_list.csv"].decode("utf-8-sig").splitlines(keepends=True)
    name_edits = {}
    seen = set()
    for edit in edits:
        if (not isinstance(edit, dict) or not isinstance(edit.get("id"), str)
                or set(edit) - {"id", "fields", "name"} or len(edit) == 1):
            raise ValueError("Each edit needs an id and fields or name; unknown edit properties are not supported.")
        entry_id = edit["id"]
        if entry_id not in entries or entry_id in seen:
            raise ValueError(f"Unknown or repeated draft entry: {entry_id}")
        seen.add(entry_id)
        entry = entries[entry_id]
        if "fields" in edit:
            fields = edit["fields"]
            if (not isinstance(fields, list) or len(fields) < 3
                    or any(not isinstance(value, str) or any(c in value for c in "\r\n\0")
                           for value in fields)):
                raise ValueError(f"Row {entry['line']}: fields must be single-line strings with src, size and preview.")
            if fields != entry["fields"]:
                old = lines[entry["line"] - 1]
                ending = "\r\n" if old.endswith("\r\n") else old[-1:] if old.endswith(("\n", "\r")) else ""
                lines[entry["line"] - 1] = _csv_record(fields, ending)
        if "name" in edit:
            name = edit["name"]
            if not isinstance(name, str) or any(c in name for c in "\r\n\0"):
                raise ValueError(f"Row {entry['line']}, name: a single-line string is required.")
            name_edits[entry["line"]] = name
    after = dict(before)
    after["_anim_list.csv"] = _encode_like("".join(lines), before["_anim_list.csv"])
    draft = read_catalog(root, tables=after)
    old_by_line = {entry["line"]: entry for entry in snapshot["entries"]}
    desired = {}
    for entry in draft["entries"]:
        old = old_by_line[entry["line"]]
        name = name_edits.get(entry["line"], old["name"])
        variant = old["variant"]
        if name != entry["name"] or variant != entry["variant"]:
            desired[entry["name_key"]] = (name, variant)
    if desired:
        contents = before["_anim_names.csv"]
        existing = parse_navigation_names(contents) if contents is not None else []
        # Resolve legacy repeated names once through the same algorithm as the generator.
        original_rows = []
        for entry in snapshot["entries"]:
            row = parse_csv_row(entry["fields"], lambda warning: None)
            row["artboard"] = entry["artboard"]
            row["page_stem"] = entry["page_stem"]
            original_rows.append(row)
        updated, _ = resolve_navigation_names(original_rows, existing)
        values = [
            (key, *desired.pop(key, (name, variant))) for key, name, variant in updated
        ]
        values.extend((key, name, variant) for key, (name, variant) in desired.items())
        header = next(csv.reader(io.StringIO(contents.decode("utf-8-sig"), newline=""))) if contents else []
        # Canonical, ordinary name tables can retain every untouched physical line.
        if contents is not None and existing == updated and all(
            "\n" not in name and "\r" not in name for _, name, _ in existing
        ) and (len(header) == 3 or not any(variant for _, _, variant in values)):
            name_lines = contents.decode("utf-8-sig").splitlines(keepends=True)
            positions = [index for index, line in enumerate(name_lines[1:], 1) if line.strip()]
            if len(positions) == len(existing):
                for position, old, new in zip(positions, existing, values):
                    if old != new:
                        line = name_lines[position]
                        ending = "\r\n" if line.endswith("\r\n") else line[-1:] if line.endswith(("\n", "\r")) else ""
                        name_lines[position] = _csv_record(new if len(header) == 3 else new[:2], ending)
                if len(values) > len(existing):
                    ending = "\r\n" if b"\r\n" in contents else "\n"
                    if name_lines and not name_lines[-1].endswith(("\r", "\n")):
                        name_lines[-1] += ending
                    name_lines.extend(
                        _csv_record(value if len(header) == 3 else value[:2], ending)
                        for value in values[len(existing):]
                    )
                after["_anim_names.csv"] = _encode_like("".join(name_lines), contents)
            else:
                raise ValueError("Cannot safely locate names-table rows.")
        else:
            ending = "\r\n" if contents is None or b"\r\n" in contents else "\n"
            after["_anim_names.csv"] = _encode_like(
                _csv_record(["filename", "name", "variant"], ending)
                + "".join(_csv_record(value, ending) for value in values), contents,
            )
        draft = read_catalog(root, tables=after)
    return after, draft


def execute(request):
    if (not isinstance(request, dict) or type(request.get("version")) is not int
            or request["version"] != PROTOCOL_VERSION):
        raise ValueError("Request must specify protocol version 1.")
    command = request.get("command")
    if command not in ("load", "validate", "save", "recover"):
        raise ValueError("Supported commands: load, validate, save, recover.")
    root_value = request.get("root")
    if not isinstance(root_value, str) or not root_value:
        raise ValueError("Request must specify a repository root.")
    root = Path(root_value).resolve()
    with catalog_lock(root):
        if command == "recover":
            recover_tables(root)
        require_recovered(root)
        before = read_tables(root)
        if command == "save" or (command == "validate" and "edits" in request):
            after, data = prepare_draft(root, before, request)
        else:
            after, data = before, read_catalog(root, tables=before)
        success = command in ("load", "recover") or not any(
            issue["severity"] == "error" for issue in data["diagnostics"]
        )
        if command == "save" and success:
            try:
                save_tables(root, before, after)
            except (OSError, CatalogConflict) as error:
                if (root / JOURNAL).exists():
                    raise RecoveryRequired(f"Save interrupted: {error}. Restore the pre-save files before editing.") from error
                raise
        return {
            "version": PROTOCOL_VERSION, "success": success, "data": data,
            "error": None if success else "Validation failed. Fix the located catalog diagnostics before saving.",
            "error_code": None if success else "validation",
        }


def main() -> int:
    try:
        response = execute(json.load(sys.stdin))
    except (OSError, UnicodeError, ValueError, csv.Error) as error:
        response = {
            "version": PROTOCOL_VERSION, "success": False, "data": None, "error": str(error),
            "error_code": "recovery_required" if isinstance(error, RecoveryRequired) else
                "conflict" if isinstance(error, CatalogConflict) else "error",
        }
    json.dump(response, sys.stdout, ensure_ascii=False)
    sys.stdout.write("\n")
    return 0 if response["success"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
