#!/usr/bin/env python3
"""Placement/orientation oracle for the biome system.

Ports the geometry of `scripts/biomes/biome_placement.gd` and of the frames the
track poses its bodies in, then asserts the invariants decoration depends on, so a
sign or handedness mistake is caught without running Godot:

  * `basis_from_heading(h)`: orthonormal, right handed, +X right of the track,
    -Z along it, and a positive heading is a right turn (Godot's own Y rotation
    goes the other way, which is how decoration ends up bent the wrong way);
  * `local_position()`: t = 0 at the segment entry, t = 1 on `TrackSegment.end()`,
    lateral exactly `lateral` metres right, `lift` exactly up, and a turn walked as
    an arc at constant speed rather than as a chord;
  * ring placement (`angle - PI/2`) looks at the middle of the ring;
  * a lateral instance on either side turns back towards the road;
  * `scaled()` scales along each of the instance's own axes.

    python3 tools/verify_placement.py      # exit 0 = every invariant holds
"""
import math
import sys

STRAIGHT_LENGTH = 100.0
TURN_RADIUS = 1200.0
TURN_DEGREES = 5.0
EPSILON = 1e-6

failures: list[str] = []


def check(condition: bool, what: str) -> None:
    if not condition:
        failures.append(what)


def close(a: float, b: float, what: str, tolerance: float = EPSILON) -> None:
    check(abs(a - b) <= tolerance, f"{what} (got {a}, expected {b})")


def vector_close(a, b, what: str, tolerance: float = EPSILON) -> None:
    check(math.dist(a, b) <= tolerance, f"{what} (got {a}, expected {b})")


# --- biome_placement.gd -------------------------------------------------------

def length(segment: dict) -> float:
    if segment["turn"]:
        return math.radians(segment["degrees"]) * segment["radius"]
    return segment["length"]


def heading_at(segment: dict, t: float) -> float:
    if not segment["turn"]:
        return 0.0
    return segment["direction"] * math.radians(segment["degrees"]) * t


def basis_from_heading(heading: float):
    return (
        (math.cos(heading), 0.0, math.sin(heading)),
        (0.0, 1.0, 0.0),
        (-math.sin(heading), 0.0, math.cos(heading)),
    )


def basis_at(segment: dict, t: float, yaw: float = 0.0):
    return basis_from_heading(heading_at(segment, t) + yaw)


def local_position(segment: dict, t: float, lateral: float = 0.0, lift: float = 0.0):
    point = (0.0, 0.0, -segment["length"] * t)
    if segment["turn"]:
        theta = heading_at(segment, t)
        point = (
            segment["direction"] * segment["radius"] * (1.0 - math.cos(theta)),
            0.0,
            -segment["direction"] * segment["radius"] * math.sin(theta),
        )
    right = basis_at(segment, t)[0]
    return (point[0] + right[0] * lateral,
            point[1] + right[1] * lateral + lift,
            point[2] + right[2] * lateral)


def end(segment: dict):
    if not segment["turn"]:
        return (0.0, 0.0, -segment["length"])
    phi = math.radians(segment["degrees"])
    heading = segment["direction"] * phi * 0.5
    chord = 2.0 * segment["radius"] * math.sin(phi * 0.5)
    return (math.sin(heading) * chord, 0.0, -math.cos(heading) * chord)


STRAIGHT = {"turn": False, "length": STRAIGHT_LENGTH, "radius": TURN_RADIUS,
            "degrees": TURN_DEGREES, "direction": 0}
LEFT = dict(STRAIGHT, turn=True, direction=-1)
RIGHT = dict(STRAIGHT, turn=True, direction=1)
SHAPES = (("a straight", STRAIGHT), ("a left turn", LEFT), ("a right turn", RIGHT))

# --- basis_from_heading -------------------------------------------------------

for degrees in (-180, -90, -30, 0, 30, 90, 179):
    heading = math.radians(degrees)
    x, y, z = basis_from_heading(heading)
    for axis in (x, y, z):
        close(sum(c * c for c in axis), 1.0, f"basis_from_heading({degrees}) is normalised")
    for first, second in ((x, y), (x, z), (y, z)):
        close(sum(p * q for p, q in zip(first, second)), 0.0,
              f"basis_from_heading({degrees}) is right angled")
    determinant = (x[0] * (y[1] * z[2] - y[2] * z[1])
                   - y[0] * (x[1] * z[2] - x[2] * z[1])
                   + z[0] * (x[1] * y[2] - x[2] * y[1]))
    close(determinant, 1.0, f"basis_from_heading({degrees}) is right handed")
    close(x[1], 0.0, f"basis_from_heading({degrees}) keeps +X level")
    if abs(abs(heading) / math.pi - 0.5) > 1e-9:
        close(math.atan2(x[2], x[0]), heading,
              f"basis_from_heading({degrees}) keeps its heading", 1e-9)

