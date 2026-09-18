# tools

Small checkers that run **without Godot**, for the parts of this project that are
authored as text: the scrolling track's resources, the biome system's placement
maths, and the debug overlay's readout. They exist because a typo in a hand-written
`.tres`, or a sign error in a placement formula, does not crash anything - it just
quietly renders the wrong thing.

| Script | What it checks |
|---|---|
| `check_res.py` | every `.tres`/`.tscn` in the project: resource paths and types, `script_class`, property names against the engine's class reference, typed arrays, shader parameters, node parents and `unique_id`s |
| `verify_placement.py` | `BiomePlacement`'s geometry: end points, frames, handedness, arcs, lateral offsets, ring and lateral orientation |
| `verify_horizon.py` | the numbers `biomes/rural/layers/rural_far.tres` is authored with: ridge continuity, band, haze, rebuild interval |
| `verify_debug_stats.py` | the debug overlay's readout: biome runs, distance to the next biome, run progress |
| `check_engine_api.py` | every engine call in the project's GDScript, against the engine's own method list |
| `check_gdscript_scope.py` | the *scope* of the project's GDScript: a name used outside the block that declares it, a `:=` value with no inferable type, a line indented past every open block, an integer literal too large for 64 bits, a scene-tree script that adds nodes without a frame entry point |
| `verify_atmosphere.py` | that a biome change is *visible*: colours far enough apart and haze that reaches the horizon, for the fogs an environment switches on |
| `build_godot_index.py` | rebuilds `godot_class_index.json`, the class knowledge `check_res.py` runs on |
| `resfile.py` | shared helper, not a checker: parses a `.tres`/`.tscn` and finds an asset by name, so the checkers survive a restructure |

```bash
python3 tools/check_res.py $(find . -path ./.git -prune -o \( -name "*.tres" -o -name "*.tscn" \) -print)
python3 tools/verify_placement.py
python3 tools/verify_horizon.py
python3 tools/verify_debug_stats.py
python3 tools/verify_atmosphere.py
python3 tools/check_engine_api.py
python3 tools/check_gdscript_scope.py
```

All of them exit non-zero and print what is wrong, so they can be wired into a
commit hook or CI as-is.

`check_engine_api.py` is the one that catches a mistake Godot itself only reports at
runtime, and only when the line is reached: a method that exists nowhere
(`tween.get_total_duration()` - no engine version has ever had it). It is a spelling
check, not a type check: it cannot tell whether the method exists on the *right*
class. Names the project declares, and names it promises through
`has_method("x")`/`"x" in node`, are accepted; anything else can go in
`tools/engine_api_allow.txt`, one per line.

`check_gdscript_scope.py` is the same idea one level down: `gdparse` and `gdlint`
check that a script *parses* and is styled (the repo's `.gdlintrc` raises only the
file-length limit, for the biome self-test - see the file itself for why), and neither can see scope, so a block of
code that slips one tab outwards still passes both while the engine refuses to load
the file at all - `Identifier "segment" not declared in the current scope`, naming a
line whose only fault is that the loop that declared `segment` is now a tab away. The
checker reads indentation as blocks and `var`/`const`/`for`/parameters as declarations,
resolves every other name against `godot_class_index.json` plus the project's own
`class_name`s, and reports the names that fall between the two. It is deliberately
silent about what it cannot decide from one file (lambda bindings, `match` patterns,
statements split across brackets) rather than guessing. Like `check_engine_api.py`,
it was validated against the revision it exists to catch, not only against a clean
tree. It also knows one engine lifecycle rule worth knowing: a script extending
`SceneTree`/`MainLoop` that adds nodes but has no `_process`/`_physics_process` entry
point is adding them before the root is inside the tree, so their `_ready()` never
runs - which is what the biome self-test's first run was about.

`verify_horizon.py` and `verify_atmosphere.py` read the biomes' own `.tres` files
rather than mirroring their numbers, so tuning the demo content cannot leave them
judging an older version of it - and they respect the switches those files set:
`fog_enabled` is the environment asset's decision, so a fog left off is reported and
left alone rather than failed. Neither has an asset path written into it: they ask
`resfile.py` for the file by name and follow its references from there (an
`atmosphere` may be a file of its own or an inline sub-resource), which is why moving
the biome folders around the project does not silently break them.

`godot_class_index.json` is generated from the engine's own `doc/classes` XML plus the
C++ sources, so it knows what a resource may contain, which methods exist, and which
methods are bound in C++ without being documented (`set_owner()` is one). It is
committed to keep the checkers offline; regenerate it after an engine upgrade:

```bash
python3 tools/build_godot_index.py --source /path/to/godot/source   # or --tarball, or nothing to download
```

The real self-test is Godot's:

```bash
godot --headless --script res://scripts/biomes/tests/biome_selftest.gd
```
