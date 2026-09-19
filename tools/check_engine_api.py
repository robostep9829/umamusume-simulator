#!/usr/bin/env python3
"""Checks every engine call in the project's GDScript against the engine itself.

Godot fails on an unknown method only when the line runs, which for a debug view or an
error path can be hours in - and a typo in a rarely taken branch never fails at all.
This reads the project's `.gd` files and asks a much simpler question than a compiler
would: **does any engine class have a method by this name?** A call that matches
nothing in 810 classes and 129 global functions is a typo, a renamed API, or a
function that was never written.

It cannot tell you whether the method exists on the *right* class (`Array.size()` on a
`String` looks fine to it), so it is a spelling check, not a type check - but it is the
one that catches `tween.get_total_duration()`, which no engine version has ever had.

Names the project defines itself are fine, of course: `func` declarations, `signal`
names, `class_name`s, and the names the code itself promises exist -
`has_method("x")` and `"x" in node` are duck typing, and are taken at their word.
Anything else can be listed in `tools/engine_api_allow.txt` (one name per line), for
a call resolved through `call()` or a method an addon provides.

    python3 tools/check_engine_api.py [paths …]   # exit 0 = every call exists
"""
import json
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
INDEX = HERE / "godot_class_index.json"
ALLOW_FILE = HERE / "engine_api_allow.txt"

# Language constructs that look like calls: `Node.new()`, `preload()`, `load()` and
# the `assert`/`range` family, which the GDScript parser handles itself.
LANGUAGE = {
    "new", "preload", "load", "assert", "range", "not", "in", "is", "as", "await",
    "self", "super", "true", "false", "null", "typeof", "yield", "call", "callv",
}

# Built-in types, which are constructors rather than methods and have no class entry
# for the scalar ones (`float(3)`, `int(x)`, `String(y)`).
# Keywords that can sit in front of a parenthesised expression without calling
# anything: `return (a - b)`, `x if (y) else z`.
KEYWORDS = {
    "if", "elif", "else", "for", "while", "match", "when", "return", "break",
    "continue", "pass", "func", "static", "var", "const", "enum", "class", "extends",
    "signal", "export", "onready", "set", "get", "and", "or", "not", "in", "is", "as",
    "await", "void", "yield", "super", "self", "true", "false", "null",
}

VARIANT_TYPES = {
    "bool", "int", "float", "Variant", "String", "StringName", "NodePath", "RID",
    "Vector2", "Vector2i", "Rect2", "Rect2i", "Vector3", "Vector3i", "Vector4",
    "Vector4i", "Transform2D", "Transform3D", "Basis", "Quaternion", "Plane", "AABB",
    "Color", "Callable", "Signal", "Dictionary", "Array", "PackedByteArray",
    "PackedInt32Array", "PackedInt64Array", "PackedFloat32Array", "PackedFloat64Array",
    "PackedStringArray", "PackedVector2Array", "PackedVector3Array", "PackedVector4Array",
    "PackedColorArray",
}

# Every name followed by `(`, which is a call, a constructor or a declaration. What
# is *not* one of those (`if (`, `return (`) and what is a constructor rather than a
# method is filtered below. Matching the dot before a call is what the first version
# of this got wrong: `tween.get_total_duration(` was invisible to it.
CALL = re.compile(r"\b([A-Za-z_]\w*)\s*\(")
# `has_method("get_player_data")` and `"player_data" in root` are how GDScript says
# "this call is duck-typed": the name is expected to exist at runtime, so it is
# accepted. Names inside the quotes are what the project promises about itself.
DUCK_TYPED = re.compile(r"has_method\(\s*\"([A-Za-z_]\w*)\"|\"([A-Za-z_]\w*)\"\s+in\s")
DECLARATION = re.compile(r"^\s*(?:static\s+)?(?:func|signal)\s+([A-Za-z_]\w*)")
CLASS_NAME = re.compile(r"^\s*class_name\s+([A-Za-z_]\w*)")
VARIABLE = re.compile(r"^\s*var\s+([A-Za-z_]\w*)")
LAMBDA_PARAM = re.compile(r"\bfunc\s*\(([^)]*)\)")


