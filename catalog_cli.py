"""Read-only JSON bridge for the macOS catalog prototype."""

import csv
import hashlib
import json
import math
import re
import sys
from pathlib import Path

from _navigation import load_navigation_entries, name_key
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


def read_catalog(root: Path) -> dict:
    table = root / "_videos.csv"
    contents = table.read_bytes()
    lines = contents.decode("utf-8-sig").splitlines()
    if not lines or next(csv.reader([lines[0]]))[:3] != ["src", "size", "preview"]:
        raise ValueError("_videos.csv must start with src,size,preview")

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
    labels = dict(load_navigation_entries(rows, root / "_videos_names.csv", synchronize=False))
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
            "label": labels[row["page_stem"]],
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
        "revision": hashlib.sha256(contents).hexdigest(),
    }


def main() -> int:
    try:
        request = json.load(sys.stdin)
        if (not isinstance(request, dict) or type(request.get("version")) is not int
                or request["version"] != PROTOCOL_VERSION):
            raise ValueError("Request must specify protocol version 1.")
        command = request.get("command")
        if command not in ("load", "validate"):
            raise ValueError("Supported commands: load, validate. Writes are not enabled.")
        root_value = request.get("root")
        if not isinstance(root_value, str) or not root_value:
            raise ValueError("Request must specify a repository root.")
        data = read_catalog(Path(root_value).resolve())
        success = command == "load" or not any(
            issue["severity"] == "error" for issue in data["diagnostics"]
        )
        response = {"version": PROTOCOL_VERSION, "success": success, "data": data, "error": None}
    except (OSError, UnicodeError, ValueError, csv.Error) as error:
        response = {
            "version": PROTOCOL_VERSION, "success": False, "data": None, "error": str(error)
        }
    json.dump(response, sys.stdout, ensure_ascii=False)
    sys.stdout.write("\n")
    return 0 if response["success"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
