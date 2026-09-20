#!/usr/bin/env python3
"""Checks the *scope* of the project's GDScript, which gdparse and gdlint cannot see.

Godot reports these only when it loads the script, and the error points at the symptom
rather than the cause:

    SCRIPT ERROR: Parse Error: Identifier "segment" not declared in the current scope.
              at: GDScript::reload (res://scripts/biomes/tests/biome_selftest.gd:110)
    Parse Error: The variable type is being inferred from a Variant value.

That was a block of test code whose indentation had slipped one tab outwards, leaving
behind the `for segment` loop that declared `segment`. Every line of the file was valid
on its own, so `gdparse` and `gdlint` both passed - only scope analysis notices, and
only running the engine does it. This does that analysis by reading the file:

* a name declared as a local somewhere in the file, used where that declaration is not
  in scope: Godot's "not declared in the current scope";
* a `:=` value that is arithmetic over the loop variable of an untyped `for … in […]`,
  or an element read out of an untyped `Array`/`Dictionary`, which have no inferable
  type: Godot's "inferred from a Variant value";

* a line indented deeper than any open block, and a statement at file scope - the two
  shapes a lost or added tab leaves behind;
* a bare `return` in a function declared to return a builtin type, which the engine
  refuses at load the same way it refuses a `:=` it cannot infer;
* an integer literal too large for a signed 64-bit integer, which the engine prints as
  "Cannot represent 0x…" and then substitutes INT64_MAX for;
* a scene-tree script that adds nodes without a `_process`/`_physics_process` entry
  point: the root is not inside the tree while `_initialize()` runs, so the nodes it
  adds never get their `_ready()` (see the self-test's own note).

It is not a compiler: blocks come from indentation, scopes from `var`/`const`/`for`/
parameter declarations, and members from the engine index (`godot_class_index.json`).
Anything needing more than that - a binding made inside a lambda, a statement split
across brackets, a `match` pattern - is left alone rather than guessed at.

    python3 tools/check_gdscript_scope.py [files …]   # exit 0 = nothing out of scope
"""
import json
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
sys.path.insert(0, str(HERE))
from check_engine_api import KEYWORDS, VARIANT_TYPES, strip_code  # noqa: E402

INDEX = HERE / "godot_class_index.json"

DECLARE = re.compile(r"^\s*(?:static\s+)?(?:var|const)\s+([A-Za-z_]\w*)")
FOR_LOOP = re.compile(r"^\s*for\s+([A-Za-z_]\w*)\s*(?::[^:=]+)?\s+in\s+(.+?)\s*:\s*$")
FOR_ARRAY = re.compile(r"^\s*for\s+[A-Za-z_]\w*\s*(?::[^:=]+)?\s+in\s*[\[{]")
FUNC = re.compile(r"^\s*(?:static\s+)?func\s+([A-Za-z_]\w*)\s*\(([^)]*)\)")
SIGNAL = re.compile(r"^\s*signal\s+([A-Za-z_]\w*)\s*\(([^)]*)\)")
CLASS_NAME = re.compile(r"^class_name\s+([A-Za-z_]\w*)")
EXTENDS = re.compile(r"^extends\s+([A-Za-z_]\w*)")
ENUM = re.compile(r"^\s*enum\s+([A-Za-z_]\w*)")
MEMBER = re.compile(r"^\s*(?:static\s+)?(?:var|const|signal)\s+([A-Za-z_]\w*)")
IDENTIFIER = re.compile(r"(?<![\w.$%@&])([A-Za-z_]\w*)")
NUMBER = re.compile(r"\b\d[\w.]*")
OPENS = re.compile(r"^\s*(?:@\w+\s+)?(?:static\s+)?(?:func|if|elif|else|for|while|match|class)\b")
# Statements that may stand at file scope. Anything else there is a misplaced body.
TOP_LEVEL_OK = re.compile(
    r"^(@|#|class_name\b|extends\b|class\b|enum\b|const\b|var\b|static\b|signal\b|"
    r"func\b|tool\b|breakpoint\b)"
)