def strip_code(line: str) -> str:
    """The line without its comment and without anything inside a string literal.

    Both matter for a name check: a doc comment or a message is not code, and
    `"a fade of 2 s (got %s)"` would otherwise look like a call to `s()`.
    """
    out = []
    quote = ""
    index = 0
    while index < len(line):
        character = line[index]
        if quote:
            if character == "\\" and index + 1 < len(line):
                index += 2
                continue
            if character == quote:
                quote = ""
            else:
                out.append(" ")
        elif character in "\"'":
            quote = character
            out.append(" ")
        elif character == "#" and not line[:index].rstrip().endswith("#"):
            break
        else:
            out.append(character)
        index += 1
    return "".join(out)


def call_sites(text: str):
    """Every `name(` in the file, with the line it is on. The `.` before a call is not
    required - `super.foo()`, `foo()` and `x.foo()` are all calls."""
    for number, line in enumerate(text.splitlines(), start=1):
        stripped = strip_code(line)
        if stripped.lstrip().startswith("@"):
            continue
        for match in CALL.finditer(stripped):
            if match.group(1) not in KEYWORDS:
                yield match.group(1), number


def project_symbols(paths) -> set:
    """Names the project declares: every `func`, `signal` and `var`, and the
    parameters of its lambdas."""
    names = set()
    for path in paths:
        for line in path.read_text(errors="ignore").splitlines():
            declared = DECLARATION.match(line) or VARIABLE.match(line) or CLASS_NAME.match(line)
            if declared:
                names.add(declared.group(1))
            for params in LAMBDA_PARAM.findall(line):
                for param in params.split(","):
                    names.add(param.strip().split(":")[0].strip())
            for found in DUCK_TYPED.findall(line):
                names.add(found[0] or found[1])
    names.discard("")
    return names


def main() -> int:
    index = json.loads(INDEX.read_text())
    # A class name is a constructor, not a method: `BiomeDirector.new()` is fine, and
    # so is `Vector3(1, 0, 0)` - `Vector3` here is the built-in type's constructor.
    engine = set(index["methods"]) | set(index["globals"]) | set(index["constants"])
    engine |= set(index["classes"]) | VARIANT_TYPES | LANGUAGE

    if len(sys.argv) > 1:
        paths = [Path(argument) for argument in sys.argv[1:]]
    else:
        paths = sorted(
            path for path in ROOT.rglob("*.gd")
            if not any(part in path.parts for part in (".git", "addons", "tools"))
        )
    if not paths:
        raise SystemExit("no .gd files were found to check")

    known = engine | project_symbols(paths)
    if ALLOW_FILE.is_file():
        known |= {
            line.strip() for line in ALLOW_FILE.read_text().splitlines()
            if line.strip() and not line.startswith("#")
        }

    unknown = []
    for path in paths:
        for name, number in call_sites(path.read_text(errors="ignore")):
            if name not in known:
                unknown.append((path, number, name))
    unknown = sorted(set(unknown), key=lambda entry: (str(entry[0]), entry[1]))

    checked = sum(1 for path in paths for _ in call_sites(path.read_text(errors="ignore")))
    if unknown:
        print(f"{len(unknown)} call(s) match nothing in the engine ({checked} checked):")
        for path, number, name in unknown:
            where = path.relative_to(ROOT) if path.is_relative_to(ROOT) else path
            print(f"  {where}:{number}: `{name}()`")
        print("\nFix the call, or add the name to tools/engine_api_allow.txt if it is "
              "provided by a plugin or resolved through call().")
        return 1
    print(f"{checked} engine calls, all of them exist ({len(paths)} files)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
