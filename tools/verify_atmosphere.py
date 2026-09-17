#!/usr/bin/env python3
"""Checks that the atmosphere of a playlist is worth looking at.

The biome system's most easily broken promise is the one that has no geometry to
look wrong: a biome carries its own `Environment`, the director cross-fades to it,
and if the numbers in two of those files are close together - or most of a fog
colour is thrown away by `fog_aerial_perspective` - then the world keeps working
and nothing changes on screen. That is the failure this checks.

What the *assets* say is respected, never overridden. `fog_enabled` is the
environment's own switch: a biome with fog off, or one that leaves `atmosphere`
unset and keeps the level's environment, is a perfectly good thing to author and is
not reported as a problem - it simply carries no fog. The checks below only apply to
a fog that is switched *on*, and the comparisons need at least two of those.

Read from the demo content itself, so the numbers cannot drift apart from the
files: the playlist picks the biomes, each biome names its environment and its far
layer, and the far layer says how far away the haze is judged.

    python3 tools/verify_atmosphere.py      # exit 0 = the atmosphere is worth looking at
"""
import math
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BIOMES = ROOT / "worlds/scrolling_track/biomes"
PLAYLIST = BIOMES / "playlist_demo.tres"

# Thresholds of "a player would notice", applied only to a fog that is switched on.
# The sky carries most of the screen, so it is the one that matters: the shift is
# the fog colour mixed into the sky by `fog_sky_affect`, minus whatever
# `fog_aerial_perspective` hands back to the sky.
MIN_SKY_SHIFT = 0.05
MIN_HORIZON_HAZE = 0.40
MIN_HAZE_DIFFERENCE = 0.10
MAX_AERIAL_PERSPECTIVE = 0.50            # above this the fog colour stops leading
MIN_SKY_AFFECT = 0.30                    # below this the sky ignores the fog
MAX_DENSITY = 0.05                       # beyond this the world is a grey wall


def read_resource(path: Path) -> dict:
    """Properties of a text resource's `[resource]` block, plus its ext_resources."""
    values: dict = {}
    ext: dict = {}
    in_resource = False
    for raw in path.read_text().splitlines():
        line = raw.strip()
        if line.startswith("[ext_resource"):
            # `\b` matters: without it the `id="` inside a `uid="uid://..."` matches
            # first and every reference resolves to a UID, which Godot adds on save.
            found = re.search(r'\bid="([^"]+)"', line)
            resource = re.search(r'\bpath="res://([^"]+)"', line)
            if found and resource:
                ext[found.group(1)] = ROOT / resource.group(1)
            continue
        if line.startswith("["):
            in_resource = line == "[resource]"
            continue
        if in_resource and "=" in line:
            key, value = line.split("=", 1)
            values[key.strip()] = value.strip()
    values["_ext"] = ext
    values["_path"] = path
    return values


def reference(value: str, values: dict) -> Path:
    """The file an `ExtResource("id")` property points at."""
    found = re.search(r'ExtResource\("([^"]+)"\)', value)
    if not found:
        raise SystemExit(f"{values['_path'].name}: value is not a reference: {value}")
    return values["_ext"][found.group(1)]


def references(value: str, values: dict) -> list:
    """The files an array property points at, ignoring the array's own type."""
    body = value.split("](", 1)[1] if "](" in value else value
    return [values["_ext"][name] for name in re.findall(r'ExtResource\("([^"]+)"\)', body)]


def colour(value: str) -> tuple:
    numbers = [float(part) for part in re.findall(r"-?\d+(?:\.\d+)?", value)]
    return tuple(numbers[:3])


def number(values: dict, key: str, fallback: float) -> float:
    return float(values[key]) if key in values else fallback


def boolean(values: dict, key: str, fallback: bool) -> bool:
    return values[key] == "true" if key in values else fallback


def haze(density: float, distance: float) -> float:
    """How much of a surface at `distance` is fog: Godot's exponential fog."""
    return 1.0 - math.exp(-density * distance)


playlist = read_resource(PLAYLIST)
providers = references(playlist["biomes"], playlist)
if len(providers) < 2:
    raise SystemExit(f"{PLAYLIST.name}: a transition needs at least two biomes")

print(f"playlist: {len(providers)} biomes, "
      f"{playlist.get('segments_per_biome', '?')} elements each")

rows = []
for provider_path in providers:
    provider = read_resource(provider_path)
    if "atmosphere" not in provider:
        rows.append({"name": provider_path.stem, "environment": None, "layer": None})
        continue
    environment_path = reference(provider["atmosphere"], provider)
    environment = read_resource(environment_path)
    layer = reference(provider["far_layer"], provider) if "far_layer" in provider else None
    rows.append({
        "name": provider_path.stem,
        "environment": environment,
        "environment_path": environment_path,
        "layer": read_resource(layer) if layer else None,
    })