class Block:
    """An open block: the indent of its body, and the names that body introduces."""

    def __init__(self, indent: int):
        self.indent = indent
        self.names = set()        # locals and loop variables
        self.variants = set()     # loop variables of an untyped `for … in […]`


def extends_of(path: Path) -> str:
    for line in path.read_text(errors="ignore").splitlines()[:20]:
        found = EXTENDS.match(line.strip())
        if found:
            return found.group(1)
    return ""


def own_class(path: Path) -> str:
    found = CLASS_NAME.match(path.read_text(errors="ignore"))
    return found.group(1) if found else ""


def own_declarations(path: Path) -> set:
    """Members, constants, signals, functions and enum members: names a bare identifier
    can reach from anywhere in the class. Enum members are shouty by convention."""
    names = set()
    in_enum = False
    for line in path.read_text(errors="ignore").splitlines():
        code = strip_code(line)
        if in_enum:
            if "}" in code:
                in_enum = False
            else:
                names.update(re.findall(r"\b([A-Z][A-Z_0-9]*)\b", code))
            continue
        if line[:1].isspace() or not code.strip():
            continue
        found = ENUM.match(code)
        if found:
            names.add(found.group(1))
            in_enum = code.rstrip().endswith(("{", ":"))
            continue
        for pattern in (MEMBER, CLASS_NAME, FUNC, SIGNAL):
            found = pattern.match(code)
            if found:
                names.add(found.group(1))
    return names


def inherited_names(index: dict, class_name: str, classes: dict, seen=None) -> set:
    """Names reachable bare from a class, up its `extends` chain."""
    seen = seen or set()
    if not class_name or class_name in seen:
        return set()
    seen.add(class_name)
    engine_class = index["classes"].get(class_name)
    if engine_class is not None:
        return (set(engine_class["members"])
                | inherited_names(index, engine_class["inherits"], classes, seen))
    path = classes.get(class_name)
    if path is None:
        return set()
    return own_declarations(path) | inherited_names(index, extends_of(path), classes, seen)


def parameters(text: str) -> set:
    """Names introduced by a `(a, b: int, c := 1)` parameter list."""
    return {found.group(1) for found in
            (re.match(r"\s*(?:var\s+)?([A-Za-z_]\w*)", part) for part in text.split(","))
            if found}


def variant_arithmetic(expression: str, variants: set) -> str:
    """The untyped loop variable whose Variant type poisons a `:=` value, if any.

    `for side in [-1.0, 1.0]` makes `side` a Variant, so `var yaw := -side * PI * 0.5`
    cannot be inferred and the script does not compile. A value that merely passes the
    variable to a call (`var y := f(side)`) may still be inferred from the call, so only
    arithmetic with the variable is reported.
    """
    text = NUMBER.sub("", expression)
    for name in variants:
        if re.search(r"[-+*/%&|^]\s*[-+]?\s*\b" + name + r"\b", text) or \
           re.search(r"\b" + name + r"\b\s*[-+*/%&|^]", text):
            return name
    return ""


# A variable that holds an untyped `Array` or `Dictionary`: reading an element out of
# one gives a Variant, so `var x := it[i]` cannot be inferred. Typed containers are
# deliberately absent - `Array[int]`, `PackedInt32Array`, `Array[Node]` all have an
# element type the analyzer knows.
UNTYPED_CONTAINER = re.compile(
    r"^\s*(?:@\w+\s+)?(?:static\s+)?var\s+([A-Za-z_]\w*)\s*"
    r"(?::\s*(?:Array|Dictionary)\b(?![\w\[])|(?::?=)\s*(?:\[\s*\]|\{\s*\}))"
)
PARAMETER_CONTAINER = re.compile(
    r"([A-Za-z_]\w*)\s*:\s*(Array|Dictionary)\b(?![\w\[])"
)


TYPED_CONTAINER = re.compile(
    r"^\s*(?:@\w+\s+)?(?:static\s+)?var\s+([A-Za-z_]\w*)\s*:\s*"
    r"(?:Array\s*\[|Packed\w*Array\b)"
)


