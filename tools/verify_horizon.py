#!/usr/bin/env python3
"""Geometry check of a biome's horizon ring, as authored.

A `RING` layer is the one decoration layer whose numbers are not visible in the
editor: the cards sit hundreds of metres away, on an anchor that rides with the
runner. What matters about them is whether the ridge stays continuous (no holes of
sky between the cards), whether it sits in the far band of `doc/LAYERS.md`, how much
haze covers it, and how often it is laid out again.

The band is bounded on both ends, and neither end belongs to the layer file. The
near end is `BiomeLayer.RING_MIN_DISTANCE` - closer than that the horizon reads as
scenery the runner could reach - and it is read from the script that defines it. The
far end is the camera's far plane, read from `prefabs/third_person.tscn`: past it a
card is culled and never drawn, so a ring authored 1.2 km out against a 250 m camera
is invisible rather than far away. The card's *corners* have to clear the far plane
too, or the ridge is clipped into a straight edge.

The ring and its fog are read from the assets that author them - the biome's
`far_layer` and its `atmosphere`, wherever those live and whether the atmosphere is
a file of its own or an inline `[sub_resource]` - so a restructure or a change
cannot leave this checker judging an older version. The only mirrored constant is
`BiomeDirector`'s own slide jitter, because that one is code.

    python3 tools/verify_horizon.py [biome.tres ...]
                                     # exit 0 = the authored numbers hold
"""
import math
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import resfile

# BiomeDirector._build_ring(): how far a card may slide inside its slot, as a
# fraction of the slot. Kept small on purpose, so the ridge cannot open a hole.
SLOT_JITTER = 0.15
# the track and the runner
ELEMENT_LENGTH = 100.0
SPEED = 25.0
EYE_HEIGHT = 2.0
# Godot's own default, used when the camera does not set one
CAMERA_FAR_DEFAULT = 4000.0
RING_MIN_DEFAULT = 200.0


def ring_min_distance() -> float:
    """`BiomeLayer.RING_MIN_DISTANCE`, read from the script that defines it."""
    source = resfile.find_asset("biome_layer.gd", under="scripts").read_text()
    for line in source.splitlines():
        if line.startswith("const RING_MIN_DISTANCE"):
            return float(line.split(":=")[1].strip())
    return RING_MIN_DEFAULT


def camera_far() -> float:
    """The far plane of the camera that draws the level.

    Read as text rather than through `resfile`, which parses `[resource]` and
    `[sub_resource]` sections: a scene's camera is a `[node]`, and the only number
    that matters here is that node's `far`.
    """
    text = resfile.find_asset("third_person.tscn", under="prefabs").read_text()
    inside_camera = False
    for line in text.splitlines():
        if line.startswith("[node "):
            inside_camera = 'name="Camera3D"' in line
        elif inside_camera and line.startswith("far = "):
            return float(line.removeprefix("far = "))
    return CAMERA_FAR_DEFAULT


ring_min = ring_min_distance()
far_plane = camera_far()


def biome_files() -> list:
    """Every biome in the project, found by their shared folder rather than by a
    path written into this file."""
    folder = resfile.find_asset("rural.tres").parent
    return sorted(
        path for path in folder.glob("*.tres")
        if "far_layer" in resfile.read(path).values
    )


paths = [Path(argument).resolve() for argument in sys.argv[1:]] or biome_files()
if not paths:
    raise SystemExit("no biome with a `far_layer` was found to check")

failures = []
checked = set()
for path in paths:
    biome = resfile.read(path)
    layer = biome.reference("far_layer")
    environment = biome.reference("atmosphere")
    if layer is None:
        failures.append(f"{biome.origin}: no `far_layer`, so there is no horizon")
        continue
    # BiomeLayer.Mode: 0 = ALONG_TRACK, 1 = RING. Only a ring is judged here.
    if layer.integer("mode", 0) != 1:
        continue
    # Two biomes sharing one ring is the normal case, so the ring is judged once.
    key = (layer.origin, environment.origin if environment else "")
    if key in checked:
        continue
    checked.add(key)

    mesh = layer.references("meshes")
    mesh = mesh[0] if mesh else None
    count = max(layer.integer("count", 0), 0)
    dist_min = layer.number("distance_min", 0.0)
    dist_max = layer.number("distance_max", 0.0)
    scale_min = layer.number("scale_min", 1.0)
    host_every = max(layer.integer("host_every", 1), 1)
    width, height = mesh.vector2("size") if mesh else (0.0, 0.0)
    fogged = environment is not None and environment.boolean("fog_enabled")
    density = environment.number("fog_density", 0.0) if fogged else 0.0

    print(f"biome {biome.text('biome_id', path.stem)}: ring {layer.origin}")
    print(f"      {count} cards of {width:g} x {height:g} m, scale {scale_min:g}.."
          f"{layer.number('scale_max', 1.0):g}")
    slot_degrees = math.degrees(math.tau / max(count, 1))
    print(f"      band {dist_min:g}..{dist_max:g} m, one slot = {slot_degrees:.1f} deg")
    if not fogged:
        print("      the biome's environment has fog off: the ring is judged unfogged")

    if count < 2 or mesh is None:
        failures.append(f"{layer.origin}: a ring needs `count` cards and one mesh in `meshes`")
        continue

    slot = math.tau / count
    spacing_worst = slot * (1.0 + 2.0 * SLOT_JITTER)
    half_width_min = math.asin(min(width * scale_min / 2.0 / max(dist_max, 1.0), 1.0))
    gap_worst = spacing_worst - 2.0 * half_width_min
    interval = host_every * ELEMENT_LENGTH / SPEED
    print(f"      worst-case gap between neighbours: {math.degrees(gap_worst):8.2f} deg"
          f" = {gap_worst * dist_max:7.1f} m of sky")
    for distance in (dist_min, dist_max):
        haze = 1.0 - math.exp(-density * distance)
        ridge = math.degrees(math.atan(max(height * scale_min - EYE_HEIGHT, 0.0) / distance))
        print(f"      at {distance:7.0f} m: {haze * 100:4.0f}% haze, ridge {ridge:4.1f} deg tall")
    print(f"      laid out again every {host_every * ELEMENT_LENGTH:.0f} m = "
          f"{interval:.0f} s of running")
    print(f"      band limits: {ring_min:g} m to the camera's far plane at {far_plane:g} m")

    if gap_worst > 0.0:
        failures.append(f"{layer.origin}: the ridge can break by "
                        f"{math.degrees(gap_worst):.1f} deg of sky")
    if dist_min < ring_min:
        failures.append(
            f"{layer.origin}: a ring card could be close enough to drive past "
            f"({dist_min:g} m, want at least {ring_min:g} m)")
    if dist_max > far_plane:
        failures.append(
            f"{layer.origin}: the ring is at {dist_max:g} m, past the camera's far plane "
            f"({far_plane:g} m), so it is never drawn")
    corner = math.hypot(dist_max, width * layer.number("scale_max", 1.0) / 2.0)
    if corner > far_plane:
        failures.append(
            f"{layer.origin}: a card's far corner reaches {corner:.0f} m, past the camera's "
            f"far plane ({far_plane:g} m), where it is clipped")
    if interval < 60.0:
        failures.append(f"{layer.origin}: the horizon is laid out again every {interval:.0f} s, "
                        f"which would crawl")

if failures:
    print(f"\n{len(failures)} problem(s):")
    for failure in failures:
        print("  -", failure)
    sys.exit(1)
print("\nthe ridge stays continuous, sits between both band limits, and holds for a region")
