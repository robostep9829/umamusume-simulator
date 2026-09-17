#!/usr/bin/env python3
"""Builds `godot_class_index.json`, the class knowledge `check_res.py` runs on.

Godot's own class reference is the only trustworthy description of what a `.tres`
may contain, and it ships with the engine sources rather than the editor. Point
this at either an extracted Godot source tree or the source tarball:

    python3 tools/build_godot_index.py                       # looks for one, or downloads
    python3 tools/build_godot_index.py --source /tmp/godot-4.7.2-stable
    python3 tools/build_godot_index.py --tarball /tmp/godot-src.tar.gz

The index is committed, so this only has to run when the engine version changes.
"""
import argparse
import json
import pathlib
import re
import subprocess
import sys
import tarfile
import tempfile
import xml.etree.ElementTree as ET

HERE = pathlib.Path(__file__).resolve().parent
OUTPUT = HERE / "godot_class_index.json"
DEFAULT_TAG = "4.7.2-stable"
ARCHIVE_URL = "https://codeload.github.com/godotengine/godot/tar.gz/refs/tags/{tag}"


def find_source(root: pathlib.Path) -> pathlib.Path:
    candidates = [root]
    if root.is_dir():
        candidates += sorted(root.iterdir())
    for candidate in candidates:
        if (candidate / "doc/classes").is_dir():
            return candidate
    return pathlib.Path()


def extract(tarball: pathlib.Path, target: pathlib.Path) -> pathlib.Path:
    with tarfile.open(tarball) as archive:
        wanted = [member for member in archive.getmembers()
                  if "/doc/classes/" in member.name and member.name.endswith(".xml")
                  or re.search(r"/(scene|core)/.*\.cpp$", member.name)]
        archive.extractall(target, members=wanted)
    return find_source(target)


def download(tag: str, target: pathlib.Path) -> pathlib.Path:
    tarball = target / "godot-src.tar.gz"
    url = ARCHIVE_URL.format(tag=tag)
    print("downloading", url)
    subprocess.run(["curl", "-sL", "--max-time", "900", "-o", str(tarball), url], check=True)
    return extract(tarball, target)


def build(source: pathlib.Path) -> dict:
    classes = {}
    for xml in sorted((source / "doc/classes").glob("*.xml")):
        try:
            node = ET.parse(xml).getroot()
        except ET.ParseError:
            continue
        classes[node.get("name")] = {
            "inherits": node.get("inherits") or "",
            "members": sorted({m.get("name") for m in node.findall(".//member")}),
        }

    # Property names the engine registers in C++ without a class-reference entry
    # (serialised internals such as `surface_material_override/0`, `data`...).
    cpp = set()
    for folder in ("scene", "core"):
        for path in (source / folder).rglob("*.cpp"):
            text = path.read_text(errors="ignore")
            cpp |= set(re.findall(r'ADD_PROPERTYI?\(PropertyInfo\([^,]+,\s*"([^"]+)"', text))
    cpp |= {"script", "metadata", "unique_id", "node_paths", "instance", "index",
            "connection", "name", "type", "id", "groups", "owner", "process_mode"}
    return {"classes": classes, "cpp_properties": sorted(cpp)}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", help="extracted Godot source tree")
    parser.add_argument("--tarball", help="Godot source tarball to extract first")
    parser.add_argument("--tag", default=DEFAULT_TAG, help="tag to download (default %(default)s)")
    parser.add_argument("--out", default=str(OUTPUT))
    arguments = parser.parse_args()

    with tempfile.TemporaryDirectory() as scratch:
        target = pathlib.Path(scratch)
        source = pathlib.Path(arguments.source) if arguments.source else pathlib.Path()
        if arguments.tarball:
            source = extract(pathlib.Path(arguments.tarball), target)
        if not source or not (source / "doc/classes").is_dir():
            source = download(arguments.tag, target)
        index = build(source)

    pathlib.Path(arguments.out).write_text(json.dumps(index))
    size = pathlib.Path(arguments.out).stat().st_size // 1024
    print(f"{len(index['classes'])} classes, {len(index['cpp_properties'])} C++ property names"
          f" -> {arguments.out} ({size} KiB)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