# Return types a bare `return` cannot satisfy. `Variant` accepts nil and so do object
# types (the analyzer's own check_type_compatibility() lets nil through for anything
# that is not a builtin), but every builtin value type refuses it - and that refusal is
# an analysis error, not a warning, so the whole script fails to load:
#
#     SCRIPT ERROR: Parse Error: Cannot return value of type "null" because the
#     function return type is "bool".
NULL_INTOLERANT_RETURN = set(VARIANT_TYPES) - {"Variant"}


def null_intolerant(return_type: str) -> str:
    """The builtin return type a bare `return` cannot satisfy, or "" if it can.

    An object type is left alone: nil is an object value, and the engine converts it.
    An enum is left alone too, because its name here is indistinguishable from a class
    name and guessing would be worse than missing it.
    """
    name = return_type.split("[", 1)[0].strip()
    return name if name in NULL_INTOLERANT_RETURN else ""


def untyped_parameters(signature: str) -> set:
    """Names of parameters declared as an untyped `Array` or `Dictionary`."""
    return {name for name, _ in PARAMETER_CONTAINER.findall(signature)}


def as_type_hint(name: str, local_types: dict) -> str:
    """The type this file states for `name`, when it states one.

    Only used to keep the subscript rule quiet: a value that is named as a
    `PackedInt32Array` or an `Array[int]` has an element type the analyzer knows, so
    reporting it would be a false alarm.
    """
    return local_types.get(name, "")


def subscript_base(expression: str) -> str:
    """The container `expression` reads an element out of, or "" if it is not one.

    The value has to *be* the element for the `:=` to be uninferable: `x[i]`, not
    `String(x[i])` - the call in front of it names the type, and the engine infers
    from that. `x[i] as String` is spelled out and is left alone for the same reason.
    """
    text = expression.strip()
    if re.search(r"\bas\s+[A-Za-z_]", text):
        return ""
    if not text.endswith("]"):
        return ""
    depth = 0
    for index in range(len(text) - 1, -1, -1):
        character = text[index]
        if character == "]":
            depth += 1
        elif character == "[":
            depth -= 1
            if depth == 0:
                return text[:index].strip()
    return ""


def untyped_element(expression: str, containers: set) -> str:
    """The untyped container a `:=` value reads an element out of, if any.

    `var band := BiomeProvider.Layer.keys()[layer]` is the shape: an enum is a
    Dictionary, its `keys()` is an untyped `Array`, and one element of it is a Variant,
    so the analyzer refuses the `:=` ("Cannot infer the type of \"band\" variable because
    the value doesn't have a set type"). Only containers this can *prove* are untyped
    are reported - a name declared as one, a `.keys()`/`.values()` result, an array or
    dictionary literal - and anything else is left to the engine rather than guessed at.
    """
    base = subscript_base(expression)
    if not base:
        return ""
    if base.startswith(("[", "{")):
        return base.split("]")[0].split("}")[0].strip() + ("]" if base.startswith("[") else "}")
    # `X.keys()` / `X.values()` are an untyped Array whatever `X` is - a Dictionary,
    # an enum (which is a Dictionary), or a project type reached through its class.
    if re.fullmatch(r"[A-Za-z_]\w*(?:\.[A-Za-z_]\w*)*\.(?:keys|values)\(\)", base):
        return base
    if re.fullmatch(r"[A-Za-z_]\w*", base) and base in containers:
        return base
    return ""


def statements(lines: list) -> list:
    """Fold physical lines into logical statements.

    A multi-line function signature puts its `) -> void:` on the last line, and a
    `match` pattern line opens a block without starting with a keyword, so both the
    opener test and the declaration scan need the whole statement. Continuation lines
    are folded into their first line: their indentation is free-form and their line
    numbers become the statement's.
    """
    folded = []
    depth = 0
    for number, line in enumerate(lines, start=1):
        code = strip_code(line)
        if depth == 0:
            if not code.strip():
                continue
            folded.append([number, len(line) - len(line.lstrip("\t")), code.strip()])
        else:
            folded[-1][2] += " " + code.strip()
        depth = max(depth + code.count("(") + code.count("[") + code.count("{")
                    - code.count(")") - code.count("]") - code.count("}"), 0)
    return [(number, indent, " ".join(text.split())) for number, indent, text in folded]


