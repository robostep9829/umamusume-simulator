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
    providers/rural_biome.gd             - the rural biome as a subclass
    tests/biome_selftest.gd              - headless checks, no art needed

worlds/scrolling_track/biomes/
    rural.tres                           - a biome, as data (a RuralBiome)
    rural_dusk.tres                      - a second one, to show transitions

worlds/scrolling_track/biomes/rural/     - everything the rural biome owns
    layers/rural_{near,mid,far}.tres     - the three decoration layers
    materials/*.tres                     - road skins and placeholder prop materials
    props/rural_tree.tscn, leaf_mesh.tres
    tex/*.png, *.exr                     - the textures those materials use

worlds/scrolling_track/playlists/
    playlist_demo.tres                   - rural / rural_dusk, 3 elements each
    playlist_single.tres                 - one biome for the whole track
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
| `host_every` | `RING` only: how many elements may pass before the horizon is laid out again |
| `frequency_min/max` | along-track sparsity: each element draws its own period from the decoration seed and is dressed only when its index is a multiple of it, so 1..6 dresses roughly one element in six |
| `distance_min/max` | metres from the centreline, or the ring radius |
| `edge_margin`, `along_scatter`, `lateral_scatter`, `lift`, `lift_scatter` | where exactly inside those bounds an instance ends up |
| `scale_min/max`, `yaw_scatter`, `face_track` | how it is oriented and sized |
| `fit_to_segment` | stretch a mesh so one copy spans its share of the segment - for railings, fences and hedges whose authored length you would otherwise match by hand |
| `visible_range`, `cast_shadow` | cost controls |
| `seed` | offsets this layer's slice of the director's decoration seed |

A `RING` layer ignores `side`, `edge_margin` and `along_scatter` (its instances are
spread evenly around the circle), and an along-track layer ignores `host_every`: the
two modes decide how often they change in different ways.

### 1.4 `BiomePlaylist` - which biome runs where

Two authoring styles, and the one that fits the level is used:

```text
Endless track    biomes + segments_per_biome
                 elements 0..N-1 run in biomes[0], the next N in biomes[1], then
                 it wraps. 12 elements x 100 m is a couple of minutes per biome;
                 the demo sets 3 so a transition is visible within seconds.
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

Three properties fall out of that:

* **The first pool is dressed before the first frame is drawn.** A level lists its
  `TrackManager` before its `BiomeDirector`, so the track places its whole first
  pool in its own `_ready()` - which runs first, because children are readied in
  tree order - while nothing is listening yet. The director re-announces what it
  finds as it becomes ready (`TrackManager.refresh_pool()`), so a run never opens
  on a bare window. In endless mode that is not a cosmetic difference: nothing
  announces the pool again until the window re-centres, which is ~26 elements of
  running away.
* **Decoration follows the track for free.** It is parented to the floor body, so
  it is correct on straights and on both turn directions, and it disappears with
  the segment when the pool recycles it. No per-frame work at all.
* **Re-placing is a no-op, and a re-centre is nearly one.** `segment_placed` fires
  for the whole pool every physics frame in closed-loop mode and on every window
  re-centre in endless mode; the director compares `(element_index, provider,
  segment)` per body and returns early when nothing changed. That comparison is only
  worth anything because `TrackManager._body_for_slot()` keys each body by the
  window slot it carries, counted absolutely: a re-centre by six elements leaves the
  elements that are still in the window on the body they are already dressed on, so
  only the six that entered are rebuilt - six elements, not the whole pool. Since
  decoration is seeded by the element index, even those reproduce the same
  world-space decoration they had the last time the window covered them, which is
  why re-centring does not visibly reshuffle the scenery.

### 2.2 Horizon: layer 3 without a seam

A `RING` layer is not tied to a segment. It lives on a `HorizonAnchor` that rides
with the runner - position only, never rotation - so:

* the horizon **surrounds** them in every direction instead of piling up in a cone
  ahead of them. A ring whose cards all end up in front is the classic way to make
  distant scenery read as floating cards;
* it cannot be outrun: every card stays exactly `distance_min..distance_max` away
  whatever the runner does, so a `RING` layer belongs to the far band, where the
  band's own limits are `BiomeLayer.RING_MIN_DISTANCE` and the camera's far plane;
* it does not show the seams of the segment pool.

The ring is laid out again only when the runner moves into another region of
`host_every` elements, or when the biome changes. Between rebuilds the cards are
perfectly still, which is the "camera-locked or very slow parallax" `LAYERS.md`
asks of layer 3, and it costs nothing per frame. A biome without a `RING` layer
leaves the anchor untouched.

Because `_build_ring()` spreads the cards one slot apart with a slot jitter of at
most 15 %, a ring whose cards are about as wide as a slot is continuous: the ridge
of `rural/layers/rural_far.tres` (20 cards of 115 x 22 m on a 200-235 m ring)
overlaps itself even in the worst case instead of leaving holes of empty sky.

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
interpolated, so it is swapped with the rest of the biome's environment, and so is
`fog_enabled`: a biome that turns fog *on* does it as its environment is assigned,
while its colour, density and energy travel over the fade.

The first biome of a run is applied without a fade: cross-fading out of the level's
own environment would show *that* look - possibly a different time of day, or much
denser fog - at the start of every run, which is not a transition the player made.
Every later switch, and only those, takes `environment_transition_time`.

`fog_enabled` is the environment file's own switch. Nothing in the system writes to
it: a biome whose environment leaves fog off is rendered with fog off, and the
change is carried by whatever that environment *does* set (background, ambient light,
tonemap). The one consequence worth knowing is that the switch is not interpolated -
it is swapped with the rest of the resource - so going from a fogged biome to an
unfogged one cuts the fog instead of fading it out.

**A biome's `atmosphere` is a whole environment, not a patch on the level's.**
While a biome that has one is active, the `WorldEnvironment` renders that file, so
a fog setting left in the level's own environment (`environment/new_environment.tres`)
only survives until the first biome is applied. Turning fog on there and waiting for
the biome to change its colour will therefore show nothing at all - author the fog in
the biome's environment, or give the provider no `atmosphere` to keep the level's own.
The debug overlay's `fog` line reads the environment that is actually rendering, so
this is visible rather than guessed at.

One approximation to know about: element boundaries are measured along the
centreline, and the endless track indexes slots by the straight segment's length,
while a 5-degree turn is 104.7 m long. The biome under the player can therefore
be off by about half a segment near a boundary, which a multi-second fade hides
completely.

The demos show why a biome should carry its own `atmosphere` even when it is a
day-lit one: `rural.tres` carries one as an inline `Environment` (the project's
sky and tonemapping, plus fog and a haze colour), and that fog is what turns the
far end of the view into distance instead of a crisp rectangle. Without it,
everything past the playfield is as sharp as the road.

Two biomes have to differ *where the player is looking*, or the transition is
invisible even though the data changed. The numbers that matter for fog are:

| Field | Why it decides whether a change is seen |
|---|---|
| `fog_density` | metres of air per unit of haze: the demo's two atmospheres are 0.0027 and 0.0042, so the same geometry sits in much thicker air after the change |
| `fog_light_color` | the colour the distance takes; the clearest signal a biome has |
| `fog_sky_affect` | how much of that colour the *sky* takes - and the sky is most of the picture |
| `fog_aerial_perspective` | gives the fog colour back to the sky, so a high value hides the biome's own tint |
| `fog_light_energy` | makes a dusk haze glow rather than just grey the view |

The demo playlist's two atmospheres are chosen this way: colours far enough apart to
notice, and haze that actually reaches the horizon, so the transition cannot silently
become a no-op. Only what is switched on counts - a biome with fog off, or with no
`atmosphere` at all, is respected rather than reported.

---

## 3. Authoring a new biome

1. **Road.** Make a material with the ground shader of the biome (or an existing
   one). Either reference it directly or put several into `road_skins` so the
   surface varies along the biome.
2. **Layers.** Duplicate `rural/layers/rural_near.tres`, `rural/layers/rural_mid.tres`
   and `rural/layers/rural_far.tres` - one per band of `LAYERS.md`, whose distance
   limits 3.1 lists - or write new ones, and assign the artwork as described there.
   The director does not enforce the bands.
3. **Atmosphere.** Optional: an `Environment` in `atmosphere` for a different
   time of day or weather; the transition is automatic.
4. **Biome.** Duplicate `rural.tres`, set `biome_id`, `display_name` and the
   fields above. `BiomeProvider` can be used directly - no script needed.
5. **Playlist.** Add it to `playlist_demo.tres` for the endless track, or to a
   `sections` list for an authored lap.
6. **Check.** `playlist.validate()` runs on `BiomeDirector._ready()` and reports
   empty biomes, empty layers, inconsistent numbers - and layers that are set up to do
   something other than what they look like they do - through `push_error()`. See
   section 7.

For the three biomes of `BIOMES.md`, step 2 is the work: the obstacle and
feature tables there are data for the hooks of section 1.2 once obstacles exist.

### 3.1 Assigning assets to a layer

A biome has one decoration slot per band - `near_layer`, `mid_layer`, `far_layer` -
and each slot is one [BiomeLayer] resource. Inside that resource the artwork goes
into one of two lists, and the director picks one entry per instance:

| List | Takes | Use it for |
|---|---|---|
| `variants` | `PackedScene`s (root must be a `Node3D`) | props made of several nodes, or props with their own materials - a tree with a trunk and leaves, a house, a lamp. Materials travel inside the scene, and `mesh_material` is not applied |
| `meshes` | `Mesh`es | one-piece geometry where the layer's single `mesh_material` is enough - cards, silhouettes, hedge segments. This is the only form `multimesh` and `fit_to_segment` can use |

`variants` win: when both lists are filled the scenes are used, so a biome can swap
placeholder meshes for real props without touching anything else.

Which band takes what:

| Layer | Content of `LAYERS.md` | Assign it as | Cost knobs that matter |
|---|---|---|---|
| 1 - near, 15-60 m | trees, bushes, fences, lamps, mailboxes, benches - things the player can recognise as objects | `variants`, one scene per prop; or `meshes` with `multimesh` when the band is one repeated piece of geometry, as the demo's fence is | `frequency_min/max` for density (a wide range leaves visible gaps), `visible_range` around 300 m, `cast_shadow` off for anything small |
| 2 - mid, 60-200 m | tree lines, rooftops, hedges, poles, walls: silhouettes, not objects | `meshes`, one card or block per kind, `multimesh = true` | `fit_to_segment` for strips that must tile without gaps, `visible_range` ~600 m, `cast_shadow` off, `frequency_min/max` if the band should not dress every element |
| 3 - far, `RING_MIN_DISTANCE` up to the camera's far plane | far hills, a town edge, atmospheric haze | `mode = RING`, one card in `meshes`, an unshaded or billboard material in `mesh_material` | `count` and the card width together decide whether the ridge has holes (2.2 does the arithmetic), `host_every` = elements the silhouette may last for, `visible_range` past the ring, `cast_shadow` off |

Layer 0 is not a `BiomeLayer`: the road is assigned on the provider itself, through
`road_material_override` (or `road_skins`, which cycles per element, or
`road_surfaces` of [RuralBiome] for a surface that changes every few elements) and
`road_mesh_override`. Its two priority fields - `override_road_priority` and
`road_render_priority` - are the leftover of a reverted draw-order pass and nothing
reads them today; a biome currently draws with the priorities its materials were
authored with.

Four things that decide whether a layer looks right:

* **A sparse layer is a layer with gaps.** Nothing stitches the elements it skips
  together: a layer dressed by a `frequency` range comes in stretches, each of them
  continuous only inside its own segment. Where the look is one uninterrupted run -
  a hedge, a railing, a treeline - the answer is geometry that spans the element
  (`fit_to_segment`) on every element, not a sparser gate.
* **Distance bands come from `LAYERS.md`, not from the code**, and they are about the
  *player's* perception: near dressing should not be so far away that it reads as mid
  scenery. The one band limit the code does police is the ring's floor,
  `BiomeLayer.RING_MIN_DISTANCE` (200 m) - closer than that a card reads as scenery the
  runner could reach, and drive past. Its ceiling is not a layer's to choose:
  `prefabs/third_person.tscn` draws 250 m of world, and a ring past the far plane is
  simply not rendered. The demo's playfield is a bare 30 m road strip with no ground
  beside it, which is why `rural_near.tres` stands at 13.0 m - widen it once there is
  terrain to stand on.
* **`mesh_material` is a `material_override`.** One material for every mesh of the
  layer, and it wins over the mesh's own material. When two props need different
  looks, they are two scenes in `variants`, or two layers in different bands.
* **Placement is seeded, not random.** Every instance's position comes from
  `decor_seed + layer.seed`, the band, the element index and the slot, so a prop is
  in exactly the same place every time the endless track recycles that element.
  Give each layer its own `seed` only if you want the same band to look different
  between two providers or two layers of one biome.

A whole new prop that is a scene, end to end:

```text
1. worlds/scrolling_track/biomes/rural/props/roadside_bush.tscn
   - root Node3D, mesh children, their own materials
2. worlds/scrolling_track/biomes/rural/layers/rural_mid.tres
   - the rural band that instances scenes today: add the file to `variants` and keep
     the band and cost fields. `rural_near.tres` is a `multimesh` fence layer, where a
     `variants` entry would win and leave the fence unbuilt
3. rural.tres already points at that layer, so nothing else changes
4. BiomeDirector.refresh() rebuilds every placed segment at runtime and the debug
   overlay's `layers` line should show the new instance count. Editing the layer
   while the game runs is not enough on its own: the director remembers what each
   body already wears, so it rebuilds only when that changes - `refresh()` is what
   forgets
```

**Props inside the playfield (layer 0).** There is no decoration slot for it:
`decoration(ROAD)` is never asked (the default returns `null` for it) and
`decorate_layer()` is never called with `ROAD`. What layer 0 takes is the road
itself, which `_skin_road()` assigns on every placement from the provider fields
listed above.

Nothing validates the bands, though: `distance_min` and `distance_max` are just
metres from the centreline, so a `near_layer` is free to stand inside the playfield.
The demo already does it - the road is 30 m wide and `rural_near.tres` runs its fence
at 13.0 m, in the decorative margin `LAYERS.md` describes ("outer 3-6 m on each
side"). Three things come with it:

* Keep the running corridor clear. A 30 m playfield with an 18-24 m corridor leaves
  about 3-6 m of margin per side; anything closer than that is in the runner's path.
* Props there are visual. `BiomeLayer` instances are geometry with no collision, so
  the runner passes through them - unless the prop scene carries its own
  `StaticBody3D`, in which case it stops the runner but still has no gameplay meaning
  (no scoring, no despawn, no spawning rules). Real obstacles are the 1.2 hook.
* They pop in at the pool edge. Scenery at 90-150 m hides the pool window; a prop two
  metres from the runner appears in front of them, so keep those low and small, and do
  not expect `visible_range` to help.

If a biome needs playfield-level props as a first-class thing rather than scenery
placed close, that is a fourth slot (`road_layer`) plus a branch in `decoration()` and
`ROAD` added to the director's loop - worth doing when obstacles land, not before.

One slot per band is a deliberate limit, not an oversight: three bands with a list
each covers "what is near, what is middle, what is horizon" without a scene graph
to maintain. When a band needs two *independent* layers - a fence at 13 m and bushes
at 22 m, placed with different counts and seeds - either mix both assets in that
band's lists (the director spreads them over the same band), or add the second one
by hand in `decorate_layer()`. Turning the slots into arrays is a small change to
`BiomeProvider.decoration()` and `BiomeDirector` if a biome ever needs it.

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
  values), which is the property the recycling rules rely on - and those seeds
  spread over the whole 64-bit range, which is what keeps the mix constants above
  2^63 - 1 honest;
* playlist selection in all four modes (auto, single biome, shuffle, sections);
* the track/director contract: every pooled body gets the road skin, a layer is
  built once per hosted element, re-placing unchanged segments keeps the *same*
  decoration nodes, and switching biome rebuilds them in place;
* the pool ring: a body carries the window slot it is given rather than its position
  in the array, so moving the endless window by one element and stepping the closed
  loop by one both re-dress a single body and leave the rest as they were - the
  property that keeps a re-centre from rebuilding the whole pool in one frame;
* the spawn gate: an element a layer dresses only every N-th time is hosted the same
  way every time it is rebuilt, which is the same determinism claim one level up;
* horizon rings keep their distance band, ride with the runner, and are only laid
  out again when the runner leaves a region;
* the debug readout's numbers: the run a biome covers, the distance and element
  count to the next change (counting turns as the arcs they are), the run's
  progress, and the single-biome case, where there is no change to wait for.

It also refuses to pass quietly, because a runtime error in GDScript abandons the
function it happened in and the caller carries on - so a broken test would otherwise be
nothing but a run with fewer checks in it. Every test is declared `-> bool` and ends
with `return true`, which the runner reads back; a test that asserted nothing is a
failure whether it finished or not; and a run whose tree never came up names the tests
it skipped instead of reporting the shorter suite as a passing one. The summary counts
tests as well as checks - `252 checks in 18 tests, all green` - so a lost test says
`17 of 18` rather than hiding behind a green sentence. Why each of those guards is
there, including why the run starts from the first `_process` frame and not from
`_initialize()`, is in the file's own header comments; every one of them came from a
real failure.

---

## 5. What is placeholder here

The system is complete; the *content* of the demo is not, and the demo says so
wherever it matters:

| Asset | What it is |
|---|---|
| `rural/layers/rural_near.tres` | the wooden fence: `props/rural/fence_segment_wooden.obj` instanced through one [MultiMesh] per segment, 64 copies at 13.0 m, painted with the trunk material. `frequency_max = 6` makes it the demo of the seeded spawn gate - the fence arrives on about one element in six - and the `host_every = 3` the file also carries is a ring field this layer ignores |
| `rural/props/leaf_mesh.tres` | the leaf quad baked out of `uma_island.tscn`, so the demo does not depend on `props/rural/leaf.obj` being present in the checkout |
| `rural/layers/rural_mid.tres` | the island's tree, wrapped as `rural/props/rural_tree.tscn` and placed as a scene variant: real art, 4 per side between 18 and 70 m. Its 4700 leaf instances are laid out once per [MultiMesh], which is why the layer keeps `visible_range` short and casts no shadows; a real biome should bake a lighter tree |
| `rural/layers/rural_far.tres` | twenty billboard cards of 115 x 22 m on a 200-235 m ring - a horizon, not a panorama. They are still flat rectangles: replacing the card mesh with a hill silhouette is what this layer wants next. Only `rural_dusk` points at it, so the day biome runs without a horizon of its own |
| the base `Environment` in `rural.tres` | an inline sub-resource: background, sky and the fog that hazes the far band out. A real biome would light its own sky, not reuse the island's |
| `rural_dusk.tres` | a second biome so that transitions are visible at all; it is rural again with the dirt road texture and its own inline dusk `Environment`, and should be replaced by the first real biome (city or suburbs) |
| `rural/materials/*.tres` | flat colours with `TODO`-less names, because they will be replaced wholesale |

One geometric detail about `fit_to_segment`: a stretched strip is aligned with
the track's chord, not with the arc. On a 5-degree turn of 1200 m radius that is
about a metre of sag at the segment's ends, so neighbouring railing pieces meet
with a small step instead of a perfect seam. It is invisible next to a real
mesh; if it ever matters, wrap the strip in a short scene and do not use
`fit_to_segment`.

Three more things worth knowing while iterating:

* Biomes are play-time only. `TrackManager` is not a `@tool` script, so no biome
  work happens while the editor is paused; press Play, and see step 4 of 3.1 for
  re-applying an edit to a running world.
* Everything that scales with the pool is O(pooled segments): decoration is
  parented per segment, so the cost of a biome is its layer descriptors, not the
  length of the track, and an idle frame only compares 40 small dictionaries.
* What a rebuild costs is worth watching, because it is the one place the system
  spends real time: the overlay's `build` line reports the segments and instances of
  the last thing that was built, with the milliseconds it took
  (`BiomeDirector.last_build()`). It is published wherever a build *finishes* - at the
  end of each physics frame, and at the end of `_ready()` for the level's first
  dressing, which is the expensive one and would otherwise be blamed on the first
  frame. A re-centre should read a handful of segments; a number near `pool_size`
  means every body changed element, which in the demo is a few hundred instanced tree
  scenes and a visible freeze. The self-test asserts the first case for both an endless
  re-centre and a closed-loop step.

---

## 6. Debug overlay

`scripts/debug/debug_overlay.gd` is the window into all of the above at runtime. It
is a `CanvasLayer` that builds its own panel, finds the level's `TrackManager`,
`BiomeDirector` and player by itself (or takes them from the inspector), and shows:

| Line | What it is |
|---|---|
| `fps / frame / physics` | frame rate and the two process times, in ms |
| `s` | metres along the centreline to the runner, counted from the start of the endless level or from the closed loop's origin, plus the lap and the distance left in it |
| `speed` | the player's velocity, in m/s and in km/h |
| `element` | the element index under the runner, whether it is a straight or which way it turns, and how far into it they are |
| `pos` | the player's world position |
| `biome` | the active provider's `biome_id` and `display_name` |
| `next` | the biome that follows, in metres, seconds and elements - or "this biome runs the whole track" when the playlist pins one |
| the bar | how far through the current biome run the runner is |
| `track` | endless or closed loop, pool size, seed / lap length |
| `layers` | instances built per decoration band, as they really are in the world: an along-track layer parents them to the segment bodies, a `RING` one to the horizon anchor, and both are counted |
| `build` | what the last rebuild cost: segments re-dressed, instances built, milliseconds spent; a frame that built nothing leaves it as it was, so it reads as the last cost rather than flickering to zero |
| `horizon` | cards in the ring and how far the anchor currently is |
| `fog` | the environment that is *rendering*: fog colour (with a swatch), density, energy, sky affect, aerial perspective, sun scatter |
| `issues` | how many problems the console reported, shown at every detail level |
| `skin` / `atmo` / `playlist` / `coming` | road variant, atmosphere file (and how far a transition has come), playlist mode, the next few runs |

The `fog` line is read from the live environment rather than from the biome's
`.tres`, so during a transition it shows the colour the player is looking at right
now, together with `atmo ... fading 43%`. That is what makes "the fog does not
change with the biome" answerable from the screen instead of from the data.

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
the biome self-test checks the arithmetic behind them.

`run_range_at()` deserves a note: a biome *run* is a maximal stretch of elements
served by one provider, measured rather than derived from `segments_per_biome`.
That matters with shuffling, where a round can open with the biome that is already
running, making the run twice as long as a round.

To add the overlay to another level, add a `CanvasLayer` with the script attached:

```gdscript
[node name="DebugOverlay" type="CanvasLayer" parent="."]
script = ExtResource("debug_overlay")
```

---

## 7. Errors in the console

The biome system is data, so most of what can go wrong with it goes wrong quietly: a
layer keeps rendering, it just renders something else than what the file says. Two
kinds of message are printed to catch that.

**At startup**, `BiomeDirector._ready()` asks the playlist to validate itself and
prints one `push_error` per problem, after a line naming the file they came from:

```text
BiomeDirector (BiomeDirector): res://worlds/scrolling_track/playlists/playlist_demo.tres
has 3 problem(s), biomes still run:
  - rural_dusk: MID layer `visible_range` (120.0 m) is closer than `distance_max` (200.0 m),
    so part of this layer is never visible
  - rural_dusk: FAR layer a ring card at `distance_min` = 60.0 m could be driven past;
    the horizon belongs beyond 200 m
  - both `biomes` and `sections` are set: the sections win, so the 2 biome(s) in `biomes`
    are never used
```

Problems do not stop the run: the playlist is still applied. They mean the world will
not look like the data says, and the alternative - a prop that never appears, a ring
that is driven through, a list that is silently ignored - is found by eye hours later.

**At runtime**, anything that fails while the world is being built is reported with
`_report_once()`: the first occurrence prints, repeats do not. A pooled body without
its `Mesh` child or a variant that is not a `Node3D` would otherwise print the same
line once per segment, several hundred times per minute, and the second message is no
more useful than the first. The keys are in `reported_problems()`, so a test can see
what was said:

| Reported once | When |
|---|---|
| no `TrackManager` / no `BiomePlaylist` | the director cannot run at all |
| the track has no `player` | no biome can be chosen, so nothing is decorated |
| a pooled body has no `Mesh` child | the road skin is not applied (check `TrackManager`'s pool) |
| a biome carries an atmosphere but there is no `WorldEnvironment` | no sky, fog or light of a biome is ever shown |
| neither the biome nor the level has an environment | the atmosphere stays whatever it was |
| a `variants` entry is empty, or its root is not a `Node3D` | that prop is skipped |

`BiomeDirector.validation_problems()` and `reported_problems()` expose both kinds for a
test, and the debug overlay shows an `issues` line - `2 · see the Output panel` - at
every detail level, because a phone screen has no Output panel to look at.
