import csv
import io
import os
import re
import tempfile
from collections import Counter, defaultdict
from html import escape
from pathlib import Path
from urllib.parse import quote


def name_key(filename):
    base, separator, suffix = filename.strip().partition("--")
    if base.lower().endswith(".riv"):
        base = base[:-4]
    base = re.sub(r"_v\d+[a-zA-Z0-9]*$", "", base, flags=re.IGNORECASE)
    return base + (separator + suffix if separator else "")


def animation_id(filename):
    base = filename.strip()
    if base.lower().endswith(".riv"):
        base = base[:-4]
    base = re.sub(r"_v\d+[a-zA-Z0-9]*$", "", base, flags=re.IGNORECASE)
    identifier, separator, name = base.partition("_")
    return identifier if separator and name else None


def valid_animation_id(identifier):
    return bool(identifier) and identifier[0].isalnum() and all(
        character.isalnum() or character in "-." for character in identifier
    )


def sanitize_for_filename(value):
    value = (value or "").strip()
    value = re.sub(r"[^A-Za-z0-9_-]+", "_", value)
    return value.strip("_") or "artboard"


def parse_navigation_names(contents, source="Names table"):
    existing = []
    reader = csv.DictReader(io.StringIO(contents.decode("utf-8-sig"), newline=""))
    if reader.fieldnames not in (
        ["id", "name"], ["filename", "name"], ["id", "name", "variant"],
        ["filename", "name", "variant"],
    ):
        raise ValueError(f"{source} must have filename, name and optional variant columns")
    key_field = reader.fieldnames[0]
    for name_row in reader:
        if None in name_row or not (name_row[key_field] or "").strip():
            raise ValueError(f"{source} contains an invalid name row")
        variant = (name_row.get("variant") or "").strip()
        if variant and not re.fullmatch(r"[a-z]", variant):
            raise ValueError(f"{source} contains an invalid variant {variant!r}; use a lowercase letter")
        existing.append((name_row[key_field].strip(), name_row["name"] or "", variant))
    return existing


def resolve_navigation_names(rows, existing):
    """Resolve canonical keys and legacy names without writing any files."""
    groups = defaultdict(list)
    for filename, name, variant in existing:
        groups[name_key(filename)].append((name, variant))

    id_counts = Counter(animation_id(row["src"]) for row in rows)
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
            raise ValueError(f"Names table has ambiguous legacy names for {key}")

    for row, key in catalog:
        identifier = animation_id(row["src"])
        if key not in names and identifier and id_counts[identifier] == 1:
            if identifier in groups and len(groups[identifier]) == 1:
                names[key] = groups.pop(identifier)[0]

    reserved = defaultdict(set)
    for key, values in groups.items():
        identifier = animation_id(key)
        if identifier:
            reserved[identifier].update(variant for _, variant in values if variant)
    by_id = defaultdict(list)
    for row, key in catalog:
        identifier = animation_id(row["src"])
        if identifier:
            by_id[identifier].append(key)
    for identifier, keys in by_id.items():
        used = set(reserved[identifier])
        active = set()
        for key in keys:
            variant = names.get(key, ("", ""))[1]
            if variant and variant in active:
                raise ValueError(f"Duplicate variant {variant!r} for animation ID {identifier}")
            if variant:
                active.add(variant)
                used.add(variant)
        if len(keys) > 1:
            for key in keys:
                name, variant = names.get(key, ("", ""))
                if not variant:
                    available = next((letter for letter in "abcdefghijklmnopqrstuvwxyz" if letter not in used), None)
                    if available is None:
                        raise ValueError(f"No free variant letters for animation ID {identifier}")
                    names[key] = (name, available)
                    used.add(available)

    updated = [(key, *names.get(key, ("", ""))) for _, key in catalog]
    for key, values in groups.items():
        updated.extend((key, name, variant) for name, variant in values)
    return updated, catalog


def load_navigation_entries(rows, names_path, *, synchronize=True):
    """Resolve version-independent names; optionally synchronize the names table."""
    names_path = Path(names_path)
    existing = parse_navigation_names(names_path.read_bytes(), names_path) if names_path.exists() else []
    updated, catalog = resolve_navigation_names(rows, existing)
    if synchronize and (updated != existing or not names_path.exists()):
        temp_path = None
        try:
            with tempfile.NamedTemporaryFile(
                mode="w", newline="", encoding="utf-8", dir=names_path.parent, delete=False
            ) as names_file:
                temp_path = Path(names_file.name)
                writer = csv.writer(names_file)
                writer.writerow(["filename", "name", "variant"])
                writer.writerows(updated)
            if names_path.exists():
                os.chmod(temp_path, names_path.stat().st_mode)
            os.replace(temp_path, names_path)
        finally:
            if temp_path is not None and temp_path.exists():
                temp_path.unlink()

    variants = {key: variant for key, _, variant in updated}
    return navigation_labels(catalog, updated), {
        row["page_stem"]: variants[key] for row, key in catalog
    }


def navigation_labels(catalog, updated):
    names = {key: name for key, name, _ in updated}
    entries = []
    for row, key in reversed(catalog):
        identifier = animation_id(row["src"])
        base = re.sub(r"_v\d+[a-zA-Z0-9]*$", "", row["src"], flags=re.IGNORECASE) if identifier else name_key(row["src"])
        fallback = base[len(identifier) + 1:] if identifier else base
        name = names.get(key, "").strip() or fallback.replace("_", " ")
        label = f"{identifier} {name}" if identifier else name
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
