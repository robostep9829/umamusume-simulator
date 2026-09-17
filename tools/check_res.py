#!/usr/bin/env python3
"""Validates this project's Godot text resources (.tres / .tscn) without Godot.

    python3 tools/check_res.py <file> [<file> ...]        # paths from the repo root
    python3 tools/check_res.py $(find worlds ui prefabs environment -name "*.tres" -o -name "*.tscn")

Hand-authored resources are the easiest place to make a silent mistake: a typo in
a property name, a path that moved, a `script_class` that no longer matches its
script. Godot's text loader ignores what it does not understand, so the resource
just quietly does less than intended. This checks what the format and the engine's
own class reference can tell us:

  * every `[ext_resource]` path exists and its declared `type=` is the real type of
    the file or one of its ancestors;
  * `script_class=` matches the `class_name` of the script the block actually uses;
  * every property of a block exists on the class (or the script) the block is for,
    following `extends` chains of engine classes *and* of scripts;
  * `Array[ExtResource(...)]` values match the element type the script declares;
  * `shader_parameter/*` names exist as uniforms of the referenced shader;
  * scene nodes: a `parent=` is defined before it is used, `unique_id`s are unique.

Names the reference cannot know - engine-registered properties such as
`surface_material_override/0`, nested animation keys, editor hints - are skipped
rather than guessed at, so the checker errs towards silence. Exit code 1 means at
least one problem; every problem is printed as `<file>: <problem>`.
"""
import json
import pathlib
import re
import sys

HERE = pathlib.Path(__file__).resolve().parent
REPO = HERE.parent
INDEX = json.loads((HERE / "godot_class_index.json").read_text())
CLASSES = INDEX["classes"]
CPP_PROPERTIES = set(INDEX["cpp_properties"])

ATTR_RE = re.compile(r'(\w+)=(?:"([^"]*)"|([^\s\]]+))')
ASSIGN_RE = re.compile(r'^([\w/]+)\s*=\s*(.*)$')
REF_RE = re.compile(r'(?:Ext|Sub)Resource\("([^"]+)"\)')
CLASS_NAME_RE = re.compile(r'^class_name\s+(\w+)', re.M)
EXTENDS_RE = re.compile(r'^extends\s+([\w\.]+)', re.M)
EXPORT_RE = re.compile(r'^@export[^\n]*?\bvar\s+(\w+)\s*(?::\s*([\[\]\w\.]+))?', re.M)
VAR_RE = re.compile(r'^(?:@\w+[\w()\s,]*\s+)?var\s+(\w+)\s*(?::\s*([\[\]\w\.]+))?', re.M)

EXTENSION_TYPES = {
    ".gd": ("Script",),
    ".tscn": ("PackedScene",),
    ".tres": (),  # read from the file's own header
    ".obj": ("ArrayMesh",),
    ".glb": ("PackedScene",),
    ".gltf": ("PackedScene",),
    ".png": ("Texture2D",),
    ".jpg": ("Texture2D",),
    ".hdr": ("Texture2D",),
    ".exr": ("Texture2D", "CompressedTexture3D"),
    ".gdshader": ("Shader",),
    ".gdshaderinc": ("ShaderInclude",),
    ".wav": ("AudioStream",),
    ".ogg": ("AudioStream",),
    ".mp3": ("AudioStream",),
}

EDITOR_HINTS = {"layout_mode", "anchors_preset", "anchors_layout_preset", "groups", "owner"}
# Engine-serialised internals registered through _bind_methods() without an
# ADD_PROPERTY entry, so the class reference does not list them.
ENGINE_INTERNALS = {"bonemap", "bind_count", "node_connections", "transitions"}

problems: list[str] = []
_scripts: dict[str, dict] = {}
_scene_roots: dict[str, tuple] = {}
_uniforms: dict[str, set] = {}


# --- the class reference ------------------------------------------------------

def class_chain(name: str):
    seen, current = set(), name
    while current and current not in seen:
        seen.add(current)
        yield current
        current = CLASSES.get(current, {}).get("inherits", "")


def class_members(name: str) -> set:
    found = set()
    for cls in class_chain(name):
        found |= set(CLASSES.get(cls, {}).get("members", []))
    return found


# --- scripts -----------------------------------------------------------------

