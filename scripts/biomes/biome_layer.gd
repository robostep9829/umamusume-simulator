class_name BiomeLayer
extends Resource

## One decoration layer of a biome: what is placed, how far from the track, how
## densely, and how it is recycled.
##
## [BiomeProvider]s hand these out per [enum BiomeProvider.Layer] and the
## [BiomeDirector] turns them into nodes, so most biomes stay pure data - a few
## `.tres` files, no spawning code - which is the "same chunk logic, different
## theme" idea from `worlds/scrolling_track/doc/BIOMES.md` and the distance bands
## from `worlds/scrolling_track/doc/LAYERS.md`.
##
## Instances are placed in the hosting segment's local frame (entry point at the
## origin, -Z forward, +X to the right of the runner), so a layer follows the
## track exactly - curves included, in both directions - and recycles together
## with the segment it hangs off.


## Where the instances of a layer are placed.
enum Mode {
	## Spread along the hosting segment's arc, beside the track. This is the
	## classic "trees along the road" layer; it recycles with the segment pool
	## and is what layers 1 and 2 of LAYERS.md need.
	ALONG_TRACK,
	## Spread evenly on a ring around the horizon anchor, facing the middle of
	## the ring. Horizon content (far hills, a town silhouette, a ring of haze
	## cards) must not show the seams of the segment pool, so it is not tied to
	## a segment at all: it is rebuilt only when the player has moved far enough
	## away from the anchor (see [member BiomeDirector.ring_anchor_snap_distance]).
	RING,
}

## Which side of the track gets instances (in RING mode the ring is closed, so
## this is ignored).
enum Side {
	BOTH,
	## Left of the travelling direction, i.e. -X in the segment's local frame.
	LEFT,
	## Right of the travelling direction, i.e. +X in the segment's local frame.
	RIGHT,
}

## Uncheck to keep an authored layer around but inactive.
@export var enabled: bool = true

@export_group("Content")
## Scenes instanced for this layer; one is picked per instance. Prefer these for
## props made of several nodes (a tree with trunk and leaves, a house).
@export var variants: Array[PackedScene] = []
## Meshes instanced for this layer; one is picked per instance. Prefer these for
## cheap repeated geometry and when `multimesh` is on.
@export var meshes: Array[Mesh] = []
## Material applied to instances built from `meshes` (scenes keep their own).
@export var mesh_material: Material
## Draw all instances of this layer inside one MultiMesh, i.e. one draw call per
## segment. Forces the first mesh of `meshes` for every instance. ALONG_TRACK
## only, since a ring is a single group anyway.
@export var multimesh: bool = false

@export_group("Placement")
@export var mode: Mode = Mode.ALONG_TRACK
## Instances per hosted segment and side (ALONG_TRACK), or the total number of
## instances around the anchor (RING).
@export var count: int = 2
## Which side of the track gets instances. Ignored in RING mode, which always
## closes the circle.
@export var side: Side = Side.BOTH
## ALONG_TRACK: host the layer on every N-th element only. The objects themselves
## have to cover the skipped span (a tree line built for `host_every = 4` must be
## as long as four segments), otherwise the layer will look like it has holes.
## RING: how many elements may pass before the horizon is allowed to change, so a
## far biome can keep one silhouette for a long while (1 = every re-snap).
@export var host_every: int = 1
## Distance from the centreline (ALONG_TRACK) or ring radius (RING), in metres.
## The LAYERS.md bands are roughly: 15-60 m for layer 1, 60-200 m for layer 2,
## 200 m and beyond for layer 3.
@export var distance_min: float = 18.0
@export var distance_max: float = 30.0
## ALONG_TRACK: fraction of the segment left empty at both ends, so neighbouring
## segments do not stack objects on top of each other at the seam. Ignored in RING
## mode.
@export var edge_margin: float = 0.1
## ALONG_TRACK: random offset along the track, as a fraction of each instance's
## share of the segment (0 = perfectly even spacing, 1 = anywhere inside its
## share). Ignored in RING mode, which always spreads instances evenly around the
## circle.
@export var along_scatter: float = 0.5
## Additional random lateral offset, in metres (plus or minus this value).
@export var lateral_scatter: float = 0.0
## Vertical offset from the track surface, in metres.
@export var lift: float = 0.0
## Additional random vertical offset, in metres (plus or minus this value).
@export var lift_scatter: float = 0.0
@export var scale_min: float = 1.0
@export var scale_max: float = 1.0
## Random yaw, in degrees, added to the base orientation (plus or minus this
## value).
@export var yaw_scatter: float = 0.0
## Rotate every instance so that it faces the centreline (fences, signs, houses).
@export var face_track: bool = false
## Stretch the mesh so that one copy spans its share of the segment, and align
## the mesh's longest horizontal side with the track. Use it for strips that must
## tile without gaps (railings, fences, hedges) whose authored length you would
## otherwise have to match by hand. Mesh layers only; scenes and `multimesh` are
## left as authored.
@export var fit_to_segment: bool = false
## Offset added to the director's decoration seed, so two layers of one biome do
## not have to be authored with matching seeds.
@export var seed: int = 0

@export_group("Cost")
## Hide instances further away than this, in metres.
@export var visible_range: float = 600.0
## Uncheck for layers whose shadows would never be visible (horizon cards).
@export var cast_shadow: bool = true


## False when the layer has nothing to draw, either because it is disabled or
## because no content was authored. The director skips it in that case, which is
## how a biome can leave a layer empty.
func is_usable() -> bool:
	if not enabled:
		return false
	return not variants.is_empty() or not meshes.is_empty()


## True when the layer is built by the horizon anchor instead of by a segment.
func is_ring() -> bool:
	return mode == Mode.RING


## Problems the [BiomeDirector] reports at startup, so an unfinished biome fails
## loudly instead of rendering nothing.
func validate() -> PackedStringArray:
	var problems := PackedStringArray()
	if not is_usable():
		problems.append("is enabled but has neither `variants` nor `meshes`")
	if count <= 0:
		problems.append("`count` must be at least 1")
	if host_every <= 0:
		problems.append("`host_every` must be at least 1")
	if distance_max < distance_min:
		problems.append("`distance_max` is smaller than `distance_min`")
	if fit_to_segment and meshes.is_empty():
		problems.append("`fit_to_segment` needs `meshes`, it is ignored for scenes")
	return problems
