#!/usr/bin/env python3
"""Geometry check of the demo biome's horizon ring, as authored.

A `RING` layer is the one decoration layer whose numbers are not visible in the
editor: the cards sit 1.2-1.6 km away, on an anchor that rides with the runner.
What matters about them is whether the ridge stays continuous (no holes of sky
between the cards), whether it sits in the far band of `doc/LAYERS.md`, how much
haze covers it, and how often it is laid out again.

The numbers below mirror `worlds/scrolling_track/biomes/layers/rural_far.tres`,
`BiomeDirector._build_ring()` and `biomes/rural_env.tres`; update them together.

    python3 tools/verify_horizon.py      # exit 0 = the authored numbers hold
"""
import math
import sys

# layers/rural_far.tres
COUNT = 14
DIST_MIN, DIST_MAX = 1200.0, 1600.0
WIDTH, HEIGHT = 1200.0, 110.0
SCALE_MIN, SCALE_MAX = 0.9, 1.4
HOST_EVERY = 40
# BiomeDirector._build_ring()
SLOT_JITTER = 0.15
# biomes/rural_env.tres
FOG_DENSITY = 0.0008
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