def script_info(path: str) -> dict:
    """`class_name`, base and declared variables of a script."""
    if path in _scripts:
        return _scripts[path]
    file = REPO / path
    source = file.read_text(errors="ignore") if file.exists() else ""
    class_name = CLASS_NAME_RE.search(source)
    extends = EXTENDS_RE.search(source)
    variables: dict[str, str] = {}
    for match in EXPORT_RE.finditer(source):
        variables[match.group(1)] = match.group(2) or ""
    for match in VAR_RE.finditer(source):
        variables.setdefault(match.group(1), match.group(2) or "")
    info = {
        "class_name": class_name.group(1) if class_name else "",
        "extends": extends.group(1) if extends else "",
        "variables": variables,
    }
    _scripts[path] = info
    return info


def find_script_by_class(name: str) -> str:
    for path, info in list(_scripts.items()):
        if info["class_name"] == name:
            return path
    for candidate in REPO.rglob("*.gd"):
        rel = str(candidate.relative_to(REPO))
        if ".godot/" in rel or "addons/" in rel:
            continue
        if rel not in _scripts and script_info(rel)["class_name"] == name:
            return rel
    return ""


def script_variables(path: str, depth: int = 0) -> dict:
    """Properties of a script, including those it inherits from other scripts."""
    if depth > 12 or not path:
        return {}
    own = script_info(path)["variables"]
    base = script_info(path)["extends"]
    if not base or base in CLASSES:
        return dict(own)
    inherited = script_variables(find_script_by_class(base), depth + 1)
    inherited.update(own)
    return inherited


def script_engine_base(path: str, depth: int = 0) -> str:
    """The engine class a script ultimately extends, walking script `extends`."""
    if depth > 12 or not path:
        return ""
    base = script_info(path)["extends"]
    if not base:
        return ""
    if base in CLASSES:
        return base
    return script_engine_base(find_script_by_class(base), depth + 1)


# --- text format --------------------------------------------------------------

def parse_attrs(line: str) -> dict:
    return {m.group(1): (m.group(2) if m.group(3) is None else m.group(3))
            for m in ATTR_RE.finditer(line)}


def parse_blocks(text: str):
    blocks, current = [], None
    for line in text.splitlines():
        if line.startswith("["):
            kind = line[1:line.index(" ")] if " " in line else line[1:-1]
            current = (kind, parse_attrs(line), [])
            blocks.append(current)
        elif current is not None:
            current[2].append(line)
    return blocks


def file_type(path: str) -> tuple:
    """Engine class(es) a file can hold; empty when unknown."""
    suffix = pathlib.Path(path).suffix
    if suffix == ".tres":
        header = (REPO / path).read_text(errors="ignore").split("]", 1)[0]
        found = re.search(r'type="([^"]+)"', header)
        return (found.group(1) if found else "Resource",)
    return EXTENSION_TYPES.get(suffix, ())


def scene_root(path: str) -> tuple:
    """Type and script of a scene's root node: what an instanced node inherits."""
    if path in _scene_roots:
        return _scene_roots[path]
    kind, script = "", ""
    file = REPO / path
    if file.exists():
        blocks = parse_blocks(file.read_text(errors="ignore"))
        ext = {a.get("id", ""): a.get("path", "").removeprefix("res://")
               for k, a, _ in blocks if k == "ext_resource"}
        for block_kind, attrs, body in blocks:
            if block_kind != "node" or "parent=" in attrs:
                continue
            kind = attrs.get("type", "")
            for line in body:
                match = ASSIGN_RE.match(line)
                if match and match.group(1) == "script":
                    reference = REF_RE.search(match.group(2))
                    if reference:
                        script = ext.get(reference.group(1), "")
                break
            break
    _scene_roots[path] = (kind, script)
    return _scene_roots[path]


def uniform_names(path: str) -> set:
    if path in _uniforms:
        return _uniforms[path]
    body = (REPO / path).read_text(errors="ignore").split('code = "', 1)[-1]
    names = set(re.findall(r'uniform\s+[^;=\n]*?\b(\w+)\s*(?::|=|;)', body))
    _uniforms[path] = names
    return names


