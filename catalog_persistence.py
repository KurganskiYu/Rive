"""Revision checks and recoverable, serialized writes for catalog tables."""

import fcntl
import hashlib
import json
import os
import stat
import uuid
from contextlib import contextmanager

TABLES = ("_videos.csv", "_videos_names.csv", "_catalog.json")
JOURNAL = ".catalog-save.json"


class CatalogConflict(ValueError):
    pass


class RecoveryRequired(ValueError):
    pass


def read_tables(root):
    tables = {}
    for name in TABLES:
        path = root / name
        if path.is_symlink():
            raise ValueError(f"{name} must not be a symbolic link.")
        tables[name] = path.read_bytes() if path.exists() else None
    return tables


def digest(contents):
    return hashlib.sha256(contents).hexdigest() if contents is not None else None


def revision(tables):
    return digest(json.dumps(
        {name: digest(tables[name]) for name in TABLES}, sort_keys=True
    ).encode("utf-8"))


@contextmanager
def catalog_lock(root):
    descriptor = os.open(root / ".catalog-save.lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise CatalogConflict("Another catalog operation is in progress. Try again.") from error
        yield
    finally:
        os.close(descriptor)


def require_recovered(root):
    if (root / JOURNAL).exists():
        raise RecoveryRequired(
            "An interrupted catalog save needs recovery. Restore the pre-save files before editing."
        )


def _sync_directory(path):
    descriptor = os.open(path, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _write(path, contents, mode=0o600):
    with path.open("xb") as file:
        file.write(contents)
        file.flush()
        os.fchmod(file.fileno(), mode)
        os.fsync(file.fileno())


def save_tables(root, before, after):
    """Caller holds catalog_lock; keep before-images until explicitly cleaned by the user."""
    require_recovered(root)
    if read_tables(root) != before:
        raise CatalogConflict("Catalog files changed outside the app. Reload before saving.")
    changed = [name for name in TABLES if before[name] != after[name]]
    if not changed:
        return
    if any(after[name] is None for name in changed):
        raise ValueError("Deleting catalog tables is not supported.")
    history = root / ".catalog-backups"
    if history.is_symlink():
        raise ValueError("The catalog backup directory must not be a symbolic link.")
    history.mkdir(exist_ok=True, mode=0o700)
    backup = history / uuid.uuid4().hex
    backup.mkdir(mode=0o700)
    files = []
    for index, name in enumerate(changed):
        path = root / name
        mode = stat.S_IMODE(path.stat().st_mode) if before[name] is not None else 0o644
        if before[name] is not None:
            _write(backup / f"before-{index}", before[name])
        _write(backup / f"after-{index}", after[name], mode)
        files.append({
            "name": name, "before": digest(before[name]), "after": digest(after[name]), "mode": mode,
        })
    manifest = json.dumps({"version": 1, "backup": backup.name, "files": files}).encode("utf-8")
    _write(backup / "journal.json", manifest)
    _sync_directory(backup)
    _sync_directory(history)
    # Publishing the durable journal is the boundary before the first table replacement.
    journal_stage = backup / "active.json"
    _write(journal_stage, manifest)
    os.replace(journal_stage, root / JOURNAL)
    _sync_directory(root)
    for index, item in enumerate(files):
        if read_tables(root)[item["name"]] != before[item["name"]]:
            raise CatalogConflict("A catalog file changed during save. Recovery is required.")
        os.replace(backup / f"after-{index}", root / item["name"])
        _sync_directory(root)
    if read_tables(root) != after:
        raise CatalogConflict("Catalog files changed during save. Recovery is required.")
    (root / JOURNAL).unlink()
    _sync_directory(root)


def recover_tables(root):
    """Roll back only files still matching this interrupted transaction's before/after images."""
    journal = root / JOURNAL
    if not journal.exists():
        raise ValueError("There is no interrupted save to recover.")
    manifest = json.loads(journal.read_bytes())
    if (not isinstance(manifest, dict) or manifest.get("version") != 1
            or not isinstance(manifest.get("backup"), str)
            or len(manifest["backup"]) != 32
            or any(char not in "0123456789abcdef" for char in manifest["backup"])):
        raise ValueError("Invalid catalog recovery journal. Keep the journal and backups for review.")
    backup = root / ".catalog-backups" / manifest["backup"]
    if backup.is_symlink() or backup.parent.is_symlink():
        raise ValueError("Recovery backups must not be symbolic links.")
    if (backup / "journal.json").read_bytes() != journal.read_bytes():
        raise ValueError("Recovery journal does not match its backup.")
    files = manifest.get("files")
    if (not isinstance(files, list) or not files or len(files) > len(TABLES)
            or any(not isinstance(item, dict) or item.get("name") not in TABLES for item in files)
            or len({item["name"] for item in files}) != len(files)):
        raise ValueError("Invalid recovery file list.")
    current = read_tables(root)
    originals = []
    for index, item in enumerate(files):
        if (not isinstance(item.get("mode"), int) or not 0 <= item["mode"] <= 0o7777
                or not isinstance(item.get("after"), str) or "before" not in item):
            raise ValueError("Invalid recovery file record.")
        if digest(current[item["name"]]) not in (item["before"], item["after"]):
            raise CatalogConflict(
                f"{item['name']} changed after the interrupted save. Recovery will not overwrite it."
            )
        original = None if item["before"] is None else (backup / f"before-{index}").read_bytes()
        if digest(original) != item["before"]:
            raise ValueError(f"Recovery backup for {item['name']} is damaged.")
        originals.append(original)
    for index, (item, original) in enumerate(zip(files, originals)):
        path = root / item["name"]
        if read_tables(root)[item["name"]] != current[item["name"]]:
            raise CatalogConflict(f"{item['name']} changed during recovery. Try recovery again.")
        if original is None:
            if path.exists():
                path.unlink()
        else:
            stage = backup / f"restore-{index}-{uuid.uuid4().hex}"
            _write(stage, original, item["mode"])
            os.replace(stage, path)
        _sync_directory(root)
    journal.unlink()
    _sync_directory(root)