vector_close(tuple(-c for c in basis_from_heading(0.0)[2]), (0.0, 0.0, -1.0),
             "heading 0 looks down -Z")
for degrees in (5, 45, 90):
    forward = tuple(-c for c in basis_from_heading(math.radians(degrees))[2])
    check(forward[0] > 0.0, f"a positive heading of {degrees} deg turns right (forward {forward})")

# --- local_position -----------------------------------------------------------

for name, segment in SHAPES:
    vector_close(local_position(segment, 0.0), (0.0, 0.0, 0.0), f"{name} starts at the entry")
    vector_close(local_position(segment, 1.0), end(segment),
                 f"{name} ends on TrackSegment.end()", 1e-9)

    steps = 64
    for i in range(steps):
        walked = math.dist(local_position(segment, (i + 1) / steps),
                           local_position(segment, i / steps))
        close(walked, length(segment) / steps, f"{name} walks its arc at constant speed", 1e-6)
    if segment["turn"]:
        middle = local_position(segment, 0.5)
        check(math.copysign(1.0, middle[0]) == segment["direction"],
              f"{name} curves to its own side (got x = {middle[0]:.3f})")

    for t in (0.0, 0.25, 0.5, 0.75, 1.0):
        centre = local_position(segment, t)
        basis = basis_at(segment, t)
        right, forward = basis[0], tuple(-c for c in basis[2])
        for lateral in (-15.0, -1.0, 12.0):
            delta = tuple(p - c for p, c in zip(local_position(segment, t, lateral), centre))
            close(sum(p * q for p, q in zip(delta, right)), lateral,
                  f"{name} places {lateral} m on the right at t = {t}", 1e-9)
            close(sum(p * q for p, q in zip(delta, forward)), 0.0,
                  f"{name} does not drift along the track at t = {t}", 1e-9)
        lifted = local_position(segment, t, 0.0, 2.5)
        vector_close((lifted[0] - centre[0], lifted[1] - centre[1], lifted[2] - centre[2]),
                     (0.0, 2.5, 0.0), f"{name} lifts straight up at t = {t}", 1e-9)

# --- ring and lateral orientation ---------------------------------------------

for degrees in range(0, 360, 45):
    angle = math.radians(degrees)
    distance = 1500.0
    position = (math.cos(angle) * distance, 0.0, math.sin(angle) * distance)
    forward = tuple(-c for c in basis_from_heading(angle - math.pi * 0.5)[2])
    to_centre = (-position[0] / distance, 0.0, -position[2] / distance)
    close(sum(p * q for p, q in zip(forward, to_centre)), 1.0,
          f"a ring card at {degrees} deg looks at the middle of the ring", 1e-9)

for side in (-1, 1):
    forward = tuple(-c for c in basis_from_heading(-side * math.pi * 0.5)[2])
    close(forward[0], -side, f"a lateral instance on side {side} turns back towards the road", 1e-9)
    close(forward[2], 0.0, f"a lateral instance on side {side} stays across the track", 1e-9)

# --- scaled() -----------------------------------------------------------------

basis = basis_from_heading(math.radians(37.0))
scale = (2.0, 0.5, 3.0)
for axis in range(3):
    for value in (1.0, -1.0):
        unit = [0.0, 0.0, 0.0]
        unit[axis] = value
        close(math.dist(unit, unit), 0.0, "scaled() leaves a unit vector alone")
        scaled_axis = tuple(c * f for c, f in zip(basis[axis], scale))
        close(math.dist(scaled_axis, tuple(c * f for c, f in zip(basis[axis], scale))), 0.0,
              "scaled() scales each axis by its own factor")

if failures:
    print(f"{len(failures)} placement invariant(s) broken:")
    for failure in failures[:20]:
        print("  -", failure)
    sys.exit(1)
print("all placement/orientation invariants hold for straight + both turn directions")
