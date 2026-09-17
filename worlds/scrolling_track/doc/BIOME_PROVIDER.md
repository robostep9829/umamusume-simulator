[//]: # (Companion to BIOMES.md and LAYERS.md - describes the implementation)
# BiomeProvider: biomes as swappable skins for the scrolling track

`BIOMES.md` proposes biomes as *themes over the same chunk logic* and `LAYERS.md`
proposes the four layers that make up a look. This document describes the code
that implements both.

```text
scripts/biomes/
    biome_provider.gd     BiomeProvider  - the interface: road skin, layers, sky
    biome_layer.gd        BiomeLayer     - one authored decoration layer
    biome_playlist.gd     BiomePlaylist  - which biome runs where
    biome_section.gd      BiomeSection   - one leg of an authored lap
    biome_director.gd     BiomeDirector  - applies a playlist to a TrackManager
    biome_placement.gd    BiomePlacement - segment-local geometry + seeded RNG
    tests/biome_selftest.gd              - headless checks, no art needed

worlds/scrolling_track/biomes/
    rural.tres                           - a biome, as data
    rural_dusk.tres                      - a second one, to show transitions
    playlist_demo.tres                   - rural / rural_dusk, 12 elements each
    playlist_single.tres                 - one biome for the whole track
    layers/rural_{near,mid,far}.tres     - the three decoration layers
    materials/*.tres                     - road skins and placeholder prop materials
    rural_dusk_env.tres                  - the dusk atmosphere
```

The design rule is the one from `BIOMES.md`: **the track never changes shape.**
`TrackManager`, `TrackLevel` and `InfiniteTrackLevel` keep deciding where the road
goes and what is on it; a biome only says what that road *looks like* and what
stands beside it. Swapping biomes changes no gameplay geometry at all.

---

## 1. The contract

### 1.1 `BiomeProvider` - what a biome answers

`BiomeProvider` is a `Resource` that answers four questions.

| Question | Method | Layer in `LAYERS.md` |
|---|---|---|
| What is the road surface? | `road_material(segment, variant)`, `road_mesh(segment, variant)` | 0 - playfield |
| What stands beside the road? | `decoration(NEAR / MID / FAR)` → `BiomeLayer` | 1, 2, 3 |
| Anything that cannot be described as a list of props? | `decorate_layer(layer, host, element_index, segment)` | 1, 2, 3 |
| What is the sky doing? | `environment_override()` | 3 - horizon/atmosphere |

Every method has a sensible default, and the defaults read exported fields, so a
biome that is a pure re-skin needs **no code at all**: duplicate `rural.tres`,
point `road_material_override` at another material and swap the three layer
resources. Subclass `BiomeProvider` when a biome needs more than that - the road
skin of `road_skins` can cycle per element, `decorate_layer()` can add scripted
content, `environment_override()` can return a computed sky.

Biomes must not assume a turn direction: the same provider runs on left- and
right-hand corners of a level, so all placement is relative to the travelling
direction (`+X` is "right of the runner"), never to world axes.

### 1.2 Gameplay hooks - declared, not consumed yet

`BIOMES.md` also describes obstacle skins (`BARRIER`, `DIRT_PATH`, `WEIGHT`,
`STAIRS`, `SLOW_ZONE`) and per-biome features (`final_stretch_gates`,
`crosswalk_zone`, `park_stretch`). The interface declares them:

```gdscript
func obstacle_skin(kind: ObstacleSkin) -> PackedScene   # reads obstacle_skins[]
func feature(feature_id: StringName) -> Variant          # null today
```

Nothing calls either of them yet, because there is no obstacle system to dress
yet. They exist so a biome does not have to be re-authored when obstacles land.

### 1.3 `BiomeLayer` - one authored decoration layer

A layer is data: what to instance, how far away, how many, how jittered.

| Field | Meaning |
|---|---|
| `mode` | `ALONG_TRACK` = spread beside the road, recycles with the segment. `RING` = a circle around the horizon anchor |
| `variants` / `meshes` | scenes (a tree, a house) or meshes (cheap repeated props) |
| `multimesh` | one draw call per segment for a whole layer; forces the first mesh |
| `count`, `side` | instances per segment and side, or the number of instances around a ring |
| `host_every` | `ALONG_TRACK`: only every N-th element is dressed. `RING`: how many elements the horizon may stay unchanged |
| `distance_min/max` | metres from the centreline, or the ring radius |
| `edge_margin`, `along_scatter`, `lateral_scatter`, `lift`, `lift_scatter` | where exactly inside those bounds an instance ends up |
| `scale_min/max`, `yaw_scatter`, `face_track` | how it is oriented and sized |
| `fit_to_segment` | stretch a mesh so one copy spans its share of the segment, longest horizontal side aligned with the track. Built for railings, fences and hedges whose authored length you do not want to match by hand |
| `visible_range`, `cast_shadow` | cost controls |
| `seed` | offsets this layer's slice of the director's decoration seed |

A `RING` layer ignores `side`, `edge_margin` and `along_scatter` (its instances
are spread evenly around the circle). `host_every` works in both modes, with the
meaning above.

### 1.4 `BiomePlaylist` - which biome runs where

Two authoring styles, and the one that fits the level is used:

```text
Endless track    biomes + segments_per_biome
                 elements 0..N-1 run in biomes[0], the next N in biomes[1], then
                 it wraps. 12 elements x 100 m is a couple of minutes per biome.
                 One biome in the list, or segments_per_biome = 0, pins the whole
                 track to that biome - the intended setup for a themed level.
                 order = SHUFFLE reshuffles the list on every pass.

Closed lap       sections
                 An explicit running order ("30 elements of racetrack, then 20 of
                 suburbs") repeated around the loop. This is what a lap with two
                 biomes will use; a one-biome lap is just a one-section playlist.
```

Selection is a pure function of the *element index* and never of the player's
position, so every pooled body agrees on it, it survives a reload, and it is the
same after the endless track re-centred its window.

---

## 2. How `BiomeDirector` applies it

Add one `BiomeDirector` node next to the `TrackManager`, point it at the track,
the playlist and the `WorldEnvironment`, and that is the whole wiring:

```text
ScrollingTrack
├── TrackManager          infinite = true
├── Player
├── DirectionalLight3D
├── WorldEnvironment      <- the atmosphere a biome overrides
└── BiomeDirector         track = ../TrackManager, playlist = playlist_demo.tres
```

`worlds/scrolling_track/scrolling_track.tscn` is wired exactly like that and can
be run straight away (after the editor imports the assets).

### 2.1 Segments: decoration that rides the track

`TrackManager` emits `segment_placed(element_index, body, segment)` for every
floor body it (re)places, after the body is posed in its segment's local frame
(entry point at the origin, `-Z` forward, `+X` right). The director then:

1. asks the playlist for the biome that owns that element,
2. sets the road material (and mesh, if the biome replaces it),
3. if this body now shows a different segment or a different biome, clears its
   `BiomeLayer{NEAR,MID,FAR}` container nodes and rebuilds them from the layers.

Two properties fall out of that:

* **Decoration follows the track for free.** It is parented to the floor body, so
  it is correct on straights and on both turn directions, and it disappears with
  the segment when the pool recycles it. No per-frame work at all.
* **Re-placing is a no-op.** `segment_placed` fires for the whole pool every
  physics frame in closed-loop mode and on every window re-centre in endless
  mode; the director compares `(element_index, provider, segment)` per body and
  returns early when nothing changed. Since decoration is seeded by the element
  index, rebuilding a segment that moved to another pooled body reproduces the
  *same* world-space result - which is why re-centring the endless window does
  not visibly reshuffle the scenery.

### 2.2 Horizon: layer 3 without a seam

A `RING` layer is not tied to a segment. It lives on a `HorizonAnchor` that rides
with the runner - position only, never rotation - so:

* the horizon **surrounds** them in every direction instead of piling up in a cone
  ahead of them. A ring whose cards all end up in front is the classic way to make
  distant scenery read as floating cards;
* it cannot be outrun: every card stays exactly `distance_min..distance_max` away,
  whatever the runner does, so a `RING` layer belongs to the far band and wants a
  `distance_min` of a kilometre or more;
* it does not show the seams of the segment pool.

The ring is laid out again only when the runner moves into another region of
`host_every` elements, or when the biome changes. Between rebuilds the cards are
perfectly still, which is the "camera-locked or very slow parallax" `LAYERS.md`
asks of layer 3, and it costs nothing per frame. A biome without a `RING` layer
leaves the anchor untouched.

Because `_build_ring()` spreads the cards one slot apart with a slot jitter of at
most 15 %, a ring whose cards are about as wide as a slot is continuous: the ridge
of `layers/rural_far.tres` (14 cards of 1200 x 110 m on a 1.2-1.6 km ring) overlaps
itself even in the worst case instead of leaving holes of empty sky.

### 2.3 Atmosphere: the one thing that must not change at a chunk boundary

`LAYERS.md` says layer 3 "changes only on biome transition". The director polls
the biome under the player each physics frame and, when it changes:

* rebuilds the horizon around the anchor of the new biome,
* cross-fades `WorldEnvironment.environment` over
  `environment_transition_time` seconds,
* emits `biome_changed(provider)` for UI, audio or the camera rig.

The fade works on a *duplicate* of the biome's `Environment` (the authored
`.tres` is never written to) and blends the numeric fields both environments
have - background, ambient light, fog and tonemap. A resource's `sky` cannot be
interpolated, so it is swapped with the rest of the biome's environment.

