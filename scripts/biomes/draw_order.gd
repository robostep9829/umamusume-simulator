class_name BiomeDrawOrder
extends RefCounted

## Front-to-back ordering for the instances a [BiomeLayer] places.
##
## Godot does not sort the opaque pass by distance. It sorts it by one packed key
## (`render_forward_mobile.h:484-506`, mobile renderer, and the same in `forward_plus`),
## compared `sort_key2` first and then `sort_key1`:
##
## [codeblock]
## priority:8 | shader_id:32 | material:32 | geometry:32 | surface:8 | depth_layer:4 | lod:8
## [/codeblock]
##
## `render_priority` is the whole first field, so it orders *groups* of material and
## nothing else. A mesh's index comes next, so two props drawn with different meshes are
## grouped by mesh before anything position-dependent is considered. Only then comes
## `depth_layer`: four bits, set from the distance from the camera to the instance's
## bounds centre as `CLAMP(int(depth * 16 / z_max), 0, 15)` with `z_max = far - near`
## (`render_forward_mobile.cpp:2182` and `:2213`). Instances that tie on every field -
## which is what every instance of one layer does - come out in whatever order the sort
## left them, and the sort is not stable, so the order is a permutation of the order the
## nodes were created in and changes as they are recycled.
##
## The one per-instance lever is that 4-bit field: the engine computes
## `depth = distance_to_bounds_centre - sorting_offset` (`:2206` and `:2211`), so
## [member GeometryInstance3D.sorting_offset] moves an instance between the sixteen
## buckets without touching its position. This class hands out one bucket per instance,
## nearest first, so the instances of a layer are drawn front to back even though the
## engine only ever sees sixteen bands.
##
## What this cannot do, and why:
##
## * Order instances of *different* meshes or materials against each other. Those fields
##   outrank the bucket, so a layer's trunks and its canopies are each ordered among
##   themselves but never interleaved.
## * Order the instances inside one [MultiMesh]. A [MultiMeshInstance3D] is a single
##   element with a single bucket; its instances are rasterised in buffer order, which is
##   the order the CSV was baked in.
## * Order anything against a group of a different `render_priority`. Buckets only
##   compare within one group - see the draw-order section of
##   `worlds/scrolling_track/doc/LAYERS.md`.

## The engine's depth buckets are four bits wide, so there are exactly sixteen.
const DEPTH_LAYERS := 16


## Width of one bucket in metres: `z_max / 16`. The camera's far plane is what sets it -
## at the default 4000 m a bucket is 250 m, which is why a near layer 300 m deep landed
## in one or two buckets and read as unordered; `prefabs/third_person.tscn` uses 250 m,
## which makes a bucket ~15.6 m.
static func bucket_size(camera_far: float, camera_near: float) -> float:
	return maxf(camera_far - camera_near, 0.001) / float(DEPTH_LAYERS)


## Which bucket the `rank`-th nearest instance of `count` should land in.
##
## Spread evenly over all sixteen rather than one rank per bucket: a layer with four
## instances then uses 0, 5, 10, 15 (so the whole visible depth range separates them),
## and a layer with more than sixteen doubles up in some buckets instead of pushing
## everything past the sixteenth into the last one.
static func bucket_for(rank: int, count: int) -> int:
	if count <= 1:
		return 0
	var spread := float(DEPTH_LAYERS - 1) * float(rank) / float(count - 1)
	return clampi(roundi(spread), 0, DEPTH_LAYERS - 1)


## The `sorting_offset` that puts an instance at `distance` into `bucket`.
##
## An offset of `distance - (bucket + 0.5) * size` lands it in the middle of the bucket
## whatever its real distance: half a bucket of margin on each side, so the next frame's
## camera movement cannot nudge it into a neighbouring bucket and swap it with its
## neighbour.
static func sorting_offset(distance: float, bucket: int, size: float) -> float:
	return distance - (float(bucket) + 0.5) * size


## Ranks `nodes` nearest first and writes the bucket each one needs into its
## `sorting_offset`. Mutates the nodes; the array itself is not reordered.
##
## Also switches them to origin-based depth. The engine's default is the centre of the
## instance's transformed bounds, which is the wrong point for these props - a tree's
## bounds centre is halfway up its canopy, and a horizon card's is metres above the
## ground - and it is the one distance this code can compute and the engine cannot
## disagree with.
##
## Returns how many instances were ranked, so a caller can tell "nothing to do" from
## "no camera".
static func rank(
	nodes: Array[GeometryInstance3D], origin: Vector3, camera_far: float, camera_near: float
) -> int:
	var pairs: Array = []
	for node in nodes:
		if node == null or not is_instance_valid(node):
			continue
		pairs.append([origin.distance_to(_origin_of(node)), node])
	if pairs.is_empty():
		return 0
	pairs.sort_custom(_nearer_first)
	var size := bucket_size(camera_far, camera_near)
	var count := pairs.size()
	for i in count:
		var pair: Array = pairs[i]
		var node: GeometryInstance3D = pair[1]
		node.sorting_use_aabb_center = false
		node.sorting_offset = sorting_offset(float(pair[0]), bucket_for(i, count), size)
	return count


## Nearest first, and by instance id when two are equidistant.
##
## Equidistant is the normal case for a mid-layer card: it places one copy each side of
## the track, the same distance out. The engine's sort is not stable, so without this
## tie-break those two would trade places between passes, and a capture of one frame
## would not match the next.
static func _nearer_first(a: Array, b: Array) -> bool:
	var a_distance := float(a[0])
	var b_distance := float(b[0])
	if is_equal_approx(a_distance, b_distance):
		var a_node: GeometryInstance3D = a[1]
		var b_node: GeometryInstance3D = b[1]
		return a_node.get_instance_id() < b_node.get_instance_id()
	return a_distance < b_distance


## The point the engine measures the instance from once this class has switched it to
## origin-based depth: its transform origin.
##
## `global_position` is only defined for a node inside the tree - on a detached one the
## engine reports `Condition "!is_inside_tree()"`, returns an identity transform and would
## have every instance of a detached band ranked at distance zero - so a node that is not
## in the tree yet is measured by its own position instead. The director ranks nodes that
## are in the tree; this keeps a probe or a node built but not yet added honest rather
## than silently out of order.
static func _origin_of(node: GeometryInstance3D) -> Vector3:
	return node.global_position if node.is_inside_tree() else node.position
