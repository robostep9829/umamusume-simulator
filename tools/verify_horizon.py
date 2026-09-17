#!/usr/bin/env python3
"""Geometry check of the demo biome's horizon ring, as authored.

A `RING` layer is the one decoration layer whose numbers are not visible in the
editor: the cards sit 1.2-1.6 km away, on an anchor that rides with the runner.
What matters about them is whether the ridge stays continuous (no holes of sky
between the cards), whether it sits in the far band of `doc/LAYERS.md`, how much
haze covers it, and how often it is laid out again.

The ring and its fog are read from the files that author them, so a change there
cannot leave this checker judging the old numbers; `BiomeDirector._build_ring()`
is the only place a constant is mirrored, because it is code.

    python3 tools/verify_horizon.py      # exit 0 = the authored numbers hold
"""
import math
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LAYER = ROOT / "worlds/scrolling_track/biomes/layers/rural_far.tres"
ENVIRONMENT = ROOT / "worlds/scrolling_track/biomes/rural_env.tres"


def read_resource(path):
    """Properties of a text resource's `[resource]` block and its sub_resources."""
    values = {}
    sub_resources = {}
    current = None
    for raw in path.read_text().splitlines():
        line = raw.strip()
        if line.startswith("[sub_resource"):
            current = re.search(r'\bid="([^"]+)"', line).group(1)
            sub_resources[current] = {}
            continue
        if line.startswith("["):
            current = "resource" if line == "[resource]" else None
            continue
        if current is not None and "=" in line:
            key, value = line.split("=", 1)
            sub_resources.setdefault(current, {})[key.strip()] = value.strip()
    values.update(sub_resources.pop("resource", {}))
    values["_sub_resources"] = sub_resources
    return values


def number(values, key, fallback):
    return float(values[key]) if key in values else fallback


def vector2(value):
    """`Vector2(1200, 110)` as a pair of floats - the constructor name is not a number."""
    inside = re.search(r"\(([^)]*)\)", value)
    parts = inside.group(1).split(",") if inside else value.split(",")
    return tuple(float(part) for part in parts[:2])


layer = read_resource(LAYER)
environment = read_resource(ENVIRONMENT)
mesh = layer["_sub_resources"][re.search(r'SubResource\("([^"]+)"\)', layer["meshes"]).group(1)]

COUNT = int(number(layer, "count", 0))
DIST_MIN, DIST_MAX = number(layer, "distance_min", 0.0), number(layer, "distance_max", 0.0)
WIDTH, HEIGHT = vector2(mesh["size"])
SCALE_MIN, SCALE_MAX = number(layer, "scale_min", 1.0), number(layer, "scale_max", 1.0)
HOST_EVERY = int(number(layer, "host_every", 1))
# The biome's fog as its environment actually has it: switched off, there is no
# haze to measure, and the ring is judged by size and distance alone.
FOG_ENABLED = environment.get("fog_enabled") == "true"
FOG_DENSITY = number(environment, "fog_density", 0.0) if FOG_ENABLED else 0.0
# BiomeDirector._build_ring()
SLOT_JITTER = 0.15
# the track and the runner
ELEMENT_LENGTH = 100.0
SPEED = 25.0
EYE_HEIGHT = 2.0

slot = math.tau / COUNT
spacing_worst = slot * (1.0 + 2.0 * SLOT_JITTER)
half_width_min = math.asin(WIDTH * SCALE_MIN / 2.0 / DIST_MAX)
gap_worst = spacing_worst - 2.0 * half_width_min
interval = HOST_EVERY * ELEMENT_LENGTH / SPEED

print(f"ring: {COUNT} cards of {WIDTH:g} x {HEIGHT:g} m, scale {SCALE_MIN:g}..{SCALE_MAX:g}")
print(f"      band {DIST_MIN:g}..{DIST_MAX:g} m, one slot = {math.degrees(slot):.1f} deg")
print(f"      worst-case gap between neighbours: {math.degrees(gap_worst):8.2f} deg"
      f" = {gap_worst * DIST_MAX:7.1f} m of sky")
for distance in (DIST_MIN, DIST_MAX):
    haze = 1.0 - math.exp(-FOG_DENSITY * distance)
    ridge = math.degrees(math.atan((HEIGHT * SCALE_MIN - EYE_HEIGHT) / distance))
    print(f"      at {distance:7.0f} m: {haze * 100:4.0f}% haze, ridge {ridge:4.1f} deg tall")
print(f"laid out again every {HOST_EVERY * ELEMENT_LENGTH:.0f} m = {interval:.0f} s of running")
if not FOG_ENABLED:
    print("      the biome's environment has fog off: the ring is judged unfogged")

failures = []
if gap_worst > 0.0:
    failures.append(f"the ridge can break by {math.degrees(gap_worst):.1f} deg of sky")
if DIST_MIN < 300.0:
    failures.append("a ring card could be close enough to drive past")
if interval < 60.0:
    failures.append(f"the horizon is laid out again every {interval:.0f} s, which would crawl")
if failures:
    print("\nFAILURES:")
    for failure in failures:
        print("  -", failure)
    sys.exit(1)
print("\nthe ridge stays continuous, sits in the far band, and holds for a whole region")