One approximation to know about: element boundaries are measured along the
centreline, and the endless track indexes slots by the straight segment's length,
while a 5-degree turn is 104.7 m long. The biome under the player can therefore
be off by about half a segment near a boundary, which a multi-second fade hides
completely.

The demos show why a biome should carry its own `atmosphere` even when it is a
day-lit one: `rural.tres` uses `rural_env.tres`, the project's base environment
plus `fog_enabled` and a haze colour, and that fog is what turns a 1.5 km card into
distant scenery instead of a crisp rectangle. Without it, everything past the
playfield is as sharp as the road.

---

## 3. Authoring a new biome

1. **Road.** Make a material with the ground shader of the biome (or an existing
   one). Either reference it directly or put several into `road_skins` so the
   surface varies along the biome.
2. **Layers.** Duplicate `layers/rural_near.tres` (beside the road, 15-60 m),
   `rural_mid.tres` (60-200 m) and `rural_far.tres` (the ring), or write new ones.
   Keep the bands of `LAYERS.md`; the director does not enforce them.
3. **Atmosphere.** Optional: an `Environment` in `atmosphere` for a different
   time of day or weather; the transition is automatic.
4. **Biome.** Duplicate `rural.tres`, set `biome_id`, `display_name` and the
   fields above. `BiomeProvider` can be used directly - no script needed.
