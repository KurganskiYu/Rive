"""Read custom catalog definitions and publish their generated pages safely."""

import csv
import os
import re
from pathlib import Path


CUSTOM_CATALOG_MARKER = "<!-- Generated custom catalog; do not edit. -->\n"
SET_NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9_-]*\Z")
NUMBER = re.compile(r"[0-9]+\Z")
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
        number, separator, description = line.partition(":")
        number, description = number.strip(), description.strip()
        if not separator or not NUMBER.fullmatch(number) or not description:
            raise ValueError(f"{path.name}, line {line_number}: expected number: description")
        key = int(number)
        if key in descriptions:
            raise ValueError(f"{path.name}, line {line_number}: duplicate number {number}")
        descriptions[key] = description
    return descriptions


def load_custom_catalogs(sets_path, descriptions_path, rows, navigation_entries):
    descriptions = load_descriptions(descriptions_path)
    labels = dict(navigation_entries)
    by_number = {}
    for row in rows:
        match = re.match(r"^([0-9]+)_", row["src"])
        if match:
            by_number.setdefault(int(match.group(1)), []).append(row)

    unused_descriptions = descriptions.keys() - by_number.keys()
    if unused_descriptions:
        numbers = ", ".join(str(number) for number in sorted(unused_descriptions))
        print(f"Warning: descriptions have no matching animation: {numbers}")

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

            numbers = []
            seen_numbers = set()
            for value in values[1:]:
                value = value.strip()
                if not value:
                    continue
                if not NUMBER.fullmatch(value):
                    raise ValueError(f"{location}: invalid animation number {value!r}")
                number = int(value)
                if number not in seen_numbers:
                    numbers.append(number)
                    seen_numbers.add(number)
            missing = [number for number in numbers if number not in by_number]
            if missing:
                raise ValueError(f"{location}: no animations found for {', '.join(map(str, missing))}")

            selected = [
                {
                    **row,
                    "_custom_label": labels[row["page_stem"]],
                    "_custom_description": descriptions.get(number, ""),
                }
                for number in numbers
                for row in by_number[number]
            ]
            catalogs.append((name, selected))
    return catalogs


def is_generated_page(path):
    path = Path(path)
    if path.is_symlink() or not path.is_file():
        return False
    with path.open("rb") as file:
        return file.readline() == CUSTOM_CATALOG_MARKER.encode("utf-8")


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
