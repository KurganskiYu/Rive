import csv
import os
import re
import tempfile
from collections import defaultdict
from html import escape
from pathlib import Path
from urllib.parse import quote


def name_key(filename):
    base, separator, suffix = filename.strip().partition("--")
    if base.lower().endswith(".riv"):
        base = base[:-4]
    base = re.sub(r"_v\d+[a-zA-Z0-9]*$", "", base, flags=re.IGNORECASE)
    return base + (separator + suffix if separator else "")


def sanitize_for_filename(value):
    value = (value or "").strip()
    value = re.sub(r"[^A-Za-z0-9_-]+", "_", value)
    return value.strip("_") or "artboard"


def load_navigation_entries(rows, names_path):
    """Synchronize names in catalog order and return entries in navigation order.

    Keys omit the version and include the page's artboard suffix for shared files.
    New names are blank, and unused names are retained to avoid losing edits.
    Legacy repeated filenames are migrated in their original catalog order.
    """
    names_path = Path(names_path)
    existing = []
    if names_path.exists():
        with names_path.open(newline="", encoding="utf-8-sig") as names_file:
            reader = csv.DictReader(names_file)
            if reader.fieldnames != ["filename", "name"]:
                raise ValueError(f"{names_path} must have filename and name columns")
            for name_row in reader:
                if None in name_row or not (name_row["filename"] or "").strip():
                    raise ValueError(f"{names_path} contains an invalid name row")
                existing.append((name_row["filename"].strip(), name_row["name"] or ""))

    groups = defaultdict(list)
    for filename, name in existing:
        groups[name_key(filename)].append(name)

    catalog = []
    active_keys = set()
    for row in reversed(rows):
        src = row["src"]
        stem = row["page_stem"]
        suffix = stem[len(src):] if stem.startswith(src + "--") else ""
        base = name_key(src)
        if not suffix and base not in groups:
            artboard = sanitize_for_filename(row.get("artboard") or row.get("trigger") or "default")
            if f"{base}--{artboard}" in groups:
                suffix = f"--{artboard}"
        key = base + suffix
        if key in active_keys:
            raise ValueError(f"Ambiguous catalog name key {key!r}; use distinct artboards")
        active_keys.add(key)
        catalog.append((row, key))

    names = {}
    for _, key in catalog:
        if key in groups and len(groups[key]) == 1:
            names[key] = groups.pop(key)[0]

    # Older files used repeated source names in catalog order for artboards.
    for key in list(groups):
        candidates = [
            target for _, target in catalog
            if target not in names and target.partition("--")[0] == key
        ]
        if candidates and len(groups[key]) == len(candidates):
            names.update(zip(candidates, groups.pop(key)))
        elif len(groups[key]) > 1 and candidates:
            raise ValueError(f"{names_path} has ambiguous legacy names for {key}")

    updated = [(key, names.get(key, "")) for _, key in catalog]
    for key, values in groups.items():
        updated.extend((key, value) for value in values)

    if updated != existing or not names_path.exists():
        temp_path = None
        try:
            with tempfile.NamedTemporaryFile(
                mode="w", newline="", encoding="utf-8", dir=names_path.parent, delete=False
            ) as names_file:
                temp_path = Path(names_file.name)
                writer = csv.writer(names_file)
                writer.writerow(["filename", "name"])
                writer.writerows(updated)
            if names_path.exists():
                os.chmod(temp_path, names_path.stat().st_mode)
            os.replace(temp_path, names_path)
        finally:
            if temp_path is not None and temp_path.exists():
                temp_path.unlink()

    entries = []
    for row, key in reversed(catalog):
        base = name_key(row["src"])
        number = re.match(r"^(\d+)_", base)
        fallback = base[number.end():] if number else base
        name = names.get(key, "").strip() or fallback.replace("_", " ")
        label = f"{number.group(1)} {name}" if number else name
        entries.append((row["page_stem"], label))
    return entries


def render_navigation(entries, is_root):
    prefix = "pages/" if is_root else ""
    links = "\n".join(
        f'          <li><a href="{prefix}{quote(stem, safe="")}.html">{escape(label)}</a></li>'
        for stem, label in entries
    )
    return f'''
    <nav class="animation-nav" aria-label="Animation pages">
      <details open>
        <summary>Animations</summary>
        <ul>
{links}
        </ul>
      </details>
    </nav>
'''