5. **Playlist.** Add it to `playlist_demo.tres` for the endless track, or to a
   `sections` list for an authored lap.
6. **Check.** `playlist.validate()` runs on `_ready` and reports empty biomes,
   empty layers and inconsistent numbers through `push_warning()`.

For the three biomes of `BIOMES.md`, step 2 is the work: the obstacle and
feature tables there are data for the hooks of section 1.2 once obstacles exist.

---

## 4. Verifying it

```bash
godot --headless --script res://scripts/biomes/tests/biome_selftest.gd
```

The self-test builds its own segments, layers, playlist and track (no imported
art), so it runs in about a second and exits non-zero on failure. It checks:

* placement lands exactly on `TrackSegment.end()` for straights and for left and
  right turns, mirror symmetry between the two turn directions, and that lateral
  offsets stay perpendicular to the track;
* decoration placement is reproducible (same seed + element + slot = same
  values), which is the property the recycling rules rely on;
* playlist selection in all four modes (auto, single biome, shuffle, sections);
* the track/director contract: every pooled body gets the road skin, a layer is
  built once per hosted element, re-placing unchanged segments keeps the *same*
  decoration nodes, and switching biome rebuilds them in place;
* horizon rings keep their distance band, ride with the runner, and are only laid
  out again when the runner leaves a region;
* the debug readout's numbers: the run a biome covers, the distance and element
  count to the next change (counting turns as the arcs they are), the run's
  progress, and the single-biome case, where there is no change to wait for.

Godot does not have to be the only judge. `tools/` holds four offline checkers,
all of which exit non-zero and say what is wrong:

```bash
python3 tools/check_res.py $(find . -path ./.git -prune -o \( -name "*.tres" -o -name "*.tscn" \) -print)
python3 tools/verify_placement.py     # placement/orientation invariants
python3 tools/verify_horizon.py       # the far layer's numbers: continuity, haze, cost
python3 tools/verify_debug_stats.py   # what the debug overlay reads
```

`check_res.py` validates the text resources - paths, types, `script_class`,
property names, typed arrays, shader parameters, node parents - against the same
class information Godot itself uses (a class index generated from the engine's
`doc/classes`, see `tools/build_godot_index.py`), so a typo in a hand-authored
`.tres` is caught before the editor is opened. The three oracles exist because the
biome system's failures are geometric and numeric - a mirrored instance, a ring
that drifts out of reach, a distance that reads wrong - and those are exactly the
things a headless self-test in a text-only checkout cannot see either.

---

## 5. What is placeholder here

The system is complete; the *content* of the demo is not, and the demo says so
wherever it matters:

