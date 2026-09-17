#!/usr/bin/env python3
"""Reading Godot's text resources, and finding them by name.

Shared by the checkers in this folder so that a resource is parsed the same way
everywhere, and so that moving an asset around the project does not quietly break a
tool that had its old path written into it: assets are looked up by file name (see
`find_asset`), and a reference is followed wherever it points.

Only what Godot writes to `.tres`/`.tscn` is understood: an `[ext_resource]` block,
an inline `[sub_resource]`, the `[resource]` block itself, `Color(...)`,
`Vector2(...)`, `Array[T]([...])`, `&"name"`, numbers and booleans. Anything else is
returned as the text Godot wrote, which is enough for a checker that compares a
handful of fields.
"""
from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


class Res:
    """One resource: its `[resource]` properties, its references and its owner."""

    def __init__(self, path: Path | None, values: dict, subs: dict, exts: dict,
                 uid: str = "", kind: str = "", inline: bool = False):
        self.path = path
        self.inline = inline
        self.values = values
        self.subs = subs
        self.exts = exts
        self.uid = uid
        self.kind = kind

    @property
    def name(self) -> str:
        """The file name, or `<inline>` for a sub-resource inside another file."""
        return self.path.name if self.path else "<inline>"

    @property
    def origin(self) -> str:
        """Where to point a reader: `res://…` for a file, and for an inline
        sub-resource the file it lives in, so the message is always openable."""
        where = ""
        if self.path:
            try:
                where = "res://" + str(self.path.relative_to(ROOT))
            except ValueError:
                where = str(self.path)
        if self.inline:
            return f"<{self.kind} inside {where or 'the resource'}>"
        return where or f"<{self.kind or 'resource'}>"

    def has(self, key: str) -> bool:
        return key in self.values

    def get(self, key: str, default=None):
        return self.values.get(key, default)

    def number(self, key: str, default: float = 0.0) -> float:
        value = self.values.get(key)
        return float(value) if value is not None else default

    def integer(self, key: str, default: int = 0) -> int:
        return int(float(self.values[key])) if key in self.values else default

    def boolean(self, key: str, default: bool = False) -> bool:
        return self.values[key] == "true" if key in self.values else default

    def text(self, key: str, default: str = "") -> str:
        """A `&"name"` or `"name"` property, unquoted."""
        value = self.values.get(key)
        if value is None:
            return default
        found = re.match(r'&?"([^"]*)"', value.strip())
        return found.group(1) if found else value

    def colour(self, key: str, default=(1.0, 1.0, 1.0)) -> tuple:
        value = self.values.get(key)
        if value is None:
            return default
        numbers = [float(part) for part in re.findall(r"-?\d+(?:\.\d+)?", value)]
        return tuple(numbers[:3]) if len(numbers) >= 3 else default

    def vector2(self, key: str, default=(0.0, 0.0)) -> tuple:
        """`Vector2(1200, 110)` as a pair of floats - the name is not a number."""
        value = self.values.get(key)
        if value is None:
            return default
        inside = re.search(r"\(([^)]*)\)", value)
        parts = inside.group(1).split(",") if inside else value.split(",")
        numbers = [float(part) for part in parts[:2] if part.strip()]
        return tuple(numbers) if len(numbers) == 2 else default

    def reference(self, key: str) -> Res | None:
        """The resource a property points at, following `ExtResource` or
        `SubResource`. `None` when the property is unset."""
        value = self.values.get(key)
        return resolve(value, self) if value else None

    def references(self, key: str) -> list:
        """The resources an array property points at, in order."""
        value = self.values.get(key)
        if not value:
            return []
        body = value.split("](", 1)[1] if "](" in value else value
        found = []
        for whole in re.finditer(r'(?:Ext|Sub)Resource\("([^"]+)"\)', body):
            reference = resolve(whole.group(0), self)
            if reference is not None:
                found.append(reference)
        return found