def check_file(target: str) -> None:
    path = target[2:] if target.startswith("./") else target
    blocks = parse_blocks((REPO / path).read_text(errors="ignore"))
    header = blocks[0][1] if blocks else {}

    ext: dict[str, tuple[str, str]] = {}
    for kind, attrs, _ in blocks:
        if kind != "ext_resource":
            continue
        referenced = attrs.get("path", "").removeprefix("res://")
        declared = attrs.get("type", "")
        ext[attrs.get("id", "")] = (declared, referenced)
        if not (REPO / referenced).exists():
            problems.append(f"{path}: {referenced} does not exist")
            continue
        candidates = file_type(referenced)
        if declared and candidates:
            if not any(declared in set(class_chain(candidate)) for candidate in candidates):
                problems.append(f"{path}: {referenced} is a {candidates[0]}, not a {declared}")

    declared_class = header.get("type", "")
    script_class = header.get("script_class", "")
    sub_types = {a.get("id", ""): a.get("type", "") for k, a, _ in blocks if k == "sub_resource"}
    nodes_seen: set[str] = set()
    unique_ids: set[str] = set()

    for kind, attrs, body in blocks:
        if kind in ("connection", "editable", "gd_scene", "gd_resource", "ext_resource"):
            continue

        # the script and the shader of this block, from `script = ` / `shader = `
        script_path = ""
        shader_path = ""
        for line in body:
            match = ASSIGN_RE.match(line)
            if not match:
                continue
            reference = REF_RE.search(match.group(2))
            if not reference:
                continue
            if match.group(1) == "script":
                script_path = ext.get(reference.group(1), ("", ""))[1]
            elif match.group(1) == "shader":
                shader_path = ext.get(reference.group(1), ("", ""))[1]

        engine = ""
        if kind == "resource":
            engine = declared_class or script_class
        elif kind == "sub_resource":
            engine = sub_types.get(attrs.get("id", ""), "")
        elif kind == "node":
            if attrs.get("instance"):
                reference = REF_RE.search(attrs.get("instance", ""))
                instanced = ext.get(reference.group(1), ("", ""))[1] if reference else ""
                engine, script_path = scene_root(instanced)
            else:
                engine = attrs.get("type", "")
            node = attrs.get("name", "")
            parent = attrs.get("parent", "")
            if parent not in ("", ".") and parent not in nodes_seen:
                problems.append(f"{path}: node {node} has undefined parent {parent}")
            nodes_seen.add(node if parent in ("", ".") else f"{parent}/{node}")
            unique = attrs.get("unique_id")
            if unique:
                if unique in unique_ids:
                    problems.append(f"{path}: duplicate unique_id {unique}")
                unique_ids.add(unique)

        allowed: set[str] = set(class_members(engine)) if engine in CLASSES else set()
        if script_path:
            allowed |= set(script_variables(script_path))
            base = script_engine_base(script_path)
            if base:
                allowed |= class_members(base)
        if kind == "resource":
            allowed |= class_members("Resource")
        if kind == "resource" and script_class and not script_path:
            declared = find_script_by_class(script_class)
            if declared:
                allowed |= set(script_variables(declared))

        multiline_tail = False
        for line in body:
            if multiline_tail:
                multiline_tail = not line.rstrip().endswith('"')
                continue
            match = ASSIGN_RE.match(line)
            if not match or line.startswith(('"', "}", "]", ")", "{")):
                continue
            key, value = match.group(1), match.group(2)
            if value.startswith('"') and not value.endswith('"'):
                multiline_tail = True

            if key == "script" or "/" in key:
                continue  # indexed/nested keys are serialisation details
            if key in EDITOR_HINTS or key in ENGINE_INTERNALS or key in CPP_PROPERTIES:
                continue
            if allowed and key not in allowed:
                problems.append(f"{path}: `{key}` is not a property of the block")

            if script_path:
                declared_type = script_variables(script_path).get(key, "")
                element = re.match(r'Array\[ExtResource\("([^"]+)"\)\]', value)
                if element and declared_type.startswith("Array[") and declared_type.endswith("]"):
                    referenced = ext.get(element.group(1), ("", ""))[1]
                    element_class = script_info(referenced)["class_name"] if referenced else ""
                    wanted = declared_type[6:-1]
                    if element_class and wanted and element_class != wanted:
                        problems.append(
                            f"{path}: `{key}` is Array[{element_class}]"
                            f" but the script declares {declared_type}"
                        )

            parameter = re.match(r"shader_parameter/(\w+)", key)
            if parameter and shader_path.endswith(".gdshader"):
                uniforms = uniform_names(shader_path)
                if uniforms and parameter.group(1) not in uniforms:
                    problems.append(
                        f"{path}: shader_parameter/{parameter.group(1)}"
                        f" is not a uniform of {shader_path}"
                    )


def main(argv: list[str]) -> int:
    targets = argv[1:]
    if not targets:
        print(__doc__)
        return 2
    checked = 0
    for target in targets:
        if (REPO / target).exists():
            check_file(target)
            checked += 1
    if problems:
        print(f"{len(problems)} problem(s):")
        for problem in problems:
            print("  -", problem)
        return 1
    print(f"checked {checked} files, no problems")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