| Asset | What it is |
|---|---|
| `layers/rural_near.tres` | the island's tree, wrapped as `props/rural_tree.tscn` and placed as a scene variant: real art, one per side per segment. Its leaf `MultiMesh` is 4700 instances rebuilt per instance, so the layer hosts it on every second element only, keeps `visible_range` short and casts no shadows; a real biome should bake a lighter tree |
| `props/leaf_mesh.tres` | the leaf quad baked out of `uma_island.tscn`, so the demo does not depend on `props/rural/leaf.obj` being present in the checkout |
| `layers/rural_mid.tres` | one `QuadMesh` card per segment with a flat unshaded material - a treeline, not a treeline asset |
| `layers/rural_far.tres` | fourteen Y-billboard cards on a 1.2-1.6 km ring - a horizon, not a panorama. They are still flat rectangles: replacing the card mesh with a hill silhouette is what this layer wants next |
| `rural_env.tres` | the base environment plus fog, so the far band hazes out; a real biome would light its own sky, not reuse the island's |
| `rural_dusk.tres` | a second biome so that transitions are visible at all; it is rural again with the dirt road texture and a dusk `Environment`, and should be replaced by the first real biome (city or suburbs) |
| `materials/*.tres` | flat colours with `TODO`-less names, because they will be replaced wholesale |

One thing to know about the demo level: `scrolling_track.tscn` is a bare 30 m road
strip with no terrain beside it, so the near layer keeps its trees *on* the strip
(13-14.5 m from the centreline, just inside the edge). In a level with ground,
widen `distance_min`/`distance_max` to the 15-60 m band of `LAYERS.md`.

One geometric detail about `fit_to_segment`: a stretched strip is aligned with
the track's chord, not with the arc. On a 5-degree turn of 1200 m radius that is
about a metre of sag at the segment's ends, so neighbouring railing pieces meet
with a small step instead of a perfect seam. It is invisible next to a real
mesh; if it ever matters, wrap the strip in a short scene and do not use
`fit_to_segment`.

Two more things worth knowing while iterating:

* Biomes are play-time only. `TrackManager` is not a `@tool` script, so no biome
  work happens while the editor is paused; press Play. `BiomeDirector.refresh()`
  re-applies everything to a running world (it calls `TrackManager.refresh_pool()`,
  which re-places and re-announces every pooled segment).
* Everything that scales with the pool is O(pooled segments): decoration is
  parented per segment, so the cost of a biome is its layer descriptors, not the
  length of the track, and an idle frame only compares 40 small dictionaries.

---

## 6. Debug overlay

`scripts/debug/debug_overlay.gd` is the window into all of the above at runtime. It
is a `CanvasLayer` that builds its own panel, finds the level's `TrackManager`,
`BiomeDirector` and player by itself (or takes them from the inspector), and shows:

| Line | What it is |
|---|---|
| `fps / frame / physics` | frame rate and the two process times, in ms |
| `s` | metres along the centreline to the runner, counted from the start of the endless level or from the closed loop's origin, plus the lap and the distance left in it |
| `speed` | the player's velocity, in m/s |
| `element` | the element index under the runner, whether it is a straight or which way it turns, and how far into it they are |
| `pos` | the player's world position |
| `biome` | the active provider's `biome_id` and `display_name` |
| `next` | the biome that follows, in metres, seconds and elements - or "this biome runs the whole track" when the playlist pins one |
| the bar | how far through the current biome run the runner is |
| `track` | endless or closed loop, pool size, seed / lap length |
| `layers` | instances built per decoration layer, as they really are in the pool |
| `horizon` | cards in the ring and how far the anchor currently is |
| `skin` / `atmo` / `playlist` / `coming` | road variant, atmosphere file, playlist mode, the next few runs |

**F3** shows and hides it, **F4** cycles `compact` / `normal` / `full`. On a
touchscreen a small button in the top-right corner opens it instead. The panel
never takes input, so it cannot swallow the game's controls, and its width is fixed
so the readout does not twitch as numbers change. Nothing in it is needed at
runtime: delete the node and the game is exactly as before.

The overlay does not reach into the biome system's internals. It reads one
dictionary - `BiomeDirector.debug_stats()` - plus the track's inspection helpers
(`is_endless()`, `lap_length()`, `track_distance_at()`, `element_index_at()`,
`element_length_at()`, `element_direction_at()`, `element_progress_at()`) and the
playlist's (`is_single_biome()`, `run_range_at()`, `describe()`). Those are
read-only and public on purpose: any other HUD, tool or test that wants "which
biome is the runner in, and how long until it changes?" can use them, and
`tools/verify_debug_stats.py` checks the arithmetic behind them.

`run_range_at()` deserves a note: a biome *run* is a maximal stretch of elements
served by one provider, measured rather than derived from `segments_per_biome`.
That matters with shuffling, where a round can open with the biome that is already
running, making the run twice as long as a round.

To add the overlay to another level, add a `CanvasLayer` with the script attached:

```gdscript
[node name="DebugOverlay" type="CanvasLayer" parent="."]
script = ExtResource("debug_overlay")
```
