# Project a Nix MCP catalog onto mutable client config files.
#
# Owned names are replaced wholesale. Names the catalog does not mention stay
# as they are. `remove` deletes a name. The file is written only when the
# server map changes, and a parse error leaves it untouched.

from __future__ import annotations

import argparse
import json
import os
import sys
import tempfile
from collections.abc import Mapping
from pathlib import Path

import tomlkit


def plain(value):
    if isinstance(value, Mapping):
        return {str(key): plain(item) for key, item in value.items()}
    if isinstance(value, list):
        return [plain(item) for item in value]
    unwrap = getattr(value, "unwrap", None)
    if callable(unwrap):
        return plain(unwrap())
    return value


def semantic(value) -> str:
    return json.dumps(
        plain(value),
        sort_keys=True,
        ensure_ascii=False,
        separators=(",", ":"),
    )


def reconcile(have, desired, remove) -> dict:
    if not isinstance(have, dict):
        raise ValueError("MCP server map must be an object")
    owned = dict(desired)
    removed = set(remove)
    overlap = removed & owned.keys()
    if overlap:
        names = ", ".join(sorted(overlap))
        raise ValueError(f"server is both owned and removed: {names}")
    kept = {name: spec for name, spec in have.items() if name not in removed}
    return {**kept, **{name: spec for name, spec in owned.items()}}


def changed(before, after) -> bool:
    return semantic(before) != semantic(after)


def refuse_symlink(path: Path) -> None:
    if path.is_symlink():
        raise ValueError(f"refusing to edit symlink {path}")


def atomic_write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    mode = path.stat().st_mode & 0o777 if path.exists() else 0o600
    descriptor, temporary = tempfile.mkstemp(dir=path.parent, prefix=f".{path.name}.")
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            handle.write(text)
        os.chmod(temporary, mode)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def parent_of(document, pointer: list[str], create: bool):
    current = document
    for key in pointer[:-1]:
        if not isinstance(current, dict):
            raise ValueError(f"{key} is not an object")
        child = current.get(key)
        if child is None:
            if not create:
                return None
            child = {}
            current[key] = child
        if not isinstance(child, dict):
            raise ValueError(f"{key} is not an object")
        current = child
    if not isinstance(current, dict):
        raise ValueError("MCP parent is not an object")
    return current


def load_json(path: Path) -> dict:
    if not path.exists():
        return {}
    refuse_symlink(path)
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise ValueError(f"invalid JSON in {path}: {exc}") from exc
    if not isinstance(document, dict):
        raise ValueError(f"JSON root must be an object: {path}")
    return document


def render_json(document) -> str:
    return json.dumps(document, indent=2, ensure_ascii=False) + "\n"


def apply_json(path: Path, operations: list[dict], dry_run: bool) -> list[str]:
    document = load_json(path)
    notes = []
    mutated = False
    for operation in operations:
        pointer = operation["pointer"]
        parent = parent_of(document, pointer, create=False)
        key = pointer[-1]
        have = {} if parent is None else parent.get(key, {})
        if have is None:
            have = {}
        updated = reconcile(have, operation.get("servers") or {}, operation.get("remove") or [])
        label = f"{path} {'/'.join(pointer)}"
        if not changed(have, updated):
            notes.append(f"unchanged {label}")
            continue
        if parent is None:
            parent = parent_of(document, pointer, create=True)
        parent[key] = updated
        mutated = True
        notes.append(f"update {label}")
    if mutated and not dry_run:
        atomic_write(path, render_json(document))
    return notes


def load_toml(path: Path):
    if not path.exists():
        return tomlkit.document()
    refuse_symlink(path)
    try:
        return tomlkit.parse(path.read_text(encoding="utf-8"))
    except Exception as exc:
        raise ValueError(f"invalid TOML in {path}: {exc}") from exc


def toml_table(document, pointer: list[str], create: bool):
    current = document
    for key in pointer:
        child = current.get(key) if isinstance(current, Mapping) else None
        if child is None:
            if not create:
                return None
            child = tomlkit.table()
            current[key] = child
        if not isinstance(child, Mapping):
            raise ValueError(f"{key} is not a table")
        current = child
    return current


def toml_server(spec: dict):
    table = tomlkit.table()
    for key, value in spec.items():
        if isinstance(value, dict):
            nested = tomlkit.table()
            for nested_key, nested_value in value.items():
                nested[nested_key] = nested_value
            table[key] = nested
        else:
            table[key] = value
    return table


def apply_toml(path: Path, operations: list[dict], dry_run: bool) -> list[str]:
    document = load_toml(path)
    notes = []
    mutated = False
    for operation in operations:
        pointer = operation["table"]
        existing = toml_table(document, pointer, create=False)
        have = {} if existing is None else plain(existing)
        desired = operation.get("servers") or {}
        remove = operation.get("remove") or []
        updated = reconcile(have, desired, remove)
        label = f"{path} {'/'.join(pointer)}"
        if not changed(have, updated):
            notes.append(f"unchanged {label}")
            continue
        table = existing if existing is not None else toml_table(document, pointer, create=True)
        for name in remove:
            if name in table:
                del table[name]
        for name, spec in desired.items():
            if name in table:
                del table[name]
            table[name] = toml_server(spec)
        mutated = True
        notes.append(f"update {label}")
    if mutated and not dry_run:
        atomic_write(path, tomlkit.dumps(document))
    return notes


def project(plan: dict, home: Path, dry_run: bool) -> list[str]:
    notes = []
    json_groups: dict[str, list[dict]] = {}
    for operation in plan.get("json") or []:
        json_groups.setdefault(operation["path"], []).append(operation)
    for relative, operations in json_groups.items():
        notes.extend(apply_json(home / relative, operations, dry_run))
    toml_groups: dict[str, list[dict]] = {}
    for operation in plan.get("toml") or []:
        toml_groups.setdefault(operation["path"], []).append(operation)
    for relative, operations in toml_groups.items():
        notes.extend(apply_toml(home / relative, operations, dry_run))
    return notes


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("plan")
    parser.add_argument("--home", required=True)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    plan = json.loads(Path(args.plan).read_text(encoding="utf-8"))
    try:
        notes = project(plan, Path(args.home), args.dry_run)
    except ValueError as exc:
        print(f"reconcile-mcp: {exc}", file=sys.stderr)
        sys.exit(1)
    for note in notes:
        if note.startswith("update") or args.dry_run:
            print(note)


if __name__ == "__main__":
    main()
