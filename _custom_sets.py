"""Read custom catalog definitions and publish their generated pages safely."""

import csv
import os
import re
from collections import defaultdict
from pathlib import Path

from _navigation import animation_id, valid_animation_id


CUSTOM_CATALOG_MARKER = "<!-- Generated custom catalog; do not edit. -->\n"
SET_NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9_-]*\Z")
RESERVED_NAMES = {"con", "prn", "aux", "nul"} | {
    f"{prefix}{number}" for prefix in ("com", "lpt") for number in range(1, 10)
}


def load_descriptions(path):
    descriptions = {}
    path = Path(path)
    for line_number, line in enumerate(path.read_text(encoding="utf-8-sig").splitlines(), 1):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        identifier, separator, description = line.partition(":")
        identifier, description = identifier.strip(), description.strip()
        if not separator or not valid_animation_id(identifier) or not description:
            raise ValueError(f"{path.name}, line {line_number}: expected ID: description")
        if identifier in descriptions:
            raise ValueError(f"{path.name}, line {line_number}: duplicate ID {identifier}")
        descriptions[identifier] = description
    return descriptions


def index_animation_ids(rows):
    by_id = defaultdict(list)
    for row in rows:
        identifier = animation_id(row["src"])
        if not identifier or not valid_animation_id(identifier):
            raise ValueError(f"Animation {row['src']!r} must start with an ID followed by an underscore")
        by_id[identifier].append(row)
    return by_id


def load_custom_catalogs(sets_path, descriptions_path, rows, navigation_entries, variants):
    descriptions = load_descriptions(descriptions_path)
    labels = dict(navigation_entries)
    by_id = index_animation_ids(rows)
    by_variant = {}
    for identifier, matching_rows in by_id.items():
        for row in matching_rows:
            variant = variants[row["page_stem"]]
            if len(matching_rows) > 1 and not variant:
                raise ValueError(f"Missing variant for animation ID {identifier}")
            if variant:
                selector = identifier + variant
                if selector in by_variant or selector in by_id:
                    raise ValueError(f"Ambiguous animation selector {selector!r}")
                by_variant[selector] = row

    unused_descriptions = descriptions.keys() - (by_id.keys() | by_variant.keys())
    if unused_descriptions:
        identifiers = ", ".join(sorted(unused_descriptions))
        print(f"Warning: descriptions have no matching animation: {identifiers}")

    catalogs = []
    seen_names = set()
    sets_path = Path(sets_path)
    with sets_path.open(newline="", encoding="utf-8-sig") as file:
        reader = csv.reader(file, strict=True)
        for values in reader:
            if not values or all(not value.strip() for value in values):
                continue
            name = values[0].strip()
            if name.startswith("#"):
                continue
            location = f"{sets_path.name}, line {reader.line_num}"
            if not SET_NAME.fullmatch(name):
                raise ValueError(f"{location}: set names must use letters, numbers, - or _")
            if name.casefold() in RESERVED_NAMES:
                raise ValueError(f"{location}: reserved set name {name!r}")
            if name.casefold() in seen_names:
                raise ValueError(f"{location}: duplicate set name {name!r}")
            seen_names.add(name.casefold())

            identifiers = []
            seen_ids = set()
            for value in values[1:]:
                value = value.strip()
                if not value:
                    continue
                if not valid_animation_id(value):
                    raise ValueError(f"{location}: invalid animation ID {value!r}")
                if value not in seen_ids:
                    identifiers.append(value)
                    seen_ids.add(value)
            missing = [
                identifier for identifier in identifiers
                if identifier not in by_id and identifier not in by_variant
            ]
            if missing:
                raise ValueError(f"{location}: no animations found for {', '.join(missing)}")

            selected = []
            seen_pages = set()
            for identifier in identifiers:
                matching_rows = by_id[identifier] if identifier in by_id else [by_variant[identifier]]
                for row in matching_rows:
                    stem = row["page_stem"]
                    if stem in seen_pages:
                        continue
                    seen_pages.add(stem)
                    base_id = animation_id(row["src"])
                    if base_id is None:
                        raise ValueError(f"Animation {row['src']!r} has no ID")
                    variant_id = base_id + variants[stem]
                    selected.append({
                        **row,
                        "_custom_label": labels[stem],
                        "_custom_description": descriptions.get(variant_id, descriptions.get(base_id, "")),
                    })
            catalogs.append((name, selected))
    return catalogs


def is_generated_page(path, marker=CUSTOM_CATALOG_MARKER):
    path = Path(path)
    if path.is_symlink() or not path.is_file():
        return False
    with path.open("rb") as file:
        return file.readline() == marker.encode("utf-8")


def validate_custom_directory(directory):
    directory = Path(directory)
    if directory.is_symlink():
        raise ValueError(f"Custom set folder {directory.name!r} cannot be a symbolic link")
    if directory.exists():
        if not directory.is_dir():
            raise ValueError(f"Custom set folder {directory.name!r} is not a directory")
        if any(directory.iterdir()) and not is_generated_page(directory / "index.html"):
            raise ValueError(f"Folder {directory.name!r} already exists and is not a generated custom catalog")


def publish_custom_catalog(staging_directory, output_directory):
    staging_directory, output_directory = Path(staging_directory), Path(output_directory)
    validate_custom_directory(output_directory)
    staged_pages = list(staging_directory.iterdir())
    for page in staged_pages:
        if page.suffix != ".html" or not is_generated_page(page):
            raise ValueError(f"Unexpected file in custom catalog staging folder: {page.name}")
        destination = output_directory / page.name
        if os.path.lexists(destination) and not is_generated_page(destination):
            raise ValueError(f"Cannot replace non-generated file {output_directory.name}/{page.name}")

    names = {page.name for page in staged_pages}
    stale_pages = []
    if output_directory.exists():
        stale_pages = [
            page for page in output_directory.iterdir()
            if page.suffix.lower() == ".html" and page.name not in names and is_generated_page(page)
        ]
    output_directory.mkdir(exist_ok=True)
    for page in sorted(staged_pages, key=lambda page: page.name == "index.html"):
        os.replace(page, output_directory / page.name)
    for page in stale_pages:
        if not is_generated_page(page):
            raise ValueError(f"Generated file changed while updating {output_directory.name}/{page.name}")
        page.unlink()
