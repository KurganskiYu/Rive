import csv
import re
from html import escape
from urllib.parse import quote


def load_navigation_entries(rows, names_path):
    """Match reversed catalog rows to names in CSV order, including repeated filenames."""
    with open(names_path, newline="", encoding="utf-8-sig") as names_file:
        reader = csv.DictReader(names_file)
        if not reader.fieldnames or not {"filename", "name"}.issubset(reader.fieldnames):
            raise ValueError(f"{names_path} must have filename and name columns")
        names = list(reader)[::-1]

    if len(names) != len(rows):
        raise ValueError(f"{names_path} must contain one name per catalog row, in the same order")

    entries = []
    for row, name_row in zip(rows, names):
        filename = (name_row["filename"] or "").strip()
        name = (name_row["name"] or "").strip()
        if filename != row["src"] or not name:
            raise ValueError(
                f"{names_path} must match catalog row order and contain a name for {row['src']}"
            )
        number = re.match(r"^(\d+)_", filename)
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
