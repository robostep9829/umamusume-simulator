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
| `verify_horizon.py` | the numbers `biomes/layers/rural_far.tres` is authored with: ridge continuity, band, haze, rebuild interval |
| `verify_debug_stats.py` | the debug overlay's readout: biome runs, distance to the next biome, run progress |
| `check_engine_api.py` | every engine call in the project's GDScript, against the engine's own method list |
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