def lifecycle_findings(path: Path) -> list:
    """A main loop that adds nodes needs a frame entry point to survive.

    `SceneTree::initialize()` calls the script's `_initialize()` and only then puts
    `root` inside the tree, so a node added from there never enters the tree and its
    `_ready()` never runs - and a Tween bound to it silently does nothing when
    stepped. This is what the biome self-test's very first run was about.
    """
    text = path.read_text(errors="ignore")
    if extends_of(path) not in ("SceneTree", "MainLoop"):
        return []
    found = []
    for number, line in enumerate(text.splitlines(), start=1):
        code = strip_code(line)
        if re.search(r"\badd_child\(", code):
            found.append(number)
    if not found:
        return []
    if re.search(r"^func (_process|_physics_process)\s*\(", text, re.M):
        return []
    return [(found[0], "extends %s and adds nodes, but has no `_process` or "
                       "`_physics_process` entry point: while `_initialize()` runs the root "
                       "is not inside the tree yet, so the nodes added here never get their "
                       "`_ready()` - run the work a frame later" % extends_of(path))]


def check_file(path: Path, index: dict, classes: dict, known: set) -> list:
    findings = list(lifecycle_findings(path))

    def report(number: int, message: str) -> None:
        findings.append((number, message))

    file_known = set(known) | own_declarations(path)
    file_known |= inherited_names(index, extends_of(path), classes)

    return_type = ""         # the declared return type of the function being walked
    declared_at = {}         # name -> line of its local declaration, anywhere in the file
    untyped_at = {}          # loop variable -> line of the `for … in […]` that made it one
    untyped_containers = set()   # names holding an untyped Array/Dictionary
    stack = [Block(0)]
    pending = set()          # names the opener above introduces: loop variable, parameters
    pending_variants = set()  # the subset of those a `for … in […]` left untyped
    opens = False            # the statement above opened a block and expects a body
    opener_indent = 0

    source_lines = path.read_text(errors="ignore").splitlines()
    for number, indent, code in statements(source_lines):
        while len(stack) > 1 and stack[-1].indent > indent:
            stack.pop()

        if opens:
            if indent > opener_indent:
                stack.append(Block(indent))
                for name in pending:
                    stack[-1].names.add(name)
                    if name in pending_variants:
                        stack[-1].variants.add(name)
                pending, pending_variants = set(), set()
            opens = False
        elif stack[-1].indent < indent:
            report(number, f"indented {indent} tab(s) past the block at {stack[-1].indent}: "
                           f"a lost or added tab?")
            stack.append(Block(indent))
        if indent == 0 and not TOP_LEVEL_OK.match(code):
            report(number, "statement at file scope: only declarations can live here")

        # --- what this statement declares ------------------------------------------
        declared = DECLARE.match(code)
        if declared:
            stack[-1].names.add(declared.group(1))
            if indent > 0:
                declared_at[declared.group(1)] = number
        container = UNTYPED_CONTAINER.match(code)
        if container:
            untyped_containers.add(container.group(1))
        container = TYPED_CONTAINER.match(code)
        if container:
            untyped_containers.discard(container.group(1))
        loop = FOR_LOOP.match(code)
        if loop:
            pending = {loop.group(1)}
            if indent > 0:
                declared_at[loop.group(1)] = number
            typed = re.match(r"^\s*for\s+[A-Za-z_]\w*\s*:", code)
            pending_variants = {loop.group(1)} if FOR_ARRAY.match(code) and not typed else set()
            if pending_variants:
                untyped_at[loop.group(1)] = number
                # An element of a Variant is a Variant too: `var x := side[0]` is as
                # uninferable as arithmetic over `side`.
                untyped_containers |= pending_variants
        declared_return = FUNC.match(code)
        if declared_return:
            annotation = re.search(r"\)\s*->\s*([A-Za-z_][\w.]*(?:\[[^]]*\])?)", code)
            return_type = annotation.group(1) if annotation else ""
        function = FUNC.match(code) or SIGNAL.match(code)
        if function:
            pending = parameters(function.group(2)) | {function.group(1)}
            pending_variants = set()
            untyped_containers |= untyped_parameters(function.group(2))

        # --- what this statement uses ----------------------------------------------
        variants = set().union(*[block.variants for block in stack]) if stack else set()
        for name in IDENTIFIER.findall(code):
            if name in KEYWORDS or name in VARIANT_TYPES or name in file_known:
                continue
            if name in pending or any(name in block.names for block in stack):
                continue
            if re.search(r"[:>\"]\s*" + name + r"\b", code):
                continue                       # a type annotation or a dictionary key
            if name.upper() == name:
                continue                       # a constant, shouting by convention
            if name in declared_at:
                report(number, f"`{name}` is out of scope here: it is declared on line "
                               f"{declared_at[name]}")

        inferred = re.match(r"^var\s+([A-Za-z_]\w*)\s*:=\s*(.+)$", code)
        if inferred:
            culprit = variant_arithmetic(inferred.group(2), variants)
            if culprit:
                report(number, f"`{inferred.group(1)}` has no inferable type: it is "
                               f"arithmetic over `{culprit}`, a loop variable of the "
                               f"untyped `for … in […]` on line {untyped_at[culprit]}")
            else:
                element = untyped_element(inferred.group(2), untyped_containers)
                if element:
                    report(number, f"`{inferred.group(1)}` has no inferable type: it is "
                                   f"an element of `{element}`, which is untyped, and "
                                   f"indexing one gives a Variant")

        # `return ""` and a bare `return` fold to the same statement, because string
        # contents are blanked before folding, so ask the physical line instead.
        physical = source_lines[number - 1] if number <= len(source_lines) else ""
        if re.fullmatch(r"\s*return\s*(?:#.*)?", physical):
            refusal = null_intolerant(return_type)
            if refusal:
                report(number, f"`return` with no value in a function declared `-> "
                               f"{return_type}`: nil converts to an object type but not "
                               f"to a builtin one, and the engine refuses the whole "
                               f"script at load - the fix is `return false`, or "
                               f"whatever the function means by stopping here")

        for literal in re.findall(r"\b0x[0-9a-fA-F]+\b", code):
            if int(literal, 16) > 2 ** 63 - 1:
                report(number, f"`{literal}` does not fit in a signed 64-bit integer: the "
                               f"engine refuses it (one error at load) and substitutes "
                               f"INT64_MAX")

        # --- leave the block open for the statement below ---------------------------
        opens = code.endswith(":")
        opener_indent = indent
    return findings


