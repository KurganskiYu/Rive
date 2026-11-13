"""Shared, side-effect-free interpretation of the catalog's CSV grammar."""

import csv
import os
import re
from collections.abc import Callable

from _navigation import sanitize_for_filename

DEFAULT_STATE_MACHINE = "State Machine 1"
DEFAULT_ARTBOARD = "main"
LAYOUT_KEYWORD = "layout"
LAYOUT_PLACEHOLDER_PX = 300
SCALAR_KEYS = {"sm": "state_machine", "artboard": "artboard", "trigger": "trigger"}
INPUT_TYPE_PREFIXES = {"num", "bol", "v_num", "v_bol", "txt", "col", "img", "list", "enum", "font"}


def parse_size_spec(size_str):
    """Parse fixed/layout dimensions, retaining the generator's invalid-size behavior."""
    spec = {"width": 0, "height": 0, "auto_w": False, "auto_h": False}
    if not size_str:
        return spec
    parts = size_str.lower().split("x")
    if len(parts) != 2:
        return spec
    values = []
    for part in parts:
        part = part.strip()
        if part == LAYOUT_KEYWORD:
            values.append(None)
            continue
        try:
            values.append(int(part))
        except ValueError:
            return spec
    spec["auto_w"] = values[0] is None
    spec["auto_h"] = values[1] is None
    spec["width"] = LAYOUT_PLACEHOLDER_PX if spec["auto_w"] else values[0]
    spec["height"] = LAYOUT_PLACEHOLDER_PX if spec["auto_h"] else values[1]
    return spec


def strip_quotes(value):
    value = value.strip()
    if len(value) >= 2 and value[0] == '"' and value[-1] == '"':
        return value[1:-1]
    return value


def parse_csv_row(values: list[str], warn: Callable[[str], None] = print):
    source = values[0].strip() if len(values) > 0 else ""
    row = {
        "src": source[1:] if source.startswith("-") else source,
        "hidden": source.startswith("-"),
        "size": values[1].strip() if len(values) > 1 else "",
        "preview": values[2].strip() if len(values) > 2 else "",
        "inputs": [],
        "notes": [],
    }
    if row["src"].lower().endswith(".riv"):
        row["src"] = row["src"][:-4]
    for raw_token in values[3:]:
        token = raw_token.strip()
        if not token:
            continue
        key, sep, rest = token.partition(":")
        if not sep:
            warn(f"Warning: ignoring malformed token '{token}' for {row['src']}")
        elif key == "note":
            note = strip_quotes(rest)
            if note:
                row["notes"].append(note)
        elif key in SCALAR_KEYS:
            value = strip_quotes(rest)
            if key == "artboard" and value == "-":
                value = ""
            row[SCALAR_KEYS[key]] = value
        elif key in INPUT_TYPE_PREFIXES:
            row["inputs"].append(token)
        else:
            warn(f"Warning: unknown key '{key}' in token '{token}' for {row['src']}")
    return row


def load_csv_rows(csv_file_path):
    """Load one physical CSV line per entry; retain existing CLI warning messages."""
    with open(csv_file_path, newline="", encoding="utf-8") as csvfile:
        lines = csvfile.read().splitlines()
    return [
        parse_csv_row(next(csv.reader([line])))
        for line in lines[1:]
        if line.strip()
    ]


def assign_page_stems(rows):
    src_counts = {}
    for row in rows:
        src_counts[row["src"]] = src_counts.get(row["src"], 0) + 1
    seen_stems = set()
    for row in rows:
        stem = row["src"]
        if src_counts[row["src"]] > 1:
            suffix = sanitize_for_filename(row.get("artboard") or row.get("trigger") or "default")
            base_stem = f'{row["src"]}--{suffix}'
            stem = base_stem
            n = 2
            while stem in seen_stems:
                stem = f"{base_stem}-{n}"
                n += 1
        row["page_stem"] = stem
        seen_stems.add(stem)


def parse_input_type_name(input_value):
    if not input_value:
        return None, None
    input_value = input_value.strip()
    if ":" in input_value:
        t, n = input_value.split(":", 1)
        return t.strip(), n.strip()
    return "num", input_value.strip()


def parse_input_spec(input_value):
    t, name = parse_input_type_name(input_value)
    default = None
    if name and name.endswith(")") and "(" in name:
        match = re.match(r"^(.*)\(([^()]*)\)\s*$", name)
        if match:
            name = match.group(1).strip()
            default = match.group(2).strip()
            if t != "enum" and len(default) >= 2 and (
                (default.startswith('"') and default.endswith('"'))
                or (default.startswith("'") and default.endswith("'"))
            ):
                default = default[1:-1]
    return t, name, default


def parse_font_spec(input_value):
    _t, name, default = parse_input_spec(input_value)
    name = strip_quotes(name or "")
    if default:
        return os.path.splitext(name)[0], default
    return os.path.splitext(name)[0], name


def parse_enum_spec(value):
    value = value or ""
    default_part, sep, options_part = value.partition(":")
    if not sep:
        default_part, options_part = "", value
    options = [strip_quotes(o) for o in options_part.split("|") if o.strip()]
    default = strip_quotes(default_part)
    if default and default not in options:
        options.insert(0, default)
    if not default and options:
        default = options[0]
    return default, options


def parse_number_range(value):
    if not value:
        return None
    match = re.fullmatch(
        r"\s*(-?(?:\d+(?:\.\d*)?|\.\d+))\s*:\s*(-?(?:\d+(?:\.\d*)?|\.\d+))"
        r"\s*-\s*(-?(?:\d+(?:\.\d*)?|\.\d+))\s*",
        value,
    )
    if not match:
        return None
    current, minimum, maximum = match.groups()
    precision = max(len(part.partition(".")[2]) if "." in part else 0 for part in match.groups())
    step = "1" if precision == 0 else f"{10 ** -precision:.{precision}f}"
    return current, minimum, maximum, step
