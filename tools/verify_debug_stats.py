#!/usr/bin/env python3
"""Checks the numbers the debug overlay shows.

The overlay's headline reading - "distance until the biome changes" - is
arithmetic over three pieces of the engine's state: the element grid the track
indexes slots by (`floor(s / straight_length)`), the run a biome covers
(`BiomePlaylist.run_range_at`), and the arc length of each element
(`TrackSegment.arc_length`). This mirrors `BiomeDirector.debug_stats()`,
`distance_to_biome_change()` and `BiomePlaylist.run_range_at()` in Python and
asserts the values the GDScript self-test asserts, so the two can be compared
without a Godot binary:

    python3 tools/verify_debug_stats.py      # exit 0 = the readout is right
"""
import math
import sys

STRAIGHT_LENGTH = 100.0
TURN_RADIUS = 1200.0
TURN_DEGREES = 5.0
ARC = math.radians(TURN_DEGREES) * TURN_RADIUS

failures: list[str] = []


def check(condition: bool, what: str) -> None:
    if not condition:
        failures.append(what)


def close(actual: float, expected: float, what: str, tolerance: float = 1e-6) -> None:
    check(abs(actual - expected) <= tolerance, f"{what} (got {actual}, expected {expected})")


# --- the endless level of the self-test: 10 straights, then 6 turns, repeating ---
def element_at(index: int) -> str:
    position = index % 16
    return "straight" if position < 10 else "turn"


def element_length(index: int) -> float:
    return STRAIGHT_LENGTH if element_at(index) == "straight" else ARC


def element_direction(index: int) -> int:
    if element_at(index) == "straight":
        return 0
    return 1 if (index // 16) % 2 == 0 else -1


# --- TrackManager: the element grid -------------------------------------------
def element_index_at(s: float) -> int:
    return int(math.floor(s / STRAIGHT_LENGTH))


def element_progress_at(s: float) -> float:
    return min(max(math.fmod(s, STRAIGHT_LENGTH) / STRAIGHT_LENGTH, 0.0), 1.0)


# --- BiomePlaylist: the run of one provider -----------------------------------
def provider_at(index: int, biomes: int, per_biome: int) -> int:
    if biomes == 1 or per_biome <= 0:
        return 0
    return (index // per_biome) % biomes


def run_range_at(index: int, biomes: int, per_biome: int) -> tuple:
    provider = provider_at(index, biomes, per_biome)
    bound = per_biome * biomes
    first = index
    while index - first < bound and provider_at(first - 1, biomes, per_biome) == provider:
        first -= 1
    last = index
    while last - index < bound and provider_at(last + 1, biomes, per_biome) == provider:
        last += 1
    return first, last - first + 1


# --- BiomeDirector: the readout -------------------------------------------------
def distance_to_change(s: float, biomes: int, per_biome: int) -> float:
    if biomes == 1 or per_biome <= 0:
        return -1.0
    index = element_index_at(s)
    first, length = run_range_at(index, biomes, per_biome)
    elements = max(first + length - index, 0)
    distance = element_length(index) * (1.0 - element_progress_at(s))
    for step in range(elements - 1):
        distance += element_length(index + step + 1)
    return distance


def run_progress(s: float, biomes: int, per_biome: int) -> float:
    index = element_index_at(s)
    first, length = run_range_at(index, biomes, per_biome)
    walked = float(index - first) + element_progress_at(s)
    return min(max(walked / max(length, 1), 0.0), 1.0)


def upcoming(index: int, biomes: int, per_biome: int, count: int = 3) -> list:
    runs = []
    first, length = run_range_at(index, biomes, per_biome)
    cursor = first + length
    for _step in range(count):
        run_first, run_length = run_range_at(cursor, biomes, per_biome)
        runs.append((provider_at(cursor, biomes, per_biome), run_length))
        cursor = run_first + run_length
    return runs


# --- what the overlay must show on the demo playlist --------------------------
BIOMES, PER_BIOME = 2, 4
close(element_length(0), 100.0, "element 0 is a 100 m straight")
close(element_length(10), ARC, "element 10 is the 104.72 m arc of a 5 degree turn")
check(element_direction(0) == 0, "a straight has no direction")
check(abs(element_direction(11)) == 1, "a turn bends to one side")

check(run_range_at(0, BIOMES, PER_BIOME) == (0, 4), "a run starts where its round does")
check(run_range_at(3, BIOMES, PER_BIOME) == (0, 4), "the last element of a round is in it")
check(run_range_at(4, BIOMES, PER_BIOME) == (4, 4), "the next round is a run of its own")
check(upcoming(0, BIOMES, PER_BIOME) == [(1, 4), (0, 4), (1, 4)],
      "the upcoming runs start after the current one and alternate")

close(distance_to_change(0.0, BIOMES, PER_BIOME), 400.0, "at s = 0 the change is 400 m away")
close(distance_to_change(50.0, BIOMES, PER_BIOME), 350.0, "at s = 50 half of element 0 is left")
close(run_progress(50.0, BIOMES, PER_BIOME), 0.125, "at s = 50 the run is an eighth done")

# Elements 0-9 are straights and 10-15 are turns, so a run can be all straights,
# all arcs, or a mix - and the readout has to count what each element really is.
close(distance_to_change(400.0, BIOMES, PER_BIOME), 4 * STRAIGHT_LENGTH,
      "the second run is four straights")
close(distance_to_change(1000.0, BIOMES, PER_BIOME), 2 * ARC,
      "a run that ends in the turns counts their arcs")
close(distance_to_change(800.0, BIOMES, PER_BIOME), 2 * STRAIGHT_LENGTH + 2 * ARC,
      "a run that crosses into the turns counts both")
check(distance_to_change(500.0, BIOMES, PER_BIOME) < distance_to_change(400.0, BIOMES, PER_BIOME),
      "the distance to the change falls as the runner advances")

# One biome for the whole track: nothing to wait for.
check(distance_to_change(1234.0, 1, PER_BIOME) == -1.0, "a single biome never changes")
check(distance_to_change(1234.0, BIOMES, 0) == -1.0, "a pinned playlist never changes")

# A single-biome playlist is also what the demo's "playlist_single" is.
check(provider_at(0, 1, 12) == provider_at(9999, 1, 12), "one biome serves the whole track")

if failures:
    print(f"{len(failures)} debug-readout value(s) wrong:")
    for failure in failures:
        print("  -", failure)
    sys.exit(1)
print("the debug readout's biome run, distance-to-change and progress values hold")