def autoloads() -> set:
    names = set()
    project = ROOT / "project.godot"
    if not project.is_file():
        return names
    in_section = False
    for line in project.read_text(errors="ignore").splitlines():
        if line.startswith("["):
            in_section = line.strip() == "[autoload]"
        elif in_section and "=" in line:
            names.add(line.split("=", 1)[0].strip())
    return names


def main() -> int:
    index = json.loads(INDEX.read_text())
    classes = {}
    files = []
    for path in sorted(ROOT.rglob("*.gd")):
        if any(part in path.parts for part in (".git", "addons")):
            continue
        files.append(path)
        named = own_class(path)
        if named:
            classes[named] = path

    if len(sys.argv) > 1:
        files = [Path(argument) for argument in sys.argv[1:]]

    known = set(index["globals"]) | set(index["constants"]) | set(classes) | autoloads()
    total = 0
    for path in files:
        for number, message in check_file(path, index, classes, known):
            total += 1
            where = path.relative_to(ROOT) if path.is_relative_to(ROOT) else path
            print(f"{where}:{number}: {message}")
    if total:
        print(f"\n{total} problem(s) in {len(files)} file(s)")
        return 1
    print(f"{len(files)} files, nothing out of scope")
    return 0


if __name__ == "__main__":
    sys.exit(main())
