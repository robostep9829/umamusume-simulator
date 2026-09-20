[//]: # (By Qwen3.8-Max)
# Recommended layer structure

## Layer 0: Playfield / Gameplay Layer

This is your active running surface.

```text
~30m wide ground plane/chunks
barriers
coins
weights
dirt zones
stairs
colliders
spawn sockets
```

This layer:

```text
spawns in front of the player
recycles behind the player
needs collision
needs gameplay logic
needs high visual clarity
```

This is the only layer that should strongly affect gameplay.

Example:

```text
Playfield width: 30m
Chunk length: 60m / 80m / 100m
Player corridor: maybe 18–24m of the 30m
Outer 3–6m on each side: decorative margin
```

Even if the plane is 30m wide, you do not need to place critical obstacles across all 30m. Keep the main playable corridor clean and readable.

---

## Layer 1: Near Dressing Layer

This is the 3D decoration close to the track.

```text
fences
trees
mailboxes
lamps
bushes
small houses
benches
flower beds
```

This layer:

```text
sits beside the playfield
can be full 3D
should recycle with chunks
usually has no gameplay collision
should not block the player’s view of obstacles
```

Distance from track center:

```text
roughly 15m to 60m outward
```

This layer helps the world feel physical and lived-in, but it should not fight for attention.

---

## Layer 2: Mid Parallax Layer

This is where the world starts feeling large.

```text
house silhouettes
tree lines
distant fences
hills
power poles
small buildings
water tower
```

This layer:

```text
moves slower than the playfield
can be low-poly or flat cards
does not need collision
can update less frequently
can be reused for a long time
```

Distance:

```text
roughly 60m to 200m away
```

This layer is very important for the “vast but simple” look.

---

## Layer 3: Far Background / Sky Layer

This is your horizon.

```text
sky
clouds
far hills
far town silhouette
large landmarks
atmospheric haze
```

This layer:

```text
is basically camera-locked or very slow parallax
does not need collision
does not need detailed geometry
can be a texture, panorama card, cylinder, or skybox
changes only on biome transition
```

Distance:

```text
visually 200m to infinity
```

The far end of that is not the layer's to choose: this layer is culled by the camera's
far plane, and the camera draws 250 m of world (`prefabs/third_person.tscn`). The rural
horizon therefore sits at 200-235 m: 20 cards of 115 x 22 m, the closest a ring may be
without reading as scenery you could drive into (`BiomeLayer.RING_MIN_DISTANCE`) and
inside the far plane, where it is drawn. A ring parked beyond the far plane is reported
by `BiomeDirector` instead of quietly vanishing, and `tools/verify_horizon.py` checks
both ends of the band against the camera. The fog had to be raised with it - 0.0018
covered the old 1.2 km ring 88% but the new one only 30%, so the rural atmosphere is at
0.0027, which puts 42% of the horizon in fog and keeps the ridge reading as distance.

This layer sells the scale.

---

## Draw order

Godot does not draw the opaque pass in any order a scene authored. It sorts the whole
pass by one packed key (`render_forward_mobile.h:484-506` in 4.7.2; the Forward+ renderer
uses the same key) and compares the fields in this order:

| # | Field | Bits | Comes from |
|---|---|---|---|
| 1 | `priority` | 8 | `render_priority` + 128, so a lower value is drawn first |
| 2 | `shader_id` | 32 | the RID of the shader |
| 3 | `material_id` | 32 | the RID of the material |
| 4 | `geometry_id` | 32 | the RID of the mesh |
| 5 | `surface_index` | 8 | the surface inside that mesh |
| 6 | `depth_layer` | 4 | `clamp(distance × 16 / (far − near), 0, 15)`, camera to the instance's bounds centre |
| 7 | `lod_index`, lightmap | 8+1 | |

Three things follow, and they are the whole of what this project can do about draw order:

* **Distance is the last field and it is four bits wide.** It is not a sort, it is
  sixteen buckets of `(far − near) / 16`. Behind the default 4000 m far plane a bucket is
  250 m - wider than a whole near band - which is why a layer 300 m deep used to come out
  "seemingly random". `prefabs/third_person.tscn` now draws 250 m, so a bucket is ~15.6 m.
* **Everything above it groups first.** Two props drawn with different meshes or
  materials can never be interleaved by distance: the mesh's RID decides before the
  bucket does. A layer's trunks and its canopies are each ordered among themselves and
  never against each other.
* **A tie is not broken in any order you authored.** `SortArray` is an introsort: a list
  of 16 elements or fewer is only insertion-sorted (so it keeps submission order), a
  longer one is permuted, and the permutation depends on the creation order of the nodes.
  That single threshold is what made the road tiles and the floor skirts look correctly
  ordered - 4 tiles each, so they kept track order - while 20 canopies and 18 trunks came
  out shuffled, and the mid layer's few cards shuffled *again* every time they were
  recreated on recycle.

### What a layer authors

* **`render_priority`** (with `override_render_priority` on) places a band in the frame:
  it is the first field of the key, so it orders whole groups. The rural bands use
  `1` near, `2` mid, `3` far, above the road and the ground (the materials they are
  authored with, `0`) and the character (`-1`, in its own materials). The override is
  applied to a *copy* of each material, one per (material, priority), because the leaf
  material lives inside `leaf_mesh.tres` and `uma_island` draws it too.
* **The sixteen distance buckets** are handed out by `BiomeDirector._rank_decorations`,
  which ranks the instances of a band nearest first and writes the bucket each one needs
  into `GeometryInstance3D.sorting_offset` (the engine computes
  `depth = distance − sorting_offset`, so the offset moves an instance between buckets
  without moving it in the world). See `scripts/biomes/draw_order.gd` for the arithmetic
  and for the tie-break that keeps two instances the same distance away from trading
  places between frames. The pass is bounded by the camera: it walks only the bodies whose
  own distance is within the far plane plus one bucket, so a band costs a few dozen nodes
  per pass instead of the whole pool. An instance of a body it did keep can still be past
  the far plane - the walk prunes whole bodies and never looks inside a pruned one - which
  costs nothing, because the far plane clips it whatever bucket it is in.

### What cannot be ordered

* **The instances inside one `MultiMesh`.** A `MultiMeshInstance3D` is one element with
  one bucket; its instances are rasterised in buffer order, which is the order the CSV was
  baked in. Re-baking the layout in a different order is the only lever, and it cannot be
  view-dependent - one buffer order serves every camera angle and every yaw.
* **Instances of different meshes or materials against each other** (see above).
* **Anything across two priority groups.** A bucket only ever compares within one.

### Reading a capture

Count the draws in the group. Four road tiles or six mid cards - 16 or fewer - are in
submission order, which is track order, and they will look right for a reason nothing in
the scene file states. Twenty canopies are in introsort order, which is a function of the
order the nodes were created. If a group's order changes between two captures of the same
run, look for nodes being recreated rather than reused: the mid layer re-instantiates its
cards on every recycle, the road tiles only have their mesh swapped.
