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
| `build_godot_index.py` | rebuilds `godot_class_index.json`, the class knowledge `check_res.py` runs on |

```bash
python3 tools/check_res.py $(find . -path ./.git -prune -o \( -name "*.tres" -o -name "*.tscn" \) -print)
python3 tools/verify_placement.py
python3 tools/verify_horizon.py
python3 tools/verify_debug_stats.py
```

All of them exit non-zero and print what is wrong, so they can be wired into a
commit hook or CI as-is.

`godot_class_index.json` is generated from the engine's own `doc/classes` XML, so
it knows exactly what a resource may contain. It is committed to keep
`check_res.py` offline; regenerate it after an engine upgrade:

```bash
python3 tools/build_godot_index.py --source /path/to/godot/source   # or --tarball, or nothing to download
```

The real self-test is Godot's:

```bash
godot --headless --script res://scripts/biomes/tests/biome_selftest.gd
```