def read(path: Path) -> Res:
    """Parse a `.tres`/`.tscn` file into a `Res`."""
    values: dict = {}
    subs: dict = {}
    exts: dict = {}
    uid = ""
    kind = ""
    current: dict | None = None
    pending_key = ""
    pending = ""

    for raw in path.read_text().splitlines():
        line = raw.strip()
        if pending:
            # A property written over several lines ends when its brackets balance.
            pending += " " + line
            balanced = (pending.count("[") <= pending.count("]")
                        and pending.count("(") <= pending.count(")"))
            if balanced:
                current[pending_key] = pending
                pending = pending_key = ""
            continue
        if line.startswith("["):
            header = re.match(r"\[(\w+)(.*)\]$", line)
            if header is None:
                continue
            block, attributes = header.group(1), header.group(2)
            attributes = re.sub(r'\buid="([^"]*)"', lambda m: f'\nUID={m.group(1)}', attributes)
            found_uid = re.search(r"UID=([^\s\]]*)", attributes)
            if block == "ext_resource":
                # `\bid=` matters: the `id="` inside a `uid="uid://..."` matches first
                # otherwise, and every reference would resolve to a UID.
                found_id = re.search(r'\bid="([^"]+)"', line)
                found_path = re.search(r'\bpath="res://([^"]+)"', line)
                if found_id and found_path:
                    exts[found_id.group(1)] = ROOT / found_path.group(1)
                current = None
            elif block == "sub_resource":
                found_id = re.search(r'\bid="([^"]+)"', line)
                kind = (re.search(r'type="([^"]+)"', line) or [None, ""])[1]
                uid = found_uid.group(1) if found_uid else ""
                current = {}
                if found_id:
                    subs[found_id.group(1)] = {"__kind": kind, "__uid": uid, "__values": current}
                    current = current
            elif block == "resource":
                kind = (re.search(r'type="([^"]+)"', line) or [None, ""])[1]
                uid = found_uid.group(1) if found_uid else ""
                current = values
            else:
                current = None
            continue
        if current is None or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key, value = key.strip(), value.strip()
        if value.count("[") > value.count("]") or value.count("(") > value.count(")"):
            pending_key, pending = key, value
            continue
        current[key] = value

    return Res(path, values, subs, exts, uid, kind)


def resolve(value: str, owner: Res) -> Res | None:
    """The resource a `ExtResource("id")` / `SubResource("id")` expression names."""
    if not value:
        return None
    found = re.match(r'ExtResource\("([^"]+)"\)$', value.strip())
    if found:
        target = owner.exts.get(found.group(1))
        return read(target) if target else None
    found = re.match(r'SubResource\("([^"]+)"\)$', value.strip())
    if found:
        sub = owner.subs.get(found.group(1))
        if sub is None:
            return None
        return Res(owner.path, sub["__values"], owner.subs, owner.exts,
                   sub["__uid"], sub["__kind"], inline=True)
    return None


def find_asset(name: str, under: str = "worlds") -> Path:
    """Locate a resource by file name, wherever it was moved to.

    Several matches are only a problem when they are genuinely different files: the
    checkers pass the name of an asset they expect exactly one of, and Godot keeping
    a `.uid` sidecar next to it is not a second asset. The search starts in `under`
    (the folder a project usually keeps its content in) and widens to the whole repo
    so that a restructure cannot silently break a tool.
    """
    for search in (ROOT / under, ROOT):
        matches = sorted(
            path for path in search.rglob(name)
            if ".git" not in path.parts and not path.name.endswith(".import")
        )
        if len(matches) == 1:
            return matches[0]
        if len(matches) > 1:
            listed = "\n".join(f"  - {path.relative_to(ROOT)}" for path in matches)
            raise SystemExit(f"{name}: {len(matches)} files have this name:\n{listed}")
    raise SystemExit(f"{name}: no such resource under {ROOT}")