failures = []
for row in rows:
    environment = row["environment"]
    if environment is None:
        # Not an error: `atmosphere` unset is the documented way to keep the level's
        # own environment, and this biome then has no fog of its own to check.
        print(f"  {row['name']:10} keeps the level's environment, no atmosphere of its own")
        continue
    name = row["environment_path"].name
    enabled = boolean(environment, "fog_enabled", False)
    density = number(environment, "fog_density", 0.01)
    aerial = number(environment, "fog_aerial_perspective", 0.0)
    sky_affect = number(environment, "fog_sky_affect", 1.0)
    energy = number(environment, "fog_light_energy", 1.0)
    tint = colour(environment["fog_light_color"]) if "fog_light_color" in environment else (1, 1, 1)
    row.update({"density": density, "aerial": aerial, "sky_affect": sky_affect,
                "energy": energy, "tint": tint, "enabled": enabled, "file": name})
    if not enabled:
        # The environment asset decides. Say so, and judge nothing about it.
        print(f"  {row['name']:10} {name:20} fog off - the asset leaves it off")
        continue
    print(f"  {row['name']:10} {name:20} fog on  colour {tint} density {density:g}")
    print(f"             sky affect {sky_affect:g}, aerial perspective {aerial:g}, "
          f"energy {energy:g}")
    if not 0.0 < density <= MAX_DENSITY:
        failures.append(f"{name}: fog density {density:g} is outside 0..{MAX_DENSITY:g}")
    if aerial > MAX_AERIAL_PERSPECTIVE:
        failures.append(
            f"{name}: `fog_aerial_perspective` {aerial:g} hands more than "
            f"{MAX_AERIAL_PERSPECTIVE:.0%} of the fog colour back to the sky")
    if sky_affect < MIN_SKY_AFFECT:
        failures.append(f"{name}: `fog_sky_affect` {sky_affect:g} leaves the sky out of the fog")

# Only biomes that switched fog on can be compared. A biome with it off is not a
# wrong biome: the fog simply cuts rather than fades, because `fog_enabled` is
# swapped with the rest of the environment instead of being interpolated.
with_atmosphere = [row for row in rows if row["environment"] is not None]
fogged = [row for row in with_atmosphere if row["enabled"]]
if len(fogged) < len(with_atmosphere):
    print(f"fog is on in {len(fogged)} of {len(with_atmosphere)} biomes that carry an "
          f"environment: entering one from another switches it instantly, in or out")

if len(fogged) < 2:
    print(f"only {len(fogged)} biome(s) have fog on, so there is nothing to compare - the "
          f"atmosphere change has to be carried by background, ambient light or tonemap")
else:
    # What the player sees on the sky, which is most of the picture: the biome's fog
    # colour mixed in by `fog_sky_affect`, with `fog_aerial_perspective` of it replaced
    # by the sky itself (the same sky in every biome, so only the rest can differ).
    weights = [(1.0 - row["aerial"]) * row["sky_affect"] * row["energy"] for row in fogged]
    shifts = []
    for i in range(len(fogged) - 1):
        weight = min(weights[i], weights[i + 1])
        shifts.append(weight * max(
            abs(a - b) for a, b in zip(fogged[i]["tint"], fogged[i + 1]["tint"])))
    shift = max(shifts)
    print(f"strongest recolouring of the sky between two biomes with fog: {shift:.3f}")
    if shift < MIN_SKY_SHIFT:
        failures.append(
            f"the fog can only repaint the sky by {shift:.3f}: the colours are too "
            f"close, or the sky is getting too little of them (want {MIN_SKY_SHIFT})")

    # And on the horizon, where the fog has had a kilometre to build up.
    for row in fogged:
        if row["layer"] is None:
            failures.append(f"{row['name']}: no `far_layer`, so there is no horizon to judge")
            continue
        distance = number(row["layer"], "distance_min", 0.0)
        row["haze"] = haze(row["density"], distance)
        print(f"  {row['name']:10} horizon at {distance:g} m is {row['haze']:.0%} fog")
        if row["haze"] < MIN_HORIZON_HAZE:
            failures.append(
                f"{row['name']}: at its own horizon distance only {row['haze']:.0%} of the "
                f"picture is fog (want {MIN_HORIZON_HAZE:.0%})")
    if all("haze" in row for row in fogged):
        spread = max(row["haze"] for row in fogged) - min(row["haze"] for row in fogged)
        if spread < MIN_HAZE_DIFFERENCE and min(row["haze"] for row in fogged) < 0.9:
            failures.append(
                f"the biomes are {spread:.0%} apart in horizon haze: too alike to notice")

if failures:
    print(f"\n{len(failures)} problem(s) with the atmosphere:")
    for failure in failures:
        print("  -", failure)
    sys.exit(1)
print("\nthe atmosphere differs where it is seen, and every fog left off was left alone")
